import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/lab_server.dart';

void main() {
  late Directory dir;
  late LabServer server;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('labsrv');
    await File(
      '${dir.path}/nscontrol-1.jsonl',
    ).writeAsString('{"type":"meta"}\n');
    server = LabServer(
      port: 0,
      key: 'k1',
      recordings: () async => [File('${dir.path}/nscontrol-1.jsonl')],
      onConnected: () => [
        {'type': 'meta', 'schema': 1},
      ],
    );
    await server.start();
  });
  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  Future<(int, String)> get(String path) async {
    final client = HttpClient();
    final request = await client.get('127.0.0.1', server.boundPort!, path);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    return (response.statusCode, body);
  }

  test('page and recordings need the key', () async {
    expect((await get('/')).$1, 403);
    final (code, html) = await get('/?k=k1');
    expect(code, 200);
    expect(html, contains('NSControl · Лаборатория'));
    expect(html, isNot(contains('http://')), reason: 'no external resources');
    final (_, list) = await get('/recordings?k=k1');
    expect(jsonDecode(list), [
      {'name': 'nscontrol-1.jsonl', 'bytes': 16},
    ]);
    expect(
      (await get('/recordings/nscontrol-1.jsonl?k=k1')).$2,
      '{"type":"meta"}\n',
    );
    expect((await get('/recordings/other.jsonl?k=k1')).$1, 404);
    expect(server.urls.every((u) => u.endsWith('?k=k1')), isTrue);
  });

  test('addresses: Wi-Fi first, no 464XLAT or link-local, no duplicates', () {
    expect(
      LabServer.reachableAddresses([
        ('lo0', '127.0.0.1'),
        ('pdp_ip0', '192.0.0.6'),
        ('pdp_ip1', '192.0.0.6'),
        ('en2', '169.254.10.2'),
        ('bridge100', '172.20.10.1'),
        ('en0', '192.168.0.35'),
        ('en0', '192.168.0.35'),
      ]),
      ['192.168.0.35', '172.20.10.1', '127.0.0.1'],
    );
  });

  test('websocket gets the greeting, broadcasts and pongs', () async {
    expect(
      () => WebSocket.connect('ws://127.0.0.1:${server.boundPort}/ws?k=bad'),
      throwsA(isA<WebSocketException>()),
    );
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/ws?k=k1',
    );
    final messages = StreamIterator(socket.map((m) => jsonDecode(m as String)));
    expect(await messages.moveNext(), isTrue);
    expect(messages.current['type'], 'meta');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(server.clients, 1);
    server.broadcast({'type': 'frame', 'capturedUs': 1});
    expect(await messages.moveNext(), isTrue);
    expect(messages.current['type'], 'frame');
    socket.add(jsonEncode({'type': 'ping', 't': 12.5}));
    expect(await messages.moveNext(), isTrue);
    expect(messages.current, {'type': 'pong', 't': 12.5});
    await socket.close();
  });

  test('review page, reviews and clips of the trip debug', () async {
    final dir = await Directory.systemTemp.createTemp('review');
    addTearDown(() => dir.delete(recursive: true));
    final messages = <Map<String, Object?>>[];
    final demand = <bool>[];
    final debug = LabServer(
      port: 0,
      key: 'k2',
      recordings: () async => [],
      directory: dir,
      onMessage: messages.add,
      onVideoDemand: demand.add,
    );
    await debug.start();
    addTearDown(debug.stop);
    final port = debug.boundPort!;
    Future<(int, String)> call(
      String method,
      String path, [
      String? body,
    ]) async {
      final client = HttpClient();
      final request = await client.open(method, '127.0.0.1', port, path);
      if (body != null) request.write(body);
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      client.close();
      return (response.statusCode, text);
    }

    final (code, html) = await call('GET', '/review?k=k2');
    expect(code, 200);
    expect(html, contains('NSControl · Разбор поездки'));
    expect(html, isNot(contains('http://')));
    expect((await call('GET', '/reviews/trip-1?k=k2')).$1, 404);
    expect((await call('PUT', '/reviews/trip-1?k=k2', '{"type":"x"}')).$1, 400);
    expect((await call('PUT', '/reviews/..%2Fa?k=k2', '{}')).$1, 404);
    final review = {'type': 'review', 'schema': 1, 'recordingId': 'trip-1'};
    expect(
      (await call('PUT', '/reviews/trip-1?k=k2', jsonEncode(review))).$1,
      200,
    );
    expect(jsonDecode((await call('GET', '/reviews/trip-1?k=k2')).$2), review);
    expect(
      await File('${dir.path}/nscontrol-trip-1.review.json').exists(),
      isTrue,
    );
    expect((await call('PUT', '/reviews/trip-1?k=bad', '{}')).$1, 403);

    await Directory('${dir.path}/clips').create();
    await File(
      '${dir.path}/clips/nscontrol-trip-1.clip-5000-mark.ndjson',
    ).writeAsString('{"type":"clip"}\n');
    await File(
      '${dir.path}/clips/nscontrol-trip-2.clip-5000-mark.ndjson',
    ).writeAsString('{"type":"clip"}\n');
    expect(jsonDecode((await call('GET', '/clips?rec=trip-1&k=k2')).$2), [
      {'name': 'nscontrol-trip-1.clip-5000-mark.ndjson', 'bytes': 16},
    ]);
    expect(
      (await call(
        'GET',
        '/clips/nscontrol-trip-1.clip-5000-mark.ndjson?k=k2',
      )).$2,
      '{"type":"clip"}\n',
    );

    final socket = await WebSocket.connect('ws://127.0.0.1:$port/ws?k=k2');
    final binary = <List<int>>[];
    socket.listen((m) {
      if (m is List<int>) binary.add(m);
    });
    socket.add(jsonEncode({'type': 'video', 'on': true}));
    socket.add(jsonEncode({'type': 'mark', 'kind': 'miss'}));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(demand, [true]);
    expect(messages.single['kind'], 'miss');
    debug.broadcastJpeg(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(binary.single, [1, 2, 3]);
    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(demand, [true, false]);
  });
}

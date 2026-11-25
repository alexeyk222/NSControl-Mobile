import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
}

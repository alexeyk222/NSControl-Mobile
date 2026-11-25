import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'lab_page_html.dart';

/// Local HTTP + WebSocket server of the lab. It runs only while the lab is
/// open, serves one self-contained page and pushes the same JSON objects that
/// go into the recording (one object per message). Only numbers leave the
/// phone. Every request needs the random key shown in the lab, so another
/// device in the same Wi-Fi cannot read the stream by guessing the address.
class LabServer {
  LabServer({
    required this.recordings,
    this.port = 8765,
    this.onConnected,
    String? key,
  }) : key = key ?? _randomKey();

  final int port;
  final String key;

  /// Lists the recording files that may be downloaded (newest first).
  final Future<List<File>> Function() recordings;

  /// Objects to send to a newly connected page (meta, calibration).
  final List<Map<String, Object?>> Function()? onConnected;
  HttpServer? _server;
  final _clients = <WebSocket>{};
  List<String> addresses = [];
  int get clients => _clients.length;
  bool get running => _server != null;
  int? get boundPort => _server?.port;

  static String _randomKey() {
    final random = Random.secure();
    return List.generate(8, (_) => random.nextInt(36).toRadixString(36)).join();
  }

  Future<void> start() async {
    if (_server != null) return;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    server.listen(_handle, onError: (_) {});
    addresses = await localAddresses();
  }

  /// Wi-Fi addresses first (en0 on iOS), loopback last.
  static Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      interfaces.sort(
        (a, b) => (a.name == 'en0' ? 0 : 1).compareTo(b.name == 'en0' ? 0 : 1),
      );
      return [
        for (final i in interfaces)
          for (final a in i.addresses) a.address,
      ];
    } catch (_) {
      return [];
    }
  }

  List<String> get urls => [
    for (final a in addresses) 'http://$a:${boundPort ?? port}/?k=$key',
  ];

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers.set('Cache-Control', 'no-store');
      if (request.uri.queryParameters['k'] != key) {
        response.statusCode = HttpStatus.forbidden;
        response.headers.contentType = ContentType.text;
        response.write('Нужна ссылка с ключом из Лаборатории NSControl.');
        await response.close();
        return;
      }
      final path = request.uri.path;
      if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _accept(socket);
        return;
      }
      if (path == '/' || path == '/index.html') {
        response.headers.contentType = ContentType.html;
        response.write(labPageHtml);
      } else if (path == '/recordings') {
        final files = await recordings();
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode([
            for (final f in files)
              {'name': f.uri.pathSegments.last, 'bytes': await f.length()},
          ]),
        );
      } else if (path.startsWith('/recordings/')) {
        final name = path.substring('/recordings/'.length);
        final file = (await recordings())
            .where((f) => f.uri.pathSegments.last == name)
            .firstOrNull;
        if (file == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.headers.set('Content-Type', 'application/x-ndjson');
          response.headers.set(
            'Content-Disposition',
            'attachment; filename="$name"',
          );
          await response.addStream(file.openRead());
        }
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  void _accept(WebSocket socket) {
    _clients.add(socket);
    for (final line in onConnected?.call() ?? const []) {
      socket.add(jsonEncode(line));
    }
    socket.listen(
      (message) {
        if (message is! String) return;
        try {
          final value = jsonDecode(message);
          // Round trip for the page's latency estimate.
          if (value is Map && value['type'] == 'ping') {
            socket.add(jsonEncode({'type': 'pong', 't': value['t']}));
          }
        } catch (_) {}
      },
      onDone: () => _clients.remove(socket),
      onError: (_) => _clients.remove(socket),
      cancelOnError: true,
    );
  }

  void broadcast(Map<String, Object?> line) {
    if (_clients.isEmpty) return;
    final text = jsonEncode(line);
    for (final socket in _clients.toList()) {
      try {
        socket.add(text);
      } catch (_) {
        _clients.remove(socket);
      }
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final socket in _clients.toList()) {
      // A page that never answers the close handshake must not block us.
      unawaited(
        socket.close().timeout(const Duration(seconds: 1), onTimeout: () {}),
      );
    }
    _clients.clear();
    await server?.close(force: true);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'lab_page_html.dart';
import 'review_page_html.dart';

/// Local HTTP + WebSocket server of the lab and of the trip's live debug
/// (docs/trip-debug.md). It serves the live page and the review page and
/// pushes the same JSON objects that go into the recording (one object per
/// message). Pictures leave the phone only as the developer debug video:
/// binary messages to pages that asked for it ([broadcastJpeg]) and clip
/// files on request, over the local network. Every request needs the random
/// key shown on the phone, so another device in the same Wi-Fi cannot read
/// the stream by guessing the address.
class LabServer {
  LabServer({
    required this.recordings,
    this.port = 8765,
    this.onConnected,
    this.onMessage,
    this.onVideoDemand,
    this.directory,
    String? key,
  }) : key = key ?? _randomKey();

  final int port;
  final String key;

  /// Lists the recording files that may be downloaded (newest first).
  final Future<List<File>> Function() recordings;

  /// Objects to send to a newly connected page (meta, calibration).
  final List<Map<String, Object?>> Function()? onConnected;

  /// A JSON object from a page other than `ping` (marks, video on/off).
  final void Function(Map<String, Object?> message)? onMessage;

  /// Called when the first page asks for the debug video and when the last
  /// one stops or leaves.
  final void Function(bool wanted)? onVideoDemand;

  /// The recordings folder: alarm clips in `clips/`, reviews beside the
  /// recordings as `nscontrol-<id>.review.json`. Null: no clips, no reviews.
  final Directory? directory;
  HttpServer? _server;
  final _clients = <WebSocket>{};
  final _video = <WebSocket>{};
  bool get videoWanted => _video.isNotEmpty;
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
      // Wi-Fi first, then the phone's own hotspot (bridge100 on iOS, the
      // Mac joins it in the car), loopback last.
      int rank(NetworkInterface i) => i.name == 'en0'
          ? 0
          : i.name.startsWith('bridge')
          ? 1
          : i.name.startsWith('lo')
          ? 3
          : 2;
      interfaces.sort((a, b) => rank(a).compareTo(rank(b)));
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
      } else if (path == '/review') {
        response.headers.contentType = ContentType.html;
        response.write(reviewPageHtml);
      } else if (path == '/clips') {
        final id = request.uri.queryParameters['rec'] ?? '';
        final files = await _clipFiles(id);
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode([
            for (final f in files)
              {'name': f.uri.pathSegments.last, 'bytes': await f.length()},
          ]),
        );
      } else if (path.startsWith('/clips/')) {
        final name = path.substring('/clips/'.length);
        final file = (await _clipFiles(
          null,
        )).where((f) => f.uri.pathSegments.last == name).firstOrNull;
        if (file == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          response.headers.set('Content-Type', 'application/x-ndjson');
          await response.addStream(file.openRead());
        }
      } else if (path.startsWith('/reviews/')) {
        await _review(request, path.substring('/reviews/'.length));
        return;
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

  /// Clip files of one recording (all with [recordingId] null).
  Future<List<File>> _clipFiles(String? recordingId) async {
    final dir = directory == null
        ? null
        : Directory('${directory!.path}/clips');
    if (dir == null || !await dir.exists()) return [];
    final prefix = recordingId == null ? null : 'nscontrol-$recordingId.clip-';
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.ndjson'))
        .cast<File>()
        .where(
          (f) => prefix == null || f.uri.pathSegments.last.startsWith(prefix),
        )
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static final _safeId = RegExp(r'^[A-Za-z0-9._-]{1,120}$');

  /// GET or PUT `nscontrol-<id>.review.json` (the review page's verdicts:
  /// numbers and words only, never pictures).
  Future<void> _review(HttpRequest request, String id) async {
    final response = request.response;
    final dir = directory;
    if (dir == null || !_safeId.hasMatch(id) || id.contains('..')) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final file = File('${dir.path}/nscontrol-$id.review.json');
    if (request.method == 'PUT' || request.method == 'POST') {
      final body = await utf8.decoder
          .bind(request)
          .fold<String>('', (a, b) => a + b);
      try {
        if (body.length > 4 * 1024 * 1024) throw const FormatException();
        final value = jsonDecode(body);
        if (value is! Map || value['type'] != 'review') {
          throw const FormatException();
        }
        await dir.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent(' ').convert(value),
          flush: true,
        );
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'saved': file.uri.pathSegments.last}));
      } on FormatException {
        response.statusCode = HttpStatus.badRequest;
      }
    } else if (await file.exists()) {
      response.headers.contentType = ContentType.json;
      await response.addStream(file.openRead());
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
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
          if (value is! Map) return;
          switch (value['type']) {
            case 'ping':
              // Round trip for the page's latency estimate.
              socket.add(jsonEncode({'type': 'pong', 't': value['t']}));
            case 'video':
              _setVideo(socket, value['on'] == true);
            default:
              onMessage?.call(Map<String, Object?>.from(value));
          }
        } catch (_) {}
      },
      onDone: () => _drop(socket),
      onError: (_) => _drop(socket),
      cancelOnError: true,
    );
  }

  void _drop(WebSocket socket) {
    _clients.remove(socket);
    _setVideo(socket, false);
  }

  void _setVideo(WebSocket socket, bool on) {
    final before = _video.isNotEmpty;
    if (on) {
      _video.add(socket);
    } else {
      _video.remove(socket);
    }
    if (before != _video.isNotEmpty) onVideoDemand?.call(_video.isNotEmpty);
  }

  /// A debug video picture (`DebugJpeg.message`) to the pages that asked
  /// for the video.
  void broadcastJpeg(Uint8List message) {
    for (final socket in _video.toList()) {
      try {
        socket.add(message);
      } catch (_) {
        _drop(socket);
      }
    }
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
    final hadVideo = _video.isNotEmpty;
    _video.clear();
    if (hadVideo) onVideoDemand?.call(false);
    await server?.close(force: true);
  }
}

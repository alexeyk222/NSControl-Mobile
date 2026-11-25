import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Developer debug video (docs/trip-debug.md). Off by default and only in
/// developer mode: small JPEGs of the ARKit frame for the live page on the
/// Mac (local Wi-Fi or the phone's hotspot, never the internet) and short
/// clips around alarms and marks kept on the phone for the review. This is
/// the one place where pictures exist outside the native preview; the
/// JSONL recording stays numbers only (ФТ-01).
class DebugVideoOptions {
  const DebugVideoOptions({this.fps = 0, this.width = 480, this.quality = .5});

  /// JPEGs a second; 0 is off.
  final double fps;

  /// Long side of the JPEG (the sensor image is landscape, 4:3 on ARKit).
  final int width;

  /// JPEG quality 0..1.
  final double quality;

  static const off = DebugVideoOptions();

  /// About 15–25 KB a JPEG at 480×360 and quality 0.5: ~100 KB/s at 5 fps.
  static const live = DebugVideoOptions(fps: 5);

  bool get on => fps > 0;

  Map<String, Object?> toMap() => {
    'fps': fps,
    'width': width,
    'quality': quality,
  };

  @override
  bool operator ==(Object other) =>
      other is DebugVideoOptions &&
      other.fps == fps &&
      other.width == width &&
      other.quality == quality;

  @override
  int get hashCode => Object.hash(fps, width, quality);
}

/// One JPEG of the debug video, in the sensor orientation. [quarterTurns]
/// and [mirrored] say how the phone's preview shows it (the preview
/// `displayTransform`): the page rotates the picture the same way.
class DebugJpeg {
  const DebugJpeg({
    required this.capturedUs,
    required this.bytes,
    required this.width,
    required this.height,
    this.quarterTurns = 1,
    this.mirrored = true,
  });

  /// Frame time on the caller's clock (the one given to the engine).
  final int capturedUs;
  final Uint8List bytes;
  final int width, height, quarterTurns;
  final bool mirrored;

  Map<String, Object?> header(int atUs) => {
    'type': 'jpeg',
    'atUs': atUs,
    'width': width,
    'height': height,
    'quarterTurns': quarterTurns,
    'mirrored': mirrored,
  };

  /// Binary WebSocket message: `NSJ1`, the header length (uint32, little
  /// endian), the header JSON in UTF-8, then the JPEG. [atUs] is the frame
  /// time on the stream's clock (the recording clock).
  Uint8List message(int atUs) {
    final head = utf8.encode(jsonEncode(header(atUs)));
    final out = Uint8List(8 + head.length + bytes.length);
    out.setRange(0, 4, ascii.encode('NSJ1'));
    ByteData.sublistView(out).setUint32(4, head.length, Endian.little);
    out.setRange(8, 8 + head.length, head);
    out.setRange(8 + head.length, out.length, bytes);
    return out;
  }

  /// Inverse of [message] for tests and tools: header and JPEG bytes.
  static (Map<String, dynamic>, Uint8List)? parseMessage(Uint8List data) {
    if (data.length < 8 || ascii.decode(data.sublist(0, 4)) != 'NSJ1') {
      return null;
    }
    final n = ByteData.sublistView(data).getUint32(4, Endian.little);
    if (8 + n > data.length) return null;
    final head = jsonDecode(utf8.decode(data.sublist(8, 8 + n)));
    if (head is! Map<String, dynamic>) return null;
    return (head, Uint8List.sublistView(data, 8 + n));
  }
}

/// A face source that can send the debug video (ARKit).
abstract interface class DebugVideoSource {
  /// Turns the debug JPEGs on ([options] with fps > 0) or off; each JPEG
  /// goes to [onJpeg]. Kept across restarts of the source.
  Future<void> setDebugVideo(
    DebugVideoOptions options,
    void Function(DebugJpeg jpeg)? onJpeg,
  );
}

/// Keeps the last seconds of the debug video in memory and writes a clip
/// around each alarm or mark to `clips/` beside the recordings, so a false
/// alarm can be seen in the review after the trip without a Mac in the car.
///
/// A clip file is NDJSON: a `clip` header line, then one `jpeg` line per
/// picture with its time on the recording clock and the JPEG in base64.
/// Clips that overlap are merged into one.
class ClipRecorder {
  ClipRecorder({
    required this.directory,
    required this.recordingId,
    this.beforeUs = 10000000,
    this.afterUs = 5000000,
    this.maxClips = 200,
    this.maxBytes = 400 * 1024 * 1024,
  });

  final Directory directory;
  final String recordingId;
  final int beforeUs, afterUs, maxClips, maxBytes;

  final _frames = ListQueue<(int, DebugJpeg)>();
  final List<_PendingClip> _pending = [];
  final List<File> written = [];
  int _bytes = 0, _clips = 0;
  Future<void> _writes = Future.value();

  /// Clips started but not yet written.
  int get pending => _pending.length;

  static String fileName(String recordingId, int atUs, String reason) =>
      'nscontrol-$recordingId.clip-${atUs ~/ 1000}-${_safe(reason)}.ndjson';

  static String _safe(String text) =>
      text.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// Adds a JPEG at [atUs] (recording clock); writes the clips it ends.
  void add(int atUs, DebugJpeg jpeg) {
    _frames.add((atUs, jpeg));
    // What a new trigger needs, or the earliest open clip if it needs more.
    var keepFrom = atUs - beforeUs;
    final open = _pending.firstOrNull;
    if (open != null && open.fromUs < keepFrom) keepFrom = open.fromUs;
    while (_frames.isNotEmpty && _frames.first.$1 < keepFrom) {
      _frames.removeFirst();
    }
    while (_pending.isNotEmpty && atUs >= _pending.first.toUs) {
      _write(_pending.removeAt(0));
    }
  }

  /// A clip around [atUs]: [beforeUs] before it and [afterUs] after.
  void trigger({required int atUs, required String reason, String? eventId}) {
    final from = atUs - beforeUs, to = atUs + afterUs;
    final last = _pending.lastOrNull;
    if (last != null && from <= last.toUs) {
      last.toUs = to > last.toUs ? to : last.toUs;
      last.reasons.add(reason);
      if (eventId != null) last.eventIds.add(eventId);
      return;
    }
    if (_clips + _pending.length >= maxClips || _bytes >= maxBytes) return;
    _pending.add(
      _PendingClip(atUs: atUs, fromUs: from, toUs: to, reason: reason)
        ..reasons.add(reason)
        ..eventIds.addAll([?eventId]),
    );
  }

  /// Writes the open clips with what there is (end of the trip).
  Future<void> flush() {
    for (final clip in _pending) {
      _write(clip);
    }
    _pending.clear();
    return _writes;
  }

  void _write(_PendingClip clip) {
    final frames = [
      for (final (at, jpeg) in _frames)
        if (at >= clip.fromUs && at <= clip.toUs) (at, jpeg),
    ];
    if (frames.isEmpty) return;
    _clips++;
    final first = frames.first.$2;
    final header = {
      'type': 'clip',
      'recordingId': recordingId,
      'atUs': clip.atUs,
      'fromUs': clip.fromUs,
      'toUs': clip.toUs,
      'reason': clip.reason,
      'reasons': clip.reasons.toList(),
      if (clip.eventIds.isNotEmpty) 'eventIds': clip.eventIds.toList(),
      'width': first.width,
      'height': first.height,
      'quarterTurns': first.quarterTurns,
      'mirrored': first.mirrored,
      'frames': frames.length,
    };
    final text = StringBuffer()..writeln(jsonEncode(header));
    for (final (at, jpeg) in frames) {
      text.writeln(
        jsonEncode({
          'type': 'jpeg',
          'atUs': at,
          'data': base64Encode(jpeg.bytes),
        }),
      );
    }
    final body = text.toString();
    _bytes += body.length;
    final file = File(
      '${directory.path}/${fileName(recordingId, clip.atUs, clip.reason)}',
    );
    _writes = _writes.then((_) async {
      try {
        await directory.create(recursive: true);
        await file.writeAsString(body, flush: true);
        written.add(file);
      } catch (_) {
        // A clip is a debugging aid: a full disk must not touch the trip.
      }
    });
  }
}

class _PendingClip {
  _PendingClip({
    required this.atUs,
    required this.fromUs,
    required this.toUs,
    required this.reason,
  });
  final int atUs, fromUs;
  int toUs;
  final String reason;
  final Set<String> reasons = {};
  final Set<String> eventIds = {};
}

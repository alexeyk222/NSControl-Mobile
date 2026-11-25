import 'dart:convert';
import 'calibration.dart';
import 'fatigue.dart';
import 'observation.dart';
import 'signals.dart';

/// Lines of the lab recording, JSONL schema 1 (docs/recognition-contract.md).
/// One JSON object per line; times are integer microseconds of a monotonic
/// clock that starts with the recording. The same objects go to the live
/// stream. Only numbers are recorded, never images (ФТ-01).
abstract final class RecordingSchema {
  static const version = 1;

  static Map<String, Object?> meta({
    required String recordingId,
    required String app,
    required List<String> engines,
    required DateTime startedAt,
    String? device,
    String? os,
    String subject = '',
    String notes = '',
    Map<String, Object?> extra = const {},
  }) => {
    'type': 'meta',
    'schema': version,
    'recordingId': recordingId,
    'app': app,
    'device': device,
    'os': os,
    'engines': engines,
    'startedAt': _localIso(startedAt),
    'subject': subject,
    'notes': notes,
    ...extra,
  };

  static Map<String, Object?> calibration({
    required int atUs,
    required CalibrationProfile profile,
    Map<String, Object?>? zones,
  }) => {
    'type': 'calibration',
    'atUs': atUs,
    'profile': profile.toJson(),
    'zones': ?zones,
  };

  /// One completed analysis of one engine. Without a face [signals] is null
  /// and `faceCount` is 0; with several faces the first is the driver
  /// candidate and `faceCount` tells the rest.
  static Map<String, Object?> frame({
    required String engine,
    required int capturedUs,
    required int completedUs,
    required int faceCount,
    FaceSignals? signals,
  }) => {
    'type': 'frame',
    'engine': engine,
    'capturedUs': capturedUs,
    'completedUs': completedUs,
    'faceCount': faceCount,
    if (signals != null) 'signals': signals.toJson(),
  };

  static Map<String, Object?> derived({
    required int atUs,
    required GazeZone zone,
    ChannelSnapshot? eyes,
    ChannelSnapshot? head,
    FatigueSnapshot? fatigue,
    Map<String, Object?> extra = const {},
  }) => {
    'type': 'derived',
    'atUs': atUs,
    'zone': zone.code,
    if (eyes != null) 'eyes': eyes.toJson(),
    if (head != null) 'head': head.toJson(),
    if (fatigue != null) 'fatigue': fatigue.toJson(),
    ...extra,
  };

  static Map<String, Object?> event({
    required String change,
    required ObservationEvent event,
    int? atUs,
  }) => {
    'type': 'event',
    'change': change,
    'atUs': ?atUs,
    'event': event.toJson(),
  };

  static Map<String, Object?> label({
    required int atUs,
    required String scenario,
    required String step,
    required String edge,
    int? rep,
  }) => {
    'type': 'label',
    'atUs': atUs,
    'scenario': scenario,
    'step': step,
    'edge': edge,
    'rep': ?rep,
  };

  static String encode(Map<String, Object?> line) => jsonEncode(line);

  /// Calendar time with the local offset, e.g. 2026-11-27T10:00:00+03:00.
  static String _localIso(DateTime time) {
    final local = time.toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    String two(int v) => v.toString().padLeft(2, '0');
    final base = local.toIso8601String().split('.').first;
    return '$base$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
  }
}

/// Minimal reader used by tests and tools: parses the lines, keeps unknown
/// types as raw maps and checks every `frame` through [FaceSignals.fromJson].
class RecordingReader {
  RecordingReader._(this.lines);
  final List<Map<String, dynamic>> lines;

  factory RecordingReader.parse(String text) {
    final lines = <Map<String, dynamic>>[];
    for (final raw in const LineSplitter().convert(text)) {
      if (raw.trim().isEmpty) continue;
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> || value['type'] is! String) {
        throw const FormatException('Строка записи не является объектом');
      }
      lines.add(value);
    }
    if (lines.isEmpty || lines.first['type'] != 'meta') {
      throw const FormatException('Запись должна начинаться со строки meta');
    }
    if (lines.first['schema'] != RecordingSchema.version) {
      throw FormatException('Неизвестная схема: ${lines.first['schema']}');
    }
    return RecordingReader._(lines);
  }

  Map<String, dynamic> get meta => lines.first;
  Iterable<Map<String, dynamic>> ofType(String type) =>
      lines.where((l) => l['type'] == type);

  /// Signals of every frame with a face, validated against the contract.
  Iterable<FaceSignals> signals({String? engine}) => ofType('frame')
      .where((l) => engine == null || l['engine'] == engine)
      .where((l) => l['signals'] != null)
      .map((l) => FaceSignals.fromJson(l['signals'] as Map<String, dynamic>));
}

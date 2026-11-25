import 'dart:async';
import 'dart:io';
import '../logic/domain.dart';

/// Appends JSONL lines (schema 1) to `nscontrol-<recordingId>.jsonl` in the
/// app documents. Numbers only: frames are never written (ФТ-01).
class LabRecorder {
  LabRecorder(this.directory);
  final Directory directory;
  IOSink? _sink;
  File? file;
  int lines = 0;
  bool get active => _sink != null;

  static String fileName(String recordingId) => 'nscontrol-$recordingId.jsonl';

  Future<File> start(String recordingId) async {
    await stop();
    await directory.create(recursive: true);
    final created = File('${directory.path}/${fileName(recordingId)}');
    _sink = created.openWrite();
    file = created;
    lines = 0;
    return created;
  }

  void write(Map<String, Object?> line) {
    final sink = _sink;
    if (sink == null) return;
    sink.writeln(RecordingSchema.encode(line));
    lines++;
  }

  Future<File?> stop() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return null;
    await sink.flush();
    await sink.close();
    return file;
  }

  /// Recordings in the folder, newest first.
  Future<List<File>> list() async {
    if (!await directory.exists()) return [];
    final files = await directory
        .list()
        .where((e) => e is File && e.path.endsWith('.jsonl'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}

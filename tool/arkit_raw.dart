import 'dart:io';

import 'package:nscontrol/logic/arkit_geometry.dart';
import 'package:nscontrol/logic/arkit_rederive.dart';

/// `dart run tool/arkit_raw.dart FILE.jsonl` — geometry report from the
/// ARKit `raw` field (phone tilt, face position, angles per sign hypothesis).
/// `dart run tool/arkit_raw.dart FILE.jsonl --mirror [--swap-eyes]
/// --out fixed.jsonl` — the same recording with ARKit signals recomputed.
Future<void> main(List<String> args) async {
  final files = args.where((a) => !a.startsWith('--')).toList();
  final outIndex = args.indexOf('--out');
  final out = outIndex >= 0 && outIndex + 1 < args.length
      ? args[outIndex + 1]
      : null;
  final input = files.where((f) => f != out).toList();
  if (input.length != 1) {
    stderr.writeln(
      'usage: dart run tool/arkit_raw.dart <file.jsonl> '
      '[--mirror] [--swap-eyes] [--out fixed.jsonl]',
    );
    exitCode = 64;
    return;
  }
  final recording = ArkitRawRecording(await File(input.single).readAsString());
  final mirror = args.contains('--mirror'), swap = args.contains('--swap-eyes');
  if (out == null && !mirror && !swap) {
    stdout.write(recording.diagnose());
    return;
  }
  final text = recording.rederive(ArkitAxes(mirror: mirror, swapEyes: swap));
  if (out == null) {
    stdout.write(text);
  } else {
    await File(out).writeAsString(text);
  }
}

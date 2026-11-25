import 'dart:io';

import 'package:nscontrol/logic/engine_compare.dart';

/// Compares the face engines of one JSONL recording (schema 1) by the four
/// criteria of the plan and prints a markdown report.
///
/// `dart run tool/engine_compare.dart FILE.jsonl [--out report.md]
/// [--mlkit-swap-eyes] [--arkit-swap-eyes]` — the swap flags exchange the
/// left and right eye of that engine before the comparison.
Future<void> main(List<String> args) async {
  String? file, out;
  final swap = <String>{};
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--out':
        if (i + 1 >= args.length) _fail('Не хватает значения для --out');
        out = args[++i];
      case '--mlkit-swap-eyes':
        swap.add('mlkit_face_detection');
      case '--arkit-swap-eyes':
        swap.add('arkit_face_tracking');
      case '-h' || '--help':
        stdout.writeln(
          'dart run tool/engine_compare.dart <file.jsonl> [--out report.md] '
          '[--mlkit-swap-eyes] [--arkit-swap-eyes]',
        );
        return;
      default:
        if (args[i].startsWith('-')) _fail('Неизвестный параметр ${args[i]}');
        file = args[i];
    }
  }
  if (file == null) _fail('Укажите файл записи .jsonl');
  final report = EngineComparison(
    await File(file).readAsString(),
    swapEyes: swap,
  ).report();
  if (out == null) {
    stdout.write(report);
  } else {
    await File(out).writeAsString(report);
    stderr.writeln('Отчёт: $out');
  }
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(64);
}

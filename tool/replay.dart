import 'dart:io';

import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/logic/synthetic.dart';

/// Replays a JSONL recording (schema 1) through the attention logic and the
/// ТЗ automata and prints a markdown report.
///
/// Usage: see [_usage] or run with `--help`.
const _usage = '''
Прогон записи:
  dart run tool/replay.dart <file.jsonl> [--engine <id>] [--mode both|acceptance|lab] [--recalibrate] [--out report.md]
Синтетическая запись:
  dart run tool/replay.dart --synthetic arkit|mlkit|arkit-mlkit --write <file.jsonl>
''';

Future<void> main(List<String> args) async {
  String? file, engine, out, synthetic, write;
  var mode = 'both';
  var recalibrate = false;
  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) _fail('Не хватает значения для ${args[i]}');
      return args[++i];
    }

    switch (args[i]) {
      case '--engine':
        engine = next();
      case '--mode':
        mode = next();
      case '--out':
        out = next();
      case '--recalibrate':
        recalibrate = true;
      case '--synthetic':
        synthetic = next();
      case '--write':
        write = next();
      case '-h' || '--help':
        stdout.write(_usage);
        return;
      default:
        if (args[i].startsWith('-')) _fail('Неизвестный параметр ${args[i]}');
        file = args[i];
    }
  }
  if (synthetic != null) {
    final style = switch (synthetic) {
      'arkit' => SyntheticStyle.arkit,
      'mlkit' => SyntheticStyle.mlKit,
      'arkit-mlkit' => SyntheticStyle.arkitMlKit,
      _ => _fail('--synthetic принимает arkit, mlkit или arkit-mlkit'),
    };
    final text = SyntheticScenario(style).toJsonl();
    if (write == null) {
      stdout.write(text);
    } else {
      await File(write).writeAsString(text);
      stderr.writeln('Записано: $write');
    }
    return;
  }
  if (file == null) _fail(_usage);
  final recording = Recording.parse(await File(file).readAsString());
  final engines = engine == null ? recording.engines : [engine];
  final modes = switch (mode) {
    'acceptance' => [const AttentionSettings.acceptance()],
    'lab' => [AttentionSettings.lab],
    'both' => [const AttentionSettings.acceptance(), AttentionSettings.lab],
    _ => _fail('--mode принимает both, acceptance или lab'),
  };
  final runner = ReplayRunner(recording);
  final results = <ReplayResult>[];
  final errors = <String>[];
  for (final e in engines) {
    for (final m in modes) {
      try {
        results.add(
          runner.run(
            ReplayOptions(engine: e, attention: m, recalibrate: recalibrate),
          ),
        );
      } catch (error) {
        // One engine that cannot be replayed must not hide the others.
        errors.add(
          '- $e, ${m.isAcceptance ? 'приёмка' : 'расширения'}: $error',
        );
        stderr.writeln('$e: $error');
      }
    }
  }
  if (results.isEmpty) _fail('Ни один движок не удалось прогнать.');
  var report = replayReport(recording, results);
  if (errors.isNotEmpty) {
    report += '\n## Не прогнано\n\n${errors.join('\n')}\n';
  }
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

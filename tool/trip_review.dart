import 'dart:convert';
import 'dart:io';

import 'package:nscontrol/logic/trip_review.dart';

/// Turns a reviewed trip into labelled data for the replay and the tuning,
/// and reports the review (docs/trip-debug.md).
///
/// Usage: see [_usage] or run with `--help`.
const _usage = '''
Разбор поездки:
  dart run tool/trip_review.dart <nscontrol-trip-….jsonl> [--review nscontrol-trip-….review.json] [--out размеченная.jsonl] [--report отчёт.md]
Без --review берётся файл разбора рядом с записью. Размеченную запись можно
прогнать: dart run tool/replay.dart размеченная.jsonl --profile v1
и подобрать пороги: dart run tool/tune.dart размеченная.jsonl … --out tune.md
''';

Future<void> main(List<String> args) async {
  String? file, reviewPath, out, reportPath;
  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) _fail('Не хватает значения для ${args[i]}');
      return args[++i];
    }

    switch (args[i]) {
      case '--review':
        reviewPath = next();
      case '--out':
        out = next();
      case '--report':
        reportPath = next();
      case '-h' || '--help':
        stdout.write(_usage);
        return;
      default:
        if (args[i].startsWith('-')) _fail('Неизвестный параметр ${args[i]}');
        file = args[i];
    }
  }
  if (file == null) _fail(_usage);
  final text = await File(file).readAsString();
  reviewPath ??= file.replaceFirst(RegExp(r'\.jsonl$'), '.review.json');
  if (!await File(reviewPath).exists()) {
    _fail(
      'Нет файла разбора $reviewPath. Разберите поездку на странице /review.',
    );
  }
  final review = TripReview.parse(await File(reviewPath).readAsString());
  final report = tripReviewReport(text, review);
  if (reportPath != null) {
    await File(reportPath).writeAsString(report);
  } else {
    stdout.write(report);
  }
  if (out != null) {
    await File(out).writeAsString(labelTrip(text, review));
    stderr.writeln('Размеченная запись: $out');
  }
}

/// Markdown report: alarms by verdict and cause, false alarms per hour,
/// misses, and each item with what the automata saw at that moment.
String tripReviewReport(String jsonl, TripReview review) {
  Map<String, dynamic> meta = const {};
  int? firstCal, last;
  final derived = <Map<String, dynamic>>[];
  for (final raw in const LineSplitter().convert(jsonl)) {
    if (raw.trim().isEmpty) continue;
    Map<String, dynamic> line;
    try {
      line = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final t = (line['atUs'] ?? line['capturedUs']) as num?;
    if (t != null && (last == null || t > last)) last = t.toInt();
    switch (line['type']) {
      case 'meta':
        meta = line;
      case 'calibration':
        firstCal ??= (line['atUs'] as num).toInt();
      case 'derived':
        derived.add(line);
    }
  }
  final observedUs = firstCal == null || last == null ? 0 : last - firstCal;
  final hours = observedUs / 3.6e9;
  final b = StringBuffer()
    ..writeln('# Разбор поездки ${review.recordingId}')
    ..writeln()
    ..writeln(
      '- Профиль ${(meta['detectionProfile'] as Map?)?['id'] ?? review.profile ?? '—'}, '
      'движок ${meta['tripEngine'] ?? (meta['engines'] as List?)?.join(', ') ?? '—'}, '
      'крепление ${(meta['mount'] as Map?)?['position'] ?? '—'}.',
    )
    ..writeln(
      '- Наблюдение ${(observedUs / 6e7).toStringAsFixed(1)} мин от первой калибровки.',
    );
  final events = review.items.where((i) => i.isEvent).toList();
  final marks = review.items.where((i) => !i.isEvent).toList();
  int count(String? type, String? verdict) => events
      .where(
        (e) => (type == null || e.eventType == type) && e.verdict == verdict,
      )
      .length;
  b
    ..writeln()
    ..writeln('| Тревога | всего | верных | ложных | спорных | не разобрано |')
    ..writeln('|---|---:|---:|---:|---:|---:|');
  for (final type in {for (final e in events) e.eventType}) {
    b.writeln(
      '| $type | ${events.where((e) => e.eventType == type).length} | '
      '${count(type, 'true')} | ${count(type, 'false')} | '
      '${count(type, 'unsure')} | ${count(type, null)} |',
    );
  }
  final tzFalse = events
      .where((e) => e.verdict == 'false' && e.eventType != 'distraction')
      .length;
  b
    ..writeln()
    ..writeln(
      '- Ложных тревог глаз и головы: $tzFalse'
      '${hours > 0 ? ', ${(tzFalse / hours).toStringAsFixed(1)} в час (КЧ-03: не больше 1 в час)' : ''}.',
    )
    ..writeln(
      '- Пропусков по меткам: глаза '
      '${marks.where((m) => m.verdict == 'miss_eyes').length}, голова '
      '${marks.where((m) => m.verdict == 'miss_head').length}; меток без '
      'проблемы ${marks.where((m) => m.verdict == 'no_issue').length}, не '
      'разобрано ${marks.where((m) => m.verdict == null).length}.',
    );
  final causes = <String, int>{};
  for (final e in events.where((e) => e.verdict == 'false')) {
    causes.update(e.cause ?? '—', (n) => n + 1, ifAbsent: () => 1);
  }
  if (causes.isNotEmpty) {
    b.writeln(
      '- Причины ложных: ${(causes.entries.toList()..sort((a, c) => c.value.compareTo(a.value))).map((e) => '${e.key} ${e.value}').join(', ')}.',
    );
  }
  b
    ..writeln()
    ..writeln('## По порядку')
    ..writeln()
    ..writeln(
      '| Время | Что | Вердикт | Причина | Зона | Наклон/поворот, ° | Глаза Л/П, T | Затвор | Заметка |',
    )
    ..writeln('|---|---|---|---|---|---|---|---|---|');
  Map<String, dynamic>? near(int t) {
    Map<String, dynamic>? best;
    var diff = 300000;
    for (final d in derived) {
      final dt = ((d['atUs'] as num).toInt() - t).abs();
      if (dt < diff) {
        diff = dt;
        best = d;
      }
    }
    return best;
  }

  String n(Object? v, [int digits = 1]) =>
      v is num ? v.toStringAsFixed(digits) : '—';
  for (final item in review.items) {
    final d = near(item.atUs);
    final m = (d?['measure'] as Map?) ?? const {};
    final gate = (d?['attention'] as Map?)?['eyeGate'];
    b.writeln(
      '| ${_t(item.atUs)} | ${item.isEvent ? item.eventType : 'метка ${item.mark}'} | '
      '${item.verdict ?? 'не разобрано'} | ${item.cause ?? ''} | ${d?['zone'] ?? '—'} | '
      '${n(m['pitchDown'])}/${n(m['yaw'])} | ${n(m['eyeLeft'], 2)}/${n(m['eyeRight'], 2)}, ${n(m['eyeThreshold'], 2)} | '
      '${gate ?? '—'} | ${(item.note ?? '').replaceAll('|', '/').replaceAll('\n', ' ')} |',
    );
  }
  return b.toString();
}

String _t(int us) {
  final s = us / 1e6;
  return '${s ~/ 60}:${(s % 60).toStringAsFixed(1).padLeft(4, '0')}';
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(64);
}

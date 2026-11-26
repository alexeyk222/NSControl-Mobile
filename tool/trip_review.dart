import 'dart:convert';
import 'dart:io';

import 'package:nscontrol/logic/trip_review.dart';

/// Turns a reviewed trip into labelled data for the replay and the tuning,
/// and reports the review (docs/trip-debug.md).
///
/// Usage: see [_usage] or run with `--help`.
const _usage = '''
Разбор поездки:
  dart run tool/trip_review.dart <nscontrol-trip-….jsonl> [--review nscontrol-trip-….review.json] [--out размеченная.jsonl] [--report отчёт.md] [--score-gaps]
Без --review берётся файл разбора рядом с записью; если его нет, берутся
только случаи со страницы («Новый случай»), и время между ними не
оценивается (испытатель в это время смотрит в клавиатуру). --score-gaps
считает его ездой без тревог; с файлом разбора берётся выбор, сделанный на
странице разбора. Размеченную запись можно
прогнать: dart run tool/replay.dart размеченная.jsonl --profile v1
и подобрать пороги: dart run tool/tune.dart размеченная.jsonl … --out tune.md
''';

Future<void> main(List<String> args) async {
  String? file, reviewPath, out, reportPath;
  bool? scoreGaps;
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
      case '--score-gaps':
        scoreGaps = true;
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
  final TripReview review;
  if (await File(reviewPath).exists()) {
    review = TripReview.parse(await File(reviewPath).readAsString());
    scoreGaps ??= review.scoreGaps ?? true;
  } else {
    scoreGaps ??= false;
    stderr.writeln('Нет файла разбора $reviewPath: беру только случаи.');
    review = TripReview(recordingId: '', items: const []);
  }
  final report = tripReviewReport(text, review);
  if (reportPath != null) {
    await File(reportPath).writeAsString(report);
  } else {
    stdout.write(report);
  }
  if (out != null) {
    await File(
      out,
    ).writeAsString(labelTrip(text, review, scoreGaps: scoreGaps));
    stderr.writeln('Размеченная запись: $out');
  }
}

/// Markdown report: alarms by verdict and cause, false alarms per hour,
/// misses, and each item with what the automata saw at that moment.
String tripReviewReport(String jsonl, TripReview review) {
  Map<String, dynamic> meta = const {};
  int? firstCal, last;
  final derived = <Map<String, dynamic>>[];
  final caseLines = <Map<String, dynamic>>[];
  final alarms = <(int, String)>[];
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
      case 'mark' when line['kind'] == 'case':
        caseLines.add(line);
      case 'event' when line['change'] == 'started':
        final e = line['event'] as Map;
        alarms.add((
          (e['thresholdUs'] as num).toInt() +
              ((line['sessionOffsetUs'] as num?)?.toInt() ?? 0),
          e['type'] as String,
        ));
    }
  }
  final observedUs = firstCal == null || last == null ? 0 : last - firstCal;
  final hours = observedUs / 3.6e9;
  final b = StringBuffer()
    ..writeln(
      '# Разбор поездки ${review.recordingId.isEmpty ? meta['recordingId'] ?? '' : review.recordingId}',
    )
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
  final marks = review.items.where((i) => !i.isEvent && !i.isCase).toList();
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
      '- Ложных тревог глаз и головы вне случаев: $tzFalse'
      '${review.scoreGaps == false
          ? '; в час не считаются: время вне случаев не оценивается (стенд)'
          : hours > 0
          ? ', ${(tzFalse / hours).toStringAsFixed(1)} в час (КЧ-03: не больше 1 в час)'
          : ''}.',
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
  final cases = tripCases(caseLines, review: review);
  if (cases.isNotEmpty) {
    const names = {
      'ok': 'верно',
      'false_alarm': 'ложная',
      'missed': 'пропуск',
      'other_type': 'другой тип',
      'too_short': 'короче 3 с, не в счёт',
      'unsure': 'без ответа',
    };
    final outcomes = [for (final c in cases) caseOutcome(c, alarms)];
    b
      ..writeln()
      ..writeln('## Случаи со страницы')
      ..writeln()
      ..writeln(
        '- ${cases.length} случаев: ${names.entries.map((e) => '${e.value} ${outcomes.where((o) => o == e.key).length}').join(', ')}.',
      )
      ..writeln()
      ..writeln('| Что было | всего | верно | ложных | пропусков | не в счёт |')
      ..writeln('|---|---:|---:|---:|---:|---:|');
    for (final truth in caseTruths.keys) {
      final of = [
        for (var i = 0; i < cases.length; i++)
          if (cases[i].truth == truth) outcomes[i],
      ];
      if (of.isEmpty) continue;
      int count(Set<String> which) => of.where(which.contains).length;
      b.writeln(
        '| $truth | ${of.length} | ${count({'ok'})} | '
        '${count({'false_alarm'})} | ${count({'missed'})} | '
        '${count({'other_type', 'too_short', 'unsure'})} |',
      );
    }
    b
      ..writeln()
      ..writeln(
        '| Время | Длит., с | Что было | Ждали | Тревоги | Итог | Наклон макс, ° | Поворот макс, ° | Глаза мин |',
      )
      ..writeln('|---|---:|---|---|---|---|---:|---:|---:|');
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final inside = derived.where((d) {
        final t = (d['atUs'] as num).toInt();
        // The pose itself: the tail after the end is not the pose.
        return t >= c.startUs && t <= (c.endUs ?? c.startUs);
      });
      double? pitch, yaw, eyes;
      for (final d in inside) {
        final m = (d['measure'] as Map?) ?? const {};
        final p = (m['pitchDown'] as num?)?.toDouble();
        final y = (m['yaw'] as num?)?.toDouble().abs();
        final l = (m['eyeLeft'] as num?)?.toDouble();
        final r = (m['eyeRight'] as num?)?.toDouble();
        if (p != null && (pitch == null || p > pitch)) pitch = p;
        if (y != null && (yaw == null || y > yaw)) yaw = y;
        if (l != null && r != null) {
          final e = l > r ? l : r;
          if (eyes == null || e < eyes) eyes = e;
        }
      }
      final got = [
        for (final (at, type) in alarms)
          if (at >= c.startUs && at <= c.toUs) type,
      ];
      b.writeln(
        '| ${_t(c.startUs)} | ${c.endUs == null ? '—' : ((c.endUs! - c.startUs) / 1e6).toStringAsFixed(1)} | '
        '${c.truth ?? '—'} | ${c.expect ?? '—'} | ${got.isEmpty ? '—' : got.join(', ')} | '
        '${names[outcomes[i]]} | ${n(pitch)} | ${n(yaw)} | ${n(eyes, 2)} |',
      );
    }
  }
  if (review.items.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## По порядку')
      ..writeln()
      ..writeln(
        '| Время | Что | Вердикт | Причина | Зона | Наклон/поворот, ° | Глаза Л/П, T | Затвор | Заметка |',
      )
      ..writeln('|---|---|---|---|---|---|---|---|---|');
  }
  for (final item in review.items.where((i) => !i.isCase)) {
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

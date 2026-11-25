import 'dart:io';

import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/detection_profile.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/logic/tune.dart';

import 'replay.dart' show readRecording;

const _usage = '''
Подбор порогов профиля по размеченным записям.

  dart run tool/tune.dart <file.jsonl[.gz]>... [--engine <id>] [--out tune.md]

Для каждого движка перебирает наклон и длительность головы, порог T и
длительность глаз, допуск разрыва кадров, затвор зевка и подстройку позы
«дорога»; считает полноту, ложные тревоги на отрицательных шагах и задержку;
выбирает набор с наибольшим запасом до границы целей КЧ.
''';

/// Eye view limits measured by the ARKit thread (25.11.2026): ARKit both
/// eyes reliable to at least 55° (50° taken), ML Kit to 10°.
const _eyeYawLimits = {
  'arkit_face_tracking': 50.0,
  'mlkit_face_detection': 10.0,
};

/// Base of every sweep: the attention settings of the working profile
/// (eye gate, side mount, continuity; distraction off in v1).
const _base = DetectionProfile(
  id: 'tune',
  eyeYawLimits: _eyeYawLimits,
  attention: AttentionSettings(gazeAwareEyes: true, mountRelative: true),
);

const _adapt = [null, 1.0];
const _gaps = [300000, 600000];
const _pitches = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22];
const _headDurations = [1000000, 1500000, 2000000, 2500000, 3000000];
const _yawn = [null, .3, .4, .5];
const _thresholds = [.15, .2, .25, .3, .35, .4];
const _eyeDurations = [
  1200000,
  1300000,
  1400000,
  1500000,
  1600000,
  1700000,
  1800000,
  1900000,
  2000000,
];

AttentionSettings _attention({double? yawn, double? adapt}) =>
    AttentionSettings(
      gazeAwareEyes: true,
      mountRelative: true,
      yawnJaw: yawn,
      roadAdaptDegPerMin: adapt,
    );

Future<void> main(List<String> args) async {
  final files = <String>[];
  String? engine, out;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--engine':
        engine = args[++i];
      case '--out':
        out = args[++i];
      case '-h' || '--help':
        stdout.write(_usage);
        return;
      default:
        files.add(args[i]);
    }
  }
  if (files.isEmpty) {
    stderr.write(_usage);
    exit(64);
  }
  final recordings = [
    for (final f in files) Recording.parse(await readRecording(f)),
  ];
  final engines = <String>{
    for (final r in recordings) ...r.engines,
  }.where((e) => engine == null || e == engine).toList();
  final b = StringBuffer('# Подбор порогов профиля\n\n');
  final heads = <String, TuneSweep>{};
  final subjects = {for (final r in recordings) '${r.meta['subject'] ?? '?'}'};
  b.writeln(
    '- Записей ${recordings.length} '
    '(${recordings.map((r) => r.id).join(', ')}), людей ${subjects.length}. '
    '${subjects.length < 3 ? '**Выборка мала: профиль предварительный.**' : ''}',
  );
  b.writeln(
    '- Цели КЧ: полнота eyes_closed ≥ 90 %, head_pitch_down ≥ 85 %, '
    'не больше 1 ложной тревоги в час. На записи короче часа одна ложная '
    'тревога уже больше 1 в час, поэтому набор годен только без ложных.',
  );
  b.writeln(
    '- Запас: на сколько шагов сетки набор отстоит от ближайшего, который '
    'не проходит цели, или от края сетки. Выбирается наибольший запас, при '
    'равенстве — больший простор вдоль каждой оси по отдельности (середина '
    'годной области), затем ближайший к ТЗ 2.2. Подстройка позы «дорога» '
    'входит в профиль. Механизм сверх этого (затвор зевка, длинный допуск '
    'разрыва) берётся, только если без него запас меньше 2 шагов.',
  );
  b.writeln(
    '- Предел вида глаз по замеру: '
    '${_eyeYawLimits.entries.map((e) => '${e.key} ${e.value.round()}°').join(', ')}.',
  );
  for (final e in engines) {
    final samples = [
      for (final r in recordings)
        if (r.engines.contains(e)) TuneSample(r, e),
    ];
    stderr.writeln('$e: ${samples.length} записей');
    b.writeln('\n## $e\n');
    final reference = evaluate(DetectionProfile.tz22, samples);
    for (final f in {...reference.failures}) {
      b.writeln('- ТЗ 2.2 (эталон) не прогнан: $f');
    }
    final head = sweep(
      type: ScenarioExpectations.headPitchDown,
      axes: ['подстройка', 'разрыв', 'наклон', 'длительность'],
      values: [_adapt, _gaps, _pitches, _headDurations],
      // Road adaptation is part of the profile: the reference variant.
      reference: [1.0, 300000, 20, 2000000],
      categorical: {0, 1},
      apply: (v) => _base.copyWith(
        attention: _attention(adapt: v[0] as double?),
        maximumGapUs: v[1]! as int,
        pitchThreshold: (v[2]! as int).toDouble(),
        headDownUs: v[3]! as int,
      ),
      samples: samples,
    );
    final headBest = head.best;
    final hasEyes =
        (reference.expected[ScenarioExpectations.eyesClosed] ?? 0) > 0;
    TuneSweep? eyes;
    var natural = <double, int>{};
    if (hasEyes) {
      // The eye duration stays at least 0.25 s above the longest natural
      // closure at that T, outside the steps where the eyes may close.
      natural = {
        for (final t in _thresholds)
          t: samples
              .map((s) => longestNaturalClosureUs(s, t))
              .fold(0, (a, b) => a > b ? a : b),
      };
      eyes = sweep(
        type: ScenarioExpectations.eyesClosed,
        axes: ['зевок', 'разрыв', 'T', 'длительность'],
        values: [_yawn, _gaps, _thresholds, _eyeDurations],
        reference: [null, 300000, .4, 1500000],
        categorical: {0, 1},
        extra: (p) =>
            p.metrics.profile.eyesClosedUs >=
            natural[p.metrics.profile.eyeThresholds.values.first]! + 250000,
        apply: (v) => _base.copyWith(
          attention: _attention(yawn: v[0] as double?),
          maximumGapUs: v[1]! as int,
          eyeThresholds: {e: v[2]! as double},
          eyesClosedUs: v[3]! as int,
        ),
        samples: samples,
      );
    }
    final headProfile = headBest?.metrics.profile;
    final eyesProfile = eyes?.best?.metrics.profile;
    final chosen = _base.copyWith(
      pitchThreshold: headProfile?.pitchThreshold,
      headDownUs: headProfile?.headDownUs,
      eyeThresholds: eyesProfile?.eyeThresholds,
      eyesClosedUs: eyesProfile?.eyesClosedUs,
      // One gap tolerance for both automata: the longer one asked for.
      maximumGapUs: [
        headProfile?.maximumGapUs ?? 300000,
        eyesProfile?.maximumGapUs ?? 300000,
      ].reduce((a, b) => a > b ? a : b),
      attention: _attention(
        yawn: eyesProfile?.attention.yawnJaw,
        adapt: headProfile?.attention.roadAdaptDegPerMin,
      ),
    );
    final chosenMetrics = evaluate(chosen, samples);
    heads[e] = head;
    b.writeln(_episodes(chosenMetrics));
    b.writeln();
    b.writeln('| Профиль | ${_header()} |');
    b.writeln('|---|---|---|---|---|---|');
    b.writeln('| ТЗ 2.2 (эталон) | ${_row(reference)} |');
    b.writeln('| Выбранный набор | ${_row(chosenMetrics)} |');
    b.writeln();
    b.writeln('Выбранный набор: ${chosen.summary}.');
    b.writeln('\n### Голова');
    _slices(
      b,
      head,
      title: (p) {
        final a = p.metrics.profile.attention.roadAdaptDegPerMin;
        return '${a == null ? 'без подстройки позы' : 'подстройка позы $a°/мин'}, '
            'разрыв до ${p.metrics.profile.maximumGapUs ~/ 1000} мс';
      },
      row: (p) => '${p.metrics.profile.pitchThreshold.round()}°',
      column: (p) =>
          '${(p.metrics.profile.headDownUs / 1e6).toStringAsFixed(1)} с',
    );
    b.writeln(_bestLine(head));
    if (eyes != null) {
      b.writeln('\n### Глаза');
      _slices(
        b,
        eyes,
        title: (p) {
          final y = p.metrics.profile.attention.yawnJaw;
          return '${y == null ? 'только T' : 'T и затвор зевка jawOpen ≥ $y'}, '
              'разрыв до ${p.metrics.profile.maximumGapUs ~/ 1000} мс';
        },
        row: (p) => 'T ${p.metrics.profile.eyeThresholds.values.first}',
        column: (p) =>
            '${(p.metrics.profile.eyesClosedUs / 1e6).toStringAsFixed(1)} с',
      );
      b.writeln(_bestLine(eyes));
      b.writeln(
        '\n### Самое долгое закрытие вне шагов закрытия, зевка, смеха и '
        'прищура\n',
      );
      b.writeln('| T | Длительность, с |');
      b.writeln('|---|---|');
      for (final t in _thresholds) {
        b.writeln('| $t | ${(natural[t]! / 1e6).toStringAsFixed(2)} |');
      }
    }
    for (final (name, m) in [
      ('выбранного набора', chosenMetrics),
      ('ТЗ 2.2 (эталон)', reference),
    ]) {
      if (m.falseAlarms.isEmpty) continue;
      b.writeln('\nЛожные тревоги $name:');
      for (final f in m.falseAlarms) {
        b.writeln('- $f');
      }
    }
  }
  if (heads.length > 1) _jointHead(b, heads);
  if (out == null) {
    stdout.write(b);
  } else {
    await File(out).writeAsString(b.toString());
    stderr.writeln('Отчёт: $out');
  }
}

/// One table per combination of the categorical axes.
void _slices(
  StringBuffer b,
  TuneSweep s, {
  required String Function(TunePoint) title,
  required String Function(TunePoint) row,
  required String Function(TunePoint) column,
}) {
  final best = s.best;
  final titles = <String>[];
  for (final p in s.points) {
    if (!titles.contains(title(p))) titles.add(title(p));
  }
  for (final t in titles) {
    b.writeln('\n#### $t\n');
    final points = s.points.where((p) => title(p) == t).toList();
    final rows = <String>[], columns = <String>[];
    for (final p in points) {
      if (!rows.contains(row(p))) rows.add(row(p));
      if (!columns.contains(column(p))) columns.add(column(p));
    }
    b.writeln('| | ${columns.join(' | ')} |');
    b.writeln('|---|${columns.map((_) => '---').join('|')}|');
    for (final r in rows) {
      final cells = [
        for (final c in columns)
          () {
            final p = points.firstWhere((p) => row(p) == r && column(p) == c);
            final v = p.metrics.recall(s.type);
            final fp = p.metrics.falseAlarms
                .where((f) => f.endsWith(':${s.type}'))
                .length;
            final mark = identical(p, best)
                ? ' ★'
                : p.feasible
                ? ' ✓${p.margin}'
                : '';
            return '${v == null ? '—' : '${(v * 100).round()} %'}'
                '${fp > 0 ? ', ложн. $fp' : ''}$mark';
          }(),
      ];
      b.writeln('| $r | ${cells.join(' | ')} |');
    }
  }
  b.writeln(
    '\n✓N — проходит цели, запас N шагов; ★ — выбранный; '
    'проценты — полнота ${s.type}.',
  );
}

String _episodes(TuneMetrics m) =>
    '- Эпизодов: ${tuneTypes.map((t) => '$t ${m.expected[t] ?? 0}'
        '${(m.borderline[t] ?? 0) > 0 ? ' (+${m.borderline[t]} пограничных, не в счёт)' : ''}').join(', ')}; '
    'наблюдение ${(m.observedUs / 6e7).toStringAsFixed(1)} мин.';

String _header() =>
    'Полнота eyes_closed | Полнота head_pitch_down | Ложных ТЗ | '
    'Ложных в час | Медианная задержка от метки, с (глаза / голова)';

String _row(TuneMetrics m) {
  String r(String t) {
    final v = m.recall(t);
    return v == null
        ? '—'
        : '${(v * 100).round()} % (${m.found[t] ?? 0}/${m.expected[t]})';
  }

  String d(String t) {
    final v = m.medianDelayUs(t);
    return v == null ? '—' : (v / 1e6).toStringAsFixed(1);
  }

  return '${r(ScenarioExpectations.eyesClosed)} | '
      '${r(ScenarioExpectations.headPitchDown)} | ${m.falseAlarms.length} | '
      '${m.falsePerHour.toStringAsFixed(1)} | '
      '${d(ScenarioExpectations.eyesClosed)} / ${d(ScenarioExpectations.headPitchDown)}';
}

String _bestLine(TuneSweep s) {
  final best = s.best;
  return best == null
      ? '\n**Ни один набор не проходит цели.**'
      : '\nВыбран: ${best.metrics.profile.summary}; запас ${best.margin} '
            'шаг(а) сетки.';
}

/// The profile has one head threshold for every engine: the point feasible
/// for all of them, with the margin counted over the joint feasible region.
void _jointHead(StringBuffer b, Map<String, TuneSweep> heads) {
  String key(TunePoint p) => p.coordinates.join(',');
  final feasible = {
    for (final e in heads.entries)
      e.key: {
        for (final p in e.value.points)
          if (p.feasible) key(p),
      },
  };
  final first = heads.values.first;
  final joint = first.where((_) => true);
  final all = TuneSweep(
    type: joint.type,
    axes: joint.axes,
    points: joint.points,
    targets: joint.targets,
    sizes: joint.sizes,
    reference: joint.reference,
    categorical: joint.categorical,
    extra: (p) => feasible.values.every((f) => f.contains(key(p))),
  );
  b.writeln('\n## Общий порог головы (${heads.keys.join(', ')})\n');
  b.writeln(
    'Порог наклона и длительность в профиле одни для всех движков. Набор '
    'годен, если проходит цели на каждом движке; запас считается по общей '
    'годной области.',
  );
  final best = all.best;
  if (best == null) {
    b.writeln('\nОбщего годного набора нет.');
    return;
  }
  b.writeln(
    '\nВыбран: ${best.metrics.profile.summary}; запас ${best.margin} '
    'шаг(а) сетки.',
  );
  final rows = <int, List<String>>{};
  for (final p in all.points.where(all.atReferenceCategory)) {
    rows
        .putIfAbsent(p.coordinates[2], () => [])
        .add(p.feasible ? (identical(p, best) ? '★' : '✓${p.margin}') : '—');
  }
  b.writeln(
    '\nСрез профиля (подстройка позы, разрыв 300 мс), годность на всех '
    'движках:\n',
  );
  final columns = [
    for (final p in all.points)
      if (all.atReferenceCategory(p) && p.coordinates[2] == 0)
        '${(p.metrics.profile.headDownUs / 1e6).toStringAsFixed(1)} с',
  ];
  b.writeln('| | ${columns.join(' | ')} |');
  b.writeln('|---|${List.filled(columns.length, '---').join('|')}|');
  final pitches = {
    for (final p in all.points)
      p.coordinates[2]: p.metrics.profile.pitchThreshold.round(),
  };
  for (final r in rows.entries) {
    b.writeln('| ${pitches[r.key]}° | ${r.value.join(' | ')} |');
  }
}

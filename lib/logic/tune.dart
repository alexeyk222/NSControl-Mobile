import 'dart:math' as math;

import 'detection_profile.dart';
import 'replay.dart';

/// One labelled recording replayed for one engine.
class TuneSample {
  const TuneSample(this.recording, this.engine);
  final Recording recording;
  final String engine;

  String get subject => '${recording.meta['subject'] ?? '?'}';
}

/// Quality of one profile over all samples.
class TuneMetrics {
  TuneMetrics(this.profile);
  final DetectionProfile profile;

  /// Expected episodes by type (borderline misses left out, as in replay),
  /// and how many of them were found (in tolerance or later in the step).
  final Map<String, int> expected = {}, found = {};

  /// Borderline misses (eyes_closed_2s), not counted in [expected].
  final Map<String, int> borderline = {};

  /// ТЗ-type events where none was expected: step and type.
  final List<String> falseAlarms = [];

  /// Delay from the label to the event threshold, µs, by type.
  final Map<String, List<int>> delays = {};
  int observedUs = 0;

  /// Recordings that could not be replayed with this profile (calibration).
  final List<String> failures = [];

  double? recall(String type) {
    final n = expected[type] ?? 0;
    return n == 0 ? null : (found[type] ?? 0) / n;
  }

  double get hours => observedUs / 3.6e9;
  double get falsePerHour => hours == 0 ? 0 : falseAlarms.length / hours;

  int? medianDelayUs(String type) {
    final d = [...?delays[type]]..sort();
    return d.isEmpty ? null : d[d.length ~/ 2];
  }
}

/// Quality targets (КЧ) a profile must meet.
class TuneTargets {
  const TuneTargets({
    this.eyesRecall = .9,
    this.headRecall = .85,
    this.falsePerHour = 1,
  });
  final double eyesRecall, headRecall, falsePerHour;

  /// On a short recording even one false alarm is several per hour, so the
  /// sample check is "none at all"; the per-hour figure is reported apart.
  bool meets(TuneMetrics m, {required String type}) {
    final r = m.recall(type);
    final target = type == ScenarioExpectations.eyesClosed
        ? eyesRecall
        : headRecall;
    return r != null &&
        r >= target &&
        !m.falseAlarms.any((f) => f.endsWith(':$type'));
  }
}

/// The ТЗ alarms that the targets are about.
const tuneTypes = [
  ScenarioExpectations.eyesClosed,
  ScenarioExpectations.headPitchDown,
];

TuneMetrics evaluate(DetectionProfile profile, List<TuneSample> samples) {
  final m = TuneMetrics(profile);
  for (final s in samples) {
    final ReplayResult r;
    try {
      r = ReplayRunner(
        s.recording,
      ).run(ReplayOptions(engine: s.engine, profile: profile));
    } on StateError catch (error) {
      // The ТЗ calibration refuses a side view: reported, not counted.
      m.failures.add('${s.recording.id}: ${error.message}');
      continue;
    }
    m.observedUs += r.observedUs;
    for (final e in r.episodes) {
      if (e.episode.aborted) continue;
      for (final type in tuneTypes) {
        if (e.expected.contains(type)) {
          final hit = [
            ...e.matched.where((x) => x.type == type),
            ...e.late.where((x) => x.type == type),
          ];
          if (hit.isEmpty && e.borderline) {
            m.borderline.update(type, (n) => n + 1, ifAbsent: () => 1);
            continue;
          }
          m.expected.update(type, (n) => n + 1, ifAbsent: () => 1);
          if (hit.isNotEmpty) {
            m.found.update(type, (n) => n + 1, ifAbsent: () => 1);
            (m.delays[type] ??= []).add(
              hit.first.thresholdUs - e.episode.startUs,
            );
          }
        }
        for (final x in [...e.unexpected, ...e.duplicates]) {
          if (x.type == type) {
            m.falseAlarms.add(
              '${s.recording.id} ${e.episode.step} #${e.episode.rep}:$type',
            );
          }
        }
      }
    }
    for (final x in r.outsideSteps) {
      if (tuneTypes.contains(x.type)) {
        m.falseAlarms.add(
          '${s.recording.id} вне шагов ${(x.thresholdUs / 1e6).toStringAsFixed(1)} с:${x.type}',
        );
      }
    }
  }
  return m;
}

/// A grid point: the profile and its coordinates (grid step indices).
class TunePoint {
  TunePoint(this.coordinates, this.metrics);
  final List<int> coordinates;
  final TuneMetrics metrics;
  bool feasible = false;

  /// Grid steps to the nearest point that misses a target (Chebyshev
  /// distance); the larger, the more room on every side.
  int margin = 0;

  /// Room along each numeric axis taken alone (steps to an infeasible point
  /// or past the edge, the nearer side), summed: breaks ties of [margin]
  /// toward the middle of the feasible region.
  int room = 0;
}

/// A sweep of one alarm type over a grid of profiles.
///
/// A point is feasible when it meets the targets (and [extra], if given).
/// Its margin is the number of grid steps to the nearest infeasible point or
/// past the edge of the grid, whichever is closer: an edge is untested
/// ground, not room. The chosen point has the largest margin; on a tie, the
/// most [TunePoint.room] along the axes taken one by one; then the one
/// closer to [reference] (grid coordinates of ТЗ 2.2), so the profile moves
/// away from the ТЗ only as far as the data asks.
class TuneSweep {
  TuneSweep({
    required this.type,
    required this.axes,
    required this.points,
    required this.targets,
    required this.sizes,
    required this.reference,
    this.categorical = const {},
    this.extra,
  }) {
    for (final p in points) {
      p.feasible =
          targets.meets(p.metrics, type: type) && (extra?.call(p) ?? true);
    }
    final infeasible = points.where((p) => !p.feasible).toList();
    for (final p in points.where((p) => p.feasible)) {
      var best = 1 << 30;
      for (var i = 0; i < sizes.length; i++) {
        if (sizes[i] < 2 || categorical.contains(i)) continue;
        final c = p.coordinates[i];
        best = math.min(best, math.min(c, sizes[i] - 1 - c) + 1);
      }
      for (final q in infeasible) {
        if (!_sameCategory(p, q)) continue;
        var d = 0;
        for (var i = 0; i < p.coordinates.length; i++) {
          if (categorical.contains(i)) continue;
          d = math.max(d, (p.coordinates[i] - q.coordinates[i]).abs());
        }
        best = math.min(best, d);
      }
      p.margin = best;
    }
    final byKey = {for (final p in points) p.coordinates.join(','): p};
    for (final p in points.where((p) => p.feasible)) {
      var room = 0;
      for (var i = 0; i < sizes.length; i++) {
        if (sizes[i] < 2 || categorical.contains(i)) continue;
        int side(int step) {
          var n = 0;
          final c = [...p.coordinates];
          while (true) {
            c[i] += step;
            n++;
            if (c[i] < 0 || c[i] >= sizes[i]) return n;
            final q = byKey[c.join(',')];
            if (q == null || !q.feasible) return n;
          }
        }

        room += math.min(side(-1), side(1));
      }
      p.room = room;
    }
  }
  final String type;
  final List<String> axes;
  final List<TunePoint> points;
  final TuneTargets targets;

  /// Number of values on each axis.
  final List<int> sizes;

  /// ТЗ 2.2 position on each axis, in grid steps (may be fractional).
  final List<double> reference;

  /// Axes that switch a mechanism (on/off, a variant) rather than move a
  /// number: margins are counted inside each of their slices.
  final Set<int> categorical;

  bool _sameCategory(TunePoint p, TunePoint q) =>
      categorical.every((i) => p.coordinates[i] == q.coordinates[i]);

  /// Is [p] in the ТЗ 2.2 variant of every categorical axis?
  bool atReferenceCategory(TunePoint p) =>
      categorical.every((i) => p.coordinates[i] == reference[i].round());

  /// An extra condition of feasibility (e.g. the eye duration above the
  /// longest natural closure).
  final bool Function(TunePoint)? extra;

  double _fromReference(TunePoint p) {
    var d = 0.0;
    for (var i = 0; i < reference.length; i++) {
      d += (p.coordinates[i] - reference[i]).abs();
    }
    return d;
  }

  /// The point with the largest margin. A mechanism the ТЗ does not have
  /// (a categorical axis away from the reference) is taken only when the
  /// reference variant does not reach a margin of [preferReferenceMargin].
  TunePoint? get best {
    final plain = _best(points.where(atReferenceCategory));
    if (plain != null && plain.margin >= preferReferenceMargin) return plain;
    return _best(points);
  }

  static const preferReferenceMargin = 2;

  TunePoint? _best(Iterable<TunePoint> candidates) {
    TunePoint? choice;
    for (final p in candidates.where((p) => p.feasible)) {
      if (choice == null ||
          p.margin > choice.margin ||
          (p.margin == choice.margin && p.room > choice.room) ||
          (p.margin == choice.margin &&
              p.room == choice.room &&
              _fromReference(p) < _fromReference(choice))) {
        choice = p;
      }
    }
    return choice;
  }

  /// The same sweep restricted to some points (one slice of an axis).
  TuneSweep where(bool Function(TunePoint) keep, {List<int>? sizes}) =>
      TuneSweep(
        type: type,
        axes: axes,
        points: [
          for (final p in points.where(keep))
            TunePoint(p.coordinates, p.metrics),
        ],
        targets: targets,
        sizes: sizes ?? this.sizes,
        reference: reference,
        categorical: categorical,
        extra: extra,
      );
}

/// Sweeps the profile over [values] (one list per axis; [apply] builds the
/// profile from one value of each axis). [reference] is the ТЗ 2.2 value on
/// each axis.
TuneSweep sweep({
  required String type,
  required List<String> axes,
  required List<List<Object?>> values,
  required List<Object?> reference,
  required DetectionProfile Function(List<Object?> v) apply,
  required List<TuneSample> samples,
  TuneTargets targets = const TuneTargets(),
  Set<int> categorical = const {},
  bool Function(TunePoint)? extra,
}) {
  final points = <TunePoint>[];
  void walk(int axis, List<int> idx) {
    if (axis == values.length) {
      final v = [for (var i = 0; i < idx.length; i++) values[i][idx[i]]];
      points.add(TunePoint([...idx], evaluate(apply(v), samples)));
      return;
    }
    for (var i = 0; i < values[axis].length; i++) {
      walk(axis + 1, [...idx, i]);
    }
  }

  walk(0, []);
  return TuneSweep(
    type: type,
    axes: axes,
    points: points,
    targets: targets,
    sizes: [for (final v in values) v.length],
    reference: [
      for (var i = 0; i < values.length; i++)
        math.max(0, values[i].indexOf(reference[i])).toDouble(),
    ],
    categorical: categorical,
    extra: extra,
  );
}

/// Longest closure (both eyes below [threshold]) outside the steps where the
/// eyes may close (closures, yawns, laughter, squints): the eye duration must
/// stay above it with a margin.
int longestNaturalClosureUs(TuneSample s, double threshold) {
  const allowed = {
    'eyes_closed_1s',
    'eyes_closed_2s',
    'eyes_closed_3s',
    'yawn',
    'laugh',
    'squint',
    'head_down_3s',
  };
  final episodes = Episode.fromLabels(s.recording.labels);
  bool inside(int us) => episodes.any(
    (e) =>
        allowed.contains(e.step) && us >= e.startUs && us <= e.endUs + 1000000,
  );
  var longest = 0;
  int? since;
  int? last;
  for (final f in s.recording.frames) {
    if (f.engine != s.engine) continue;
    final x = f.signals;
    final closed =
        x != null &&
        x.eyeOpenLeft != null &&
        x.eyeOpenRight != null &&
        x.eyeOpenLeft! < threshold &&
        x.eyeOpenRight! < threshold &&
        !inside(f.capturedUs);
    if (closed) {
      since ??= f.capturedUs;
      last = f.capturedUs;
    } else if (since != null) {
      longest = math.max(longest, last! - since);
      since = null;
    }
  }
  return longest;
}

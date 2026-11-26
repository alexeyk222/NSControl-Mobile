/// Early fatigue indicators computed from the same camera measurements as the
/// observation engine. They are informational trends (PERCLOS, long blinks,
/// short head nods) and never replace the eyes_closed/head_pitch_down events.
enum FatigueLevel { unknown, low, moderate, high }

class FatigueSnapshot {
  const FatigueSnapshot({
    required this.level,
    required this.eyeCoverage,
    required this.longBlinks,
    required this.nods,
    this.yawns = 0,
    this.perclos,
    this.blinksPerMinute,
    this.meanBlinkMs,
  });
  static const empty = FatigueSnapshot(
    level: FatigueLevel.unknown,
    eyeCoverage: 0,
    longBlinks: 0,
    nods: 0,
  );

  final FatigueLevel level;

  /// Share of usable eye time with both eyes closed over the last 60 s.
  final double? perclos;
  final double? blinksPerMinute;
  final int? meanBlinkMs;

  /// Closures of 0.4 s up to the event threshold, within the last 5 minutes.
  final int longBlinks;

  /// Short head drops that recovered before the head event threshold, 5 min.
  final int nods;

  /// Share of the last 60 s covered by usable eye measurements.
  final double eyeCoverage;

  /// Yawns (jawOpen held open) within the last 5 minutes. Information only:
  /// it does not change [level], because ТЗ rules do not use yawns.
  final int yawns;

  List<String> get signs => [
    if ((perclos ?? 0) >= FatigueMonitor.perclosModerate)
      'Глаза закрыты ${((perclos ?? 0) * 100).round()} % времени за минуту',
    if (longBlinks > 0) 'Долгие моргания за 5 мин: $longBlinks',
    if (nods > 0) 'Кратковременные кивки за 5 мин: $nods',
    if (yawns > 0) 'Зевки за 5 мин: $yawns',
  ];

  Map<String, Object?> toJson() => {
    'level': level.name,
    'perclos': perclos,
    'blinks_per_minute': blinksPerMinute,
    'mean_blink_ms': meanBlinkMs,
    'long_blinks_5m': longBlinks,
    'nods_5m': nods,
    'yawns_5m': yawns,
    'eye_coverage': eyeCoverage,
  };
}

class _Sample {
  const _Sample(this.atUs, this.closed);
  final int atUs;
  final bool closed;
}

class FatigueMonitor {
  FatigueMonitor({
    required this.eyeThreshold,
    required this.nodThreshold,
    required this.eyesEventUs,
    required this.headEventUs,
  });

  static const windowUs = 60000000;
  static const trendUs = 300000000;
  static const maxStepUs = 300000;
  static const minBlinkUs = 50000;
  static const longBlinkUs = 400000;
  static const minNodUs = 300000;
  static const perclosModerate = .08;
  static const perclosHigh = .15;

  /// A yawn: jawOpen at or above [yawnJawOpen] for at least [minYawnUs].
  /// Speech and laughter open the jaw less or for shorter.
  static const yawnJawOpen = .5;
  static const minYawnUs = 1000000;

  /// Closure threshold T from calibration; null in hidden-eyes mode.
  final double? eyeThreshold;

  /// Pitch delta (degrees down from neutral) treated as a nod.
  final double nodThreshold;
  final int eyesEventUs, headEventUs;

  final List<_Sample> _eyes = [];
  final List<int> _blinkDurations = [], _blinkEnds = [];
  final List<int> _longBlinks = [], _nods = [], _yawns = [];
  int? _closedSince, _nodSince, _yawnSince;
  // In hidden-eyes mode only head trends exist; report "low" once the head
  // channel has been observed instead of staying unknown forever.
  bool _headSeen = false;

  void addEyes(int atUs, double left, double right) {
    final t = eyeThreshold;
    if (t == null) return;
    final closed = left < t && right < t;
    if (closed) {
      _closedSince ??= atUs;
    } else if (_closedSince != null) {
      final duration = atUs - _closedSince!;
      if (duration >= longBlinkUs && duration < eyesEventUs) {
        _longBlinks.add(atUs);
      } else if (duration >= minBlinkUs && duration < longBlinkUs) {
        _blinkDurations.add(duration);
        _blinkEnds.add(atUs);
      }
      _closedSince = null;
    }
    _eyes.add(_Sample(atUs, closed));
    _trim(atUs);
  }

  /// Unusable eye data interrupts a closure without counting it as a blink.
  void eyesUnavailable() => _closedSince = null;

  void addHead(int atUs, double pitchDelta) {
    _headSeen = true;
    if (pitchDelta > nodThreshold) {
      _nodSince ??= atUs;
    } else if (_nodSince != null) {
      final duration = atUs - _nodSince!;
      if (duration >= minNodUs && duration < headEventUs) _nods.add(atUs);
      _nodSince = null;
    }
  }

  void headUnavailable() => _nodSince = null;

  /// Mouth opening from the `jawOpen` blendshape (ARKit). Engines without it
  /// never call this, and the yawn count stays 0.
  void addMouth(int atUs, double jawOpen) {
    if (jawOpen >= yawnJawOpen) {
      _yawnSince ??= atUs;
    } else if (_yawnSince != null) {
      if (atUs - _yawnSince! >= minYawnUs) _yawns.add(atUs);
      _yawnSince = null;
    }
  }

  void mouthUnavailable() => _yawnSince = null;

  void _trim(int nowUs) {
    _eyes.removeWhere((s) => nowUs - s.atUs > windowUs);
    while (_blinkEnds.isNotEmpty && nowUs - _blinkEnds.first > windowUs) {
      _blinkEnds.removeAt(0);
      _blinkDurations.removeAt(0);
    }
    _longBlinks.removeWhere((t) => nowUs - t > trendUs);
    _nods.removeWhere((t) => nowUs - t > trendUs);
    _yawns.removeWhere((t) => nowUs - t > trendUs);
  }

  FatigueSnapshot snapshot(int nowUs) {
    _trim(nowUs);
    var usable = 0, closed = 0;
    for (var i = 0; i + 1 < _eyes.length; i++) {
      final step = (_eyes[i + 1].atUs - _eyes[i].atUs).clamp(0, maxStepUs);
      usable += step;
      if (_eyes[i].closed) closed += step;
    }
    final coverage = (usable / windowUs).clamp(0.0, 1.0);
    final enoughEyes = usable >= windowUs ~/ 2;
    final perclos = enoughEyes ? closed / usable : null;
    final blinksPerMinute = enoughEyes
        ? _blinkEnds.length * windowUs / usable
        : null;
    final meanBlink = _blinkDurations.isEmpty
        ? null
        : _blinkDurations.reduce((a, b) => a + b) ~/
              _blinkDurations.length ~/
              1000;
    final p = perclos ?? 0;
    final level =
        p >= perclosHigh || _longBlinks.length >= 4 || _nods.length >= 3
        ? FatigueLevel.high
        : p >= perclosModerate || _longBlinks.length >= 2 || _nods.isNotEmpty
        ? FatigueLevel.moderate
        : enoughEyes || (eyeThreshold == null && _headSeen)
        ? FatigueLevel.low
        : FatigueLevel.unknown;
    return FatigueSnapshot(
      level: level,
      perclos: perclos,
      blinksPerMinute: blinksPerMinute,
      meanBlinkMs: meanBlink,
      longBlinks: _longBlinks.length,
      nods: _nods.length,
      yawns: _yawns.length,
      eyeCoverage: coverage,
    );
  }
}

/// Continuous driving time. A pause of at least [restCredit] counts as a
/// break and restarts the count; shorter pauses do not.
class DriveClock {
  DriveClock({
    this.breakAfterUs = 2 * 3600 * 1000000,
    this.restCreditUs = 15 * 60 * 1000000,
  });

  /// Continuous driving after which a break is due (settable: the break
  /// interval of the settings).
  int breakAfterUs;
  final int restCreditUs;
  int? _segmentStartUs, _lastActiveUs;

  /// Records activity; returns true when a pause long enough to count as a
  /// rest has just ended (not for the very first activity).
  bool active(int nowUs) {
    final rested =
        _lastActiveUs != null && nowUs - _lastActiveUs! >= restCreditUs;
    if (_lastActiveUs == null || rested) _segmentStartUs = nowUs;
    _lastActiveUs = nowUs;
    return rested;
  }

  /// Explicit "I took a break" from the user.
  void markBreak(int nowUs) {
    _segmentStartUs = nowUs;
    _lastActiveUs = nowUs;
  }

  void reset() {
    _segmentStartUs = null;
    _lastActiveUs = null;
  }

  int continuousUs(int nowUs) {
    if (_segmentStartUs == null || _lastActiveUs == null) return 0;
    if (nowUs - _lastActiveUs! >= restCreditUs) return 0;
    return nowUs - _segmentStartUs!;
  }

  bool breakDue(int nowUs) => continuousUs(nowUs) >= breakAfterUs;
  int untilBreakUs(int nowUs) =>
      (breakAfterUs - continuousUs(nowUs)).clamp(0, breakAfterUs);
}

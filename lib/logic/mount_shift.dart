/// When the trip re-calibrates by itself because the holder seems to have
/// moved (FR-CAL-08, docs/ux/ux-spec.md; copy `trip.moved`).
///
/// The sign is [RoadAdaptation.atLimit]: the road pose has drifted past the
/// cap of the slow adaptation and the median road pose lies beyond it. When
/// that holds for [holdUs], the trip says «Телефон сдвинулся. Смотрите на
/// дорогу, перенастроюсь» and collects a new side-mount calibration over
/// 10 s while observation goes on with the old one. The car may be moving,
/// so nothing needs a tap: it starts only while the driver looks at the road
/// with no sign or event of the automata, and a failed attempt is retried
/// after [retryUs] in silence.
class MountShiftMonitor {
  MountShiftMonitor({
    this.holdUs = 20000000,
    this.retryUs = 120000000,
    this.promptDelayUs = 1500000,
  });

  /// How long the drift must stay at the cap.
  final int holdUs;

  /// Pause after an attempt (success or not) before the next one.
  final int retryUs;

  /// From the voice prompt to the start of the calibration window: the
  /// driver hears it and settles on the road.
  final int promptDelayUs;
  int? _lastAttemptUs;

  /// [atLimitSinceUs] from [RoadAdaptation], all times on the same clock.
  bool shouldStart({
    required int atUs,
    required int? atLimitSinceUs,
    required bool onRoad,
    required bool signActive,
  }) {
    if (atLimitSinceUs == null || atUs - atLimitSinceUs < holdUs) return false;
    if (!onRoad || signActive) return false;
    final last = _lastAttemptUs;
    return last == null || atUs - last >= retryUs;
  }

  void attempted(int atUs) => _lastAttemptUs = atUs;
}

/// Trip reaction to the phone's heat (FR-DRV-08, docs/ux/states.md S-11,
/// S-12), from the iOS thermal state in ARKit's once-a-second `device` line.
///
/// - `serious` or `critical`: economy. The ARKit preview is hidden and only
///   every n-th frame is analysed, never fewer than [minPerSecond] analyses
///   a second (КЧ-05: at least 600 in every 60 s). Said once a trip.
/// - `critical`: a warning by voice and on the screen, repeated every
///   [criticalRepeatUs] while it lasts.
/// - Economy ends after [coolDownUs] at `nominal`/`fair`, so the phone does
///   not swing between the two rates.
/// - If the analyses fall below [minPerSecond] for [floorSeconds] seconds in
///   a row with the reduced rate, the full rate comes back for the rest of
///   the trip (ARKit itself may drop to 14 fps when hot, bench-v1).
///
/// ARKit face tracking does not go below 30 fps, so skipping frames only
/// saves our part (channel, attention, recording); the preview is the
/// bigger saving. Neither is measured yet: data comes from recorded trips.
class HeatPolicy {
  HeatPolicy({
    this.minPerSecond = 10,
    this.economyPerSecond = 15,
    this.coolDownUs = 120000000,
    this.criticalRepeatUs = 300000000,
    this.floorSeconds = 3,
  });
  final int minPerSecond, economyPerSecond, coolDownUs, criticalRepeatUs;
  final int floorSeconds;

  /// Latest thermal state (`nominal`, `fair`, `serious`, `critical`).
  String? thermal;
  bool economy = false;

  /// Frames are skipped (economy and the floor not hit).
  bool rateReduced = false;

  /// The analyses fell below [minPerSecond] with the reduced rate: the full
  /// rate stays for the rest of the trip.
  bool floorHit = false;
  bool _announced = false;
  int? _coolSinceUs, _lastCriticalUs;
  int _lowSeconds = 0, _skip = 0;

  bool get critical => thermal == 'critical';
  bool get previewAllowed => !economy;

  /// Every n-th frame of an engine at [fps] goes to the analysis.
  int emitEvery(int fps) {
    if (!rateReduced || fps <= 0) return 1;
    var n = fps ~/ economyPerSecond;
    if (n < 1) n = 1;
    while (n > 1 && fps / n < minPerSecond) {
      n--;
    }
    return n;
  }

  /// The engine restarted with new options: its first seconds are partial,
  /// so they do not count for the floor.
  void restarted() {
    _lowSeconds = 0;
    _skip = 2;
  }

  /// One `device` line: [sent] analyses in the last second.
  HeatDecision update({
    required int atUs,
    required String thermal,
    required int sent,
  }) {
    var sayEconomy = false, warnCritical = false;
    final hot = thermal == 'serious' || thermal == 'critical';
    final cool = thermal == 'nominal' || thermal == 'fair';
    if (hot || cool) this.thermal = thermal;
    if (hot) {
      _coolSinceUs = null;
      if (!economy) {
        economy = true;
        rateReduced = !floorHit;
        _lowSeconds = 0;
        if (!_announced && thermal == 'serious') sayEconomy = true;
      }
      _announced = true;
      if (thermal == 'critical') {
        final last = _lastCriticalUs;
        if (last == null || atUs - last >= criticalRepeatUs) {
          warnCritical = true;
          _lastCriticalUs = atUs;
        }
      } else {
        _lastCriticalUs = null;
      }
    } else if (cool) {
      _lastCriticalUs = null;
      if (economy) {
        final since = _coolSinceUs ??= atUs;
        if (atUs - since >= coolDownUs) {
          economy = false;
          rateReduced = false;
          _coolSinceUs = null;
        }
      }
    }
    if (rateReduced) {
      if (_skip > 0) {
        _skip--;
      } else if (sent < minPerSecond) {
        if (++_lowSeconds >= floorSeconds) {
          rateReduced = false;
          floorHit = true;
        }
      } else {
        _lowSeconds = 0;
      }
    }
    return HeatDecision(sayEconomy: sayEconomy, warnCritical: warnCritical);
  }
}

class HeatDecision {
  const HeatDecision({this.sayEconomy = false, this.warnCritical = false});
  final bool sayEconomy, warnCritical;
}

import 'dart:math' as math;

import 'calibration.dart';

/// How a holder shift was noticed.
enum HolderShiftSource {
  /// The phone's tilt to gravity changed (pitch or roll of the holder).
  gravity('gravity'),

  /// The head rests away from the road pose with the eyes looking straight
  /// out of the head, as if the camera, not the driver, had turned (a turn
  /// of the holder around the vertical, which gravity does not see).
  pose('pose');

  const HolderShiftSource(this.code);
  final String code;
}

/// Thresholds of [HolderShift]; part of the detection profile.
class HolderShiftSettings {
  const HolderShiftSettings({
    this.gravityDeg = 8,
    this.gravityHoldUs = 5000000,
    this.poseDeg = 12,
    this.poseSpreadDeg = 3,
    this.eyesInHeadDeg = 6,
    this.poseHoldUs = 15000000,
    this.poseShare = .8,
  });

  /// Tilt of the phone to gravity, from the calibration, that counts as a
  /// shift when it holds [gravityHoldUs]. Session 1: a phone sagging in the
  /// vent holder moved 5° in a minute; a desk bench stays within 0.5°.
  final double gravityDeg;
  final int gravityHoldUs;

  /// Pose path (a turn of the holder around the vertical, which gravity
  /// does not see): the median head yaw at least this far from the road
  /// (road frame) over [poseHoldUs], with [poseShare] of all frames of
  /// that window within 2 × [poseSpreadDeg] of the median yaw and pitch, and
  /// the eyes within [eyesInHeadDeg] of their position in the head at
  /// calibration (engines with gaze). Mirror and blind-spot glances (≤ 3.5 s
  /// in session 1) end long before; a 9 s look aside in bench-v1 fills only
  /// half of the window.
  final double poseDeg, poseSpreadDeg, eyesInHeadDeg;
  final int poseHoldUs;
  final double poseShare;

  Map<String, Object?> toJson() => {
    'gravityDeg': gravityDeg,
    'gravityHoldUs': gravityHoldUs,
    'poseDeg': poseDeg,
    'poseSpreadDeg': poseSpreadDeg,
    'eyesInHeadDeg': eyesInHeadDeg,
    'poseHoldUs': poseHoldUs,
    'poseShare': poseShare,
  };

  factory HolderShiftSettings.fromJson(Map<String, dynamic> json) {
    const d = HolderShiftSettings();
    double n(String k, double v) => (json[k] as num?)?.toDouble() ?? v;
    int i(String k, int v) => (json[k] as num?)?.toInt() ?? v;
    return HolderShiftSettings(
      gravityDeg: n('gravityDeg', d.gravityDeg),
      gravityHoldUs: i('gravityHoldUs', d.gravityHoldUs),
      poseDeg: n('poseDeg', d.poseDeg),
      poseSpreadDeg: n('poseSpreadDeg', d.poseSpreadDeg),
      eyesInHeadDeg: n('eyesInHeadDeg', d.eyesInHeadDeg),
      poseHoldUs: i('poseHoldUs', d.poseHoldUs),
      poseShare: n('poseShare', d.poseShare),
    );
  }
}

/// A sudden shift of the phone holder (FR-CAL-08), which the slow road-pose
/// adaptation does not follow: a jump of more than about 14° takes the road
/// pose out of its window.
///
/// The sign only suggests a new calibration. Observation goes on with the
/// old one until the new one is collected, because a false "shift" is the
/// dangerous error: calibrating on a distracted pose would hide the
/// distraction. Hence the long hold of the pose path.
class HolderShift {
  HolderShift({this.settings = const HolderShiftSettings()});
  final HolderShiftSettings settings;

  /// A shift is suspected since [sinceUs]; [offset] is how far (yaw left,
  /// pitch down, roll right, degrees): the phone's tilt for [source]
  /// gravity (yaw 0, gravity cannot see it), the resting head direction in
  /// the road frame for [source] pose.
  bool get suspected => sinceUs != null;
  int? sinceUs;
  HolderShiftSource? source;
  (double, double, double) offset = (0, 0, 0);

  List<double>? _gravity;
  (double, double)? _eyes;
  int? _tiltSinceUs;
  final List<_Pose> _poses = [];
  int? _checkedUs;

  /// Starts over with the calibration's references: the phone's "up"
  /// vector (camera frame) and the eyes' direction in the head.
  void reset({List<double>? gravityUp, (double, double)? eyesInHead}) {
    _gravity = gravityUp == null ? null : _unit(gravityUp);
    _eyes = eyesInHead;
    _tiltSinceUs = null;
    _poses.clear();
    _checkedUs = null;
    sinceUs = null;
    source = null;
    offset = (0, 0, 0);
  }

  /// One frame. [head]: road-frame head angles (yaw left, pitch down, roll),
  /// null without the driver's face. [eyesInHead]: eye-in-head direction
  /// (left, down) when the engine measures it. [eyesOpen]: false when the
  /// lids are shut. [sign]: a ТЗ sign or event is active.
  void observe(
    int atUs, {
    List<double>? gravityUp,
    (double, double, double)? head,
    (double, double)? eyesInHead,
    bool eyesOpen = true,
    bool sign = false,
  }) {
    if (suspected) return;
    _observeGravity(atUs, gravityUp);
    if (suspected) return;
    _observePose(atUs, head, eyesInHead, eyesOpen: eyesOpen, sign: sign);
  }

  void _observeGravity(int atUs, List<double>? up) {
    final reference = _gravity;
    if (up == null) return;
    final g = _unit(up);
    if (g == null) return;
    if (reference == null) {
      // No reference from the calibration: the first frame is one.
      _gravity = g;
      return;
    }
    final cos =
        (g[0] * reference[0] + g[1] * reference[1] + g[2] * reference[2]).clamp(
          -1.0,
          1.0,
        );
    final tilt = math.acos(cos) * 180 / math.pi;
    if (tilt > settings.gravityDeg) {
      final since = _tiltSinceUs ??= atUs;
      if (atUs - since >= settings.gravityHoldUs) {
        sinceUs = since;
        source = HolderShiftSource.gravity;
        var roll = _roll(g) - _roll(reference);
        if (roll > 180) roll -= 360;
        if (roll < -180) roll += 360;
        offset = (0, _pitch(g) - _pitch(reference), roll);
      }
    } else if (tilt < settings.gravityDeg * .75) {
      _tiltSinceUs = null;
    }
  }

  void _observePose(
    int atUs,
    (double, double, double)? head,
    (double, double)? eyes, {
    required bool eyesOpen,
    required bool sign,
  }) {
    final usable = head != null && eyesOpen && !sign;
    _poses.add(_Pose(atUs, usable ? head : null, usable ? eyes : null));
    final hold = settings.poseHoldUs;
    while (_poses.isNotEmpty && atUs - _poses.first.atUs > hold) {
      _poses.removeAt(0);
    }
    if (atUs - _poses.first.atUs < hold * .95) return;
    // The window statistics twice a second are enough for a 15 s hold.
    final checked = _checkedUs;
    if (checked != null && atUs - checked < 500000) return;
    _checkedUs = atUs;
    final heads = [
      for (final p in _poses)
        if (p.head != null) p.head!,
    ];
    if (heads.length < settings.poseShare * _poses.length) return;
    final yaws = heads.map((h) => h.$1), pitches = heads.map((h) => h.$2);
    final yaw = median(yaws), pitch = median(pitches);
    // Only a turn around the vertical: gravity sees a tilt of the holder,
    // so a steady pitch with gravity unchanged is the driver's posture
    // (bench-v1 001948: the head rose 12° in a minute, gravity within 0.2°).
    if (yaw.abs() < settings.poseDeg) return;
    // Steady over the whole window, not just over its larger part: a
    // glance aside for half of it must not pass.
    final band = 2 * settings.poseSpreadDeg;
    final steady = heads
        .where(
          (h) => (h.$1 - yaw).abs() <= band && (h.$2 - pitch).abs() <= band,
        )
        .length;
    if (steady < settings.poseShare * _poses.length) return;
    // With gaze: a driver who turned to look somewhere moves the eyes in the
    // head too (the eyes lead); a turned camera leaves them where they were.
    final reference = _eyes;
    final gaze = [
      for (final p in _poses)
        if (p.eyes != null) p.eyes!,
    ];
    if (reference != null && gaze.length >= heads.length / 2) {
      final left = median(gaze.map((e) => e.$1)) - reference.$1,
          down = median(gaze.map((e) => e.$2)) - reference.$2;
      if (math.max(left.abs(), down.abs()) > settings.eyesInHeadDeg) return;
    }
    sinceUs = _poses.first.atUs;
    source = HolderShiftSource.pose;
    offset = (yaw, pitch, median(heads.map((h) => h.$3)));
  }

  static List<double>? _unit(List<double> v) {
    if (v.length != 3) return null;
    final n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return n < 1e-6 ? null : [v[0] / n, v[1] / n, v[2] / n];
  }

  /// Phone tilt angles in the camera frame: toward the camera axis (z) and
  /// around it.
  static double _pitch(List<double> g) => math.asin(g[2]) * 180 / math.pi;
  static double _roll(List<double> g) => math.atan2(g[0], g[1]) * 180 / math.pi;
}

class _Pose {
  const _Pose(this.atUs, this.head, this.eyes);
  final int atUs;
  final (double, double, double)? head;
  final (double, double)? eyes;
}

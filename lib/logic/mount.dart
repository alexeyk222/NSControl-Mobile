import 'dart:math' as math;

import 'calibration.dart';
import 'face.dart';
import 'signals.dart';

/// Head pose relative to the road for a phone mounted to the side.
///
/// On a vent mount left or right of the driver, turned towards the driver,
/// the camera sees the face from the side: looking at the road is a head
/// turn of 25–40° for the camera. ФТ-05 measures the head "relative to
/// calibration", so the angles that go into the ТЗ automata are taken from
/// the rotation of the head relative to the calibrated road pose,
/// `R_cal⁻¹ · R`, not from differences of Euler angles: with the camera
/// turned and tilted, a difference of Euler angles under-reads a nod and
/// mixes it with the roll. See docs/attention-method.md, section 9.
///
/// Conventions (the same as `FaceSignals.headRotation` and
/// `lib/logic/arkit_geometry.dart`): a camera-bound frame with x to the
/// driver's left, y up and z from the face to the camera; the columns of a
/// head rotation are the face axes (own left, up, forward out of the face) in
/// that frame. Head angles are `R = Ry(yawLeft) · Rx(pitchDown) ·
/// Rz(rollRight)`: yaw and pitch are the azimuth and elevation of the face's
/// forward axis, roll is measured against the frame with the same yaw and
/// pitch.
class Rotation3 {
  const Rotation3._(this.m);

  /// Row-major 3×3.
  final List<double> m;

  static const identity = Rotation3._([1, 0, 0, 0, 1, 0, 0, 0, 1]);

  static double _rad(double deg) => deg * math.pi / 180;
  static double _deg(double rad) => rad * 180 / math.pi;

  factory Rotation3.fromAngles(
    double yawLeft,
    double pitchDown, [
    double rollRight = 0,
  ]) => rotationY(yawLeft) * rotationX(pitchDown) * rotationZ(rollRight);

  /// From the Euler angles of an engine in its own order (see
  /// [mlKitEulerOrder]); the contract order for every other engine.
  factory Rotation3.fromEngineAngles(
    String? engineId,
    double yawLeft,
    double pitchDown,
    double rollRight,
  ) => engineId == DetectorCapabilities.mlKit.id
      ? rotationX(pitchDown) * rotationZ(rollRight) * rotationY(yawLeft)
      : Rotation3.fromAngles(yawLeft, pitchDown, rollRight);

  /// Unit quaternion [w, x, y, z].
  factory Rotation3.fromQuaternion(List<double> q) {
    final n = math.sqrt(q.fold<double>(0, (s, v) => s + v * v));
    final w = q[0] / n, x = q[1] / n, y = q[2] / n, z = q[3] / n;
    return Rotation3._([
      1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y), //
      2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x), //
      2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y),
    ]);
  }

  /// Turn to the driver's left about the up axis.
  static Rotation3 rotationY(double deg) {
    final c = math.cos(_rad(deg)), s = math.sin(_rad(deg));
    return Rotation3._([c, 0, s, 0, 1, 0, -s, 0, c]);
  }

  /// Nod down about the left axis.
  static Rotation3 rotationX(double deg) {
    final c = math.cos(_rad(deg)), s = math.sin(_rad(deg));
    return Rotation3._([1, 0, 0, 0, c, -s, 0, s, c]);
  }

  /// Tilt to the right shoulder about the forward axis.
  static Rotation3 rotationZ(double deg) {
    final c = math.cos(_rad(deg)), s = math.sin(_rad(deg));
    return Rotation3._([c, -s, 0, s, c, 0, 0, 0, 1]);
  }

  Rotation3 operator *(Rotation3 o) {
    final r = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        var sum = 0.0;
        for (var k = 0; k < 3; k++) {
          sum += m[i * 3 + k] * o.m[k * 3 + j];
        }
        r[i * 3 + j] = sum;
      }
    }
    return Rotation3._(r);
  }

  Rotation3 get transposed =>
      Rotation3._([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);

  List<double> apply(List<double> v) => [
    m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
    m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
    m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
  ];

  /// (yawLeft, pitchDown, rollRight), degrees.
  (double, double, double) get angles {
    final yaw = _deg(math.atan2(m[2], m[8]));
    final pitch = _deg(math.asin((-m[5]).clamp(-1.0, 1.0)));
    final roll = _deg(math.atan2(m[3], m[4]));
    return (yaw, pitch, roll);
  }

  /// Euler angles of [engineId]'s order, the inverse of
  /// [Rotation3.fromEngineAngles].
  (double, double, double) engineAngles(String? engineId) {
    if (engineId != DetectorCapabilities.mlKit.id) return angles;
    // R = Rx(pitch) · Rz(roll) · Ry(yaw).
    final roll = _deg(math.asin((-m[1]).clamp(-1.0, 1.0)));
    final yaw = _deg(math.atan2(m[2], m[0]));
    final pitch = _deg(math.atan2(m[7], m[4]));
    return (yaw, pitch, roll);
  }

  /// Unit quaternion [w, x, y, z] with w ≥ 0.
  List<double> get quaternion {
    final t = m[0] + m[4] + m[8];
    double w, x, y, z;
    if (t > 0) {
      final r = math.sqrt(1 + t) * 2;
      w = r / 4;
      x = (m[7] - m[5]) / r;
      y = (m[2] - m[6]) / r;
      z = (m[3] - m[1]) / r;
    } else if (m[0] > m[4] && m[0] > m[8]) {
      final r = math.sqrt(1 + m[0] - m[4] - m[8]) * 2;
      w = (m[7] - m[5]) / r;
      x = r / 4;
      y = (m[1] + m[3]) / r;
      z = (m[2] + m[6]) / r;
    } else if (m[4] > m[8]) {
      final r = math.sqrt(1 + m[4] - m[0] - m[8]) * 2;
      w = (m[2] - m[6]) / r;
      x = (m[1] + m[3]) / r;
      y = r / 4;
      z = (m[5] + m[7]) / r;
    } else {
      final r = math.sqrt(1 + m[8] - m[0] - m[4]) * 2;
      w = (m[3] - m[1]) / r;
      x = (m[2] + m[6]) / r;
      y = (m[5] + m[7]) / r;
      z = r / 4;
    }
    return w < 0 ? [-w, -x, -y, -z] : [w, x, y, z];
  }

  /// Rotation angle between two poses, degrees.
  double angleTo(Rotation3 o) {
    final r = transposed * o;
    final c = ((r.m[0] + r.m[4] + r.m[8] - 1) / 2).clamp(-1.0, 1.0);
    return _deg(math.acos(c));
  }

  /// Unit vector of a direction given as azimuth (left) and elevation (down).
  static List<double> direction(double left, double down) {
    final l = _rad(left), d = _rad(down);
    return [math.cos(d) * math.sin(l), -math.sin(d), math.cos(d) * math.cos(l)];
  }

  /// (left, down) of a direction vector, degrees.
  static (double, double) anglesOf(List<double> v) {
    final n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return (
      _deg(math.atan2(v[0], v[2])),
      _deg(math.asin((-v[1] / n).clamp(-1.0, 1.0))),
    );
  }
}

/// Order of ML Kit's Euler angles, provisional: `R = Rx(pitch) · Rz(roll)
/// · Ry(yaw)` (yaw first, then roll and pitch about the camera axes). Chosen
/// on the first side-mount recording (signs-v1, vent left, view 42°): with
/// it `sign_head_down` comes out as a clean nod (16.9° down, roll 0.6°,
/// yaw 0.9°), while the contract order gives 13.6° with 11.2° of roll. To be
/// confirmed on more sign recordings.
const mlKitEulerOrder = 'XZY';

/// Head rotation of [s] in the camera frame: `FaceSignals.headRotation`
/// when the engine reports it (ARKit), else from the engine's Euler angles
/// (the contract order, or [mlKitEulerOrder] for ML Kit; roll 0 when the
/// engine does not report it). Null without a rotation and without yaw and
/// pitch.
Rotation3? headRotationOf(FaceSignals s) {
  final q = s.headRotation;
  if (q != null && q.length == 4) return Rotation3.fromQuaternion(q);
  final yaw = s.headYawLeft, pitch = s.headPitchDown;
  if (!FaceMeasurement.angle(yaw) || !FaceMeasurement.angle(pitch)) {
    return null;
  }
  final roll = s.headRollRight;
  return Rotation3.fromEngineAngles(
    s.engineId,
    yaw!,
    pitch!,
    FaceMeasurement.angle(roll) ? roll! : 0,
  );
}

/// The calibrated "looking at the road" pose: converts head and gaze angles
/// from the camera frame to the road frame (road = 0, 0, 0).
class RoadFrame {
  RoadFrame(this.road) : _inverse = road.transposed;

  /// From the engine's Euler angles of the road pose (the calibration
  /// neutrals are medians of the engine's own angles).
  factory RoadFrame.fromAngles(
    double yaw,
    double pitch,
    double roll, {
    String? engineId,
  }) => RoadFrame(Rotation3.fromEngineAngles(engineId, yaw, pitch, roll));

  factory RoadFrame.fromProfile(CalibrationProfile p) => RoadFrame.fromAngles(
    p.neutralYaw,
    p.neutralPitch,
    p.neutralRoll,
    engineId: p.detector.id,
  );

  /// Head pose while looking at the road, in the camera frame.
  final Rotation3 road;
  final Rotation3 _inverse;

  /// Head (yawLeft, pitchDown, rollRight) relative to the road pose.
  (double, double, double)? head(FaceSignals s) {
    final r = headRotationOf(s);
    return r == null ? null : (_inverse * r).angles;
  }

  /// A camera-frame direction (gaze) as (left, down) in the road frame.
  (double, double) direction(double left, double down) =>
      Rotation3.anglesOf(_inverse.apply(Rotation3.direction(left, down)));
}

/// One face for the ТЗ automata on a side mount: head angles relative to
/// the road pose ([RoadFrame.head]); the eyes only while the camera sees the
/// face within the engine's eye limit (the far eye leaves the view). Engines
/// without face ids (one face only) inherit the calibrated id. Used by the
/// lab pipeline and by the trip.
FaceMeasurement mountMeasurement(
  FaceSignals f, {
  required RoadFrame road,
  required CalibrationProfile calibration,
  bool withEyes = true,
  RoadAdaptation? adaptation,
}) {
  final m = f.toMeasurement();
  final view = f.headYawLeft;
  final eyes =
      withEyes &&
      view != null &&
      view.abs() <= calibration.detector.eyeYawLimit;
  final raw = road.head(f);
  final head = raw == null ? null : (adaptation?.apply(raw) ?? raw);
  return FaceMeasurement(
    trackingId: m.trackingId ?? calibration.trackingId,
    leftEye: eyes ? m.leftEye : null,
    rightEye: eyes ? m.rightEye : null,
    pitchDown: head?.$2,
    yaw: head?.$1,
    roll: head?.$3,
  );
}

/// The profile for `ObservationEngine` when the pipeline feeds road-frame
/// angles: neutral angles 0 (the road), the same eyes, and no eye view limit
/// of its own, because the pipeline already withholds the eyes when the face
/// is turned from the camera beyond [CalibrationProfile.detector]'s limit
/// (the eye limit is about the view of the camera, not about the road).
CalibrationProfile roadProfile(CalibrationProfile p) => CalibrationProfile(
  trackingId: p.trackingId,
  detector: DetectorCapabilities(
    id: p.detector.id,
    version: '${p.detector.version}+road',
    eyeYawLimit: 90,
  ),
  hiddenEyes: p.hiddenEyes,
  neutralPitch: 0,
  neutralYaw: 0,
  neutralRoll: 0,
  leftEyeMedian: p.leftEyeMedian,
  rightEyeMedian: p.rightEyeMedian,
  eyeThreshold: p.eyeThreshold,
  eyeShare: p.eyeShare,
  eyeCap: p.eyeCap,
);

class MountCalibrationResult {
  const MountCalibrationResult(this.result, {this.viewYaw, this.note});
  final CalibrationResult result;

  /// Median head yaw to the camera while looking at the road, degrees: the
  /// angle at which the camera sees the face.
  final double? viewYaw;

  /// Shown to the driver when the calibration succeeded with a restriction
  /// (eyes not evaluated on this mount).
  final String? note;

  CalibrationProfile? get profile => result.profile;
  bool get successful => result.successful;
  List<String> get issues => result.issues;
}

/// ТЗ calibration (10 s looking at the road) for a side mount, flag
/// `mountRelative`. Differences from `CalibrationCollector`:
/// - frames are not dropped for an absolute head yaw: the usable frames are
///   those within [spreadDeg] of the median pose (rotation angle), so a
///   phone turned 25–40° from the road still calibrates;
/// - the eyes are calibrated only when the camera sees the face within the
///   engine's eye limit ([DetectorCapabilities.eyeYawLimit]); otherwise, up
///   to [maxViewYaw], the head alone is calibrated and [MountCalibrationResult
///   .note] says why;
/// - the other ТЗ checks are the same: 10 s, at least 90 usable frames and
///   90 % of the frames, head stable (MAD ≤ 5°), eyes open and stable.
class MountCalibrationCollector {
  MountCalibrationCollector({
    required this.trackingId,
    required this.detector,
    required this.hiddenEyes,
    required this.startedUs,
    this.spreadDeg = 10,
    this.maxViewYaw = 45,
  }) {
    if (startedUs < 0 || !detector.valid) {
      throw ArgumentError('Некорректная калибровка');
    }
  }
  final int trackingId, startedUs;
  final DetectorCapabilities detector;
  final bool hiddenEyes;
  final double spreadDeg, maxViewYaw;

  final List<FaceSignals> _faces = [];
  int _processed = 0;
  bool _identityChanged = false;
  int? _lastUs;

  int get processedFrames => _processed;

  /// The restriction shown when the eyes are out of the engine's view.
  static String eyesNote(double viewYaw, double limit) =>
      'При этом креплении глаза не оцениваются: ракурс '
      '${viewYaw.abs().round()}°, предел ${limit.round()}°. '
      'Контролируется только наклон головы.';

  void add({required int capturedUs, required List<FaceSignals> faces}) {
    if (capturedUs < startedUs ||
        capturedUs > startedUs + 10000000 ||
        (_lastUs != null && capturedUs <= _lastUs!)) {
      return;
    }
    _lastUs = capturedUs;
    _processed++;
    final tracked = faces.where((f) => f.tracked).toList();
    if (tracked.length > 1 ||
        (tracked.length == 1 &&
            tracked.single.trackingId != null &&
            tracked.single.trackingId != trackingId)) {
      _identityChanged = true;
      return;
    }
    if (tracked.isEmpty) return;
    final face = tracked.single;
    if (headRotationOf(face) == null ||
        !FaceMeasurement.angle(face.headRollRight)) {
      return;
    }
    _faces.add(face);
  }

  MountCalibrationResult finish({required int nowUs}) {
    final issues = <String>[];
    if (_identityChanged) {
      issues.add(
        'Лицо изменилось или выбор неоднозначен. Подтвердите лицо и повторите калибровку.',
      );
    }
    if (nowUs - startedUs < 10000000) {
      issues.add('Калибровка длится 10 секунд. Дождитесь окончания.');
    }
    var usable = <FaceSignals>[];
    double? yaw, pitch, roll;
    if (_faces.isNotEmpty) {
      yaw = median(_faces.map((f) => f.headYawLeft!));
      pitch = median(_faces.map((f) => f.headPitchDown!));
      roll = median(_faces.map((f) => f.headRollRight!));
      final center = Rotation3.fromEngineAngles(detector.id, yaw, pitch, roll);
      usable = [
        for (final f in _faces)
          if (center.angleTo(headRotationOf(f)!) <= spreadDeg) f,
      ];
    }
    if (usable.length < 90) {
      issues.add(
        'Нужно не менее 90 пригодных кадров. Улучшите освещение и повторите.',
      );
    }
    if (_processed == 0 || usable.length / _processed < .9) {
      issues.add(
        'Пригодно менее 90% кадров. Удерживайте лицо в кадре, смотрите на дорогу и повторите.',
      );
    }
    if (usable.isNotEmpty) {
      yaw = median(usable.map((f) => f.headYawLeft!));
      pitch = median(usable.map((f) => f.headPitchDown!));
      roll = median(usable.map((f) => f.headRollRight!));
      for (final values in [
        usable.map((f) => f.headPitchDown!),
        usable.map((f) => f.headYawLeft!),
        usable.map((f) => f.headRollRight!),
      ]) {
        if (medianAbsoluteDeviation(values) > 5) {
          issues.add(
            'Положение головы нестабильно. Закрепите телефон и повторите.',
          );
          break;
        }
      }
    }
    if (yaw != null && yaw.abs() > maxViewYaw) {
      issues.add(
        'Камера видит лицо под углом ${yaw.abs().round()}°, больше '
        '${maxViewYaw.round()}°. Поверните телефон к водителю и повторите.',
      );
    }
    String? note;
    var eyes = !hiddenEyes;
    double? left, right;
    if (eyes && yaw != null) {
      final limit = detector.eyeYawLimit;
      final eyeFrames = [
        for (final f in usable)
          if (f.eyeOpenLeft != null &&
              f.eyeOpenRight != null &&
              f.headYawLeft!.abs() <= limit)
            f,
      ];
      if (yaw.abs() > limit ||
          eyeFrames.length < 90 ||
          eyeFrames.length < .9 * usable.length) {
        eyes = false;
        note = eyesNote(yaw, limit);
      } else {
        left = median(eyeFrames.map((f) => f.eyeOpenLeft!));
        right = median(eyeFrames.map((f) => f.eyeOpenRight!));
        if (left < .6 || right < .6) {
          issues.add('Откройте глаза и улучшите освещение; затем повторите.');
        }
        if (medianAbsoluteDeviation(eyeFrames.map((f) => f.eyeOpenLeft!)) >
                .15 + 1e-12 ||
            medianAbsoluteDeviation(eyeFrames.map((f) => f.eyeOpenRight!)) >
                .15 + 1e-12) {
          issues.add('Оценки глаз нестабильны. Устраните блики и повторите.');
        }
      }
    }
    final profile = issues.isNotEmpty
        ? null
        : CalibrationProfile(
            trackingId: trackingId,
            detector: detector,
            hiddenEyes: !eyes,
            neutralPitch: pitch!,
            neutralYaw: yaw!,
            neutralRoll: roll!,
            leftEyeMedian: eyes ? left : null,
            rightEyeMedian: eyes ? right : null,
            eyeThreshold: eyes
                ? math.min(.4, .5 * math.min(left!, right!))
                : null,
          );
    return MountCalibrationResult(
      CalibrationResult(
        profile: profile,
        issues: issues,
        processedFrames: _processed,
        usableFrames: usable.length,
      ),
      viewYaw: yaw,
      note: profile == null ? null : note,
    );
  }
}

/// Slow drift of the road pose (side mount): over minutes a driver settles
/// into the seat and the head pose while looking at the road moves away from
/// the calibrated one (session 1: about 8° in 11 min). The head angles for
/// the automata are then taken relative to the calibrated road pose turned
/// by a small correction, which follows the median head pose of the frames
/// in the road zone while no automaton has a sign.
///
/// The correction moves at most [degPerMin] degrees per minute and never
/// beyond [maxOffset] from the calibration, and only frames within
/// [sampleLimit] of the current road pose count, so a lowered head or a
/// glance elsewhere cannot pull it: a slow droop from fatigue is followed
/// for at most [maxOffset].
class RoadAdaptation {
  RoadAdaptation({
    required this.degPerMin,
    this.windowUs = 120000000,
    this.minSpanUs = 30000000,
    this.updateEveryUs = 5000000,
    this.maxOffset = 10,
    this.sampleLimit = 7,
  });
  final double degPerMin, maxOffset, sampleLimit;
  final int windowUs, minSpanUs, updateEveryUs;

  /// The correction (yaw left, pitch down) from the calibrated road pose.
  double yaw = 0, pitch = 0;
  final List<(int, double, double)> _samples = [];
  int? _lastUpdateUs;

  /// The posture has drifted past [maxOffset]: the correction sits at the
  /// cap and the median road pose of the window lies beyond it. More than
  /// a slow drift of the posture: the holder may have moved (FR-CAL-08), so
  /// the trip may offer a new calibration. Since when, in [observe] time;
  /// null while the correction is within the cap.
  int? atLimitSinceUs;
  bool get atLimit => atLimitSinceUs != null;

  /// Head angles relative to the corrected road pose, from angles relative
  /// to the calibrated one.
  (double, double, double) apply((double, double, double) h) {
    if (yaw == 0 && pitch == 0) return h;
    final c = Rotation3.fromAngles(yaw, pitch, 0);
    return (c.transposed * Rotation3.fromAngles(h.$1, h.$2, h.$3)).angles;
  }

  /// A road-zone frame without a sign: [adjusted] are the head angles
  /// relative to the corrected road pose.
  void observe(int atUs, (double, double, double) adjusted) {
    if (adjusted.$1.abs() > 2 * sampleLimit ||
        adjusted.$2.abs() > sampleLimit) {
      return;
    }
    _samples.add((atUs, adjusted.$1 + yaw, adjusted.$2 + pitch));
    while (_samples.isNotEmpty && atUs - _samples.first.$1 > windowUs) {
      _samples.removeAt(0);
    }
    final last = _lastUpdateUs;
    if (last != null && atUs - last < updateEveryUs) return;
    if (atUs - _samples.first.$1 < minSpanUs) return;
    final step =
        degPerMin * (last == null ? updateEveryUs : atUs - last) / 60e6;
    double toward(double from, double to) =>
        (from + (to - from).clamp(-step, step)).clamp(-maxOffset, maxOffset);
    final targetYaw = median(_samples.map((s) => s.$2)),
        targetPitch = median(_samples.map((s) => s.$3));
    yaw = toward(yaw, targetYaw);
    pitch = toward(pitch, targetPitch);
    _lastUpdateUs = atUs;
    final capped =
        (yaw.abs() >= maxOffset && targetYaw.abs() > maxOffset) ||
        (pitch.abs() >= maxOffset && targetPitch.abs() > maxOffset);
    atLimitSinceUs = capped ? (atLimitSinceUs ?? atUs) : null;
  }
}

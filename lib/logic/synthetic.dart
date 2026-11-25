import 'dart:convert';
import 'dart:math' as math;

import 'calibration.dart';
import 'face.dart';
import 'signals.dart';

/// Synthetic recordings (JSONL, schema 1) of the contract scenario steps, for
/// tests and for checking the replay without a phone.
///
/// Three kinds of recordings:
/// - [SyntheticStyle.arkit]: 30 fps, head pose, gaze, eye-in-head angles,
///   blendshapes, openness = 1 − eyeBlink;
/// - [SyntheticStyle.mlKit]: 15 fps, head angles and eye-open probabilities
///   only;
/// - [SyntheticStyle.arkitMlKit]: the lab's comparison mode «ARKit + ML Kit»
///   as the iPhone writes it: ARKit at 60 fps with the `raw` field, ML Kit on
///   every fourth ARKit frame with the same `capturedUs` (two `frame` lines
///   per analysed frame), a `device` line every second. One scene for both
///   engines (the ARKit one); ML Kit is assumed to keep the lid above T in a
///   squint or yawn, as in [SyntheticStyle.mlKit].
///
/// The model is deliberately simple and its assumptions are listed in
/// docs/attention-method.md. It exercises the logic; it does not replace
/// recordings of a real face.
enum SyntheticStyle {
  arkit('arkit_face_tracking'),
  mlKit('mlkit_face_detection'),
  arkitMlKit('arkit_face_tracking');

  const SyntheticStyle(this.engineId);

  /// The primary engine: calibration and the ТЗ automata.
  final String engineId;

  List<String> get engines => this == arkitMlKit
      ? const ['arkit_face_tracking', 'mlkit_face_detection']
      : [engineId];
}

class _Pose {
  const _Pose({
    this.yaw = 0,
    this.pitch = 0,
    this.roll = 0,
    this.eyeLeft = 0,
    this.eyeDown = 0,
    this.lid = .9,
    this.squint = 0,
    this.jaw = 0,
    this.visible = true,
  });
  final double yaw, pitch, roll, eyeLeft, eyeDown, lid, squint, jaw;
  final bool visible;

  _Pose lerp(_Pose b, double k) {
    double l(double x, double y) => x + (y - x) * k;
    return _Pose(
      yaw: l(yaw, b.yaw),
      pitch: l(pitch, b.pitch),
      roll: l(roll, b.roll),
      eyeLeft: l(eyeLeft, b.eyeLeft),
      eyeDown: l(eyeDown, b.eyeDown),
      lid: l(lid, b.lid),
      squint: l(squint, b.squint),
      jaw: l(jaw, b.jaw),
      visible: visible && b.visible,
    );
  }

  _Pose copy({double? lid, double? jaw, bool? visible}) => _Pose(
    yaw: yaw,
    pitch: pitch,
    roll: roll,
    eyeLeft: eyeLeft,
    eyeDown: eyeDown,
    lid: lid ?? this.lid,
    squint: squint,
    jaw: jaw ?? this.jaw,
    visible: visible ?? this.visible,
  );
}

const _road = _Pose();

class _Step {
  _Step(this.name, this.keys);

  /// Keyframes (offset from step start, pose), linear in between.
  final List<(int, _Pose)> keys;
  final String name;
  int get durationUs => keys.last.$1;

  _Pose at(int tUs) {
    for (var i = 0; i + 1 < keys.length; i++) {
      final (t0, p0) = keys[i];
      final (t1, p1) = keys[i + 1];
      if (tUs >= t0 && tUs <= t1) {
        return t1 == t0 ? p1 : p0.lerp(p1, (tUs - t0) / (t1 - t0));
      }
    }
    return keys.last.$2;
  }

  /// Move to [pose] in [rampMs], hold [holdMs], return to the road.
  factory _Step.glance(
    String name,
    _Pose pose,
    int holdMs, {
    int rampMs = 150,
  }) => _Step(name, [
    (0, _road),
    (rampMs * 1000, pose),
    ((rampMs + holdMs) * 1000, pose),
    ((2 * rampMs + holdMs) * 1000, _road),
  ]);

  factory _Step.sequence(
    String name,
    List<(_Pose, int)> holds, {
    int rampMs = 200,
  }) {
    final keys = <(int, _Pose)>[(0, _road)];
    var t = 0;
    for (final (pose, holdMs) in holds) {
      t += rampMs * 1000;
      keys.add((t, pose));
      t += holdMs * 1000;
      keys.add((t, pose));
    }
    keys.add((t + rampMs * 1000, _road));
    return _Step(name, keys);
  }
}

/// Builds the bench scenario as a JSONL recording.
class SyntheticScenario {
  SyntheticScenario(this.style, {this.seed = 7});
  final SyntheticStyle style;
  final int seed;

  static const calibrationUs = 10000000;
  static const gapUs = 2500000;

  /// Camera offset of the road direction (phone a bit to the right and below).
  static const roadYaw = 4.0, roadPitch = -3.0;

  /// The scene and the primary engine are ARKit's.
  bool get _arkit => style != SyntheticStyle.mlKit;
  bool get _dual => style == SyntheticStyle.arkitMlKit;

  /// ML Kit analyses every n-th ARKit frame in the comparison mode (busy).
  static const mlKitEvery = 4;

  /// The bench-v1 steps of the contract plus `distraction_4s`.
  List<_Step> get _steps => [
    _Step('road', [(0, _road), (20000000, _road)]),
    for (var i = 0; i < 2; i++) ...[
      _Step.glance(
        'mirror_left',
        const _Pose(yaw: 20, eyeLeft: 16, eyeDown: 3),
        1000,
      ),
      _Step.glance(
        'mirror_right',
        const _Pose(yaw: -32, eyeLeft: -20, eyeDown: 5),
        1000,
      ),
      _Step.glance(
        'mirror_rear',
        const _Pose(yaw: -14, pitch: -6, eyeLeft: -12, eyeDown: -8),
        1000,
      ),
    ],
    _Step.glance(
      'blind_spot_left',
      const _Pose(yaw: 75, eyeLeft: 15),
      1000,
      rampMs: 300,
    ),
    _Step.glance(
      'blind_spot_right',
      const _Pose(yaw: -75, eyeLeft: -15),
      1000,
      rampMs: 300,
    ),
    _Step.sequence('intersection_scan', [
      (const _Pose(yaw: 50, eyeLeft: 10), 1200),
      (const _Pose(yaw: -50, eyeLeft: -10), 1500),
      (const _Pose(yaw: 45, eyeLeft: 10), 2500),
    ], rampMs: 350),
    // ARKit: a 2 s glance with the lid lowered below T by the downward gaze.
    // ML Kit: a short 1.2 s glance (its probability drops the same way).
    _Step.glance(
      'instruments',
      const _Pose(pitch: 6, eyeDown: 20),
      _arkit ? 2000 : 1200,
    ),
    _Step('talk', [
      for (var t = 0; t <= 6000; t += 100)
        (
          t * 1000,
          _Pose(yaw: 5 * math.sin(t / 900), jaw: .22 + .13 * math.sin(t / 50)),
        ),
    ]),
    _Step.sequence('laugh', [
      (const _Pose(lid: .5, squint: .55, jaw: .45, pitch: -3), 1000),
      (const _Pose(lid: .28, squint: .75, jaw: .5, pitch: -5), 800),
      (const _Pose(lid: .5, squint: .55, jaw: .4), 1000),
    ], rampMs: 150),
    _Step.glance(
      'squint',
      // ARKit openness falls below T; ML Kit is assumed to stay above T.
      _Pose(lid: _arkit ? .35 : .5, squint: .7),
      3000,
      rampMs: 300,
    ),
    _Step.sequence('yawn', [
      (const _Pose(jaw: .5, pitch: -4), 500),
      (_Pose(jaw: .85, pitch: -8, lid: _arkit ? .3 : .45, squint: .6), 2000),
      (const _Pose(jaw: .4, pitch: -3), 500),
    ], rampMs: 300),
    _Step.glance('eyes_closed_1s', const _Pose(lid: .03), 1000, rampMs: 100),
    _Step.glance('eyes_closed_2s', const _Pose(lid: .03), 2000, rampMs: 100),
    _Step.glance('eyes_closed_3s', const _Pose(lid: .03), 3000, rampMs: 100),
    _Step.glance(
      'head_down_3s',
      const _Pose(pitch: 28, eyeDown: 5, lid: .6),
      3000,
      rampMs: 300,
    ),
    _Step.glance('nod', const _Pose(pitch: 25, lid: .6), 800, rampMs: 200),
    _Step('distraction_4s', [
      (0, _road),
      (300000, const _Pose(yaw: -18, pitch: 15, eyeLeft: -10, eyeDown: 18)),
      (2000000, const _Pose(yaw: -18, pitch: 15, eyeLeft: -10, eyeDown: 18)),
      // A short tracking loss inside the glance must not reset the timer.
      (
        2000001,
        const _Pose(
          yaw: -18,
          pitch: 15,
          eyeLeft: -10,
          eyeDown: 18,
          visible: false,
        ),
      ),
      (
        2300000,
        const _Pose(
          yaw: -18,
          pitch: 15,
          eyeLeft: -10,
          eyeDown: 18,
          visible: false,
        ),
      ),
      (2300001, const _Pose(yaw: -18, pitch: 15, eyeLeft: -10, eyeDown: 18)),
      (4300000, const _Pose(yaw: -18, pitch: 15, eyeLeft: -10, eyeDown: 18)),
      (4600000, _road),
    ]),
    _Step('road', [
      (0, _road),
      (3000000, _road),
      // Tracking dropout on the road.
      (3000001, _road.copy(visible: false)),
      (3250000, _road.copy(visible: false)),
      (3250001, _road),
      (8000000, _road),
    ]),
  ];

  String toJsonl() {
    final rnd = math.Random(seed);
    double noise(double amp) => (rnd.nextDouble() * 2 - 1) * amp;
    final frameUs = _dual ? 16667 : (_arkit ? 33333 : 66667);
    final latencyUs = _dual ? 20000 : (_arkit ? 35000 : 70000);
    final plan = <(int, _Step)>[];
    var cursor = calibrationUs + gapUs;
    for (final s in _steps) {
      plan.add((cursor, s));
      cursor += s.durationUs + gapUs;
    }
    final endUs = cursor;
    final out = <String>[];
    final frames = <(int, int, FaceSignals?)>[];
    // Comparison mode: ML Kit results of the same frames.
    final mlKitFrames = <int, (int, FaceSignals?)>{};
    var nextBlinkUs = 2000000;
    var wasLost = false, mlKitWasLost = false;
    _id = 1;
    var mlKitId = 1, index = 0;
    for (var t = 0; t <= endUs; t += frameUs, index++) {
      final captured = t + noise(2000).round().abs();
      var pose = _road;
      for (final (start, step) in plan) {
        if (captured >= start && captured <= start + step.durationUs) {
          pose = step.at(captured - start);
        }
      }
      // Natural blinks, 150 ms, unless the eyes are already nearly shut.
      if (captured >= nextBlinkUs && captured < nextBlinkUs + 150000) {
        if (pose.lid > .5) pose = pose.copy(lid: .05);
      } else if (captured >= nextBlinkUs + 150000) {
        nextBlinkUs += 3500000 + rnd.nextInt(1500000);
      }
      final visible = pose.visible && pose.yaw.abs() <= (_arkit ? 60 : 55);
      // ML Kit gives the face a new tracking id after every loss.
      if (!_arkit && visible && wasLost) _id++;
      wasLost = !visible;
      frames.add((
        captured,
        captured + latencyUs + noise(5000).round().abs(),
        visible ? _signals(pose, noise, arkit: _arkit, id: _id) : null,
      ));
      if (_dual && index % mlKitEvery == 0) {
        final seen = pose.visible && pose.yaw.abs() <= 55;
        if (seen && mlKitWasLost) mlKitId++;
        mlKitWasLost = !seen;
        mlKitFrames[captured] = (
          captured + 60000 + noise(10000).round().abs(),
          seen ? _signals(pose, noise, arkit: false, id: mlKitId) : null,
        );
      }
    }
    final profile = _calibrate(frames);
    out.add(
      jsonEncode({
        'type': 'meta',
        'schema': 1,
        'recordingId': 'synthetic-${style.name}-$seed',
        'app': 'synthetic',
        'device': _dual ? 'iPhone12,1' : 'synthetic',
        'os': 'synthetic',
        'engines': style.engines,
        'startedAt': '2026-11-25T00:00:00+03:00',
        'subject': 'synthetic',
        'notes': 'SyntheticScenario',
      }),
    );
    var calibrationWritten = false;
    final labels = <(int, String)>[];
    final reps = <String, int>{};
    for (final (start, step) in plan) {
      final rep = reps.update(step.name, (n) => n + 1, ifAbsent: () => 1);
      labels.add((
        start,
        jsonEncode({
          'type': 'label',
          'atUs': start,
          'scenario': 'bench-v1',
          'step': step.name,
          'rep': rep,
          'edge': 'start',
        }),
      ));
      labels.add((
        start + step.durationUs,
        jsonEncode({
          'type': 'label',
          'atUs': start + step.durationUs,
          'scenario': 'bench-v1',
          'step': step.name,
          'rep': rep,
          'edge': 'end',
        }),
      ));
    }
    var li = 0;
    var nextDeviceUs = 1000000;
    for (final (captured, completed, signals) in frames) {
      if (_dual && captured >= nextDeviceUs) {
        out.add(jsonEncode(_device(nextDeviceUs, endUs)));
        nextDeviceUs += 1000000;
      }
      if (!calibrationWritten && captured > calibrationUs) {
        out.add(
          jsonEncode({
            'type': 'calibration',
            'atUs': calibrationUs,
            'profile': profile.toJson(),
          }),
        );
        calibrationWritten = true;
      }
      while (li < labels.length && labels[li].$1 <= captured) {
        out.add(labels[li++].$2);
      }
      out.add(
        jsonEncode({
          'type': 'frame',
          'engine': style.engineId,
          'capturedUs': captured,
          'completedUs': completed,
          'faceCount': signals == null ? 0 : 1,
          if (signals != null) 'signals': signals.toJson(),
          if (_dual) 'raw': _raw(signals),
        }),
      );
      final mlKit = mlKitFrames[captured];
      if (mlKit != null) {
        final (done, face) = mlKit;
        out.add(
          jsonEncode({
            'type': 'frame',
            'engine': SyntheticStyle.mlKit.engineId,
            'capturedUs': captured,
            'completedUs': done,
            'faceCount': face == null ? 0 : 1,
            if (face != null) 'signals': face.toJson(),
          }),
        );
      }
    }
    while (li < labels.length) {
      out.add(labels[li++].$2);
    }
    return '${out.join('\n')}\n';
  }

  DetectorCapabilities get detector => _arkit
      ? const DetectorCapabilities(
          id: 'arkit_face_tracking',
          version: 'synthetic',
          eyeYawLimit: 25,
        )
      : DetectorCapabilities.mlKit;

  CalibrationProfile _calibrate(List<(int, int, FaceSignals?)> frames) {
    final collector = CalibrationCollector(
      trackingId: 1,
      detector: detector,
      hiddenEyes: false,
      startedUs: 0,
    );
    for (final (captured, _, signals) in frames) {
      if (captured > calibrationUs) break;
      collector.add(
        capturedUs: captured,
        faces: [if (signals != null) signals.toMeasurement()],
      );
    }
    final result = collector.finish(nowUs: calibrationUs);
    if (!result.successful) {
      throw StateError('Синтетическая калибровка: ${result.issues}');
    }
    return result.profile!;
  }

  int _id = 1;

  /// A `device` line of the comparison mode: slow warming and discharge.
  Map<String, Object?> _device(int atUs, int endUs) {
    final k = atUs / endUs;
    return {
      'type': 'device',
      'atUs': atUs,
      'thermal': k < .6 ? 'nominal' : 'fair',
      'battery': double.parse((.81 - .04 * k).toStringAsFixed(3)),
      'batteryState': 'unplugged',
      'lowPower': false,
      'light': 820,
      'arkitFps': 60,
      'sent': 60,
      'dropped': 0,
      'mlKitDone': 60 ~/ mlKitEvery,
      'mlKitSkipped': 60 - 60 ~/ mlKitEvery,
      'mlKitErrors': 0,
      'mlKitBusyUs': 900000,
      'mlKitOrientation': 'leftMirrored',
    };
  }

  /// Bridge numbers of an ARKit frame (shape of `ArkitFaceSource.onRaw`);
  /// the replay ignores them, they only have to be carried.
  Map<String, Object?> _raw(FaceSignals? s) => {
    'gravityUp': [0.0, 1.0, 0.0],
    'light': 820,
    'axes': {'mirror': false, 'swapEyes': false},
    'faces': [
      if (s != null)
        {
          'id': s.trackingId,
          'tracked': true,
          'faceInCamera': [
            1.0, 0.0, 0.0, 0.0, //
            0.0, 1.0, 0.0, 0.0, //
            0.0, 0.0, 1.0, 0.0, //
            0.0, 0.0, -(s.distanceM ?? .55), 1.0,
          ],
          'lookAt': [0.0, 0.0, 1.0],
          'blendshapes': {
            'eyeBlink_L': s.blendshape(Blendshape.eyeBlinkLeft),
            'eyeBlink_R': s.blendshape(Blendshape.eyeBlinkRight),
          },
        },
    ],
  };

  FaceSignals _signals(
    _Pose p,
    double Function(double) noise, {
    required bool arkit,
    required int id,
  }) {
    // The face box moves and narrows as the head turns.
    final yawRad = p.yaw * math.pi / 180;
    final width = .3 * (.75 + .25 * math.cos(yawRad)) + noise(.004);
    final box = FaceBox(
      left: .5 - p.yaw * .004 + noise(.004) - width / 2,
      top: .45 + p.pitch * .003 + noise(.004) - .2,
      width: width,
      height: .4 + noise(.004),
    );
    double clamp01(double v) => v.clamp(0.0, 1.0).toDouble();
    // The lid follows the eye down: about 0.035 openness per degree below 5°.
    final lidDrop = p.eyeDown > 5 ? (p.eyeDown - 5) * .035 : 0.0;
    var open = math.min(p.lid, .9 - lidDrop);
    // One scene for both engines in the comparison mode: ML Kit is assumed
    // to keep the lid above T in a squint or yawn (see [SyntheticStyle]).
    if (!arkit && _dual && p.squint >= .55) open = math.max(open, .5);
    final closed = open < .2;
    final yaw = roadYaw + p.yaw + noise(.6);
    final pitch = roadPitch + p.pitch + noise(.6);
    final roll = 1 + p.roll + noise(.5);
    final left = clamp01(open + noise(arkit ? .02 : .05));
    final right = clamp01(open + noise(arkit ? .02 : .05));
    if (!arkit) {
      return FaceSignals(
        engineId: arkit
            ? SyntheticStyle.arkit.engineId
            : SyntheticStyle.mlKit.engineId,
        trackingId: id,
        headYawLeft: yaw,
        box: box,
        headPitchDown: pitch,
        headRollRight: roll,
        eyeOpenLeft: left,
        eyeOpenRight: right,
      );
    }
    // ARKit artefact modelled on purpose: with closed lids the eye transforms
    // and eyeLookDown drift down, so "looking down" alone must not hide a
    // closure.
    final eyeDown = p.eyeDown + (closed ? 10 : 0) + noise(1);
    final eyeLeft = p.eyeLeft + noise(1);
    final lookDown = clamp01(eyeDown / 30 + (closed ? .4 : 0));
    return FaceSignals(
      engineId: arkit
          ? SyntheticStyle.arkit.engineId
          : SyntheticStyle.mlKit.engineId,
      trackingId: id,
      headYawLeft: yaw,
      box: box,
      headPitchDown: pitch,
      headRollRight: roll,
      gazeLeft: yaw + eyeLeft,
      gazeDown: pitch + eyeDown,
      eyeGazeLeft: eyeLeft,
      eyeGazeDown: eyeDown,
      eyeOpenLeft: left,
      eyeOpenRight: right,
      distanceM: .55 + noise(.01),
      blendshapes: {
        Blendshape.eyeBlinkLeft: 1 - left,
        Blendshape.eyeBlinkRight: 1 - right,
        Blendshape.eyeLookDownLeft: lookDown,
        Blendshape.eyeLookDownRight: lookDown,
        Blendshape.eyeLookUpLeft: clamp01(-eyeDown / 25),
        Blendshape.eyeLookUpRight: clamp01(-eyeDown / 25),
        Blendshape.eyeLookOutLeft: clamp01(eyeLeft / 30),
        Blendshape.eyeLookInRight: clamp01(eyeLeft / 30),
        Blendshape.eyeLookInLeft: clamp01(-eyeLeft / 30),
        Blendshape.eyeLookOutRight: clamp01(-eyeLeft / 30),
        Blendshape.eyeSquintLeft: clamp01(p.squint + noise(.03)),
        Blendshape.eyeSquintRight: clamp01(p.squint + noise(.03)),
        Blendshape.jawOpen: clamp01(p.jaw + noise(.02)),
      },
    );
  }
}

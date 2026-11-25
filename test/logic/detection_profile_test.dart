import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/detection_profile.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/mount.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/logic/synthetic.dart';
import 'package:nscontrol/logic/tune.dart';

const arkitId = 'arkit_face_tracking';

CalibrationProfile calibration({double left = .9, double right = .8}) =>
    CalibrationProfile(
      trackingId: 1,
      detector: DetectorCapabilities.mlKit,
      hiddenEyes: false,
      neutralPitch: 0,
      neutralYaw: 0,
      neutralRoll: 0,
      leftEyeMedian: left,
      rightEyeMedian: right,
      eyeThreshold: .4,
    );

FaceSignals face({double open = .9, double jaw = 0}) => FaceSignals(
  engineId: arkitId,
  trackingId: 1,
  headYawLeft: 0,
  headPitchDown: 0,
  headRollRight: 0,
  eyeGazeLeft: 0,
  eyeGazeDown: 0,
  eyeOpenLeft: open,
  eyeOpenRight: open,
  blendshapes: {Blendshape.jawOpen: jaw},
);

FaceMeasurement measurement({double eye = .8}) => FaceMeasurement(
  trackingId: 1,
  leftEye: eye,
  rightEye: eye,
  pitchDown: 0,
  yaw: 0,
  roll: 0,
);

void main() {
  group('detection profile', () {
    test('ТЗ 2.2 reference keeps the ТЗ numbers', () {
      const p = DetectionProfile.tz22;
      final a = p.algorithm(hiddenEyes: false);
      expect(a.eyesClosedUs, 1500000);
      expect(a.headDownUs, 2000000);
      expect(a.pitchThreshold, 20);
      expect(a.headYawLimit, 30);
      expect(a.maximumGapUs, 300000);
      expect(p.attention.isAcceptance, isTrue);
      expect(p.eyeRule(arkitId), (.5, .4));
      expect(p.label, 'ТЗ 2.2 (эталон)');
    });

    test('json round trip', () {
      for (final p in DetectionProfile.all) {
        expect(DetectionProfile.fromJson(p.toJson()).toJson(), p.toJson());
      }
    });

    test('a fixed T in engine units', () {
      const p = DetectionProfile(id: 't', eyeThresholds: {arkitId: .25});
      final (share, cap) = p.eyeRule(arkitId);
      final c = calibration().withEyeRule(share: share, cap: cap);
      expect(c.eyeThreshold, .25);
      expect(CalibrationProfile.fromJson(c.toJson()).eyeThreshold, .25);
      // Other engines keep the ТЗ rule.
      expect(p.eyeRule('mlkit_face_detection'), (.5, .4));
    });

    test('the calibration still checks T against its rule', () {
      expect(
        () => CalibrationProfile(
          trackingId: 1,
          detector: DetectorCapabilities.mlKit,
          hiddenEyes: false,
          neutralPitch: 0,
          neutralYaw: 0,
          neutralRoll: 0,
          leftEyeMedian: .9,
          rightEyeMedian: .9,
          eyeThreshold: .25,
        ),
        throwsArgumentError,
      );
    });

    test('the eye view limit by engine', () {
      const p = DetectionProfile(id: 't', eyeYawLimits: {arkitId: 50});
      const arkit = DetectorCapabilities(
        id: arkitId,
        version: 'x',
        eyeYawLimit: 25,
      );
      expect(p.detector(arkit).eyeYawLimit, 50);
      expect(p.detector(DetectorCapabilities.mlKit).eyeYawLimit, 18);
    });
  });

  group('gap tolerance', () {
    ObservationEngine engine(int gapUs) => ObservationEngine(
      sessionId: 's',
      calibration: calibration(left: .9, right: .9),
      settings: AlgorithmSettings(maximumGapUs: gapUs),
    );

    List<String> closure(ObservationEngine e) {
      final events = <String>[];
      void at(int t) => events.addAll(
        e
            .process(
              sessionId: 's',
              capturedUs: t,
              completedUs: t,
              faces: [measurement(eye: .1)],
            )
            .started
            .map((x) => x.type.code),
      );
      for (var t = 0; t <= 700000; t += 100000) {
        at(t);
      }
      // The camera pauses 0.5 s (after a voice prompt in the lab).
      for (var t = 1200000; t <= 3500000; t += 100000) {
        at(t);
      }
      return events;
    }

    test('ТЗ 2.2: a 0.5 s pause resets the closure', () {
      final e = engine(300000);
      expect(closure(e), ['eyes_closed']);
      // Found only 1.5 s after the pause, not 1.5 s after the closure.
    });

    test('a 600 ms tolerance keeps the closure through the pause', () {
      final strict = engine(300000), tolerant = engine(600000);
      closure(strict);
      closure(tolerant);
      expect(
        tolerant.snapshot.eyes.activeEvent!.thresholdUs,
        lessThan(strict.snapshot.eyes.activeEvent!.thresholdUs),
      );
    });

    test('the tolerance is checked', () {
      expect(
        () => AlgorithmSettings(maximumGapUs: 1000000),
        throwsArgumentError,
      );
      expect(
        AlgorithmSettings.fromJson(
          AlgorithmSettings(maximumGapUs: 600000).toJson(),
        ).maximumGapUs,
        600000,
      );
    });
  });

  group('yawn gate', () {
    EyeGateReason run(EyeGate gate, List<FaceSignals> frames) {
      var last = EyeGateReason.none;
      for (var i = 0; i < frames.length; i++) {
        last = gate.evaluate(
          face: frames[i],
          zone: GazeZone.road,
          threshold: .4,
          headOnly: false,
          atUs: i * 33000,
        );
      }
      return last;
    }

    test('narrowed lids with the mouth wide open are a yawn', () {
      expect(
        run(EyeGate(yawnJaw: .4), [
          face(),
          face(jaw: .5, open: .7),
          face(jaw: .8, open: .3),
          face(jaw: .85, open: .25),
        ]),
        EyeGateReason.yawn,
      );
    });

    test('a deep closure counts with the mouth open', () {
      expect(
        run(EyeGate(yawnJaw: .4), [
          face(jaw: .8, open: .3),
          face(jaw: .8, open: .05),
        ]),
        EyeGateReason.none,
      );
    });

    test('off by default', () {
      expect(run(EyeGate(), [face(jaw: .8, open: .3)]), EyeGateReason.none);
    });

    test('held a little after the jaw closes', () {
      final gate = EyeGate(yawnJaw: .4);
      final frames = [face(jaw: .8, open: .3), face(jaw: .1, open: .3)];
      expect(run(gate, frames), EyeGateReason.yawn);
      expect(
        gate.evaluate(
          face: face(jaw: .1, open: .3),
          zone: GazeZone.road,
          threshold: .4,
          headOnly: false,
          atUs: 1000000,
        ),
        EyeGateReason.none,
      );
    });
  });

  group('road adaptation', () {
    test('follows a slow drift at the set rate, up to the cap', () {
      final a = RoadAdaptation(degPerMin: 1);
      // The driver sits 5° lower than at calibration for 10 minutes.
      for (var t = 0; t <= 600000000; t += 100000) {
        a.observe(t, a.apply((0, 5, 0)));
      }
      expect(a.pitch, closeTo(5, .2));
      final b = RoadAdaptation(degPerMin: 1);
      for (var t = 0; t <= 120000000; t += 100000) {
        b.observe(t, b.apply((0, 5, 0)));
      }
      // Two minutes, the first 30 s only collect: at most 1.5°.
      expect(b.pitch, inInclusiveRange(1, 1.6));
    });

    test('a drift past the cap is reported', () {
      final a = RoadAdaptation(degPerMin: 3);
      // The posture creeps 1°/min upward for 20 min: the cap is 10°.
      for (var t = 0; t <= 1200000000; t += 100000) {
        final drift = -t / 60e6;
        a.observe(t, a.apply((0, drift, 0)));
        if (t == 300000000) expect(a.atLimit, isFalse);
      }
      expect(a.pitch, -10);
      expect(a.atLimit, isTrue);
      expect(a.atLimitSinceUs, lessThan(1200000000));
    });

    test('a lowered head does not pull the road pose', () {
      final a = RoadAdaptation(degPerMin: 1);
      for (var t = 0; t <= 300000000; t += 100000) {
        a.observe(t, a.apply((0, 18, 0)));
      }
      expect(a.pitch, 0);
    });

    test('head zones follow the drift too', () {
      final map = ZoneMap.fromCalibration(calibration(), mountRelative: true);
      const s = FaceSignals(
        engineId: 'mlkit_face_detection',
        trackingId: 1,
        headYawLeft: 0,
        headPitchDown: -10,
        headRollRight: 0,
        eyeOpenLeft: .9,
        eyeOpenRight: .9,
      );
      // The driver sits 10° higher than at calibration: off the road...
      expect(map.classify(map.directionOf(s)!), isNot(GazeZone.road));
      // ...until the road pose has followed the posture.
      final a = RoadAdaptation(degPerMin: 1)..pitch = -8;
      expect(map.classify(map.directionOf(s, adaptation: a)!), GazeZone.road);
    });

    test('the correction is applied as a rotation', () {
      final a = RoadAdaptation(degPerMin: 1)..pitch = 5;
      final (y, p, r) = a.apply((0, 20, 0));
      expect(p, closeTo(15, 1e-9));
      expect(y.abs(), lessThan(1e-9));
      expect(r.abs(), lessThan(1e-9));
    });
  });

  group('tune', () {
    TunePoint point(List<int> c, {required bool ok}) {
      final m = TuneMetrics(const DetectionProfile(id: 'x'))
        ..expected['head_pitch_down'] = 3
        ..found['head_pitch_down'] = ok ? 3 : 1;
      return TunePoint(c, m);
    }

    test('margin counts grid steps to a failing point or the edge', () {
      final points = [
        for (var i = 0; i < 7; i++) point([0, i], ok: i >= 2),
      ];
      final s = TuneSweep(
        type: 'head_pitch_down',
        axes: const ['c', 'x'],
        points: points,
        targets: const TuneTargets(),
        sizes: const [1, 7],
        reference: const [0, 6],
        categorical: const {0},
      );
      expect([for (final p in points) p.margin], [0, 0, 1, 2, 3, 2, 1]);
      expect(s.best!.coordinates, [0, 4]);
    });

    test('a mechanism beyond the ТЗ only when needed', () {
      final points = [
        // Without it: feasible with margin 2 at the middle.
        for (var i = 0; i < 5; i++) point([0, i], ok: true),
        // With it: everything passes, more room.
        for (var i = 0; i < 9; i++) point([1, i], ok: true),
      ];
      final s = TuneSweep(
        type: 'head_pitch_down',
        axes: const ['mechanism', 'x'],
        points: points,
        targets: const TuneTargets(),
        sizes: const [2, 9],
        reference: const [0, 2],
        categorical: const {0},
      );
      expect(s.best!.coordinates[0], 0);
    });

    test('synthetic ARKit at the side mount meets the targets with v1', () {
      final recording = Recording.parse(
        SyntheticScenario(
          SyntheticStyle.arkit,
          mountYaw: -30,
          arkitEyeYawLimit: 50,
        ).toJsonl(),
      );
      final m = evaluate(DetectionProfile.v1, [TuneSample(recording, arkitId)]);
      expect(m.recall('eyes_closed'), 1);
      expect(m.recall('head_pitch_down'), 1);
      expect(m.falseAlarms, isEmpty);
    });
  });
}

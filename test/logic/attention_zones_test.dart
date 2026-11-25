import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/domain.dart';

final profile = CalibrationProfile(
  trackingId: 1,
  detector: DetectorCapabilities.mlKit,
  hiddenEyes: false,
  neutralPitch: -3,
  neutralYaw: 4,
  neutralRoll: 1,
  leftEyeMedian: .9,
  rightEyeMedian: .9,
  eyeThreshold: .4,
);

/// ARKit-like face: head angles relative to the road plus eye-in-head angles.
FaceSignals arkit({
  double yaw = 0,
  double pitch = 0,
  double eyeLeft = 0,
  double eyeDown = 0,
  double open = .9,
  double squint = 0,
  double? lookDown,
  bool tracked = true,
}) => FaceSignals(
  engineId: 'arkit_face_tracking',
  trackingId: 1,
  tracked: tracked,
  headYawLeft: 4 + yaw,
  headPitchDown: -3 + pitch,
  headRollRight: 1,
  gazeLeft: 4 + yaw + eyeLeft,
  gazeDown: -3 + pitch + eyeDown,
  eyeGazeLeft: eyeLeft,
  eyeGazeDown: eyeDown,
  eyeOpenLeft: open,
  eyeOpenRight: open,
  blendshapes: {
    Blendshape.eyeBlinkLeft: 1 - open,
    Blendshape.eyeBlinkRight: 1 - open,
    Blendshape.eyeLookDownLeft: lookDown ?? (eyeDown / 30).clamp(0, 1),
    Blendshape.eyeLookDownRight: lookDown ?? (eyeDown / 30).clamp(0, 1),
    Blendshape.eyeSquintLeft: squint,
    Blendshape.eyeSquintRight: squint,
  },
);

FaceSignals mlkit({double yaw = 0, double pitch = 0, double open = .9}) =>
    FaceSignals(
      engineId: 'mlkit_face_detection',
      trackingId: 1,
      headYawLeft: 4 + yaw,
      headPitchDown: -3 + pitch,
      headRollRight: 1,
      eyeOpenLeft: open,
      eyeOpenRight: open,
    );

void main() {
  group('zones', () {
    final map = ZoneMap.fromCalibration(profile);
    GazeZone zoneOf(FaceSignals s) => map.classify(map.directionOf(s)!);

    test('default gaze sectors', () {
      expect(zoneOf(arkit()), GazeZone.road);
      expect(zoneOf(arkit(yaw: 20, eyeLeft: 16)), GazeZone.mirrorLeft);
      expect(zoneOf(arkit(yaw: -32, eyeLeft: -20)), GazeZone.mirrorRight);
      expect(
        zoneOf(arkit(yaw: -14, pitch: -6, eyeLeft: -12, eyeDown: -8)),
        GazeZone.mirrorRear,
      );
      expect(zoneOf(arkit(pitch: 6, eyeDown: 20)), GazeZone.instruments);
      expect(
        zoneOf(arkit(yaw: -18, pitch: 15, eyeLeft: -10, eyeDown: 18)),
        GazeZone.console,
      );
      expect(zoneOf(arkit(yaw: 60, eyeLeft: 15)), GazeZone.offCamera);
    });

    test('head-only sectors for engines without gaze', () {
      expect(zoneOf(mlkit()), GazeZone.road);
      expect(zoneOf(mlkit(yaw: 22)), GazeZone.mirrorLeft);
      expect(zoneOf(mlkit(yaw: -35)), GazeZone.mirrorRight);
      expect(zoneOf(mlkit(yaw: -16, pitch: -7)), GazeZone.mirrorRear);
      expect(zoneOf(mlkit(pitch: 12)), GazeZone.instruments);
      expect(zoneOf(mlkit(yaw: 55)), GazeZone.offCamera);
      expect(map.directionOf(mlkit())!.fromGaze, isFalse);
    });

    test('off the road between sectors is never the road', () {
      // Far up: nearest non-road zone, not road.
      expect(zoneOf(arkit(pitch: -25, eyeDown: -10)), isNot(GazeZone.road));
    });

    test('json round trip', () {
      final back = ZoneMap.fromJson(map.toJson());
      expect(back.toJson(), map.toJson());
      expect(
        () => ZoneRegion.fromJson({
          'zone': 'road',
          'left': 0,
          'down': 0,
          'radiusLeft': 0,
          'radiusDown': 1,
        }),
        throwsFormatException,
      );
    });
  });

  group('zone tracker', () {
    test('one noisy frame does not change the zone; a held glance does', () {
      final t = GazeZoneTracker(ZoneMap.fromCalibration(profile));
      var us = 0;
      GazeZone step(FaceSignals? s) => t.update(us += 33000, s);
      for (var i = 0; i < 10; i++) {
        step(arkit());
      }
      expect(step(arkit(yaw: 20, eyeLeft: 16)), GazeZone.road);
      expect(step(arkit()), GazeZone.road);
      for (var i = 0; i < 5; i++) {
        step(arkit(yaw: 20, eyeLeft: 16));
      }
      expect(step(arkit(yaw: 20, eyeLeft: 16)), GazeZone.mirrorLeft);
      expect(t.sinceUs, lessThan(us));
    });

    test('hysteresis keeps the zone at the border', () {
      final t = GazeZoneTracker(ZoneMap.fromCalibration(profile));
      var us = 0;
      for (var i = 0; i < 10; i++) {
        t.update(us += 33000, arkit(yaw: 20, eyeLeft: 16));
      }
      // 25° is outside the left-mirror region but inside its sticky border.
      for (var i = 0; i < 10; i++) {
        expect(
          t.update(us += 33000, arkit(yaw: 15, eyeLeft: 10)),
          GazeZone.mirrorLeft,
        );
      }
    });

    test('short tracking loss keeps the zone, a long one becomes unknown', () {
      final t = GazeZoneTracker(ZoneMap.fromCalibration(profile));
      var us = 0;
      for (var i = 0; i < 10; i++) {
        t.update(us += 33000, arkit());
      }
      for (var i = 0; i < 20; i++) {
        expect(t.update(us += 33000, null), GazeZone.road);
      }
      for (var i = 0; i < 20; i++) {
        t.update(us += 33000, null);
      }
      expect(t.zone, GazeZone.unknown);
    });

    test('face lost while turned far is a look over the shoulder', () {
      final t = GazeZoneTracker(ZoneMap.fromCalibration(profile));
      var us = 0;
      for (var i = 0; i < 10; i++) {
        t.update(us += 33000, arkit());
      }
      t.update(us += 33000, arkit(yaw: 45, eyeLeft: 10));
      for (var i = 0; i < 60; i++) {
        t.update(us += 33000, null);
      }
      expect(t.zone, GazeZone.offCamera);
      // An untracked face counts as lost.
      expect(t.update(us += 33000, arkit(tracked: false)), GazeZone.offCamera);
    });
  });

  group('mirror calibration', () {
    test('measured glances replace the default sectors', () {
      final base = ZoneMap.fromCalibration(profile);
      final c = ZoneCalibrationCollector(base);
      var us = 0;
      c.begin(GazeZone.mirrorLeft, us);
      for (var i = 0; i < 60; i++) {
        c.add(us += 33000, arkit(yaw: 30, eyeLeft: 25 + (i % 3)));
      }
      expect(c.end(us), isNull);
      c.begin(GazeZone.mirrorRight, us);
      for (var i = 0; i < 5; i++) {
        c.add(us += 33000, arkit(yaw: -40));
      }
      expect(c.end(us), isNotNull, reason: 'too short');
      expect(() => c.begin(GazeZone.road, us), throwsArgumentError);
      final map = c.finish();
      expect(map.mirrorsCalibrated, isTrue);
      final left = map.gazeRegions.firstWhere(
        (r) => r.zone == GazeZone.mirrorLeft,
      );
      expect(left.left, closeTo(56, 1));
      expect(left.radiusLeft, ZoneCalibrationCollector.minimumRadius);
      expect(
        map.classify(map.directionOf(arkit(yaw: 30, eyeLeft: 26))!),
        GazeZone.mirrorLeft,
      );
      // The right mirror failed and keeps its default sector.
      expect(
        map.gazeRegions.firstWhere((r) => r.zone == GazeZone.mirrorRight).left,
        -52,
      );
      expect(ZoneMap.fromJson(map.toJson()).toJson(), map.toJson());
    });
  });

  group('eye gate', () {
    EyeGateReason run(
      EyeGate gate,
      List<FaceSignals> frames, {
      bool headOnly = false,
    }) {
      var last = EyeGateReason.none;
      final map = ZoneMap.fromCalibration(profile);
      for (final f in frames) {
        last = gate.evaluate(
          face: f,
          zone: map.classify(map.directionOf(f)!),
          threshold: .4,
          headOnly: headOnly,
        );
      }
      return last;
    }

    test('lowered lid while looking down does not count', () {
      final gate = EyeGate();
      expect(
        run(gate, [
          arkit(),
          arkit(eyeDown: 12, open: .7),
          arkit(pitch: 6, eyeDown: 20, open: .35),
          arkit(pitch: 6, eyeDown: 20, open: .3),
        ]),
        EyeGateReason.lookDown,
      );
    });

    test('a closure that starts on the road is never hidden', () {
      // The engine reports closed eyes as looking down (ARKit artefact).
      expect(
        run(EyeGate(), [
          arkit(),
          arkit(open: .3, eyeDown: 15, lookDown: .8),
          arkit(open: .25, eyeDown: 15, lookDown: .8),
        ]),
        EyeGateReason.none,
      );
    });

    test('a deep closure counts even while looking down', () {
      expect(
        run(EyeGate(), [
          arkit(eyeDown: 15, open: .8),
          arkit(pitch: 6, eyeDown: 20, open: .3),
          arkit(pitch: 6, eyeDown: 25, open: .05),
        ]),
        EyeGateReason.none,
      );
    });

    test('looking back up disarms the gate', () {
      final gate = EyeGate();
      run(gate, [arkit(eyeDown: 15, open: .8), arkit(eyeDown: 20, open: .3)]);
      expect(run(gate, [arkit(), arkit(open: .3)]), EyeGateReason.none);
    });

    test('squint', () {
      expect(
        run(EyeGate(), [arkit(open: .3, squint: .7)]),
        EyeGateReason.squint,
      );
      expect(
        run(EyeGate(), [arkit(open: .05, squint: .7)]),
        EyeGateReason.none,
      );
    });

    test('squint has hysteresis: on at 0.45, off below 0.35', () {
      final gate = EyeGate();
      EyeGateReason step(double squint) => gate.evaluate(
        face: arkit(open: .3, squint: squint),
        zone: GazeZone.road,
        threshold: .4,
        headOnly: false,
      );
      expect(step(.42), EyeGateReason.none);
      expect(step(.45), EyeGateReason.squint);
      expect(step(.36), EyeGateReason.squint);
      expect(step(.34), EyeGateReason.none);
      expect(step(.42), EyeGateReason.none);
    });

    test(
      'looking down has hysteresis: on at 12° or 0.35, off below 9° and 0.25',
      () {
        final gate = EyeGate();
        EyeGateReason step(double eyeDown, double lookDown, double open) =>
            gate.evaluate(
              face: arkit(eyeDown: eyeDown, lookDown: lookDown, open: open),
              zone: GazeZone.road,
              threshold: .4,
              headOnly: false,
            );
        step(11, .2, .8);
        expect(step(11, .2, .3), EyeGateReason.none, reason: 'not on yet');
        step(12, .2, .8);
        expect(step(9.5, .2, .3), EyeGateReason.lookDown);
        expect(step(8, .3, .3), EyeGateReason.lookDown, reason: 'blend ≥ 0.25');
        expect(step(8, .2, .3), EyeGateReason.none);
        step(5, .36, .8);
        expect(step(5, .26, .3), EyeGateReason.lookDown);
      },
    );

    test('engines without gaze need the head-only flag', () {
      final frames = [mlkit(pitch: 12, open: .8), mlkit(pitch: 12, open: .3)];
      expect(run(EyeGate(), frames), EyeGateReason.none);
      expect(run(EyeGate(), frames, headOnly: true), EyeGateReason.lookDown);
    });
  });

  group('closure latch', () {
    /// 1 s on the road, then [frames] frames of [closure] (ARKit-like: the
    /// engine also reports the closed eye as looking down). Returns the first
    /// event and whether an active event was cut.
    ({ObservationEvent? event, int closedAtUs, bool cut}) run(
      EyeGate gate,
      FaceSignals Function(int i) closure, {
      int frames = 75,
    }) {
      final engine = ObservationEngine(sessionId: 's', calibration: profile);
      final p = AttentionPipeline(
        calibration: profile,
        settings: AttentionSettings.lab,
        eyeGate: gate,
      );
      var us = 0;
      var eyesEvent = false, cut = false, closing = false;
      ObservationEvent? event;
      void frame(FaceSignals f) {
        us += 33333;
        final u = engine.process(
          sessionId: 's',
          capturedUs: us,
          completedUs: us + 20000,
          faces: p.process(us, [f], eyesEventActive: eyesEvent).measurements,
        );
        if (u.started.isNotEmpty) event ??= u.started.first;
        if (u.ended.isNotEmpty && closing) cut = true;
        eyesEvent = u.snapshot.eyes.activeEvent != null;
      }

      for (var i = 0; i < 30; i++) {
        frame(arkit());
      }
      final closedAt = us + 33333;
      closing = true;
      for (var i = 0; i < frames; i++) {
        frame(closure(i));
      }
      closing = false;
      for (var i = 0; i < 15; i++) {
        frame(arkit());
      }
      return (event: event, closedAtUs: closedAt, cut: cut);
    }

    /// eyeSquint jumping between 0.42 and 0.5, as in laughter.
    double jumping(int i) => i % 3 == 2 ? .5 : .42;

    /// Closed-eye artefact: the eye "looks down" more and more.
    FaceSignals closed(int i, {required double open, required double squint}) =>
        arkit(
          open: open,
          squint: squint,
          eyeDown: i < 15 ? i.toDouble() : 15,
          lookDown: (.3 + i * .01).clamp(0, .8).toDouble(),
        );

    test('laughter: 3 s at openness 0.25 with a jumping squint, no event', () {
      final r = run(
        EyeGate(),
        (i) => arkit(open: .25, squint: jumping(i)),
        frames: 90,
      );
      expect(r.event, isNull);
    });

    test('a real closure with the same jumping squint is found', () {
      final r = run(
        EyeGate(),
        (i) => closed(i, open: i.isEven ? .05 : .1, squint: jumping(i)),
      );
      expect(r.event?.type, EventType.eyesClosed);
      expect(
        r.event!.thresholdUs - r.closedAtUs,
        inInclusiveRange(1500000, 1700000),
      );
      expect(r.cut, isFalse, reason: 'the active event must not be cut');
    });

    // A closure that starts without a squint and is then joined by one
    // (lids squeezed): latched after 100 ms, the squint changes nothing.
    FaceSignals squeezed(int i) =>
        closed(i, open: i.isEven ? .2 : .3, squint: i < 5 ? .3 : jumping(i));

    test('a latched closure is not reset by a squint joining it', () {
      final r = run(EyeGate(), squeezed);
      expect(r.event?.type, EventType.eyesClosed);
      expect(
        r.event!.thresholdUs - r.closedAtUs,
        inInclusiveRange(1500000, 1700000),
      );
      expect(r.cut, isFalse);
    });

    test('without the latch the same closure would be lost', () {
      expect(run(EyeGate(latchUs: 1 << 40), squeezed).event, isNull);
    });

    test('ungated frames latch only when they last 100 ms in a row', () {
      final gate = EyeGate();
      var us = 0;
      void step(double squint) {
        us += 33333;
        gate.evaluate(
          face: arkit(open: .3, squint: squint),
          zone: GazeZone.road,
          threshold: .4,
          headOnly: false,
          atUs: us,
        );
      }

      // Two ungated frames, a squint, two more, a squint, ... never 100 ms.
      for (var i = 0; i < 30; i++) {
        step(i % 3 == 2 ? .5 : .3);
      }
      expect(gate.latched, isFalse);
      for (var i = 0; i < 4; i++) {
        step(.3);
      }
      expect(gate.latched, isFalse, reason: '99.9 ms');
      step(.3);
      expect(gate.latched, isTrue);
    });

    test('the latch releases when both eyes are open again', () {
      final gate = EyeGate();
      var us = 0;
      EyeGateReason step(FaceSignals f) {
        us += 33333;
        return gate.evaluate(
          face: f,
          zone: GazeZone.road,
          threshold: .4,
          headOnly: false,
          atUs: us,
        );
      }

      for (var i = 0; i < 6; i++) {
        step(arkit(open: .3, squint: i < 5 ? .3 : .5));
      }
      expect(gate.latched, isTrue);
      expect(step(arkit(open: .3, squint: .7)), EyeGateReason.none);
      step(arkit());
      expect(gate.latched, isFalse);
      expect(step(arkit(open: .3, squint: .7)), EyeGateReason.squint);
    });

    test('an active eyes event latches at once', () {
      final gate = EyeGate();
      final map = ZoneMap.fromCalibration(profile);
      final f = arkit(open: .3, squint: .7);
      expect(
        gate.evaluate(
          face: f,
          zone: map.classify(map.directionOf(f)!),
          threshold: .4,
          headOnly: false,
          eyesEventActive: true,
        ),
        EyeGateReason.none,
      );
    });
  });

  group('pipeline', () {
    test('acceptance passes exactly the ТЗ measurement', () {
      final p = AttentionPipeline(calibration: profile);
      expect(const AttentionSettings.acceptance().isAcceptance, isTrue);
      var us = 0;
      for (final f in [
        mlkit(),
        mlkit(pitch: 12, open: .3),
        arkit(pitch: 6, eyeDown: 20, open: .3),
        arkit(open: .3, squint: .7),
      ]) {
        final m = p.process(us += 33000, [f]).measurements.single;
        final expected = f.toMeasurement();
        expect(
          [m.trackingId, m.leftEye, m.rightEye, m.pitchDown, m.yaw, m.roll],
          [
            expected.trackingId,
            expected.leftEye,
            expected.rightEye,
            expected.pitchDown,
            expected.yaw,
            expected.roll,
          ],
        );
      }
      expect(p.attention.distraction, isNull);
    });

    test('ML Kit signals pass unchanged even with the lab extensions', () {
      final p = AttentionPipeline(
        calibration: profile,
        settings: AttentionSettings.lab,
      );
      var us = 0;
      for (var i = 0; i < 30; i++) {
        final f = mlkit(pitch: 12, open: i.isEven ? .3 : .8);
        final m = p.process(us += 66000, [f]).measurements.single;
        expect(m.leftEye, f.eyeOpenLeft);
      }
    });

    test('gated frame withholds only the eyes', () {
      final p = AttentionPipeline(
        calibration: profile,
        settings: AttentionSettings.lab,
      );
      var us = 0;
      p.process(us += 33000, [arkit(eyeDown: 14, open: .7)]);
      final frame = p.process(us += 33000, [
        arkit(pitch: 6, eyeDown: 20, open: .3),
      ]);
      final m = frame.measurements.single;
      expect(frame.state.eyeGate, EyeGateReason.lookDown);
      expect(m.hasEyes, isFalse);
      expect(m.hasHeadAngles, isTrue);
      expect(m.trackingId, 1);
      expect(frame.state.toJson()['eyeGate'], 'look_down');
    });

    test('the provider takes every face and gives every measurement', () {
      final provider = ZoneAttentionProvider()..reset(profile);
      final engine = ObservationEngine(sessionId: 's', calibration: profile);
      var us = 0;
      void frame(List<FaceSignals> faces) {
        us += 33333;
        provider.updateFaces(faces, us);
        engine.process(
          sessionId: 's',
          capturedUs: us,
          completedUs: us + 20000,
          faces: provider.lastMeasurements,
        );
        provider.eyesEventActive = engine.snapshot.eyes.activeEvent != null;
      }

      for (var i = 0; i < 10; i++) {
        frame([arkit()]);
      }
      expect(provider.lastMeasurements, hasLength(1));
      expect(provider.lastMeasurement?.trackingId, 1);
      final passenger = FaceSignals(
        engineId: 'arkit_face_tracking',
        trackingId: 2,
        headYawLeft: 30,
        headPitchDown: 0,
        headRollRight: 0,
        eyeOpenLeft: .9,
        eyeOpenRight: .9,
      );
      frame([arkit(), passenger]);
      expect(provider.lastMeasurements, hasLength(2));
      expect(provider.lastMeasurement, isNull);
      expect(engine.snapshot.requiresRecalibration, isTrue);
      frame([]);
      expect(provider.lastMeasurements, isEmpty);
    });

    test('faces without an id inherit the calibrated id', () {
      final p = AttentionPipeline(calibration: profile);
      const f = FaceSignals(
        engineId: 'arkit_face_tracking',
        headYawLeft: 4,
        headPitchDown: -3,
        headRollRight: 1,
        eyeOpenLeft: .9,
        eyeOpenRight: .9,
      );
      expect(p.process(1000, [f]).measurements.single.trackingId, 1);
    });
  });

  group('distraction', () {
    test('3 s off the road starts one long-glance event', () {
      final m = DistractionMonitor();
      final started = <DistractionEvent>[];
      for (var us = 0; us <= 5000000; us += 100000) {
        final r = m.update(us, us < 1000000 ? GazeZone.road : GazeZone.console);
        if (r.started != null) started.add(r.started!);
      }
      expect(started, hasLength(1));
      expect(started.single.kind, DistractionKind.longGlance);
      expect(started.single.thresholdUs, 4000000);
      final end = m.update(5100000, GazeZone.road);
      expect(end.ended!.endedUs, 5100000);
      expect(m.active, isNull);
    });

    test('a mirror glance of 1 s and a sweep across the road do not', () {
      final m = DistractionMonitor();
      var us = 0;
      for (var i = 0; i < 25; i++) {
        expect(
          m
              .update(us += 100000, GazeZone.offCamera, raw: GazeZone.offCamera)
              .started,
          isNull,
        );
      }
      // The gaze crosses the road for one raw frame, then looks right.
      m.update(us += 100000, GazeZone.offCamera, raw: GazeZone.road);
      for (var i = 0; i < 25; i++) {
        expect(m.update(us += 100000, GazeZone.mirrorRight).started, isNull);
      }
    });

    test('10 s on the console within 30 s', () {
      final m = DistractionMonitor();
      DistractionEvent? event;
      var us = 0;
      for (var round = 0; round < 6 && event == null; round++) {
        for (var i = 0; i < 20 && event == null; i++) {
          event = m.update(us += 100000, GazeZone.console).started;
        }
        for (var i = 0; i < 10 && event == null; i++) {
          event = m.update(us += 100000, GazeZone.road).started;
        }
      }
      expect(event, isNotNull);
      expect(event!.kind, DistractionKind.cumulative);
    });

    test('mirrors do not add up to visual time sharing', () {
      final m = DistractionMonitor();
      var us = 0;
      for (var round = 0; round < 10; round++) {
        for (var i = 0; i < 20; i++) {
          expect(m.update(us += 100000, GazeZone.mirrorLeft).started, isNull);
        }
        for (var i = 0; i < 10; i++) {
          m.update(us += 100000, GazeZone.road);
        }
      }
    });

    test('the long-glance limit is set per zone', () {
      expect(DistractionMonitor().longFor(GazeZone.mirrorLeft), 3000000);
      final m = DistractionMonitor(
        longUsByZone: const {GazeZone.mirrorLeft: 6000000},
      );
      for (var us = 0; us <= 4000000; us += 100000) {
        expect(m.update(us, GazeZone.mirrorLeft).started, isNull);
      }
      m.update(4100000, GazeZone.road);
      DistractionEvent? event;
      for (var us = 4200000; us <= 8000000 && event == null; us += 100000) {
        event = m.update(us, GazeZone.console).started;
      }
      expect(event?.thresholdUs, 7200000);
    });

    test('a ТЗ sign has priority', () {
      final m = DistractionMonitor();
      for (var us = 0; us <= 5000000; us += 100000) {
        expect(
          m.update(us, GazeZone.instruments, suppress: true).started,
          isNull,
        );
      }
    });

    test('a short tracking loss inside a glance keeps the count', () {
      final p = AttentionPipeline(
        calibration: profile,
        settings: AttentionSettings.lab,
      );
      DistractionEvent? event;
      var us = 0;
      final console = arkit(yaw: -18, pitch: 15, eyeLeft: -10, eyeDown: 18);
      for (var i = 0; i < 60; i++) {
        final lost = i >= 40 && i < 50;
        event ??= p
            .process(us += 33333, lost ? [] : [console])
            .distractionStarted;
      }
      for (var i = 0; i < 40 && event == null; i++) {
        event = p.process(us += 33333, [console]).distractionStarted;
      }
      expect(event, isNotNull);
      expect(event!.thresholdUs - event.signStartedUs, 3000000);
      expect(event.signStartedUs, lessThan(400000));
    });
  });

  group('yawns', () {
    test('counted as information, level unchanged', () {
      final m = FatigueMonitor(
        eyeThreshold: .4,
        nodThreshold: 12,
        eyesEventUs: 1500000,
        headEventUs: 2000000,
      );
      var us = 0;
      void mouth(double jaw, int frames) {
        for (var i = 0; i < frames; i++) {
          m.addMouth(us += 100000, jaw);
          m.addEyes(us, .9, .9);
        }
      }

      mouth(.1, 10);
      mouth(.8, 25); // yawn, 2.5 s
      mouth(.1, 10);
      mouth(.6, 5); // short laugh, 0.5 s
      mouth(.1, 10);
      final s = m.snapshot(us);
      expect(s.yawns, 1);
      expect(s.signs, contains('Зевки за 5 мин: 1'));
      expect(s.toJson()['yawns_5m'], 1);
      expect(s.level, isNot(FatigueLevel.moderate));
      expect(s.level, isNot(FatigueLevel.high));
    });
  });
}

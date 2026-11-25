import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/attention_zones.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/driver_continuity.dart';

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

FaceSignals face(
  int? id, {
  double cx = .5,
  double width = .3,
  double? distance,
  bool box = true,
  double open = .9,
}) => FaceSignals(
  engineId: 'mlkit_face_detection',
  trackingId: id,
  headYawLeft: 4,
  headPitchDown: -3,
  headRollRight: 1,
  eyeOpenLeft: open,
  eyeOpenRight: open,
  distanceM: distance,
  box: box
      ? FaceBox(left: cx - width / 2, top: .25, width: width, height: .4)
      : null,
);

/// Runs [frames] (null = no face, list = faces) at 15 fps through the
/// pipeline and the ТЗ engine, like the trip will.
({ObservationEngine engine, AttentionPipeline pipeline, int us}) drive(
  List<List<FaceSignals>> frames, {
  int startUs = 0,
}) {
  final engine = ObservationEngine(sessionId: 's', calibration: profile);
  final pipeline = AttentionPipeline(calibration: profile);
  var us = startUs;
  for (final faces in frames) {
    us += 66667;
    engine.process(
      sessionId: 's',
      capturedUs: us,
      completedUs: us + 40000,
      faces: pipeline.process(us, faces).measurements,
    );
  }
  return (engine: engine, pipeline: pipeline, us: us);
}

List<List<FaceSignals>> repeat(int n, List<FaceSignals> faces) =>
    List.filled(n, faces);

void main() {
  test('a 1.5 s blind-spot check with a new ML Kit id continues', () {
    final r = drive([
      ...repeat(30, [face(1)]),
      ...repeat(23, []), // 1.5 s without a face
      ...repeat(30, [face(2, cx: .52)]),
    ]);
    expect(r.engine.snapshot.requiresRecalibration, isFalse);
    expect(r.engine.snapshot.eyes.available, isTrue);
    expect(r.engine.snapshot.head.available, isTrue);
    expect(r.pipeline.continuity.decision, ContinuityDecision.same);
  });

  test('the restored id stays restored and is reported once', () {
    final c = DriverContinuity(trackingId: 1);
    c.resolve(0, [face(1)]);
    c.resolve(100000, []);
    expect(c.resolve(1600000, [face(7)]).single.trackingId, 1);
    expect(c.decision, ContinuityDecision.restored);
    expect(c.resolve(1700000, [face(7)]).single.trackingId, 1);
    expect(c.decision, ContinuityDecision.same);
  });

  test('a second face suspends observation (ФТ-02)', () {
    final r = drive([
      ...repeat(30, [face(1)]),
      ...repeat(3, [face(1), face(5, cx: .8)]),
      ...repeat(10, [face(1)]),
    ]);
    expect(r.engine.snapshot.requiresRecalibration, isTrue);
  });

  test('another face after 30 s without a face suspends observation', () {
    final r = drive([
      ...repeat(30, [face(1)]),
      ...repeat(450, []), // 30 s
      ...repeat(10, [face(9)]),
    ]);
    expect(r.engine.snapshot.requiresRecalibration, isTrue);
    expect(r.pipeline.continuity.decision, ContinuityDecision.different);
  });

  test('a face elsewhere or of another size suspends observation', () {
    for (final other in [face(4, cx: .85), face(4, width: .15)]) {
      final r = drive([
        ...repeat(30, [face(1)]),
        ...repeat(10, []),
        ...repeat(10, [other]),
      ]);
      expect(r.engine.snapshot.requiresRecalibration, isTrue);
    }
  });

  test('distance decides for ARKit-like faces', () {
    final c = DriverContinuity(trackingId: 1);
    c.resolve(0, [face(null, box: false, distance: .55)]);
    c.resolve(100000, []);
    expect(
      c
          .resolve(1500000, [face(null, box: false, distance: .58)])
          .single
          .trackingId,
      1,
    );
    c.resolve(1600000, []);
    c.resolve(1700000, [face(null, box: false, distance: .9)]);
    expect(c.decision, ContinuityDecision.different);
  });

  test('without any geometry only a short loss is taken back', () {
    final c = DriverContinuity(trackingId: 1);
    c.resolve(0, [face(1, box: false)]);
    c.resolve(100000, []);
    expect(c.resolve(2000000, [face(2, box: false)]).single.trackingId, 1);
    c.resolve(2100000, []);
    c.resolve(5500000, [face(3, box: false)]);
    expect(c.decision, ContinuityDecision.different);
  });

  test('with geometry the loss may last up to 5 s, not longer', () {
    final c = DriverContinuity(trackingId: 1);
    c.resolve(0, [face(1)]);
    c.resolve(100000, []);
    expect(c.resolve(4900000, [face(2)]).single.trackingId, 1);
    c.resolve(5000000, []);
    c.resolve(10100000, [face(3)]);
    expect(c.decision, ContinuityDecision.different);
  });

  group('replacement of the participant (ПМИ)', () {
    test('leaving through the frame edge is not taken back after 2 s', () {
      final r = drive([
        ...repeat(30, [face(1)]),
        // The participant slides out to the left until the box crosses it.
        for (var i = 1; i <= 10; i++) [face(1, cx: .5 - i * .04)],
        ...repeat(30, []), // 2 s: the other participant sits down
        ...repeat(15, [face(2)]),
      ]);
      expect(r.pipeline.continuity.decision, ContinuityDecision.different);
      expect(r.engine.snapshot.requiresRecalibration, isTrue);
    });

    test('a hand over the face for 2 s, no second face: continues', () {
      final r = drive([
        ...repeat(30, [face(1)]),
        ...repeat(30, []),
        ...repeat(15, [face(2, cx: .48)]),
      ]);
      expect(r.pipeline.continuity.decision, ContinuityDecision.same);
      expect(r.engine.snapshot.requiresRecalibration, isFalse);
      expect(r.engine.snapshot.eyes.available, isTrue);
    });

    test('a second face stays while the selected one is covered: pause', () {
      final r = drive([
        ...repeat(30, [face(1)]),
        ...repeat(15, [face(1), face(5, cx: .82, width: .25)]),
        ...repeat(30, [face(5, cx: .82, width: .25)]),
      ]);
      expect(r.pipeline.continuity.decision, ContinuityDecision.different);
      expect(r.engine.snapshot.requiresRecalibration, isTrue);
    });

    test('the edge rule needs the box to reach the edge', () {
      final c = DriverContinuity(trackingId: 1);
      c.resolve(0, [face(1, cx: .2)]); // left edge at 0.05
      c.resolve(100000, []);
      expect(c.leftFrame, isFalse);
      expect(c.resolve(2000000, [face(2, cx: .22)]).single.trackingId, 1);
      c.resolve(2100000, [face(2, cx: .16)]); // left edge at 0.01
      c.resolve(2200000, []);
      expect(c.leftFrame, isTrue);
      c.resolve(3000000, [face(3, cx: .16)]);
      expect(c.decision, ContinuityDecision.different);
    });
  });

  group('reference from calibration', () {
    test('a face lost right after calibration comes back restored', () {
      final provider = ZoneAttentionProvider()..reset(profile);
      provider.anchorDriver(face(1), 10000000);
      provider.updateFaces([], 10066667);
      provider.updateFaces([], 12000000); // 2 s without a face
      provider.updateFaces([face(2, cx: .52)], 12066667);
      expect(
        provider.pipeline!.continuity.decision,
        ContinuityDecision.restored,
      );
      expect(provider.lastMeasurement?.trackingId, 1);
    });

    test('without the reference the same start stops observation', () {
      final c = DriverContinuity(trackingId: 1);
      c.resolve(10066667, []);
      c.resolve(12066667, [face(2, cx: .52)]);
      expect(c.decision, ContinuityDecision.different);
    });

    test('the reference does not take back a face elsewhere or too late', () {
      for (final (us, other) in [
        (12000000, face(2, cx: .85)),
        (16000000, face(2)),
      ]) {
        final c = DriverContinuity(trackingId: 1)
          ..anchor(10000000, box: face(1).box);
        c.resolve(10066667, []);
        c.resolve(us, [other]);
        expect(c.decision, ContinuityDecision.different);
      }
    });

    test('a reference at the frame edge counts as leaving the frame', () {
      final c = DriverContinuity(trackingId: 1)
        ..anchor(10000000, box: face(1, cx: .15).box);
      c.resolve(10066667, []);
      c.resolve(11000000, [face(2, cx: .15)]);
      expect(c.decision, ContinuityDecision.different);
    });
  });

  test('the decision is in the attention state', () {
    final p = AttentionPipeline(calibration: profile);
    expect(p.process(1000, [face(1)]).state.toJson()['driver'], 'same');
    expect(p.process(2000, []).state.toJson()['driver'], 'no_face');
  });
}

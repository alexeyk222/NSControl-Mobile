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

  test('the decision is in the attention state', () {
    final p = AttentionPipeline(calibration: profile);
    expect(p.process(1000, [face(1)]).state.toJson()['driver'], 'same');
    expect(p.process(2000, []).state.toJson()['driver'], 'no_face');
  });
}

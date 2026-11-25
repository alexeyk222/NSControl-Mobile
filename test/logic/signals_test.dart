import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';

void main() {
  const full = FaceSignals(
    engineId: 'arkit_face_tracking',
    trackingId: 3,
    headYawLeft: 12.5,
    headPitchDown: -4,
    headRollRight: 1,
    gazeLeft: 30,
    gazeDown: 5,
    eyeGazeLeft: 17.5,
    eyeGazeDown: 9,
    eyeOpenLeft: .9,
    eyeOpenRight: .85,
    distanceM: .55,
    blendshapes: {Blendshape.eyeBlinkLeft: .1, Blendshape.jawOpen: .02},
  );

  test('json round trip keeps every field', () {
    final back = FaceSignals.fromJson(full.toJson());
    expect(back.toJson(), full.toJson());
    expect(back.hasGaze, isTrue);
    expect(back.blendshape(Blendshape.jawOpen), .02);
  });

  test('missing values stay null, not zero', () {
    final back = FaceSignals.fromJson({'engine': 'mlkit_face_detection'});
    expect(back.gazeLeft, isNull);
    expect(back.hasGaze, isFalse);
    expect(back.eyeOpenLeft, isNull);
    expect(back.tracked, isTrue);
    expect(back.toJson(), {'engine': 'mlkit_face_detection', 'tracked': true});
  });

  test('maps onto the ТЗ measurement without changing values', () {
    final m = full.toMeasurement();
    expect(m.trackingId, 3);
    expect(m.leftEye, .9);
    expect(m.rightEye, .85);
    expect(m.pitchDown, -4);
    expect(m.yaw, 12.5);
    expect(m.roll, 1);
    expect(m.hasEyes, isTrue);
    expect(m.hasHeadAngles, isTrue);
  });

  test('rejects values outside the contract', () {
    expect(
      () => FaceSignals.fromJson({'engine': 'x', 'eyeOpenLeft': 1.2}),
      throwsFormatException,
    );
    expect(
      () => FaceSignals.fromJson({'engine': 'x', 'gazeLeft': 400}),
      throwsFormatException,
    );
    expect(
      () => FaceSignals.fromJson({
        'engine': 'x',
        'blendshapes': {'jawOpen': -.1},
      }),
      throwsFormatException,
    );
    expect(() => FaceSignals.fromJson({'engine': ''}), throwsFormatException);
  });

  test('zones keep stable codes', () {
    for (final zone in GazeZone.values) {
      expect(GazeZone.fromCode(zone.code), zone);
    }
    expect(GazeZone.mirrorLeft.drivingRelated, isTrue);
    expect(GazeZone.console.drivingRelated, isFalse);
    expect(() => GazeZone.fromCode('sky'), throwsFormatException);
  });
}

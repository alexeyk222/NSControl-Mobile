import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/mlkit_signals.dart';

void main() {
  test('ML Kit values map onto the contract and the old measurement', () {
    final s = MlKitSignals.from(
      trackingId: 4,
      leftEyeOpen: .9,
      rightEyeOpen: .8,
      eulerX: 10, // ML Kit: positive = looking up
      eulerY: -12,
      eulerZ: 3,
    );
    expect(s.engineId, 'mlkit_face_detection');
    expect(s.headPitchDown, -10);
    expect(s.headYawLeft, MlKitSignals.yawSign * -12);
    expect(s.headRollRight, MlKitSignals.rollSign * 3);
    expect(s.gazeLeft, isNull);
    expect(s.blendshapes, isEmpty);
    final m = s.toMeasurement();
    expect(m.trackingId, 4);
    expect(m.pitchDown, -10);
    expect(m.leftEye, .9);
    expect(m.rightEye, .8);
  });

  test('missing ML Kit values stay null', () {
    final s = MlKitSignals.from(trackingId: 1);
    expect(s.headPitchDown, isNull);
    expect(s.headYawLeft, isNull);
    expect(s.eyeOpenLeft, isNull);
  });
}

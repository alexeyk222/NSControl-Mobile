import '../logic/domain.dart';

/// Maps ML Kit face values onto the shared [FaceSignals] conventions.
///
/// Pitch: ML Kit Euler X is positive when the face looks up, the contract
/// wants positive down. Yaw and roll: the contract wants positive toward the
/// driver's own left (yaw) and right shoulder (roll). The signs below must be
/// confirmed on the iPhone with the `signs-v1` lab scenario; the result is
/// recorded in docs/recognition-contract.md. The ТЗ automata only use |yaw|
/// and yaw relative to the calibration, so a sign flip does not change them.
abstract final class MlKitSignals {
  static const engineId = 'mlkit_face_detection';
  static const yawSign = 1.0;
  static const rollSign = 1.0;

  static FaceSignals from({
    int? trackingId,
    double? leftEyeOpen,
    double? rightEyeOpen,
    double? eulerX,
    double? eulerY,
    double? eulerZ,
  }) => FaceSignals(
    engineId: engineId,
    trackingId: trackingId,
    headPitchDown: eulerX == null ? null : -eulerX,
    headYawLeft: eulerY == null ? null : yawSign * eulerY,
    headRollRight: eulerZ == null ? null : rollSign * eulerZ,
    eyeOpenLeft: leftEyeOpen,
    eyeOpenRight: rightEyeOpen,
  );
}

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
    FaceBox? box,
  }) => FaceSignals(
    engineId: engineId,
    trackingId: trackingId,
    headPitchDown: eulerX == null ? null : -eulerX,
    headYawLeft: eulerY == null ? null : yawSign * eulerY,
    headRollRight: eulerZ == null ? null : rollSign * eulerZ,
    eyeOpenLeft: leftEyeOpen,
    eyeOpenRight: rightEyeOpen,
    box: box,
  );

  /// [FaceSignals.box] from an ML Kit bounding box. ML Kit reports it in the
  /// upright (rotated) image, not mirrored, so only the size has to follow
  /// the rotation: a quarter turn swaps width and height.
  static FaceBox? boxOf({
    required double left,
    required double top,
    required double width,
    required double height,
    required int imageWidth,
    required int imageHeight,
    required int rotation,
  }) {
    final quarter = rotation % 180 != 0;
    final w = (quarter ? imageHeight : imageWidth).toDouble();
    final h = (quarter ? imageWidth : imageHeight).toDouble();
    if (w <= 0 || h <= 0) return null;
    final box = FaceBox(
      left: left / w,
      top: top / h,
      width: width / w,
      height: height / h,
    );
    try {
      box.validate();
      return box;
    } on FormatException {
      return null;
    }
  }
}

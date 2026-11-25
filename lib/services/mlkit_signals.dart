import '../logic/domain.dart';

/// Maps ML Kit face values onto the shared [FaceSignals] conventions.
///
/// Pitch: ML Kit Euler X is positive when the face looks up, the contract
/// wants positive down. Yaw and roll: the contract wants positive toward the
/// driver's own left (yaw) and right shoulder (roll).
///
/// [yawSign] and [rollSign] are for an unmirrored image. A mirrored image
/// (iOS front camera through the camera plugin) flips left and right: yaw and
/// roll change sign and the box is flipped. The eyes are not swapped: with
/// the phone on the left vent the eye ML Kit calls left on the mirrored frame
/// is the driver's left one (checked against ARKit eye geometry, 2026-11-25). iPhone 11, `signs-v1` 2026-11-25 (mirrored frames): head
/// turned to the driver's left gave Euler Y ≈ −34°, head down gave pitch
/// ≈ +34°, so [yawSign] = +1 for unmirrored frames. Roll is still weak in
/// the recordings. The ТЗ automata only use |yaw| and yaw relative to
/// the calibration, so a sign flip does not change them.
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
    bool mirrored = false,
  }) {
    final flip = mirrored ? -1.0 : 1.0;
    return FaceSignals(
      engineId: engineId,
      trackingId: trackingId,
      headPitchDown: eulerX == null ? null : -eulerX,
      headYawLeft: eulerY == null ? null : flip * yawSign * eulerY,
      headRollRight: eulerZ == null ? null : flip * rollSign * eulerZ,
      eyeOpenLeft: leftEyeOpen,
      eyeOpenRight: rightEyeOpen,
      box: box,
    );
  }

  /// [FaceSignals.box] from an ML Kit bounding box. ML Kit reports it in the
  /// upright (rotated) image, so the size follows the rotation (a quarter
  /// turn swaps width and height); a [mirrored] image is flipped back, since
  /// the contract box is unmirrored.
  static FaceBox? boxOf({
    required double left,
    required double top,
    required double width,
    required double height,
    required int imageWidth,
    required int imageHeight,
    required int rotation,
    bool mirrored = false,
  }) {
    final quarter = rotation % 180 != 0;
    final w = (quarter ? imageHeight : imageWidth).toDouble();
    final h = (quarter ? imageWidth : imageHeight).toDouble();
    if (w <= 0 || h <= 0) return null;
    final box = FaceBox(
      left: mirrored ? 1 - (left + width) / w : left / w,
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

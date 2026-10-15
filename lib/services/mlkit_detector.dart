import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    as ml;
import '../logic/domain.dart';
import 'detector.dart';

class MlKitDetector implements FaceDetectorPort {
  final _detector = ml.FaceDetector(
    options: ml.FaceDetectorOptions(
      enableClassification: true,
      enableTracking: true,
      enableLandmarks: true,
      enableContours: false,
      performanceMode: ml.FaceDetectorMode.fast,
      minFaceSize: 0.15,
    ),
  );
  @override
  DetectorCapabilities get capabilities => DetectorCapabilities.mlKit;

  @override
  Future<List<DetectedFace>> detect(VisionFrame frame) async {
    final rotation = ml.InputImageRotationValue.fromRawValue(frame.rotation);
    if (rotation == null) throw ArgumentError('Invalid image rotation');
    final image = ml.InputImage.fromBytes(
      bytes: frame.bytes,
      metadata: ml.InputImageMetadata(
        size: Size(frame.width.toDouble(), frame.height.toDouble()),
        rotation: rotation,
        format: frame.format == PixelFormat.nv21
            ? ml.InputImageFormat.nv21
            : ml.InputImageFormat.bgra8888,
        bytesPerRow: frame.bytesPerRow,
      ),
    );
    final faces = await _detector.processImage(image);
    return faces
        .map(
          (f) => DetectedFace(
            FaceMeasurement(
              trackingId: f.trackingId,
              leftEye: f.leftEyeOpenProbability,
              rightEye: f.rightEyeOpenProbability,
              // ML Kit Euler X is positive when the face is looking UP.
              pitchDown: f.headEulerAngleX == null ? null : -f.headEulerAngleX!,
              yaw: f.headEulerAngleY,
              roll: f.headEulerAngleZ,
            ),
            f.boundingBox,
          ),
        )
        .toList();
  }

  @override
  Future<void> close() => _detector.close();
}

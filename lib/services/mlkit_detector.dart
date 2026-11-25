import 'dart:ui';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart'
    as ml;
import '../logic/domain.dart';
import 'detector.dart';
import 'mlkit_signals.dart';

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
    return faces.map((f) {
      final signals = MlKitSignals.from(
        trackingId: f.trackingId,
        leftEyeOpen: f.leftEyeOpenProbability,
        rightEyeOpen: f.rightEyeOpenProbability,
        eulerX: f.headEulerAngleX,
        eulerY: f.headEulerAngleY,
        eulerZ: f.headEulerAngleZ,
        box: MlKitSignals.boxOf(
          left: f.boundingBox.left,
          top: f.boundingBox.top,
          width: f.boundingBox.width,
          height: f.boundingBox.height,
          imageWidth: frame.width,
          imageHeight: frame.height,
          rotation: frame.rotation,
        ),
      );
      // The ТЗ automata keep their input: the same five numbers as before.
      return DetectedFace(
        signals.toMeasurement(),
        f.boundingBox,
        signals: signals,
      );
    }).toList();
  }

  @override
  Future<void> close() => _detector.close();
}

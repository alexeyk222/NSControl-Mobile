import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/services/camera_service.dart';
import 'package:nscontrol/services/detector.dart';
import 'package:nscontrol/services/face_source.dart';

class _Detector implements FaceDetectorPort {
  bool closed = false;
  @override
  DetectorCapabilities get capabilities => DetectorCapabilities.mlKit;
  @override
  Future<List<DetectedFace>> detect(VisionFrame frame) async => [];
  @override
  Future<void> close() async => closed = true;
}

class _Camera extends CameraService {
  _Camera({
    required super.detector,
    required super.nowUs,
    required super.onFaces,
    required super.onError,
    required super.onChanged,
  });
  bool streaming = false;
  @override
  bool get running => streaming;
  @override
  Future<void> start() async => streaming = true;
  @override
  Future<void> stop() async => streaming = false;
}

void main() {
  test(
    'camera source reports results of its detector with upright size',
    () async {
      final detector = _Detector();
      late _Camera camera;
      final source = CameraFaceSource(
        detector,
        cameraFactory: (d, now, onFaces, onError, onChanged) =>
            camera = _Camera(
              detector: d,
              nowUs: now,
              onFaces: onFaces,
              onError: onError,
              onChanged: onChanged,
            ),
      );
      final results = <FaceResult>[];
      await source.start(
        nowUs: () => 0,
        onResult: results.add,
        onError: (_) {},
        onChanged: () {},
      );
      expect(source.running, isTrue);
      expect(source.engines.single.id, 'mlkit_face_detection');
      camera
        ..frameWidth = 640
        ..frameHeight = 480
        ..frameRotation = 270;
      const face = DetectedFace(
        FaceMeasurement(trackingId: 1),
        Rect.fromLTWH(10, 20, 100, 120),
      );
      camera.onFaces([face], 100, 150);
      expect(results.single.engineId, 'mlkit_face_detection');
      expect(results.single.capturedUs, 100);
      expect(results.single.completedUs, 150);
      expect(results.single.faces.single, same(face));
      expect(results.single.imageSize, const Size(480, 640));
      await source.dispose();
      expect(source.running, isFalse);
      expect(detector.closed, isTrue);
    },
  );
}

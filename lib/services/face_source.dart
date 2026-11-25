import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import '../logic/domain.dart';
import 'camera_service.dart';
import 'detector.dart';

/// One completed analysis of one engine.
class FaceResult {
  const FaceResult({
    required this.engineId,
    required this.capturedUs,
    required this.completedUs,
    required this.faces,
    this.imageSize,
  });
  final String engineId;

  /// Times on the clock passed to [FaceSource.start]. In comparison mode both
  /// engines report the same [capturedUs] for the same camera frame.
  final int capturedUs, completedUs;
  final List<DetectedFace> faces;

  /// Upright image size that [DetectedFace.bounds] refer to, when known.
  final Size? imageSize;
}

/// A face engine that delivers results by itself (push), used by the lab.
/// The camera plugin plus a [FaceDetectorPort] is one source; an engine that
/// owns the camera itself (ARKit) is another, and a comparison source may run
/// two engines on the same frames. The first of [engines] is the primary one:
/// its results drive calibration and the ТЗ automata in the lab.
abstract interface class FaceSource {
  List<DetectorCapabilities> get engines;
  bool get running;

  /// True when [preview] shows a mirrored (selfie) image, so face boxes in
  /// image coordinates must be flipped horizontally.
  bool get previewMirrored;

  Future<void> start({
    required int Function() nowUs,
    required void Function(FaceResult) onResult,
    required void Function(Object) onError,
    required void Function() onChanged,
  });
  Future<void> stop();

  /// Live preview (never recorded or streamed), or null when unavailable.
  Widget? preview();
  Future<void> dispose();
}

/// The existing path: camera plugin frames → [FaceDetectorPort].
class CameraFaceSource implements FaceSource {
  CameraFaceSource(this.detector, {this.cameraFactory});
  final FaceDetectorPort detector;

  /// Test hook; defaults to [CameraService].
  final CameraService Function(
    FaceDetectorPort detector,
    int Function() nowUs,
    void Function(List<DetectedFace>, int, int) onFaces,
    void Function(Object) onError,
    void Function() onChanged,
  )?
  cameraFactory;
  CameraService? camera;

  @override
  List<DetectorCapabilities> get engines => [detector.capabilities];
  @override
  bool get running => camera?.running ?? false;
  @override
  bool get previewMirrored => true;

  @override
  Future<void> start({
    required int Function() nowUs,
    required void Function(FaceResult) onResult,
    required void Function(Object) onError,
    required void Function() onChanged,
  }) async {
    await stop();
    late final CameraService created;
    void onFaces(List<DetectedFace> faces, int captured, int completed) {
      final w = created.frameWidth, h = created.frameHeight;
      final quarter = (created.frameRotation ?? 0) % 180 != 0;
      onResult(
        FaceResult(
          engineId: detector.capabilities.id,
          capturedUs: captured,
          completedUs: completed,
          faces: faces,
          imageSize: w == null || h == null
              ? null
              : quarter
              ? Size(h.toDouble(), w.toDouble())
              : Size(w.toDouble(), h.toDouble()),
        ),
      );
    }

    created = (cameraFactory ?? _defaultCamera)(
      detector,
      nowUs,
      onFaces,
      onError,
      onChanged,
    );
    camera = created;
    await created.start();
  }

  static CameraService _defaultCamera(
    FaceDetectorPort detector,
    int Function() nowUs,
    void Function(List<DetectedFace>, int, int) onFaces,
    void Function(Object) onError,
    void Function() onChanged,
  ) => CameraService(
    detector: detector,
    nowUs: nowUs,
    onFaces: onFaces,
    onError: onError,
    onChanged: onChanged,
  );

  @override
  Future<void> stop() async {
    final old = camera;
    camera = null;
    await old?.stop();
  }

  @override
  Widget? preview() {
    final controller = camera?.controller;
    if (controller == null || !controller.value.isInitialized) return null;
    return CameraPreview(controller);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await detector.close();
  }
}

/// A lab engine choice: what the user picks in the lab.
class LabEngineOption {
  const LabEngineOption({
    required this.id,
    required this.title,
    required this.engineIds,
    required this.create,
  });
  final String id, title;

  /// Engine ids the source will report, primary first.
  final List<String> engineIds;
  final FaceSource Function() create;
}

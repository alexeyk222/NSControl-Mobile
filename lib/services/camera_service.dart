import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'detector.dart';
import 'frame_pipeline.dart';

int androidRotation(int sensorOrientation, DeviceOrientation orientation) {
  final compensation = switch (orientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  return (sensorOrientation + compensation) % 360; // Front lens only.
}

class CameraService {
  CameraService({
    required this.detector,
    required this.nowUs,
    required this.onFaces,
    required this.onError,
    required this.onChanged,
  }) {
    pipeline = FramePipeline(
      analyze: detector.detect,
      onResult: onFaces,
      onError: onError,
      nowUs: nowUs,
      onDiscard: (captured, completed) => onFaces([], captured, completed),
    );
  }
  final FaceDetectorPort detector;
  final int Function() nowUs;
  final void Function(List<DetectedFace>, int, int) onFaces;
  final void Function(Object) onError;
  final void Function() onChanged;
  late final FramePipeline<VisionFrame, List<DetectedFace>> pipeline;
  CameraController? controller;
  CameraDescription? _description;
  int _generation = 0;
  bool _starting = false;
  bool get running => controller?.value.isStreamingImages ?? false;

  Future<void> start() async {
    if (_starting || running) return;
    _starting = true;
    final generation = ++_generation;
    CameraController? candidate;
    try {
      if (!Platform.isAndroid && !Platform.isIOS) {
        throw UnsupportedError('Камера доступна в приложении Android или iOS.');
      }
      final cameras = await availableCameras();
      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (front.isEmpty) throw StateError('Фронтальная камера не найдена');
      _description = front.first;
      candidate = CameraController(
        front.first,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await candidate.initialize();
      if (generation != _generation) {
        await candidate.dispose();
        return;
      }
      controller = candidate;
      candidate.addListener(_cameraValueChanged);
      pipeline.begin();
      await candidate.startImageStream((image) {
        if (generation == _generation && identical(controller, candidate)) {
          _onFrame(image);
        }
      });
      if (generation != _generation) {
        await stop();
        return;
      }
      onChanged();
    } catch (error) {
      if (candidate != null && candidate != controller) {
        await candidate.dispose();
      }
      if (generation == _generation) {
        await stop();
        onError(error);
      }
    } finally {
      _starting = false;
    }
  }

  void _cameraValueChanged() {
    final value = controller?.value;
    if (value?.hasError ?? false) {
      onError(StateError(value!.errorDescription ?? 'Ошибка камеры'));
    }
  }

  void _onFrame(CameraImage image) {
    if (pipeline.busy || controller == null) {
      pipeline.dropped++;
      return;
    }
    final captured = nowUs();
    if (image.width < 480 ||
        image.height < 480 ||
        (image.width < 640 && image.height < 640) ||
        image.planes.length != 1) {
      onError(
        StateError(
          'Нужен кадр не менее 640×480 в формате NV21/BGRA с одной плоскостью.',
        ),
      );
      return;
    }
    final format = Platform.isAndroid ? PixelFormat.nv21 : PixelFormat.bgra8888;
    if ((Platform.isAndroid && image.format.group != ImageFormatGroup.nv21) ||
        (Platform.isIOS && image.format.group != ImageFormatGroup.bgra8888)) {
      onError(
        StateError('Камера вернула неподдерживаемый формат изображения.'),
      );
      return;
    }
    final rotation = Platform.isAndroid
        ? androidRotation(
            _description!.sensorOrientation,
            controller!.value.deviceOrientation,
          )
        : _description!.sensorOrientation;
    unawaited(
      pipeline.offer(
        VisionFrame(
          bytes: image.planes.single.bytes,
          width: image.width,
          height: image.height,
          rotation: rotation,
          format: format,
          bytesPerRow: image.planes.single.bytesPerRow,
        ),
        captured,
      ),
    );
  }

  Future<void> stop() async {
    _generation++;
    pipeline.end();
    final old = controller;
    controller = null;
    if (old == null) return;
    old.removeListener(_cameraValueChanged);
    try {
      if (old.value.isStreamingImages) await old.stopImageStream();
    } finally {
      await old.dispose();
      onChanged();
    }
  }
}

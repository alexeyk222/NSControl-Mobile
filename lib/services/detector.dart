import 'dart:typed_data';
import 'dart:ui';
import '../logic/domain.dart';

enum PixelFormat { nv21, bgra8888 }

class VisionFrame {
  const VisionFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotation,
    required this.format,
    required this.bytesPerRow,
  });
  final Uint8List bytes;
  final int width, height, rotation, bytesPerRow;
  final PixelFormat format;
}

class DetectedFace {
  const DetectedFace(this.measurement, this.bounds);
  final FaceMeasurement measurement;
  final Rect bounds;
}

/// Adapters must normalize pitch to positive-down and publish their own
/// identity/eye-validity range. They never own event thresholds or timers.
abstract interface class FaceDetectorPort {
  DetectorCapabilities get capabilities;
  Future<List<DetectedFace>> detect(VisionFrame frame);
  Future<void> close();
}

class DetectorRegistry {
  DetectorRegistry(Map<String, FaceDetectorPort Function()> factories)
    : _factories = Map.unmodifiable(factories);
  final Map<String, FaceDetectorPort Function()> _factories;
  Iterable<String> get ids => _factories.keys;
  FaceDetectorPort create(String id) {
    final factory = _factories[id];
    if (factory == null) {
      throw ArgumentError.value(id, 'id', 'Unknown detector');
    }
    return factory();
  }
}

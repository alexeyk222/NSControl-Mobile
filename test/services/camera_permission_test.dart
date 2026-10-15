import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'trip_controller_test.dart'
    show ControllerTestDetector, ControllerTestPlatform, ControllerTestCamera;

class CountingCamera extends ControllerTestCamera {
  CountingCamera({
    required super.detector,
    required super.nowUs,
    required super.onFaces,
    required super.onError,
    required super.onChanged,
  });
  int starts = 0;
  @override
  Future<void> start() async {
    starts++;
    await super.start();
  }
}

void main() {
  test(
    'permission denial stops automatic retry until explicit user retry',
    () async {
      late CountingCamera camera;
      final trip = TripController(
        repository: null,
        platform: ControllerTestPlatform(),
        detector: ControllerTestDetector(),
        cameraFactory: (d, n, f, e, c) => camera = CountingCamera(
          detector: d,
          nowUs: n,
          onFaces: f,
          onError: e,
          onChanged: c,
        ),
      );
      try {
        await trip.start();
        camera.onError(
          CameraException('CameraAccessDenied', 'Permission denied'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 2200));
        expect(camera.running, isFalse);
        expect(camera.starts, 1);
        await trip.retryCamera();
        expect(camera.starts, 2);
      } finally {
        trip.dispose();
      }
    },
  );
}

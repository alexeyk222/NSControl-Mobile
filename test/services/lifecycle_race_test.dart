import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/platform_bridge.dart';
import 'package:nscontrol/services/trip_controller.dart';

import 'trip_controller_test.dart'
    show ControllerTestCamera, ControllerTestDetector;

class PendingAwakePlatform extends PlatformBridge {
  final awakeRequested = Completer<void>();
  final releaseAwake = Completer<void>();

  @override
  Stream<Map<String, Object?>> get events => const Stream.empty();

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (method == 'screen.keepAwake' && arguments?['enabled'] == true) {
      awakeRequested.complete();
      await releaseAwake.future;
    }
    return {'status': 'ok'};
  }
}

void main() {
  test(
    'a pending trip start cannot reopen the camera after backgrounding',
    () async {
      final platform = PendingAwakePlatform();
      late ControllerTestCamera camera;
      final trip = TripController(
        repository: null,
        platform: platform,
        detector: ControllerTestDetector(),
        cameraFactory: (d, n, f, e, c) => camera = ControllerTestCamera(
          detector: d,
          nowUs: n,
          onFaces: f,
          onError: e,
          onChanged: c,
        ),
      );
      final starting = trip.start();
      try {
        await platform.awakeRequested.future;
        await trip.foreground(false);
        expect(trip.phase, TripPhase.paused);
        expect(camera.running, isFalse);

        platform.releaseAwake.complete();
        await starting;

        expect(trip.phase, TripPhase.paused);
        expect(
          camera.running,
          isFalse,
          reason:
              'Completing an old foreground request must not reopen the '
              'camera while the app is in the background.',
        );
      } finally {
        if (!platform.releaseAwake.isCompleted) {
          platform.releaseAwake.complete();
        }
        await starting;
        trip.dispose();
        await trip.pendingWrites;
      }
    },
  );
}

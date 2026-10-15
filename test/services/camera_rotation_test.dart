import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/services/camera_service.dart';

void main() {
  test(
    'front camera orientation accounts for all device rotations without mirroring bytes',
    () {
      expect(androidRotation(270, DeviceOrientation.portraitUp), 270);
      expect(androidRotation(270, DeviceOrientation.landscapeLeft), 0);
      expect(androidRotation(270, DeviceOrientation.portraitDown), 90);
      expect(androidRotation(270, DeviceOrientation.landscapeRight), 180);
    },
  );
}

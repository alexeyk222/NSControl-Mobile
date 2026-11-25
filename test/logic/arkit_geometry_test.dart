import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/arkit_geometry.dart';
import 'package:nscontrol/logic/domain.dart';

const _rad = math.pi / 180;

/// A synthetic ARKit frame. The camera basis (driver's right, up, direction
/// to the driver) is given in camera coordinates so the same head pose can be
/// tested under different axis conventions.
class _Rig {
  _Rig({required this.right, required this.up, required this.toDriver})
    : assert((right.cross(up) - toDriver).length < 1e-9, 'right-handed');
  final Vec3 right, up, toDriver;

  Vec3 cam(Vec3 d) => right * d.x + up * d.y + toDriver * d.z;

  /// Face pose for yaw to the driver's left, pitch down and roll to the right
  /// (degrees), 0.5 m from the camera.
  List<double> face({double yaw = 0, double pitch = 0, double roll = 0}) {
    Vec3 rot(Vec3 v) =>
        _ry(yaw * _rad, _rx(-pitch * _rad, _rz(-roll * _rad, v)));
    // Neutral face axes in driver coordinates: +x the face's own left,
    // +y up, +z towards the camera.
    final x = cam(rot(const Vec3(-1, 0, 0)));
    final y = cam(rot(const Vec3(0, 1, 0)));
    final z = cam(rot(const Vec3(0, 0, -1)));
    final p = toDriver * .5;
    return [
      x.x,
      x.y,
      x.z,
      0,
      y.x,
      y.y,
      y.z,
      0,
      z.x,
      z.y,
      z.z,
      0,
      p.x,
      p.y,
      p.z,
      1,
    ];
  }

  List<double> get gravity {
    final g = up;
    return [g.x, g.y, g.z];
  }
}

Vec3 _ry(double a, Vec3 v) => Vec3(
  math.cos(a) * v.x + math.sin(a) * v.z,
  v.y,
  -math.sin(a) * v.x + math.cos(a) * v.z,
);
Vec3 _rx(double a, Vec3 v) => Vec3(
  v.x,
  math.cos(a) * v.y - math.sin(a) * v.z,
  math.sin(a) * v.y + math.cos(a) * v.z,
);
Vec3 _rz(double a, Vec3 v) => Vec3(
  math.cos(a) * v.x - math.sin(a) * v.y,
  math.sin(a) * v.x + math.cos(a) * v.y,
  v.z,
);

/// Eye transform in face space (+x the face's own left, +z forward) looking
/// [left]/[down] degrees, eye at x.
List<double> _eye(double x, {double left = 0, double down = 0}) {
  final d = _ry(left * _rad, _rx(down * _rad, const Vec3(0, 0, 1)));
  // Only the z column (gaze) and translation matter for the adapter.
  return [1, 0, 0, 0, 0, 1, 0, 0, d.x, d.y, d.z, 0, x, .03, .02, 1];
}

List<double> _lookAt({double left = 0, double down = 0}) {
  final d = _ry(left * _rad, _rx(down * _rad, const Vec3(0, 0, 1))) * .8;
  return [d.x, d.y + .03, d.z + .02];
}

ArkitFaceRaw _raw(
  _Rig rig, {
  double yaw = 0,
  double pitch = 0,
  double roll = 0,
  double eyeLeft = 0,
  double eyeDown = 0,
  Map<String, double> shapes = const {'eyeBlink_L': .1, 'eyeBlink_R': .3},
}) => ArkitFaceRaw(
  id: 1,
  tracked: true,
  faceInCamera: rig.face(yaw: yaw, pitch: pitch, roll: roll),
  leftEye: _eye(.03, left: eyeLeft, down: eyeDown),
  rightEye: _eye(-.03, left: eyeLeft, down: eyeDown),
  lookAt: _lookAt(left: eyeLeft, down: eyeDown),
  blendshapes: shapes,
);

List<double> _q(Vec3 axis, double degrees) {
  final h = degrees * _rad / 2;
  return [
    math.cos(h),
    axis.x * math.sin(h),
    axis.y * math.sin(h),
    axis.z * math.sin(h),
  ];
}

List<double> _mul(List<double> a, List<double> b) => [
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
];

List<double> _inverse(List<double> q) => [q[0], -q[1], -q[2], -q[3]];

/// Same rotation (q and −q are equal rotations).
Matcher _sameRotation(List<double> expected) => predicate<List<double>>((q) {
  final dot = [
    for (var i = 0; i < 4; i++) q[i] * expected[i],
  ].reduce((a, b) => a + b);
  return (dot.abs() - 1).abs() < 1e-9;
}, 'rotation $expected');

void main() {
  // Apple's camera space: face in front at −z, portrait "up" along −x.
  final apple = _Rig(
    right: const Vec3(0, -1, 0),
    up: const Vec3(-1, 0, 0),
    toDriver: const Vec3(0, 0, -1),
  );
  // Same head, a front-camera space with the face at +z and up along +y.
  final front = _Rig(
    right: const Vec3(1, 0, 0),
    up: const Vec3(0, 1, 0),
    toDriver: const Vec3(0, 0, 1),
  );

  for (final (name, rig) in [('apple', apple), ('front', front)]) {
    group('head pose, $name axes', () {
      test('neutral face looks straight at the camera', () {
        final s = arkitSignals(_raw(rig), gravityUp: rig.gravity);
        expect(s.headYawLeft, closeTo(0, 1e-9));
        expect(s.headPitchDown, closeTo(0, 1e-9));
        expect(s.headRollRight, closeTo(0, 1e-9));
        expect(s.distanceM, closeTo(.5, 1e-9));
        expect(s.engineId, 'arkit_face_tracking');
        expect(s.tracked, isTrue);
      });

      test('yaw, pitch and roll keep the driver-centred signs', () {
        final s = arkitSignals(
          _raw(rig, yaw: 25, pitch: 15, roll: 10),
          gravityUp: rig.gravity,
        );
        expect(s.headYawLeft, closeTo(25, 1e-6));
        expect(s.headPitchDown, closeTo(15, 1e-6));
        expect(s.headRollRight, closeTo(10, 1e-6));
        final r = arkitSignals(
          _raw(rig, yaw: -40, pitch: -10, roll: -20),
          gravityUp: rig.gravity,
        );
        expect(r.headYawLeft, closeTo(-40, 1e-6));
        expect(r.headPitchDown, closeTo(-10, 1e-6));
        expect(r.headRollRight, closeTo(-20, 1e-6));
      });

      test('a tilted holder only needs gravity close to an axis', () {
        final tilted = [rig.up.x + .2, rig.up.y + .2, rig.up.z + .3];
        final s = arkitSignals(_raw(rig, yaw: 10), gravityUp: tilted);
        expect(s.headYawLeft, closeTo(10, 1e-6));
      });

      test('gaze is head plus eyes; eye-in-head is eyes only', () {
        final s = arkitSignals(
          _raw(rig, yaw: 20, eyeLeft: 15, eyeDown: 0),
          gravityUp: rig.gravity,
        );
        expect(s.eyeGazeLeft, closeTo(15, 1e-6));
        expect(s.eyeGazeDown, closeTo(0, 1e-6));
        expect(s.gazeLeft, closeTo(35, 1e-6));
        expect(s.gazeDown, closeTo(0, 1e-6));
        final down = arkitSignals(
          _raw(rig, pitch: 10, eyeDown: 20),
          gravityUp: rig.gravity,
        );
        expect(down.eyeGazeDown, closeTo(20, 1e-6));
        expect(down.gazeDown, closeTo(30, 1e-6));
        expect(down.hasGaze, isTrue);
      });
    });
  }

  test('mirror flips every left/right quantity and nothing else', () {
    final s = arkitSignals(
      _raw(apple, yaw: 20, pitch: 5, roll: 8, eyeLeft: 10),
      gravityUp: apple.gravity,
      axes: const ArkitAxes(mirror: true),
    );
    expect(s.headYawLeft, closeTo(-20, 1e-6));
    expect(s.headPitchDown, closeTo(5, 1e-6));
    expect(s.headRollRight, closeTo(-8, 1e-6));
    expect(s.eyeGazeLeft, closeTo(-10, 1e-6));
    // Yaw and eye angles add exactly only without pitch.
    expect(s.gazeLeft, closeTo(-30, .2));
  });

  group('headRotation', () {
    const left = Vec3(1, 0, 0), up = Vec3(0, 1, 0), toCamera = Vec3(0, 0, 1);
    for (final (name, rig) in [('apple', apple), ('front', front)]) {
      test('$name axes: identity when looking at the camera', () {
        final q = arkitSignals(_raw(rig), gravityUp: rig.gravity).headRotation!;
        expect(q, _sameRotation(const [1, 0, 0, 0]));
        expect(q[0], greaterThan(0));
      });

      test('$name axes: yaw · pitch · roll about up, left, to camera', () {
        final s = arkitSignals(
          _raw(rig, yaw: 35, pitch: 15, roll: 10),
          gravityUp: rig.gravity,
        );
        final expected = _mul(_q(up, 35), _mul(_q(left, 15), _q(toCamera, 10)));
        expect(s.headRotation, _sameRotation(expected));
        s.validate();
      });
    }

    test('relative to a side calibration the nod is exact', () {
      // Phone on the air vent: the road pose is 35° to the camera.
      final cal = arkitSignals(
        _raw(apple, yaw: 35),
        gravityUp: apple.gravity,
      ).headRotation!;
      final nod = arkitSignals(
        _raw(apple, yaw: 35, pitch: 20),
        gravityUp: apple.gravity,
      ).headRotation!;
      expect(_mul(_inverse(cal), nod), _sameRotation(_q(left, 20)));
    });

    test('mirror flips yaw and roll, keeps pitch', () {
      final s = arkitSignals(
        _raw(apple, yaw: 20, pitch: 10, roll: 5),
        gravityUp: apple.gravity,
        axes: const ArkitAxes(mirror: true),
      );
      final expected = _mul(_q(up, -20), _mul(_q(left, 10), _q(toCamera, -5)));
      expect(s.headRotation, _sameRotation(expected));
    });

    test('round-trips through JSON and rejects a non-unit quaternion', () {
      final s = arkitSignals(_raw(apple, yaw: 30), gravityUp: apple.gravity);
      final back = FaceSignals.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.headRotation, s.headRotation);
      expect(
        () => FaceSignals(
          engineId: 'x',
          headRotation: const [1, 1, 0, 0],
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => FaceSignals(engineId: 'x', headRotation: const [1, 0]).validate(),
        throwsFormatException,
      );
    });

    test('untracked faces have no rotation', () {
      final s = arkitSignals(
        const ArkitFaceRaw(id: 1, tracked: false),
        gravityUp: apple.gravity,
      );
      expect(s.headRotation, isNull);
    });
  });

  test('eyelids: eyeOpen = 1 − eyeBlink, names follow the contract', () {
    final s = arkitSignals(
      _raw(
        apple,
        shapes: {
          'eyeBlink_L': .1,
          'eyeBlink_R': .3,
          'eyeLookDown_L': .6,
          'jawOpen': .2,
          'eyeSquint_R': 1.02,
        },
      ),
      gravityUp: apple.gravity,
    );
    expect(s.eyeOpenLeft, closeTo(.9, 1e-12));
    expect(s.eyeOpenRight, closeTo(.7, 1e-12));
    expect(s.blendshape(Blendshape.eyeLookDownLeft), .6);
    expect(s.blendshape(Blendshape.jawOpen), .2);
    expect(s.blendshape(Blendshape.eyeSquintRight), 1.0);
    s.validate();
    expect(FaceSignals.fromJson(s.toJson()).toJson(), s.toJson());
    final m = s.toMeasurement();
    expect(m.hasEyes, isTrue);
    expect(m.hasHeadAngles, isTrue);
  });

  test('swapEyes exchanges left and right eyes', () {
    final s = arkitSignals(
      _raw(apple),
      gravityUp: apple.gravity,
      axes: const ArkitAxes(swapEyes: true),
    );
    expect(s.eyeOpenLeft, closeTo(.7, 1e-12));
    expect(s.eyeOpenRight, closeTo(.9, 1e-12));
    expect(s.blendshape(Blendshape.eyeBlinkRight), .1);
  });

  test('an untracked face carries no stale numbers', () {
    final raw = ArkitFaceRaw(
      id: 4,
      tracked: false,
      faceInCamera: apple.face(yaw: 10),
      blendshapes: const {'eyeBlink_L': 0},
    );
    final s = arkitSignals(raw, gravityUp: apple.gravity);
    expect(s.tracked, isFalse);
    expect(s.trackingId, 4);
    expect(s.headYawLeft, isNull);
    expect(s.eyeOpenLeft, isNull);
    final m = s.toMeasurement();
    expect(m.hasEyes, isFalse);
    expect(m.hasHeadAngles, isFalse);
  });

  test('parses the bridge map and rejects malformed arrays', () {
    final raw = ArkitFaceRaw.fromMap({
      'id': 2,
      'tracked': true,
      'faceInCamera': apple.face(),
      'leftEye': [1, 2, 3],
      'lookAt': [0, 0, 1],
      'blendshapes': {'jawOpen': .5, 'bad': double.nan},
      'bounds': [10, 20, 100, 120],
    });
    expect(raw.id, 2);
    expect(raw.faceInCamera, hasLength(16));
    expect(raw.leftEye, isNull);
    expect(raw.blendshapes, {'jawOpen': .5});
    expect(raw.bounds, [10, 20, 100, 120]);
    expect(ArkitFaceRaw.fromMap(raw.toJson()).toJson(), raw.toJson());
  });

  test('blendshape names', () {
    expect(contractBlendshapeName('eyeBlink_L'), Blendshape.eyeBlinkLeft);
    expect(contractBlendshapeName('eyeLookOut_R'), Blendshape.eyeLookOutRight);
    expect(contractBlendshapeName('jawOpen'), Blendshape.jawOpen);
    expect(
      contractBlendshapeName('eyeBlink_L', swap: true),
      Blendshape.eyeBlinkRight,
    );
  });

  test('display orientation from displayTransform', () {
    expect(displayOrientation([1, 0, 0, 1, 0, 0]), (
      quarterTurns: 0,
      mirrored: false,
    ));
    // Image x goes down the screen: a quarter turn clockwise.
    expect(displayOrientation([0, 1, -1, 0, 1, 0]), (
      quarterTurns: 1,
      mirrored: false,
    ));
    expect(displayOrientation([0, -1, 1, 0, 0, 1]), (
      quarterTurns: 3,
      mirrored: false,
    ));
    // Flipped then turned.
    expect(displayOrientation([0, -1, -1, 0, 1, 1]), (
      quarterTurns: 1,
      mirrored: true,
    ));
    expect(displayOrientation([.7, .7, -.7, .7, 0, 0]), isNull);
  });

  test('capabilities are valid and separate from ML Kit', () {
    expect(arkitCapabilities.valid, isTrue);
    expect(arkitCapabilities.matches(DetectorCapabilities.mlKit), isFalse);
  });
}

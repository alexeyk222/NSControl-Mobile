import 'dart:math' as math;

import 'face.dart';
import 'signals.dart';

/// [DetectorCapabilities] of the ARKit Face Tracking adapter.
///
/// `eyeYawLimit` is provisional: until the yaw range in which ARKit eyelids
/// stay reliable is measured on the iPhone 11 (`tool/engine_compare.dart`,
/// criterion 3), the adapter keeps the conservative ТЗ value. The measured
/// value replaces it together with a new [version], because a calibration
/// profile is bound to id, version and limit.
const arkitCapabilities = DetectorCapabilities(
  id: 'arkit_face_tracking',
  version: 'arkit-adapter-1',
  eyeYawLimit: 18,
);

/// Sign corrections for ARKit, confirmed by the sign test in the lab.
///
/// The defaults follow Apple's documented conventions: a right-handed camera
/// space and a face space whose +x is the face's own left. Should the device
/// show a mirrored world, [mirror] flips every left/right quantity; should
/// ARKit name eyes from the viewer's side, [swapEyes] swaps left and right
/// eyes and blendshapes.
class ArkitAxes {
  const ArkitAxes({this.mirror = false, this.swapEyes = false});
  static const standard = ArkitAxes();
  final bool mirror, swapEyes;

  Map<String, Object?> toJson() => {'mirror': mirror, 'swapEyes': swapEyes};
  factory ArkitAxes.fromJson(Map<String, dynamic> json) => ArkitAxes(
    mirror: json['mirror'] as bool? ?? false,
    swapEyes: json['swapEyes'] as bool? ?? false,
  );
}

/// One ARKit face as sent by the iOS bridge (`FaceTrackingPlugin.swift`).
/// Matrices are 4×4, column-major, as `simd_float4x4` stores them.
class ArkitFaceRaw {
  const ArkitFaceRaw({
    required this.id,
    required this.tracked,
    this.faceInCamera,
    this.leftEye,
    this.rightEye,
    this.lookAt,
    this.blendshapes = const {},
    this.bounds,
  });

  /// Session-local face number (stable while ARKit keeps the anchor).
  final int id;
  final bool tracked;

  /// Face pose in camera space: `camera.transform⁻¹ · anchor.transform`.
  final List<double>? faceInCamera;

  /// Eye poses in face space (`leftEyeTransform`, `rightEyeTransform`).
  final List<double>? leftEye, rightEye;

  /// `lookAtPoint` in face space.
  final List<double>? lookAt;

  /// Raw ARKit names (`eyeBlink_L`, `jawOpen`, …).
  final Map<String, double> blendshapes;

  /// x, y, width, height in portrait display pixels.
  final List<double>? bounds;

  static List<double>? _numbers(Object? value, int length) {
    if (value is! List || value.length != length) return null;
    final result = <double>[];
    for (final item in value) {
      if (item is! num || !item.isFinite) return null;
      result.add(item.toDouble());
    }
    return result;
  }

  factory ArkitFaceRaw.fromMap(Map<Object?, Object?> map) {
    final shapes = map['blendshapes'];
    return ArkitFaceRaw(
      id: (map['id'] as num).toInt(),
      tracked: map['tracked'] == true,
      faceInCamera: _numbers(map['faceInCamera'], 16),
      leftEye: _numbers(map['leftEye'], 16),
      rightEye: _numbers(map['rightEye'], 16),
      lookAt: _numbers(map['lookAt'], 3),
      blendshapes: shapes is Map
          ? {
              for (final e in shapes.entries)
                if (e.key is String &&
                    e.value is num &&
                    (e.value as num).isFinite)
                  e.key as String: (e.value as num).toDouble(),
            }
          : const {},
      bounds: _numbers(map['bounds'], 4),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'tracked': tracked,
    if (faceInCamera != null) 'faceInCamera': faceInCamera,
    if (leftEye != null) 'leftEye': leftEye,
    if (rightEye != null) 'rightEye': rightEye,
    if (lookAt != null) 'lookAt': lookAt,
    if (blendshapes.isNotEmpty) 'blendshapes': blendshapes,
    if (bounds != null) 'bounds': bounds,
  };
}

/// Small 3-vector helper; the math here is a handful of dot/cross products.
class Vec3 {
  const Vec3(this.x, this.y, this.z);
  final double x, y, z;
  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);
  Vec3 operator -() => Vec3(-x, -y, -z);
  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) =>
      Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get length => math.sqrt(dot(this));
  Vec3 get unit {
    final l = length;
    return l > 1e-9 ? this * (1 / l) : this;
  }

  @override
  String toString() => 'Vec3($x, $y, $z)';
}

/// Column [c] (0..3) of a column-major 4×4 matrix, xyz part.
Vec3 column(List<double> m, int c) =>
    Vec3(m[c * 4], m[c * 4 + 1], m[c * 4 + 2]);

const _deg = 180 / math.pi;

/// The driver's frame expressed in camera space, built from geometry the
/// device measures rather than from assumed axis names:
/// - [toDriver]: from the camera towards the face (the optical axis, ±z);
/// - [up]: the camera axis (±x or ±y) closest to gravity "up", so a phone in
///   portrait or landscape both work;
/// - [right]: the driver's own right, `up × toDriver` in a right-handed space.
class DriverFrame {
  DriverFrame._(this.right, this.up, this.toDriver);
  final Vec3 right, up, toDriver;

  /// [facePosition] is the face origin in camera space; [gravityUp] is world
  /// up in camera space. Returns null when either is degenerate.
  static DriverFrame? from({
    required Vec3 facePosition,
    required Vec3 gravityUp,
    bool mirror = false,
  }) {
    if (facePosition.z.abs() < 1e-6 || gravityUp.length < 1e-6) return null;
    final toDriver = Vec3(0, 0, facePosition.z.sign);
    final candidates = const [
      Vec3(1, 0, 0),
      Vec3(-1, 0, 0),
      Vec3(0, 1, 0),
      Vec3(0, -1, 0),
    ];
    var up = candidates.first;
    var best = -double.infinity;
    for (final c in candidates) {
      final score = c.dot(gravityUp);
      if (score > best) {
        best = score;
        up = c;
      }
    }
    final right = up.cross(toDriver);
    return DriverFrame._(mirror ? -right : right, up, toDriver);
  }

  /// Components of a camera-space direction along (right, up, toDriver).
  Vec3 local(Vec3 v) => Vec3(v.dot(right), v.dot(up), v.dot(toDriver));
}

/// Yaw to the driver's left and pitch down of a direction given in driver
/// coordinates ([DriverFrame.local]) that should point from the face to the
/// camera when the driver looks straight at it.
({double left, double down}) _lookAngles(Vec3 d) => (
  left: math.atan2(-d.x, -d.z) * _deg,
  down: math.atan2(-d.y, math.sqrt(d.x * d.x + d.z * d.z)) * _deg,
);

/// ARKit `eyeBlink_L` → contract `eyeBlinkLeft`; other names unchanged.
String contractBlendshapeName(String arkitName, {bool swap = false}) {
  final l = swap ? 'Right' : 'Left', r = swap ? 'Left' : 'Right';
  if (arkitName.endsWith('_L')) {
    return '${arkitName.substring(0, arkitName.length - 2)}$l';
  }
  if (arkitName.endsWith('_R')) {
    return '${arkitName.substring(0, arkitName.length - 2)}$r';
  }
  return arkitName;
}

double _unit(double v) => v.isNaN ? 0 : v.clamp(0.0, 1.0).toDouble();

/// Contract signals of one ARKit face. Untracked faces carry no numbers: a
/// stale pose must never reach the automata.
///
/// [boxFrame] is the portrait display size that [ArkitFaceRaw.bounds] refer
/// to, and whether that display is mirrored; with it the signals get the
/// contract's unmirrored, normalized [FaceSignals.box].
FaceSignals arkitSignals(
  ArkitFaceRaw raw, {
  required List<double> gravityUp,
  ArkitAxes axes = ArkitAxes.standard,
  ({double width, double height, bool mirrored})? boxFrame,
}) {
  final pose = raw.faceInCamera;
  if (!raw.tracked || pose == null || gravityUp.length != 3) {
    return FaceSignals(
      engineId: arkitCapabilities.id,
      trackingId: raw.id,
      tracked: false,
    );
  }
  final position = column(pose, 3);
  final frame = DriverFrame.from(
    facePosition: position,
    gravityUp: Vec3(gravityUp[0], gravityUp[1], gravityUp[2]),
    mirror: axes.mirror,
  );
  if (frame == null) {
    return FaceSignals(
      engineId: arkitCapabilities.id,
      trackingId: raw.id,
      tracked: false,
    );
  }
  final faceX = column(pose, 0).unit,
      faceY = column(pose, 1).unit,
      faceZ = column(pose, 2).unit;
  Vec3 toCamera(Vec3 v) => faceX * v.x + faceY * v.y + faceZ * v.z;

  // Head: forward is the face's +z (out of the face, towards the camera).
  final forward = frame.local(faceZ);
  final head = _lookAngles(forward);
  // Roll from the face's up vector against a level frame with the same yaw
  // and pitch; the face's own x axis is not needed.
  final faceUp = frame.local(faceY);
  final levelRight = forward.cross(const Vec3(0, 1, 0)).unit;
  final levelUp = levelRight.cross(forward).unit;
  final rollRight =
      math.atan2(faceUp.dot(levelRight), faceUp.dot(levelUp)) * _deg;

  // Gaze: from the middle between the eyes to lookAtPoint, in face space.
  double? gazeLeft, gazeDown, eyeGazeLeft, eyeGazeDown;
  final left = raw.leftEye, right = raw.rightEye, look = raw.lookAt;
  if (look != null) {
    final origin = left != null && right != null
        ? (column(left, 3) + column(right, 3)) * .5
        : const Vec3(0, 0, 0);
    var direction = (Vec3(look[0], look[1], look[2]) - origin).unit;
    // Eyes cannot look backwards: guard against an inverted convention.
    if (direction.z < 0) direction = -direction;
    final g = _lookAngles(frame.local(toCamera(direction)));
    gazeLeft = g.left;
    gazeDown = g.down;
  }
  if (left != null && right != null) {
    var eye = (column(left, 2).unit + column(right, 2).unit).unit;
    if (eye.z < 0) eye = -eye;
    // Face space: +x is the face's own left, +y up, +z forward.
    final side = axes.mirror ? -eye.x : eye.x;
    eyeGazeLeft = math.atan2(side, eye.z) * _deg;
    eyeGazeDown =
        math.atan2(-eye.y, math.sqrt(eye.x * eye.x + eye.z * eye.z)) * _deg;
  }

  // Exact pose: face axes in the upright camera-fixed head frame
  // (+x driver's left, +y up, +z towards the camera). With [ArkitAxes.mirror]
  // both the frame's and the face's left flip, which keeps it a rotation.
  final leftSign = axes.mirror ? -1.0 : 1.0;
  final hx = -frame.right, hy = frame.up, hz = -frame.toDriver;
  Vec3 inHead(Vec3 v) => Vec3(v.dot(hx), v.dot(hy), v.dot(hz));
  final headRotation = quaternionFromAxes(
    inHead(faceX * leftSign),
    inHead(faceY),
    inHead(faceZ),
  );

  final shapes = <String, double>{
    for (final e in raw.blendshapes.entries)
      contractBlendshapeName(e.key, swap: axes.swapEyes): _unit(e.value),
  };
  final blinkLeft = shapes[Blendshape.eyeBlinkLeft],
      blinkRight = shapes[Blendshape.eyeBlinkRight];
  final distance = position.length;
  return FaceSignals(
    box: _box(raw.bounds, boxFrame),
    engineId: arkitCapabilities.id,
    trackingId: raw.id,
    tracked: true,
    headYawLeft: head.left,
    headPitchDown: head.down,
    headRollRight: rollRight,
    gazeLeft: gazeLeft,
    gazeDown: gazeDown,
    eyeGazeLeft: eyeGazeLeft,
    eyeGazeDown: eyeGazeDown,
    eyeOpenLeft: blinkLeft == null ? null : 1 - blinkLeft,
    eyeOpenRight: blinkRight == null ? null : 1 - blinkRight,
    distanceM: distance.isFinite && distance > 0 ? distance : null,
    headRotation: headRotation,
    blendshapes: Map.unmodifiable(shapes),
  );
}

/// Unit quaternion `[w, x, y, z]` (w ≥ 0) of the rotation whose matrix has
/// columns [x], [y], [z]. The axes are re-orthonormalized from [z] and [y]
/// first; null when they are degenerate.
List<double>? quaternionFromAxes(Vec3 x, Vec3 y, Vec3 z) {
  final c2 = z.unit;
  final c0 = y.cross(c2).unit;
  final c1 = c2.cross(c0);
  if (c0.length < .5 || c2.length < .5 || c0.dot(x) <= 0) return null;
  final m00 = c0.x, m01 = c1.x, m02 = c2.x;
  final m10 = c0.y, m11 = c1.y, m12 = c2.y;
  final m20 = c0.z, m21 = c1.z, m22 = c2.z;
  final trace = m00 + m11 + m22;
  double w, qx, qy, qz;
  if (trace > 0) {
    final s = math.sqrt(trace + 1) * 2;
    w = s / 4;
    qx = (m21 - m12) / s;
    qy = (m02 - m20) / s;
    qz = (m10 - m01) / s;
  } else if (m00 > m11 && m00 > m22) {
    final s = math.sqrt(1 + m00 - m11 - m22) * 2;
    w = (m21 - m12) / s;
    qx = s / 4;
    qy = (m01 + m10) / s;
    qz = (m02 + m20) / s;
  } else if (m11 > m22) {
    final s = math.sqrt(1 + m11 - m00 - m22) * 2;
    w = (m02 - m20) / s;
    qx = (m01 + m10) / s;
    qy = s / 4;
    qz = (m12 + m21) / s;
  } else {
    final s = math.sqrt(1 + m22 - m00 - m11) * 2;
    w = (m10 - m01) / s;
    qx = (m02 + m20) / s;
    qy = (m12 + m21) / s;
    qz = s / 4;
  }
  final sign = w < 0 ? -1 : 1;
  final n = math.sqrt(w * w + qx * qx + qy * qy + qz * qz) * sign;
  final q = [w / n, qx / n, qy / n, qz / n];
  return q.every((v) => v.isFinite) ? List.unmodifiable(q) : null;
}

FaceBox? _box(
  List<double>? bounds,
  ({double width, double height, bool mirrored})? frame,
) {
  if (bounds == null || frame == null) return null;
  if (!(frame.width > 0 && frame.height > 0)) return null;
  final width = bounds[2] / frame.width, height = bounds[3] / frame.height;
  var left = bounds[0] / frame.width;
  if (frame.mirrored) left = 1 - left - width;
  final box = FaceBox(
    left: left,
    top: bounds[1] / frame.height,
    width: width,
    height: height,
  );
  try {
    box.validate();
  } on FormatException {
    return null;
  }
  return box;
}

/// How to show `capturedImage` upright on a portrait screen, read from
/// `ARFrame.displayTransform(for: .portrait, …)` = [a, b, c, d, tx, ty].
/// [quarterTurns] is clockwise, as in Flutter's `RotatedBox`; [mirrored] is a
/// horizontal flip of the image before the rotation, i.e.
/// `RotatedBox(quarterTurns, child: Transform.flip(flipX: mirrored, …))`.
({int quarterTurns, bool mirrored})? displayOrientation(List<double> t) {
  if (t.length < 4) return null;
  final a = t[0], b = t[1], c = t[2], d = t[3];
  int? sign(double v) =>
      v > .5 ? 1 : (v < -.5 ? -1 : (v.abs() < .5 ? 0 : null));
  final sa = sign(a), sb = sign(b), sc = sign(c), sd = sign(d);
  if (sa == null || sb == null || sc == null || sd == null) return null;
  // CGAffineTransform maps (x, y) → (a·x + c·y, b·x + d·y) in normalized
  // coordinates with y pointing down. Rotations have det +1, flips −1.
  final det = sa * sd - sb * sc;
  if (det == 0) return null;
  final mirrored = det < 0;
  // Undo the flip (x → −x) to read the pure rotation.
  final ra = mirrored ? -sa : sa, rb = mirrored ? -sb : sb;
  // Image +x axis goes to (ra, rb) on screen (y down).
  final turns = switch ((ra, rb)) {
    (1, 0) => 0,
    (0, 1) => 1,
    (-1, 0) => 2,
    (0, -1) => 3,
    _ => null,
  };
  if (turns == null) return null;
  return (quarterTurns: turns, mirrored: mirrored);
}

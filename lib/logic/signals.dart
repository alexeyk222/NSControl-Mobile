import 'face.dart';

/// Engine-neutral per-face signals: the shared contract between the face
/// engines (ML Kit, ARKit), the recognition lab / telemetry and the attention
/// logic. Engines fill what they can measure and leave the rest null; consumers
/// must treat null as "not measured", never as zero.
///
/// Angles are degrees relative to the camera (not to the calibration), seen
/// from the driver's own point of view:
/// - [headYawLeft] > 0 — head turned to the driver's own left;
/// - [headPitchDown] > 0 — head tilted down (same sign as
///   [FaceMeasurement.pitchDown]);
/// - [headRollRight] > 0 — head tilted toward the driver's right shoulder;
/// - [gazeLeft] / [gazeDown] — where the eyes look (head plus eyes), same
///   signs as the head angles;
/// - [eyeGazeLeft] / [eyeGazeDown] — eye-in-head angles, same signs.
///
/// Eye openness is 0..1 with 1 = fully open, the scale the ТЗ automata and the
/// calibration threshold T already use. Blendshapes are 0..1 coefficients named
/// as in ARKit / MediaPipe (see [Blendshape]); "Left"/"Right" mean the driver's
/// own left/right eye. An adapter must normalize its engine to these
/// conventions and prove each sign on a device before its values are trusted.
class FaceSignals {
  const FaceSignals({
    required this.engineId,
    this.trackingId,
    this.tracked = true,
    this.headYawLeft,
    this.headPitchDown,
    this.headRollRight,
    this.gazeLeft,
    this.gazeDown,
    this.eyeGazeLeft,
    this.eyeGazeDown,
    this.eyeOpenLeft,
    this.eyeOpenRight,
    this.distanceM,
    this.box,
    this.blendshapes = const {},
  });

  /// [DetectorCapabilities.id] of the engine that produced the signals.
  final String engineId;
  final int? trackingId;

  /// False when the engine reports the face as present but not reliably
  /// tracked (for example ARKit `isTracked == false`).
  final bool tracked;
  final double? headYawLeft, headPitchDown, headRollRight;
  final double? gazeLeft, gazeDown, eyeGazeLeft, eyeGazeDown;
  final double? eyeOpenLeft, eyeOpenRight;

  /// Distance from the camera to the face, metres, when the engine knows it.
  final double? distanceM;

  /// Face rectangle in the upright analysed image (after rotation, not
  /// mirrored), normalized to 0..1 of its width and height, origin top-left.
  /// Used to keep the driver's identity across tracking-id changes (ФТ-02,
  /// ФТ-03); null when the engine does not report it.
  final FaceBox? box;
  final Map<String, double> blendshapes;

  bool get hasGaze =>
      FaceMeasurement.angle(gazeLeft) && FaceMeasurement.angle(gazeDown);

  double? blendshape(String name) => blendshapes[name];

  /// Input for the ТЗ automata (ФТ-04/ФТ-05). Thresholds stay in the
  /// automata; this only maps the shared conventions onto [FaceMeasurement].
  FaceMeasurement toMeasurement() => FaceMeasurement(
    trackingId: trackingId,
    leftEye: eyeOpenLeft,
    rightEye: eyeOpenRight,
    pitchDown: headPitchDown,
    yaw: headYawLeft,
    roll: headRollRight,
  );

  /// Fails on values outside the contract instead of passing them on.
  void validate() {
    if (engineId.isEmpty) throw const FormatException('engineId is empty');
    for (final angle in [
      headYawLeft,
      headPitchDown,
      headRollRight,
      gazeLeft,
      gazeDown,
      eyeGazeLeft,
      eyeGazeDown,
    ]) {
      if (angle != null && !FaceMeasurement.angle(angle)) {
        throw FormatException('angle out of range: $angle');
      }
    }
    for (final value in [eyeOpenLeft, eyeOpenRight, ...blendshapes.values]) {
      if (value != null && !FaceMeasurement.probability(value)) {
        throw FormatException('value out of 0..1: $value');
      }
    }
    if (distanceM != null && !(distanceM!.isFinite && distanceM! > 0)) {
      throw FormatException('distance out of range: $distanceM');
    }
    box?.validate();
  }

  Map<String, Object?> toJson() => {
    'engine': engineId,
    if (trackingId != null) 'trackingId': trackingId,
    'tracked': tracked,
    if (headYawLeft != null) 'headYawLeft': headYawLeft,
    if (headPitchDown != null) 'headPitchDown': headPitchDown,
    if (headRollRight != null) 'headRollRight': headRollRight,
    if (gazeLeft != null) 'gazeLeft': gazeLeft,
    if (gazeDown != null) 'gazeDown': gazeDown,
    if (eyeGazeLeft != null) 'eyeGazeLeft': eyeGazeLeft,
    if (eyeGazeDown != null) 'eyeGazeDown': eyeGazeDown,
    if (eyeOpenLeft != null) 'eyeOpenLeft': eyeOpenLeft,
    if (eyeOpenRight != null) 'eyeOpenRight': eyeOpenRight,
    if (distanceM != null) 'distanceM': distanceM,
    if (box != null) 'box': box!.toJson(),
    if (blendshapes.isNotEmpty) 'blendshapes': blendshapes,
  };

  factory FaceSignals.fromJson(Map<String, dynamic> json) {
    double? d(String key) => (json[key] as num?)?.toDouble();
    final shapes = (json['blendshapes'] as Map<String, dynamic>?) ?? const {};
    final result = FaceSignals(
      engineId: json['engine'] as String,
      trackingId: json['trackingId'] as int?,
      tracked: (json['tracked'] as bool?) ?? true,
      headYawLeft: d('headYawLeft'),
      headPitchDown: d('headPitchDown'),
      headRollRight: d('headRollRight'),
      gazeLeft: d('gazeLeft'),
      gazeDown: d('gazeDown'),
      eyeGazeLeft: d('eyeGazeLeft'),
      eyeGazeDown: d('eyeGazeDown'),
      eyeOpenLeft: d('eyeOpenLeft'),
      eyeOpenRight: d('eyeOpenRight'),
      distanceM: d('distanceM'),
      box: json['box'] == null
          ? null
          : FaceBox.fromJson(Map<String, dynamic>.from(json['box'] as Map)),
      blendshapes: Map.unmodifiable({
        for (final e in shapes.entries) e.key: (e.value as num).toDouble(),
      }),
    );
    result.validate();
    return result;
  }
}

/// Normalized face rectangle, see [FaceSignals.box]. A face partly outside
/// the image may extend a little beyond 0..1.
class FaceBox {
  const FaceBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
  final double left, top, width, height;

  double get centerX => left + width / 2;
  double get centerY => top + height / 2;

  void validate() {
    if (![left, top, width, height].every((v) => v.isFinite) ||
        width <= 0 ||
        height <= 0 ||
        width > 1.5 ||
        height > 1.5 ||
        left < -1 ||
        top < -1 ||
        left + width > 2 ||
        top + height > 2) {
      throw FormatException('face box out of range: ${toJson()}');
    }
  }

  Map<String, Object?> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  factory FaceBox.fromJson(Map<String, dynamic> json) {
    double d(String key) => (json[key] as num).toDouble();
    return FaceBox(
      left: d('left'),
      top: d('top'),
      width: d('width'),
      height: d('height'),
    );
  }
}

/// Blendshape names shared by ARKit and MediaPipe that the attention logic
/// reads. Engines may send more; consumers ignore unknown names.
abstract final class Blendshape {
  static const eyeBlinkLeft = 'eyeBlinkLeft';
  static const eyeBlinkRight = 'eyeBlinkRight';
  static const eyeLookDownLeft = 'eyeLookDownLeft';
  static const eyeLookDownRight = 'eyeLookDownRight';
  static const eyeLookUpLeft = 'eyeLookUpLeft';
  static const eyeLookUpRight = 'eyeLookUpRight';
  static const eyeLookInLeft = 'eyeLookInLeft';
  static const eyeLookInRight = 'eyeLookInRight';
  static const eyeLookOutLeft = 'eyeLookOutLeft';
  static const eyeLookOutRight = 'eyeLookOutRight';
  static const eyeSquintLeft = 'eyeSquintLeft';
  static const eyeSquintRight = 'eyeSquintRight';
  static const eyeWideLeft = 'eyeWideLeft';
  static const eyeWideRight = 'eyeWideRight';
  static const jawOpen = 'jawOpen';
}

/// Where the driver looks, decided per frame by the attention logic.
/// Only [road] counts as "on road"; mirrors and instruments are driving-related
/// glances that never raise an alarm by themselves.
enum GazeZone {
  road('road'),
  mirrorLeft('mirror_left'),
  mirrorRight('mirror_right'),
  mirrorRear('mirror_rear'),
  instruments('instruments'),
  console('console'),
  offCamera('off_camera'),
  unknown('unknown');

  const GazeZone(this.code);
  final String code;

  bool get drivingRelated => switch (this) {
    road || mirrorLeft || mirrorRight || mirrorRear || instruments => true,
    console || offCamera || unknown => false,
  };

  static GazeZone fromCode(String code) => values.firstWhere(
    (zone) => zone.code == code,
    orElse: () => throw FormatException('unknown zone: $code'),
  );
}

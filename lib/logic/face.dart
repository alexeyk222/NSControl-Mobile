class DetectorCapabilities {
  const DetectorCapabilities({
    required this.id,
    required this.version,
    required this.eyeYawLimit,
  });

  static const mlKit = DetectorCapabilities(
    id: 'mlkit_face_detection',
    version: '0.15.1',
    eyeYawLimit: 18,
  );
  final String id, version;
  final double eyeYawLimit;

  bool get valid =>
      id.isNotEmpty &&
      version.isNotEmpty &&
      eyeYawLimit.isFinite &&
      eyeYawLimit >= 0 &&
      eyeYawLimit <= 90;

  bool matches(DetectorCapabilities other) =>
      id == other.id &&
      version == other.version &&
      eyeYawLimit == other.eyeYawLimit;

  Map<String, Object?> toJson() => {
    'id': id,
    'version': version,
    'eyeYawLimit': eyeYawLimit,
  };
  factory DetectorCapabilities.fromJson(Map<String, dynamic> json) {
    final result = DetectorCapabilities(
      id: json['id'] as String,
      version: json['version'] as String,
      eyeYawLimit: (json['eyeYawLimit'] as num).toDouble(),
    );
    if (!result.valid) {
      throw const FormatException('Некорректные возможности детектора');
    }
    return result;
  }
}

/// The adapter supplies degrees with positive pitch pointing down.
class FaceMeasurement {
  const FaceMeasurement({
    this.trackingId,
    this.leftEye,
    this.rightEye,
    this.pitchDown,
    this.yaw,
    this.roll,
  });
  final int? trackingId;
  final double? leftEye, rightEye, pitchDown, yaw, roll;

  bool get hasEyes => probability(leftEye) && probability(rightEye);
  bool get hasHeadAngles => angle(pitchDown) && angle(yaw) && angle(roll);
  static bool probability(double? value) =>
      value != null && value.isFinite && value >= 0 && value <= 1;
  static bool angle(double? value) =>
      value != null && value.isFinite && value.abs() <= 180;
}

import 'attention_zones.dart';
import 'calibration.dart';
import 'face.dart';
import 'holder_shift.dart';
import 'settings.dart';

/// Every detection threshold in one versioned set.
///
/// The ТЗ 2.2 numbers ([tz22]) stay as the reference for comparison with
/// earlier results. The working profile is tuned on labelled recordings
/// (`tool/tune.dart`) against the quality targets: eyes_closed recall ≥ 90 %,
/// head_pitch_down recall ≥ 85 %, at most one false alarm per hour, and no
/// alarm on mirrors, instruments or intersections. The profile is written to
/// the recording (`meta.detectionProfile`) and to each calibration line.
class DetectionProfile {
  const DetectionProfile({
    required this.id,
    this.eyeThresholds = const {},
    this.eyesClosedUs = 1500000,
    this.pitchThreshold = 20,
    this.headDownUs = 2000000,
    this.headYawLimit = 30,
    this.maximumGapUs = 300000,
    this.eyeYawLimits = const {},
    this.attention = const AttentionSettings(),
    this.holderShift = const HolderShiftSettings(),
    this.basis,
  });

  /// Profile name, e.g. `tz-2.2` or `v1`.
  final String id;

  /// Eye threshold T in the engine's own units (openness or probability) by
  /// engine id. An engine not listed keeps the ТЗ 2.2 rule
  /// T = min(0.4; 0.5 · min(calibrated eyes)).
  final Map<String, double> eyeThresholds;

  /// The calibration rule (share, cap) giving this profile's T for an
  /// engine: a fixed T is share 1 capped at T.
  (double, double) eyeRule(String engineId) {
    final t = eyeThresholds[engineId];
    return t == null
        ? (CalibrationProfile.defaultEyeShare, CalibrationProfile.defaultEyeCap)
        : (1, t);
  }

  /// Both eyes below T for this long: `eyes_closed`.
  final int eyesClosedUs;

  /// Head lowered more than [pitchThreshold] degrees for [headDownUs], while
  /// turned no more than [headYawLimit] from the road: `head_pitch_down`.
  final double pitchThreshold, headYawLimit;
  final int headDownUs;

  /// A frame gap longer than this resets an automaton's timer (ТЗ 2.2:
  /// 300 ms). Short tracking losses must not reset it (ADDW 2023/2590,
  /// § 3.3.2.4); the lab camera pauses 0.5–0.6 s after each voice prompt.
  final int maximumGapUs;

  /// Eye view limit (|yaw to the camera|, degrees) by engine id; an engine
  /// not listed keeps its own [DetectorCapabilities.eyeYawLimit].
  final Map<String, double> eyeYawLimits;

  /// Eye gate, side mount, driver continuity and distraction.
  final AttentionSettings attention;

  /// What the numbers were chosen on (people, episodes, recordings), shown
  /// in reports; null for the reference.
  final String? basis;

  /// Sudden holder shift (FR-CAL-08): when to suggest a new calibration.
  final HolderShiftSettings holderShift;

  /// ТЗ 2.2 as written: the reference for comparison only.
  static const tz22 = DetectionProfile(
    id: 'tz-2.2',
    attention: AttentionSettings.acceptance(),
  );

  /// Profile v1 (25.11.2026), chosen by `tool/tune.dart` on session 1: one
  /// participant, the left vent grille (docs/attention-method.md, п. 10).
  /// Preliminary until more people are recorded. The head threshold is
  /// common to both engines (joint feasible region); ARKit alone would take
  /// 17°.
  static const v1 = DetectionProfile(
    id: 'v1',
    eyeThresholds: {'arkit_face_tracking': .25},
    eyesClosedUs: 1600000,
    pitchThreshold: 19,
    headDownUs: 1500000,
    eyeYawLimits: {'arkit_face_tracking': 50, 'mlkit_face_detection': 10},
    attention: AttentionSettings(
      gazeAwareEyes: true,
      mountRelative: true,
      roadAdaptDegPerMin: 1,
    ),
    basis:
        'сессия 1 (25–26.11.2026): 1 участник, iPhone 11, левая решётка 38°; '
        'bench-v1 001948 (ARKit + ML Kit) и signs-v1 000944 (ARKit), 000546 '
        '(ML Kit); 4 закрытия глаз, 3 наклона головы, 12,7 мин. Порог '
        'головы предварительный',
  );

  static const all = [tz22, v1];

  /// The default of the trip and the lab.
  static const current = v1;

  static DetectionProfile byId(String id) => all.firstWhere(
    (p) => p.id == id,
    orElse: () => throw ArgumentError('Нет профиля $id'),
  );

  bool get isReference => id == tz22.id;

  String get label => isReference ? 'ТЗ 2.2 (эталон)' : 'профиль $id';

  /// Engine parameters of the automata.
  AlgorithmSettings algorithm({required bool hiddenEyes}) => AlgorithmSettings(
    eyesClosedUs: eyesClosedUs,
    headDownUs: headDownUs,
    pitchThreshold: pitchThreshold,
    headYawLimit: headYawLimit,
    hiddenEyes: hiddenEyes,
    maximumGapUs: maximumGapUs,
  );

  /// Settings of an observation session: the user's alarm options (volume,
  /// vibration, escalation, preview, hidden eyes) with this profile's
  /// thresholds. The ТЗ reference keeps the user's thresholds, because the
  /// ТЗ lets the user set them. [hiddenEyes] adds the calibration's verdict.
  AlgorithmSettings session(AlgorithmSettings user, {bool hiddenEyes = false}) {
    final own = !isReference;
    return AlgorithmSettings(
      eyesClosedUs: own ? eyesClosedUs : user.eyesClosedUs,
      headDownUs: own ? headDownUs : user.headDownUs,
      pitchThreshold: own ? pitchThreshold : user.pitchThreshold,
      headYawLimit: own ? headYawLimit : user.headYawLimit,
      maximumGapUs: own ? maximumGapUs : user.maximumGapUs,
      hiddenEyes: user.hiddenEyes || hiddenEyes,
      volume: user.volume,
      vibration: user.vibration,
      showPreview: user.showPreview,
      escalate: user.escalate,
    );
  }

  /// [c] with this profile's eye threshold rule for its engine.
  CalibrationProfile calibrate(CalibrationProfile c) {
    final (share, cap) = eyeRule(c.detector.id);
    return c.withEyeRule(share: share, cap: cap);
  }

  /// The engine's capabilities with this profile's eye view limit.
  DetectorCapabilities detector(DetectorCapabilities base) {
    final limit = eyeYawLimits[base.id];
    return limit == null || limit == base.eyeYawLimit
        ? base
        : DetectorCapabilities(
            id: base.id,
            version: base.version,
            eyeYawLimit: limit,
          );
  }

  DetectionProfile copyWith({
    String? id,
    Map<String, double>? eyeThresholds,
    int? eyesClosedUs,
    double? pitchThreshold,
    int? headDownUs,
    double? headYawLimit,
    int? maximumGapUs,
    Map<String, double>? eyeYawLimits,
    AttentionSettings? attention,
    HolderShiftSettings? holderShift,
    String? basis,
  }) => DetectionProfile(
    id: id ?? this.id,
    eyeThresholds: eyeThresholds ?? this.eyeThresholds,
    eyesClosedUs: eyesClosedUs ?? this.eyesClosedUs,
    pitchThreshold: pitchThreshold ?? this.pitchThreshold,
    headDownUs: headDownUs ?? this.headDownUs,
    headYawLimit: headYawLimit ?? this.headYawLimit,
    maximumGapUs: maximumGapUs ?? this.maximumGapUs,
    eyeYawLimits: eyeYawLimits ?? this.eyeYawLimits,
    attention: attention ?? this.attention,
    holderShift: holderShift ?? this.holderShift,
    basis: basis ?? this.basis,
  );

  /// One line for reports.
  String get summary =>
      'T ${eyeThresholds.isEmpty ? 'по ТЗ' : eyeThresholds.entries.map((e) => '${e.key} ${_n(e.value)}').join(', ')}, '
      'глаза ${_s(eyesClosedUs)}; голова > ${_n(pitchThreshold)}° за '
      '${_s(headDownUs)} при |повороте| ≤ ${_n(headYawLimit)}°; '
      'разрыв кадров до ${maximumGapUs ~/ 1000} мс'
      '${eyeYawLimits.isEmpty ? '' : '; предел вида глаз ${eyeYawLimits.entries.map((e) => '${e.key} ${_n(e.value)}°').join(', ')}'}'
      '${attention.yawnJaw == null ? '' : '; затвор зевка jawOpen ≥ ${_n(attention.yawnJaw!)}'}'
      '${attention.roadAdaptDegPerMin == null ? '' : '; подстройка позы «дорога» до ${_n(attention.roadAdaptDegPerMin!)}°/мин'}';

  static String _n(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();
  static String _s(int us) => '${(us / 1e6).toStringAsFixed(1)} с';

  Map<String, Object?> toJson() => {
    'id': id,
    if (eyeThresholds.isNotEmpty) 'eyeThresholds': eyeThresholds,
    'eyesClosedUs': eyesClosedUs,
    'pitchThreshold': pitchThreshold,
    'headDownUs': headDownUs,
    'headYawLimit': headYawLimit,
    'maximumGapUs': maximumGapUs,
    if (eyeYawLimits.isNotEmpty) 'eyeYawLimits': eyeYawLimits,
    'attention': attention.toJson(),
    'holderShift': holderShift.toJson(),
    if (basis != null) 'basis': basis,
  };

  factory DetectionProfile.fromJson(Map<String, dynamic> json) =>
      DetectionProfile(
        id: json['id'] as String,
        eyeThresholds: _doubles(json['eyeThresholds']),
        eyesClosedUs: (json['eyesClosedUs'] as int?) ?? 1500000,
        pitchThreshold: (json['pitchThreshold'] as num?)?.toDouble() ?? 20,
        headDownUs: (json['headDownUs'] as int?) ?? 2000000,
        headYawLimit: (json['headYawLimit'] as num?)?.toDouble() ?? 30,
        maximumGapUs: (json['maximumGapUs'] as int?) ?? 300000,
        eyeYawLimits: _doubles(json['eyeYawLimits']),
        attention: json['attention'] is Map
            ? AttentionSettings.fromJson(
                Map<String, dynamic>.from(json['attention'] as Map),
              )
            : const AttentionSettings(),
        holderShift: json['holderShift'] is Map
            ? HolderShiftSettings.fromJson(
                Map<String, dynamic>.from(json['holderShift'] as Map),
              )
            : const HolderShiftSettings(),
        basis: json['basis'] as String?,
      );
}

Map<String, double> _doubles(Object? json) => {
  for (final e in ((json as Map?) ?? const {}).entries)
    e.key as String: (e.value as num).toDouble(),
};

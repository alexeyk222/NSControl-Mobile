/// Immutable parameters. A parameter change requires a new observation session.
class AlgorithmSettings {
  AlgorithmSettings({
    this.eyesClosedUs = 1500000,
    this.headDownUs = 2000000,
    this.pitchThreshold = 20,
    this.headYawLimit = 30,
    this.hiddenEyes = false,
    this.volume = 1,
    this.vibration = true,
    this.showPreview = true,
    this.escalate = true,
  }) {
    if (eyesClosedUs < 1000000 ||
        eyesClosedUs > 3000000 ||
        eyesClosedUs % 100000 != 0 ||
        headDownUs < 1000000 ||
        headDownUs > 5000000 ||
        headDownUs % 100000 != 0 ||
        !pitchThreshold.isFinite ||
        pitchThreshold < 10 ||
        pitchThreshold > 35 ||
        pitchThreshold != pitchThreshold.roundToDouble() ||
        !headYawLimit.isFinite ||
        headYawLimit < 20 ||
        headYawLimit > 45 ||
        headYawLimit != headYawLimit.roundToDouble() ||
        !volume.isFinite ||
        volume < 0 ||
        volume > 1) {
      throw ArgumentError(
        'Параметры алгоритма вне допустимого диапазона или шага',
      );
    }
  }

  final int eyesClosedUs, headDownUs;
  final double pitchThreshold, headYawLimit, volume;
  final bool hiddenEyes, vibration, showPreview;

  /// Raise an unacknowledged alarm to full volume with vibration after
  /// [escalationDelayUs] (product extension; the base alarm is unchanged).
  final bool escalate;
  static const escalationDelayUs = 5000000;

  Map<String, Object?> toJson() => {
    'eyesClosedUs': eyesClosedUs,
    'headDownUs': headDownUs,
    'pitchThreshold': pitchThreshold,
    'headYawLimit': headYawLimit,
    'hiddenEyes': hiddenEyes,
    'volume': volume,
    'vibration': vibration,
    'showPreview': showPreview,
    'escalate': escalate,
  };

  factory AlgorithmSettings.fromJson(Map<String, dynamic> json) =>
      AlgorithmSettings(
        eyesClosedUs: _integer(json['eyesClosedUs'], 1500000),
        headDownUs: _integer(json['headDownUs'], 2000000),
        pitchThreshold: _number(json['pitchThreshold'], 20),
        headYawLimit: _number(json['headYawLimit'], 30),
        volume: _number(json['volume'], 1),
        hiddenEyes: _boolean(json['hiddenEyes'], false),
        vibration: _boolean(json['vibration'], true),
        showPreview: _boolean(json['showPreview'], true),
        escalate: _boolean(json['escalate'], true),
      );
}

int _integer(Object? value, int fallback) {
  if (value == null) return fallback;
  if (value is! int) throw const FormatException('Ожидалось целое число');
  return value;
}

double _number(Object? value, double fallback) {
  if (value == null) return fallback;
  if (value is! num) throw const FormatException('Ожидалось число');
  return value.toDouble();
}

bool _boolean(Object? value, bool fallback) {
  if (value == null) return fallback;
  if (value is! bool) {
    throw const FormatException('Ожидалось логическое значение');
  }
  return value;
}

import 'dart:math' as math;
import 'face.dart';

double median(Iterable<double> values) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty || sorted.any((v) => !v.isFinite)) {
    throw ArgumentError('Медиана требует конечных измерений');
  }
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

double medianAbsoluteDeviation(Iterable<double> values) {
  final list = values.toList();
  final center = median(list);
  return median(list.map((v) => (v - center).abs()));
}

class CalibrationProfile {
  CalibrationProfile({
    required this.trackingId,
    required this.detector,
    required this.hiddenEyes,
    required this.neutralPitch,
    required this.neutralYaw,
    required this.neutralRoll,
    this.leftEyeMedian,
    this.rightEyeMedian,
    this.eyeThreshold,
  }) {
    if (!detector.valid ||
        !FaceMeasurement.angle(neutralPitch) ||
        !FaceMeasurement.angle(neutralYaw) ||
        !FaceMeasurement.angle(neutralRoll)) {
      throw ArgumentError('Некорректные углы калибровки');
    }
    if (hiddenEyes) {
      if (eyeThreshold != null ||
          leftEyeMedian != null ||
          rightEyeMedian != null) {
        throw ArgumentError(
          'Калибровка скрытых глаз не содержит глазной порог',
        );
      }
    } else if (!FaceMeasurement.probability(leftEyeMedian) ||
        !FaceMeasurement.probability(rightEyeMedian) ||
        leftEyeMedian! < .6 ||
        rightEyeMedian! < .6 ||
        eyeThreshold == null ||
        !eyeThreshold!.isFinite ||
        (eyeThreshold! -
                    math.min(
                      .4,
                      .5 * math.min(leftEyeMedian!, rightEyeMedian!),
                    ))
                .abs() >
            1e-12 ||
        neutralYaw.abs() > detector.eyeYawLimit) {
      throw ArgumentError('Непригодная калибровка глаз');
    }
  }
  final int trackingId;
  final DetectorCapabilities detector;
  final bool hiddenEyes;
  final double neutralPitch, neutralYaw, neutralRoll;
  final double? leftEyeMedian, rightEyeMedian, eyeThreshold;

  Map<String, Object?> toJson() => {
    'trackingId': trackingId,
    'detector': detector.toJson(),
    'hiddenEyes': hiddenEyes,
    'neutralPitch': neutralPitch,
    'neutralYaw': neutralYaw,
    'neutralRoll': neutralRoll,
    'leftEyeMedian': leftEyeMedian,
    'rightEyeMedian': rightEyeMedian,
    'eyeThreshold': eyeThreshold,
  };

  factory CalibrationProfile.fromJson(Map<String, dynamic> json) =>
      CalibrationProfile(
        trackingId: json['trackingId'] as int,
        detector: DetectorCapabilities.fromJson(
          Map<String, dynamic>.from(json['detector'] as Map),
        ),
        hiddenEyes: json['hiddenEyes'] as bool,
        neutralPitch: (json['neutralPitch'] as num).toDouble(),
        neutralYaw: (json['neutralYaw'] as num).toDouble(),
        neutralRoll: (json['neutralRoll'] as num).toDouble(),
        leftEyeMedian: (json['leftEyeMedian'] as num?)?.toDouble(),
        rightEyeMedian: (json['rightEyeMedian'] as num?)?.toDouble(),
        eyeThreshold: (json['eyeThreshold'] as num?)?.toDouble(),
      );
}

class CalibrationResult {
  CalibrationResult({
    this.profile,
    required Iterable<String> issues,
    required this.processedFrames,
    required this.usableFrames,
  }) : issues = List.unmodifiable(issues);
  final CalibrationProfile? profile;
  final List<String> issues;
  final int processedFrames, usableFrames;
  bool get successful => profile != null;
}

class CalibrationCollector {
  CalibrationCollector({
    required this.trackingId,
    required this.detector,
    required this.hiddenEyes,
    required this.startedUs,
  }) {
    if (startedUs < 0 || !detector.valid) {
      throw ArgumentError('Некорректная калибровка');
    }
  }
  final int trackingId, startedUs;
  final DetectorCapabilities detector;
  final bool hiddenEyes;
  final List<FaceMeasurement> _usable = [];
  int _processed = 0;
  bool _identityChanged = false;
  int? _lastUs;
  int get processedFrames => _processed;
  int get usableFrames => _usable.length;

  void add({required int capturedUs, required List<FaceMeasurement> faces}) {
    if (capturedUs < startedUs ||
        capturedUs > startedUs + 10000000 ||
        (_lastUs != null && capturedUs <= _lastUs!)) {
      return;
    }
    _lastUs = capturedUs;
    _processed++;
    if (faces.length > 1 ||
        (faces.length == 1 && faces.single.trackingId != trackingId)) {
      _identityChanged = true;
      return;
    }
    if (faces.isEmpty) return;
    final face = faces.single;
    if (!face.hasHeadAngles) return;
    if (!hiddenEyes &&
        (!face.hasEyes || face.yaw!.abs() > detector.eyeYawLimit)) {
      return;
    }
    _usable.add(face);
  }

  CalibrationResult finish({required int nowUs}) {
    final issues = <String>[];
    if (_identityChanged) {
      issues.add(
        'Лицо изменилось или выбор неоднозначен. Подтвердите лицо и повторите калибровку.',
      );
    }
    if (nowUs - startedUs < 10000000) {
      issues.add('Калибровка длится 10 секунд. Дождитесь окончания.');
    }
    if (_usable.length < 90) {
      issues.add(
        'Нужно не менее 90 пригодных кадров. Улучшите освещение и повторите.',
      );
    }
    if (_processed == 0 || _usable.length / _processed < .9) {
      issues.add(
        'Пригодно менее 90% кадров. Удерживайте лицо в кадре и повторите.',
      );
    }
    double? left, right;
    if (_usable.isNotEmpty) {
      for (final values in [
        _usable.map((f) => f.pitchDown!),
        _usable.map((f) => f.yaw!),
        _usable.map((f) => f.roll!),
      ]) {
        if (medianAbsoluteDeviation(values) > 5) {
          issues.add(
            'Положение головы нестабильно. Закрепите телефон и повторите.',
          );
          break;
        }
      }
      if (!hiddenEyes) {
        left = median(_usable.map((f) => f.leftEye!));
        right = median(_usable.map((f) => f.rightEye!));
        if (left < .6 || right < .6) {
          issues.add('Откройте глаза и улучшите освещение; затем повторите.');
        }
        // 0.9 - 0.75 is represented slightly above 0.15 in binary doubles.
        if (medianAbsoluteDeviation(_usable.map((f) => f.leftEye!)) >
                .15 + 1e-12 ||
            medianAbsoluteDeviation(_usable.map((f) => f.rightEye!)) >
                .15 + 1e-12) {
          issues.add('Оценки глаз нестабильны. Устраните блики и повторите.');
        }
      }
    }
    final profile = issues.isNotEmpty
        ? null
        : CalibrationProfile(
            trackingId: trackingId,
            detector: detector,
            hiddenEyes: hiddenEyes,
            neutralPitch: median(_usable.map((f) => f.pitchDown!)),
            neutralYaw: median(_usable.map((f) => f.yaw!)),
            neutralRoll: median(_usable.map((f) => f.roll!)),
            leftEyeMedian: left,
            rightEyeMedian: right,
            eyeThreshold: hiddenEyes
                ? null
                : math.min(.4, .5 * math.min(left!, right!)),
          );
    return CalibrationResult(
      profile: profile,
      issues: issues,
      processedFrames: _processed,
      usableFrames: _usable.length,
    );
  }
}

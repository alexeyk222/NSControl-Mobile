import 'dart:convert';
import 'sleep.dart';

enum SelfAssessment { unknown, notSleepy, sleepy }

enum RecommendationAction {
  noGrounds(0, 'По доступным данным основания для рекомендации не выявлены'),
  reconsiderTripTime(1, 'Пересмотрите время поездки'),
  takeBreak(
    2,
    'Сделайте перерыв: остановитесь в безопасном месте на 15–20 минут',
  ),
  checkCondition(3, 'Продолжительный наклон головы — проверьте состояние'),
  delayAndRest(4, 'Отложите начало поездки и отдохните'),
  stopAndRest(5, 'Остановитесь в безопасном месте для отдыха');

  const RecommendationAction(this.priority, this.label);
  final int priority;
  final String label;
}

enum RecommendationReason {
  eyesClosed('eyes_closed', 'Наблюдалось длительное закрытие глаз'),
  selfReportedSleepiness(
    'self_reported_sleepiness',
    'Вы сообщили о сонливости',
  ),
  insufficientSleep(
    'insufficient_sleep',
    'Возможный недостаток сна за последние 24 часа',
  ),
  headPitchDown(
    'head_pitch_down',
    'Продолжительный наклон головы — проверьте состояние',
  ),
  nightPeriod(
    'night_period',
    'Ночной период повышенной сонливости: 00:00–06:00',
  ),
  fatigueSigns(
    'fatigue_signs',
    'Ранние признаки усталости по камере: долгие моргания или кивки',
  ),
  longDrive('long_drive', 'Непрерывная поездка без перерыва'),
  lowBodyBattery('low_body_battery', 'Низкий запас энергии по данным часов');

  const RecommendationReason(this.code, this.label);
  final String code, label;
}

class Recommendation {
  Recommendation({
    required this.id,
    required this.tripId,
    required this.action,
    required Iterable<RecommendationReason> reasons,
    required this.dataStatus,
    required this.assessment,
    required this.sleep,
    required this.evaluatedAt,
    this.drivingTime,
    this.bodyBattery,
  }) : reasons = List.unmodifiable(reasons);
  static const rulesVersion = '1.1.0';
  final String id, tripId;
  final RecommendationAction action;
  final List<RecommendationReason> reasons;
  final SleepDataStatus dataStatus;
  final SelfAssessment assessment;
  final SleepSummary sleep;
  final DateTime evaluatedAt;
  final Duration? drivingTime;
  final int? bodyBattery;
  int get priority => action.priority;
  bool get actionable => priority > 0;
  String get message => action.label;
  String get dataMessage => dataStatus == SleepDataStatus.insufficient
      ? 'Недостаточно данных для оценки сна'
      : 'Полнота сведений о сне подтверждена';
  List<String> get reasonTexts => List.unmodifiable(
    reasons.map(
      (r) => switch (r) {
        RecommendationReason.insufficientSleep =>
          '${r.label}: ${sleep.duration.inHours} ч ${sleep.duration.inMinutes.remainder(60)} мин, источник: ${sleep.source}',
        RecommendationReason.longDrive when drivingTime != null =>
          '${r.label}: ${drivingTime!.inHours} ч ${drivingTime!.inMinutes.remainder(60)} мин',
        RecommendationReason.lowBodyBattery when bodyBattery != null =>
          '${r.label}: Body Battery $bodyBattery',
        _ => r.label,
      },
    ),
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'tripId': tripId,
    'rulesVersion': rulesVersion,
    'action': action.name,
    'priority': priority,
    'message': message,
    'reasons': reasons.map((r) => r.code).toList(),
    'reasonTexts': reasonTexts,
    'dataStatus': dataStatus.name,
    'assessment': assessment.name,
    'sleep': sleep.toJson(),
    'evaluatedAt': evaluatedAt.toIso8601String(),
    'drivingMinutes': drivingTime?.inMinutes,
    'bodyBattery': bodyBattery,
  };
}

class RecommendationUpdate {
  const RecommendationUpdate({
    required this.recommendation,
    required this.changed,
    required this.shouldNotify,
  });
  final Recommendation recommendation;
  final bool changed, shouldNotify;
}

/// One instance per trip. Acknowledging camera signals does not affect its latch.
class RecommendationEngine {
  RecommendationEngine({required this.tripId, this.breakAfter = longDrive}) {
    if (tripId.isEmpty) throw ArgumentError('Поездка должна иметь ID');
  }
  final String tripId;

  /// The default break interval.
  static const longDrive = Duration(hours: 2);

  /// Continuous driving that is a reason for a break (the trip's break
  /// interval, [longDrive] by default).
  final Duration breakAfter;
  static const lowBodyBatteryLimit = 20;
  bool _eyesSeen = false, _fatigueSeen = false;
  int _sequence = 0;
  Recommendation? _previous;
  String? _previousState;

  RecommendationUpdate evaluate({
    required DateTime localNow,
    required SleepSummary sleep,
    SelfAssessment assessment = SelfAssessment.unknown,
    bool tripStarted = false,
    bool eyesEventOccurred = false,
    bool headEventActive = false,
    bool fatigueHigh = false,
    Duration? drivingTime,
    int? bodyBattery,
  }) {
    _eyesSeen = _eyesSeen || eyesEventOccurred;
    // Fatigue trends are latched like eye evidence, but a break clears them.
    _fatigueSeen = tripStarted && (_fatigueSeen || fatigueHigh);
    final driveDue =
        tripStarted && drivingTime != null && drivingTime >= breakAfter;
    final lowEnergy =
        bodyBattery != null &&
        bodyBattery >= 0 &&
        bodyBattery <= lowBodyBatteryLimit;
    final reasons = <RecommendationReason>[];
    if (_eyesSeen) reasons.add(RecommendationReason.eyesClosed);
    if (assessment == SelfAssessment.sleepy) {
      reasons.add(RecommendationReason.selfReportedSleepiness);
    }
    if (sleep.complete && sleep.duration < const Duration(hours: 7)) {
      reasons.add(RecommendationReason.insufficientSleep);
    }
    if (headEventActive) reasons.add(RecommendationReason.headPitchDown);
    if (localNow.hour < 6) reasons.add(RecommendationReason.nightPeriod);
    if (_fatigueSeen) reasons.add(RecommendationReason.fatigueSigns);
    if (driveDue) reasons.add(RecommendationReason.longDrive);
    if (lowEnergy) reasons.add(RecommendationReason.lowBodyBattery);
    var action = RecommendationAction.noGrounds;
    if (_eyesSeen) {
      action = RecommendationAction.stopAndRest;
    } else if (reasons.contains(RecommendationReason.selfReportedSleepiness) ||
        reasons.contains(RecommendationReason.insufficientSleep)) {
      action = tripStarted
          ? RecommendationAction.stopAndRest
          : RecommendationAction.delayAndRest;
    } else if (headEventActive) {
      action = RecommendationAction.checkCondition;
    } else if (_fatigueSeen || driveDue) {
      action = RecommendationAction.takeBreak;
    } else if (reasons.contains(RecommendationReason.nightPeriod) ||
        lowEnergy) {
      action = RecommendationAction.reconsiderTripTime;
    }
    final state = jsonEncode([
      action.name,
      reasons.map((r) => r.code).toList(),
      sleep.dataStatus.name,
      assessment.name,
      sleep.source,
      sleep.duration.inMicroseconds,
      sleep.readStatus.name,
      lowEnergy,
    ]);
    final changed = state != _previousState;
    final shouldNotify =
        action.priority > 0 &&
        (_previous == null || action.priority > _previous!.priority);
    final recommendation = Recommendation(
      id: changed ? '$tripId:recommendation:${++_sequence}' : _previous!.id,
      tripId: tripId,
      action: action,
      reasons: reasons,
      dataStatus: sleep.dataStatus,
      assessment: assessment,
      sleep: sleep,
      evaluatedAt: localNow,
      drivingTime: drivingTime,
      bodyBattery: bodyBattery,
    );
    _previous = recommendation;
    _previousState = state;
    return RecommendationUpdate(
      recommendation: recommendation,
      changed: changed,
      shouldNotify: shouldNotify,
    );
  }

  /// A confirmed break clears fatigue trends; eye evidence stays per ТЗ.
  void restTaken() => _fatigueSeen = false;

  /// Ends the retention of camera evidence; create a fresh engine for a new trip.
  void endTrip() {
    _eyesSeen = false;
    _fatigueSeen = false;
    _previous = null;
    _previousState = null;
  }
}

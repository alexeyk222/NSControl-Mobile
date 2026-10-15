import 'dart:convert';
import 'sleep.dart';

enum SelfAssessment { unknown, notSleepy, sleepy }

enum RecommendationAction {
  noGrounds(0, 'По доступным данным основания для рекомендации не выявлены'),
  reconsiderTripTime(1, 'Пересмотрите время поездки'),
  checkCondition(2, 'Продолжительный наклон головы — проверьте состояние'),
  delayAndRest(3, 'Отложите начало поездки и отдохните'),
  stopAndRest(4, 'Остановитесь в безопасном месте для отдыха');

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
  );

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
  }) : reasons = List.unmodifiable(reasons);
  static const rulesVersion = '1.0.0';
  final String id, tripId;
  final RecommendationAction action;
  final List<RecommendationReason> reasons;
  final SleepDataStatus dataStatus;
  final SelfAssessment assessment;
  final SleepSummary sleep;
  final DateTime evaluatedAt;
  int get priority => action.priority;
  bool get actionable => priority > 0;
  String get message => action.label;
  String get dataMessage => dataStatus == SleepDataStatus.insufficient
      ? 'Недостаточно данных для оценки сна'
      : 'Полнота сведений о сне подтверждена';
  List<String> get reasonTexts => List.unmodifiable(
    reasons.map(
      (r) => r == RecommendationReason.insufficientSleep
          ? '${r.label}: ${sleep.duration.inHours} ч ${sleep.duration.inMinutes.remainder(60)} мин, источник: ${sleep.source}'
          : r.label,
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
  RecommendationEngine({required this.tripId}) {
    if (tripId.isEmpty) throw ArgumentError('Поездка должна иметь ID');
  }
  final String tripId;
  bool _eyesSeen = false;
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
  }) {
    _eyesSeen = _eyesSeen || eyesEventOccurred;
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
    } else if (reasons.contains(RecommendationReason.nightPeriod)) {
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
    );
    _previous = recommendation;
    _previousState = state;
    return RecommendationUpdate(
      recommendation: recommendation,
      changed: changed,
      shouldNotify: shouldNotify,
    );
  }

  /// Ends the retention of camera evidence; create a fresh engine for a new trip.
  void endTrip() {
    _eyesSeen = false;
    _previous = null;
    _previousState = null;
  }
}

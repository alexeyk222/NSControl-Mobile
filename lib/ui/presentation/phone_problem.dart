import '../copy.dart';

/// A failure of the phone itself, from `TripController.alertError`: the
/// alarm sound or its escalation refused, a platform call failed, the trip
/// recording or the live debug did not start. The controller keeps the
/// last one until the app restarts.
///
/// [PhoneProblem.of] is pure: it turns the controller's text into a plain
/// title for the driver and keeps the original text as [detail] (it names
/// the cause, which is what a bug report needs).
class PhoneProblem {
  const PhoneProblem({
    required this.title,
    required this.detail,
    this.hint,
    this.alarm = false,
  });

  final String title;

  /// The controller's own text, shown small under the title.
  final String detail;

  /// What the driver can do about it.
  final String? hint;

  /// The alarm sound may not start: the most serious kind.
  final bool alarm;

  /// Null when there is nothing to show.
  static PhoneProblem? of(String? alertError) {
    final text = alertError?.trim();
    if (text == null || text.isEmpty) return null;
    if (text.startsWith('Запись поездки')) {
      return PhoneProblem(title: Copy.problemRecording, detail: text);
    }
    if (text.startsWith('Живой дебаг')) {
      return PhoneProblem(title: Copy.problemDebug, detail: text);
    }
    if (text.startsWith('Оповещение телефона') ||
        text.startsWith('Усиление сигнала') ||
        text.toLowerCase().contains('alert')) {
      return PhoneProblem(
        title: Copy.problemAlarm,
        detail: text,
        hint: Copy.problemAlarmHint,
        alarm: true,
      );
    }
    return PhoneProblem(title: Copy.problemOther, detail: text);
  }
}

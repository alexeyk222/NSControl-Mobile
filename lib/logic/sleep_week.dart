import 'dart:math' as math;
import 'sleep.dart';

/// Sleep attributed to one local calendar day: the window from 18:00 of the
/// previous day to 18:00 of this day, so a night belongs to its wake-up day.
class SleepNight {
  const SleepNight({
    required this.day,
    this.duration,
    this.onset,
    this.inBedOnly = false,
  });
  final DateTime day;

  /// Records exist but none is a sleep stage (e.g. only "in bed"); such a
  /// night is shown, yet excluded from averages and debt.
  final bool inBedOnly;

  /// Null when the selected source has no records touching the window.
  final Duration? duration;
  final DateTime? onset;
  bool get hasData => duration != null;
}

/// Informational multi-day view (ФТ-11 «дальнейшее направление»). It never
/// feeds the 24 h recommendation and never treats a missing night as zero.
class SleepWeek {
  SleepWeek._(this.nights);
  static const target = Duration(hours: 7);
  final List<SleepNight> nights;

  List<SleepNight> get recorded => nights.where((n) => n.hasData).toList();

  Duration? get average {
    final r = recorded;
    if (r.isEmpty) return null;
    final total = r.fold<int>(0, (s, n) => s + n.duration!.inMicroseconds);
    return Duration(microseconds: total ~/ r.length);
  }

  /// Shortfall against 7 h, summed over recorded nights only.
  Duration get debt => Duration(
    microseconds: recorded.fold<int>(
      0,
      (s, n) => s + math.max(0, (target - n.duration!).inMicroseconds),
    ),
  );

  /// Standard deviation of sleep onset time-of-day, in minutes (≥ 3 nights).
  int? get onsetSpreadMinutes {
    final onsets = recorded.where((n) => n.onset != null).map((n) {
      // Minutes relative to 18:00 keep 23:30 and 00:30 one hour apart.
      final local = n.onset!.toLocal();
      return ((local.hour - 18) % 24) * 60 + local.minute;
    }).toList();
    if (onsets.length < 3) return null;
    final mean = onsets.reduce((a, b) => a + b) / onsets.length;
    final variance =
        onsets.map((m) => (m - mean) * (m - mean)).reduce((a, b) => a + b) /
        onsets.length;
    return math.sqrt(variance).round();
  }

  static SleepWeek build({
    required Iterable<SleepRecord> records,
    required String? source,
    required DateTime now,
    int days = 7,
  }) {
    final local = now.toLocal();
    final today = DateTime(local.year, local.month, local.day);
    final selected = records.where((r) => r.source == source).toList();
    final nights = <SleepNight>[];
    for (var i = days - 1; i >= 0; i--) {
      final day = DateTime(today.year, today.month, today.day - i);
      final from = DateTime(day.year, day.month, day.day - 1, 18);
      final to = DateTime(day.year, day.month, day.day, 18);
      final touching = selected
          .where((r) => r.end.isAfter(from) && r.start.isBefore(to))
          .toList();
      if (touching.isEmpty) {
        nights.add(SleepNight(day: day));
        continue;
      }
      final asleepRecords = touching.where((r) => r.isSleep);
      if (asleepRecords.isEmpty) {
        nights.add(SleepNight(day: day, inBedOnly: true));
        continue;
      }
      final asleep =
          asleepRecords
              .map(
                (r) => (
                  r.start.isBefore(from) ? from : r.start,
                  r.end.isAfter(to) ? to : r.end,
                ),
              )
              .toList()
            ..sort((a, b) => a.$1.compareTo(b.$1));
      var total = Duration.zero;
      DateTime? curStart, curEnd;
      for (final (s, e) in asleep) {
        if (curEnd == null || s.isAfter(curEnd)) {
          if (curEnd != null) total += curEnd.difference(curStart!);
          curStart = s;
          curEnd = e;
        } else if (e.isAfter(curEnd)) {
          curEnd = e;
        }
      }
      if (curEnd != null) total += curEnd.difference(curStart!);
      nights.add(SleepNight(day: day, duration: total, onset: asleep.first.$1));
    }
    return SleepWeek._(List.unmodifiable(nights));
  }
}

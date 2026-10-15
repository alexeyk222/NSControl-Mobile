import 'dart:convert';

enum SleepStage { asleep, core, deep, rem, awake, inBed }

enum SleepReadStatus { success, unavailable, permissionDenied, failed }

enum SleepDataStatus { complete, insufficient }

class SleepRecord {
  SleepRecord({
    required this.source,
    required this.sourceId,
    required this.start,
    required this.end,
    this.stage = SleepStage.asleep,
  }) {
    if (source.isEmpty || sourceId.isEmpty || !end.isAfter(start)) {
      throw ArgumentError(
        'Запись сна должна иметь источник, ID и положительный интервал',
      );
    }
  }
  final String source, sourceId;
  final DateTime start, end;
  final SleepStage stage;
  bool get isSleep => stage != SleepStage.awake && stage != SleepStage.inBed;
  Map<String, Object?> toJson() => {
    'source': source,
    'sourceId': sourceId,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'stage': stage.name,
  };
  factory SleepRecord.fromJson(Map<String, dynamic> json) => SleepRecord(
    source: json['source'] as String,
    sourceId: json['sourceId'] as String,
    start: DateTime.parse(json['start'] as String),
    end: DateTime.parse(json['end'] as String),
    stage: SleepStage.values.byName(json['stage'] as String),
  );
}

class SleepCoverage {
  SleepCoverage({
    required this.source,
    required this.start,
    required this.end,
    required this.confirmedAt,
    required this.hasUnrecordedSleep,
    required this.inputFingerprint,
  }) {
    if (source.isEmpty ||
        !end.isAfter(start) ||
        end.isAfter(confirmedAt) ||
        inputFingerprint.isEmpty) {
      throw ArgumentError('Некорректное подтверждение полноты сна');
    }
  }
  final String source, inputFingerprint;
  final DateTime start, end, confirmedAt;
  final bool hasUnrecordedSleep;
  Map<String, Object?> toJson() => {
    'source': source,
    'start': start.toIso8601String(),
    'end': end.toIso8601String(),
    'confirmedAt': confirmedAt.toIso8601String(),
    'hasUnrecordedSleep': hasUnrecordedSleep,
    'inputFingerprint': inputFingerprint,
  };
  factory SleepCoverage.fromJson(Map<String, dynamic> json) => SleepCoverage(
    source: json['source'] as String,
    start: DateTime.parse(json['start'] as String),
    end: DateTime.parse(json['end'] as String),
    confirmedAt: DateTime.parse(json['confirmedAt'] as String),
    hasUnrecordedSleep: json['hasUnrecordedSleep'] as bool,
    inputFingerprint: json['inputFingerprint'] as String,
  );
}

class SleepInterval {
  const SleepInterval({required this.start, required this.end});
  final DateTime start, end;
  Duration get duration => end.difference(start);
}

class SleepSummary {
  SleepSummary({
    required this.windowStart,
    required this.windowEnd,
    required this.source,
    required this.readStatus,
    required this.lastSuccessfulRead,
    required Iterable<SleepInterval> intervals,
    required this.complete,
    required this.inputFingerprint,
    required this.recordCount,
  }) : intervals = List.unmodifiable(intervals);
  final DateTime windowStart, windowEnd;
  final String? source;
  final SleepReadStatus readStatus;
  final DateTime? lastSuccessfulRead;
  final List<SleepInterval> intervals;
  final bool complete;
  final String inputFingerprint;
  final int recordCount;
  Duration get duration => Duration(
    microseconds: intervals.fold<int>(
      0,
      (sum, v) => sum + v.duration.inMicroseconds,
    ),
  );
  SleepDataStatus get dataStatus =>
      complete ? SleepDataStatus.complete : SleepDataStatus.insufficient;
  Map<String, Object?> toJson() => {
    'windowStart': windowStart.toIso8601String(),
    'windowEnd': windowEnd.toIso8601String(),
    'source': source,
    'readStatus': readStatus.name,
    'lastSuccessfulRead': lastSuccessfulRead?.toIso8601String(),
    'durationUs': duration.inMicroseconds,
    'complete': complete,
    'recordCount': recordCount,
  };
}

class SleepNormalizer {
  /// Later occurrences of the same source record ID are updates, not extra sleep.
  static SleepSummary summarize({
    required List<SleepRecord> records,
    required DateTime now,
    required String? selectedSource,
    required SleepReadStatus readStatus,
    DateTime? lastSuccessfulRead,
    SleepCoverage? coverage,
  }) {
    final windowEnd = now.toUtc();
    final windowStart = windowEnd.subtract(const Duration(hours: 24));
    final byId = <String, SleepRecord>{};
    for (final record in records) {
      if (record.source == selectedSource) byId[record.sourceId] = record;
    }
    final eligible =
        byId.values
            .where(
              (r) =>
                  !r.end.isAfter(windowEnd) &&
                  r.end.isAfter(windowStart) &&
                  r.start.isBefore(windowEnd),
            )
            .toList()
          ..sort((a, b) => a.sourceId.compareTo(b.sourceId));
    // Canonical data, not synchronization timestamps: rereading old sleep does not make it new.
    final fingerprint = jsonEncode([
      selectedSource,
      for (final r in eligible)
        [
          r.sourceId,
          r.start.toUtc().microsecondsSinceEpoch,
          r.end.toUtc().microsecondsSinceEpoch,
          r.stage.name,
        ],
    ]);
    final asleep = <SleepInterval>[], awake = <SleepInterval>[];
    for (final record in eligible) {
      final interval = SleepInterval(
        start: record.start.isBefore(windowStart)
            ? windowStart
            : record.start.toUtc(),
        end: record.end.isAfter(windowEnd) ? windowEnd : record.end.toUtc(),
      );
      if (record.isSleep) asleep.add(interval);
      if (record.stage == SleepStage.awake) awake.add(interval);
    }
    final sleepUnion = _union(asleep), awakeUnion = _union(awake);
    final intervals = <SleepInterval>[];
    for (final sleep in sleepUnion) {
      var cursor = sleep.start;
      for (final wake in awakeUnion) {
        if (!wake.end.isAfter(cursor) || !wake.start.isBefore(sleep.end)) {
          continue;
        }
        if (wake.start.isAfter(cursor)) {
          intervals.add(SleepInterval(start: cursor, end: wake.start));
        }
        if (wake.end.isAfter(cursor)) cursor = wake.end;
        if (!cursor.isBefore(sleep.end)) break;
      }
      if (cursor.isBefore(sleep.end)) {
        intervals.add(SleepInterval(start: cursor, end: sleep.end));
      }
    }
    final complete =
        selectedSource != null &&
        asleep.isNotEmpty &&
        readStatus == SleepReadStatus.success &&
        lastSuccessfulRead != null &&
        !lastSuccessfulRead.isAfter(now) &&
        coverage != null &&
        coverage.source == selectedSource &&
        !coverage.hasUnrecordedSleep &&
        !coverage.start.isAfter(windowStart) &&
        !coverage.end.isBefore(windowEnd) &&
        !coverage.confirmedAt.isAfter(now) &&
        coverage.inputFingerprint == fingerprint;
    return SleepSummary(
      windowStart: windowStart,
      windowEnd: windowEnd,
      source: selectedSource,
      readStatus: readStatus,
      lastSuccessfulRead: lastSuccessfulRead,
      intervals: intervals,
      complete: complete,
      inputFingerprint: fingerprint,
      recordCount: eligible.length,
    );
  }

  static List<SleepInterval> _union(List<SleepInterval> input) {
    final ordered = [...input]..sort((a, b) => a.start.compareTo(b.start));
    final result = <SleepInterval>[];
    for (final interval in ordered) {
      if (result.isEmpty || interval.start.isAfter(result.last.end)) {
        result.add(interval);
      } else if (interval.end.isAfter(result.last.end)) {
        result[result.length - 1] = SleepInterval(
          start: result.last.start,
          end: interval.end,
        );
      }
    }
    return result;
  }
}

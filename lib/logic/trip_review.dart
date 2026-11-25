import 'dart:convert';

/// Review of a recorded trip (docs/trip-debug.md): the verdict on each
/// alarm and mark, made on the review page after the trip. It turns a
/// natural, uncontrolled drive into labelled data for the replay and the
/// threshold tuning (tool/tune.dart): every reviewed alarm and missed
/// moment becomes a scenario step, and the rest of the drive a step where
/// no alarm is expected.
///
/// The review file is `nscontrol-<recordingId>.review.json`:
/// `{"type":"review","schema":1,"recordingId":…,"items":[…]}`. Times are
/// microseconds of the recording clock (the line's `atUs`; event times plus
/// `sessionOffsetUs`).
class TripReview {
  TripReview({
    required this.recordingId,
    required this.items,
    this.profile,
    this.reviewedAt,
  });

  final String recordingId;
  final List<TripReviewItem> items;
  final String? profile, reviewedAt;

  static const schema = 1;

  factory TripReview.fromJson(Map<String, dynamic> json) {
    if (json['type'] != 'review') {
      throw const FormatException('Это не файл разбора NSControl');
    }
    if (json['schema'] != schema) {
      throw FormatException('Неизвестная схема разбора: ${json['schema']}');
    }
    return TripReview(
      recordingId: json['recordingId'] as String? ?? '',
      profile: json['profile'] as String?,
      reviewedAt: json['reviewedAt'] as String?,
      items: [
        for (final item in (json['items'] as List? ?? const []))
          TripReviewItem.fromJson(Map<String, dynamic>.from(item as Map)),
      ],
    );
  }

  static TripReview parse(String text) =>
      TripReview.fromJson(jsonDecode(text) as Map<String, dynamic>);
}

/// One alarm (`kind` event) or mark (`kind` mark) of the review.
class TripReviewItem {
  const TripReviewItem({
    required this.kind,
    required this.atUs,
    this.eventId,
    this.eventType,
    this.signStartedUs,
    this.endedUs,
    this.mark,
    this.verdict,
    this.cause,
    this.note,
    this.windowFromUs,
    this.windowToUs,
  });

  /// `event` or `mark`.
  final String kind;

  /// Alarm: its threshold moment; mark: when it was set.
  final int atUs;
  final String? eventId, eventType;
  final int? signStartedUs, endedUs;

  /// Mark kind as set on the drive: mark, miss, false, true.
  final String? mark;

  /// Alarm: true, false, unsure. Mark: no_issue, miss_eyes, miss_head,
  /// false_alarm, unsure. Null: not reviewed.
  final String? verdict;
  final String? cause, note;

  /// Mark: where the missed sign was, by the reviewer.
  final int? windowFromUs, windowToUs;

  bool get isEvent => kind == 'event';

  factory TripReviewItem.fromJson(Map<String, dynamic> json) {
    int? i(String key) => (json[key] as num?)?.toInt();
    return TripReviewItem(
      kind: json['kind'] as String,
      atUs: i('atUs')!,
      eventId: json['eventId'] as String?,
      eventType: json['eventType'] as String?,
      signStartedUs: i('signStartedUs'),
      endedUs: i('endedUs'),
      mark: json['mark'] as String?,
      verdict: json['verdict'] as String?,
      cause: json['cause'] as String?,
      note: json['note'] as String?,
      windowFromUs: i('windowFromUs'),
      windowToUs: i('windowToUs'),
    );
  }
}

/// Scenario steps the review adds; their expectations are in the replay's
/// `ScenarioExpectations`.
abstract final class TripReviewSteps {
  static const scenario = 'trip-review';

  /// Driving with nothing reviewed: no alarm expected.
  static const drive = 'trip_drive';

  /// Around an alarm the reviewer called false: no alarm expected.
  static const falseAlarm = 'trip_alarm_false';
  static const eyesTrue = 'trip_eyes_true';
  static const headTrue = 'trip_head_true';
  static const distractionTrue = 'trip_distraction_true';
  static const eyesMissed = 'trip_eyes_missed';
  static const headMissed = 'trip_head_missed';

  /// Not decided or not reviewed: shown, never scored (aborted step).
  static const unsure = 'trip_unsure';
}

/// A scored or ignored window of the reviewed trip.
class ReviewWindow {
  const ReviewWindow(this.step, this.fromUs, this.toUs, {this.why});
  final String step;
  final int fromUs, toUs;

  /// What the window comes from (alarm id, mark), for the report.
  final String? why;
  bool get aborted => step == TripReviewSteps.unsure;
}

/// Windows around reviewed items, plus [TripReviewSteps.drive] in between
/// over the observed span [fromUs, toUs].
///
/// - A true alarm: from the sign start to 1 s after its end. The replay
///   finds the event at sign start + duration, so a profile with another
///   duration still matches (within ±1 s, or later in the step).
/// - A false alarm: 2 s either side of the sign. Any alarm there is false.
/// - A missed sign: the reviewer's window (10 s before the mark to 1 s
///   after by default).
/// - Unsure or not reviewed: 2 s either side, left out of the scoring.
List<ReviewWindow> reviewWindows(
  TripReview review, {
  required int fromUs,
  required int toUs,
}) {
  const around = 2000000, after = 1000000;
  final windows = <ReviewWindow>[];
  for (final item in review.items) {
    if (item.isEvent) {
      final start = item.signStartedUs ?? item.atUs;
      final end = (item.endedUs ?? item.atUs) < item.atUs
          ? item.atUs
          : (item.endedUs ?? item.atUs);
      final why = '${item.eventType} ${item.eventId ?? ''}'.trim();
      switch (item.verdict) {
        case 'true':
          final step = switch (item.eventType) {
            'eyes_closed' => TripReviewSteps.eyesTrue,
            'head_pitch_down' => TripReviewSteps.headTrue,
            'distraction' => TripReviewSteps.distractionTrue,
            _ => TripReviewSteps.unsure,
          };
          windows.add(ReviewWindow(step, start, end + after, why: why));
        case 'false':
          windows.add(
            ReviewWindow(
              TripReviewSteps.falseAlarm,
              start - around,
              end + around,
              why: why,
            ),
          );
        default:
          windows.add(
            ReviewWindow(
              TripReviewSteps.unsure,
              start - around,
              end + around,
              why: why,
            ),
          );
      }
    } else {
      final from = item.windowFromUs ?? item.atUs - 10000000;
      final to = item.windowToUs ?? item.atUs + after;
      final why = 'метка ${item.mark ?? ''}'.trim();
      switch (item.verdict) {
        case 'miss_eyes':
          windows.add(
            ReviewWindow(TripReviewSteps.eyesMissed, from, to, why: why),
          );
        case 'miss_head':
          windows.add(
            ReviewWindow(TripReviewSteps.headMissed, from, to, why: why),
          );
        case 'no_issue':
          break;
        default:
          windows.add(ReviewWindow(TripReviewSteps.unsure, from, to, why: why));
      }
    }
  }
  windows.sort((a, b) => a.fromUs.compareTo(b.fromUs));
  // The rest of the drive: the gaps between reviewed windows.
  final result = <ReviewWindow>[];
  var cursor = fromUs;
  for (final w in windows) {
    if (w.fromUs > cursor) {
      result.add(ReviewWindow(TripReviewSteps.drive, cursor, w.fromUs));
    }
    result.add(w);
    if (w.toUs > cursor) cursor = w.toUs;
  }
  if (toUs > cursor) {
    result.add(ReviewWindow(TripReviewSteps.drive, cursor, toUs));
  }
  return result;
}

/// The trip recording [jsonl] with the review's windows appended as
/// `label` lines (scenario `trip-review`; an unsure window ends with
/// `aborted`), ready for `tool/replay.dart` and `tool/tune.dart`. The
/// observed span starts at the first calibration.
String labelTrip(String jsonl, TripReview review) {
  int? from, to;
  for (final raw in const LineSplitter().convert(jsonl)) {
    if (raw.trim().isEmpty) continue;
    final Map<String, dynamic> line;
    try {
      line = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      continue;
    }
    final t = (line['atUs'] ?? line['capturedUs']) as num?;
    if (t != null && (to == null || t > to)) to = t.toInt();
    if (line['type'] == 'calibration' && from == null) {
      from = (line['atUs'] as num).toInt();
    }
  }
  if (from == null || to == null) {
    throw const FormatException('В записи нет калибровки: размечать нечего');
  }
  final out = StringBuffer(jsonl);
  if (!jsonl.endsWith('\n')) out.writeln();
  var rep = 0;
  for (final w in reviewWindows(review, fromUs: from, toUs: to)) {
    rep++;
    out.writeln(
      jsonEncode({
        'type': 'label',
        'atUs': w.fromUs,
        'scenario': TripReviewSteps.scenario,
        'step': w.step,
        'edge': 'start',
        'rep': rep,
      }),
    );
    out.writeln(
      jsonEncode({
        'type': 'label',
        'atUs': w.toUs,
        'scenario': TripReviewSteps.scenario,
        'step': w.step,
        'edge': 'end',
        'rep': rep,
        if (w.aborted) 'aborted': true,
      }),
    );
  }
  return out.toString();
}

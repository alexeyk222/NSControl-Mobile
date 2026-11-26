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
    this.scoreGaps,
  });

  final String recordingId;
  final List<TripReviewItem> items;
  final String? profile, reviewedAt;

  /// The reviewer's choice for the time outside the cases and the reviewed
  /// alarms: true, it was driving and any alarm there is false; false, it
  /// is not scored (a staged session: the tester looks at the keyboard
  /// between the cases). Null: not chosen.
  final bool? scoreGaps;

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
      scoreGaps: json['scoreGaps'] as bool?,
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
    this.caseId,
    this.truth,
  });

  /// `event`, `mark` or `case`.
  final String kind;

  /// Alarm: its threshold moment; mark: when it was set; case: its start.
  final int atUs;
  final String? eventId, eventType;

  /// Case (a staged case of the live page, corrected on the review page):
  /// its id, and what really happened (a key of [caseTruths]; empty: no
  /// answer). [atUs] and [endedUs] are its start and end.
  final String? caseId, truth;
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
  bool get isCase => kind == 'case';

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
      caseId: json['caseId'] as String?,
      truth: json['truth'] as String?,
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

  /// Staged cases (the live page's «Новый случай»): the tester took a
  /// pose and said what it was.
  static const caseEyes = 'trip_case_eyes';
  static const caseHead = 'trip_case_head';
  static const caseQuiet = 'trip_case_quiet';
}

/// A case staged on the live page: `mark` lines of kind `case` with one
/// [id], edges `start` and `end`, and the tester's [truth] (docs/trip-debug.md,
/// «Разметка»).
class TripCase {
  TripCase(this.id, this.startUs);
  final String id;
  int startUs;
  int? endUs;
  String? truth;

  /// The start of the next case, set by [tripCases].
  int? nextStartUs;

  /// An alarm up to this long after the end still belongs to the case.
  static const tailUs = 1000000;

  /// An alarm-wanted case shorter than this is not scored. The tester's
  /// finger is 0.3–0.5 s late at both ends, so a 2 s case may hold a 1.3 s
  /// closure (bench-v1: «2 с» gave 1.3–2.1 s), which is on the wrong side
  /// of a 1.6 s threshold.
  static const positiveMinUs = 3000000;

  /// What the truth wants: `none`, `eyes`, `head`, `any`; null when the
  /// truth is not given or unknown ([truthExpect]).
  String? get expect => truthExpect(truth);

  /// Where alarms count for the case: up to [tailUs] after its end, and
  /// never into the next case.
  int get toUs {
    final end = endUs ?? startUs;
    final next = nextStartUs;
    return next != null && next >= end && next < end + tailUs
        ? next
        : end + tailUs;
  }

  /// An alarm is wanted, but the pose was not held for [positiveMinUs].
  bool get tooShort {
    final end = endUs, want = expect;
    return end != null &&
        want != null &&
        want != 'none' &&
        end - startUs < positiveMinUs;
  }
}

/// The live page's answers (TRUTHS in lab_page_html.dart) and the alarm
/// each one wants. A truth is one answer or several that happened together,
/// joined by `+` (`eyes_closed+mirror_right`): see [truthExpect].
const caseTruths = {
  'road': 'none',
  'mirror_left': 'none',
  'mirror_right': 'none',
  'mirror_center': 'none',
  'blind_left': 'none',
  'blind_right': 'none',
  'instruments': 'none',
  'phone_short': 'none',
  'talk': 'none',
  'yawn': 'none',
  'squint': 'none',
  'hand_face': 'none',
  'blink': 'none',
  'other_quiet': 'none',
  'eyes_closed': 'eyes',
  'nod': 'head',
  'look_down': 'head',
  'other_alarm': 'any',
};

/// The answers of a truth (`eyes_closed+mirror_right`: two); empty when
/// the truth is not given or one of its answers is unknown.
List<String> truthParts(String? truth) {
  if (truth == null || truth.isEmpty) return const [];
  final parts = truth.split('+').toSet().toList();
  return parts.every(caseTruths.containsKey) ? parts : const [];
}

/// What a truth wants: `none`, `eyes`, `head`, `any`, or null (no or an
/// unknown truth). Of several answers the alarm-wanted one decides: closed
/// eyes while looking into a mirror want `eyes`. A lowered head wins over
/// closed eyes: the head channel sees the pose for sure, the eyes may be
/// hidden by it (replay allows the other alarm in both steps).
String? truthExpect(String? truth) {
  final wants = {for (final part in truthParts(truth)) caseTruths[part]};
  for (final want in const ['head', 'eyes', 'any', 'none']) {
    if (wants.contains(want)) return want;
  }
  return null;
}

/// One spelling of a truth: the alarm-wanted answers first, then the order
/// of [caseTruths]. Unknown truths are returned as they are.
String truthKey(String truth) {
  final parts = truthParts(truth);
  if (parts.isEmpty) return truth;
  final order = caseTruths.keys.toList();
  int rank(String k) =>
      (caseTruths[k] == 'none' ? order.length : 0) + order.indexOf(k);
  return (parts..sort((a, b) => rank(a).compareTo(rank(b)))).join('+');
}

/// Cases of a recording, in the order they started. [review]: its `case`
/// items correct the truth and the bounds given on the live page.
List<TripCase> tripCases(
  Iterable<Map<String, dynamic>> lines, {
  TripReview? review,
}) {
  final cases = <String, TripCase>{};
  final cancelled = <String>{};
  for (final line in lines) {
    if (line['type'] != 'mark' || line['kind'] != 'case') continue;
    final id = line['caseId'], at = line['atUs'];
    if (id is! String || at is! num) continue;
    final c = cases.putIfAbsent(id, () => TripCase(id, at.toInt()));
    switch (line['edge']) {
      case 'start':
        c.startUs = at.toInt();
      case 'end':
        c.endUs = at.toInt();
      case 'cancel':
        cancelled.add(id);
    }
    final truth = line['truth'];
    if (truth is String && truth.isNotEmpty) c.truth = truthKey(truth);
  }
  for (final item in review?.items ?? const <TripReviewItem>[]) {
    final c = item.isCase ? cases[item.caseId] : null;
    if (c == null) continue;
    c.startUs = item.atUs;
    if (item.endedUs case final end? when end >= item.atUs) c.endUs = end;
    if (item.truth case final truth?) {
      c.truth = truth.isEmpty ? null : truthKey(truth);
    }
  }
  final result = cases.values.where((c) => !cancelled.contains(c.id)).toList()
    ..sort((a, b) => a.startUs.compareTo(b.startUs));
  for (var i = 0; i + 1 < result.length; i++) {
    result[i].nextStartUs = result[i + 1].startUs;
  }
  return result;
}

/// How a case went against the alarms that started in its window
/// ([alarms]: threshold moment on the recording clock and ТЗ type):
/// `ok`, `false_alarm`, `missed`, `other_type`, `too_short` (an alarm was
/// wanted, the pose was held less than [TripCase.positiveMinUs]: not
/// scored), or `unsure` (no truth or no end).
String caseOutcome(TripCase c, Iterable<(int, String)> alarms) {
  final expect = c.expect;
  if (expect == null || c.endUs == null) return 'unsure';
  final got = {
    for (final (at, type) in alarms)
      if (at >= c.startUs && at <= c.toUs) type,
  };
  if (expect == 'none') return got.isEmpty ? 'ok' : 'false_alarm';
  if (c.tooShort) return 'too_short';
  final want = switch (expect) {
    'eyes' => 'eyes_closed',
    'head' => 'head_pitch_down',
    _ => null,
  };
  if (want == null ? got.isNotEmpty : got.contains(want)) return 'ok';
  return got.isEmpty ? 'missed' : 'other_type';
}

/// Label windows of the cases: from the start to 1 s after the end (the
/// next case cuts it). A case without an end or an answer, with the answer
/// «другое, тревога нужна» or too short for its alarm is left unscored.
List<ReviewWindow> caseWindows(List<TripCase> cases) => [
  for (final c in cases)
    ReviewWindow(
      c.endUs == null || c.tooShort
          ? TripReviewSteps.unsure
          : switch (c.expect) {
              'none' => TripReviewSteps.caseQuiet,
              'eyes' => TripReviewSteps.caseEyes,
              'head' => TripReviewSteps.caseHead,
              _ => TripReviewSteps.unsure,
            },
      c.startUs,
      c.endUs == null ? c.startUs + 2000000 : c.toUs,
      why: 'случай ${c.truth ?? ''}'.trim(),
    ),
];

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
  List<ReviewWindow> extra = const [],
  String gapStep = TripReviewSteps.drive,
}) {
  const around = 2000000, after = 1000000;
  final windows = <ReviewWindow>[];
  for (final item in review.items) {
    // A case's item only corrects the case (tripCases); its window is in
    // [extra]. An alarm inside a case is explained by the case: a window of
    // its own would take the alarm away from the case in the replay.
    if (item.isCase) continue;
    if (item.isEvent &&
        extra.any((w) => item.atUs >= w.fromUs && item.atUs <= w.toUs)) {
      continue;
    }
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
  // The margins around a reviewed alarm or mark never reach into a case:
  // the case's own window scores that time.
  for (var i = windows.length - 1; i >= 0; i--) {
    var w = windows[i];
    for (final e in extra) {
      if (e.fromUs <= w.fromUs && e.toUs > w.fromUs) {
        w = ReviewWindow(w.step, e.toUs, w.toUs, why: w.why);
      }
      if (e.toUs >= w.toUs && e.fromUs < w.toUs) {
        w = ReviewWindow(w.step, w.fromUs, e.fromUs, why: w.why);
      }
    }
    if (w.toUs > w.fromUs) {
      windows[i] = w;
    } else {
      windows.removeAt(i);
    }
  }
  windows
    ..addAll(extra)
    ..sort((a, b) => a.fromUs.compareTo(b.fromUs));
  // The rest of the drive: the gaps between reviewed windows.
  final result = <ReviewWindow>[];
  var cursor = fromUs;
  for (final w in windows) {
    if (w.fromUs > cursor) {
      result.add(ReviewWindow(gapStep, cursor, w.fromUs));
    }
    result.add(w);
    if (w.toUs > cursor) cursor = w.toUs;
  }
  if (toUs > cursor) {
    result.add(ReviewWindow(gapStep, cursor, toUs));
  }
  return result;
}

/// The trip recording [jsonl] with the review's windows and the staged
/// cases appended as `label` lines (scenario `trip-review`; an unsure
/// window ends with `aborted`), ready for `tool/replay.dart` and
/// `tool/tune.dart`. The observed span starts at the first calibration.
///
/// [scoreGaps] false leaves the time outside the reviewed windows and cases
/// unscored (`trip_unsure`): in a staged session the tester looks at the
/// keyboard between cases, which is not driving. Null: the reviewer's
/// choice in the review file, else true.
String labelTrip(String jsonl, TripReview review, {bool? scoreGaps}) {
  scoreGaps ??= review.scoreGaps ?? true;
  int? from, to;
  final caseLines = <Map<String, dynamic>>[];
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
    if (line['type'] == 'mark' && line['kind'] == 'case') caseLines.add(line);
  }
  if (from == null || to == null) {
    throw const FormatException('В записи нет калибровки: размечать нечего');
  }
  final out = StringBuffer(jsonl);
  if (!jsonl.endsWith('\n')) out.writeln();
  var rep = 0;
  final windows = reviewWindows(
    review,
    fromUs: from,
    toUs: to,
    extra: caseWindows(tripCases(caseLines, review: review)),
    gapStep: scoreGaps ? TripReviewSteps.drive : TripReviewSteps.unsure,
  );
  for (final w in windows) {
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

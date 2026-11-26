import 'dart:convert';

import '../../data/trip_repository.dart';
import '../../logic/observation.dart';

/// One finished (or running) trip as the summary and the history show it:
/// how long, how many alarms of each kind, how long the driver was not
/// seen, and the ribbon «Как прошла поездка» (README §9: watching in the
/// accent, not seen hatched yellow, pause grey, an alarm as a white bar).
///
/// Built by [TripStory.build] from the journal rows only (pure, tested in
/// `test/ui/trip_story_test.dart`); [TripStory.load] reads the rows.
class TripStory {
  const TripStory({
    required this.id,
    required this.start,
    required this.end,
    required this.segments,
    required this.alarms,
    required this.eyesAlarms,
    required this.headAlarms,
    required this.unseen,
    required this.breaks,
    required this.partial,
    required this.active,
  });

  final String id;
  final DateTime start, end;

  /// Ribbon pieces in order, each a share of [total].
  final List<StorySegment> segments;

  /// Alarm moments as shares of [total] (0…1).
  final List<double> alarms;
  final int eyesAlarms, headAlarms, breaks;

  /// Time the driver was not seen at all (both channels unavailable for
  /// longer than [unseenMin]).
  final Duration unseen;

  /// The journal of this trip is incomplete or the trip was interrupted.
  final bool partial;

  /// The trip is still going.
  final bool active;

  Duration get total => end.difference(start);
  int get alarmCount => eyesAlarms + headAlarms;

  /// Short gaps (a turn of the head, a hand) are not «не видел».
  static const unseenMin = Duration(seconds: 10);

  static Future<TripStory?> load(TripRepository db, String tripId) async {
    final trip = (await db.listTrips()).where((t) => t['id'] == tripId);
    if (trip.isEmpty) return null;
    return build(
      trip: trip.first,
      sessions: await db.listSessions(tripId: tripId),
      transitions: await db.listTransitions(tripId: tripId),
      events: await db.listEvents(tripId: tripId),
    );
  }

  /// Every trip, newest first.
  static Future<List<TripStory>> loadAll(TripRepository db) async {
    final out = <TripStory>[];
    for (final t in (await db.listTrips()).reversed) {
      final story = await load(db, t['id'] as String);
      if (story != null) out.add(story);
    }
    return out;
  }

  static TripStory build({
    required Row trip,
    required List<Row> sessions,
    required List<Row> transitions,
    required List<Row> events,
    DateTime? now,
  }) {
    final start = DateTime.parse(trip['started_at'] as String);
    final endText = trip['ended_at'] as String?;
    final active = trip['status'] == 'active';
    var partial =
        trip['journal_incomplete'] == 1 || trip['status'] == 'interrupted';

    // Sessions as wall-clock spans; the gaps between them are pauses.
    final spans = <(String, DateTime, DateTime)>[];
    var lastEnd = start;
    var breaks = 0;
    for (final s in sessions) {
      final from = DateTime.parse(s['started_at'] as String);
      final us = (s['ended_us'] as int?) ?? (s['last_us'] as int? ?? 0);
      final to = from.add(Duration(microseconds: us));
      spans.add((s['id'] as String, from, to));
      if (to.isAfter(lastEnd)) lastEnd = to;
      partial |= s['journal_incomplete'] == 1 || s['status'] == 'interrupted';
      final diag = s['diagnostics_json'];
      try {
        final d = diag is String ? jsonDecode(diag) : null;
        if (d is Map && d['trip_breaks'] is int && d['trip_breaks'] > breaks) {
          breaks = d['trip_breaks'] as int;
        }
      } catch (_) {}
    }
    var end = endText != null
        ? DateTime.parse(endText)
        : (active ? (now ?? DateTime.now()) : lastEnd);
    if (end.isBefore(lastEnd)) end = lastEnd;
    final total = end.difference(start).inMicroseconds;
    double at(DateTime t) => total <= 0
        ? 0
        : (t.difference(start).inMicroseconds / total).clamp(0, 1);

    final segments = <StorySegment>[];
    void add(StoryKind kind, DateTime from, DateTime to) {
      final a = at(from), b = at(to);
      if (b <= a) return;
      if (segments.isNotEmpty &&
          segments.last.kind == kind &&
          (segments.last.to - a).abs() < 1e-9) {
        segments[segments.length - 1] = StorySegment(
          kind,
          segments.last.from,
          b,
        );
      } else {
        segments.add(StorySegment(kind, a, b));
      }
    }

    var unseenUs = 0;
    var cursor = start;
    for (final (id, from, to) in spans) {
      if (from.isAfter(cursor)) add(StoryKind.pause, cursor, from);
      // Not-seen stretches of this session: both channels unavailable.
      final rows = transitions.where((t) => t['session_id'] == id).toList()
        ..sort((a, b) => (a['at_us'] as int).compareTo(b['at_us'] as int));
      var eyes = true, head = true;
      int? lostAt;
      var segStart = from;
      final lengthUs = to.difference(from).inMicroseconds;
      void closeLost(int atUs) {
        final lost = lostAt;
        lostAt = null;
        if (lost == null) return;
        if (atUs - lost < unseenMin.inMicroseconds) return;
        final a = from.add(Duration(microseconds: lost));
        final b = from.add(Duration(microseconds: atUs));
        add(StoryKind.watching, segStart, a);
        add(StoryKind.unseen, a, b);
        unseenUs += atUs - lost;
        segStart = b;
      }

      for (final t in rows) {
        final atUs = (t['at_us'] as int).clamp(0, lengthUs);
        final available = t['available'] == 1;
        final ch = t['channel'];
        if (ch == 'eyes' || ch == 'both') eyes = available;
        if (ch == 'head' || ch == 'both') head = available;
        final lostNow = !eyes && !head;
        if (lostNow && lostAt == null) lostAt = atUs;
        if (!lostNow && lostAt != null) closeLost(atUs);
      }
      closeLost(lengthUs);
      add(StoryKind.watching, segStart, to);
      if (to.isAfter(cursor)) cursor = to;
    }
    if (end.isAfter(cursor) && !active) add(StoryKind.pause, cursor, end);

    final alarms = <double>[];
    var eyesN = 0, headN = 0;
    final sessionStart = {for (final (id, from, _) in spans) id: from};
    for (final e in events) {
      final us = (e['alert_requested_us'] ?? e['threshold_us']) as int?;
      if (us == null) continue; // a sign that never became an alarm
      if (e['type'] == EventType.eyesClosed.code) eyesN++;
      if (e['type'] == EventType.headPitchDown.code) headN++;
      final base = sessionStart[e['session_id']];
      if (base != null) alarms.add(at(base.add(Duration(microseconds: us))));
    }

    return TripStory(
      id: trip['id'] as String,
      start: start,
      end: end,
      segments: segments,
      alarms: alarms,
      eyesAlarms: eyesN,
      headAlarms: headN,
      unseen: Duration(microseconds: unseenUs),
      breaks: breaks,
      partial: partial,
      active: active,
    );
  }
}

enum StoryKind { watching, unseen, pause }

class StorySegment {
  const StorySegment(this.kind, this.from, this.to);
  final StoryKind kind;

  /// Start and end as shares of the trip (0…1).
  final double from, to;

  @override
  String toString() =>
      '${kind.name} ${from.toStringAsFixed(3)}–${to.toStringAsFixed(3)}';
}

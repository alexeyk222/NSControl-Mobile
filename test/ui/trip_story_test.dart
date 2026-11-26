import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/ui/presentation/trip_story.dart';

void main() {
  final start = DateTime.utc(2026, 11, 26, 21, 40);
  String at(Duration d) => start.add(d).toIso8601String();
  const minute = 60 * 1000000;

  test('sessions, a pause between them, a long loss and two alarms', () {
    final story = TripStory.build(
      trip: {
        'id': 't',
        'started_at': at(Duration.zero),
        'ended_at': at(const Duration(minutes: 100)),
        'status': 'completed',
        'journal_incomplete': 0,
      },
      sessions: [
        {
          'id': 's1',
          'started_at': at(Duration.zero),
          'ended_us': 50 * minute,
          'last_us': 50 * minute,
          'status': 'completed',
          'diagnostics_json': '{"trip_breaks":1}',
        },
        {
          'id': 's2',
          'started_at': at(const Duration(minutes: 60)),
          'ended_us': 40 * minute,
          'last_us': 40 * minute,
          'status': 'completed',
          'diagnostics_json': '{}',
        },
      ],
      transitions: [
        // 7 minutes not seen in the first session.
        {
          'session_id': 's1',
          'at_us': 10 * minute,
          'channel': 'both',
          'available': 0,
        },
        {
          'session_id': 's1',
          'at_us': 17 * minute,
          'channel': 'both',
          'available': 1,
        },
        // 3 s gap: not «не видел».
        {
          'session_id': 's1',
          'at_us': 30 * minute,
          'channel': 'both',
          'available': 0,
        },
        {
          'session_id': 's1',
          'at_us': 30 * minute + 3000000,
          'channel': 'both',
          'available': 1,
        },
      ],
      events: [
        {
          'session_id': 's1',
          'type': 'eyes_closed',
          'alert_requested_us': 20 * minute,
        },
        {
          'session_id': 's2',
          'type': 'eyes_closed',
          'alert_requested_us': 10 * minute,
        },
        // A sign that never became an alarm.
        {
          'session_id': 's2',
          'type': 'head_pitch_down',
          'alert_requested_us': null,
        },
      ],
    );
    expect(story.total, const Duration(minutes: 100));
    expect(story.eyesAlarms, 2);
    expect(story.headAlarms, 0);
    expect(story.unseen, const Duration(minutes: 7));
    expect(story.breaks, 1);
    expect(story.partial, isFalse);
    expect(story.segments.map((s) => s.kind).toList(), [
      StoryKind.watching,
      StoryKind.unseen,
      StoryKind.watching,
      StoryKind.pause,
      StoryKind.watching,
    ]);
    expect(story.segments[1].from, closeTo(.10, 1e-9));
    expect(story.segments[1].to, closeTo(.17, 1e-9));
    expect(story.segments[3].from, closeTo(.50, 1e-9));
    expect(story.alarms, [closeTo(.20, 1e-9), closeTo(.70, 1e-9)]);
  });

  test('an interrupted trip is partial', () {
    final story = TripStory.build(
      trip: {
        'id': 't',
        'started_at': at(Duration.zero),
        'ended_at': null,
        'status': 'interrupted',
        'journal_incomplete': 0,
      },
      sessions: const [],
      transitions: const [],
      events: const [],
    );
    expect(story.partial, isTrue);
    expect(story.alarmCount, 0);
  });
}

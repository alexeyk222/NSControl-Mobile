import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/data/trip_repository.dart';
import 'package:nscontrol/logic/detection_profile.dart';
import 'package:nscontrol/logic/domain.dart';
import 'package:nscontrol/logic/replay.dart';
import 'package:nscontrol/logic/trip_review.dart';
import 'package:nscontrol/services/arkit_engine.dart';
import 'package:nscontrol/services/debug_video.dart';
import 'package:nscontrol/services/lab_page_html.dart';
import 'package:nscontrol/services/lab_recorder.dart';
import 'package:nscontrol/services/review_page_html.dart';
import 'package:nscontrol/services/trip_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'trip_arkit_test.dart' show FakeArkit, arkitFace;
import 'trip_controller_test.dart' as fixtures;

/// ARKit stand-in that also sends the debug video.
class VideoArkit extends FakeArkit implements DebugVideoSource {
  VideoArkit(super.options, super.onStats, super.onRaw);
  final List<DebugVideoOptions> video = [];
  void Function(DebugJpeg)? onJpeg;

  @override
  Future<void> setDebugVideo(
    DebugVideoOptions options,
    void Function(DebugJpeg jpeg)? onJpeg,
  ) async {
    video.add(options);
    this.onJpeg = onJpeg;
  }

  void jpeg(int capturedUs) => onJpeg?.call(
    DebugJpeg(
      capturedUs: capturedUs,
      bytes: Uint8List.fromList([0xff, 0xd8, capturedUs & 0xff, 0xff, 0xd9]),
      width: 480,
      height: 360,
    ),
  );
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('DebugJpeg and ClipRecorder', () {
    test('binary message round trip', () {
      final jpeg = DebugJpeg(
        capturedUs: 5,
        bytes: Uint8List.fromList([1, 2, 3]),
        width: 480,
        height: 360,
        quarterTurns: 3,
      );
      final (head, bytes) = DebugJpeg.parseMessage(jpeg.message(1234))!;
      expect(head['atUs'], 1234);
      expect(head['quarterTurns'], 3);
      expect(head['mirrored'], isTrue);
      expect(bytes, [1, 2, 3]);
      expect(DebugJpeg.parseMessage(Uint8List.fromList([1, 2])), isNull);
    });

    test('clips: 10 s before, 5 s after, overlapping clips merged', () async {
      final dir = await Directory.systemTemp.createTemp('clips');
      addTearDown(() => dir.delete(recursive: true));
      final clips = ClipRecorder(directory: dir, recordingId: 'trip-1');
      DebugJpeg j(int t) => DebugJpeg(
        capturedUs: t,
        bytes: Uint8List.fromList([t ~/ 1000000]),
        width: 4,
        height: 3,
      );
      for (var t = 0; t <= 60000000; t += 500000) {
        if (t == 20000000) clips.trigger(atUs: t, reason: 'eyes_closed');
        if (t == 23000000) clips.trigger(atUs: t, reason: 'mark');
        if (t == 50000000) clips.trigger(atUs: t, reason: 'miss');
        clips.add(t, j(t));
      }
      await clips.flush();
      expect(clips.written, hasLength(2));
      final first = await clips.written.first.readAsLines();
      final head = jsonDecode(first.first) as Map<String, dynamic>;
      expect(head['reasons'], ['eyes_closed', 'mark']);
      expect(head['fromUs'], 10000000);
      expect(head['toUs'], 28000000);
      final times = [
        for (final l in first.skip(1)) (jsonDecode(l) as Map)['atUs'] as int,
      ];
      expect(times.first, 10000000);
      expect(times.last, 28000000);
      expect(
        clips.written.first.uri.pathSegments.last,
        'nscontrol-trip-1.clip-20000-eyes_closed.ndjson',
      );
    });
  });

  group('trip live debug', () {
    late TripRepository repository;
    late TripController trip;
    late fixtures.ControllerTestPlatform platform;
    late Directory dir;
    final sources = <VideoArkit>[];

    setUp(() async {
      sources.clear();
      dir = await Directory.systemTemp.createTemp('tripdebug');
      repository = await TripRepository.open(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      platform = fixtures.ControllerTestPlatform();
      trip = TripController(
        repository: repository,
        platform: platform,
        detector: fixtures.ControllerTestDetector(),
        cameraFactory: (d, n, f, e, c) => fixtures.ControllerTestCamera(
          detector: d,
          nowUs: n,
          onFaces: f,
          onError: e,
          onChanged: c,
        ),
        arkitFactory: (options, onStats, onRaw) {
          final s = VideoArkit(options, onStats, onRaw);
          sources.add(s);
          return s;
        },
        arkitSupported: () async => true,
      );
      trip
        ..recorder = LabRecorder(dir)
        ..recordTrips = true
        ..debugClips = true;
    });
    tearDown(() async {
      trip.dispose();
      await trip.pendingWrites;
      await repository.close();
      await dir.delete(recursive: true);
    });

    VideoArkit arkit() => sources.last;

    var lastUs = 0;
    void calibrate() {
      trip.clock.stop();
      final base = trip.clock.elapsedMicroseconds;
      arkit().emit([arkitFace()], base);
      trip.confirmFace(arkitFace().trackingId!);
      final start = trip.calibrationStartUs;
      for (var t = start; t <= start + 10200000; t += 33000) {
        arkit().emit([arkitFace()], t);
      }
      trip.finishCalibration(start + 10300000);
      lastUs = start + 10300000;
    }

    /// Frames (and a JPEG every 200 ms) for [seconds].
    void drive(double seconds, FaceSignals Function() make) {
      final end = lastUs + (seconds * 1e6).round();
      for (var t = lastUs + 33000; t <= end; t += 33000) {
        arkit().emit([make()], t);
        if ((t ~/ 33000) % 6 == 0) arkit().jpeg(t);
        lastUs = t;
      }
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test(
      'stream, video on demand, marks from the Mac and the phone, clips',
      () async {
        await trip.setLiveDebug(true);
        final port = trip.debugServer!.boundPort!;
        final key = trip.debugServer!.key;
        expect(trip.debugUrls.every((u) => u.contains(':$port/')), isTrue);
        await trip.start();
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:$port/ws?k=$key',
        );
        final text = <Map<String, dynamic>>[];
        final binary = <Uint8List>[];
        socket.listen((m) {
          if (m is String) text.add(jsonDecode(m) as Map<String, dynamic>);
          if (m is List<int>) binary.add(Uint8List.fromList(m));
        });
        await settle();
        final meta = text.firstWhere((l) => l['type'] == 'meta');
        expect(meta['source'], 'trip');
        expect(meta['clips'], isTrue);
        expect(meta['thresholds']['pitchThreshold'], 19);
        expect(meta['thresholds']['eyeThreshold'], .25);
        // Clips need the video from the start; the page asks for more.
        expect(arkit().video.last.fps, 5);
        socket.add(jsonEncode({'type': 'video', 'on': true}));
        await settle();
        expect(trip.debugServer!.videoWanted, isTrue);

        calibrate();
        drive(2, arkitFace);
        await settle();
        final head = DebugJpeg.parseMessage(binary.last)!.$1;
        expect(head['type'], 'jpeg');
        expect(head['atUs'], greaterThan(10000000));
        final derived = text.lastWhere((l) => l['type'] == 'derived');
        expect(derived['measure']['eyeThreshold'], .25);
        expect(derived['measure']['pitchDown'], closeTo(0, .5));

        // Eyes closed long enough for an alarm, then open again.
        drive(2.5, () => arkitFace(open: .05));
        expect(trip.snapshot!.eyes.activeEvent, isNotNull);
        final eventId = trip.snapshot!.eyes.activeEvent!.id;
        trip.acknowledge({eventId});
        drive(1, arkitFace);
        socket.add(
          jsonEncode({
            'type': 'mark',
            'kind': 'false',
            'eventId': eventId,
            'cause': 'squint',
          }),
        );
        await settle();
        // Far enough from the alarm's clip (5 s after) not to merge.
        drive(8, arkitFace);
        trip.mark();
        expect(platform.spoken.last, 'Отметил');
        drive(6, arkitFace);
        await settle();
        expect(text.where((l) => l['type'] == 'mark').map((l) => l['source']), [
          'mac',
          'phone',
        ]);
        await socket.close();
        await trip.finish();
        expect(arkit().video.last.on, isFalse);

        final file = (await LabRecorder(dir).list()).single;
        final lines = [
          for (final l in await file.readAsLines())
            jsonDecode(l) as Map<String, dynamic>,
        ];
        final marks = lines.where((l) => l['type'] == 'mark').toList();
        expect(marks.first['kind'], 'false');
        expect(marks.first['eventId'], eventId);
        expect(marks.first['cause'], 'squint');
        expect(marks.last['source'], 'phone');
        expect(lines.any((l) => l['type'] == 'jpeg'), isFalse);
        expect(lines.last['type'], 'trip');
        // One clip around the alarm, one around the phone's mark.
        final clips = await Directory('${dir.path}/clips').list().toList();
        expect(clips, hasLength(2));
        final clipHead =
            jsonDecode(
                  (await File(
                    clips
                        .firstWhere((c) => c.path.contains('eyes_closed'))
                        .path,
                  ).readAsLines()).first,
                )
                as Map<String, dynamic>;
        expect(clipHead['eventIds'], [eventId]);
        expect(clipHead['frames'], greaterThan(20));

        // The server lists and serves the clips for the review page.
        final client = HttpClient();
        final id = lines.first['recordingId'];
        final request = await client.get(
          '127.0.0.1',
          port,
          '/clips?rec=$id&k=$key',
        );
        final list = jsonDecode(
          await (await request.close()).transform(utf8.decoder).join(),
        );
        expect(list, hasLength(2));
        client.close();
      },
    );

    test(
      'a reviewed trip replays: true alarm found, false alarm counted',
      () async {
        await trip.start();
        calibrate();
        drive(3, arkitFace);
        drive(2.5, () => arkitFace(open: .05));
        final event = trip.snapshot!.eyes.activeEvent!;
        trip.acknowledge({event.id});
        drive(10, arkitFace);
        await trip.finish();
        final text = await (await LabRecorder(
          dir,
        ).list()).single.readAsString();
        final started = text
            .split('\n')
            .where((l) => l.contains('"change":"started"'))
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .single;
        final off = started['sessionOffsetUs'] as int;
        final ev = started['event'] as Map<String, dynamic>;
        TripReview review(String verdict) => TripReview(
          recordingId: 'x',
          items: [
            TripReviewItem(
              kind: 'event',
              eventId: event.id,
              eventType: 'eyes_closed',
              atUs: (ev['thresholdUs'] as int) + off,
              signStartedUs: (ev['signStartedUs'] as int) + off,
              verdict: verdict,
            ),
          ],
        );
        ReplayResult run(String verdict) {
          final recording = Recording.parse(labelTrip(text, review(verdict)));
          expect(
            recording.labels.map((l) => l.step).toSet(),
            containsAll([
              TripReviewSteps.drive,
              verdict == 'true'
                  ? TripReviewSteps.eyesTrue
                  : TripReviewSteps.falseAlarm,
            ]),
          );
          return ReplayRunner(recording).run(
            ReplayOptions(
              engine: recording.engines.single,
              profile: DetectionProfile.v1,
            ),
          );
        }

        final right = run('true');
        final eyesTrue = right.episodes.singleWhere(
          (e) => e.episode.step == TripReviewSteps.eyesTrue,
        );
        expect(
          [...eyesTrue.matched, ...eyesTrue.late].map((e) => e.type),
          contains('eyes_closed'),
        );
        expect(right.episodes.expand((e) => e.unexpected), isEmpty);

        final wrong = run('false');
        expect(
          wrong.episodes
              .singleWhere((e) => e.episode.step == TripReviewSteps.falseAlarm)
              .unexpected
              .map((e) => e.type),
          ['eyes_closed'],
        );
      },
    );

    test(
      'staged cases from the page: recorded, compared, labelled for replay',
      () async {
        await trip.setLiveDebug(true);
        final port = trip.debugServer!.boundPort!;
        await trip.start();
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:$port/ws?k=${trip.debugServer!.key}',
        );
        final text = <Map<String, dynamic>>[];
        socket.listen((m) {
          if (m is String) text.add(jsonDecode(m) as Map<String, dynamic>);
        });
        await settle();
        void send(Map<String, Object?> m) =>
            socket.add(jsonEncode({'type': 'mark', 'kind': 'case', ...m}));

        calibrate();
        drive(2, arkitFace);
        // Case 1: eyes closed, the alarm is wanted and comes.
        send({'caseId': 'c1', 'edge': 'start'});
        await settle();
        drive(2.5, () => arkitFace(open: .05));
        trip.acknowledge({trip.snapshot!.eyes.activeEvent!.id});
        drive(1, arkitFace);
        send({'caseId': 'c1', 'edge': 'end', 'truth': 'eyes_closed'});
        await settle();
        drive(8, arkitFace);
        // Case 2: a mirror glance, no alarm wanted; the truth comes later.
        send({'caseId': 'c2', 'edge': 'start'});
        await settle();
        drive(3, arkitFace);
        send({'caseId': 'c2', 'edge': 'end'});
        await settle();
        send({'caseId': 'c2', 'edge': 'truth', 'truth': 'mirror_left'});
        // Not a case: no id.
        send({'edge': 'start'});
        // Cancelled, and one left open: the trip's end closes it.
        send({'caseId': 'c3', 'edge': 'start'});
        send({'caseId': 'c3', 'edge': 'cancel'});
        send({'caseId': 'c4', 'edge': 'start', 'truth': 'road'});
        await settle();
        drive(3, arkitFace);
        final live = text.where((l) => l['kind'] == 'case').toList();
        expect(live.map((l) => '${l['caseId']} ${l['edge']}'), [
          'c1 start',
          'c1 end',
          'c2 start',
          'c2 end',
          'c2 truth',
          'c3 start',
          'c3 cancel',
          'c4 start',
        ]);
        await socket.close();
        await trip.finish();

        final file = (await LabRecorder(dir).list()).single;
        final recorded = await file.readAsString();
        final lines = [
          for (final l in const LineSplitter().convert(recorded))
            jsonDecode(l) as Map<String, dynamic>,
        ];
        final cases = tripCases(lines);
        expect(cases.map((c) => c.truth), [
          'eyes_closed',
          'mirror_left',
          'road',
        ]);
        expect(cases.last.endUs, isNotNull);
        final alarms = [
          for (final l in lines)
            if (l['type'] == 'event' && l['change'] == 'started')
              (
                ((l['event'] as Map)['thresholdUs'] as int) +
                    (l['sessionOffsetUs'] as int),
                (l['event'] as Map)['type'] as String,
              ),
        ];
        expect(cases.map((c) => caseOutcome(c, alarms)), ['ok', 'ok', 'ok']);
        // Both edges of each case start a clip; the truth does not.
        expect(lines.where((l) => l['kind'] == 'case').map((l) => l['edge']), [
          'start',
          'end',
          'start',
          'end',
          'truth',
          'start',
          'cancel',
          'start',
          'end',
        ]);
        // No voice for the case the trip's end closed.
        expect(platform.spoken, isNot(contains('Отметил')));

        final empty = TripReview(recordingId: 'x', items: const []);
        expect(
          Recording.parse(
            labelTrip(recorded, empty, scoreGaps: false),
          ).labels.map((l) => l.step).toSet(),
          isNot(contains(TripReviewSteps.drive)),
        );
        final recording = Recording.parse(labelTrip(recorded, empty));
        expect(
          recording.labels.map((l) => l.step).toSet(),
          containsAll([
            TripReviewSteps.caseEyes,
            TripReviewSteps.caseQuiet,
            TripReviewSteps.drive,
          ]),
        );
        final result = ReplayRunner(recording).run(
          ReplayOptions(
            engine: recording.engines.single,
            profile: DetectionProfile.v1,
          ),
        );
        final eyes = result.episodes.singleWhere(
          (e) => e.episode.step == TripReviewSteps.caseEyes,
        );
        expect(
          [...eyes.matched, ...eyes.late].map((e) => e.type),
          contains('eyes_closed'),
        );
        expect(result.episodes.expand((e) => e.unexpected), isEmpty);
      },
    );

    test('case outcomes', () {
      TripCase c(String? truth, {int? end = 5000000}) => TripCase('c', 0)
        ..endUs = end
        ..truth = truth;
      const eyes = [(2000000, 'eyes_closed')];
      const head = [(2000000, 'head_pitch_down')];
      expect(caseOutcome(c('road'), const []), 'ok');
      expect(caseOutcome(c('mirror_left'), head), 'false_alarm');
      // Up to 1 s after the end still counts.
      expect(
        caseOutcome(c('road'), const [(5900000, 'eyes_closed')]),
        'false_alarm',
      );
      expect(caseOutcome(c('road'), const [(6100000, 'eyes_closed')]), 'ok');
      expect(caseOutcome(c('eyes_closed'), eyes), 'ok');
      expect(caseOutcome(c('eyes_closed'), const []), 'missed');
      expect(caseOutcome(c('nod'), eyes), 'other_type');
      expect(caseOutcome(c('other_alarm'), head), 'ok');
      expect(caseOutcome(c(null), eyes), 'unsure');
      expect(caseOutcome(c('road', end: null), const []), 'unsure');
      expect(caseOutcome(c('something new'), const []), 'unsure');
    });

    test('case rules: short alarm-wanted poses, the tail, the next case', () {
      TripCase c(String truth, int start, int end) => TripCase('c$start', start)
        ..endUs = end
        ..truth = truth;
      // An alarm-wanted pose held less than 3 s is not scored either way:
      // the finger is late at both ends, the closure may be 1.3 s.
      expect(
        caseOutcome(c('eyes_closed', 0, 2900000), const [
          (1700000, 'eyes_closed'),
        ]),
        'too_short',
      );
      expect(caseOutcome(c('nod', 0, 2900000), const []), 'too_short');
      expect(caseOutcome(c('nod', 0, 3000000), const []), 'missed');
      expect(caseOutcome(c('blink', 0, 900000), const []), 'ok');
      expect(
        caseWindows([c('eyes_closed', 0, 2900000)]).single.step,
        TripReviewSteps.unsure,
      );

      // The tail after a case never reaches into the next one.
      Map<String, dynamic> mark(String id, String edge, int at, [String? t]) =>
          {
            'type': 'mark',
            'kind': 'case',
            'caseId': id,
            'edge': edge,
            'atUs': at,
            'truth': ?t,
          };
      final cases = tripCases([
        mark('a', 'start', 0),
        mark('a', 'end', 4000000, 'mirror_left'),
        mark('b', 'start', 4300000),
        mark('b', 'end', 8000000, 'eyes_closed'),
      ]);
      expect(cases.map((c) => c.toUs), [4300000, 9000000]);
      const alarm = [(4800000, 'eyes_closed')];
      expect(cases.map((c) => caseOutcome(c, alarm)), ['ok', 'ok']);
      expect(caseWindows(cases).map((w) => '${w.step} ${w.toUs}'), [
        'trip_case_quiet 4300000',
        'trip_case_eyes 9000000',
      ]);
    });

    test('several answers on one case: the alarm-wanted one decides', () {
      expect(truthParts('eyes_closed+mirror_right'), [
        'eyes_closed',
        'mirror_right',
      ]);
      expect(truthParts('eyes_closed+sneeze'), isEmpty);
      expect(truthExpect('mirror_right+talk'), 'none');
      expect(truthExpect('mirror_right+eyes_closed'), 'eyes');
      // A lowered head hides the eyes: the head alarm is the one wanted.
      expect(truthExpect('eyes_closed+nod'), 'head');
      expect(truthExpect('other_alarm+yawn'), 'any');
      expect(truthExpect('eyes_closed+sneeze'), isNull);
      expect(truthExpect(null), isNull);
      // One spelling: alarm-wanted answers first, then the page's order.
      expect(
        truthKey('talk+mirror_right+eyes_closed'),
        'eyes_closed+mirror_right+talk',
      );
      expect(truthKey('nod+eyes_closed'), 'eyes_closed+nod');
      expect(truthKey('sneeze'), 'sneeze');

      Map<String, dynamic> mark(String id, String edge, int at, [String? t]) =>
          {
            'type': 'mark',
            'kind': 'case',
            'caseId': id,
            'edge': edge,
            'atUs': at,
            'truth': ?t,
          };
      final cases = tripCases([
        mark('a', 'start', 0),
        mark('a', 'end', 4000000, 'mirror_right+eyes_closed'),
        mark('b', 'start', 10000000, 'nod'),
        mark('b', 'truth', 11000000, 'nod+eyes_closed'),
        mark('b', 'end', 14000000),
        mark('c', 'start', 20000000),
        mark('c', 'end', 24000000, 'talk+mirror_left'),
        mark('d', 'start', 30000000),
        mark('d', 'end', 34000000, 'eyes_closed+sneeze'),
      ]);
      expect(cases.map((c) => c.truth), [
        'eyes_closed+mirror_right',
        'eyes_closed+nod',
        'mirror_left+talk',
        'eyes_closed+sneeze',
      ]);
      expect(cases.map((c) => c.expect), ['eyes', 'head', 'none', null]);
      const alarms = [
        (1700000, 'eyes_closed'),
        (11700000, 'eyes_closed'),
        (21700000, 'eyes_closed'),
      ];
      expect(cases.map((c) => caseOutcome(c, alarms)), [
        'ok',
        // The eyes alarm woke the driver, the head channel missed its pose.
        'other_type',
        'false_alarm',
        'unsure',
      ]);
      expect(
        caseOutcome(cases[1], const [(11600000, 'head_pitch_down')]),
        'ok',
      );
      expect(caseWindows(cases).map((w) => w.step), [
        TripReviewSteps.caseEyes,
        TripReviewSteps.caseHead,
        TripReviewSteps.caseQuiet,
        TripReviewSteps.unsure,
      ]);
      // The review's answer may be a combination too.
      final review = TripReview.fromJson({
        'type': 'review',
        'schema': 1,
        'recordingId': 'r',
        'items': [
          {
            'kind': 'case',
            'caseId': 'c',
            'atUs': 20000000,
            'endedUs': 24000000,
            'truth': 'mirror_left+eyes_closed',
          },
        ],
      });
      expect(
        tripCases([
          mark('c', 'start', 20000000),
          mark('c', 'end', 24000000, 'talk'),
        ], review: review).single.truth,
        'eyes_closed+mirror_left',
      );
    });

    test('the review corrects cases; an alarm in a case is not judged apart', () {
      String line(Map<String, Object?> m) => jsonEncode(m);
      Map<String, Object?> mark(String id, String edge, int at, [String? t]) =>
          {
            'type': 'mark',
            'kind': 'case',
            'caseId': id,
            'edge': edge,
            'atUs': at,
            'truth': ?t,
          };
      final jsonl = [
        line({'type': 'calibration', 'atUs': 1000000}),
        line(mark('a', 'start', 10000000)),
        line(mark('a', 'end', 14000000, 'road')),
        line(mark('b', 'start', 32500000, 'mirror_left')),
        line(mark('b', 'end', 36000000)),
        line({'type': 'derived', 'atUs': 60000000}),
      ].join('\n');
      final review = TripReview.fromJson({
        'type': 'review',
        'schema': 1,
        'recordingId': 'trip-1',
        'scoreGaps': false,
        'items': [
          // The reviewer saw on the clip that it was a long look down and
          // that the case ended a second later.
          {
            'kind': 'case',
            'caseId': 'a',
            'atUs': 10000000,
            'endedUs': 15000000,
            'truth': 'look_down',
          },
          // An older page listed the alarm inside the case as well.
          {
            'kind': 'event',
            'eventType': 'head_pitch_down',
            'atUs': 12000000,
            'signStartedUs': 10500000,
            'endedUs': 14500000,
          },
          // A false alarm between the cases: its margin stops at case b.
          {
            'kind': 'event',
            'eventType': 'head_pitch_down',
            'atUs': 30000000,
            'signStartedUs': 28500000,
            'endedUs': 31000000,
            'verdict': 'false',
            'cause': 'road',
            'truth': 'road',
          },
        ],
      });
      expect(review.scoreGaps, isFalse);
      final cases = tripCases([
        for (final l in const LineSplitter().convert(jsonl))
          jsonDecode(l) as Map<String, dynamic>,
      ], review: review);
      expect(cases.first.truth, 'look_down');
      expect(cases.first.endUs, 15000000);
      List<String> steps(String labelled) {
        final labels = Recording.parse(labelled).labels;
        return [
          for (final l in labels.where((l) => l.edge == 'start'))
            '${l.step} ${l.atUs ~/ 100000} '
                '${labels.firstWhere((e) => e.edge == 'end' && e.rep == l.rep).atUs ~/ 100000}',
        ];
      }

      // The reviewer chose not to score the time outside the cases.
      expect(steps(labelTrip(jsonl, review)), [
        'trip_unsure 10 100',
        'trip_case_head 100 160',
        'trip_unsure 160 265',
        'trip_alarm_false 265 325',
        'trip_case_quiet 325 370',
        'trip_unsure 370 600',
      ]);
      expect(
        steps(labelTrip(jsonl, review, scoreGaps: true)),
        contains('trip_drive 160 265'),
      );
    });

    test('the pages offer the answers of caseTruths, one key each', () {
      for (final html in [labPageHtml, reviewPageHtml]) {
        final block = RegExp(
          r'const TRUTHS = \[(.*?)\]\];',
          dotAll: true,
        ).firstMatch(html)!.group(1)!;
        final rows = RegExp(
          r'\["(\w+)","[^"]*","(\w+)","(\w+)"',
        ).allMatches(block).toList();
        expect({for (final m in rows) m.group(1)!: m.group(2)!}, caseTruths);
        expect({for (final m in rows) m.group(3)}, hasLength(rows.length));
        // Several answers: the same order of what decides as truthExpect.
        expect(html, contains('["head", "eyes", "any", "none"].find('));
      }
    });

    test(
      'the hand that confirmed the face does not spoil the calibration',
      () async {
        await trip.start();
        trip.clock.stop();
        final tap = trip.clock.elapsedMicroseconds;
        arkit().emit([arkitFace()], tap);
        trip.confirmFace(arkitFace().trackingId!);
        expect(
          trip.calibrationStartUs,
          tap + TripController.calibrationSettleUs,
        );
        // The hand covers the camera, then the head turns back.
        const settle = 1500000;
        for (var t = tap + 33000; t < tap + 1400000; t += 33000) {
          arkit().emit(t < tap + 900000 ? [] : [arkitFace(view: 10)], t);
        }
        final start = trip.calibrationStartUs;
        for (var t = tap + 1400000; t <= tap + settle + 10200000; t += 33000) {
          arkit().emit([arkitFace()], t);
        }
        trip.finishCalibration(start + 10300000);
        expect(trip.phase, TripPhase.observing);
        await trip.finish();
      },
    );

    test(
      'with the live debug on the trip is recorded without the option',
      () async {
        // Labels of the live page are worth nothing without the numbers.
        trip.recordTrips = false;
        await trip.setLiveDebug(true);
        await trip.start();
        expect(trip.recording, isTrue);
        calibrate();
        drive(1, arkitFace);
        trip.mark(
          kind: 'case',
          source: 'mac',
          caseId: 'c1',
          edge: 'start',
          truth: 'eyes_closed+mirror_right',
        );
        drive(1, arkitFace);
        await trip.finish();
        final file = (await LabRecorder(dir).list()).single;
        final lines = [
          for (final l in await file.readAsLines())
            if (l.isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
        ];
        expect(lines.first['live'], isNull);
        expect(lines.where((l) => l['type'] == 'derived'), isNotEmpty);
        expect(tripCases(lines).single.truth, 'eyes_closed+mirror_right');
      },
    );

    test('nothing goes out without the recording or a live page', () async {
      trip.recordTrips = false;
      await trip.start();
      calibrate();
      drive(1, arkitFace);
      expect(trip.debugServer, isNull);
      expect(arkit().video, isEmpty);
      await trip.finish();
      expect(await LabRecorder(dir).list(), isEmpty);
    });
  });

  group('review windows', () {
    test('alarms, misses and the drive between them', () {
      final review = TripReview.fromJson({
        'type': 'review',
        'schema': 1,
        'recordingId': 'trip-1',
        'items': [
          {
            'kind': 'event',
            'eventType': 'head_pitch_down',
            'atUs': 30000000,
            'signStartedUs': 28500000,
            'endedUs': 31000000,
            'verdict': 'false',
          },
          {
            'kind': 'event',
            'eventType': 'eyes_closed',
            'atUs': 60000000,
            'signStartedUs': 58400000,
            'verdict': 'true',
          },
          {
            'kind': 'mark',
            'mark': 'miss',
            'atUs': 100000000,
            'verdict': 'miss_head',
          },
          {'kind': 'mark', 'mark': 'mark', 'atUs': 120000000},
          {
            'kind': 'mark',
            'mark': 'mark',
            'atUs': 140000000,
            'verdict': 'no_issue',
          },
        ],
      });
      final w = reviewWindows(review, fromUs: 10000000, toUs: 200000000);
      expect(
        [
          for (final x in w)
            '${x.step} ${x.fromUs ~/ 100000} ${x.toUs ~/ 100000}',
        ],
        [
          'trip_drive 100 265',
          'trip_alarm_false 265 330',
          'trip_drive 330 584',
          'trip_eyes_true 584 610',
          'trip_drive 610 900',
          'trip_head_missed 900 1010',
          'trip_drive 1010 1100',
          'trip_unsure 1100 1210',
          'trip_drive 1210 2000',
        ],
      );
      expect(w.where((x) => x.aborted).single.step, TripReviewSteps.unsure);
      expect(
        () => TripReview.fromJson({'type': 'review', 'schema': 2}),
        throwsFormatException,
      );
    });
  });

  test('ARKit engine maps debug JPEG events to the caller clock', () async {
    // Covered on the device; here only that the option survives a stop.
    final engine = ArkitEngine();
    await engine.setDebugVideo(DebugVideoOptions.live, (_) {});
    expect(engine.debugVideo.fps, 5);
    expect(engine.running, isFalse);
  });

  test('the review page has no external resources', () async {
    final source = await File(
      'lib/services/review_page_html.dart',
    ).readAsString();
    expect(source, isNot(contains('http://')));
    expect(source, isNot(contains('https://')));
  });
}

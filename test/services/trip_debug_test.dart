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
import 'package:nscontrol/services/lab_recorder.dart';
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

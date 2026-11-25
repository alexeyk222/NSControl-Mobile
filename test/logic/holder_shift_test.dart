import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/detection_profile.dart';
import 'package:nscontrol/logic/holder_shift.dart';

/// "Up" of a phone tilted [deg] about the camera x axis from [-1, 0, 0]
/// (the lab's landscape sensor frame), towards +z.
List<double> up(double deg) {
  final r = deg * math.pi / 180;
  return [-math.cos(r), 0, math.sin(r)];
}

void main() {
  HolderShift shift() =>
      HolderShift()..reset(gravityUp: up(0), eyesInHead: (10, 4));

  /// Frames every 33 ms from [from] for [seconds].
  int run(
    HolderShift h,
    int from,
    double seconds, {
    double tilt = 0,
    (double, double, double)? head = (0, 0, 0),
    (double, double)? eyes = (10, 4),
    bool sign = false,
  }) {
    var t = from;
    for (; t < from + seconds * 1e6; t += 33000) {
      h.observe(
        t,
        gravityUp: up(tilt),
        head: head,
        eyesInHead: eyes,
        sign: sign,
      );
    }
    return t;
  }

  group('gravity', () {
    test('a holder tilted 15° for 5 s is a shift', () {
      final h = shift();
      final t = run(h, 0, 20);
      run(h, t, 6, tilt: 15);
      expect(h.suspected, isTrue);
      expect(h.source, HolderShiftSource.gravity);
      expect(h.sinceUs, greaterThanOrEqualTo(t));
      expect(h.offset.$2.abs(), closeTo(15, .5));
      expect(h.offset.$1, 0);
    });

    test('a short jolt or a slow sag below 8° is not', () {
      final h = shift();
      var t = run(h, 0, 2, tilt: 15);
      t = run(h, t, 10);
      run(h, t, 60, tilt: 6);
      expect(h.suspected, isFalse);
    });
  });

  group('pose', () {
    test(
      'a holder turned 18° about the vertical: head aside, eyes as before',
      () {
        final h = shift();
        final t = run(h, 0, 10);
        run(h, t, 16, head: (18, 1, 0));
        expect(h.suspected, isTrue);
        expect(h.source, HolderShiftSource.pose);
        expect(h.offset.$1, closeTo(18, 1e-9));
      },
    );

    test('a long look aside moves the eyes in the head: not a shift', () {
      final h = shift();
      run(h, 0, 20, head: (18, 1, 0), eyes: (25, 4));
      expect(h.suspected, isFalse);
    });

    test('a look aside for half of the window is not a shift', () {
      final h = shift();
      var t = run(h, 0, 10);
      for (var i = 0; i < 4; i++) {
        t = run(h, t, 8, head: (20, 2, 0));
        t = run(h, t, 7);
      }
      expect(h.suspected, isFalse);
    });

    test('mirror glances on a steady road are not a shift', () {
      final h = shift();
      var t = 0;
      for (var i = 0; i < 10; i++) {
        t = run(h, t, 5);
        t = run(h, t, 2.5, head: (i.isEven ? 30 : -38, 3, 0));
      }
      expect(h.suspected, isFalse);
    });

    test('a steady pitch is the posture: gravity sees a tilted holder', () {
      final h = shift();
      run(h, 0, 30, head: (2, -13, 0));
      expect(h.suspected, isFalse);
    });

    test('closed eyes or a ТЗ sign do not count', () {
      final h = shift();
      run(h, 0, 20, head: (18, 1, 0), sign: true);
      expect(h.suspected, isFalse);
    });

    test('without gaze (ML Kit) the head alone decides', () {
      final h = HolderShift()..reset();
      run(h, 0, 16, head: (-16, 0, 0), eyes: null);
      expect(h.suspected, isTrue);
      expect(h.offset.$1, closeTo(-16, 1e-9));
    });
  });

  test('settings travel with the profile', () {
    final json = DetectionProfile.v1.toJson();
    expect(json['holderShift'], const HolderShiftSettings().toJson());
    expect(
      DetectionProfile.fromJson(json).holderShift.poseHoldUs,
      DetectionProfile.v1.holderShift.poseHoldUs,
    );
  });
}

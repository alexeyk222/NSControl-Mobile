import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/mount_shift.dart';

void main() {
  const s = 1000000;
  test('starts after 20 s at the cap, on the road, without a sign', () {
    final m = MountShiftMonitor();
    bool at(int t, {int? since = 0, bool road = true, bool sign = false}) =>
        m.shouldStart(
          atUs: t,
          atLimitSinceUs: since,
          onRoad: road,
          signActive: sign,
        );
    expect(at(10 * s, since: null), isFalse);
    expect(at(19 * s), isFalse);
    expect(at(20 * s, road: false), isFalse);
    expect(at(20 * s, sign: true), isFalse);
    expect(at(20 * s), isTrue);
    m.attempted(20 * s);
    expect(at(60 * s), isFalse);
    expect(at(140 * s), isTrue);
  });

  test('a sudden shift starts without the hold and the road zone', () {
    final m = MountShiftMonitor();
    bool at(int t, {bool sign = false}) => m.shouldStart(
      atUs: t,
      atLimitSinceUs: null,
      onRoad: false,
      signActive: sign,
      shifted: true,
    );
    expect(at(5 * s, sign: true), isFalse);
    expect(at(5 * s), isTrue);
    m.attempted(5 * s);
    expect(at(60 * s), isFalse);
    expect(at(125 * s), isTrue);
  });
}

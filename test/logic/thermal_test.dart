import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/thermal.dart';

void main() {
  const s = 1000000;
  group('HeatPolicy', () {
    test('serious: economy, 15 analyses a second at 30 fps, said once', () {
      final h = HeatPolicy();
      expect(h.update(atUs: 0, thermal: 'fair', sent: 30).sayEconomy, isFalse);
      expect(h.economy, isFalse);
      expect(h.emitEvery(30), 1);
      final d = h.update(atUs: s, thermal: 'serious', sent: 30);
      expect(d.sayEconomy, isTrue);
      expect(h.economy, isTrue);
      expect(h.previewAllowed, isFalse);
      expect(h.emitEvery(30), 2);
      expect(
        h.update(atUs: 2 * s, thermal: 'serious', sent: 15).sayEconomy,
        isFalse,
      );
    });

    test('never below 10 analyses a second', () {
      final h = HeatPolicy()..update(atUs: 0, thermal: 'serious', sent: 30);
      expect(h.emitEvery(60), 4);
      expect(30 / h.emitEvery(30), greaterThanOrEqualTo(10));
      expect(h.emitEvery(20), 1);
      expect(h.emitEvery(12), 1);
    });

    test('the full rate returns when the analyses fall below 10', () {
      final h = HeatPolicy()..update(atUs: 0, thermal: 'serious', sent: 30);
      h.restarted();
      // Two partial seconds after the restart do not count.
      h.update(atUs: s, thermal: 'serious', sent: 3);
      h.update(atUs: 2 * s, thermal: 'serious', sent: 3);
      h.update(atUs: 3 * s, thermal: 'serious', sent: 9);
      h.update(atUs: 4 * s, thermal: 'serious', sent: 9);
      expect(h.rateReduced, isTrue);
      h.update(atUs: 5 * s, thermal: 'serious', sent: 7);
      expect(h.rateReduced, isFalse);
      expect(h.floorHit, isTrue);
      expect(h.emitEvery(30), 1);
      // Economy (no preview) stays.
      expect(h.economy, isTrue);
    });

    test('critical warns now and every 5 minutes', () {
      final h = HeatPolicy();
      final first = h.update(atUs: 0, thermal: 'critical', sent: 30);
      expect(first.warnCritical, isTrue);
      expect(first.sayEconomy, isFalse);
      expect(h.critical, isTrue);
      expect(
        h.update(atUs: 60 * s, thermal: 'critical', sent: 15).warnCritical,
        isFalse,
      );
      expect(
        h.update(atUs: 300 * s, thermal: 'critical', sent: 15).warnCritical,
        isTrue,
      );
      // Back to serious and up again: warned at once.
      h.update(atUs: 301 * s, thermal: 'serious', sent: 15);
      expect(
        h.update(atUs: 302 * s, thermal: 'critical', sent: 15).warnCritical,
        isTrue,
      );
    });

    test('economy ends after 2 minutes cool, not on a short dip', () {
      final h = HeatPolicy()..update(atUs: 0, thermal: 'serious', sent: 30);
      h.update(atUs: s, thermal: 'fair', sent: 15);
      h.update(atUs: 60 * s, thermal: 'fair', sent: 15);
      h.update(atUs: 61 * s, thermal: 'serious', sent: 15);
      h.update(atUs: 62 * s, thermal: 'fair', sent: 15);
      h.update(atUs: 150 * s, thermal: 'nominal', sent: 15);
      expect(h.economy, isTrue);
      h.update(atUs: 182 * s, thermal: 'nominal', sent: 15);
      expect(h.economy, isFalse);
      expect(h.emitEvery(30), 1);
      // Hot again later: not announced a second time in the trip.
      expect(
        h.update(atUs: 400 * s, thermal: 'serious', sent: 30).sayEconomy,
        isFalse,
      );
      expect(h.economy, isTrue);
    });

    test('unknown states change nothing', () {
      final h = HeatPolicy()..update(atUs: 0, thermal: 'unknown', sent: 30);
      expect(h.economy, isFalse);
      expect(h.thermal, isNull);
    });
  });
}

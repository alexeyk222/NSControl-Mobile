import 'package:flutter_test/flutter_test.dart';
import 'package:nscontrol/logic/recommendation.dart';
import 'package:nscontrol/ui/copy.dart';
import 'package:nscontrol/ui/presentation/readiness.dart';
import 'package:nscontrol/ui/widgets/marks.dart';
import 'package:nscontrol/ui/widgets/mount_diagram.dart';

import 'copy_test.dart' show plain;

/// docs/ux/states.md P-01…P-07 on «Перед поездкой».
void main() {
  final day = DateTime(2026, 11, 26, 14);
  final night = DateTime(2026, 11, 26, 3);

  ReadinessFacts slept(Duration d, {DateTime? now, SelfAssessment? feel}) =>
      ReadinessFacts(
        now: now ?? day,
        sleepKnown: true,
        sleepComplete: true,
        sleepDuration: d,
        sleepReadAt: (now ?? day).subtract(const Duration(hours: 1)),
        feel: feel ?? SelfAssessment.unknown,
      );

  test('P-02 everything is fine', () {
    final r = Readiness.from(slept(const Duration(hours: 8)));
    expect(r.verdict, Copy.verdictOk);
    expect(plain(r.sub!), 'Перерыв советую через 2 часа');
    expect(r.reasons, isEmpty);
  });

  test('P-03 short sleep, sleepy, night: rest, with reasons', () {
    final r = Readiness.from(
      slept(
        const Duration(hours: 4, minutes: 50),
        now: night,
        feel: SelfAssessment.sleepy,
      ),
    );
    expect(r.verdict, Copy.verdictRest);
    expect(r.kind, VerdictKind.rest);
    expect(r.reasons.map(plain), [
      'Сон за сутки: 4 ч 50 мин',
      Copy.reasonSleepy,
      Copy.reasonNight,
    ]);
  });

  test(
    'P-01 no sleep data: «Не знаю, как вы спали» unless the driver is fine',
    () {
      final unknown = Readiness.from(ReadinessFacts(now: day));
      expect(unknown.verdict, Copy.verdictUnknown);
      expect(unknown.sleep.title, Copy.readySleepNone);
      expect(unknown.sleep.action, ReadyAction.allowSleep);
      final fine = Readiness.from(
        ReadinessFacts(now: day, feel: SelfAssessment.notSleepy),
      );
      expect(fine.verdict, Copy.verdictOk);
    },
  );

  test('readiness rows: camera, watch, sleep', () {
    final r = Readiness.from(
      ReadinessFacts(
        now: day,
        cameraReady: true,
        side: MountSide.right,
        watch: WatchReadiness.ready,
        sleepKnown: true,
        sleepComplete: true,
        sleepDuration: const Duration(hours: 8),
        sleepReadAt: DateTime(2026, 11, 26, 8, 14),
      ),
    );
    expect(r.camera.title, 'Камера настроена · справа');
    expect(r.camera.mark, MarkKind.ok);
    expect(r.watch.action, ReadyAction.testWatch);
    expect(r.sleep.title, 'Сон обновлён в 08:14');
    final first = Readiness.from(ReadinessFacts(now: day));
    expect(first.camera.title, Copy.readyCameraNone);
    expect(first.camera.mark, MarkKind.todo);
    final denied = Readiness.from(ReadinessFacts(now: day, cameraDenied: true));
    expect(denied.camera.action, ReadyAction.openSettings);
  });

  test('a sleep read long ago asks to refresh', () {
    final r = Readiness.from(
      ReadinessFacts(
        now: day,
        sleepKnown: true,
        sleepComplete: true,
        sleepDuration: const Duration(hours: 8),
        sleepReadAt: day.subtract(const Duration(hours: 20)),
      ),
    );
    expect(r.sleep.title, Copy.readySleepStale);
    expect(r.sleep.action, ReadyAction.refreshSleep);
  });
}

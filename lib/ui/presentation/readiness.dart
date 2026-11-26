import '../../logic/recommendation.dart';
import '../../logic/sleep.dart';
import '../../services/sleep_controller.dart';
import '../../services/trip_controller.dart';
import '../copy.dart';
import '../widgets/marks.dart';
import '../widgets/mount_diagram.dart';

/// The «Перед поездкой» screen as data: the verdict, its reasons and the
/// three readiness rows (camera, watch, sleep). Pure: [Readiness.from]
/// takes [ReadinessFacts], tests build them by hand.
class Readiness {
  const Readiness({
    required this.verdict,
    required this.kind,
    this.sub,
    this.reasons = const [],
    required this.camera,
    required this.watch,
    required this.sleep,
  });

  final String verdict;
  final VerdictKind kind;
  final String? sub;

  /// Reasons under the verdict, each with an amber diamond.
  final List<String> reasons;
  final ReadyRow camera, watch, sleep;

  List<ReadyRow> get rows => [camera, watch, sleep];

  /// How long the break advice comes after (`RecommendationEngine`).
  static const breakAfter = RecommendationEngine.defaultLongDrive;

  static Readiness from(ReadinessFacts f) {
    final reasons = <String>[];
    final short = f.sleepComplete && f.sleepDuration < const Duration(hours: 7);
    if (short) {
      reasons.add(Copy.reasonSleepShort(hoursMinutes(f.sleepDuration)));
    }
    if (f.feel == SelfAssessment.sleepy) reasons.add(Copy.reasonSleepy);
    if (f.now.hour < 6) reasons.add(Copy.reasonNight);
    if (f.sleepKnown && !f.sleepComplete && f.sleepDuration > Duration.zero) {
      reasons.add(Copy.reasonSleepPartial(hoursMinutes(f.sleepDuration)));
    }

    final String verdict;
    final VerdictKind kind;
    String? sub;
    if (short || f.feel == SelfAssessment.sleepy) {
      verdict = Copy.verdictRest;
      kind = VerdictKind.rest;
    } else if (!f.sleepComplete && f.feel != SelfAssessment.notSleepy) {
      verdict = Copy.verdictUnknown;
      kind = VerdictKind.unknown;
      sub = Copy.verdictUnknownSub;
    } else {
      verdict = Copy.verdictOk;
      kind = VerdictKind.ok;
      sub = Copy.verdictOkSub(breakInterval(breakAfter));
    }

    final camera = f.cameraDenied
        ? const ReadyRow(
            id: 'camera',
            title: Copy.readyCameraDenied,
            note: Copy.calCameraDenied,
            mark: MarkKind.attention,
            action: ReadyAction.openSettings,
          )
        : f.cameraReady
        ? ReadyRow(
            id: 'camera',
            title: Copy.readyCameraOk(f.side.short),
            mark: MarkKind.ok,
          )
        : const ReadyRow(
            id: 'camera',
            title: Copy.readyCameraNone,
            note: Copy.readyCameraNote,
            mark: MarkKind.todo,
          );

    final watch = switch (f.watch) {
      WatchReadiness.ready => const ReadyRow(
        id: 'watch',
        title: Copy.readyWatchOk,
        note: Copy.readyWatchNote,
        mark: MarkKind.ok,
        action: ReadyAction.testWatch,
      ),
      WatchReadiness.closed => const ReadyRow(
        id: 'watch',
        title: Copy.readyWatchClosed,
        note: Copy.readyWatchNote,
        mark: MarkKind.attention,
      ),
      WatchReadiness.missing => const ReadyRow(
        id: 'watch',
        title: Copy.readyWatchMissing,
        mark: MarkKind.todo,
      ),
      WatchReadiness.none => const ReadyRow(
        id: 'watch',
        title: Copy.readyWatchOff,
        mark: MarkKind.neutral,
      ),
    };

    final sleep = !f.sleepKnown
        ? const ReadyRow(
            id: 'sleep',
            title: Copy.readySleepNone,
            note: Copy.readySleepNoneNote,
            mark: MarkKind.attention,
            action: ReadyAction.allowSleep,
          )
        : f.sleepReadAt == null ||
              f.now.difference(f.sleepReadAt!) > const Duration(hours: 12)
        ? const ReadyRow(
            id: 'sleep',
            title: Copy.readySleepStale,
            note: Copy.readySleepNote,
            mark: MarkKind.attention,
            action: ReadyAction.refreshSleep,
          )
        : ReadyRow(
            id: 'sleep',
            title: Copy.readySleepOk(clock(f.sleepReadAt!)),
            note: Copy.readySleepNote,
            mark: MarkKind.ok,
          );

    return Readiness(
      verdict: verdict,
      kind: kind,
      sub: sub,
      reasons: kind == VerdictKind.ok
          ? reasons.where((r) => r == Copy.reasonNight).toList()
          : reasons,
      camera: camera,
      watch: watch,
      sleep: sleep,
    );
  }
}

/// The verdict's colour: the look's text, amber «лучше отдохнуть», or
/// the plain «не знаю».
enum VerdictKind { ok, rest, unknown }

/// What the button at the end of a readiness row does.
enum ReadyAction { testWatch, allowSleep, refreshSleep, openSettings }

class ReadyRow {
  const ReadyRow({
    required this.id,
    required this.title,
    required this.mark,
    this.note,
    this.action,
  });
  final String id, title;
  final String? note;
  final MarkKind mark;
  final ReadyAction? action;

  String? get actionLabel => switch (action) {
    ReadyAction.testWatch => Copy.actCheck,
    ReadyAction.allowSleep => Copy.actAllow,
    ReadyAction.refreshSleep => Copy.actRefresh,
    ReadyAction.openSettings => Copy.actOpenSettings,
    null => null,
  };
}

/// State of the watch for the readiness row, from the trip controller's
/// handshake and its status line (`TripController.describeWearable`).
enum WatchReadiness {
  ready,
  closed,
  missing,
  none;

  static WatchReadiness of(TripController trip) {
    if (trip.wearable.synchronized) return ready;
    final s = trip.wearableStatus;
    if (s.contains('не установлено')) return missing;
    if (s.contains('Откройте NSControl') ||
        s.contains('не ответили') ||
        s.contains('Подключение')) {
      return closed;
    }
    return none;
  }
}

class ReadinessFacts {
  const ReadinessFacts({
    required this.now,
    this.feel = SelfAssessment.unknown,
    this.sleepKnown = false,
    this.sleepComplete = false,
    this.sleepDuration = Duration.zero,
    this.sleepReadAt,
    this.cameraReady = false,
    this.cameraDenied = false,
    this.side = MountSide.left,
    this.watch = WatchReadiness.none,
  });

  factory ReadinessFacts.of({
    required TripController trip,
    required SleepController sleep,
    required bool cameraReady,
    DateTime? now,
  }) {
    final summary = sleep.summary;
    return ReadinessFacts(
      now: now ?? DateTime.now(),
      feel: sleep.assessment,
      sleepKnown:
          sleep.enabled && summary.readStatus == SleepReadStatus.success,
      sleepComplete: summary.complete,
      sleepDuration: summary.duration,
      sleepReadAt: sleep.lastRead,
      cameraReady: cameraReady,
      cameraDenied: trip.cameraPermissionBlocked,
      side: MountSide.parse(trip.mountPosition),
      watch: WatchReadiness.of(trip),
    );
  }

  final DateTime now;
  final SelfAssessment feel;
  final bool sleepKnown, sleepComplete, cameraReady, cameraDenied;
  final Duration sleepDuration;
  final DateTime? sleepReadAt;
  final MountSide side;
  final WatchReadiness watch;
}

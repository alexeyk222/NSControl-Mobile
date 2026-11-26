import '../../services/trip_controller.dart';
import '../copy.dart';
import '../widgets/marks.dart';
import '../widgets/status_indicator.dart';

/// How the trip screen looks now: what the indicator shows, the status
/// word, the line under it, the amber advice and the small notice on top.
///
/// [TripView.from] is a pure function of [TripFacts], so every state of
/// docs/ux/states.md (S-01…S-16) is covered by unit tests without a camera
/// (`test/ui/trip_view_test.dart`). The trip screen only draws the result.
class TripView {
  const TripView({
    required this.indicator,
    required this.status,
    required this.tone,
    this.context,
    this.advice,
    this.notice,
    this.noticeGlyph,
    this.voice,
  });

  final IndicatorKind indicator;

  /// The big word: «Слежу», «Не вижу вас», «Пауза»…
  final String status;
  final StatusTone tone;

  /// The line under the status: time on the road, «Глаза не видно»…
  final String? context;

  /// Amber advice with a diamond («Пора сделать перерыв»).
  final String? advice;

  /// Small line at the top (moved phone, heat, watch, broken journal),
  /// with its icon when it has one.
  final String? notice;
  final NsGlyph? noticeGlyph;

  /// What the interface says when the screen enters this state (null:
  /// nothing, or the trip controller says it itself).
  final String? voice;

  /// Maps the facts to the screen. Priority (states.md §3, highest first):
  /// camera stopped (S-12) › pause (S-07) › not seen (S-04) › several
  /// faces (S-05) › head only (S-02) › watching (S-01). The alarm itself
  /// is drawn over everything by the alarm overlay.
  static TripView from(TripFacts f) {
    final advice = _advice(f);
    final (notice, glyph) = _notice(f);
    // S-12: frames stopped. Never «Слежу» while nothing is watched
    // (architect, 25.11).
    if (f.cameraSilent) {
      return TripView(
        indicator: IndicatorKind.unseen,
        status: Copy.cameraError,
        tone: StatusTone.attention,
        context: Copy.cameraSilentSub,
        advice: advice,
        notice: notice,
        noticeGlyph: glyph,
        voice: Voice.cameraError,
      );
    }
    if (f.userPaused) {
      return TripView(
        indicator: IndicatorKind.paused,
        status: Copy.paused,
        tone: StatusTone.paused,
        advice: advice,
        notice: notice,
        noticeGlyph: glyph,
      );
    }
    if (f.phase != TripPhase.observing || f.watchText == null) {
      // Coming back from the background or starting the session.
      return TripView(
        indicator: IndicatorKind.idle,
        status: Copy.starting,
        tone: StatusTone.paused,
        context: f.phase == TripPhase.paused ? null : _elapsed(f),
        advice: advice,
        notice: notice,
        noticeGlyph: glyph,
      );
    }
    final text = f.watchText!;
    if (f.multipleFaces || text.startsWith('В кадре кто-то ещё')) {
      return TripView(
        indicator: IndicatorKind.unseen,
        status: Copy.many,
        tone: StatusTone.attention,
        context: 'Слежу, когда останетесь одни',
        advice: advice,
        notice: notice,
        noticeGlyph: glyph,
        voice: Voice.many,
      );
    }
    if (text == Copy.noFace) {
      return TripView(
        indicator: IndicatorKind.unseen,
        status: Copy.noFace,
        tone: StatusTone.attention,
        context: Copy.noFaceSub,
        advice: advice,
        notice: notice,
        noticeGlyph: glyph,
        voice: Voice.noFace,
      );
    }
    if (f.headOnly || text == Copy.headOnly) {
      return TripView(
        indicator: IndicatorKind.headOnly,
        status: Copy.headOnly,
        tone: StatusTone.attention,
        context: Copy.eyesHidden,
        advice: advice,
        notice: notice,
        noticeGlyph: glyph,
        // The controller says «…слежу за головой» after the calibration.
      );
    }
    return TripView(
      indicator: IndicatorKind.watching,
      status: Copy.watching,
      tone: StatusTone.normal,
      context: _elapsed(f),
      advice: advice,
      notice: notice,
      noticeGlyph: glyph,
    );
  }

  static String _elapsed(TripFacts f) =>
      Copy.elapsed(hoursMinutes(f.drivingTime));

  /// Advice after an alarm (copy.md §5) or at the break time (S-15).
  static String? _advice(TripFacts f) {
    if (f.eyesAlarms >= 2) return Copy.adviceStopNow;
    if (f.eyesAlarms == 1 || f.headAlarms > 0) return Copy.adviceStop;
    if (f.breakDue) return Copy.adviceBreak;
    return null;
  }

  /// The small line on top; the most useful one wins.
  static (String?, NsGlyph?) _notice(TripFacts f) {
    if (f.movedText != null) return (f.movedText, null);
    if (f.heatText != null) return (f.heatText, NsGlyph.thermo);
    if (f.watchLost) return (Copy.watchLost, NsGlyph.watchOff);
    if (f.journalIncomplete) return (Copy.journalBroken, null);
    if (f.calibrationNote != null) return (f.calibrationNote, null);
    return (null, null);
  }

  @override
  bool operator ==(Object other) =>
      other is TripView &&
      other.indicator == indicator &&
      other.status == status &&
      other.tone == tone &&
      other.context == context &&
      other.advice == advice &&
      other.notice == notice &&
      other.noticeGlyph == noticeGlyph;

  @override
  int get hashCode =>
      Object.hash(indicator, status, tone, context, advice, notice);

  @override
  String toString() => 'TripView($status · $context · $advice · $notice)';
}

/// Colour role of the status word: the look's text, yellow, or dimmed.
enum StatusTone { normal, attention, paused }

/// The facts of the trip that the screen depends on; read from the
/// controller by [TripFacts.of], or built directly in tests.
class TripFacts {
  const TripFacts({
    this.phase = TripPhase.observing,
    this.userPaused = false,
    this.cameraSilent = false,
    this.watchText,
    this.multipleFaces = false,
    this.drivingTime = Duration.zero,
    this.breakDue = false,
    this.eyesAlarms = 0,
    this.headAlarms = 0,
    this.movedText,
    this.heatText,
    this.calibrationNote,
    this.journalIncomplete = false,
    this.watchLost = false,
    this.headOnly = false,
  });

  factory TripFacts.of(TripController trip, {bool watchLost = false}) =>
      TripFacts(
        phase: trip.phase,
        userPaused: trip.userPaused,
        cameraSilent: trip.cameraSilent,
        watchText: trip.watchText,
        headOnly: trip.headOnly,
        multipleFaces: trip.multipleFaces,
        drivingTime: trip.drivingTime,
        breakDue: trip.drive.breakDue(trip.clock.elapsedMicroseconds),
        eyesAlarms: trip.tripEyesAlarms,
        headAlarms: trip.tripHeadAlarms,
        movedText: trip.movedText,
        heatText: trip.heatText,
        calibrationNote: trip.calibrationNote,
        journalIncomplete: trip.journalIncomplete,
        watchLost: watchLost,
      );

  final TripPhase phase;
  final bool userPaused, cameraSilent, multipleFaces, breakDue;

  /// Only the head is watched (calibration without eyes, or eyes lost
  /// for 5 s): «Слежу за головой», the watch shows the same.
  final bool headOnly;
  final String? watchText, movedText, heatText, calibrationNote;
  final Duration drivingTime;
  final int eyesAlarms, headAlarms;
  final bool journalIncomplete, watchLost;
}

/// The mark of a state in the summary and the history.
MarkKind markOf(StatusTone tone) => switch (tone) {
  StatusTone.normal => MarkKind.ok,
  StatusTone.attention => MarkKind.attention,
  StatusTone.paused => MarkKind.neutral,
};

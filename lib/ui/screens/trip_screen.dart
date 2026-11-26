import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../presentation/trip_view.dart';
import '../presentation/voice.dart';
import '../widgets/buttons.dart';
import '../widgets/fit_words.dart';
import '../widgets/marks.dart';
import '../widgets/status_indicator.dart';
import 'trip_dev_panel.dart';

/// «В пути» (design screen 6, states S-01…S-16). Always dark. Built to be
/// read in a glance from 70 cm:
///
/// * the indicator (220 pt; C 150 pt, left-aligned) and the status word;
/// * one context line, one amber advice line;
/// * «Пауза» and «Завершить» (hold 1.2 s); in a pause «Продолжить»;
/// * after [NsMotion.dimAfter] without touches everything dims to 60 % and
///   the buttons hide; a touch brings them back. Nothing else needs a tap.
///
/// The words come from [TripView.from]; voice lines are spoken when the
/// state changes. Developer mode adds [TripDevPanel] and the double-tap
/// mark.
class TripScreen extends StatefulWidget {
  const TripScreen({
    super.key,
    required this.trip,
    required this.voice,
    required this.developerMode,
    required this.onFinish,
  });
  final TripController trip;
  final UiVoice voice;
  final bool developerMode;
  final VoidCallback onFinish;

  @override
  State<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends State<TripScreen> {
  Timer? _dimTimer, _clock;
  bool _dim = false;
  bool _hadWatch = false;
  TripView? _last;
  bool _breakSaid = false;
  int _eyesSeen = 0, _headSeen = 0;

  TripController get trip => widget.trip;

  @override
  void initState() {
    super.initState();
    _hadWatch = trip.wearable.synchronized;
    _eyesSeen = trip.tripEyesAlarms;
    _headSeen = trip.tripHeadAlarms;
    trip.addListener(_onTrip);
    _wake();
    // The context line counts minutes: refresh it even when nothing else
    // changes.
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    trip.removeListener(_onTrip);
    _dimTimer?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  /// Brightens the screen and arms the dimming again.
  void _wake() {
    if (_dim) setState(() => _dim = false);
    _dimTimer?.cancel();
    _dimTimer = Timer(NsMotion.dimAfter, () {
      if (!mounted || trip.userPaused) return;
      setState(() => _dim = true);
    });
  }

  bool get _watchLost => _hadWatch && !trip.wearable.synchronized;

  /// Voice lines on state changes (copy.md §4). The controller speaks the
  /// pause, the resume and «Глаза под таким углом не видно…» itself.
  void _onTrip() {
    if (!mounted) return;
    if (trip.wearable.synchronized) _hadWatch = true;
    final view = TripView.from(TripFacts.of(trip, watchLost: _watchLost));
    final last = _last;
    _last = view;
    if (last != null && last.status != view.status) {
      if (view.voice != null) widget.voice.say(view.voice!);
      if (view.indicator == IndicatorKind.watching ||
          view.indicator == IndicatorKind.unseen) {
        _wake();
      }
      if (trip.userPaused) widget.voice.show(Voice.paused);
      if (last.status == Copy.paused && !trip.userPaused) {
        widget.voice.show(Voice.resumed);
      }
    }
    if (last != null &&
        view.notice == Copy.watchLost &&
        last.notice != Copy.watchLost) {
      widget.voice.say(Voice.watchLost);
    }
    // After an alarm: what to do now (copy.md §5).
    if (trip.tripEyesAlarms > _eyesSeen) {
      _eyesSeen = trip.tripEyesAlarms;
      _afterAlarm(_eyesSeen >= 2 ? Voice.afterEyesAgain : Voice.afterEyes);
    } else if (trip.tripHeadAlarms > _headSeen) {
      _headSeen = trip.tripHeadAlarms;
      _afterAlarm(Voice.afterHead);
    }
    final breakDue = trip.drive.breakDue(trip.clock.elapsedMicroseconds);
    if (breakDue && !_breakSaid) {
      _breakSaid = true;
      // «2 часа», «2,5 часа»: whole half hours read well aloud.
      final halfHours = (trip.drivingTime.inMinutes / 30).round();
      widget.voice.say(
        Voice.breakDue(breakInterval(Duration(minutes: halfHours * 30))),
      );
    } else if (!breakDue) {
      _breakSaid = false;
    }
  }

  /// The advice is spoken once the alarm has ended, not over it.
  void _afterAlarm(String line) {
    Future<void> wait() async {
      for (var i = 0; i < 120; i++) {
        if (!mounted) return;
        if (trip.snapshot?.activeEvents.isEmpty ?? true) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      if (mounted) widget.voice.say(line);
    }

    unawaited(wait());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([trip, widget.voice]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.trip;
    final view = TripView.from(TripFacts.of(trip, watchLost: _watchLost));
    final paused = trip.userPaused;
    final c = theme.design == NsDesign.roadsign;
    final statusColor = switch (view.tone) {
      StatusTone.normal => p.text,
      StatusTone.attention => p.attention,
      StatusTone.paused => p.text.withValues(alpha: .85),
    };
    final markEnabled = trip.liveDebug || trip.recording;
    final preview = trip.showPreview ? trip.preview() : null;
    final dimmed = _dim && !paused;

    final body = Column(
      crossAxisAlignment: c
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        // Top: the B voice bubble, or the small notice line.
        // Room for two caption lines: a notice is never cut mid-line.
        SizedBox(
          height: 68,
          child: _TopLine(
            bubble: theme.design == NsDesign.companion
                ? widget.voice.line
                : null,
            notice: view.notice,
            glyph: view.noticeGlyph,
          ),
        ),
        const Spacer(flex: 2),
        Align(
          alignment: c ? Alignment.centerLeft : Alignment.center,
          child: StatusIndicator(kind: view.indicator, size: c ? 150 : 220),
        ),
        SizedBox(height: c ? 28 : 36),
        AnimatedSwitcher(
          duration: NsMotion.state,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, .15),
                end: Offset.zero,
              ).animate(a),
              child: child,
            ),
          ),
          child: FitWords(
            view.status,
            key: ValueKey('status-${view.status}'),
            textAlign: c ? TextAlign.left : TextAlign.center,
            style: theme.tripStatus(statusColor),
          ),
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: NsMotion.state,
          child: Text(
            view.context ?? '',
            key: ValueKey('ctx-${view.context}'),
            textAlign: c ? TextAlign.left : TextAlign.center,
            style: theme.body(p.text2).copyWith(fontSize: 20, height: 1.3),
          ),
        ),
        if (widget.developerMode)
          // The controller's own calm line, to compare with the status.
          Text(
            trip.watchText ?? '',
            key: const Key('trip-watch'),
            style: theme.caption(p.text2),
          ),
        const Spacer(flex: 3),
        AnimatedSwitcher(
          duration: NsMotion.state,
          child: view.advice == null
              ? const SizedBox(height: 30)
              : Row(
                  key: ValueKey(view.advice),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusMark(MarkKind.advice, palette: p, size: 16),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        view.advice!,
                        style: theme
                            .heading(p.advice)
                            .copyWith(fontSize: 22, height: 1.25),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 18),
        AnimatedOpacity(
          duration: NsMotion.state,
          opacity: dimmed ? 0 : 1,
          child: IgnorePointer(
            ignoring: dimmed,
            child: AnimatedSwitcher(
              duration: NsMotion.state,
              transitionBuilder: (child, a) =>
                  FadeTransition(opacity: a, child: child),
              child: paused
                  ? Column(
                      key: const ValueKey('paused'),
                      children: [
                        NsButton.primary(
                          Copy.resume,
                          key: const Key('trip-resume'),
                          palette: p,
                          onPressed: () => unawaited(trip.resume()),
                        ),
                        const SizedBox(height: 10),
                        HoldToFinishButton(
                          key: const Key('trip-finish'),
                          palette: p,
                          onFinished: widget.onFinish,
                        ),
                      ],
                    )
                  : Row(
                      key: const ValueKey('running'),
                      children: [
                        Expanded(
                          child: NsButton.secondary(
                            Copy.pause,
                            key: const Key('trip-pause'),
                            height: 68,
                            palette: p,
                            onPressed: trip.phase == TripPhase.observing
                                ? () => unawaited(trip.pause())
                                : null,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: HoldToFinishButton(
                            key: const Key('trip-finish'),
                            palette: p,
                            onFinished: widget.onFinish,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ],
    );

    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark),
      child: Listener(
        // Any touch brightens the screen; it is not a button press.
        onPointerDown: (_) => _wake(),
        behavior: HitTestBehavior.translucent,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Developer live debug: a double tap anywhere marks the moment
          // for the review (docs/trip-debug.md).
          onDoubleTap: trip.active && markEnabled ? trip.mark : null,
          child: ColoredBox(
            color: p.bgTrip,
            child: SafeArea(
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 800),
                      opacity: dimmed ? NsMotion.dimOpacity : 1,
                      child: body,
                    ),
                  ),
                  if (preview != null)
                    Positioned(
                      top: 8,
                      right: 16,
                      child: AnimatedOpacity(
                        duration: NsMotion.state,
                        opacity: dimmed ? .35 : .9,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: SizedBox(
                            width: 72,
                            height: 96,
                            child: FittedBox(
                              fit: BoxFit.cover,
                              clipBehavior: Clip.hardEdge,
                              child: SizedBox(
                                width: 1080,
                                height: 1440,
                                child: preview,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.developerMode)
                    Positioned(
                      left: 16,
                      right: preview == null ? 16 : 100,
                      top: 60,
                      child: TripDevPanel(trip: trip),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The line on top of the trip screen: the voice bubble in B, otherwise a
/// small notice with its icon (moved phone, heat, watch, journal).
class _TopLine extends StatelessWidget {
  const _TopLine({this.bubble, this.notice, this.glyph});
  final String? bubble, notice;
  final NsGlyph? glyph;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.trip;
    final text = bubble ?? notice;
    return AnimatedSwitcher(
      duration: NsMotion.state,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -.3),
            end: Offset.zero,
          ).animate(a),
          child: child,
        ),
      ),
      child: text == null
          ? const SizedBox.shrink()
          : Align(
              key: ValueKey(text),
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(top: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: bubble != null ? p.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (bubble != null)
                      StatusMark(MarkKind.ok, palette: p, size: 10)
                    else if (glyph != null)
                      NsIcon(glyph!, color: p.text2),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        text,
                        style: theme.caption(bubble != null ? p.text : p.text2),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

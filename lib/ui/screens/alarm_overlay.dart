import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../logic/domain.dart';
import '../../services/trip_controller.dart';
import '../calm_alarm.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../widgets/fit_words.dart';

/// The alarm over everything (design screen 7): the whole screen in the
/// alarm red, white words «Глаза!» (96 pt) or «Поднимите голову!» (64 pt),
/// «Коснитесь экрана, чтобы выключить звук» at the bottom.
///
/// * A tap anywhere acknowledges the alarm (`TripController.acknowledge`),
///   which switches the sound and the watch off.
/// * It fades in (0.25 s), stays at least 2 s ([CalmAlarm]) and fades out
///   in [NsMotion.alarmFadeOut] when the driver has recovered.
/// * After 5 s without a reaction the brightness pulses at 1 Hz (×1.18),
///   in step with the louder sound of the escalation.
///
/// The picture never delays the sound or the automata: they run in the
/// trip controller whatever this widget does.
class AlarmOverlay extends StatelessWidget {
  const AlarmOverlay({super.key, required this.trip});
  final TripController trip;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: trip,
    builder: (context, _) => CalmAlarm(
      events: trip.snapshot?.activeEvents ?? const [],
      fadeOut: NsMotion.alarmFadeOut,
      transitionBuilder: (child, a) => FadeTransition(opacity: a, child: child),
      builder: (context, events) => AlarmView(
        key: const Key('global-alarm'),
        events: events,
        acknowledged: !(trip.snapshot?.hasUnacknowledgedAlert ?? false),
        escalated: trip.alarmEscalated,
        onAcknowledge: () => trip.acknowledge(events.map((e) => e.id).toSet()),
      ),
    ),
  );
}

/// The picture of the alarm, separate from the controller for tests and
/// screenshots.
class AlarmView extends StatefulWidget {
  const AlarmView({
    super.key,
    required this.events,
    required this.onAcknowledge,
    this.acknowledged = false,
    this.escalated = false,
  });
  final List<ObservationEvent> events;
  final VoidCallback onAcknowledge;
  final bool acknowledged, escalated;

  /// No reaction this long: the picture starts to pulse.
  static const pulseAfter = Duration(seconds: 5);

  @override
  State<AlarmView> createState() => _AlarmViewState();
}

class _AlarmViewState extends State<AlarmView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: NsMotion.alarmPulse,
  );
  Timer? _late;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _late = Timer(AlarmView.pulseAfter, _startPulse);
  }

  @override
  void didUpdateWidget(AlarmView old) {
    super.didUpdateWidget(old);
    if (widget.escalated && !old.escalated) _startPulse();
    if (widget.acknowledged) {
      _late?.cancel();
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  void _startPulse() {
    if (!mounted || widget.acknowledged) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _late?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final eyes = widget.events.any((e) => e.type == EventType.eyesClosed);
    final word = eyes ? Copy.alarmEyes : Copy.alarmHead;
    final style = theme.alarm();
    return Semantics(
      liveRegion: true,
      label: word,
      hint: widget.acknowledged ? null : Copy.alarmHint,
      button: !widget.acknowledged,
      onTap: widget.acknowledged ? null : widget.onAcknowledge,
      excludeSemantics: true,
      // Lies over the app outside any page: its own Material gives the
      // text its style.
      child: Material(
        type: MaterialType.transparency,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.acknowledged ? null : widget.onAcknowledge,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              // Brightness ×1 … ×1.18, eased like a breath at 1 Hz.
              final k =
                  1 +
                  (NsMotion.alarmPulseBrightness - 1) *
                      Curves.easeInOut.transform(_pulse.value);
              return ColoredBox(
                color: _brighter(NsColors.alarm, k),
                child: child,
              );
            },
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 40, 28, 34),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Spacer(flex: 2),
                    // «Глаза!» at 96 pt, the longer words at 64 pt, one word
                    // per line; a narrow screen shrinks them, never breaks.
                    FitWords(
                      eyes ? word : word.replaceAll(' ', '\n'),
                      style: eyes
                          ? style
                          : style.copyWith(fontSize: 64, height: 1.0),
                    ),
                    const Spacer(flex: 3),
                    AnimatedOpacity(
                      duration: NsMotion.quick,
                      opacity: widget.acknowledged ? 0 : 1,
                      child: Text(
                        Copy.alarmHint,
                        style: theme
                            .heading(NsColors.onAlarm)
                            .copyWith(fontSize: 22, height: 1.25),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Color _brighter(Color c, double k) => Color.from(
    alpha: 1,
    red: (c.r * k).clamp(0, 1),
    green: (c.g * k).clamp(0, 1),
    blue: (c.b * k).clamp(0, 1),
  );
}

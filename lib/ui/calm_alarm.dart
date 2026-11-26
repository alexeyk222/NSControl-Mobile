import 'dart:async';

import 'package:flutter/material.dart';

import '../logic/domain.dart';

/// Shows an alarm without jerks (user, 25.11: «резко появляется и резко
/// пропадает»): it fades and grows in, stays at least [minShow] even when
/// the event ends sooner, stays [linger] after the end, then fades out. The
/// sound and the automata are not delayed: this is only the picture.
class CalmAlarm extends StatefulWidget {
  const CalmAlarm({
    super.key,
    required this.events,
    required this.builder,
    this.minShow = const Duration(seconds: 2),
    this.linger = const Duration(milliseconds: 800),
    this.transitionBuilder,
    this.fadeIn = const Duration(milliseconds: 250),
    this.fadeOut = const Duration(milliseconds: 600),
  });

  /// The active events now; empty when there is no alarm.
  final List<ObservationEvent> events;

  /// The alarm for the events on screen (the last ones while it fades).
  final Widget Function(BuildContext context, List<ObservationEvent> events)
  builder;
  final Duration minShow, linger;

  /// How the alarm enters and leaves; fade and grow from the top (a
  /// banner) by default. The full-screen alarm passes a plain fade.
  final AnimatedSwitcherTransitionBuilder? transitionBuilder;
  final Duration fadeIn, fadeOut;

  @override
  State<CalmAlarm> createState() => _CalmAlarmState();
}

class _CalmAlarmState extends State<CalmAlarm> {
  List<ObservationEvent> _shown = const [];
  DateTime? _since;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(CalmAlarm old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.events.isNotEmpty) {
      _hide?.cancel();
      _hide = null;
      if (_shown.isEmpty) _since = DateTime.now();
      _shown = widget.events;
      return;
    }
    if (_shown.isEmpty || _hide != null) return;
    final shownFor = DateTime.now().difference(_since ?? DateTime.now());
    var wait = widget.minShow - shownFor;
    if (wait < widget.linger) wait = widget.linger;
    _hide = Timer(wait, () {
      if (!mounted) return;
      setState(() {
        _shown = const [];
        _hide = null;
      });
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: widget.fadeIn,
    reverseDuration: widget.fadeOut,
    switchInCurve: Curves.easeOut,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: widget.transitionBuilder ?? _grow,
    child: _shown.isEmpty
        ? const SizedBox(key: ValueKey('no-alarm'), width: double.infinity)
        : KeyedSubtree(
            key: const ValueKey('alarm'),
            child: widget.builder(context, _shown),
          ),
  );

  static Widget _grow(Widget child, Animation<double> animation) =>
      FadeTransition(
        opacity: animation,
        child: SizeTransition(
          sizeFactor: animation,
          alignment: Alignment.topCenter,
          child: child,
        ),
      );
}

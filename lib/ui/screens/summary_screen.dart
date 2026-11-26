import 'package:flutter/material.dart';

import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../presentation/trip_story.dart';
import '../widgets/buttons.dart';
import '../widgets/fit_words.dart';
import '../widgets/marks.dart';
import 'common.dart';
import 'history_tab.dart';

/// «Поездка завершена» (design screen 8, R-01/R-02): how long, what
/// happened in marked lines, one tip, «Готово» / «Подробнее». The lines
/// count in one after another.
class SummaryScreen extends StatefulWidget {
  const SummaryScreen({
    super.key,
    required this.trip,
    required this.tripId,
    required this.onDone,
    this.fallback,
  });
  final TripController trip;
  final String tripId;
  final VoidCallback onDone;

  /// What the app itself saw of the trip, shown when the journal cannot
  /// give the story (no storage, a write that failed).
  final TripStory? fallback;

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen>
    with SingleTickerProviderStateMixin {
  late final Future<TripStory?> _story = _load();
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  Future<TripStory?> _load() async {
    final db = widget.trip.repository;
    TripStory? story;
    if (db != null) {
      try {
        await widget.trip.pendingWrites;
        story = await TripStory.load(db, widget.tripId);
      } catch (_) {
        story = null;
      }
    }
    if (mounted) _in.forward();
    return story ?? widget.fallback;
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  /// One tip, the most useful first (copy.md §3.6).
  static String? tip(TripStory s) {
    if (s.eyesAlarms > 0) return Copy.sumTipSleep;
    if (s.unseen >= const Duration(minutes: 5)) return Copy.sumUnseenTip;
    if (s.total >= const Duration(hours: 2) && s.breaks == 0) {
      return Copy.sumTipBreak;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return NsPage(
      child: FutureBuilder<TripStory?>(
        future: _story,
        builder: (context, snap) {
          final s = snap.data;
          final lines = s == null
              ? <Widget>[
                  if (snap.connectionState == ConnectionState.done)
                    const MarkedLine(
                      mark: MarkKind.attention,
                      text: Copy.sumPartial,
                    ),
                ]
              : [
                  ...storyLines(s),
                  if (s.breaks > 0)
                    MarkedLine(
                      mark: MarkKind.neutral,
                      text: Copy.sumBreaks(s.breaks),
                    ),
                  if (tip(s) case final t?)
                    MarkedLine(mark: MarkKind.advice, text: t, color: p.advice),
                ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Text(Copy.sumTitle, style: theme.caption(p.text2)),
              const SizedBox(height: 6),
              FitWords(
                s == null ? ' ' : hoursMinutes(s.total),
                key: const Key('summary-duration'),
                maxLines: 1,
                style: theme.tripStatus(p.text),
              ),
              Text(Copy.sumOnRoad, style: theme.body(p.text2)),
              const SizedBox(height: 28),
              for (final (i, line) in lines.indexed)
                AnimatedBuilder(
                  animation: _in,
                  builder: (context, child) {
                    // Each line 120 ms after the previous one.
                    final start = (i * .15).clamp(0.0, .7);
                    final t = Curves.easeOutCubic.transform(
                      ((_in.value - start) / .3).clamp(0.0, 1.0),
                    );
                    return Opacity(
                      opacity: t,
                      child: Transform.translate(
                        offset: Offset(0, 12 * (1 - t)),
                        child: child,
                      ),
                    );
                  },
                  child: line,
                ),
              const Spacer(),
              NsButton.primary(
                Copy.done,
                key: const Key('summary-done'),
                onPressed: widget.onDone,
              ),
              const SizedBox(height: 10),
              NsButton.secondary(
                Copy.more,
                onPressed: s == null
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              TripDetailPage(trip: widget.trip, story: s),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

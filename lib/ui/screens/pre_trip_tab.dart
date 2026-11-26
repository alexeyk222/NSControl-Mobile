import 'dart:async';

import 'package:flutter/material.dart';

import '../../logic/recommendation.dart';
import '../../services/sleep_controller.dart';
import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../presentation/readiness.dart';
import '../presentation/ui_prefs.dart';
import '../widgets/buttons.dart';
import '../widgets/marks.dart';
import 'common.dart';

/// «Перед поездкой» (design screen 4, states P-01…P-07): the verdict and
/// its reasons, «Как вы себя чувствуете?», the readiness rows in the form
/// of the look (A a list, B cards with a note, C three tiles), «Поехали».
class PreTripTab extends StatefulWidget {
  const PreTripTab({
    super.key,
    required this.trip,
    required this.sleep,
    required this.prefs,
    required this.onStart,
  });
  final TripController trip;
  final SleepController sleep;
  final UiPrefs prefs;
  final VoidCallback onStart;

  @override
  State<PreTripTab> createState() => _PreTripTabState();
}

class _PreTripTabState extends State<PreTripTab> {
  /// The driver answered «Как вы себя чувствуете?» on this screen; «Не
  /// знаю» is shown as chosen only after a tap.
  bool _feelChosen = false;

  void _act(ReadyAction a) {
    switch (a) {
      case ReadyAction.testWatch:
        unawaited(widget.trip.testWatch());
        _toast(Copy.testSent);
      case ReadyAction.allowSleep:
        unawaited(widget.sleep.authorize());
      case ReadyAction.refreshSleep:
        unawaited(widget.sleep.refresh());
      case ReadyAction.openSettings:
        unawaited(widget.trip.openSettings());
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _testAll() async {
    await widget.trip.testAlert();
    unawaited(widget.trip.testWatch());
    _toast(Copy.testSent);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.trip, widget.sleep, widget.prefs]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    final r = Readiness.from(
      ReadinessFacts.of(
        trip: widget.trip,
        sleep: widget.sleep,
        cameraReady: widget.prefs.cameraReady,
      ),
    );
    final verdictColor = switch (r.kind) {
      VerdictKind.rest => p.advice,
      _ => p.text,
    };
    final feel = widget.sleep.assessment;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
            children: [
              AnimatedSwitcher(
                duration: NsMotion.state,
                transitionBuilder: fadeThrough,
                child: Column(
                  key: ValueKey(r.verdict),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        r.verdict,
                        key: const Key('verdict'),
                        style: theme.verdict(verdictColor),
                      ),
                    ),
                    if (r.sub != null) ...[
                      const SizedBox(height: 8),
                      Text(r.sub!, style: theme.body(p.text2)),
                    ],
                    if (r.reasons.isNotEmpty) const SizedBox(height: 10),
                    for (final reason in r.reasons)
                      MarkedLine(
                        mark: MarkKind.advice,
                        text: reason,
                        style: theme.caption(p.text),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(Copy.feelTitle, style: theme.caption(p.text2)),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (label, value) in const [
                      (Copy.feelFine, SelfAssessment.notSleepy),
                      (Copy.feelSleepy, SelfAssessment.sleepy),
                      (Copy.feelUnknown, SelfAssessment.unknown),
                    ]) ...[
                      NsChip(
                        label: label,
                        selected:
                            feel == value &&
                            (value != SelfAssessment.unknown || _feelChosen),
                        onTap: () {
                          setState(() => _feelChosen = true);
                          widget.sleep.setAssessment(value);
                        },
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              _ReadyRows(readiness: r, onAction: _act),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            children: [
              NsButton.primary(
                Copy.go,
                key: const Key('start-trip'),
                onPressed: r.camera.action == ReadyAction.openSettings
                    ? null
                    : widget.onStart,
              ),
              if (!widget.prefs.cameraReady) ...[
                const SizedBox(height: 8),
                Text(Copy.goFirstNote, style: theme.caption(p.text2)),
              ],
              const SizedBox(height: 4),
              NsButton.text(Copy.testAll, onPressed: _testAll),
            ],
          ),
        ),
      ],
    );
  }
}

/// The three readiness rows in the form of the look.
class _ReadyRows extends StatelessWidget {
  const _ReadyRows({required this.readiness, required this.onAction});
  final Readiness readiness;
  final ValueChanged<ReadyAction> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    return switch (theme.design) {
      NsDesign.cockpit => Column(
        children: [for (final row in readiness.rows) _listRow(context, row)],
      ),
      NsDesign.companion => Column(
        children: [
          for (final row in readiness.rows) ...[
            _card(context, row),
            const SizedBox(height: 8),
          ],
        ],
      ),
      NsDesign.roadsign => IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, row) in readiness.rows.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _tile(context, row)),
            ],
          ],
        ),
      ),
    };
  }

  Widget _action(BuildContext context, ReadyRow row) {
    final theme = NsTheme.of(context);
    final label = row.actionLabel;
    if (label == null) return const SizedBox.shrink();
    return Semantics(
      button: true,
      child: InkWell(
        onTap: () => onAction(row.action!),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: theme
                  .buttonSmall(theme.palette.accent)
                  .copyWith(fontSize: 16),
            ),
          ),
        ),
      ),
    );
  }

  // A · a plain list.
  Widget _listRow(BuildContext context, ReadyRow row) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      child: Row(
        children: [
          StatusMark(row.mark),
          const SizedBox(width: 14),
          Expanded(child: Text(row.title, style: theme.body())),
          _action(context, row),
        ],
      ),
    );
  }

  // B · cards with a note.
  Widget _card(BuildContext context, ReadyRow row) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(theme.radii.card),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: p.surface2,
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: StatusMark(row.mark),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title,
                  style: theme.body().copyWith(fontWeight: FontWeight.w700),
                ),
                if (row.note != null)
                  Text(row.note!, style: theme.caption(p.text2)),
              ],
            ),
          ),
          _action(context, row),
        ],
      ),
    );
  }

  // C · three tiles.
  Widget _tile(BuildContext context, ReadyRow row) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(theme.radii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusMark(row.mark, size: 16),
          const SizedBox(height: 10),
          Text(
            row.title,
            style: theme.caption(p.text).copyWith(fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          if (row.actionLabel != null)
            Transform.translate(
              offset: const Offset(-6, 0),
              child: _action(context, row),
            ),
        ],
      ),
    );
  }
}

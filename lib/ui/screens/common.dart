import 'package:flutter/material.dart';

import '../../logic/settings.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/marks.dart';

/// Page frame of the design: 24 pt side margins, safe areas, the page
/// colour of the current palette (or the trip palette with [trip]).
class NsPage extends StatelessWidget {
  const NsPage({
    super.key,
    required this.child,
    this.trip = false,
    this.padding = const EdgeInsets.fromLTRB(24, 12, 24, 24),
  });
  final Widget child;
  final bool trip;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    return ColoredBox(
      color: trip ? theme.trip.bgTrip : theme.palette.bg,
      child: SafeArea(
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A caption above a group («Оформление», «Крепление»…).
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Semantics(
        header: true,
        child: Text(text, style: theme.caption(theme.palette.text2)),
      ),
    );
  }
}

/// A rounded group of rows with thin separators (settings, history).
class RowGroup extends StatelessWidget {
  const RowGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(theme.radii.card),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 16, color: p.line),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// One settings row: a label, an optional value on the right, a switch or
/// a tap action. 56 pt high at least.
class NsRow extends StatelessWidget {
  const NsRow({
    super.key,
    required this.label,
    this.value,
    this.onTap,
    this.toggle,
    this.onToggle,
    this.accent = false,
    this.enabled = true,
  });
  final String label;
  final String? value;
  final VoidCallback? onTap;

  /// A switch on the right when not null.
  final bool? toggle;
  final ValueChanged<bool>? onToggle;

  /// Label in the accent colour (an action like «Перенастроить камеру»).
  final bool accent;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.body(
                  !enabled ? p.text2 : (accent ? p.accent : p.text),
                ),
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  value!,
                  textAlign: TextAlign.right,
                  style: theme.caption(p.text2),
                ),
              ),
            ],
            if (toggle != null)
              Switch(value: toggle!, onChanged: enabled ? onToggle : null),
          ],
        ),
      ),
    );
    if (toggle != null) {
      return MergeSemantics(child: row);
    }
    return Semantics(
      button: onTap != null,
      child: InkWell(onTap: enabled ? onTap : null, child: row),
    );
  }
}

/// A line with a shape mark in front (reasons, summary lines).
class MarkedLine extends StatelessWidget {
  const MarkedLine({
    super.key,
    required this.mark,
    required this.text,
    this.color,
    this.palette,
    this.style,
  });
  final MarkKind mark;
  final String text;
  final Color? color;
  final NsPalette? palette;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = palette ?? theme.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 12),
            child: StatusMark(mark, palette: p),
          ),
          Expanded(
            child: Text(text, style: style ?? theme.body(color ?? p.text)),
          ),
        ],
      ),
    );
  }
}

/// A confirmation sheet for destructive steps (delete a trip, delete all).
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final theme = NsTheme.of(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: theme.palette.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(theme.radii.card),
      ),
    ),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.heading()),
            const SizedBox(height: 10),
            Text(body, style: theme.body(theme.palette.text2)),
            const SizedBox(height: 24),
            NsButton.secondary(
              action,
              onPressed: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 8),
            NsButton.text(
              'Отмена',
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    ),
  );
  return ok ?? false;
}

/// [AlgorithmSettings] has no copyWith: change the user-facing options
/// through its JSON, keeping the thresholds as they are.
AlgorithmSettings settingsWith(
  AlgorithmSettings s, {
  double? volume,
  bool? vibration,
  bool? showPreview,
  bool? hiddenEyes,
  bool? escalate,
}) => AlgorithmSettings.fromJson({
  ...s.toJson(),
  'volume': ?volume,
  'vibration': ?vibration,
  'showPreview': ?showPreview,
  'hiddenEyes': ?hiddenEyes,
  'escalate': ?escalate,
});

/// Fade-through between pages (the shell's stages, home tabs).
Widget fadeThrough(Widget child, Animation<double> a) => FadeTransition(
  opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
  child: ScaleTransition(
    scale: Tween(
      begin: .98,
      end: 1.0,
    ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
    child: child,
  ),
);

/// Duration of stage changes.
const pageMotion = NsMotion.page;

/// A column that fills the screen and scrolls only when it does not fit
/// (small phones, large text): [Spacer]s inside keep working.
class FillScroll extends StatelessWidget {
  const FillScroll({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: box.maxHeight),
        child: IntrinsicHeight(child: child),
      ),
    ),
  );
}

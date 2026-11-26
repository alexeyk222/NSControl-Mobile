import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';

/// Button kinds of the design: the large accent button (76 pt, «Поехали»,
/// «Продолжить»), the secondary button on surface 2 (64–68 pt) and a plain
/// text action.
enum NsButtonKind { primary, secondary, text }

/// A button of the current look. Shrinks slightly while pressed so a press
/// is felt even with gloves or a glance, and gives a light haptic tick.
class NsButton extends StatelessWidget {
  const NsButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.kind = NsButtonKind.primary,
    this.height,
    this.palette,
    this.icon,
  });

  /// Large accent button.
  const NsButton.primary(
    this.label, {
    super.key,
    required this.onPressed,
    this.height = 76,
    this.palette,
    this.icon,
  }) : kind = NsButtonKind.primary;

  /// Button on surface 2.
  const NsButton.secondary(
    this.label, {
    super.key,
    required this.onPressed,
    this.height = 64,
    this.palette,
    this.icon,
  }) : kind = NsButtonKind.secondary;

  /// Text action without a fill.
  const NsButton.text(
    this.label, {
    super.key,
    required this.onPressed,
    this.height = 48,
    this.palette,
    this.icon,
  }) : kind = NsButtonKind.text;

  final String label;
  final VoidCallback? onPressed;
  final NsButtonKind kind;
  final double? height;

  /// Colours; the palette of the current brightness by default (the trip
  /// screens pass the dark trip palette).
  final NsPalette? palette;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = palette ?? theme.palette;
    final enabled = onPressed != null;
    final (bg, fg, radius, style) = switch (kind) {
      NsButtonKind.primary => (
        p.accent,
        p.onAccent,
        theme.radii.button,
        theme.button(p.onAccent),
      ),
      NsButtonKind.secondary => (
        p.surface2,
        p.text,
        theme.radii.secondaryButton,
        theme.buttonSmall(p.text),
      ),
      NsButtonKind.text => (
        Colors.transparent,
        p.text,
        theme.radii.secondaryButton,
        theme.buttonSmall(p.text),
      ),
    };
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onPressed,
        child: AnimatedOpacity(
          duration: NsMotion.quick,
          opacity: enabled ? 1 : .4,
          child: Container(
            height: height,
            width: double.infinity,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(color: fg, size: 22),
                    child: icon!,
                  ),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: style.copyWith(color: fg),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Scales its child to 97 % while pressed; the shared press feedback of
/// buttons, options and tiles.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = .97,
  });
  final Widget child;
  final VoidCallback? onTap;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              widget.onTap!();
            }
          : null,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// «Завершить» on the trip screen: fires only after holding for
/// [NsMotion.holdToFinish] (1.2 s), so a stray touch while driving cannot
/// end the trip. The fill grows while held and runs back when released
/// early; the label turns into «Удерживайте…». Screen readers get a long
/// press action instead.
class HoldToFinishButton extends StatefulWidget {
  const HoldToFinishButton({
    super.key,
    required this.onFinished,
    this.label = Copy.finish,
    this.height = 68,
    this.palette,
  });
  final VoidCallback onFinished;
  final String label;
  final double height;
  final NsPalette? palette;

  @override
  State<HoldToFinishButton> createState() => _HoldToFinishButtonState();
}

class _HoldToFinishButtonState extends State<HoldToFinishButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: NsMotion.holdToFinish,
    reverseDuration: const Duration(milliseconds: 300),
  )..addStatusListener(_done);
  bool _fired = false;

  void _done(AnimationStatus s) {
    if (s == AnimationStatus.completed && !_fired) {
      _fired = true;
      HapticFeedback.heavyImpact();
      widget.onFinished();
    }
  }

  void _start() {
    _fired = false;
    HapticFeedback.lightImpact();
    _hold.forward();
  }

  void _cancel() {
    if (!_fired) _hold.reverse();
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = widget.palette ?? theme.trip;
    final radius = BorderRadius.circular(theme.radii.secondaryButton);
    return Semantics(
      button: true,
      label: widget.label,
      hint: Copy.finishHint,
      onLongPress: widget.onFinished,
      excludeSemantics: true,
      // Raw pointer events: a gesture recognizer would cancel the hold
      // when its own long-press deadline passes.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _start(),
        onPointerUp: (_) => _cancel(),
        onPointerCancel: (_) => _cancel(),
        child: AnimatedBuilder(
          animation: _hold,
          builder: (context, _) {
            final held = _hold.value > 0;
            return ClipRRect(
              borderRadius: radius,
              child: Container(
                height: widget.height,
                color: p.surface2,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _hold.value,
                      child: ColoredBox(color: p.text.withValues(alpha: .22)),
                    ),
                    Center(
                      child: AnimatedSwitcher(
                        duration: NsMotion.quick,
                        child: Text(
                          held ? Copy.finishHold : widget.label,
                          key: ValueKey(held),
                          style: theme.buttonSmall(p.text),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A selectable option row (mount side, route, look): radio circle, label,
/// optional trailing note. 64 pt high, the look's option radius.
class NsOption extends StatelessWidget {
  const NsOption({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
    this.height = 64,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final String? trailing;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: NsMotion.quick,
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(theme.radii.option),
            border: Border.all(
              color: selected ? p.accent : p.line,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              _Radio(selected: selected, color: p.accent, off: p.text2),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: theme.body(p.text),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null)
                Text(trailing!, style: theme.caption(p.text2)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  const _Radio({
    required this.selected,
    required this.color,
    required this.off,
  });
  final bool selected;
  final Color color, off;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: NsMotion.quick,
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: selected ? color : off, width: 2),
    ),
    alignment: Alignment.center,
    child: AnimatedScale(
      duration: NsMotion.quick,
      curve: Curves.easeOutBack,
      scale: selected ? 1 : 0,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    ),
  );
}

/// A two-way segmented switch («Только телефон | Телефон и машина»).
class NsSegmented<T> extends StatelessWidget {
  const NsSegmented({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    final index = values.indexOf(selected);
    final r = theme.radii.option;
    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(r),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / values.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: NsMotion.state,
                curve: Curves.easeOutCubic,
                left: w * index,
                top: 0,
                bottom: 0,
                width: w,
                child: Container(
                  decoration: BoxDecoration(
                    color: p.surface2,
                    borderRadius: BorderRadius.circular(r - 4),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < values.length; i++)
                    Expanded(
                      child: Semantics(
                        selected: i == index,
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onChanged(values[i]),
                          child: Center(
                            child: Text(
                              labels[i],
                              style: theme.caption(
                                i == index ? p.text : p.text2,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A rounded chip sized to its text («Бодро», «Хочется спать», «Не знаю»):
/// outlined, filled with the accent when chosen, never wraps (README §4).
class NsChip extends StatelessWidget {
  const NsChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: AnimatedContainer(
          duration: NsMotion.quick,
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: selected ? p.accent : p.line, width: 2),
          ),
          child: Text(
            label,
            softWrap: false,
            style: theme.buttonSmall(selected ? p.onAccent : p.text),
          ),
        ),
      ),
    );
  }
}

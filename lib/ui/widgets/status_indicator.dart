import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

import '../design/ns_theme.dart';
import '../design/tokens.dart';

/// What the indicator shows. The form is the main sign, the colour only
/// confirms it (design README «Индикатор состояния»), so the states stay
/// distinct for drivers who do not tell the colours apart.
enum IndicatorKind {
  /// «Слежу»: A whole ring, B a face with eyes, C a filled circle.
  watching,

  /// «Слежу за головой»: A upper arc, B a bar like glasses, C a half circle.
  headOnly,

  /// «Не вижу вас»: A dashed ring, B empty dashed circle, C a diamond.
  unseen,

  /// «Пауза»: thin ring/square with two bars.
  paused,

  /// No trip (history placeholder, watch «Готов»).
  idle,
}

/// The trip status indicator of the current look. Breathes in the
/// «Слежу» state (6 s, A and B), cross-fades between states.
class StatusIndicator extends StatelessWidget {
  const StatusIndicator({
    super.key,
    required this.kind,
    this.size = 220,
    this.breathe = true,
    this.palette,
  });

  final IndicatorKind kind;
  final double size;

  /// Breathing is off for small copies (history, watch preview) and when
  /// the system asks to reduce motion.
  final bool breathe;

  /// Colours; the always-dark trip palette by default.
  final NsPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = palette ?? theme.trip;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    Widget shape = CustomPaint(
      key: ValueKey('${theme.design.name}-${kind.name}'),
      size: Size.square(size),
      painter: IndicatorPainter(design: theme.design, kind: kind, palette: p),
    );
    if (kind == IndicatorKind.watching &&
        breathe &&
        !reduce &&
        theme.look.breathes) {
      shape = _Breathing(look: theme.look, child: shape);
    }
    return Semantics(
      label: switch (kind) {
        IndicatorKind.watching => 'Слежу',
        IndicatorKind.headOnly => 'Слежу за головой',
        IndicatorKind.unseen => 'Не вижу вас',
        IndicatorKind.paused => 'Пауза',
        IndicatorKind.idle => 'Ожидание',
      },
      child: SizedBox.square(
        dimension: size,
        child: AnimatedSwitcher(
          duration: reduce ? Duration.zero : NsMotion.state,
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(
              scale: Tween(begin: .86, end: 1.0).animate(a),
              child: child,
            ),
          ),
          child: KeyedSubtree(key: ValueKey(kind), child: shape),
        ),
      ),
    );
  }
}

/// Slow breathing: opacity and scale go up to 1 and back once per 6 s.
class _Breathing extends StatefulWidget {
  const _Breathing({required this.look, required this.child});
  final NsLook look;
  final Widget child;

  @override
  State<_Breathing> createState() => _BreathingState();
}

class _BreathingState extends State<_Breathing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: NsMotion.breathe ~/ 2,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // «Reduce motion» in the system settings: a still indicator.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return widget.child;
    }
    final t = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
    return AnimatedBuilder(
      animation: t,
      builder: (context, child) {
        final o = widget.look.breatheOpacity;
        final s = widget.look.breatheScale;
        return Opacity(
          opacity: o + (1 - o) * t.value,
          child: Transform.scale(scale: s + (1 - s) * t.value, child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// Geometry of the indicator, ported from the prototype SVGs
/// (`ring(kind, size)` in each `NSControl * .dc.html`).
class IndicatorPainter extends CustomPainter {
  IndicatorPainter({
    required this.design,
    required this.kind,
    required this.palette,
  });

  final NsDesign design;
  final IndicatorKind kind;
  final NsPalette palette;

  static const _yellow = NsColors.attentionOnDark;

  @override
  void paint(Canvas canvas, Size size) {
    switch (design) {
      case NsDesign.cockpit:
        _cockpit(canvas, size.width);
      case NsDesign.companion:
        _companion(canvas, size.width);
      case NsDesign.roadsign:
        _roadsign(canvas, size.width);
    }
  }

  Paint _stroke(Color c, double w, {double opacity = 1}) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..color = c.withValues(alpha: c.a * opacity);

  Paint _fill(Color c, {double opacity = 1}) =>
      Paint()..color = c.withValues(alpha: c.a * opacity);

  /// Dashed circle: [count] dashes, each [on] of its segment.
  void _dashedCircle(
    Canvas canvas,
    Offset c,
    double r,
    Paint paint,
    int count,
    double on,
  ) {
    final seg = 2 * math.pi / count;
    for (var i = 0; i < count; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        -math.pi / 2 + i * seg,
        seg * on,
        false,
        paint,
      );
    }
  }

  void _pauseBars(
    Canvas canvas,
    double size,
    Color col, {
    required double widthK,
    required double heightK,
    required double radiusK,
  }) {
    final c = size / 2, bw = size * widthK, bh = size * heightK;
    final r = Radius.circular(bw * radiusK);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(c - bw * 1.6, c - bh / 2, bw, bh),
        r,
      ),
      _fill(col),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(c + bw * .6, c - bh / 2, bw, bh),
        r,
      ),
      _fill(col),
    );
  }

  // A · Ночной кокпит: rings.
  void _cockpit(Canvas canvas, double size) {
    final sw = size > 150 ? 6.0 : (size > 60 ? 4.0 : 3.0);
    final c = Offset(size / 2, size / 2), r = size / 2 - sw * 2;
    final a = palette.accent;
    switch (kind) {
      case IndicatorKind.watching:
        canvas.drawCircle(c, r, _stroke(a, sw * 3, opacity: .16));
        canvas.drawCircle(c, r, _stroke(a, sw));
      case IndicatorKind.headOnly:
        final rect = Rect.fromCircle(center: c, radius: r);
        canvas.drawArc(rect, math.pi, math.pi, false, _stroke(_yellow, sw));
        // Lower half: dots.
        final dot = _stroke(_yellow, math.max(2, sw / 2), opacity: .45);
        final step = (sw * 2.4 + 1) / r;
        for (var t = 0.0; t <= math.pi; t += step) {
          final p = c + Offset(math.cos(t) * r, math.sin(t) * r);
          canvas.drawPoints(PointMode.points, [
            p,
          ], dot..strokeCap = StrokeCap.round);
        }
      case IndicatorKind.unseen:
        _dashedCircle(canvas, c, r, _stroke(_yellow, sw), 20, .42);
      case IndicatorKind.paused || IndicatorKind.idle:
        final col = kind == IndicatorKind.idle
            ? palette.indicatorIdle
            : palette.indicatorPause;
        canvas.drawCircle(c, r, _stroke(col, math.max(1.5, sw / 2)));
        if (kind == IndicatorKind.paused) {
          _pauseBars(
            canvas,
            size,
            col,
            widthK: .07,
            heightK: .26,
            radiusK: 1 / 3,
          );
        }
    }
  }

  // B · Спокойный компаньон: a soft face.
  void _companion(Canvas canvas, double size) {
    final c = Offset(size / 2, size / 2), r = size / 2 * .86;
    final sw = math.max(2.0, size / 55);
    final a = palette.accent;
    void eyes(Color col) {
      for (final dx in [-r * .34, r * .34]) {
        canvas.drawOval(
          Rect.fromCenter(
            center: c + Offset(dx, -r * .06),
            width: r * .17,
            height: r * .24,
          ),
          _fill(col),
        );
      }
    }

    switch (kind) {
      case IndicatorKind.watching:
        canvas.drawCircle(c, r, _fill(a, opacity: .14));
        canvas.drawCircle(c, r, _stroke(a, sw, opacity: .55));
        eyes(a);
      case IndicatorKind.headOnly:
        canvas.drawCircle(c, r, _fill(_yellow, opacity: .1));
        canvas.drawCircle(c, r, _stroke(_yellow, sw, opacity: .6));
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(c.dx - r * .6, c.dy - r * .22, r * 1.2, r * .3),
            Radius.circular(r * .15),
          ),
          _fill(_yellow),
        );
      case IndicatorKind.unseen:
        final circumference = 2 * math.pi * r;
        final count = (circumference / (r * .33)).round();
        _dashedCircle(
          canvas,
          c,
          r,
          _stroke(_yellow, sw * 1.5),
          count,
          .16 / .33,
        );
      case IndicatorKind.paused || IndicatorKind.idle:
        final col = kind == IndicatorKind.idle
            ? palette.indicatorIdle
            : palette.indicatorPause;
        canvas.drawCircle(c, r, _fill(col, opacity: .08));
        canvas.drawCircle(c, r, _stroke(col, sw));
        if (kind == IndicatorKind.paused) {
          _pauseBars(canvas, size, col, widthK: .07, heightK: .24, radiusK: .5);
        } else {
          eyes(col);
        }
    }
  }

  // C · Дорожный знак: simple still figures.
  void _roadsign(Canvas canvas, double size) {
    final c = Offset(size / 2, size / 2), r = size / 2 * .82;
    final sw = math.max(3.0, size / 20);
    switch (kind) {
      case IndicatorKind.watching:
        canvas.drawCircle(c, r, _fill(palette.accent));
      case IndicatorKind.headOnly:
        canvas.drawCircle(
          c,
          r - sw / 2,
          _stroke(_yellow, sw)..strokeCap = StrokeCap.butt,
        );
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: r),
          math.pi,
          math.pi,
          true,
          _fill(_yellow),
        );
      case IndicatorKind.unseen:
        canvas.save();
        canvas.translate(c.dx, c.dy);
        canvas.rotate(math.pi / 4);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: r * 1.4,
              height: r * 1.4,
            ),
            Radius.circular(r * .06),
          ),
          _stroke(_yellow, sw)..strokeJoin = StrokeJoin.round,
        );
        canvas.restore();
      case IndicatorKind.paused || IndicatorKind.idle:
        final col = kind == IndicatorKind.idle
            ? palette.indicatorIdle
            : palette.indicatorPause;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: r * 1.6, height: r * 1.6),
            Radius.circular(r * .1),
          ),
          _stroke(col, sw),
        );
        if (kind == IndicatorKind.paused) {
          final bw = r * .2, bh = r * .8;
          canvas.drawRect(
            Rect.fromLTWH(c.dx - bw * 1.5, c.dy - bh / 2, bw, bh),
            _fill(col),
          );
          canvas.drawRect(
            Rect.fromLTWH(c.dx + bw * .5, c.dy - bh / 2, bw, bh),
            _fill(col),
          );
        }
    }
  }

  @override
  bool shouldRepaint(IndicatorPainter old) =>
      old.design != design || old.kind != kind || old.palette != palette;
}

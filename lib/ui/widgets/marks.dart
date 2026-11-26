import 'package:flutter/material.dart';

import '../design/ns_theme.dart';
import '../design/tokens.dart';

/// Shape marks in front of readiness rows, reasons and summary lines
/// (design: the shape tells the meaning, the colour only confirms it).
enum MarkKind {
  /// Ready: a filled dot in the accent.
  ok,

  /// Not set up yet: an empty ring.
  todo,

  /// Attention (protection weakened): a yellow diamond outline.
  attention,

  /// Advice (amber): a filled diamond.
  advice,

  /// An alarm in the summary: a short vertical bar in the text colour,
  /// never red outside the alarm screen.
  alarm,

  /// Neutral fact: a short dash.
  neutral,
}

class StatusMark extends StatelessWidget {
  const StatusMark(this.kind, {super.key, this.palette, this.size = 14});
  final MarkKind kind;
  final NsPalette? palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = palette ?? NsTheme.of(context).palette;
    return CustomPaint(size: Size.square(size), painter: _MarkPainter(kind, p));
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.kind, this.p);
  final MarkKind kind;
  final NsPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final s = size.width;
    switch (kind) {
      case MarkKind.ok:
        canvas.drawCircle(c, s * .36, Paint()..color = p.accent);
      case MarkKind.todo:
        canvas.drawCircle(
          c,
          s * .34,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = p.text2,
        );
      case MarkKind.attention || MarkKind.advice:
        final d = Path()
          ..moveTo(c.dx, c.dy - s * .42)
          ..lineTo(c.dx + s * .42, c.dy)
          ..lineTo(c.dx, c.dy + s * .42)
          ..lineTo(c.dx - s * .42, c.dy)
          ..close();
        canvas.drawPath(
          d,
          kind == MarkKind.advice
              ? (Paint()..color = p.advice)
              : (Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.8
                  ..strokeJoin = StrokeJoin.round
                  ..color = p.attention),
        );
      case MarkKind.alarm:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: 4, height: s * 1.1),
            const Radius.circular(1),
          ),
          Paint()..color = p.text,
        );
      case MarkKind.neutral:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: s * .7, height: 2),
            const Radius.circular(1),
          ),
          Paint()..color = p.text2,
        );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.kind != kind || old.p != p;
}

/// Line icons of the state (README «Ресурсы»): thermometer, battery and a
/// crossed-out watch, 1.8 pt strokes on a 24 grid.
enum NsGlyph { thermo, battery, watchOff }

class NsIcon extends StatelessWidget {
  const NsIcon(this.glyph, {super.key, this.size = 18, this.color});
  final NsGlyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _GlyphPainter(glyph, color ?? NsTheme.of(context).palette.text2),
  );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final NsGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    switch (glyph) {
      case NsGlyph.thermo:
        final body = Path()
          ..moveTo(10, 14.5)
          ..lineTo(10, 5)
          ..arcToPoint(const Offset(14, 5), radius: const Radius.circular(2))
          ..lineTo(14, 14.5)
          ..arcToPoint(
            const Offset(10, 14.5),
            radius: const Radius.circular(4),
            largeArc: true,
          );
        canvas.drawPath(body, p);
        canvas.drawCircle(const Offset(12, 17.5), 1.6, Paint()..color = color);
      case NsGlyph.battery:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(3, 8, 16, 9),
            const Radius.circular(2),
          ),
          p,
        );
        canvas.drawLine(const Offset(21, 11), const Offset(21, 14), p);
        canvas.drawRect(
          const Rect.fromLTWH(5.5, 10.5, 3.5, 4),
          Paint()..color = color,
        );
      case NsGlyph.watchOff:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(7, 6, 10, 12),
            const Radius.circular(3),
          ),
          p,
        );
        canvas.drawLine(const Offset(9, 6), const Offset(9.5, 3), p);
        canvas.drawLine(const Offset(15, 6), const Offset(14.5, 3), p);
        canvas.drawLine(const Offset(9, 18), const Offset(9.5, 21), p);
        canvas.drawLine(const Offset(15, 18), const Offset(14.5, 21), p);
        canvas.drawLine(const Offset(4, 4), const Offset(20, 20), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}

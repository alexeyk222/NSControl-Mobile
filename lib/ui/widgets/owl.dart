import 'dart:async';

import 'package:flutter/material.dart';

import '../design/ns_theme.dart';
import '../design/tokens.dart';

/// The app's mark «Сова» (design handoff `assets/owl-*.svg`, variant 2a):
/// brows, two eyes with pupils and a beak, drawn in one colour on a
/// 100×100 grid. Blinks once per [NsMotion.owlBlink] when [blink] is on.
class Owl extends StatefulWidget {
  const Owl({super.key, this.size = 64, this.color, this.blink = true});

  final double size;

  /// Stroke colour; the look's accent by default.
  final Color? color;
  final bool blink;

  @override
  State<Owl> createState() => _OwlState();
}

class _OwlState extends State<Owl> with SingleTickerProviderStateMixin {
  // One blink: lids close in 90 ms and open in 140 ms.
  late final AnimationController _lid = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 230),
  );
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(Owl old) {
    super.didUpdateWidget(old);
    if (old.blink != widget.blink) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!widget.blink) return;
    _timer = Timer.periodic(NsMotion.owlBlink, (_) {
      if (!mounted) return;
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
      _lid.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? NsTheme.of(context).palette.accent;
    return Semantics(
      label: 'NSControl',
      image: true,
      child: AnimatedBuilder(
        animation: _lid,
        builder: (context, _) {
          // 0 → 1 → 0 over the blink: closed at 40 % of it.
          final t = _lid.value;
          final closed = t < .4 ? t / .4 : 1 - (t - .4) / .6;
          return CustomPaint(
            size: Size.square(widget.size),
            painter: OwlPainter(
              color: color,
              lid: _lid.isAnimating ? closed : 0,
            ),
          );
        },
      ),
    );
  }
}

/// Paints the owl; [lid] 0 is open, 1 is closed (pupils squashed to 12 %).
class OwlPainter extends CustomPainter {
  const OwlPainter({required this.color, this.lid = 0});
  final Color color;
  final double lid;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    canvas.scale(k);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    // Brows.
    canvas.drawLine(const Offset(20, 28), const Offset(33, 39), stroke);
    canvas.drawLine(const Offset(80, 28), const Offset(67, 39), stroke);
    for (final x in const [35.0, 65.0]) {
      final c = Offset(x, 54);
      canvas.drawCircle(c, 15, Paint()..color = color.withValues(alpha: .14));
      canvas.drawCircle(c, 15, stroke);
      final h = 12 * (1 - .88 * lid);
      canvas.drawOval(
        Rect.fromCenter(center: c, width: 12, height: h),
        Paint()..color = color,
      );
    }
    // Beak.
    final beak = Path()
      ..moveTo(45, 72)
      ..lineTo(50, 79)
      ..lineTo(55, 72);
    canvas.drawPath(beak, stroke..strokeWidth = 4.5);
  }

  @override
  bool shouldRepaint(OwlPainter old) => old.color != color || old.lid != lid;
}

/// The owl on a rounded tile (onboarding, 112 pt in the design).
class OwlTile extends StatelessWidget {
  const OwlTile({super.key, this.size = 112});
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: theme.palette.surface2,
        borderRadius: BorderRadius.circular(size * .26),
      ),
      alignment: Alignment.center,
      child: Owl(size: size * .66),
    );
  }
}

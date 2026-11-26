import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/ns_theme.dart';
import '../design/tokens.dart';

/// Stage of the camera setup as the picture shows it (design C-01…C-09).
enum CalStage {
  /// Looking for the face: a light runs around (B), a dashed oval (A, C).
  search,

  /// Several faces: the guide turns yellow, the driver taps their face.
  many,

  /// Capturing the road pose: the ring / bars fill over the capture.
  capture,

  /// Did not work: yellow, a short shake, then «Ещё раз».
  fail,

  /// Done: the ring closes and a check is drawn in 0.5 s.
  done,
}

/// The guide over the camera preview of the setup screen, in the form of
/// the current look:
/// * A · rings: a dashed yellow oval while searching, a progress ring
///   (R 86, stroke 8, track #2A3036) while capturing, an accent ring when
///   done;
/// * B · a ring of 60 ticks: a light runs around in 1.6 s while searching,
///   ticks light up one by one while capturing, a check when done;
/// * C · a dashed oval while searching, five bars that light up one per
///   second while capturing.
///
/// [progress] is the capture progress 0…1 from the trip controller. The
/// widget fills the preview box (3:4) and scales from the 366 pt design.
class CalibrationVisual extends StatefulWidget {
  const CalibrationVisual({super.key, required this.stage, this.progress = 0});
  final CalStage stage;
  final double progress;

  @override
  State<CalibrationVisual> createState() => _CalibrationVisualState();
}

class _CalibrationVisualState extends State<CalibrationVisual>
    with TickerProviderStateMixin {
  // The running light of the search.
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: NsMotion.calSweep,
  );

  // The shake on failure: three short swings.
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  // The check stroke of «Готово».
  late final AnimationController _check = AnimationController(
    vsync: this,
    duration: NsMotion.calDone,
  );

  // Smooth capture progress: the controller reports in steps of frames.
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: widget.progress,
  );

  bool get _reduce => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncStage(null);
  }

  @override
  void didUpdateWidget(CalibrationVisual old) {
    super.didUpdateWidget(old);
    _syncStage(old.stage);
    if (old.progress != widget.progress) {
      _fill.animateTo(widget.progress.clamp(0, 1));
    }
  }

  void _syncStage(CalStage? old) {
    final s = widget.stage;
    if (s == CalStage.search || s == CalStage.many) {
      if (!_sweep.isAnimating && !_reduce) _sweep.repeat();
    } else {
      _sweep.stop();
    }
    if (s == CalStage.fail && old != CalStage.fail && !_reduce) {
      _shake.forward(from: 0);
    }
    if (s == CalStage.done && old != CalStage.done) {
      _fill.value = 1;
      _reduce ? _check.value = 1 : _check.forward(from: 0);
    } else if (s != CalStage.done) {
      _check.value = 0;
    }
    if (s == CalStage.search || s == CalStage.many) _fill.value = 0;
  }

  @override
  void dispose() {
    _sweep.dispose();
    _shake.dispose();
    _check.dispose();
    _fill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([_sweep, _shake, _check, _fill]),
      builder: (context, _) {
        // Damped sine: 3 swings of ±8 pt.
        final t = _shake.value;
        final dx = _shake.isAnimating
            ? math.sin(t * math.pi * 6) * 8 * (1 - t)
            : 0.0;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: CustomPaint(
            size: Size.infinite,
            painter: CalibrationPainter(
              design: theme.design,
              stage: widget.stage,
              progress: _fill.value,
              sweep: _sweep.value,
              check: _check.value,
              accent: theme.trip.accent,
            ),
          ),
        );
      },
    );
  }
}

/// Paints the guide; all sizes are in the 366 × 488 design box and scaled.
class CalibrationPainter extends CustomPainter {
  CalibrationPainter({
    required this.design,
    required this.stage,
    required this.progress,
    required this.sweep,
    required this.check,
    required this.accent,
  });

  final NsDesign design;
  final CalStage stage;
  final double progress, sweep, check;
  final Color accent;

  static const _yellow = NsColors.attentionOnDark;
  static const _track = Color(0xFF2A3036);

  bool get _warn => stage == CalStage.fail || stage == CalStage.many;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 366;
    canvas.save();
    canvas.scale(k);
    // The face sits a little above the middle of the 3:4 frame.
    const c = Offset(183, 220);
    switch (design) {
      case NsDesign.cockpit:
        _cockpit(canvas, c);
      case NsDesign.companion:
        _companion(canvas, c);
      case NsDesign.roadsign:
        _roadsign(canvas, c);
    }
    canvas.restore();
  }

  Paint _line(Color c, double w) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..color = c;

  /// The dashed oval around the face (A and C while searching).
  void _oval(Canvas canvas, Offset c, Color color) {
    final rect = Rect.fromCenter(center: c, width: 150, height: 200);
    final path = Path()..addOval(rect);
    final paint = _line(color, 3);
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 14) {
        canvas.drawPath(metric.extractPath(d, d + 7), paint);
      }
    }
  }

  void _checkMark(Canvas canvas, Offset c, double scale, Color color) {
    if (check <= 0) return;
    // Check path of the design: M 102 132 L 122 152 L 160 110 in a 260 box
    // centred on 130,130.
    final pts = [
      const Offset(102, 132),
      const Offset(122, 152),
      const Offset(160, 110),
    ].map((p) => c + (p - const Offset(130, 130)) * scale).toList();
    final path = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * Curves.easeOut.transform(check)),
      _line(color, 10 * scale)..strokeJoin = StrokeJoin.round,
    );
  }

  // A · Ночной кокпит.
  void _cockpit(Canvas canvas, Offset c) {
    switch (stage) {
      case CalStage.search || CalStage.many || CalStage.fail:
        _oval(
          canvas,
          c,
          _yellow.withValues(alpha: stage == CalStage.search ? .9 : 1),
        );
      case CalStage.capture:
        canvas.drawCircle(c, 86, _line(_track, 8));
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: 86),
          -math.pi / 2,
          2 * math.pi * progress,
          false,
          _line(accent, 8),
        );
      case CalStage.done:
        canvas.drawCircle(c, 86, _line(accent, 8));
        _checkMark(canvas, c, .7, accent);
    }
  }

  // B · Спокойный компаньон: 60 ticks.
  void _companion(Canvas canvas, Offset c) {
    const n = NsMotion.calTicks;
    const r2 = 124.0;
    final lit = (progress * n).floor();
    for (var i = 0; i < n; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / n;
      final dir = Offset(math.cos(a), math.sin(a));
      Color color;
      double len = 10;
      switch (stage) {
        case CalStage.search:
          // The running light: a bright head with a fading tail of 12.
          final head = (sweep * n).floor();
          final behind = (head - i) % n;
          final glow = behind < 12 ? 1 - behind / 12 : 0.0;
          color = accent.withValues(alpha: .22 + .78 * glow);
          len = 10 + 8 * glow;
        case CalStage.many || CalStage.fail:
          color = _yellow;
          len = 14;
        case CalStage.capture:
          final on = i < lit;
          color = on ? _yellow : Colors.white.withValues(alpha: .22);
          len = on ? 18 : 10;
        case CalStage.done:
          color = accent;
          len = 18;
      }
      canvas.drawLine(c + dir * (r2 - len), c + dir * r2, _line(color, 4));
    }
    if (stage == CalStage.done) {
      canvas.drawCircle(
        c,
        62,
        Paint()..color = accent.withValues(alpha: .18 * check),
      );
      _checkMark(canvas, c, 1, accent);
    }
  }

  // C · Дорожный знак: five bars, one per second.
  void _roadsign(Canvas canvas, Offset c) {
    if (stage == CalStage.search || _warn) {
      _oval(canvas, c, _yellow);
      return;
    }
    const w = 48.0, h = 14.0, gap = 10.0;
    final lit = stage == CalStage.done ? 5 : (progress * 5).floor();
    final x0 = c.dx - (5 * w + 4 * gap) / 2;
    for (var i = 0; i < 5; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x0 + i * (w + gap), c.dy - h / 2, w, h),
          const Radius.circular(2),
        ),
        Paint()..color = i < lit ? accent : Colors.white.withValues(alpha: .22),
      );
    }
  }

  @override
  bool shouldRepaint(CalibrationPainter old) =>
      old.stage != stage ||
      old.progress != progress ||
      old.sweep != sweep ||
      old.check != check ||
      old.design != design ||
      old.accent != accent;
}

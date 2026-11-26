import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Large text that may wrap between words but never inside one: when the
/// longest word is wider than the box, the font shrinks until it fits.
/// For the 56–96 pt words of the trip status and the alarm («Камера
/// недоступна» at 76 pt in look C, «Поднимите голову!» at 64 pt).
class FitWords extends StatelessWidget {
  const FitWords(
    this.text, {
    super.key,
    required this.style,
    this.textAlign = TextAlign.start,
    this.maxLines,
  });
  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  /// With [maxLines] the font also shrinks until the text takes no more
  /// lines than that (1 keeps «1 ч 40 мин» on one line).
  final int? maxLines;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scaler = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      double widthOf(String s, TextStyle st) {
        final tp = TextPainter(
          text: TextSpan(text: s, style: st),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final w = tp.width;
        tp.dispose();
        return w;
      }

      var k = 1.0;
      if (box.maxWidth.isFinite) {
        final words = maxLines == 1 ? [text] : text.split(RegExp(r'\s+'));
        final widest = words.map((w) => widthOf(w, style)).fold(0.0, math.max);
        if (widest > box.maxWidth) k = box.maxWidth / widest * .98;
      }
      final fitted = style.copyWith(fontSize: (style.fontSize ?? 14) * k);
      return Text(
        text,
        style: fitted,
        textAlign: textAlign,
        maxLines: maxLines,
        softWrap: maxLines != 1,
      );
    },
  );
}

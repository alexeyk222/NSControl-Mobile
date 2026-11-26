import 'package:flutter/material.dart';

import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../presentation/phone_problem.dart';
import 'marks.dart';

/// A failure of the phone, shown as a yellow-framed card: the plain title,
/// what to do, and the controller's own text in small type. Yellow, not
/// red: red belongs to the alarm alone. With [onHide] a «Скрыть» link
/// closes it (before a trip only; on the road it stays).
class ProblemCard extends StatelessWidget {
  const ProblemCard(
    this.problem, {
    super.key,
    required this.palette,
    this.onHide,
  });

  final PhoneProblem problem;
  final NsPalette palette;
  final VoidCallback? onHide;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = palette;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: p.attention.withValues(alpha: .10),
          border: Border.all(color: p.attention, width: 1.5),
          borderRadius: BorderRadius.circular(theme.radii.card),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: StatusMark(MarkKind.attention, palette: p, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    problem.title,
                    style: theme
                        .body(p.attention)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (problem.hint != null) ...[
                    const SizedBox(height: 2),
                    Text(problem.hint!, style: theme.caption(p.text)),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    problem.detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.caption(p.text2).copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
            if (onHide != null)
              TextButton(
                onPressed: onHide,
                child: Text(Copy.problemHide, style: theme.caption(p.text2)),
              ),
          ],
        ),
      ),
    );
  }
}

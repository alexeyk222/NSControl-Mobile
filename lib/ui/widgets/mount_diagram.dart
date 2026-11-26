import 'package:flutter/material.dart';

import '../copy.dart';
import '../design/ns_theme.dart';

/// Where the phone stands, as the trip controller stores it
/// (`TripController.mountPosition`, setting `trip_mount`).
enum MountSide {
  left('vent_left', Copy.mountLeft, Copy.sideLeft),
  right('vent_right', Copy.mountRight, Copy.sideRight),
  center('front', Copy.mountCenter, Copy.sideCenter);

  const MountSide(this.code, this.label, this.short);

  /// Value of `TripController.mountPosition`.
  final String code;

  /// Option text («Слева от меня»).
  final String label;

  /// Short form for «Камера настроена · слева».
  final String short;

  static MountSide parse(String? code) =>
      values.where((m) => m.code == code).firstOrNull ?? MountSide.left;
}

/// The cabin seen from the driver's seat (onboarding «Где стоит телефон?»):
/// the dashboard, three vents, the wheel, and the phone marker that slides
/// to the chosen side in 0.3 s. Geometry from the design (366 × 210 pt).
class MountDiagram extends StatelessWidget {
  const MountDiagram({super.key, required this.side});
  final MountSide side;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    // Drawn in the design's 366 × 210 box and scaled to the width (no
    // LayoutBuilder: the onboarding column measures its intrinsic height).
    final (mx, my) = switch (side) {
      MountSide.left => (17.0, 62.0),
      MountSide.right => (201.0, 62.0),
      MountSide.center => (104.0, 10.0),
    };
    Widget vent(double left) => Positioned(
      left: left,
      top: 76,
      child: Container(
        width: 34,
        height: 18,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: p.text2, width: 2),
        ),
      ),
    );
    final diagram = Semantics(
      label: '${Copy.mountView}: ${side.label}',
      child: Container(
        height: 210,
        decoration: BoxDecoration(
          color: p.surface2,
          borderRadius: BorderRadius.circular(theme.radii.card),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // Dashboard.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 56,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surface,
                  border: Border(bottom: BorderSide(color: p.line)),
                ),
              ),
            ),
            vent(12),
            vent(196),
            vent(244),
            // Wheel.
            Positioned(
              left: 52,
              top: 84,
              child: Opacity(
                opacity: .75,
                child: Container(
                  width: 128,
                  height: 128,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: p.text2, width: 12),
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              left: mx,
              top: my,
              child: Container(
                width: 24,
                height: 40,
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: p.accent.withValues(alpha: .35),
                      blurRadius: 12,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 8,
              child: Text(Copy.mountView, style: theme.caption(p.text2)),
            ),
          ],
        ),
      ),
    );
    return AspectRatio(
      aspectRatio: 366 / 210,
      child: FittedBox(
        child: SizedBox(width: 366, height: 210, child: diagram),
      ),
    );
  }
}

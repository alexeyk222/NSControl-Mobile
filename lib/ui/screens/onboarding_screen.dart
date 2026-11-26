import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../presentation/ui_prefs.dart';
import '../widgets/buttons.dart';
import '../widgets/marks.dart';
import '../widgets/mount_diagram.dart';
import '../widgets/owl.dart';
import 'common.dart';

/// First run (design screens «Знакомство», «Крепление», «Звук»): three
/// steps that slide from the right, then the pre-trip screen. The camera
/// permission is asked by iOS at the first «Поехали», where its purpose is
/// obvious.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.trip, required this.prefs});
  final TripController trip;
  final UiPrefs prefs;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int step = 0;
  bool _back = false;
  late MountSide side = MountSide.parse(widget.trip.mountPosition);
  bool played = false;

  void _go(int to) => setState(() {
    _back = to < step;
    step = to;
  });

  void _setSide(MountSide s) {
    setState(() => side = s);
    widget.trip.mountPosition = s.code;
    widget.trip.journal((db) => db.setSetting('trip_mount', s.code));
  }

  Future<void> _louder() async {
    final t = widget.trip;
    await t.changeSettings(settingsWith(t.settings, volume: 1));
    await t.testAlert();
  }

  @override
  Widget build(BuildContext context) {
    final page = switch (step) {
      0 => _intro(context),
      1 => _mount(context),
      _ => _sound(context),
    };
    return PopScope(
      canPop: step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && step > 0) _go(step - 1);
      },
      child: NsPage(
        child: AnimatedSwitcher(
          duration: NsMotion.page,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, a) {
            final incoming = child.key == ValueKey(step);
            final dx = (incoming ? 1 : -1) * (_back ? -1 : 1) * .12;
            return FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(
                  begin: Offset(dx, 0),
                  end: Offset.zero,
                ).animate(a),
                child: child,
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey(step),
            child: FillScroll(child: page),
          ),
        ),
      ),
    );
  }

  Widget _stepLabel(BuildContext context) {
    final theme = NsTheme.of(context);
    return Text(
      '${Copy.onboardingStep} · ${step + 1} из 3',
      style: theme.caption(theme.palette.text2),
    );
  }

  Widget _intro(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 32),
        const OwlTile(),
        const SizedBox(height: 32),
        Text(Copy.introTitle, style: theme.title()),
        const SizedBox(height: 20),
        for (final point in Copy.introPoints)
          MarkedLine(mark: MarkKind.ok, text: point),
        const Spacer(),
        Text(Copy.introPrivacy, style: theme.caption(p.text2)),
        const SizedBox(height: 16),
        NsButton.primary(Copy.introCta, onPressed: () => _go(1)),
      ],
    );
  }

  Widget _mount(BuildContext context) {
    final theme = NsTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepLabel(context),
        const SizedBox(height: 8),
        Text(Copy.mountTitle, style: theme.title()),
        const SizedBox(height: 20),
        MountDiagram(side: side),
        const SizedBox(height: 16),
        for (final s in MountSide.values) ...[
          NsOption(
            label: s.label,
            selected: side == s,
            onTap: () => _setSide(s),
          ),
          const SizedBox(height: 10),
        ],
        Text(Copy.mountHint, style: theme.caption(theme.palette.text2)),
        const Spacer(),
        NsButton.primary(Copy.next, onPressed: () => _go(2)),
      ],
    );
  }

  Widget _sound(BuildContext context) {
    final theme = NsTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepLabel(context),
        const SizedBox(height: 8),
        Text(Copy.soundTitle, style: theme.title()),
        Expanded(
          child: Center(
            child: _PlayButton(
              onTap: () {
                setState(() => played = true);
                unawaited(widget.trip.testAlert());
              },
            ),
          ),
        ),
        AnimatedOpacity(
          duration: NsMotion.state,
          opacity: played ? 1 : .55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Copy.soundAsk, style: theme.heading()),
              const SizedBox(height: 16),
              NsButton.primary(
                Copy.soundYes,
                onPressed: widget.prefs.setOnboarded,
              ),
              const SizedBox(height: 10),
              NsButton.secondary(Copy.soundLouder, onPressed: _louder),
            ],
          ),
        ),
      ],
    );
  }
}

/// The round 180 pt «прослушать» button with a soft ripple while it plays.
class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = NsTheme.of(context).palette;
    return Semantics(
      button: true,
      label: Copy.soundPlay,
      excludeSemantics: true,
      child: Pressable(
        onTap: () {
          widget.onTap();
          _wave.forward(from: 0);
        },
        child: AnimatedBuilder(
          animation: _wave,
          builder: (context, _) => CustomPaint(
            painter: _WavePainter(_wave.value, p.accent),
            child: Container(
              width: 180,
              height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: p.accent, width: 6),
              ),
              child: Icon(Icons.play_arrow_rounded, size: 96, color: p.accent),
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = size.center(Offset.zero);
    for (final lag in [0.0, .3]) {
      final v = ((t - lag) / (1 - lag)).clamp(0.0, 1.0);
      if (v <= 0) continue;
      canvas.drawCircle(
        c,
        90 + 40 * v,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withValues(alpha: .5 * (1 - v)),
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.t != t;
}

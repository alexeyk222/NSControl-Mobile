import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/detector.dart';
import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../presentation/voice.dart';
import '../widgets/buttons.dart';
import '../widgets/calibration_visual.dart';
import '../widgets/marks.dart';
import 'common.dart';

/// «Настройка камеры» (design screen 5, states C-01…C-09). Runs between
/// «Поехали» and the trip screen without a single tap:
///
/// 1. search — no face: «Поверните телефон к себе» (voice after 2 s);
/// 2. one face held for [confirmAfter] — the face is confirmed for the
///    driver (`TripController.confirmFace`). Several faces: a frame over
///    each, the closest (largest) one chosen in advance; the driver taps
///    their own and «Это я» (not in «ТЗ 2.2 (эталон)», which waits for
///    one face);
/// 3. capture — «Смотрите на дорогу», the guide fills with the trip's
///    calibration progress;
/// 4. done — «Готово», a check; the app shell keeps this screen for a
///    moment, then the trip screen fades in;
/// fail — the calibration was refused: yellow, a shake, «Ещё раз» after
/// 2 s; after three failures the driver may go on with the head only.
class CameraSetupScreen extends StatefulWidget {
  const CameraSetupScreen({
    super.key,
    required this.trip,
    required this.voice,
    required this.done,
    required this.onCancel,
  });
  final TripController trip;
  final UiVoice voice;

  /// The calibration has finished: show «Готово».
  final bool done;
  final VoidCallback onCancel;

  /// One face this long before it is taken as the driver's.
  static const confirmAfter = Duration(seconds: 1);

  /// «Не получилось» stays this long before the next attempt.
  static const failFor = Duration(seconds: 2);

  @override
  State<CameraSetupScreen> createState() => _CameraSetupScreenState();
}

class _CameraSetupScreenState extends State<CameraSetupScreen> {
  int? _candidate;

  /// The face chosen among several (tracking id); the closest by default.
  int? _picked;
  Timer? _confirm, _noFaceVoice, _failTimer;
  bool _failing = false;
  int _failures = 0;
  String? _lastError;
  TripPhase? _lastPhase;

  TripController get trip => widget.trip;

  @override
  void initState() {
    super.initState();
    trip.addListener(_onTrip);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTrip());
  }

  /// Hints spoken in this attempt: each once, not on every frame.
  final Set<String> _said = {};

  void _sayOnce(String line) {
    if (_said.add(line)) widget.voice.say(line);
  }

  @override
  void didUpdateWidget(CameraSetupScreen old) {
    super.didUpdateWidget(old);
    if (widget.done && !old.done) widget.voice.say(Voice.calDone);
  }

  @override
  void dispose() {
    trip.removeListener(_onTrip);
    _confirm?.cancel();
    _noFaceVoice?.cancel();
    _failTimer?.cancel();
    super.dispose();
  }

  /// Reacts to the trip: auto-confirms a single face, notices a refused
  /// calibration, and speaks the hints that the controller does not.
  void _onTrip() {
    if (!mounted) return;
    final phase = trip.phase;
    if (phase == TripPhase.calibrating && _lastPhase != phase) {
      _said.clear();
      // The controller says «Смотрите на дорогу, как обычно» itself in
      // the side-mount calibration; show it, speak only otherwise.
      trip.mountRelative
          ? widget.voice.show(Voice.calGo)
          : widget.voice.say(Voice.calGo);
    }
    if (phase == TripPhase.findingFace &&
        _lastPhase == TripPhase.calibrating &&
        trip.error != null) {
      _fail();
    }
    _lastPhase = phase;
    _lastError = trip.error;

    if (phase != TripPhase.findingFace || _failing) {
      _confirm?.cancel();
      _confirm = null;
      _candidate = null;
      _noFaceVoice?.cancel();
      _noFaceVoice = null;
      return;
    }
    final faces = trip.faces;
    if (faces.isEmpty) {
      _confirm?.cancel();
      _confirm = null;
      _candidate = null;
      _noFaceVoice ??= Timer(const Duration(seconds: 2), () {
        if (mounted && trip.faces.isEmpty) _sayOnce(Voice.calNoFace);
      });
      return;
    }
    _noFaceVoice?.cancel();
    _noFaceVoice = null;
    if (faces.length > 1) {
      _confirm?.cancel();
      _confirm = null;
      _candidate = null;
      _sayOnce(trip.tzReference ? Voice.calMany : Voice.calManyPick);
      return;
    }
    final id = faces.single.measurement.trackingId;
    if (id == null) return;
    if (id != _candidate) {
      _candidate = id;
      _confirm?.cancel();
      _confirm = Timer(CameraSetupScreen.confirmAfter, () {
        if (!mounted) return;
        final f = trip.faces;
        if (trip.phase == TripPhase.findingFace &&
            f.length == 1 &&
            f.single.measurement.trackingId == id) {
          trip.confirmFace(id);
        }
        _candidate = null;
      });
    }
  }

  void _fail() {
    _failures++;
    _said.clear();
    _failing = true;
    widget.voice.say(Voice.calRetry);
    _failTimer?.cancel();
    _failTimer = Timer(CameraSetupScreen.failFor, () {
      if (!mounted) return;
      setState(() => _failing = false);
      _onTrip();
    });
  }

  /// The face to confirm among several: the one tapped while it is still
  /// in the frame, else the closest.
  int? get _choice {
    final ids = trip.faces.map((f) => f.measurement.trackingId).toSet();
    if (_picked != null && ids.contains(_picked)) return _picked;
    return trip.closestFace?.measurement.trackingId;
  }

  bool get _canPick =>
      _stage == CalStage.many &&
      !trip.tzReference &&
      trip.phase == TripPhase.findingFace;

  void _confirmChoice() {
    final id = _choice;
    if (id == null) return;
    trip.confirmFace(id);
    _picked = null;
  }

  Future<void> _headOnly() async {
    await trip.changeSettings(settingsWith(trip.settings, hiddenEyes: true));
    setState(() => _failures = 0);
  }

  CalStage get _stage {
    if (widget.done) return CalStage.done;
    if (_failing) return CalStage.fail;
    if (trip.phase == TripPhase.calibrating) return CalStage.capture;
    if (trip.faces.length > 1) return CalStage.many;
    return CalStage.search;
  }

  String get _hint {
    if (trip.cameraPermissionBlocked) return Copy.readyCameraDenied;
    return switch (_stage) {
      CalStage.done => Copy.calDone,
      CalStage.fail =>
        _failures >= 3
            ? Copy.calFailFinal
            : (_lastError ?? '').contains('лиц')
            ? Copy.calFailLost
            : Copy.calFailMoved,
      CalStage.capture => Copy.calGo,
      CalStage.many => trip.tzReference ? Copy.calManyWait : Copy.calMany,
      CalStage.search =>
        trip.phase != TripPhase.findingFace
            ? Copy.calStarting
            : trip.faces.length == 1
            ? Copy.calFaceSeen
            : Copy.calNoFace,
    };
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([trip, widget.voice]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.trip;
    final stage = _stage;
    final hintColor = switch (stage) {
      CalStage.fail || CalStage.many => p.attention,
      CalStage.done => p.accent,
      _ => p.text,
    };
    final faces = trip.faces;
    final single = faces.length == 1;
    final eyes =
        single &&
        (faces.single.signals?.eyeOpenLeft != null ||
            faces.single.measurement.leftEye != null);
    return Theme(
      data: Theme.of(context).copyWith(brightness: Brightness.dark),
      child: ColoredBox(
        color: p.bgTrip,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    TextButton(
                      onPressed: widget.done ? null : widget.onCancel,
                      child: Text(Copy.cancel, style: theme.body(p.text2)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        Copy.calTitle,
                        overflow: TextOverflow.ellipsis,
                        style: theme
                            .body(p.text)
                            .copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // The frame gives way to the hints when the phone is short
                // or a hint takes two lines.
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _PreviewBox(
                      trip: trip,
                      stage: stage,
                      picked: _canPick ? _choice : null,
                      onPick: _canPick
                          ? (id) => setState(() => _picked = id)
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedSwitcher(
                        duration: NsMotion.state,
                        transitionBuilder: (c, a) => FadeTransition(
                          opacity: a,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0, .2),
                              end: Offset.zero,
                            ).animate(a),
                            child: c,
                          ),
                        ),
                        child: Text(
                          _hint,
                          key: ValueKey(_hint),
                          style: theme.heading(hintColor),
                        ),
                      ),
                      const SizedBox(height: 8),
                      AnimatedOpacity(
                        duration: NsMotion.state,
                        opacity: widget.voice.line == null ? 0 : 1,
                        child: _VoiceLine(text: widget.voice.line ?? ''),
                      ),
                      const SizedBox(height: 12),
                      _Checks(
                        face: faces.isNotEmpty || widget.done,
                        eyes: eyes || widget.done,
                        light: faces.isNotEmpty || widget.done,
                        single: single || widget.done,
                        many: faces.length > 1,
                      ),
                      if (_canPick && _choice != null) ...[
                        const SizedBox(height: 16),
                        NsButton.primary(
                          Copy.calManyConfirm,
                          key: const Key('cal-this-is-me'),
                          palette: p,
                          onPressed: _confirmChoice,
                        ),
                      ],
                      if (trip.cameraPermissionBlocked) ...[
                        const SizedBox(height: 16),
                        Text(Copy.calCameraDenied, style: theme.body(p.text2)),
                        const SizedBox(height: 12),
                        NsButton.primary(
                          Copy.actOpenSettings,
                          palette: p,
                          onPressed: () => unawaited(trip.openSettings()),
                        ),
                        NsButton.text(
                          Copy.retry,
                          palette: p,
                          onPressed: () => unawaited(trip.retryCamera()),
                        ),
                      ] else if (_failures >= 3 && !widget.done) ...[
                        const SizedBox(height: 16),
                        NsButton.secondary(
                          Copy.calHeadOnly,
                          palette: p,
                          onPressed: _headOnly,
                        ),
                      ],
                    ],
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

/// The 3:4 camera frame with the guide of the look over it. ARKit's
/// 1080 × 1440 portrait frame is shown with cover fit; without a picture
/// (simulator, a camera that is starting) the guide is drawn on a dark
/// frame.
class _PreviewBox extends StatelessWidget {
  const _PreviewBox({
    required this.trip,
    required this.stage,
    this.picked,
    this.onPick,
  });
  final TripController trip;
  final CalStage stage;

  /// Several faces: the chosen one (framed in the accent) and the tap
  /// that chooses another. Null: no frames.
  final int? picked;
  final ValueChanged<int>? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final preview = trip.preview();
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        // Keep room for the hints on short phones: at most 55 % of height.
        final maxH = MediaQuery.sizeOf(context).height * .55;
        final h = math.min(w * 4 / 3, math.min(maxH, box.maxHeight));
        return ClipRRect(
          borderRadius: BorderRadius.circular(theme.radii.card),
          child: SizedBox(
            width: h * 3 / 4,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: theme.trip.surface,
                  child: preview == null
                      ? null
                      : FittedBox(
                          fit: BoxFit.cover,
                          clipBehavior: Clip.hardEdge,
                          child: SizedBox(
                            width: 1080,
                            height: 1440,
                            child: preview,
                          ),
                        ),
                ),
                // Darken the edges so the guide reads on any picture.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      radius: .85,
                      colors: [Color(0x00000000), Color(0x99000000)],
                    ),
                  ),
                ),
                CalibrationVisual(
                  stage: stage,
                  progress: trip.calibrationProgress,
                ),
                if (onPick != null)
                  _FaceFrames(
                    faces: trip.faces,
                    picked: picked,
                    onPick: onPick!,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A frame over each face to choose the driver's among several. The
/// contract box is normalized and unmirrored in the portrait image, which
/// fills this 3:4 frame exactly; the front camera's preview is mirrored, so
/// the frames are too (as on the Lab page). A face without a box gets no
/// frame: «Это я» still confirms the closest one.
class _FaceFrames extends StatelessWidget {
  const _FaceFrames({
    required this.faces,
    required this.picked,
    required this.onPick,
  });
  final List<DetectedFace> faces;
  final int? picked;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.trip;
    return LayoutBuilder(
      builder: (context, size) {
        final w = size.maxWidth, h = size.maxHeight;
        return Stack(
          children: [
            for (final face in faces)
              if (face.signals?.box case final box?)
                if (face.measurement.trackingId case final id?)
                  Positioned(
                    // Mirrored: the left of the image is the right on screen.
                    left: (1 - box.left - box.width) * w,
                    top: box.top * h,
                    width: box.width * w,
                    height: box.height * h,
                    child: Semantics(
                      button: true,
                      selected: id == picked,
                      label: Copy.calManyConfirm,
                      child: GestureDetector(
                        key: Key('face-$id'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onPick(id),
                        child: AnimatedContainer(
                          duration: NsMotion.state,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: id == picked
                                  ? p.accent
                                  : p.text2.withValues(alpha: .6),
                              width: id == picked ? 3 : 1.5,
                            ),
                            borderRadius: BorderRadius.circular(
                              theme.radii.chip,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ],
        );
      },
    );
  }
}

class _VoiceLine extends StatelessWidget {
  const _VoiceLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.trip;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text('Голос: «$text»', style: theme.caption(p.text2)),
    );
  }
}

/// Four checks in a 2 × 2 grid with shape marks.
class _Checks extends StatelessWidget {
  const _Checks({
    required this.face,
    required this.eyes,
    required this.light,
    required this.single,
    required this.many,
  });
  final bool face, eyes, light, single, many;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.trip;
    Widget check(String label, bool ok, {bool warn = false}) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: NsMotion.quick,
              child: StatusMark(
                warn ? MarkKind.attention : (ok ? MarkKind.ok : MarkKind.todo),
                key: ValueKey((ok, warn)),
                palette: p,
                size: 12,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label, style: theme.caption(ok ? p.text : p.text2)),
            ),
          ],
        ),
      ),
    );
    return Column(
      children: [
        Row(
          children: [
            check(Copy.calCheckFace, face),
            check(Copy.calCheckEyes, eyes),
          ],
        ),
        Row(
          children: [
            check(Copy.calCheckLight, light),
            check(Copy.calCheckSingle, single, warn: many),
          ],
        ),
      ],
    );
  }
}

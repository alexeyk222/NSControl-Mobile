import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/lab_controller.dart';
import '../../services/sleep_controller.dart';
import '../../services/trip_controller.dart';
import '../design/ns_theme.dart';
import '../presentation/trip_story.dart';
import '../presentation/ui_prefs.dart';
import '../presentation/voice.dart';
import 'camera_setup_screen.dart';
import 'common.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';
import 'summary_screen.dart';
import 'trip_screen.dart';

/// Where the driver is in the scenario (README «Взаимодействие»):
/// Знакомство → Перед поездкой → «Поехали» → Настройка камеры → В пути →
/// (Тревога over it) → Итог → Перед поездкой.
enum ShellStage { onboarding, home, camera, trip, summary }

/// Chooses the stage from the trip's state, so the scenario follows the
/// trip controller and never gets out of step with it (a trip restored
/// after the app was killed opens on the trip screen, a refused
/// calibration goes back to the camera). Stages cross-fade.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.trip,
    required this.sleep,
    required this.prefs,
    required this.voice,
    required this.developerMode,
    required this.onDeveloperMode,
    this.createLab,
  });
  final TripController trip;
  final SleepController sleep;
  final UiPrefs prefs;
  final UiVoice voice;
  final bool developerMode;
  final ValueChanged<bool> onDeveloperMode;
  final LabController Function()? createLab;

  /// «Готово» of the camera setup stays this long before the trip screen.
  static const doneFor = Duration(milliseconds: 1400);

  /// Pure choice of the stage, for tests.
  static ShellStage stageOf({
    required bool onboarded,
    required bool active,
    required TripPhase phase,
    required bool observed,
    required bool showingDone,
    required String? summaryFor,
  }) {
    if (!onboarded && !active) return ShellStage.onboarding;
    if (active) {
      if (showingDone) return ShellStage.camera;
      if (phase == TripPhase.findingFace || phase == TripPhase.calibrating) {
        return ShellStage.camera;
      }
      // Starting: the camera screen says «Включаю камеру».
      if (phase == TripPhase.idle && !observed) return ShellStage.camera;
      return ShellStage.trip;
    }
    if (summaryFor != null) return ShellStage.summary;
    return ShellStage.home;
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _observed = false, _wasActive = false;
  TripPhase _lastPhase = TripPhase.idle;
  DateTime? _doneUntil;
  Timer? _doneTimer;
  String? _summaryFor;

  /// When the current trip started, for the summary's fallback.
  DateTime? _startedAt;
  TripStory? _fallback;

  TripController get trip => widget.trip;

  @override
  void initState() {
    super.initState();
    _wasActive = trip.active;
    _observed = trip.active && trip.phase == TripPhase.observing;
    _lastPhase = trip.phase;
    trip.addListener(_onTrip);
    widget.prefs.addListener(_syncPrefs);
    _syncPrefs();
  }

  @override
  void dispose() {
    trip.removeListener(_onTrip);
    widget.prefs.removeListener(_syncPrefs);
    _doneTimer?.cancel();
    super.dispose();
  }

  /// The driver's choices that the trip controller uses: the look and the
  /// mount side go to the watch with every state push; the voice switch
  /// silences the optional phrases of both the screen and the controller;
  /// the break interval is taken outside a trip (the rules read it when a
  /// trip starts, and the settings row is locked during one).
  void _syncPrefs() {
    final prefs = widget.prefs;
    trip.watchExtras = {
      'design': prefs.design.name,
      'mount': trip.mountPosition,
    };
    widget.voice.enabled = prefs.voice;
    trip.voiceEnabled = prefs.voice;
    final interval = Duration(minutes: prefs.breakMinutes);
    if (!trip.active && trip.breakInterval != interval) {
      trip.breakInterval = interval;
    }
  }

  void _onTrip() {
    if (!mounted) return;
    final phase = trip.phase;
    if (trip.active && !_wasActive) {
      _observed = false;
      _summaryFor = null;
      _startedAt = DateTime.now();
      _syncPrefs();
    }
    if (trip.active &&
        phase == TripPhase.observing &&
        _lastPhase == TripPhase.calibrating) {
      // The calibration has just finished: «Готово» first.
      widget.prefs.setCameraReady(true);
      _doneUntil = DateTime.now().add(AppShell.doneFor);
      _doneTimer?.cancel();
      _doneTimer = Timer(AppShell.doneFor, () {
        if (mounted) setState(() => _doneUntil = null);
      });
    }
    if (phase == TripPhase.observing) _observed = true;
    if (!trip.active && _wasActive) {
      _summaryFor = _observed ? trip.lastFinishedTrip : null;
      final id = _summaryFor;
      _fallback = id == null
          ? null
          : TripStory(
              id: id,
              start: _startedAt ?? DateTime.now(),
              end: DateTime.now(),
              segments: const [],
              alarms: const [],
              eyesAlarms: trip.tripEyesAlarms,
              headAlarms: trip.tripHeadAlarms,
              unseen: Duration.zero,
              breaks: trip.tripBreaks,
              partial: true,
              active: false,
            );
      _doneUntil = null;
    }
    _wasActive = trip.active;
    _lastPhase = phase;
    setState(() {});
  }

  bool get _showingDone =>
      _doneUntil != null && DateTime.now().isBefore(_doneUntil!);

  void _start() => unawaited(trip.start());

  @override
  Widget build(BuildContext context) {
    final stage = AppShell.stageOf(
      onboarded: widget.prefs.onboarded,
      active: trip.active,
      phase: trip.phase,
      observed: _observed,
      showingDone: _showingDone,
      summaryFor: _summaryFor,
    );
    final theme = NsTheme.of(context);
    final darkChrome =
        stage == ShellStage.camera ||
        stage == ShellStage.trip ||
        theme.palette.isDark;
    final Widget page = switch (stage) {
      ShellStage.onboarding => OnboardingScreen(
        trip: trip,
        prefs: widget.prefs,
      ),
      ShellStage.home => HomeScreen(
        trip: trip,
        sleep: widget.sleep,
        prefs: widget.prefs,
        developerMode: widget.developerMode,
        onDeveloperMode: widget.onDeveloperMode,
        onStart: _start,
        createLab: widget.createLab,
      ),
      ShellStage.camera => CameraSetupScreen(
        trip: trip,
        voice: widget.voice,
        done: _showingDone,
        onCancel: () => unawaited(trip.finish()),
      ),
      ShellStage.trip => TripScreen(
        trip: trip,
        voice: widget.voice,
        developerMode: widget.developerMode,
        onFinish: () => unawaited(trip.finish()),
      ),
      ShellStage.summary => SummaryScreen(
        trip: trip,
        tripId: _summaryFor!,
        fallback: _fallback,
        onDone: () => setState(() => _summaryFor = null),
      ),
    };
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: darkChrome
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: stage == ShellStage.camera || stage == ShellStage.trip
            ? theme.trip.bgTrip
            : theme.palette.bg,
        body: AnimatedSwitcher(
          duration: pageMotion,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: fadeThrough,
          child: KeyedSubtree(key: ValueKey(stage), child: page),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'package:camera_android/camera_android.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'data/trip_repository.dart' hide Row;
import 'logic/arkit_geometry.dart' show arkitCapabilities;
import 'logic/domain.dart';
import 'services/detector.dart';
import 'services/arkit_engine.dart';
import 'services/lab_controller.dart';
import 'services/lab_recorder.dart';
import 'services/mlkit_detector.dart';
import 'services/platform_bridge.dart';
import 'services/sleep_controller.dart';
import 'services/trip_controller.dart';
import 'logic/detection_profile.dart';
import 'ui/design/ns_theme.dart';
import 'ui/lab_page.dart';
import 'ui/presentation/ui_prefs.dart';
import 'ui/presentation/voice.dart';
import 'ui/screens/alarm_overlay.dart';
import 'ui/screens/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Legacy camera produces the single NV21 plane expected by ML Kit.
  if (Platform.isAndroid) AndroidCamera.registerWith();
  TripRepository? db;
  var settings = AlgorithmSettings();
  var incomplete = false;
  var developerMode = false;
  var recordTrips = false;
  var liveDebug = false, debugClips = false;
  var tripProfile = DetectionProfile.current;
  var tripEngine = TripEngine.arkit;
  String? tripMount;
  try {
    db = await TripRepository.open();
    await db.recoverInterrupted();
    final stored = await db.getSetting('algorithm');
    if (stored is Map) {
      settings = AlgorithmSettings.fromJson(Map<String, dynamic>.from(stored));
    }
    developerMode = await db.getSetting('developer_mode') == true;
    final profileId = await db.getSetting('trip_profile');
    tripProfile =
        DetectionProfile.all.where((p) => p.id == profileId).firstOrNull ??
        // Before profiles: the developer switch «Поездка: ТЗ 2.2 (эталон)».
        (await db.getSetting('trip_tz_reference') == true
            ? DetectionProfile.tz22
            : DetectionProfile.current);
    recordTrips = await db.getSetting('trip_recording') == true;
    liveDebug = await db.getSetting('trip_debug_live') == true;
    debugClips = await db.getSetting('trip_debug_clips') == true;
    final engine = await db.getSetting('trip_engine');
    tripEngine =
        TripEngine.values.where((e) => e.name == engine).firstOrNull ??
        TripEngine.arkit;
    final mount = await db.getSetting('trip_mount');
    if (mount is String) tripMount = mount;
  } catch (_) {
    incomplete = true;
  }
  final registry = DetectorRegistry({
    'mlkit_face_detection': MlKitDetector.new,
  });
  final trip =
      TripController(
          repository: db,
          platform: const PlatformBridge(),
          detector: registry.create('mlkit_face_detection'),
          settings: settings,
          // ARKit is the trip's engine on iPhone; ML Kit is the fallback.
          arkitFactory: Platform.isIOS
              ? (options, onStats, onRaw) => ArkitFaceSource(
                  options: options,
                  onStats: onStats,
                  onRaw: onRaw,
                )
              : null,
          arkitSupported: Platform.isIOS
              ? () => ArkitEngine().isSupported()
              : null,
        )
        ..profile = tripProfile
        ..engineChoice = tripEngine
        ..recordTrips = recordTrips
        ..debugClips = debugClips
        ..mountPosition = tripMount ?? 'front';
  trip.journalIncomplete = incomplete || db == null;
  final sleep = SleepController(trip: trip, platform: const PlatformBridge());
  await sleep.load();
  // The look, the theme and the onboarding (docs/ux/implementation.md).
  final prefs = await UiPrefs.load(db, save: trip.journal);
  Directory? documents;
  try {
    documents = await getApplicationDocumentsDirectory();
  } catch (_) {}
  final recordings = documents == null
      ? null
      : Directory('${documents.path}/recordings');
  if (recordings != null) trip.recorder = LabRecorder(recordings);
  // Developer live debug: the server lives while the option is on.
  if (liveDebug) unawaited(trip.setLiveDebug(true));
  runApp(
    NSControlApp(
      trip: trip,
      sleep: sleep,
      prefs: prefs,
      initialDeveloperMode: developerMode,
      createLab: recordings == null
          ? null
          : () {
              late final LabController lab;
              return lab = LabController(
                options: [
                  ...labEngineOptions(
                    () => registry.create('mlkit_face_detection'),
                  ),
                  // ARKit owns the front camera while it runs; the lab stops
                  // the camera plugin source before starting another one.
                  if (Platform.isIOS)
                    ...arkitLabEngineOptions(
                      onRaw: (result, raw) {
                        if (result.engineId == arkitCapabilities.id) {
                          lab.attachRaw(result, raw);
                        }
                      },
                      onStats: (stats) => lab.deviceLine(stats.toJson()),
                    ),
                ],
                platform: const PlatformBridge(),
                settings: trip.settings,
                recordingsDirectory: recordings,
              );
            },
    ),
  );
}

/// The app: the look of [UiPrefs] (A/B/C, light or dark outside a trip),
/// the scenario of [AppShell] and the alarm over every page.
class NSControlApp extends StatefulWidget {
  const NSControlApp({
    super.key,
    required this.trip,
    required this.sleep,
    this.prefs,
    this.initialDeveloperMode = false,
    this.createLab,
  });
  final TripController trip;
  final SleepController sleep;

  /// Interface choices; tests may leave it out (onboarded, look A).
  final UiPrefs? prefs;
  final bool initialDeveloperMode;

  /// Builds the hidden developer lab; null when it is unavailable.
  final LabController Function()? createLab;
  @override
  State<NSControlApp> createState() => _NSControlAppState();
}

class _NSControlAppState extends State<NSControlApp>
    with WidgetsBindingObserver {
  late bool developerMode;
  late final UiPrefs prefs =
      widget.prefs ?? UiPrefs(onboarded: true, save: widget.trip.journal);
  late final UiVoice voice = UiVoice(
    platform: widget.trip.platform,
    enabled: prefs.voice,
  );

  @override
  void initState() {
    super.initState();
    developerMode = widget.initialDeveloperMode;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive is a system sheet or Control Centre over the app: the camera
    // goes on, so the trip does not pause (hidden/paused do pause it).
    if (state == AppLifecycleState.inactive) return;
    unawaited(widget.trip.foreground(state == AppLifecycleState.resumed));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    voice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: prefs,
    builder: (context, _) => MaterialApp(
      title: 'NSControl',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildNsTheme(prefs.design, Brightness.light),
      darkTheme: buildNsTheme(prefs.design, Brightness.dark),
      themeMode: prefs.themeMode,
      themeAnimationDuration: const Duration(milliseconds: 420),
      // The alarm lies over every page and route.
      builder: (context, child) => Stack(
        children: [
          ?child,
          Positioned.fill(child: AlarmOverlay(trip: widget.trip)),
        ],
      ),
      home: AppShell(
        trip: widget.trip,
        sleep: widget.sleep,
        prefs: prefs,
        voice: voice,
        developerMode: developerMode,
        onDeveloperMode: (value) {
          setState(() => developerMode = value);
          widget.trip.journal((db) => db.setSetting('developer_mode', value));
        },
        createLab: widget.createLab,
      ),
    ),
  );
}

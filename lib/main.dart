import 'dart:async';
import 'dart:io';
import 'package:camera_android/camera_android.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'data/trip_repository.dart' hide Row;
import 'logic/domain.dart';
import 'services/detector.dart';
import 'services/lab_controller.dart';
import 'services/mlkit_detector.dart';
import 'services/platform_bridge.dart';
import 'services/sleep_controller.dart';
import 'services/trip_controller.dart';
import 'ui/integrations_page.dart';
import 'ui/journal_page.dart';
import 'ui/lab_page.dart';
import 'ui/settings_page.dart';
import 'ui/trip_page.dart';
import 'ui/alarm_banner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Legacy camera produces the single NV21 plane expected by ML Kit.
  if (Platform.isAndroid) AndroidCamera.registerWith();
  TripRepository? db;
  var settings = AlgorithmSettings();
  var theme = ThemeMode.system;
  var incomplete = false;
  var developerMode = false;
  try {
    db = await TripRepository.open();
    await db.recoverInterrupted();
    final stored = await db.getSetting('algorithm');
    if (stored is Map) {
      settings = AlgorithmSettings.fromJson(Map<String, dynamic>.from(stored));
    }
    final storedTheme = await db.getSetting('theme');
    theme =
        ThemeMode.values.where((t) => t.name == storedTheme).firstOrNull ??
        ThemeMode.system;
    developerMode = await db.getSetting('developer_mode') == true;
  } catch (_) {
    incomplete = true;
  }
  final registry = DetectorRegistry({
    'mlkit_face_detection': MlKitDetector.new,
  });
  final trip = TripController(
    repository: db,
    platform: const PlatformBridge(),
    detector: registry.create('mlkit_face_detection'),
    settings: settings,
  );
  trip.journalIncomplete = incomplete || db == null;
  final sleep = SleepController(trip: trip, platform: const PlatformBridge());
  await sleep.load();
  Directory? documents;
  try {
    documents = await getApplicationDocumentsDirectory();
  } catch (_) {}
  final recordings = documents == null
      ? null
      : Directory('${documents.path}/recordings');
  runApp(
    NSControlApp(
      trip: trip,
      sleep: sleep,
      initialTheme: theme,
      initialDeveloperMode: developerMode,
      createLab: recordings == null
          ? null
          : () => LabController(
              options: labEngineOptions(
                () => registry.create('mlkit_face_detection'),
              ),
              platform: const PlatformBridge(),
              settings: trip.settings,
              recordingsDirectory: recordings,
            ),
    ),
  );
}

class NSControlApp extends StatefulWidget {
  const NSControlApp({
    super.key,
    required this.trip,
    required this.sleep,
    this.initialTheme = ThemeMode.system,
    this.initialDeveloperMode = false,
    this.createLab,
  });
  final TripController trip;
  final SleepController sleep;
  final ThemeMode initialTheme;
  final bool initialDeveloperMode;

  /// Builds the hidden developer lab; null when it is unavailable.
  final LabController Function()? createLab;
  @override
  State<NSControlApp> createState() => _NSControlAppState();
}

class _NSControlAppState extends State<NSControlApp>
    with WidgetsBindingObserver {
  int tab = 0;
  late ThemeMode theme;
  late bool developerMode;
  @override
  void initState() {
    super.initState();
    theme = widget.initialTheme;
    developerMode = widget.initialDeveloperMode;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(widget.trip.foreground(state == AppLifecycleState.resumed));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff126D62),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: brightness == Brightness.light
          ? const Color(0xffF3F6F4)
          : const Color(0xff101815),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .55)),
        ),
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          fontSize: 30,
          fontWeight: FontWeight.w700,
          letterSpacing: -.8,
        ),
        titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(fontSize: 14, height: 1.45),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'NSControl',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: theme,
    home: Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.radar_rounded),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'NSControl',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.4,
                ),
              ),
            ),
          ],
        ),
        actions: [
          Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.only(right: 20),
              child: MediaQuery.sizeOf(context).width < 520
                  ? const Tooltip(
                      message: 'Данные обрабатываются на устройстве',
                      child: Icon(Icons.lock_outline, size: 20),
                    )
                  : const Chip(
                      label: Text('На устройстве'),
                      avatar: Icon(Icons.lock_outline, size: 16),
                    ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            AlarmBanner(trip: widget.trip),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: switch (tab) {
                    0 => TripPage(trip: widget.trip, sleep: widget.sleep),
                    1 => IntegrationsPage(
                      trip: widget.trip,
                      sleep: widget.sleep,
                    ),
                    2 => JournalPage(trip: widget.trip),
                    _ => SettingsPage(
                      trip: widget.trip,
                      themeMode: theme,
                      onTheme: (value) {
                        setState(() => theme = value);
                        widget.trip.journal(
                          (db) => db.setSetting('theme', value.name),
                        );
                      },
                      developerMode: developerMode,
                      onDeveloperMode: (value) {
                        setState(() => developerMode = value);
                        widget.trip.journal(
                          (db) => db.setSetting('developer_mode', value),
                        );
                      },
                      createLab: widget.createLab,
                    ),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route),
            label: 'Поездка',
          ),
          NavigationDestination(
            icon: Icon(Icons.watch_outlined),
            selectedIcon: Icon(Icons.watch),
            label: 'Сон и часы',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'Журнал'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Настройки'),
        ],
      ),
    ),
  );
}

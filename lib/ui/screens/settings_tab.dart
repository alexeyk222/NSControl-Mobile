import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/lab_controller.dart';
import '../../services/sleep_controller.dart';
import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../design/tokens.dart';
import '../integrations_page.dart';
import '../journal_page.dart';
import '../presentation/readiness.dart';
import '../presentation/ui_prefs.dart';
import '../settings_page.dart';
import '../widgets/buttons.dart';
import '../widgets/mount_diagram.dart';
import '../widgets/owl.dart';
import 'common.dart';
import 'home_screen.dart';

/// «Настройки» (design screen 10, copy.md §3.8). «Оформление» comes first
/// and applies at once; the rest follows the groups of the copy. The old
/// detailed screens (thresholds, journal, watch and sleep, lab) stay under
/// «Для разработчика» when developer mode is on.
class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({
    super.key,
    required this.trip,
    required this.sleep,
    required this.prefs,
    required this.developerMode,
    required this.onDeveloperMode,
    this.createLab,
  });
  final TripController trip;
  final SleepController sleep;
  final UiPrefs prefs;
  final bool developerMode;
  final ValueChanged<bool> onDeveloperMode;
  final LabController Function()? createLab;

  @override
  Widget build(BuildContext context) {
    final p = NsTheme.of(context).palette;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const PageHeader(title: Copy.tabSettings),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([trip, sleep, prefs]),
                builder: (context, _) => _SettingsList(
                  trip: trip,
                  sleep: sleep,
                  prefs: prefs,
                  developerMode: developerMode,
                  onDeveloperMode: onDeveloperMode,
                  createLab: createLab,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsList extends StatefulWidget {
  const _SettingsList({
    required this.trip,
    required this.sleep,
    required this.prefs,
    required this.developerMode,
    required this.onDeveloperMode,
    this.createLab,
  });
  final TripController trip;
  final SleepController sleep;
  final UiPrefs prefs;
  final bool developerMode;
  final ValueChanged<bool> onDeveloperMode;
  final LabController Function()? createLab;

  @override
  State<_SettingsList> createState() => _SettingsListState();
}

class _SettingsListState extends State<_SettingsList> {
  // Developer mode can be switched here before the app shell rebuilds.
  late bool dev = widget.developerMode;

  TripController get trip => widget.trip;
  UiPrefs get prefs => widget.prefs;

  void _settings({
    double? volume,
    bool? vibration,
    bool? showPreview,
    bool? hiddenEyes,
    bool? escalate,
  }) => unawaited(
    trip.changeSettings(
      settingsWith(
        trip.settings,
        volume: volume,
        vibration: vibration,
        showPreview: showPreview,
        hiddenEyes: hiddenEyes,
        escalate: escalate,
      ),
    ),
  );

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  static String volumeName(double v) => v >= .99
      ? Copy.volumeMax
      : v >= .7
      ? Copy.volumeLoud
      : Copy.volumeMedium;

  Future<T?> _pick<T>(String title, List<(T, String)> options, T current) {
    final theme = NsTheme.of(context);
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: theme.palette.surface,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.heading()),
              const SizedBox(height: 16),
              for (final (value, label) in options) ...[
                NsOption(
                  label: label,
                  selected: value == current,
                  onTap: () => Navigator.pop(context, value),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteAll() async {
    final ok = await confirmDelete(
      context,
      title: Copy.setDeleteAll,
      body: Copy.setDeleteAllConfirm,
      action: Copy.delete,
    );
    if (!ok) return;
    trip.journal((db) async {
      for (final t in await db.listTrips()) {
        if (t['status'] == 'active') continue;
        await db.deleteTrip(t['id'] as String);
      }
    });
    await trip.pendingWrites;
    _toast('История удалена');
  }

  void _deleteCalibration() {
    trip.journal((db) => db.setSetting('calibration', null));
    prefs.setCameraReady(false);
    _toast('Настройка камеры удалена. Настрою при следующей поездке');
  }

  void _push(String title, Widget body) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(child: body),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    final s = trip.settings;
    final side = MountSide.parse(trip.mountPosition);
    final watch = WatchReadiness.of(trip);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      children: [
        const GroupLabel(Copy.setDesign),
        RowGroup(
          children: [
            for (final d in NsDesign.values)
              _DesignRow(
                design: d,
                selected: prefs.design == d,
                locked: trip.active,
                onTap: () => prefs.setDesign(d),
              ),
          ],
        ),
        if (trip.active)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(Copy.setDesignLocked, style: theme.caption(p.text2)),
          ),
        const SizedBox(height: 12),
        NsSegmented<ThemeMode>(
          values: const [ThemeMode.system, ThemeMode.dark, ThemeMode.light],
          labels: const [Copy.themeSystem, Copy.themeDark, Copy.themeLight],
          selected: prefs.themeMode,
          onChanged: prefs.setThemeMode,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text(
            '${Copy.setTheme}. В пути экран всегда тёмный',
            style: theme.caption(p.text2),
          ),
        ),

        const GroupLabel(Copy.setMount),
        RowGroup(
          children: [
            NsRow(
              label: Copy.setMountSide,
              value: side.label,
              onTap: () async {
                final v = await _pick(Copy.setMountSide, [
                  for (final m in MountSide.values) (m, m.label),
                ], side);
                if (v == null) return;
                trip.mountPosition = v.code;
                trip.journal((db) => db.setSetting('trip_mount', v.code));
                setState(() {});
              },
            ),
            NsRow(
              label: Copy.setRecal,
              accent: true,
              onTap: _deleteCalibration,
            ),
            NsRow(
              label: Copy.setPreview,
              toggle: s.showPreview,
              onToggle: (v) => _settings(showPreview: v),
            ),
          ],
        ),

        const GroupLabel(Copy.setSound),
        RowGroup(
          children: [
            NsRow(
              label: Copy.setVolume,
              value: volumeName(s.volume),
              onTap: () async {
                final v = await _pick(Copy.setVolume, const [
                  (1.0, Copy.volumeMax),
                  (.8, Copy.volumeLoud),
                  (.6, Copy.volumeMedium),
                ], s.volume >= .99 ? 1.0 : (s.volume >= .7 ? .8 : .6));
                if (v != null) _settings(volume: v);
              },
            ),
            NsRow(
              label: Copy.setVoice,
              toggle: prefs.voice,
              onToggle: prefs.setVoice,
            ),
            NsRow(
              label: Copy.setEscalate,
              toggle: s.escalate,
              onToggle: (v) => _settings(escalate: v),
            ),
            NsRow(
              label: Copy.setVibrate,
              toggle: s.vibration,
              onToggle: (v) => _settings(vibration: v),
            ),
            NsRow(
              label: Copy.setTestSound,
              accent: true,
              enabled: !trip.active,
              onTap: () => unawaited(trip.testAlert()),
            ),
          ],
        ),

        const GroupLabel(Copy.setWatch),
        RowGroup(
          children: [
            NsRow(
              label: switch (watch) {
                WatchReadiness.ready => Copy.readyWatchOk,
                WatchReadiness.closed => Copy.readyWatchClosed,
                WatchReadiness.missing => Copy.readyWatchMissing,
                WatchReadiness.none => Copy.readyWatchOff,
              },
              value: trip.watchBackgroundText,
            ),
            NsRow(
              label: Copy.setWatchTest,
              accent: true,
              enabled: watch == WatchReadiness.ready,
              onTap: () {
                unawaited(trip.testWatch());
                _toast(Copy.testSent);
              },
            ),
            NsRow(
              label: Copy.setWatchDetails,
              onTap: () => _push(
                Copy.setWatchDetails,
                IntegrationsPage(trip: trip, sleep: widget.sleep),
              ),
            ),
          ],
        ),

        const GroupLabel(Copy.setSleep),
        RowGroup(
          children: [
            NsRow(
              label: Copy.setSleepSource,
              value: widget.sleep.enabled
                  ? Copy.setSleepSourceValue
                  : Copy.readySleepNone,
              onTap: () => unawaited(
                widget.sleep.enabled
                    ? widget.sleep.refresh()
                    : widget.sleep.authorize(),
              ),
            ),
          ],
        ),

        const GroupLabel(Copy.setDetect),
        RowGroup(
          children: [
            NsRow(
              label: Copy.setGlasses,
              toggle: s.hiddenEyes,
              onToggle: (v) => _settings(hiddenEyes: v),
            ),
            NsRow(
              label: Copy.setBreak,
              value: breakInterval(Duration(minutes: prefs.breakMinutes)),
              // The rules take the interval when a trip starts.
              enabled: !trip.active,
              onTap: () async {
                final v = await _pick(Copy.setBreak, [
                  for (final m in UiPrefs.breakChoices)
                    (m, breakInterval(Duration(minutes: m))),
                ], prefs.breakMinutes);
                if (v != null) prefs.setBreakMinutes(v);
              },
            ),
          ],
        ),

        const GroupLabel(Copy.setData),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(Copy.setDataWhat, style: theme.caption(p.text2)),
        ),
        RowGroup(
          children: [
            NsRow(
              label: Copy.setDeleteAll,
              enabled: trip.repository != null,
              onTap: _deleteAll,
            ),
            NsRow(label: Copy.setDeleteCal, onTap: _deleteCalibration),
          ],
        ),

        const GroupLabel(Copy.setAbout),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Owl(size: 40, blink: false),
              const SizedBox(width: 12),
              Expanded(
                child: Text(Copy.setLimits, style: theme.caption(p.text2)),
              ),
            ],
          ),
        ),
        RowGroup(
          children: [
            NsRow(
              label: Copy.setDev,
              toggle: dev,
              onToggle: (v) {
                setState(() => dev = v);
                widget.onDeveloperMode(v);
              },
            ),
            if (dev) ...[
              NsRow(
                label: Copy.setDevTools,
                onTap: () => _push(
                  Copy.setDevTools,
                  SettingsPage(
                    trip: trip,
                    themeMode: prefs.themeMode,
                    onTheme: prefs.setThemeMode,
                    developerMode: true,
                    onDeveloperMode: (v) {
                      setState(() => dev = v);
                      widget.onDeveloperMode(v);
                    },
                    createLab: widget.createLab,
                  ),
                ),
              ),
              NsRow(
                label: 'Журнал и выгрузка',
                onTap: () => _push('Журнал', JournalPage(trip: trip)),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// A look in «Оформление»: its name, a small indicator in its own form and
/// «Выбрано». Applies at once; the whole app cross-fades to it.
class _DesignRow extends StatelessWidget {
  const _DesignRow({
    required this.design,
    required this.selected,
    required this.locked,
    required this.onTap,
  });
  final NsDesign design;
  final bool selected, locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    final look = NsLook.of(design);
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        key: Key('design-${design.name}'),
        onTap: locked ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  design.title,
                  style: TextStyle(
                    fontFamily: look.fontFamily,
                    fontSize: 17,
                    fontWeight: look.type.title.weight,
                    color: p.text,
                  ),
                ),
              ),
              AnimatedOpacity(
                duration: NsMotion.quick,
                opacity: selected ? 1 : 0,
                child: Text(
                  Copy.setDesignChosen,
                  style: theme.caption(p.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

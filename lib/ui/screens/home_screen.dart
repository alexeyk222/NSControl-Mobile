import 'package:flutter/material.dart';

import '../../services/lab_controller.dart';
import '../../services/sleep_controller.dart';
import '../../services/trip_controller.dart';
import '../copy.dart';
import '../design/ns_theme.dart';
import '../presentation/ui_prefs.dart';
import 'history_tab.dart';
import 'pre_trip_tab.dart';
import 'settings_tab.dart';

/// Outside a trip (design screen 4): the pre-trip page with «История» and
/// «Настройки» as text links on top; they open as pages with «‹ Назад».
/// There is no bottom bar: the app is a single path to «Поехали».
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.trip,
    required this.sleep,
    required this.prefs,
    required this.developerMode,
    required this.onDeveloperMode,
    required this.onStart,
    this.createLab,
  });
  final TripController trip;
  final SleepController sleep;
  final UiPrefs prefs;
  final bool developerMode;
  final ValueChanged<bool> onDeveloperMode;

  /// «Поехали».
  final VoidCallback onStart;
  final LabController Function()? createLab;

  void _open(BuildContext context, Widget Function() page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page()));

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    Widget link(String label, VoidCallback onTap, Key key) => Semantics(
      button: true,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Text(label, style: theme.body(p.text)),
        ),
      ),
    );
    return ColoredBox(
      color: p.bg,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 18, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(Copy.tabPre, style: theme.body(p.text2)),
                    ),
                  ),
                  link(
                    Copy.tabHistory,
                    () => _open(context, () => HistoryPage(trip: trip)),
                    const Key('open-history'),
                  ),
                  const SizedBox(width: 12),
                  link(
                    Copy.tabSettings,
                    () => _open(
                      context,
                      () => AppSettingsPage(
                        trip: trip,
                        sleep: sleep,
                        prefs: prefs,
                        developerMode: developerMode,
                        onDeveloperMode: onDeveloperMode,
                        createLab: createLab,
                      ),
                    ),
                    const Key('open-settings'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PreTripTab(
                trip: trip,
                sleep: sleep,
                prefs: prefs,
                onStart: onStart,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header of a pushed page: «‹ Назад» (or the parent's name) and the title.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.back = Copy.back});
  final String title, back;

  @override
  Widget build(BuildContext context) {
    final theme = NsTheme.of(context);
    final p = theme.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: back,
            excludeSemantics: true,
            child: InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Text('‹ $back', style: theme.body(p.text2)),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Semantics(
              header: true,
              child: Text(title, style: theme.title()),
            ),
          ),
        ],
      ),
    );
  }
}

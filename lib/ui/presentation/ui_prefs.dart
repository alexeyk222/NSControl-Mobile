import 'package:flutter/material.dart';

import '../../data/trip_repository.dart' hide Row;
import '../design/tokens.dart';

/// Interface choices of the driver, kept in the journal's settings table
/// next to the algorithm settings (keys below). The trip logic does not
/// read them, except the mount side, which [TripController.mountPosition]
/// owns and the screens write through.
///
/// | key                | value                                  |
/// |--------------------|----------------------------------------|
/// | `ui_design`        | `cockpit` / `companion` / `roadsign`   |
/// | `theme`            | `system` / `dark` / `light` (outside a trip) |
/// | `ui_onboarded`     | onboarding finished                    |
/// | `ui_camera_ready`  | the camera was set up at least once    |
/// | `ui_voice`         | voice prompts of the interface         |
class UiPrefs extends ChangeNotifier {
  UiPrefs({
    this.design = NsDesign.cockpit,
    this.themeMode = ThemeMode.dark,
    this.onboarded = false,
    this.cameraReady = false,
    this.voice = true,
    this.save,
  });

  /// Reads the stored choices; missing keys keep the defaults (first run:
  /// look A, dark theme, voice on).
  static Future<UiPrefs> load(
    TripRepository? db, {
    required void Function(Future<void> Function(TripRepository)) save,
  }) async {
    final prefs = UiPrefs(save: save);
    if (db == null) return prefs;
    try {
      prefs.design = NsDesign.parse(await db.getSetting('ui_design'));
      final theme = await db.getSetting('theme');
      prefs.themeMode =
          ThemeMode.values.where((t) => t.name == theme).firstOrNull ??
          ThemeMode.dark;
      prefs.onboarded = await db.getSetting('ui_onboarded') == true;
      prefs.cameraReady =
          await db.getSetting('ui_camera_ready') == true ||
          await db.getSetting('calibration') != null;
      prefs.voice = await db.getSetting('ui_voice') != false;
    } catch (_) {
      // A broken journal must not stop the app: defaults it is.
    }
    return prefs;
  }

  NsDesign design;
  ThemeMode themeMode;
  bool onboarded, cameraReady, voice;

  /// Writes one setting through the trip controller's journal queue.
  final void Function(Future<void> Function(TripRepository))? save;

  void _set(String key, Object? value) {
    save?.call((db) => db.setSetting(key, value));
    notifyListeners();
  }

  void setDesign(NsDesign v) {
    if (v == design) return;
    design = v;
    _set('ui_design', v.name);
  }

  void setThemeMode(ThemeMode v) {
    themeMode = v;
    _set('theme', v.name);
  }

  void setOnboarded() {
    onboarded = true;
    _set('ui_onboarded', true);
  }

  void setCameraReady(bool v) {
    if (v == cameraReady) return;
    cameraReady = v;
    _set('ui_camera_ready', v);
  }

  void setVoice(bool v) {
    voice = v;
    _set('ui_voice', v);
  }
}

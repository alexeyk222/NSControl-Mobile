import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'tokens.dart';

/// The current look for widgets: palette of the current brightness, the
/// always-dark trip palette and the look's type, radii and motion.
///
/// Read it with `NsTheme.of(context)`. The app installs it through
/// [buildNsTheme]; switching the look in settings rebuilds `MaterialApp`
/// with a new extension and `AnimatedTheme` cross-fades the colours.
@immutable
class NsTheme extends ThemeExtension<NsTheme> {
  const NsTheme({required this.look, required this.palette});

  final NsLook look;

  /// Palette of the current brightness (screens outside a trip).
  final NsPalette palette;

  /// The trip, camera and alarm screens are always dark (BACKEND.md §3).
  NsPalette get trip => look.dark;
  NsDesign get design => look.design;
  String get font => look.fontFamily;
  NsRadii get radii => look.radii;

  static NsTheme of(BuildContext context) =>
      Theme.of(context).extension<NsTheme>() ??
      NsTheme(look: NsLook.cockpit, palette: NsLook.cockpit.dark);

  // Text styles of the type scale in the given colour (the palette's text
  // colour by default).
  TextStyle alarm([Color? c]) =>
      look.type.alarm.style(font, color: c ?? NsColors.onAlarm);
  TextStyle tripStatus([Color? c]) => look.type.tripStatus.style(
    font,
    color: c ?? trip.text,
    letterSpacing: -.5,
  );
  TextStyle verdict([Color? c]) => look.type.verdict.style(
    font,
    color: c ?? palette.text,
    letterSpacing: -.4,
  );
  TextStyle title([Color? c]) =>
      look.type.title.style(font, color: c ?? palette.text, letterSpacing: -.4);
  TextStyle heading([Color? c]) => look.type.heading.style(
    font,
    color: c ?? palette.text,
    letterSpacing: -.2,
  );
  TextStyle body([Color? c]) =>
      look.type.body.style(font, color: c ?? palette.text);
  TextStyle caption([Color? c]) =>
      look.type.caption.style(font, color: c ?? palette.text2);

  /// Text of a large button (22 pt, the look's title weight).
  TextStyle button([Color? c]) => TextStyle(
    fontFamily: font,
    fontSize: 22,
    height: 1.1,
    fontWeight: look.type.title.weight,
    color: c ?? palette.onAccent,
  );

  /// Text of a secondary button (18 pt).
  TextStyle buttonSmall([Color? c]) => TextStyle(
    fontFamily: font,
    fontSize: 18,
    height: 1.15,
    fontWeight: look.type.body.weight == FontWeight.w400
        ? FontWeight.w500
        : FontWeight.w600,
    color: c ?? palette.text,
  );

  @override
  NsTheme copyWith({NsLook? look, NsPalette? palette}) =>
      NsTheme(look: look ?? this.look, palette: palette ?? this.palette);

  @override
  NsTheme lerp(NsTheme? other, double t) {
    if (other == null) return this;
    // Colours fade; the look (shapes, fonts) switches at the midpoint.
    return NsTheme(
      look: t < .5 ? look : other.look,
      palette: _lerpPalette(palette, other.palette, t),
    );
  }

  static NsPalette _lerpPalette(NsPalette a, NsPalette b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t)!;
    return NsPalette(
      brightness: t < .5 ? a.brightness : b.brightness,
      bgTrip: c(a.bgTrip, b.bgTrip),
      bg: c(a.bg, b.bg),
      surface: c(a.surface, b.surface),
      surface2: c(a.surface2, b.surface2),
      line: c(a.line, b.line),
      text: c(a.text, b.text),
      text2: c(a.text2, b.text2),
      accent: c(a.accent, b.accent),
      onAccent: c(a.onAccent, b.onAccent),
      attention: c(a.attention, b.attention),
      advice: c(a.advice, b.advice),
      pause: c(a.pause, b.pause),
      track: c(a.track, b.track),
      indicatorPause: c(a.indicatorPause, b.indicatorPause),
      indicatorIdle: c(a.indicatorIdle, b.indicatorIdle),
    );
  }
}

/// Material theme of a look. Material widgets that remain (dialogs, the
/// developer screens, switches) take the look's colours; the main screens
/// draw with [NsTheme] directly.
ThemeData buildNsTheme(NsDesign design, Brightness brightness) {
  final look = NsLook.of(design);
  final p = look.palette(brightness);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    // Material "error" is used by forms and destructive dialogs only; the
    // alarm red is drawn explicitly by the alarm screen.
    error: brightness == Brightness.dark
        ? const Color(0xFFFFB4AB)
        : const Color(0xFF8C1D18),
    onError: brightness == Brightness.dark
        ? const Color(0xFF690005)
        : Colors.white,
    surface: p.bg,
    onSurface: p.text,
    onSurfaceVariant: p.text2,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surface2,
    surfaceContainerHighest: p.surface2,
    outline: p.text2,
    outlineVariant: p.line,
    tertiary: p.advice,
    onTertiary: p.onAccent,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: look.fontFamily,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    splashFactory: InkSparkle.splashFactory,
    extensions: [NsTheme(look: look, palette: p)],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: look.fontFamily,
      bodyColor: p.text,
      displayColor: p.text,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: look.type.heading.style(look.fontFamily, color: p.text),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(look.radii.card),
      ),
    ),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : p.text2,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.track,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(look.radii.card),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surface2,
      contentTextStyle: look.type.body.style(look.fontFamily, color: p.text),
      behavior: SnackBarBehavior.floating,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(look.radii.secondaryButton),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 52),
        foregroundColor: p.text,
        side: BorderSide(color: p.line),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(look.radii.secondaryButton),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.accent),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

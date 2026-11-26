/// Design tokens of the three NSControl looks (design handoff 25.11.2026,
/// `tokens.json`): A «Ночной кокпит», B «Спокойный компаньон», C «Дорожный
/// знак». Colours, type, radii and motion are final (hi-fi); change them here
/// only together with the design.
///
/// Rules carried by the tokens (docs/ux/ux-spec.md §3):
/// * red ([NsColors.alarm]) appears only on the alarm screen (П3);
/// * the normal state is the look's accent, never green (П3);
/// * the trip screen and the alarm are always dark, the light palette is
///   used only outside a trip.
library;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show Brightness;

/// The look chosen in «Настройки → Оформление».
enum NsDesign {
  cockpit('A · Ночной кокпит', 'Ночной кокпит'),
  companion('B · Спокойный компаньон', 'Спокойный компаньон'),
  roadsign('C · Дорожный знак', 'Дорожный знак');

  const NsDesign(this.code, this.title);

  /// Name with the letter, for developer screens and the watch.
  final String code;

  /// Name shown in settings.
  final String title;

  static NsDesign parse(Object? value) =>
      NsDesign.values.where((d) => d.name == value).firstOrNull ??
      NsDesign.cockpit;
}

/// Colours shared by every look.
abstract final class NsColors {
  /// The only red of the app: the alarm background.
  static const alarm = Color(0xFFC8161D);
  static const onAlarm = Color(0xFFFFFFFF);

  /// Background of the soft alarm («Смотрите на дорогу»): dark with a red
  /// frame instead of a red fill.
  static const softAlarm = Color(0xFF1A0405);

  /// Attention (yellow) and advice (amber) on the dark trip screen.
  static const attentionOnDark = Color(0xFFF2D04B);
  static const adviceOnDark = Color(0xFFF2A33A);
}

/// One palette (dark or light) of a look.
class NsPalette {
  const NsPalette({
    required this.bgTrip,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.text,
    required this.text2,
    required this.accent,
    required this.onAccent,
    required this.attention,
    required this.advice,
    required this.pause,
    required this.track,
    required this.indicatorPause,
    required this.indicatorIdle,
    required this.brightness,
  });

  /// Background of the trip and camera screens (dark palettes only).
  final Color bgTrip;
  final Color bg, surface, surface2, line, text, text2;

  /// Normal state and primary buttons.
  final Color accent, onAccent;

  /// Yellow «внимание» (protection weakened) and amber «совет».
  final Color attention, advice;

  /// Paused segments of the history and the inactive switch track.
  final Color pause, track;

  /// Strokes of the status indicator in the pause and idle states.
  final Color indicatorPause, indicatorIdle;
  final Brightness brightness;

  bool get isDark => brightness == Brightness.dark;
}

/// A text style token: size, line height and weight in pt.
class NsTypeToken {
  const NsTypeToken(this.size, this.lineHeight, this.weight);
  final double size, lineHeight;
  final FontWeight weight;

  TextStyle style(String family, {Color? color, double letterSpacing = 0}) =>
      TextStyle(
        fontFamily: family,
        fontSize: size,
        height: lineHeight / size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
      );
}

/// Type scale of a look (`[size, line height, weight]` in tokens.json).
class NsTypeScale {
  const NsTypeScale({
    required this.alarm,
    required this.tripStatus,
    required this.verdict,
    required this.title,
    required this.heading,
    required this.body,
    required this.caption,
  });
  final NsTypeToken alarm, tripStatus, verdict, title, heading, body, caption;
}

/// Corner radii of a look.
class NsRadii {
  const NsRadii({
    required this.button,
    required this.secondaryButton,
    required this.card,
    required this.chip,
    required this.option,
  });
  final double button, secondaryButton, card, chip, option;
}

/// Everything that differs between the looks.
class NsLook {
  const NsLook({
    required this.design,
    required this.fontFamily,
    required this.dark,
    required this.light,
    required this.type,
    required this.radii,
    required this.breathes,
    required this.breatheOpacity,
    required this.breatheScale,
  });

  final NsDesign design;
  final String fontFamily;
  final NsPalette dark, light;
  final NsTypeScale type;
  final NsRadii radii;

  /// The «Слежу» indicator breathes (A, B); C stays still.
  final bool breathes;

  /// Breathing range: opacity and scale go from these values to 1.
  final double breatheOpacity, breatheScale;

  NsPalette palette(Brightness b) => b == Brightness.dark ? dark : light;

  static NsLook of(NsDesign design) => switch (design) {
    NsDesign.cockpit => cockpit,
    NsDesign.companion => companion,
    NsDesign.roadsign => roadsign,
  };

  static const cockpit = NsLook(
    design: NsDesign.cockpit,
    fontFamily: 'Geologica',
    breathes: true,
    breatheOpacity: .45,
    breatheScale: .965,
    radii: NsRadii(
      button: 22,
      secondaryButton: 20,
      card: 18,
      chip: 17,
      option: 18,
    ),
    type: NsTypeScale(
      alarm: NsTypeToken(96, 94, FontWeight.w800),
      tripStatus: NsTypeToken(56, 59, FontWeight.w600),
      verdict: NsTypeToken(36, 40, FontWeight.w600),
      title: NsTypeToken(34, 37, FontWeight.w600),
      heading: NsTypeToken(26, 30, FontWeight.w600),
      body: NsTypeToken(17, 24, FontWeight.w400),
      caption: NsTypeToken(15, 20, FontWeight.w400),
    ),
    dark: NsPalette(
      brightness: Brightness.dark,
      bgTrip: Color(0xFF000000),
      bg: Color(0xFF0B0D0F),
      surface: Color(0xFF15181B),
      surface2: Color(0xFF1E2226),
      line: Color(0xFF262B30),
      text: Color(0xFFE9EEF2),
      text2: Color(0xFF9BA6B0),
      accent: Color(0xFF7CC8E8),
      onAccent: Color(0xFF071116),
      attention: Color(0xFFF2D04B),
      advice: Color(0xFFF2A33A),
      pause: Color(0xFF4A525A),
      track: Color(0xFF2E343A),
      indicatorPause: Color(0xFF8A949D),
      indicatorIdle: Color(0xFF5E6870),
    ),
    light: NsPalette(
      brightness: Brightness.light,
      bgTrip: Color(0xFF000000),
      bg: Color(0xFFF3F4F5),
      surface: Color(0xFFFFFFFF),
      surface2: Color(0xFFE6E9EC),
      line: Color(0xFFD9DDE0),
      text: Color(0xFF0E1114),
      text2: Color(0xFF525C65),
      accent: Color(0xFF0F6E93),
      onAccent: Color(0xFFFFFFFF),
      attention: Color(0xFF7A5E00),
      advice: Color(0xFF9A5200),
      pause: Color(0xFFB5BCC2),
      track: Color(0xFFCDD2D6),
      indicatorPause: Color(0xFF8A949D),
      indicatorIdle: Color(0xFFB5BCC2),
    ),
  );

  static const companion = NsLook(
    design: NsDesign.companion,
    fontFamily: 'Nunito',
    breathes: true,
    breatheOpacity: .75,
    breatheScale: .94,
    radii: NsRadii(
      button: 38,
      secondaryButton: 34,
      card: 24,
      chip: 17,
      option: 26,
    ),
    type: NsTypeScale(
      alarm: NsTypeToken(96, 94, FontWeight.w900),
      tripStatus: NsTypeToken(56, 59, FontWeight.w700),
      verdict: NsTypeToken(36, 40, FontWeight.w700),
      title: NsTypeToken(34, 37, FontWeight.w700),
      heading: NsTypeToken(26, 30, FontWeight.w700),
      body: NsTypeToken(17, 24, FontWeight.w500),
      caption: NsTypeToken(15, 20, FontWeight.w500),
    ),
    dark: NsPalette(
      brightness: Brightness.dark,
      bgTrip: Color(0xFF0E0C10),
      bg: Color(0xFF141116),
      surface: Color(0xFF211D25),
      surface2: Color(0xFF2B2630),
      line: Color(0xFF342E3A),
      text: Color(0xFFF4EFF4),
      text2: Color(0xFFB0A6B5),
      accent: Color(0xFFC9B8F5),
      onAccent: Color(0xFF071116),
      attention: Color(0xFFF2D04B),
      advice: Color(0xFFF2A33A),
      pause: Color(0xFF564D5C),
      track: Color(0xFF3A3340),
      indicatorPause: Color(0xFFA49AA9),
      indicatorIdle: Color(0xFF6E6575),
    ),
    light: NsPalette(
      brightness: Brightness.light,
      bgTrip: Color(0xFF0E0C10),
      bg: Color(0xFFF6F2F4),
      surface: Color(0xFFFFFFFF),
      surface2: Color(0xFFECE6EA),
      line: Color(0xFFE2DAE0),
      text: Color(0xFF1A1420),
      text2: Color(0xFF5E5464),
      accent: Color(0xFF6347C2),
      onAccent: Color(0xFFFFFFFF),
      attention: Color(0xFF7A5E00),
      advice: Color(0xFF9A5200),
      pause: Color(0xFFC4BAC2),
      track: Color(0xFFD8CFD6),
      indicatorPause: Color(0xFFA49AA9),
      indicatorIdle: Color(0xFFC4BAC2),
    ),
  );

  static const roadsign = NsLook(
    design: NsDesign.roadsign,
    fontFamily: 'Onest',
    breathes: false,
    breatheOpacity: 1,
    breatheScale: 1,
    radii: NsRadii(
      button: 12,
      secondaryButton: 12,
      card: 12,
      chip: 17,
      option: 12,
    ),
    type: NsTypeScale(
      alarm: NsTypeToken(96, 94, FontWeight.w900),
      tripStatus: NsTypeToken(76, 76, FontWeight.w800),
      verdict: NsTypeToken(44, 46, FontWeight.w800),
      title: NsTypeToken(34, 37, FontWeight.w700),
      heading: NsTypeToken(26, 30, FontWeight.w700),
      body: NsTypeToken(18, 25, FontWeight.w500),
      caption: NsTypeToken(15, 20, FontWeight.w500),
    ),
    dark: NsPalette(
      brightness: Brightness.dark,
      bgTrip: Color(0xFF000000),
      bg: Color(0xFF0A0A0A),
      surface: Color(0xFF1A1A1A),
      surface2: Color(0xFF242424),
      line: Color(0xFF2E2E2E),
      text: Color(0xFFFFFFFF),
      text2: Color(0xFFB3B3B3),
      accent: Color(0xFF5B9BF0),
      onAccent: Color(0xFF071116),
      attention: Color(0xFFF2D04B),
      advice: Color(0xFFF2A33A),
      pause: Color(0xFF555555),
      track: Color(0xFF3A3A3A),
      indicatorPause: Color(0xFFA0A0A0),
      indicatorIdle: Color(0xFF6A6A6A),
    ),
    light: NsPalette(
      brightness: Brightness.light,
      bgTrip: Color(0xFF000000),
      bg: Color(0xFFF2F2F0),
      surface: Color(0xFFFFFFFF),
      surface2: Color(0xFFE4E4E2),
      line: Color(0xFFD4D4D2),
      text: Color(0xFF000000),
      text2: Color(0xFF4F4F4F),
      accent: Color(0xFF0B57C8),
      onAccent: Color(0xFFFFFFFF),
      attention: Color(0xFF7A5E00),
      advice: Color(0xFF9A5200),
      pause: Color(0xFFB0B0B0),
      track: Color(0xFFC8C8C6),
      indicatorPause: Color(0xFFA0A0A0),
      indicatorIdle: Color(0xFFB0B0B0),
    ),
  );
}

/// Motion tokens (tokens.json → `motion`).
abstract final class NsMotion {
  /// The «Слежу» indicator breathes once per [breathe] (ease-in-out).
  static const breathe = Duration(seconds: 6);

  /// The trip screen dims to [dimOpacity] after [dimAfter] without touches.
  static const dimAfter = Duration(seconds: 8);
  static const dimOpacity = .6;

  /// «Завершить» fires after holding for [holdToFinish].
  static const holdToFinish = Duration(milliseconds: 1200);

  /// The alarm pulses its brightness at 1 Hz (×1.18) only after 5 s
  /// without a reaction, and fades out in [alarmFadeOut].
  static const alarmPulse = Duration(seconds: 1);
  static const alarmPulseBrightness = 1.18;
  static const alarmFadeIn = Duration(milliseconds: 250);
  static const alarmFadeOut = Duration(milliseconds: 500);

  /// Calibration ring: 60 ticks; a light runs around in [calSweep] while
  /// searching, the ticks fill in [calCapture], a check draws in [calDone].
  static const calTicks = 60;
  static const calSweep = Duration(milliseconds: 1600);
  static const calCapture = Duration(seconds: 5);
  static const calDone = Duration(milliseconds: 500);

  /// The voice line bubble (B) stays this long.
  static const voiceBubble = Duration(milliseconds: 4500);

  /// The owl blinks once per [owlBlink].
  static const owlBlink = Duration(milliseconds: 4500);

  /// Page transitions and state changes.
  static const page = Duration(milliseconds: 420);
  static const state = Duration(milliseconds: 360);
  static const quick = Duration(milliseconds: 200);
}

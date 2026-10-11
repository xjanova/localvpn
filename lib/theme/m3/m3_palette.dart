import 'package:flutter/material.dart';

/// Millennium 3D colour tokens — the same two palettes as Anti X
/// (night = deep navy glass, sky = bright Aero glass). Every widget reads
/// colours from here through `context.m3`, so switching theme repaints the
/// whole app.
@immutable
class M3Palette extends ThemeExtension<M3Palette> {
  const M3Palette({
    required this.isNight,
    required this.wallpaper,
    required this.bg,
    required this.bg2,
    required this.winShade,
    required this.titleFill,
    required this.sideFill,
    required this.glassFill,
    required this.glassFillHi,
    required this.glassLine,
    required this.headerBg,
    required this.drawerFill,
    required this.glassBtn,
    required this.wordmark,
    required this.wordmarkAccent,
    required this.card,
    required this.card2,
    required this.inset,
    required this.line,
    required this.hover,
    required this.select,
    required this.row,
    required this.track,
    required this.thumb,
    required this.input,
    required this.inputLine,
    required this.popup,
    required this.popupLine,
    required this.scrim,
    required this.text,
    required this.text2,
    required this.text3,
    required this.numText,
    required this.gold,
    required this.cyan,
    required this.red,
    required this.amber,
    required this.green,
    required this.orange,
    required this.violet,
    required this.redSoft,
    required this.redSoftLine,
    required this.redText,
    required this.amberSoft,
    required this.amberSoftLine,
    required this.amberText,
    required this.greenSoft,
    required this.greenSoftLine,
    required this.greenText,
    required this.cyanSoft,
    required this.cyanSoftLine,
    required this.cyanText,
    required this.glassBtnText,
    required this.numGlow,
    required this.numGlowRed,
    required this.titleShadow,
    required this.cardShadow,
    required this.logoGlow,
  });

  final bool isNight;
  final String wallpaper;

  // Ground
  final Color bg;
  final Color bg2;
  final Color winShade;
  final LinearGradient titleFill;
  final LinearGradient sideFill;

  // Glass
  final LinearGradient glassFill;
  final LinearGradient glassFillHi;
  final LinearGradient glassLine;
  final LinearGradient headerBg;
  final LinearGradient drawerFill;
  final LinearGradient glassBtn;
  final LinearGradient wordmark;
  final LinearGradient wordmarkAccent;
  final Color card;
  final Color card2;
  final Color inset;
  final Color line;
  final Color hover;
  final Color select;
  final Color row;
  final Color track;
  final Color thumb;
  final Color input;
  final Color inputLine;
  final Color popup;
  final Color popupLine;
  final Color scrim;

  // Text and accents
  final Color text;
  final Color text2;
  final Color text3;
  final Color numText;
  final Color gold;
  final Color cyan;
  final Color red;
  final Color amber;
  final Color green;
  final Color orange;
  final Color violet;

  // Soft status fills (tags, banners)
  final Color redSoft;
  final Color redSoftLine;
  final Color redText;
  final Color amberSoft;
  final Color amberSoftLine;
  final Color amberText;
  final Color greenSoft;
  final Color greenSoftLine;
  final Color greenText;
  final Color cyanSoft;
  final Color cyanSoftLine;
  final Color cyanText;

  final Color glassBtnText;
  final List<Shadow> numGlow;
  final List<Shadow> numGlowRed;
  final List<Shadow> titleShadow;
  final List<BoxShadow> cardShadow;
  final Color logoGlow;

  static const M3Palette night = M3Palette(
    isNight: true,
    wallpaper: 'assets/m3/bg-night.webp',
    bg: Color(0xFF050A1C),
    bg2: Color(0xFF0A1430),
    winShade: Color(0x3A030818),
    titleFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xB328468C), Color(0xD9060E28)],
    ),
    sideFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x803C6EC8), Color(0xE3081434), Color(0xEB040A20)],
      stops: [0, 0.3, 1],
    ),
    glassFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      // More opaque than Anti X's WPF values: Flutter cards here sit on a
      // brighter wallpaper and the light top band washed out muted text.
      colors: [
        Color(0xA62A4C88),
        Color(0xC8132A5E),
        Color(0xD20E2052),
        Color(0xEE040A20),
      ],
      stops: [0, 0.4, 0.42, 1],
    ),
    glassFillHi: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xA64F7FC9), Color(0xD8132A62), Color(0xF4050C26)],
      stops: [0, 0.5, 1],
    ),
    glassLine: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xB3C6E6FF), Color(0x557FB2E8), Color(0x406493D0)],
      stops: [0, 0.45, 1],
    ),
    headerBg: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x4D5A8CE6), Color(0x33162A60)],
    ),
    drawerFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xF2132654), Color(0xFA050C24)],
    ),
    glassBtn: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0x803F6CC0),
        Color(0xD9122560),
        Color(0xEB060E28),
        Color(0xE60E1E50),
      ],
      stops: [0, 0.49, 0.5, 1],
    ),
    wordmark: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFFFFFFFF),
        Color(0xFFDDE6EE),
        Color(0xFF8C9AA8),
        Color(0xFFE9F1F7),
        Color(0xFFA7B2BD),
      ],
      stops: [0, 0.4, 0.52, 0.72, 1],
    ),
    wordmarkAccent: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFFE9FDFF),
        Color(0xFF5EE3F7),
        Color(0xFF0FA0D2),
        Color(0xFF7BEAFF),
      ],
      stops: [0, 0.48, 0.52, 1],
    ),
    card: Color(0xFF0E1A3C),
    card2: Color(0xFF142250),
    inset: Color(0x59050C26),
    line: Color(0x4D7FAFE6),
    hover: Color(0x3360A4FF),
    select: Color(0x4D38D9F5),
    row: Color(0x0D96C8FF),
    track: Color(0x2E7FB3FF),
    thumb: Color(0x805C7FC0),
    input: Color(0xA6050C26),
    inputLine: Color(0x6B5A8CD0),
    popup: Color(0xF50B1638),
    popupLine: Color(0x8C5A9CE0),
    scrim: Color(0xA6020612),
    text: Color(0xFFEAF4FF),
    text2: Color(0xFFA9C3E6),
    text3: Color(0xFF7A94BF),
    numText: Color(0xFFF2F8FF),
    gold: Color(0xFFF2C75C),
    cyan: Color(0xFF38D9F5),
    red: Color(0xFFFF6070),
    amber: Color(0xFFFFB547),
    green: Color(0xFF3EE08A),
    orange: Color(0xFFF6821F),
    violet: Color(0xFFA79BFF),
    redSoft: Color(0x2EFF4D5E),
    redSoftLine: Color(0x8CFF4D5E),
    redText: Color(0xFFFFC2C8),
    amberSoft: Color(0x26FFB547),
    amberSoftLine: Color(0x8CFFB547),
    amberText: Color(0xFFFFE2A8),
    greenSoft: Color(0x2635D07F),
    greenSoftLine: Color(0x8035D07F),
    greenText: Color(0xFFB8F5D2),
    cyanSoft: Color(0x2438D9F5),
    cyanSoftLine: Color(0x8038D9F5),
    cyanText: Color(0xFFBFF6FF),
    glassBtnText: Color(0xFFEAF4FF),
    numGlow: [Shadow(color: Color(0x8C38D9F5), blurRadius: 16)],
    numGlowRed: [Shadow(color: Color(0x99FF4D5E), blurRadius: 16)],
    titleShadow: [
      Shadow(color: Color(0x99000000), blurRadius: 10, offset: Offset(0, 2)),
    ],
    cardShadow: [
      BoxShadow(
        color: Color(0x73000814),
        blurRadius: 26,
        offset: Offset(0, 8),
      ),
    ],
    logoGlow: Color(0x8038D9F5),
  );

  static const M3Palette sky = M3Palette(
    isNight: false,
    wallpaper: 'assets/m3/bg-sky.webp',
    bg: Color(0xFFDCEFFC),
    bg2: Color(0xFFEAF6FF),
    winShade: Color(0x26FFFFFF),
    titleFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xE6FFFFFF), Color(0x99FFFFFF)],
    ),
    sideFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xF5FFFFFF), Color(0xE0F2F9FF), Color(0xD6E1F1FC)],
      stops: [0, 0.3, 1],
    ),
    glassFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xF7FFFFFF),
        Color(0xD1F2FAFF),
        Color(0xC2E6F4FE),
        Color(0xC7D2E9F9),
      ],
      stops: [0, 0.4, 0.42, 1],
    ),
    glassFillHi: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFCFFFFFF), Color(0xE6EEF8FF), Color(0xDDD3EAFA)],
      stops: [0, 0.5, 1],
    ),
    glassLine: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFFFFFF), Color(0xD9CFE6F7), Color(0xB38CBFE6)],
      stops: [0, 0.45, 1],
    ),
    headerBg: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xF2FFFFFF), Color(0xB3DCEEFB)],
    ),
    drawerFill: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFCFFFFFF), Color(0xF7E6F3FD)],
    ),
    glassBtn: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFFFFFFFF),
        Color(0xFFEEF8FF),
        Color(0xFFD9EEFB),
        Color(0xFFF0F9FF),
      ],
      stops: [0, 0.49, 0.5, 1],
    ),
    wordmark: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF7FA3D6),
        Color(0xFF2A4C86),
        Color(0xFF0B1633),
        Color(0xFF35609E),
      ],
      stops: [0, 0.46, 0.52, 1],
    ),
    wordmarkAccent: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        Color(0xFF7BEAFF),
        Color(0xFF14A9D8),
        Color(0xFF06709A),
        Color(0xFF2BC6EE),
      ],
      stops: [0, 0.48, 0.52, 1],
    ),
    card: Color(0xFFF4FAFF),
    card2: Color(0xFFE3F1FC),
    inset: Color(0x80FFFFFF),
    line: Color(0x808CB4D9),
    hover: Color(0x66BFE6FF),
    select: Color(0x8CA6DDF7),
    row: Color(0x66FFFFFF),
    track: Color(0x4D7FA6CC),
    thumb: Color(0x998AB4DC),
    input: Color(0xF0FFFFFF),
    inputLine: Color(0xFF9CC9EA),
    popup: Color(0xFAF8FCFF),
    popupLine: Color(0xFF9CC9EA),
    scrim: Color(0x73203A62),
    text: Color(0xFF10234A),
    text2: Color(0xFF3E5A86),
    text3: Color(0xFF647DA3),
    numText: Color(0xFF0E2A55),
    gold: Color(0xFFA26C0E),
    cyan: Color(0xFF0A86B8),
    red: Color(0xFFD31F3A),
    amber: Color(0xFFB87400),
    green: Color(0xFF0F9D58),
    orange: Color(0xFFD96A0B),
    violet: Color(0xFF6B55E0),
    redSoft: Color(0x1FD31F3A),
    redSoftLine: Color(0x8CD31F3A),
    redText: Color(0xFFB3142B),
    amberSoft: Color(0x24B87400),
    amberSoftLine: Color(0x8CB87400),
    amberText: Color(0xFF7E4F00),
    greenSoft: Color(0x1F0F9D58),
    greenSoftLine: Color(0x800F9D58),
    greenText: Color(0xFF0B6E3E),
    cyanSoft: Color(0x1F0A86B8),
    cyanSoftLine: Color(0x800A86B8),
    cyanText: Color(0xFF056C93),
    glassBtnText: Color(0xFF16345E),
    numGlow: [Shadow(color: Color(0xF2FFFFFF), offset: Offset(0, 1.5))],
    numGlowRed: [Shadow(color: Color(0xF2FFFFFF), offset: Offset(0, 1.5))],
    titleShadow: [Shadow(color: Color(0xF2FFFFFF), offset: Offset(0, 1.5))],
    cardShadow: [
      BoxShadow(
        color: Color(0x332A5B8C),
        blurRadius: 24,
        offset: Offset(0, 8),
      ),
    ],
    logoGlow: Color(0x590A86B8),
  );

  @override
  M3Palette copyWith() => this;

  // Theme switches are instant; no colour tweening between palettes.
  @override
  M3Palette lerp(ThemeExtension<M3Palette>? other, double t) {
    if (other is! M3Palette) return this;
    return t < 0.5 ? this : other;
  }
}

/// Tones shared by tags, banners, orbs and stat numbers.
enum M3Tone { cyan, green, amber, red, gold, neutral }

extension M3PaletteTones on M3Palette {
  Color toneColor(M3Tone tone) => switch (tone) {
        M3Tone.cyan => cyan,
        M3Tone.green => green,
        M3Tone.amber => amber,
        M3Tone.red => red,
        M3Tone.gold => gold,
        M3Tone.neutral => text2,
      };

  Color toneSoft(M3Tone tone) => switch (tone) {
        M3Tone.cyan => cyanSoft,
        M3Tone.green => greenSoft,
        M3Tone.amber || M3Tone.gold => amberSoft,
        M3Tone.red => redSoft,
        M3Tone.neutral => inset,
      };

  Color toneSoftLine(M3Tone tone) => switch (tone) {
        M3Tone.cyan => cyanSoftLine,
        M3Tone.green => greenSoftLine,
        M3Tone.amber || M3Tone.gold => amberSoftLine,
        M3Tone.red => redSoftLine,
        M3Tone.neutral => line,
      };

  Color toneText(M3Tone tone) => switch (tone) {
        M3Tone.cyan => cyanText,
        M3Tone.green => greenText,
        M3Tone.amber || M3Tone.gold => amberText,
        M3Tone.red => redText,
        M3Tone.neutral => text2,
      };
}

extension M3ContextPalette on BuildContext {
  /// The active Millennium 3D palette.
  M3Palette get m3 =>
      Theme.of(this).extension<M3Palette>() ?? M3Palette.night;
}

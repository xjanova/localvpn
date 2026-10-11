import 'package:flutter/material.dart';

import '../../database/app_store.dart';
import 'm3_palette.dart';

export 'm3_palette.dart';

/// Font families bundled in assets/fonts (see pubspec.yaml).
class M3Fonts {
  M3Fonts._();

  /// Headings, buttons, numbers, wordmark.
  static const String head = 'Kanit';

  /// Body text (Thai + Latin).
  static const String ui = 'Anuphan';

  /// IP addresses, keys, ports. Has no Thai glyphs, so always pair it
  /// with [monoFallback].
  static const String mono = 'JetBrainsMono';
  static const List<String> monoFallback = ['Anuphan'];
}

/// Gradients and glows that look the same in both palettes
/// (gloss, chrome, gold, coloured buttons, PRO badge frames).
class M3Fx {
  M3Fx._();

  static const _down = Alignment.topCenter;
  static const _up = Alignment.bottomCenter;

  /// Top-half shine laid over buttons and capsules (hard edge at 50 %).
  static const LinearGradient btnGloss = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0x80FFFFFF),
      Color(0x1AFFFFFF),
      Color(0x00FFFFFF),
      Color(0x00FFFFFF),
    ],
    stops: [0, 0.48, 0.5, 1],
  );

  static const LinearGradient chrome = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFFFDFEFE),
      Color(0xFFC9D4DF),
      Color(0xFF7D8997),
      Color(0xFFDDE5EC),
      Color(0xFF8F9CAA),
    ],
    stops: [0, 0.22, 0.5, 0.72, 1],
  );

  static const LinearGradient goldRing = LinearGradient(
    colors: [Color(0xFFC9932E), Color(0xFFFFF1C4), Color(0xFFC9932E)],
  );

  static const LinearGradient goldLine = LinearGradient(
    colors: [
      Color(0x00F2C75C),
      Color(0xFFF2C75C),
      Color(0xFFFFF1C4),
      Color(0xFFF2C75C),
      Color(0x00F2C75C),
    ],
    stops: [0, 0.2, 0.5, 0.8, 1],
  );

  static const LinearGradient goldGrad = LinearGradient(
    begin: _down,
    end: _up,
    colors: [Color(0xFFFFF1C7), Color(0xFFF0C96A), Color(0xFFC8962F)],
    stops: [0, 0.45, 1],
  );

  static const LinearGradient aquaGloss = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFFD4FCFF),
      Color(0xFF6EE6F8),
      Color(0xFF18AEDB),
      Color(0xFF3CCFF0),
    ],
    stops: [0, 0.47, 0.53, 1],
  );
  static const Color aquaEdge = Color(0xFF0A7FA6);
  static const Color aquaText = Color(0xFF03263B);

  static const LinearGradient goldGloss = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFFFFF6D6),
      Color(0xFFF7D47A),
      Color(0xFFD69B2A),
      Color(0xFFF2C14E),
    ],
    stops: [0, 0.48, 0.52, 1],
  );
  static const Color goldEdge = Color(0xFF9C6A12);
  static const Color goldText = Color(0xFF3A2604);

  static const LinearGradient redGloss = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFFFFB3B9),
      Color(0xFFFF5B6B),
      Color(0xFFD9213A),
      Color(0xFFF0435A),
    ],
    stops: [0, 0.48, 0.52, 1],
  );
  static const Color redEdge = Color(0xFF9E1427);

  static const LinearGradient greenGloss = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFFC9FFE0),
      Color(0xFF5BEA9C),
      Color(0xFF16A35A),
      Color(0xFF34C978),
    ],
    stops: [0, 0.48, 0.52, 1],
  );
  static const Color greenEdge = Color(0xFF0E7A40);
  static const Color greenText = Color(0xFF022A14);

  /// Glass tube fills for bars and progress.
  static const LinearGradient barAqua = LinearGradient(
    begin: _down,
    end: _up,
    colors: [Color(0xFFA6F4FF), Color(0xFF29C8EE), Color(0xFF0A78B8)],
    stops: [0, 0.4, 1],
  );
  static const LinearGradient barRed = LinearGradient(
    begin: _down,
    end: _up,
    colors: [Color(0xFFFFC2C8), Color(0xFFFF5B6B), Color(0xFFB8152D)],
    stops: [0, 0.45, 1],
  );
  static const LinearGradient barGreen = LinearGradient(
    begin: _down,
    end: _up,
    colors: [Color(0xFFC9FFE0), Color(0xFF3EE08A), Color(0xFF0E7A40)],
    stops: [0, 0.45, 1],
  );
  static const LinearGradient barGold = LinearGradient(
    begin: _down,
    end: _up,
    colors: [Color(0xFFFFF1C7), Color(0xFFF0C96A), Color(0xFFB07A1C)],
    stops: [0, 0.45, 1],
  );
  static const LinearGradient barShine = LinearGradient(
    colors: [Color(0x00FFFFFF), Color(0x8CFFFFFF), Color(0x00FFFFFF)],
    stops: [0, 0.18, 0.42],
  );

  // PRO badge
  static const LinearGradient goldFrame = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF8C5A12),
      Color(0xFFFFE9A8),
      Color(0xFFC9932E),
      Color(0xFFFFF4CC),
      Color(0xFF9C6A12),
    ],
    stops: [0, 0.22, 0.48, 0.74, 1],
  );
  static const LinearGradient silverFrame = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF7D8997),
      Color(0xFFFDFEFE),
      Color(0xFF8F9CAA),
      Color(0xFFE9F1F7),
      Color(0xFF6B7785),
    ],
    stops: [0, 0.25, 0.5, 0.75, 1],
  );
  static const LinearGradient redFrame = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF9E1427),
      Color(0xFFFFB3B9),
      Color(0xFFD9213A),
      Color(0xFF7A0F1E),
    ],
    stops: [0, 0.3, 0.6, 1],
  );
  static const LinearGradient proPlate = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFF3E3014),
      Color(0xFF1E1709),
      Color(0xFF0A0804),
      Color(0xFF1C150A),
    ],
    stops: [0, 0.48, 0.52, 1],
  );
  static const LinearGradient freePlate = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFF2E3A4E),
      Color(0xFF18202E),
      Color(0xFF0A0F18),
      Color(0xFF151C28),
    ],
    stops: [0, 0.48, 0.52, 1],
  );
  static const LinearGradient proShine = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0x00FFF1C4), Color(0x3DFFF1C4), Color(0x00FFF1C4)],
    stops: [0.3, 0.42, 0.54],
  );
  static const LinearGradient proGold = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFFFFF8DD),
      Color(0xFFF7D47A),
      Color(0xFFD69B2A),
      Color(0xFFFFE29A),
    ],
    stops: [0, 0.45, 0.56, 1],
  );
  static const LinearGradient proSilver = LinearGradient(
    begin: _down,
    end: _up,
    colors: [
      Color(0xFFFFFFFF),
      Color(0xFFDDE5EC),
      Color(0xFF8F9CAA),
      Color(0xFFE9F1F7),
    ],
    stops: [0, 0.45, 0.56, 1],
  );

  static const List<BoxShadow> goldGlow = [
    BoxShadow(color: Color(0x8CF0C96A), blurRadius: 18),
  ];
  static const List<BoxShadow> redGlow = [
    BoxShadow(color: Color(0x99FF4D5E), blurRadius: 16),
  ];
  static const List<BoxShadow> aquaGlow = [
    BoxShadow(color: Color(0x9938D9F5), blurRadius: 20),
  ];
  static const List<Shadow> proGlow = [
    Shadow(color: Color(0xB3FFC94A), blurRadius: 14),
  ];
}

/// Text styles. Never set letterSpacing on Thai text — it detaches vowels
/// and tone marks from their consonants.
class M3Text {
  M3Text._();

  static TextStyle h1(BuildContext context) => TextStyle(
        fontFamily: M3Fonts.head,
        fontSize: 26,
        fontWeight: FontWeight.w600,
        height: 1.25,
        color: context.m3.text,
        shadows: context.m3.titleShadow,
      );

  static TextStyle h2(BuildContext context) => TextStyle(
        fontFamily: M3Fonts.head,
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 1.3,
        color: context.m3.text,
      );

  static TextStyle h3(BuildContext context) => TextStyle(
        fontFamily: M3Fonts.head,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: context.m3.text,
      );

  static TextStyle body(BuildContext context) => TextStyle(
        fontFamily: M3Fonts.ui,
        fontSize: 14,
        height: 1.45,
        color: context.m3.text,
      );

  static TextStyle sub(BuildContext context) => TextStyle(
        fontFamily: M3Fonts.ui,
        fontSize: 12.5,
        height: 1.4,
        color: context.m3.text3,
      );

  static TextStyle label(BuildContext context) => TextStyle(
        fontFamily: M3Fonts.ui,
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
        color: context.m3.text2,
      );

  /// Big stat number with the theme's glow.
  static TextStyle num(BuildContext context,
          {double size = 40, Color? color, bool red = false}) =>
      TextStyle(
        fontFamily: M3Fonts.head,
        fontSize: size,
        fontWeight: FontWeight.w600,
        height: 1.1,
        color: color ?? context.m3.numText,
        shadows: red ? context.m3.numGlowRed : context.m3.numGlow,
      );

  static TextStyle mono(BuildContext context,
          {double size = 13, Color? color, FontWeight? weight}) =>
      TextStyle(
        fontFamily: M3Fonts.mono,
        fontFamilyFallback: M3Fonts.monoFallback,
        fontSize: size,
        fontWeight: weight ?? FontWeight.w500,
        color: color ?? context.m3.cyan,
      );

  /// Latin-only eyebrow (e.g. "VIRTUAL LAN"). Tracking is safe here.
  static TextStyle eyebrow(BuildContext context, {Color? color}) => TextStyle(
        fontFamily: M3Fonts.head,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 2.6,
        color: color ?? context.m3.gold,
      );
}

ThemeData buildM3Theme(M3Palette p) {
  final brightness = p.isNight ? Brightness.dark : Brightness.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.cyan,
    onPrimary: M3Fx.aquaText,
    secondary: p.gold,
    onSecondary: M3Fx.goldText,
    error: p.red,
    onError: Colors.white,
    surface: p.card,
    onSurface: p.text,
    surfaceContainerHighest: p.card2,
    outline: p.line,
  );
  final radius12 = BorderRadius.circular(12);

  TextStyle ui(double size, [FontWeight w = FontWeight.w400, Color? c]) =>
      TextStyle(
          fontFamily: M3Fonts.ui, fontSize: size, fontWeight: w, color: c);
  TextStyle head(double size, [FontWeight w = FontWeight.w600, Color? c]) =>
      TextStyle(
          fontFamily: M3Fonts.head, fontSize: size, fontWeight: w, color: c);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: M3Fonts.ui,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: p.bg,
    dividerColor: p.line,
    hoverColor: p.hover,
    splashColor: p.select,
    highlightColor: p.hover,
    focusColor: p.select,
    iconTheme: IconThemeData(color: p.text2),
    extensions: [p],
    textTheme: TextTheme(
      displayLarge: head(34, FontWeight.w700, p.text),
      displayMedium: head(30, FontWeight.w700, p.text),
      headlineLarge: head(26, FontWeight.w600, p.text),
      headlineMedium: head(22, FontWeight.w600, p.text),
      headlineSmall: head(19, FontWeight.w600, p.text),
      titleLarge: head(18, FontWeight.w600, p.text),
      titleMedium: head(16, FontWeight.w500, p.text),
      titleSmall: head(14, FontWeight.w500, p.text),
      bodyLarge: ui(15, FontWeight.w400, p.text),
      bodyMedium: ui(14, FontWeight.w400, p.text2),
      bodySmall: ui(12.5, FontWeight.w400, p.text3),
      labelLarge: head(14, FontWeight.w500, p.text),
      labelMedium: ui(12.5, FontWeight.w500, p.text2),
      labelSmall: ui(11, FontWeight.w500, p.text3),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.cyan,
      selectionColor: p.cyan.withValues(alpha: 0.35),
      selectionHandleColor: p.cyan,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.input,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: ui(13.5, FontWeight.w400, p.text3),
      labelStyle: ui(13.5, FontWeight.w500, p.text2),
      floatingLabelStyle: ui(13, FontWeight.w500, p.cyan),
      prefixIconColor: p.text3,
      suffixIconColor: p.text3,
      errorStyle: ui(12, FontWeight.w500, p.red),
      border: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.inputLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.inputLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.cyan, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.redSoftLine),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.red, width: 1.4),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius12,
        borderSide: BorderSide(color: p.line),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.popup,
      contentTextStyle: ui(13.5, FontWeight.w500, p.text),
      actionTextColor: p.cyan,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.popupLine),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.popup,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: head(18, FontWeight.w600, p.text),
      contentTextStyle: ui(14, FontWeight.w400, p.text2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.popupLine),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.popup,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: p.popup,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        side: BorderSide(color: p.popupLine),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.popup,
      surfaceTintColor: Colors.transparent,
      textStyle: ui(13.5, FontWeight.w500, p.text),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.popupLine),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.popup,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.popupLine),
      ),
      textStyle: ui(12.5, FontWeight.w500, p.text),
      waitDuration: const Duration(milliseconds: 400),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.cyan,
      linearTrackColor: p.track,
      circularTrackColor: p.track,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.cyan,
      inactiveTrackColor: p.track,
      thumbColor: const Color(0xFFDDE5EC),
      overlayColor: p.select,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.cyan : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(M3Fx.aquaText),
      side: BorderSide(color: p.inputLine, width: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.cyan : p.inputLine),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.thumb),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.text2,
      textColor: p.text,
      shape: RoundedRectangleBorder(borderRadius: radius12),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.cyan,
        textStyle: head(14, FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

/// Holds the chosen palette (night by default) and remembers it.
class M3ThemeController extends ChangeNotifier {
  M3ThemeController._();
  static final M3ThemeController instance = M3ThemeController._();

  static const _prefKey = 'ui_theme_v1';

  bool _isNight = true;
  bool get isNight => _isNight;
  M3Palette get palette => _isNight ? M3Palette.night : M3Palette.sky;

  ThemeData? _night;
  ThemeData? _sky;
  ThemeData get theme => _isNight
      ? (_night ??= buildM3Theme(M3Palette.night))
      : (_sky ??= buildM3Theme(M3Palette.sky));

  Future<void> load() async {
    try {
      final prefs = await AppStore.instance();
      _isNight = prefs.getString(_prefKey) != 'sky';
    } catch (_) {
      _isNight = true;
    }
  }

  Future<void> setNight(bool night) async {
    if (night == _isNight) return;
    _isNight = night;
    notifyListeners();
    try {
      final prefs = await AppStore.instance();
      await prefs.setString(_prefKey, night ? 'night' : 'sky');
    } catch (_) {}
  }

  /// For screenshot runs (`--theme sky`); does not persist.
  void force(bool night) {
    _isNight = night;
    notifyListeners();
  }
}

import 'package:flutter/material.dart';

@immutable
class InkColors extends ThemeExtension<InkColors> {
  const InkColors({
    required this.canvasChrome,
    required this.panel,
    required this.panelRaised,
    required this.panelBorder,
    required this.selected,
    required this.selectedStrong,
    required this.toolActive,
    required this.warning,
    required this.success,
  });

  final Color canvasChrome;
  final Color panel;
  final Color panelRaised;
  final Color panelBorder;
  final Color selected;
  final Color selectedStrong;
  final Color toolActive;
  final Color warning;
  final Color success;

  @override
  InkColors copyWith({
    Color? canvasChrome,
    Color? panel,
    Color? panelRaised,
    Color? panelBorder,
    Color? selected,
    Color? selectedStrong,
    Color? toolActive,
    Color? warning,
    Color? success,
  }) => InkColors(
    canvasChrome: canvasChrome ?? this.canvasChrome,
    panel: panel ?? this.panel,
    panelRaised: panelRaised ?? this.panelRaised,
    panelBorder: panelBorder ?? this.panelBorder,
    selected: selected ?? this.selected,
    selectedStrong: selectedStrong ?? this.selectedStrong,
    toolActive: toolActive ?? this.toolActive,
    warning: warning ?? this.warning,
    success: success ?? this.success,
  );

  @override
  InkColors lerp(covariant InkColors? other, double t) {
    if (other == null) return this;
    return InkColors(
      canvasChrome: Color.lerp(canvasChrome, other.canvasChrome, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      panelRaised: Color.lerp(panelRaised, other.panelRaised, t)!,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      selectedStrong: Color.lerp(selectedStrong, other.selectedStrong, t)!,
      toolActive: Color.lerp(toolActive, other.toolActive, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      success: Color.lerp(success, other.success, t)!,
    );
  }
}

@immutable
class InkMetrics extends ThemeExtension<InkMetrics> {
  const InkMetrics({
    this.grid = 4,
    this.desktopControlHeight = 34,
    this.touchControlHeight = 48,
    this.panelRadius = 10,
    this.dockWidth = 360,
  });

  final double grid;
  final double desktopControlHeight;
  final double touchControlHeight;
  final double panelRadius;
  final double dockWidth;

  @override
  InkMetrics copyWith({
    double? grid,
    double? desktopControlHeight,
    double? touchControlHeight,
    double? panelRadius,
    double? dockWidth,
  }) => InkMetrics(
    grid: grid ?? this.grid,
    desktopControlHeight: desktopControlHeight ?? this.desktopControlHeight,
    touchControlHeight: touchControlHeight ?? this.touchControlHeight,
    panelRadius: panelRadius ?? this.panelRadius,
    dockWidth: dockWidth ?? this.dockWidth,
  );

  @override
  InkMetrics lerp(covariant InkMetrics? other, double t) {
    if (other == null) return this;
    return InkMetrics(
      grid: lerpDouble(grid, other.grid, t),
      desktopControlHeight: lerpDouble(
        desktopControlHeight,
        other.desktopControlHeight,
        t,
      ),
      touchControlHeight: lerpDouble(
        touchControlHeight,
        other.touchControlHeight,
        t,
      ),
      panelRadius: lerpDouble(panelRadius, other.panelRadius, t),
      dockWidth: lerpDouble(dockWidth, other.dockWidth, t),
    );
  }
}

double lerpDouble(double a, double b, double t) => a + (b - a) * t;

class InkTheme {
  static ThemeData light({bool highContrast = false}) {
    final colors = highContrast ? _lightHighContrast : _light;
    return _build(colors, Brightness.light, highContrast: highContrast);
  }

  static ThemeData dark({bool highContrast = false}) {
    final colors = highContrast ? _darkHighContrast : _dark;
    return _build(colors, Brightness.dark, highContrast: highContrast);
  }

  static const _dark = InkColors(
    canvasChrome: Color(0xff17191d),
    panel: Color(0xff22252b),
    panelRaised: Color(0xff2b2f36),
    panelBorder: Color(0xff3b414b),
    selected: Color(0xff37334f),
    selectedStrong: Color(0xff8e7dff),
    toolActive: Color(0xffa99cff),
    warning: Color(0xfff2b84b),
    success: Color(0xff69d39b),
  );

  static const _darkHighContrast = InkColors(
    canvasChrome: Color(0xff000000),
    panel: Color(0xff101010),
    panelRaised: Color(0xff1f1f1f),
    panelBorder: Color(0xffbdbdbd),
    selected: Color(0xff41357d),
    selectedStrong: Color(0xffc9bdff),
    toolActive: Color(0xffe3ddff),
    warning: Color(0xffffdf87),
    success: Color(0xff8ff0bb),
  );

  static const _light = InkColors(
    canvasChrome: Color(0xffdfe2e8),
    panel: Color(0xfff5f6f8),
    panelRaised: Color(0xffffffff),
    panelBorder: Color(0xffc4c8d0),
    selected: Color(0xffe4dfff),
    selectedStrong: Color(0xff5d49bf),
    toolActive: Color(0xff4b369f),
    warning: Color(0xff8a5b00),
    success: Color(0xff176b41),
  );

  static const _lightHighContrast = InkColors(
    canvasChrome: Color(0xffd2d2d2),
    panel: Color(0xffffffff),
    panelRaised: Color(0xffffffff),
    panelBorder: Color(0xff444444),
    selected: Color(0xffd7ccff),
    selectedStrong: Color(0xff392777),
    toolActive: Color(0xff25145f),
    warning: Color(0xff704600),
    success: Color(0xff07552f),
  );

  static ThemeData _build(
    InkColors ink,
    Brightness brightness, {
    required bool highContrast,
  }) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: ink.toolActive,
      onPrimary: dark ? Colors.black : Colors.white,
      primaryContainer: ink.selected,
      onPrimaryContainer: dark ? Colors.white : Colors.black,
      secondary: ink.selectedStrong,
      onSecondary: dark ? Colors.black : Colors.white,
      secondaryContainer: ink.selected,
      onSecondaryContainer: dark ? Colors.white : Colors.black,
      tertiary: ink.success,
      onTertiary: dark ? Colors.black : Colors.white,
      error: const Color(0xffd44c5c),
      onError: Colors.white,
      surface: ink.panel,
      onSurface: dark ? const Color(0xfff2f3f5) : const Color(0xff1a1b1f),
      surfaceContainerHighest: ink.panelRaised,
      onSurfaceVariant:
          dark ? const Color(0xffc4c8d0) : const Color(0xff4b4f58),
      outline: ink.panelBorder,
      outlineVariant: ink.panelBorder.withValues(
        alpha: highContrast ? 0.9 : 0.65,
      ),
      inverseSurface: dark ? Colors.white : const Color(0xff25262a),
      onInverseSurface: dark ? Colors.black : Colors.white,
      inversePrimary: dark ? const Color(0xff4b369f) : const Color(0xffc9bdff),
      scrim: Colors.black54,
    );
    final base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      scaffoldBackgroundColor: ink.canvasChrome,
      visualDensity: VisualDensity.compact,
      splashFactory: InkRipple.splashFactory,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: ink.panelRaised,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: ink.panelBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: ink.panelBorder),
        ),
      ),
      dividerTheme: DividerThemeData(color: ink.panelBorder, space: 1),
      cardTheme: CardThemeData(
        color: ink.panel,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(const InkMetrics().panelRadius),
          side: BorderSide(color: ink.panelBorder),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(40, 40),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[ink, const InkMetrics()],
    );
    return base.copyWith(
      textTheme: base.textTheme
          .apply(
            fontFamily: null,
            bodyColor: scheme.onSurface,
            displayColor: scheme.onSurface,
          )
          .copyWith(
            labelSmall: base.textTheme.labelSmall?.copyWith(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            labelMedium: base.textTheme.labelMedium?.copyWith(
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            labelLarge: base.textTheme.labelLarge?.copyWith(fontSize: 13),
            titleSmall: base.textTheme.titleSmall?.copyWith(fontSize: 14),
            titleMedium: base.textTheme.titleMedium?.copyWith(fontSize: 14),
            titleLarge: base.textTheme.titleLarge?.copyWith(fontSize: 16),
          ),
    );
  }
}

import 'package:flutter/material.dart';

/// UXUY app palette (matched to the UXUY app screens: white pages, light gray cards, orange-red pills).
abstract final class UxuyColors {
  static const background = Color(0xFFFFFFFF);

  /// Card fill (no border), as the UXUY asset / activity tiles.
  static const panel = Color(0xFFF4F6F6);

  /// Inputs sit on gray cards, so they are white.
  static const input = Color(0xFFFFFFFF);

  /// Selected sub-tab pill / secondary fill.
  static const chip = Color(0xFFE8ECED);
  static const text = Color(0xFF000000);
  static const muted = Color(0xFF8A9295);
  static const line = Color(0xFFE8ECED);
  static const accent = Color(0xFFFF4D0D);

  /// Light orange pill with orange text (UXUY "领取").
  static const accentSoft = Color(0xFFFFEDE6);
  static const buy = Color(0xFF16A604);
  static const sell = Color(0xFFF4504E);
}

/// Derives from the host theme so typography, locale and text scaling are inherited.
ThemeData uxuyTheme(ThemeData host) {
  final scheme = host.colorScheme.copyWith(
    brightness: Brightness.light,
    primary: UxuyColors.accent,
    onPrimary: Colors.white,
    secondary: UxuyColors.accent,
    surface: UxuyColors.panel,
    onSurface: UxuyColors.text,
    error: UxuyColors.sell,
    outline: UxuyColors.line,
  );
  // Filled inputs without outlines, as in the reference; focus shows a black outline.
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide.none,
  );
  return host.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: UxuyColors.background,
    dividerColor: UxuyColors.line,
    appBarTheme: const AppBarTheme(
      backgroundColor: UxuyColors.background,
      centerTitle: true,
      foregroundColor: UxuyColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: UxuyColors.input,
      isDense: true,
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: UxuyColors.text),
      ),
      hintStyle: const TextStyle(color: UxuyColors.muted),
      labelStyle: const TextStyle(color: UxuyColors.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: UxuyColors.accent,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 44),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UxuyColors.text,
        minimumSize: const Size(0, 44),
        backgroundColor: UxuyColors.chip,
        side: BorderSide.none,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: UxuyColors.text,
      unselectedLabelColor: UxuyColors.muted,
      indicatorColor: UxuyColors.text,
      dividerColor: UxuyColors.line,
      overlayColor: WidgetStatePropertyAll(Colors.transparent),
    ),
    // Neutral toggles: black when selected; buy/sell segments override with green/red.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? UxuyColors.text
              : UxuyColors.panel,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? Colors.white : UxuyColors.text,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: const WidgetStatePropertyAll(BorderSide(color: UxuyColors.line)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: UxuyColors.background,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: UxuyColors.background,
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? UxuyColors.accent : null,
      ),
    ),
  );
}

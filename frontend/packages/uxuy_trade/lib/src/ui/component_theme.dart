import 'package:flutter/material.dart';

/// Shared form dimensions and UXUY trading colors.
abstract final class UiStyle {
  static const text = Color(0xff111111);
  static const muted = Color(0xff666666);
  static const border = Color(0xffdedede);
  static const surface = Color(0xfff2f2f2);
  static const hover = surface;
  static const action = Color(0xffbb3b0e);
  static const positive = Color(0xff216947);
  static const negative = Color(0xffaa3339);
  static const radius = 8.0;
  static const fieldPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 11);
  static const fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    borderSide: BorderSide(color: border),
  );
  static const motion = Duration(milliseconds: 180);
}

/// Presentation only. The original UXUY theme and its brand tokens stay intact.
ThemeData componentTheme(ThemeData theme) {
  // ButtonStyle.textStyle and TooltipTheme.textStyle replace a whole style;
  // they do not merge the font family from the surrounding text theme. Start
  // from that theme so the Web app keeps its bundled UXUYSans (and host apps
  // retain their own family) instead of triggering remote CJK fallbacks.
  final type = theme.textTheme.apply(
    bodyColor: UiStyle.text,
    displayColor: UiStyle.text,
  );
  final buttonText = type.labelLarge!.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
  );
  const border = UiStyle.fieldBorder;
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(UiStyle.radius),
  );
  return theme.copyWith(
    textTheme: type.copyWith(
      bodyLarge: type.bodyLarge!.copyWith(fontSize: 14, letterSpacing: 0),
      bodyMedium: type.bodyMedium!.copyWith(fontSize: 14, letterSpacing: 0),
      bodySmall: type.bodySmall!.copyWith(fontSize: 12, letterSpacing: 0),
      labelLarge: buttonText,
    ),
    splashFactory: NoSplash.splashFactory,
    dividerColor: UiStyle.border,
    colorScheme: theme.colorScheme.copyWith(
      primary: UiStyle.action,
      secondary: UiStyle.text,
      error: UiStyle.negative,
      surface: Colors.white,
      surfaceTint: Colors.transparent,
      onSurface: UiStyle.text,
      onSurfaceVariant: UiStyle.muted,
      outline: UiStyle.border,
      outlineVariant: UiStyle.border,
    ),
    checkboxTheme: theme.checkboxTheme.copyWith(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return null;
        return states.contains(WidgetState.selected) ? UiStyle.text : null;
      }),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      contentPadding: UiStyle.fieldPadding,
      suffixStyle: const TextStyle(color: UiStyle.muted, fontSize: 12),
      border: border,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: UiStyle.action),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: UiStyle.negative),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: UiStyle.negative),
      ),
      hintStyle: const TextStyle(color: UiStyle.muted, fontSize: 14),
      labelStyle: const TextStyle(color: UiStyle.muted, fontSize: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: UiStyle.action,
        foregroundColor: Colors.white,
        disabledBackgroundColor: UiStyle.hover,
        disabledForegroundColor: UiStyle.muted,
        minimumSize: const Size(0, 38),
        shape: shape,
        textStyle: buttonText.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: UiStyle.text,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: shape,
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: UiStyle.text,
        backgroundColor: Colors.white,
        side: const BorderSide(color: UiStyle.border),
        textStyle: buttonText,
        minimumSize: const Size(0, 36),
        shape: shape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: UiStyle.muted,
        iconSize: 18,
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.all(6),
        shape: shape,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      showDuration: const Duration(seconds: 3),
      textStyle: theme.textTheme.bodySmall!.copyWith(
        fontSize: 12,
        color: Colors.white,
      ),
      decoration: BoxDecoration(
        color: UiStyle.text,
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.only(top: 8),
      shape: Border(),
      collapsedShape: Border(),
      iconColor: UiStyle.muted,
      textColor: UiStyle.text,
      collapsedTextColor: UiStyle.muted,
    ),
  );
}

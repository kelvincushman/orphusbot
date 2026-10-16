// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// Flutter theme — Eloquent design language: near-white ground, black action
// colour, geometric sans. Tokens are transcribed from
// docs/design/design-tokens.md, which is the source of truth; edit the doc
// first, then wearable_tokens.dart, then this file.
//
// Usage:
//
//   MaterialApp(theme: WearableTheme.light(), ...)
//
// Eloquent is light. There is no dark variant and adding one is a product
// decision, not a theming one.

import 'package:flutter/material.dart';

/// Colour tokens — keep in lockstep with docs/design/design-tokens.md §1.
class WearableColors {
  WearableColors._();

  // Ground — near-white with a faint lavender tint
  static const Color background = Color(0xFFF4F5FF);
  // Card / sheet / list-item surface
  static const Color card = Color(0xFFFFFFFF);
  // Alt surface inside a card
  static const Color cardAlt = Color(0xFFF1F3F4);
  // Muted surface — same as cardAlt; kept named for chip backgrounds
  static const Color muted = Color(0xFFF1F3F4);
  // Lower-emphasis containers, tag fills
  static const Color secondary = Color(0xFFE8EAED);
  // Hairline on chips, inputs, dividers
  static const Color border = Color(0xFFDADCE0);
  // Headlines and body text
  static const Color foreground = Color(0xFF000000);
  // Helper text, captions, inactive tab labels — 6.05:1 on card (WCAG AA)
  static const Color mutedFg = Color(0xFF5F6368);

  // The action colour: mic button, active tab pill, filled chip
  static const Color primary = Color(0xFF000000);
  // Text/icon on primary-filled elements
  static const Color onPrimary = Color(0xFFFFFFFF);
  // Live / cloud-on tint (privacy toggle track, recording pulse). Non-text.
  static const Color accentSky = Color(0xFF8AB4F8);

  // Semantic
  static const Color info = Color(0xFF1967D2);
  static const Color destructive = Color(0xFFC5221F);
  static const Color warning = Color(0xFFA45400);
  static const Color success = Color(0xFF188038);
  // Fourth role hue — keeps the `research` role's border stripe separable from
  // `comms` (which uses `info`).
  static const Color accentViolet = Color(0xFF8430CE);
}

/// Radii — matches docs/design/design-tokens.md §3.
class WearableRadii {
  WearableRadii._();
  static const double sm = 8.0;    // tags, small badges
  static const double md = 12.0;   // inputs, alt surfaces
  static const double lg = 20.0;   // cards, bottom sheets
  static const double full = 999.0; // pills, chips, tab indicator
}

/// Typography — matches docs/design/design-tokens.md §2.
///
/// We ship no font binary. Eloquent renders in Google Sans; name it first for
/// devices that have it, fall back to the bundled "SF Pro Display" (declared in
/// pubspec.yaml, so it always resolves), then Roboto for glyph coverage.
class WearableType {
  WearableType._();
  static const String family = 'Google Sans';
  static const List<String> fallback = <String>['SF Pro Display', 'Roboto'];
}

/// Chip label — white on a selected (black-filled) chip, black otherwise.
final TextStyle _chipLabelStyle = TextStyle(
  fontFamily: WearableType.family,
  fontFamilyFallback: WearableType.fallback,
  fontSize: 14,
  height: 20 / 14,
  fontWeight: FontWeight.w600,
  color: WidgetStateColor.resolveWith(
    (states) => states.contains(WidgetState.selected)
        ? WearableColors.onPrimary
        : WearableColors.foreground,
  ),
);

class WearableTheme {
  WearableTheme._();

  /// The app's only theme.
  static ThemeData light() {
    // Upstream uses `colorScheme.primary` as the default scaffold + app-bar
    // background. To avoid a full refactor of every
    // `backgroundColor: Theme.of(context).colorScheme.primary` call-site, map
    // colorScheme.primary to the ground and expose the black action colour via
    // `colorScheme.secondary` (which upstream already uses for highlights).
    // Our own widgets reference WearableColors.primary directly where the black
    // action colour is needed (buttons, focused inputs, switches).
    final scheme = const ColorScheme.light(
      primary: WearableColors.background,
      onPrimary: WearableColors.foreground,
      secondary: WearableColors.primary,
      onSecondary: WearableColors.onPrimary,
      tertiary: WearableColors.accentSky,
      onTertiary: WearableColors.foreground,
      surface: WearableColors.card,
      onSurface: WearableColors.foreground,
      error: WearableColors.destructive,
      onError: WearableColors.onPrimary,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: Brightness.light,
      scaffoldBackgroundColor: WearableColors.background,
      canvasColor: WearableColors.background,
      dividerColor: WearableColors.border,
      fontFamily: WearableType.family,
      fontFamilyFallback: WearableType.fallback,
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          height: 38 / 32,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          color: WearableColors.foreground,
        ),
        displayMedium: TextStyle(
          fontSize: 28,
          height: 32 / 28,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          color: WearableColors.foreground,
        ),
        headlineLarge: TextStyle(
          fontSize: 24,
          height: 30 / 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
          color: WearableColors.foreground,
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          height: 26 / 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: WearableColors.foreground,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          height: 26 / 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: WearableColors.foreground,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          height: 20 / 15,
          fontWeight: FontWeight.w700,
          color: WearableColors.foreground,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          height: 24 / 16,
          fontWeight: FontWeight.w400,
          color: WearableColors.foreground,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          height: 20 / 14,
          fontWeight: FontWeight.w400,
          color: WearableColors.foreground,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          height: 16 / 12,
          fontWeight: FontWeight.w400,
          color: WearableColors.mutedFg,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          height: 20 / 14,
          fontWeight: FontWeight.w600,
          color: WearableColors.foreground,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          height: 14 / 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
          color: WearableColors.mutedFg,
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: WearableColors.background,
        foregroundColor: WearableColors.foreground,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: WearableType.family,
          fontFamilyFallback: WearableType.fallback,
          fontWeight: FontWeight.w600,
          fontSize: 20,
          letterSpacing: -0.2,
          color: WearableColors.foreground,
        ),
      ),
      // White card, no hairline, one soft diffuse shadow — doc §4 shadow-card.
      cardTheme: CardThemeData(
        color: WearableColors.card,
        elevation: 1,
        shadowColor: const Color(0x0F000000),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WearableRadii.lg),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: WearableColors.primary,
          foregroundColor: WearableColors.onPrimary,
          textStyle: const TextStyle(
            fontFamily: WearableType.family,
            fontFamilyFallback: WearableType.fallback,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WearableRadii.full),
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: WearableColors.foreground,
          side: const BorderSide(color: WearableColors.border),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(WearableRadii.full),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: WearableColors.info),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: WearableColors.card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WearableRadii.md),
          borderSide: const BorderSide(color: WearableColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WearableRadii.md),
          borderSide: const BorderSide(color: WearableColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(WearableRadii.md),
          borderSide: const BorderSide(color: WearableColors.primary, width: 2),
        ),
        hintStyle: const TextStyle(color: WearableColors.mutedFg),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(WearableColors.card),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? WearableColors.accentSky
              : WearableColors.secondary,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(WearableColors.border),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: WearableColors.primary),
      dividerTheme: const DividerThemeData(color: WearableColors.border, thickness: 1, space: 1),
      // Primary action is a solid black circle — doc §6, 72 dp.
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: WearableColors.primary,
        foregroundColor: WearableColors.onPrimary,
        shape: CircleBorder(),
      ),
      iconTheme: const IconThemeData(color: WearableColors.foreground),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: WearableColors.background,
        selectedItemColor: WearableColors.foreground,
        unselectedItemColor: WearableColors.mutedFg,
        type: BottomNavigationBarType.fixed,
      ),
      // Active tab = black pill around the icon, near-black label beneath.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: WearableColors.background,
        elevation: 0,
        height: 80,
        indicatorColor: WearableColors.primary,
        indicatorShape: const StadiumBorder(),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? WearableColors.onPrimary
              : WearableColors.mutedFg,
        )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
          fontFamily: WearableType.family,
          fontFamilyFallback: WearableType.fallback,
          fontSize: 11,
          height: 14 / 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
          color: states.contains(WidgetState.selected)
              ? WearableColors.foreground
              : WearableColors.mutedFg,
        )),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: WearableColors.info,
        unselectedLabelColor: WearableColors.mutedFg,
        indicatorColor: WearableColors.info,
      ),
      // Chips are central to Eloquent: a selected chip is a solid black pill
      // with a white label and no border; an unselected chip is a white pill
      // with a hairline border and a black label. No checkmark, no elevation,
      // no tint. ChoiceChip/FilterChip pick all of this up with nothing but
      // `label`, `selected` and `onSelected`.
      chipTheme: ChipThemeData(
        backgroundColor: WearableColors.card,
        // ChoiceChip reads secondarySelectedColor, FilterChip reads
        // selectedColor — set both so every chip fills black when selected.
        selectedColor: WearableColors.primary,
        secondarySelectedColor: WearableColors.primary,
        disabledColor: WearableColors.cardAlt,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        selectedShadowColor: Colors.transparent,
        showCheckmark: false,
        elevation: 0,
        pressElevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WearableRadii.full),
        ),
        side: WidgetStateBorderSide.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? BorderSide.none
              : const BorderSide(color: WearableColors.border),
        ),
        // RawChip resolves only the *colour* of labelStyle against widget
        // states, so the state swap has to live in the colour. Weight stays
        // constant at the type scale's button-label 600.
        labelStyle: _chipLabelStyle,
        secondaryLabelStyle: _chipLabelStyle,
      ),
    );
  }
}

/// Shadows matching docs/design/design-tokens.md §4. Apply to [Container] or
/// [Card] with `decoration.boxShadow: [WearableShadows.card]`.
class WearableShadows {
  WearableShadows._();

  /// `shadow-card: 0 4px 18px rgb(0 0 0 / 0.06)`
  static BoxShadow get card => const BoxShadow(
    color: Color(0x0F000000),
    blurRadius: 18,
    offset: Offset(0, 4),
  );

  /// `shadow-btn: 0 6px 16px rgb(0 0 0 / 0.18)`
  static BoxShadow get button => const BoxShadow(
    color: Color(0x2E000000),
    blurRadius: 16,
    offset: Offset(0, 6),
  );
}

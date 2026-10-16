// Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
//
// WearableTokens — explicit 1:1 mirror of docs/design/design-tokens.md. The point
// is auditability: when someone touches either side, a diff against this file
// shows where they fell out of lockstep.
//
// The runtime palette + ThemeData composition lives in wearable_theme.dart; this
// file is pure constants. The doc is the source of truth: update it FIRST,
// then this file, then wearable_theme.dart.
//
// server-contract/tests/design-tokens.test.ts enforces the three-way match.

import 'package:flutter/material.dart';

/// Eloquent token snapshot. Add entries when the doc adds a token. Field names
/// match the doc's §1 token column.
class WearableTokens {
  WearableTokens._();

  // ---- Surface scale -----------------------------------------------------
  /// `background: #F4F5FF` — near-white ground, faint lavender tint.
  static const Color background = Color(0xFFF4F5FF);
  /// `card: #FFFFFF`
  static const Color card = Color(0xFFFFFFFF);
  /// `cardAlt: #F1F3F4`
  static const Color cardAlt = Color(0xFFF1F3F4);
  /// `muted: #F1F3F4` (alias of cardAlt — kept distinct for chip backgrounds)
  static const Color muted = Color(0xFFF1F3F4);
  /// `secondary: #E8EAED` — lower-emphasis containers, tag fills.
  static const Color secondary = Color(0xFFE8EAED);
  /// `border: #DADCE0`
  static const Color border = Color(0xFFDADCE0);
  /// `foreground: #000000`
  static const Color foreground = Color(0xFF000000);
  /// `mutedFg: #5F6368` — 6.05:1 on card, 5.57:1 on background (WCAG AA).
  static const Color mutedFg = Color(0xFF5F6368);

  // ---- Action ------------------------------------------------------------
  /// `primary: #000000` — the action colour. Mic button, active pill, filled chip.
  static const Color primary = Color(0xFF000000);
  /// `primary-fg: #FFFFFF`
  static const Color primaryFg = Color(0xFFFFFFFF);
  /// `accentSky: #8AB4F8` — live / cloud-on tint. Non-text.
  static const Color accentSky = Color(0xFF8AB4F8);
  /// `ring: #000000` (focus ring, alias of primary)
  static const Color ring = Color(0xFF000000);

  // ---- Semantic ----------------------------------------------------------
  /// `info: #1967D2`
  static const Color info = Color(0xFF1967D2);
  /// `destructive: #C5221F`
  static const Color destructive = Color(0xFFC5221F);
  /// `warning: #A45400`
  static const Color warning = Color(0xFFA45400);
  /// `success: #188038`
  static const Color success = Color(0xFF188038);
  /// `accentViolet: #8430CE`
  static const Color accentViolet = Color(0xFF8430CE);

  // ---- Geometry ----------------------------------------------------------
  /// `radiusSm` → 8 dp. Tags, small badges.
  static const double radiusSm = 8.0;
  /// `radius` → 12 dp. Inputs, search bar, alt surfaces.
  static const double radius = 12.0;
  /// `radiusLg` → 20 dp. Cards, bottom sheets.
  static const double radiusLg = 20.0;
  /// `radiusFull` → pills, chips, tab indicator, circular buttons.
  static const double radiusFull = 999.0;

  // ---- Typography weights matching the doc's §2 scale --------------------
  /// Body / paragraph weight — 400.
  static const FontWeight weightBody = FontWeight.w400;
  /// Nav + caption labels — 500.
  static const FontWeight weightLabel = FontWeight.w500;
  /// Headlines + button labels — 600.
  static const FontWeight weightStrong = FontWeight.w600;
  /// Display / stat value / card label — 700.
  static const FontWeight weightDisplay = FontWeight.w700;

  // ---- Shadows -----------------------------------------------------------
  /// `shadow-card: 0 4px 18px rgb(0 0 0 / 0.06)`
  static BoxShadow get shadowCard => const BoxShadow(
        color: Color(0x0F000000),
        blurRadius: 18,
        offset: Offset(0, 4),
      );
  /// `shadow-btn: 0 6px 16px rgb(0 0 0 / 0.18)`
  static BoxShadow get shadowBtn => const BoxShadow(
        color: Color(0x2E000000),
        blurRadius: 16,
        offset: Offset(0, 6),
      );

  // ---- Linear gradient (mirrors `gradient-ground`) ----------------------
  /// `linear-gradient(135deg, #FCEEEE 0%, #F1F4FF 35%, #F2FBEF 70%, #EAF4FF 100%)`
  /// One pastel wash behind content. Never inside a card.
  static LinearGradient get gradientGround => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        stops: [0.0, 0.35, 0.7, 1.0],
        colors: [
          Color(0xFFFCEEEE), // coral
          Color(0xFFF1F4FF), // lilac
          Color(0xFFF2FBEF), // mint
          Color(0xFFEAF4FF), // sky
        ],
      );
}

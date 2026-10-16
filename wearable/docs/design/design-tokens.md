<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

<!-- Single source of truth for the app's design tokens. -->
<!-- Flutter (app/lib/wearable/wearable_tokens.dart + app/lib/wearable/wearable_theme.dart) MUST match this file. -->
<!-- Enforced by server-contract/tests/design-tokens.test.ts. -->

# Design Tokens — Eloquent

This document is the canonical reference for every colour, font, radius, and spacing value
used by the Flutter app (firmware LED palette excepted — the LED vocabulary lives in the
master spec §3.4).

When the design needs to change: **edit this file first**, then propagate to
`app/lib/wearable/wearable_tokens.dart` and `app/lib/wearable/wearable_theme.dart`. Never edit those files
first. `server-contract/tests/design-tokens.test.ts` fails if they fall out of lockstep.

## Design language

Modelled on **Google AI Edge Eloquent**. The rules that generate the token values:

- **Light only.** A near-white ground with a faint lavender/blue tint, overlaid by one soft
  pastel gradient wash (coral → lilac → mint → sky). There is no dark variant.
- **Contrast lives in the action, not the chrome.** The primary action is solid black on
  near-white. Everything else is neutral.
- **Cards are white, not outlined.** 20 dp corners, no hairline, one soft diffuse shadow.
- **Selection is a black pill.** Active tab, active chip, primary button — same vocabulary.
- **Colour is semantic only.** Blue for links and live/cloud state, red/amber/green for
  status. No brand hue.

---

## 1. Colour palette

| Token | Hex | Usage |
|---|---|---|
| `background` | `#F4F5FF` | Scaffold / page ground — near-white, faint lavender tint |
| `card` | `#FFFFFF` | Card, sheet, list-item surface |
| `cardAlt` / `muted` | `#F1F3F4` | Alt surface inside a card, subtle fill |
| `secondary` | `#E8EAED` | Lower-emphasis containers, tag fills |
| `border` | `#DADCE0` | 1 dp hairline on chips, inputs, dividers |
| `foreground` | `#000000` | Headlines and body text |
| `mutedFg` | `#5F6368` | Helper text, captions, inactive tab labels + icons |
| `primary` | `#000000` | The action colour — mic button, active pill, filled chip |
| `onPrimary` / `primary-fg` | `#FFFFFF` | Text/icon on primary-filled elements |
| `accentSky` | `#8AB4F8` | Live / cloud-on tint (privacy toggle track, recording pulse) |
| `ring` | `#000000` | Focus ring (matches primary) |
| `info` | `#1967D2` | Links, active underlined tab, informational badges |
| `destructive` | `#C5221F` | Delete, error, cancel |
| `warning` | `#A45400` | Overdue, pending, low battery, habitat alerts |
| `success` | `#188038` | Confirmed, connected, done |
| `accentViolet` | `#8430CE` | Fourth role hue, kept separable from `info` |

### Accessibility

Ratios are computed against the two grounds text actually lands on: `card` `#FFFFFF` and
`background` `#F4F5FF`. Every text token clears **WCAG 2.1 AA for normal-size text (4.5:1)**,
so no style depends on a large-text exemption.

| Pair | On `#FFFFFF` | On `#F4F5FF` | Verdict |
|---|---|---|---|
| `foreground` `#000000` | 21.00:1 | 19.35:1 | AA / AAA |
| `onPrimary` on `primary` | 21.00:1 | — | AA / AAA |
| `mutedFg` `#5F6368` | 6.05:1 | 5.57:1 | AA / AAA |
| `info` `#1967D2` | 5.37:1 | 4.95:1 | AA |
| `destructive` `#C5221F` | 5.80:1 | 5.34:1 | AA |
| `warning` `#A45400` | 5.46:1 | 5.03:1 | AA |
| `success` `#188038` | 5.02:1 | 4.63:1 | AA |
| `accentViolet` `#8430CE` | 6.37:1 | 5.87:1 | AA |

Two deliberate deviations from the Eloquent screenshots:

1. **`mutedFg` is one step darker than the reference.** Eloquent's inactive tab labels and
   helper text sample at ≈`#80868B`, which is **3.68:1** on white — fine for graphics, but a
   fail for 11–16 dp label text. `#5F6368` keeps the same neutral cast and passes AA.
2. **Non-text tokens sit below 3:1 by design.** `border` `#DADCE0` (1.37:1) and `secondary`
   `#E8EAED` (1.21:1) are decorative fills and hairlines; `accentSky` `#8AB4F8` (2.11:1) is a
   toggle track. None of them is the sole means of identifying a control — every control is
   identified by its black label or its black filled state — so WCAG 1.4.11 is met through
   the text, not the hairline. Do not use these three as the only signal for anything.

## 2. Typography

The app ships no font binary. Eloquent renders in Google Sans; we name the geometric faces a
device may already have, then fall back to the bundled `SF Pro Display` (declared in
`app/pubspec.yaml`, so it always resolves on both platforms) and finally to `Roboto` for
glyph coverage the first two lack.

| Token | Value |
|---|---|
| Family | `Google Sans` |
| Fallback | `SF Pro Display`, `Roboto` |
| Weights used | 400 / 500 / 600 / 700 |

Large type is tightly tracked; body type is loosely leaded. Sizes are dp; `Slot` is the
Flutter `TextTheme` field carrying the style.

| Style | Slot | Size | Line-height | Weight | Letter-spacing |
|---|---|---|---|---|---|
| Display | `displayLarge` | 32 | 38 | 700 | -0.5 |
| Stat value | `displayMedium` | 28 | 32 | 700 | -0.5 |
| Headline L | `headlineLarge` | 24 | 30 | 600 | -0.3 |
| Headline | `headlineMedium` / `titleLarge` | 20 | 26 | 600 | -0.2 |
| Card label | `titleMedium` | 15 | 20 | 700 | 0 |
| Body L | `bodyLarge` | 16 | 24 | 400 | 0 |
| Body | `bodyMedium` | 14 | 20 | 400 | 0 |
| Caption | `bodySmall` | 12 | 16 | 400 | 0 |
| Button label | `labelLarge` | 14 | 20 | 600 | 0 |
| Nav label | `labelSmall` | 11 | 14 | 500 | 0.1 |

## 3. Radius

| Token | Value | Usage |
|---|---|---|
| `radiusSm` | 8 dp | Tags, small badges |
| `radius` | 12 dp | Inputs, search bar, alt surfaces |
| `radiusLg` | 20 dp | Cards, bottom sheets |
| `radiusFull` | 999 dp | Pills, chips, tab indicator, circular buttons |

## 4. Shadow

Eloquent has no glow. Both shadows are neutral black at low alpha.

| Token | Value | Usage |
|---|---|---|
| `shadow-card` | `0 4px 18px rgb(0 0 0 / 0.06)` | White card on the tinted ground |
| `shadow-btn` | `0 6px 16px rgb(0 0 0 / 0.18)` | Black primary action (mic) |

## 5. Gradients

| Token | Value |
|---|---|
| `gradient-ground` | `linear-gradient(135deg, #FCEEEE 0%, #F1F4FF 35%, #F2FBEF 70%, #EAF4FF 100%)` |

One wash, sampled from the reference blob. Applied behind content, never inside a card.

## 6. Layout primitives

| Token | Value |
|---|---|
| Card padding | 16 dp |
| Card gap (list pitch minus card height) | 12 dp |
| Bottom-nav height | 80 dp |
| Nav indicator (active tab pill) | 64 × 32 dp |
| Primary action diameter (mic) | 72 dp |
| Touch target min | 44 dp |

---

## 7. Drift audit

Pass = the source matches this file. Captured **2026-09-06** and re-checked on every run of
`server-contract/tests/design-tokens.test.ts`, which asserts that each hex below appears in
this document **and** as `0xFF…` in both Dart files, and that no retired value survives.

| Token | This file | `wearable_tokens.dart` | `wearable_theme.dart` |
|---|---|---|---|
| `background` | `#F4F5FF` | `0xFFF4F5FF` | `0xFFF4F5FF` |
| `card` | `#FFFFFF` | `0xFFFFFFFF` | `0xFFFFFFFF` |
| `cardAlt` / `muted` | `#F1F3F4` | `0xFFF1F3F4` | `0xFFF1F3F4` |
| `secondary` | `#E8EAED` | `0xFFE8EAED` | `0xFFE8EAED` |
| `border` | `#DADCE0` | `0xFFDADCE0` | `0xFFDADCE0` |
| `foreground` | `#000000` | `0xFF000000` | `0xFF000000` |
| `mutedFg` | `#5F6368` | `0xFF5F6368` | `0xFF5F6368` |
| `primary` | `#000000` | `0xFF000000` | `0xFF000000` |
| `onPrimary` | `#FFFFFF` | `0xFFFFFFFF` | `0xFFFFFFFF` |
| `accentSky` | `#8AB4F8` | `0xFF8AB4F8` | `0xFF8AB4F8` |
| `info` | `#1967D2` | `0xFF1967D2` | `0xFF1967D2` |
| `destructive` | `#C5221F` | `0xFFC5221F` | `0xFFC5221F` |
| `warning` | `#A45400` | `0xFFA45400` | `0xFFA45400` |
| `success` | `#188038` | `0xFF188038` | `0xFF188038` |
| `accentViolet` | `#8430CE` | `0xFF8430CE` | `0xFF8430CE` |

### Retired

The previous dark/emerald theme is gone, not deprecated. These values must not reappear:
`#0A0A0A`, `#141414`, `#1F1F1F`, `#333333`, `#FAFAFA`, `#A0A0A0`, `#10B981`, `#14C491`,
`#334840`, `#EF4444`, `#F59E0B`, `#3B82F6`, `#22C55E`, `#B57AF0`, `#111A14`, and the
`Montserrat` font family. The `primaryGlow` token, the `shadow-glow` token, the
`gradient-hero` token, and `WearableTheme.dark()` were removed with them.

---

## 8. How to extend

When adding a new token:
1. Add it to §1 (or the appropriate section) above with hex + usage, and to the §7 audit table.
2. If it carries text, add its contrast ratios to the §1 accessibility table and confirm 4.5:1.
3. Add the constant to `WearableTokens` in `app/lib/wearable/wearable_tokens.dart`.
4. Add the constant to `WearableColors` in `app/lib/wearable/wearable_theme.dart` and wire it into
   `WearableTheme.light()`.
5. Run `bun test server-contract/tests/design-tokens.test.ts`. It must be green before push.

Avoid adding gradients or shadow blends ad-hoc in widget code. Promote them to a token.

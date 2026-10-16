/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. */

/**
 * Design token drift guard.
 *
 * `docs/design/design-tokens.md` is the SSOT for every colour, font, radius,
 * and shadow value the app uses. This test pins the token table against both
 * Dart mirrors — `app/lib/wearable/wearable_tokens.dart` (pure constants) and
 * `app/lib/wearable/wearable_theme.dart` (the ThemeData composition) — so touching one
 * source without the others fails loud.
 *
 * The contract, in the order the doc mandates: doc first, then wearable_tokens,
 * then wearable_theme. Each token must appear as `#RRGGBB` in the doc and as
 * `0xFFRRGGBB` in both Dart files. Retired values must appear in none of them.
 */
import { describe, expect, it } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

const DOC_PATH = path.join(REPO_ROOT, "docs", "design", "design-tokens.md");
const TOKENS_PATH = path.join(REPO_ROOT, "app", "lib", "wearable", "wearable_tokens.dart");
const THEME_PATH = path.join(REPO_ROOT, "app", "lib", "wearable", "wearable_theme.dart");

const read = (p: string) => (fs.existsSync(p) ? fs.readFileSync(p, "utf8") : "");

const doc = read(DOC_PATH);
const tokensDart = read(TOKENS_PATH);
const themeDart = read(THEME_PATH);

/** Token table — must match `docs/design/design-tokens.md` §1 and §7. */
const EXPECTED_TOKENS: ReadonlyArray<[string, string]> = [
  ["background", "F4F5FF"],
  ["card", "FFFFFF"],
  ["cardAlt / muted", "F1F3F4"],
  ["secondary", "E8EAED"],
  ["border", "DADCE0"],
  ["foreground / primary / ring", "000000"],
  ["mutedFg", "5F6368"],
  ["accentSky", "8AB4F8"],
  ["info", "1967D2"],
  ["destructive", "C5221F"],
  ["warning", "A45400"],
  ["success", "188038"],
  ["accentViolet", "8430CE"],
];

/** The dark/emerald theme is gone, not deprecated. See doc §7 "Retired". */
const RETIRED: ReadonlyArray<string> = [
  "0A0A0A",
  "141414",
  "1F1F1F",
  "333333",
  "FAFAFA",
  "A0A0A0",
  "10B981",
  "14C491",
  "334840",
  "EF4444",
  "F59E0B",
  "3B82F6",
  "22C55E",
  "B57AF0",
  "111A14",
  "Montserrat",
  "emerald",
  "primaryGlow",
];

/** Radii — doc §3. */
const EXPECTED_RADII: ReadonlyArray<[string, string]> = [
  ["radiusSm", "8.0"],
  ["radius", "12.0"],
  ["radiusLg", "20.0"],
  ["radiusFull", "999.0"],
];

describe("design-tokens SSOT — sources exist", () => {
  it("docs/design/design-tokens.md exists and is non-empty", () => {
    expect(doc.length).toBeGreaterThan(1000);
  });

  it("app/lib/wearable/wearable_tokens.dart exists", () => {
    expect(tokensDart.length).toBeGreaterThan(0);
  });

  it("app/lib/wearable/wearable_theme.dart exists", () => {
    expect(themeDart.length).toBeGreaterThan(0);
  });
});

describe("design-tokens SSOT — doc and Dart agree", () => {
  for (const [name, hex] of EXPECTED_TOKENS) {
    it(`${name} is #${hex} in the doc`, () => {
      expect(doc).toContain(`#${hex}`);
    });

    it(`${name} is 0xFF${hex} in wearable_tokens.dart`, () => {
      expect(tokensDart).toContain(`0xFF${hex}`);
    });

    it(`${name} is 0xFF${hex} in wearable_theme.dart`, () => {
      expect(themeDart).toContain(`0xFF${hex}`);
    });
  }
});

describe("design-tokens SSOT — retired values are gone", () => {
  for (const value of RETIRED) {
    it(`no source mentions ${value}`, () => {
      const haystack = `${doc}\n${tokensDart}\n${themeDart}`;
      // The doc's §7 "Retired" list names them on purpose; strip it first.
      const withoutRetiredSection = haystack.replace(
        /### Retired[\s\S]*?\n---\n/,
        "",
      );
      expect(withoutRetiredSection.toLowerCase()).not.toContain(value.toLowerCase());
    });
  }
});

describe("design-tokens SSOT — typography and geometry", () => {
  it("doc declares the Google Sans stack", () => {
    expect(doc).toContain("Google Sans");
    expect(doc).toContain("SF Pro Display");
  });

  it("wearable_theme.dart declares the same font stack", () => {
    expect(themeDart).toContain("'Google Sans'");
    expect(themeDart).toContain("'SF Pro Display'");
    expect(themeDart).toContain("'Roboto'");
  });

  it("the theme is light-only — WearableTheme.light(), no dark()", () => {
    expect(themeDart).toContain("static ThemeData light()");
    expect(themeDart).not.toContain("ThemeData dark()");
  });

  for (const [name, value] of EXPECTED_RADII) {
    it(`wearable_tokens.dart declares ${name} = ${value}`, () => {
      expect(tokensDart).toContain(`${name} = ${value}`);
    });
  }

  it("WearableRadii in wearable_theme.dart matches the doc's radius scale", () => {
    expect(themeDart).toContain("sm = 8.0");
    expect(themeDart).toContain("md = 12.0");
    expect(themeDart).toContain("lg = 20.0");
    expect(themeDart).toContain("full = 999.0");
  });
});

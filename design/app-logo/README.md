# App logo and intro

OrphusBot's logo: a rounded robot head outline with square eyes, a coiled
antenna and a cyan light. Chosen by the owner from Media Creator's concepts
(nano-banana-2-1) and built as vectors with the [Rive CLI](https://rive.app/docs/cli/overview).

- `scene.rml`, `rive.yaml`: the Rive project. Two artboards, 512x512 on a
  transparent background: `Intro`, whose state machine `Intro` plays the
  1.6 s opening once (the head pops in squashed, stretches and settles, the
  eyes blink on, the coil springs up, the light pulses) and holds on the logo;
  and `Logo`, the still mark. Build with `rive . --once`; check with
  `rive . --verify` and `rive inspect . --summary`.
- `logo-1024.png`: the `Logo` artboard rendered on black, the source of the
  large app icons. `icon-small-256.png` (from `small-icon-source.png`): the
  same head with a thicker, simpler coil for icons at 64 px and under.

The app plays `assets/brand/intro.riv` at launch (`lib/intro.dart`). Icons:
Android adaptive (`mipmap-anydpi-v26`, black background), the Mac's
`AppIcon.appiconset`, and Linux's `orphusbot` icon in the hicolor theme.

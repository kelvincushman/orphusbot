# Scout report — documentation upstream audit

**Scope:** every `.md` in the repo (46 files, 8,698 lines).
**Method:** full read of every doc, plus mechanical checks — relative-link resolution,
code-span path resolution against the real tree, URL extraction, and `git log -p` archaeology
against commit `53dd556 refactor: rebrand upstream product name to kelvinlee throughout`
to recover what the `example.com` placeholders originally pointed at.
**Status:** audit only. Nothing rewritten.

---

## 0. The headline finding

The rebrand replaced the upstream brand token `omi` with **`kelvinlee`** — the author's own
name — across 1,047 files and 3,269 occurrences (`53dd556`). Inside *our own* documents that
substitution is harmless. Inside the **inherited upstream documents it is actively harmful**,
because those documents describe upstream's product, and the sed turned every sentence about
upstream's product into a sentence that appears to describe a product called "KelvinLee":

> `firmware/readme.md:5` — "This repository contains the firmware for the KelvinLee AI wearable device."
> `firmware/scripts/devkit/KelvinLeeSimulator/README.md:5` — "Simulator of BasedHardware KelvinLee device."
> `firmware/kelvinlee/README.md:5` — "The firmware for the KELVINLEE consumer version."

These read as a brand claim over upstream's hardware. The correct fix for the (b) documents is
not a better rename — it is **deletion**, because they document hardware and workflows this
project does not build or ship.

Second headline: `LICENSE-UPSTREAM` (MIT, © 2024 Based Hardware Contributors) is the **only**
licence file in the repo. There is no `LICENSE` for our own code, despite every file header
asserting "Licensed under MIT. Copyright (c) 2025-2026 Kelvin Lee."

---

## 1. Per-file classification

Legend: **(a)** ours, about our system · **(b)** inherited, describes upstream ·
**(c)** mixed.

### Root

| File | Class | Note |
|---|---|---|
| `README.md` | **(c)** | Excellent and largely ours, but §Provenance, §"A note on paths in the docs", and §Security are structured *around* the extraction rather than around the project. |

### `app/`

| File | Class | Note |
|---|---|---|
| `app/README.md` | **(b)** | Upstream's Omi app README verbatim, brand-substituted. Two dead `example.com` links. |
| `app/Tasks.md` | **(b)** | Upstream's original `AppWithWearable` TODO list, ~2024 vintage. Nothing in it is ours. |
| `app/lib/wearable/README.md` | **(c)** | Our adapter, but framed as "integration layer *for the KelvinLee Flutter app*", with monorepo paths and a Firebase-still-present section. |
| `app/ios/.../{LaunchImage,devLaunchImage,prodLaunchImage}.imageset/README.md` ×3 | neutral | Flutter template boilerplate. Harmless, but each falsely carries `Portions (c) 2024 Based Hardware Contributors`. |

### `docs/`

| File | Class | Note |
|---|---|---|
| `docs/BUILD_FIRMWARE.md` | **(c)** | Our build variant, but §"Upstream compatibility" is a release-history table of *upstream's* releases attributed to an upstream maintainer. |
| `docs/HABITAT_ALERTS.md` | **(a)** | Genuinely original design work. Every path in it is a monorepo path that does not exist here. |
| `docs/PIN_MAP.md` | **(a)** | Original. Minor upstream framing ("the kelvinlee triangle v2 reference", "upstream devkit v2 overlay"). |
| `docs/TEST_HARNESS.md` | **(c)** | Documents upstream's Python/Xcode tools ("The upstream KelvinLee repo ships…"), which we vendored verbatim. |
| `docs/design/design-tokens.md` | **(a)** | Ours. Contract is stated against monorepo paths. |
| `docs/design/app-design-system.md` | **(c)** | `.docx` conversion. Whole document is written as a *diff against upstream's app*; §7 is literally "Differences from Upstream KelvinLee App". |
| `docs/design/per-screen-spec.md` | **(c)** | Same — "what must be added to the existing KelvinLee Flutter app". Amber callouts = "KelvinLee elements to modify". |
| `docs/design/master-reference.md` | **(c)** | Ours in conception, but describes the *server* system, the monorepo filetree, and a specific LAN host. |
| `docs/plans/wearable-one-product-pivot.md` | **(c)** | 782-line strategy doc for the monorepo. 40 `devices/wearable-…` refs, 29 `src/…` refs. |
| `docs/plans/2026-06-07-wearable-m1-shell-entry.md` | **(c)** | Implementation plan against the upstream Flutter tree; instructs deleting upstream screens. |
| `docs/product/APP-NAVIGATION.md` | **(c)** | Screen-by-screen triage of the *upstream* app, plus real device IDs and a real pairing token. |
| `docs/product/BUTTON_FEEDBACK_SPEC.md` | **(a)** | Clean. Fully ours. No upstream residue, no bad paths. Best doc in the repo. |
| `docs/product/HardwareSetup.md` | **(a)** | Original assembly guide with real BOM. 7 monorepo path refs. |
| `docs/product/PRD-wearable-agentic-cos.md` | **(a)** | Ours — but 100% **server-side**, for a backend not in this repo. |
| `docs/product/PRD-wearable-app.md` | **(c)** | Ours, but the whole plan is "strip & rebrand upstream's app". |
| `docs/product/PRD-bug-b-ambient-classify.md` | **(a)** | Server-side bug spec. Not about this repo. |
| `docs/product/PRD-chat-attachments.md` | **(a)** | Server-side endpoint spec. Not about this repo. |
| `docs/product/PROMPT-server-device-first-pipeline.md` | **(a)** | A *prompt* addressed to another coding assistant. Not documentation. |
| `docs/product/SERVER-CHANGES.md` | **(a)** | A stale server to-do list ("committed locally but not deployed"). |
| `docs/product/WAKEWORD-ONDEVICE-PROTOTYPE.md` | **(a)** | Genuine original firmware R&D. Keepable. |
| `docs/product/REVIEW_FINDINGS.md` | **(a)** | Internal punch list about monorepo files, referencing `.claude/agents/*` that don't exist here. |
| `docs/server/ARCHITECTURE.md` | **(a)** | 882 lines describing **a different repository**. Links to six `docs/*.md` that do not exist here. Leaks the deployment host's filesystem layout. |

### `firmware/`

| File | Class | Note |
|---|---|---|
| `firmware/readme.md` | **(b)** | Upstream firmware README. Describes `kelvinlee/` + `devkit/` + `boards/` as upstream's tree. |
| `firmware/BUILD_AND_OTA_FLASH.md` | **(b)** | 346 lines for the **nRF5340 consumer device** — hardware this project does not build. We build XIAO nRF52840. |
| `firmware/kelvinlee/README.md` | **(b)** | Upstream's consumer-firmware WIP checklist, including their internal notes and two GitHub asset screenshots. |
| `firmware/FLASH_3.0.8/README.md` | **(b)** | J-Link flashing for upstream's v3.0.8 nRF5340 release. |
| `firmware/scripts/docker-build.md` | **(b)** | Upstream's Docker build path; every command starts `./kelvinlee/firmware/…` (a path that does not exist). |
| `firmware/test/README.md` | **(b)** | Upstream's EVT board test commands. |
| `firmware/test/BLE_THROUGHPUT_TEST.md` | **(b)** | Upstream's throughput harness. (The `.c` it references *does* exist locally — this one is at least self-consistent.) |
| `firmware/scripts/devkit/KelvinLeeSimulator/README.md` | **(b)** | Explicitly names the upstream vendor and the pre-rebrand product names. |

### `hardware/`

| File | Class | Note |
|---|---|---|
| `hardware/cad/triangle v2 w memory/README.md` | **(b)** | Upstream's full 11-step assembly guide for **their** speaker-based enclosure — a build `docs/PIN_MAP.md` explicitly says we diverge from. Includes their dated field-fix notice ("devices assembled before August 23, 2024"). |
| `hardware/cad/consumer-watch-band/Updated Complete Watch Band/README.md` | **(b)** | Community-contributed watch band for upstream's device. |
| `hardware/cad/consumer-watch-band/1.5cm-watch-band-case/ReadMe.md` | **(b)** | Ditto; credits an upstream community contributor by handle. |
| `hardware/docs/xiao-ble-nrf52840-sense.md` | **(a)** | Third-party mirror of Seeed's wiki, properly source-attributed. **But** the header asserts `Copyright (c) 2025-2026 Kelvin Lee` over Seeed's content. |
| `hardware/docs/adafruit-microsd-bff.md` | **(a)** | Same shape — Adafruit mirror, same copyright-assertion problem. |
| `hardware/docs/adafruit-iot-button-neopixel-bff.md` | **(a)** | Same. |

### `tools/`, `scripts/`, `feature-research/`

| File | Class | Note |
|---|---|---|
| `tools/wearable_test/README.md` | **(a)** | Ours. Only residue: the sim "advertises the KelvinLee GATT profile" / `advertising 'KelvinLee'`. |
| `scripts/adb-e2e/README.md` | **(a)** | Ours and clean. Contains a real ADB device serial. |
| `feature-research/own-stack/plan.md` | **(a)** | Ours. This is the doc that authorises the present work ("Phase 3 — Docs rewritten, `LICENSE` (MIT, Kelvin Lee), `LICENSE-UPSTREAM` removed"). |

**Totals:** (a) 23 · (b) 14 · (c) 9 (3 neutral Flutter-template files counted in (a)).

---

## 2. Quoted evidence — passages describing upstream, not us

### 2.1 Upstream's product identity presented as ours

- `firmware/readme.md:3-9`
  > "# KelvinLee Firmware … This repository contains the firmware for the KelvinLee AI wearable device."
  > "- `kelvinlee/`: The main application project files"
  > "- `devkit/`: The development kit application project files (for KelvinLee DevKit1, KelvinLee DevKit2)"

  DevKit1/DevKit2 are upstream's product SKUs. We ship neither.

- `firmware/kelvinlee/README.md:5` — "The firmware for the KELVINLEE consumer version."
  Followed by upstream's own engineering diary, e.g. `:59` "Long press to chat with kelvinlee"
  and `:33` "Test with the KELVINLEE app (iOS/Android)" — an app store product we do not publish.

- `firmware/scripts/devkit/KelvinLeeSimulator/README.md:5,13-14`
  > "Simulator of BasedHardware KelvinLee device."
  > "However, previoys versions of the KelvinLee app looked for a device named "Friend" (or "Super")."
  > "In AppWithWearable project, in file /lib/utils/ble/scan.dart, at line 11 …"

  `Friend`, `Super`, and `AppWithWearable` are upstream's pre-rebrand product/repo names. The
  sed did not catch them. The same leak survives in `docs/TEST_HARNESS.md:47` — "The Wearable
  firmware advertises as **`Friend`** (upstream's default) — we'll rename it in a later phase."
  — and in the on-disk filename `firmware/scripts/devkit/play_sound_on_friend.py`.

### 2.2 Hardware we do not build

- `firmware/BUILD_AND_OTA_FLASH.md:20,35`
  > "**Target Device**: KELVINLEE device with nRF5340 SoC (dual-core ARM Cortex-M33)"
  > "The KELVINLEE firmware is a dual-core nRF5340 application …"

  Our device is a **single-core nRF52840** (XIAO BLE Sense). The entire 346-line guide, plus
  `firmware/kelvinlee/`, `firmware/boards/kelvinlee/` (nRF5340 board files) and
  `firmware/FLASH_3.0.8/`, target a board this project does not own. The build command at
  `:143` — `west build -b kelvinlee/nrf5340/cpuapp ../kelvinlee --sysbuild` — cannot be run
  against our hardware.

- `hardware/cad/triangle v2 w memory/README.md:8`
  > "KelvinLee Triangle v2 is an upgraded version of KelvinLee Triangle v1, featuring added
  > memory, a speaker, and a configurable momentary button."

  `docs/PIN_MAP.md:11` explicitly contradicts this as our build:
  > "this stack **diverges** from the kelvinlee triangle v2 reference … Triangle v2 uses the
  > Adafruit 5769 Audio BFF (speaker + button combo) which owns A1/A2/A3 for I2S. Kelvin's
  > build drops the speaker."

  So the repo ships a 400-line soldering guide for a device it documents itself as *not*
  building, alongside a second soldering guide (`docs/product/HardwareSetup.md`) for the one it
  does. Two contradictory assembly guides is worse than one.

### 2.3 Upstream's release process and support channels

- `docs/BUILD_FIRMWARE.md:6`
  > "Upstream firmware: `devkit/` variant of the KelvinLee Zephyr tree — currently at **DK2
  > v2.0.10** (tag `KelvinLee_DK2_v2.0.10`, released 2026-04-26 by `@beastoin`)."

  `@beastoin` is an upstream maintainer's handle. `KelvinLee_DK2_v2.0.10` is a rename of
  upstream's release tag. Neither exists in our repo.

- `docs/BUILD_FIRMWARE.md:12-17` — a five-row table of *upstream's* release history
  (v2.0.5 → v2.0.10, "battery-drain-in-sleep fix", "Device startup post-OTA"). This is upstream's
  changelog, not ours.

- `firmware/FLASH_3.0.8/README.md:20-25`
  > "1. Go to the upstream firmware releases page"
  > "3. Download the following files: `merged.hex` … `merged_CPUNET.hex`"

  A previous pass stripped the URL but left the instruction, so the procedure is now
  unfollowable. (`_CPUNET` is the nRF5340 network core — again, not our silicon.)

- `docs/BUILD_FIRMWARE.md:25`
  > "Obtain the stock `DK2_v2.0.10.uf2` image from your own archive of the upstream release"

  Same pattern: link removed, instruction left dangling.

- `app/README.md:61` — "💬 Join our [Discord Community](http://example.com)" — upstream's
  support channel, which we do not operate.

### 2.4 Upstream's cloud services and product decisions

- `app/Tasks.md` is entirely upstream's 2024 backlog and is the densest concentration of
  services we do not run:
  > `:31` "Settings Deepgram + openAI key are forced to be set"
  > `:32-33` "In case an API key fails, either Deepgram WebSocket connection fails, or GPT requests…"
  > `:41` "Allow users who don't have a GCP bucket to store their recordings locally."
  > `:57` "(Idea) Detect a keyword or special order e.g. "Hey Friend""
  > `:63` "so that friend recognizes when is you the one speaking"

  It also describes upstream's internal architecture — `AppStandalone`, `_ragContext`,
  `MemoryRecord`, `AppWithWerable` [sic] — none of which exist in `app/lib/wearable/`.

- `docs/design/master-reference.md:333`
  > "It reads from the server, not from KelvinLee's Firebase Action Items — those are deprecated."
- `docs/design/master-reference.md:484` — "Which KelvinLee-compatible plugins are enabled per business."
- `docs/design/app-design-system.md:576` — "Removed from nav; KelvinLee plugin manifest still loaded internally for memory plugins"
- `docs/design/app-design-system.md:424,557` — "KelvinLee-specific items (Referral Program, Get KelvinLee for Mac) are removed" / "Includes Referral, Get KelvinLee for Mac"

  Referral programmes, a Mac app, a plugin marketplace, and Firebase Action Items are all
  upstream's commercial product decisions. We describe them only to say we deleted them —
  which means an outside reader must learn upstream's product to read our design system.

- `docs/design/per-screen-spec.md:452`
  > "Does not exist. The upstream KelvinLee app has an Apps/Plugins marketplace here."
- `docs/design/per-screen-spec.md:315` — "Tasks are synced with Apple Reminders on iOS."
- `docs/design/app-design-system.md:20` — "replaces KelvinLee purple (#7C3AED) with Wearable emerald (#10B981)"

### 2.5 Upstream's repo layout as our build instructions

- `firmware/scripts/docker-build.md:21-22,90-92`
  ```
  chmod +x kelvinlee/firmware/scripts/build-docker.sh
  ./kelvinlee/firmware/scripts/build-docker.sh
  docker run --rm -it -v "$(pwd):/kelvinlee" … && cd /kelvinlee/firmware/
  ```
  These assume the repo root is a directory named `kelvinlee` containing `firmware/`. Our repo
  root **is** the firmware's parent; the correct path is `firmware/scripts/build-docker.sh`.
  As written, every command in this file fails.

- `firmware/BUILD_AND_OTA_FLASH.md:127-131`
  > "The project uses `kelvinlee.conf` but Zephyr expects `prj.conf`: `cd ../kelvinlee && cp kelvinlee.conf prj.conf`"

  A workaround for upstream's tree layout, for a board we don't build.

---

## 3. External links

### 3.1 `example.com` placeholders — with recovered originals

Recovered by diffing commit `53dd556`. All eight pointed at **upstream's own documentation
site or Discord**; none has a valid "ours" replacement, because we publish no docs site.

| # | File:line | Current placeholder | What it was / was meant to reach |
|---|---|---|---|
| 1 | `app/README.md:7` | `https://example.com/doc/developer/AppSetup` | `https://docs.omi.me/doc/developer/AppSetup` — upstream's app-setup guide |
| 2 | `app/README.md:61` | `http://example.com` | `http://discord.omi.me` — upstream's Discord community |
| 3 | `firmware/readme.md:29` | `https://example.com/doc/developer/firmware/Compile_firmware` | `https://docs.omi.me/doc/developer/firmware/Compile_firmware` |
| 4 | `firmware/readme.md:57` | (same URL) | (same) |
| 5 | `firmware/kelvinlee/README.md:9` | (same URL) | (same) |
| 6 | `firmware/scripts/docker-build.md:7` | `https://example.com/doc/developer/Compile_firmware` | `https://docs.omi.me/doc/developer/Compile_firmware` |
| 7 | `firmware/scripts/docker-build.md:147` | `https://example.com/doc/get_started/Flash_device` | `https://docs.omi.me/doc/get_started/Flash_device` |
| 8 | `firmware/BUILD_AND_OTA_FLASH.md:340` | `https://example.com/` (link text: "KELVINLEE Hardware Documentation") | `https://docs.omi.me/` (link text was "OMI Hardware Documentation") |

**Recommendation:** do **not** fill these in. Every one lives in a file this audit recommends
deleting (§6). If any host file is kept, the link should become a pointer to our own doc, not a
restored upstream link — restoring them re-establishes the upstream dependency we are removing.

### 3.2 Links silently deleted by the same pass (instruction left behind)

These are worse than placeholders, because there is no marker that anything is missing:

| File:line | Current text | Original |
|---|---|---|
| `firmware/FLASH_3.0.8/README.md:20` | "Go to the upstream firmware releases page" | "[Omi GitHub Releases page](https://github.com/BasedHardware/omi/releases)" |
| `docs/BUILD_FIRMWARE.md:25` | "from your own archive of the upstream release" | download link to `https://github.com/BasedHardware/omi/releases/tag/Omi_DK2_v2.0.10` |
| `firmware/test/BLE_THROUGHPUT_TEST.md:87` | "Copy the existing `ble_throughput_test.c` file from this repository." | previously pointed at an upstream PR diff — *this one now resolves correctly*, the file is at `firmware/test/src/ble_throughput_test.c` |
| `firmware/kelvinlee/README.md:24-26` | three bare `- [x]` checklist items | each previously carried a `github.com/BasedHardware/omi/pull/…` comment link |

### 3.3 Placeholders / non-links that need real values

| File:line | Value | Issue |
|---|---|---|
| `tools/wearable_test/README.md:21` | `http://<wearable-host>:3141` | Intentional placeholder. Fine as-is. |
| `docs/product/APP-NAVIGATION.md:218` | "Source (kelvincushman/Wearable-MissionControl)" | Names a *different* repo as the app's source. Wrong for this project. |

### 3.4 Private infrastructure exposed in docs

Not "links" in the usual sense, but they are URLs and they are wrong for a public repo:

| File:line(s) | Leak |
|---|---|
| `docs/design/master-reference.md:24,390,792` · `app-design-system.md:229,410` · `per-screen-spec.md:737,792,800` · `APP-NAVIGATION.md:207,215` | The LAN host `wearable-server.local:3141` hard-coded 10× as "the Wearable dashboard" |
| `docs/server/ARCHITECTURE.md:796,804-824` | Deployment filesystem layout: `/home/pai-server/dev/Wearable`, `/home/pai-server/Wearable`, `/home/pai-server/.claude/plans/lets-create-a-plan-replicated-taco.md`, systemd `.env` split, manual `nohup bun run start` recovery |
| `docs/plans/wearable-one-product-pivot.md:605` | `ssh pai-server "sqlite3 wearable.db …"` |
| `docs/product/APP-NAVIGATION.md:70,207,215,232` | Real device MAC `<BLE MAC>`, device id `<device id>`, and **partial live secrets**: `<device token>` (described in-doc as "**real device token**") and `<dashboard bearer>` (dashboard bearer) |
| `scripts/adb-e2e/README.md:14` | ADB serial `<adb serial>` |

**Security follow-up (out of scope for a docs rewrite, but flag it):**
`docs/screens/15-wearable-session-server.png` is a screenshot of the Session Server page which,
per `APP-NAVIGATION.md:215`, displays the real pairing token. The PNG is committed. It should
be inspected and, if the token is legible, the token rotated and the image redacted or removed.
The same applies to `07-devicestatus.png` (device MAC + server URL).

### 3.5 Links that are fine

All vendor/datasheet links resolve to legitimate third-party sources and should be kept:
Nordic (`developer.nordicsemi.com`, `docs.nordicsemi.com`, `nordicsemi.com`),
Zephyr (`docs.zephyrproject.org`, `github.com/nrfconnect/sdk-nrf`), MCUboot (`docs.mcuboot.com`),
SEGGER (`segger.com/downloads/jlink`), Seeed (`wiki.seeedstudio.com`, `files.seeedstudio.com`,
`seeedstudio.com`), Adafruit (`learn.adafruit.com`, `adafruit.com`, `github.com/adafruit/…`),
Docker (`docker.com`).

**Caveat — BOM links in `hardware/cad/triangle v2 w memory/README.md:43-48,62-76`:** these are
upstream's shopping list (Amazon `a.co` short links, DigiKey, Pine64). They are live, but they
are *upstream's* BOM for *upstream's* speaker build, and `a.co` short links rot. If we write our
own BOM (§5) we should source our own part links, not inherit these.

**Broken/rotting:**
- `github.com/user-attachments/assets/…` ×5 (`firmware/kelvinlee/README.md:17,19`,
  `hardware/cad/consumer-watch-band/**` ×3) — GitHub-issue-attachment CDN URLs pasted by
  upstream contributors. They render inline in those READMEs and are outside our control.
- `app/Tasks.md:17,36,65` — pinecone.io, developers.deepgram.com, github.com/librosa — live,
  but they are upstream's 2024 research notes.

---

## 4. Factually wrong because of the extraction / rebrand

### 4.1 Monorepo paths that no longer exist

`devices/wearable-kelvinlee/…` — **73 occurrences across 15 files**:

| File | Count |
|---|---|
| `docs/plans/wearable-one-product-pivot.md` | 40 |
| `docs/product/REVIEW_FINDINGS.md` | 9 |
| `docs/product/HardwareSetup.md` | 7 |
| `docs/plans/2026-06-07-wearable-m1-shell-entry.md` | 6 |
| `docs/TEST_HARNESS.md`, `docs/HABITAT_ALERTS.md`, `docs/design/design-tokens.md`, `docs/server/ARCHITECTURE.md` | 2 each |
| `README.md`*, `docs/BUILD_FIRMWARE.md`, `docs/design/{app-design-system,per-screen-spec,master-reference}.md`, `docs/product/{PRD-wearable-app,APP-NAVIGATION}.md` | 1 each |

\* `README.md`'s single occurrence is *intentional* — it is the translation table at
`README.md:216-224`. That table is itself the tell: a standalone project should not need a
Rosetta stone for its own docs.

`src/harness/…` and other server paths — **109 occurrences across 11 files**:

| File | Count |
|---|---|
| `docs/server/ARCHITECTURE.md` | 30 |
| `docs/plans/wearable-one-product-pivot.md` | 29 |
| `docs/product/REVIEW_FINDINGS.md` | 15 |
| `docs/design/master-reference.md` | 10 |
| `docs/product/PRD-wearable-agentic-cos.md` | 8 |
| `README.md` | 4 |
| `docs/product/SERVER-CHANGES.md` | 4 |
| `docs/HABITAT_ALERTS.md`, `docs/design/design-tokens.md` | 3 each |
| `app/lib/wearable/README.md` | 2 |
| `docs/product/PRD-bug-b-ambient-classify.md` | 1 |

The extraction moved these to `server-contract/src/device/…` and
`server-contract/src/inngest/…`. Concrete example — `docs/HABITAT_ALERTS.md:9`:

> "Signals flow: Wearable agent result → `src/harness/inngest/device-delivery.ts` picks an alert
> name → `src/harness/device/commands.ts` encodes 4-byte packets → `src/harness/device/channel.ts`
> queues them → … → `devices/wearable-kelvinlee/firmware/devkit/src/agent_commands.c` dispatches"

Five paths, five wrong. The real ones are `server-contract/src/inngest/device-delivery.ts`,
`server-contract/src/device/commands.ts`, `server-contract/src/device/channel.ts`,
`firmware/devkit/src/agent_commands.c`. Same for `:22` and `:37` (`tests/device.test.ts` →
`server-contract/tests/device.test.ts`).

### 4.2 Cross-doc links to docs that were never extracted

`docs/server/ARCHITECTURE.md:6-11` opens by pointing at five documents, **none of which exist
in this repo**:

> "- **`docs/HARNESS.md`** … - **`docs/WORKFLOWS.md`** … - **`docs/RUNBOOK.md`** …
> - **`docs/PDD.md`** … - **`docs/specs/app-design-system.md`**"

(The last one *does* exist, but at `docs/design/app-design-system.md`.) Also referenced and
missing: `docs/PHASE_LAMBDA_WIP.md`, `docs/audits/stealth-browser-2026-05-07.md`,
`docs/plans/missions-harness.md`, `CLAUDE.md`, `config/*`, `scripts/backup.sh`.

Similar dangling refs elsewhere:
- `docs/product/PRD-wearable-app.md:5` → `docs/APP-NAVIGATION.md`, `docs/PRD-wearable-agentic-cos.md` (both now under `docs/product/`)
- `docs/plans/2026-06-07-wearable-m1-shell-entry.md:11,15` → same two
- `docs/product/{SERVER-CHANGES,PROMPT-server-device-first-pipeline}.md` → `docs/PRD-bug-b-ambient-classify.md`
- `docs/product/HardwareSetup.md:7` → `devices/wearable-kelvinlee/docs/PIN_MAP.md` + 6 more
- `docs/product/REVIEW_FINDINGS.md:31` → `.claude/agents/{typescript-reviewer,security-reviewer}.md` (gitignored, never extracted)
- `docs/plans/wearable-one-product-pivot.md:6` → `docs/PDD.md`, `docs/RUNBOOK.md`, `CLAUDE.md`, `config/karpathy-guidelines.md`

Note: the markdown *link* checker reports **0 broken links** — because nearly every one of these
is written in backticks rather than as a link. The breakage is invisible to tooling.

### 4.3 Build instructions that cannot work

| File:line | Instruction | Why it fails |
|---|---|---|
| `firmware/scripts/docker-build.md:21,22,39,92,101,105,119` | `./kelvinlee/firmware/scripts/build-docker.sh`, `-v "$(pwd):/kelvinlee"`, `cd /kelvinlee/firmware/` | No `kelvinlee/` directory at repo root. Correct path is `firmware/scripts/build-docker.sh`. |
| `firmware/BUILD_AND_OTA_FLASH.md:102,143,238,252` | `cd /path/to/kelvinlee/firmware`, `west build -b kelvinlee/nrf5340/cpuapp ../kelvinlee` | Targets nRF5340. Our board is `xiao_ble_sense` (nRF52840). |
| `firmware/BUILD_AND_OTA_FLASH.md:127-131` | `cd ../kelvinlee && cp kelvinlee.conf prj.conf` | Applies to `firmware/kelvinlee/` (nRF5340 consumer app), not `firmware/devkit/`. |
| `firmware/FLASH_3.0.8/README.md:20` | "Go to the upstream firmware releases page" | No URL. Unfollowable. |
| `docs/BUILD_FIRMWARE.md:38` | "From `devices/wearable-kelvinlee/firmware/devkit/`" | Correct path is `firmware/devkit/`. The *command* is right; only the `cd` is wrong. |
| `docs/TEST_HARNESS.md:14,144,161` | `cd devices/wearable-kelvinlee/firmware/scripts/devkit` | Correct path is `firmware/scripts/devkit`. |
| `docs/BUILD_FIRMWARE.md:98` | "open a Deepgram `listen.py` client (`../firmware/scripts/devkit/client.py`)" | There is no `listen.py`; and it names a cloud STT vendor we no longer use on this path. |
| `app/README.md:14-31` | `bash setup.sh ios` … "Ensure GitHub SSH access is set up correctly for **pulling certificates from repositories**" | Upstream's signing-certificate workflow against upstream's private cert repo. Cannot work for anyone else. |

**Verified working:** the root `README.md` build command (`firmware/devkit` +
`prj_wearable.conf` + `overlay/wearable-peripherals.overlay`) matches the real tree — all three
exist. `README.md` is the only place the firmware build is stated correctly.

### 4.4 Screens / specs describing UI that is being deleted

`docs/design/per-screen-spec.md` (1,069 lines) and `docs/design/app-design-system.md` (625) are
written against the upstream Flutter tree — `pages/home/page.dart`, `conversations_page.dart`,
`lib/pages/memories/page.dart`, `lib/pages/apps/**`. Meanwhile
`feature-research/own-stack/plan.md:22` commits to deleting all of it:

> "`app/lib` (Dart) | 298 files upstream-derived | 75 (`lib/wearable`) ours | **delete + minimal new shell**"

So both specs describe screens that Phase 2 removes. `docs/plans/2026-06-07-wearable-m1-shell-entry.md`
is an implementation plan for surgery on that same doomed tree.

`docs/product/APP-NAVIGATION.md` is a snapshot audit ("Status: COMPLETE … 2026-06-07") of a UI
state that no longer holds; several of its findings are already annotated as fixed in-place
(`:222` "~~On-device model reads 'Not installed'~~ **[FIXED — diagnosis corrected]**"). It also
claims 26 screenshots while `README.md:203` claims 28 and `docs/screens/` actually holds 28
(numbered 01–19, 21–28, plus `m1-01-launch.png` — **`20-*.png` is missing**, so the numbering
itself is broken).

### 4.5 Licensing / attribution errors

1. **No `LICENSE` for our own code.** Only `LICENSE-UPSTREAM` exists. Every source and doc
   header says "Licensed under MIT. Copyright (c) 2025-2026 Kelvin Lee" but there is no MIT text
   granting that. `README.md:245-249` promises "Wearable additions: **MIT**" with no file behind it.
2. **False attribution on Flutter template files** — the three
   `app/ios/Runner/Assets.xcassets/*/README.md` carry
   `Portions (c) 2024 Based Hardware Contributors` on stock Flutter boilerplate.
3. **Copyright asserted over third-party content** — `hardware/docs/*.md` are mirrors of
   Seeed's and Adafruit's documentation (correctly `Source:`-attributed in a second comment)
   but headed `Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.` We cannot MIT-license
   Seeed's datasheet text.
4. **Community contributions attributed to us** — `hardware/cad/consumer-watch-band/…` are
   third-party community designs for upstream's device, credited in-body to an upstream
   contributor handle, yet headed with our copyright.
5. `docs/product/APP-NAVIGATION.md:218` records that the shipping app's About screen reads
   *"License: MIT — derived from BasedHardware/kelvinlee"* — i.e. the in-app licence string was
   also brand-substituted and now names a nonexistent upstream.

---

## 5. Gaps — what an original open-source hardware project needs and we lack

| # | Missing | Why it matters | Priority |
|---|---|---|---|
| 1 | **`LICENSE`** (MIT, © 2025-2026 Kelvin Lee) | Every header claims it; no file grants it. The repo is currently *un*licensed for our own contributions. | **P0** |
| 2 | **`NOTICE` / `THIRD-PARTY.md`** | We vendor Xiph Opus (BSD-3, `firmware/devkit/src/lib/opus-1.2.1/`), Zephyr (Apache-2.0), Nordic HAL, MCUboot sample keys, plus Seeed/Adafruit doc mirrors. Nothing enumerates them or their licences. `feature-research/own-stack/plan.md:12` already commits to keeping and attributing Opus. | **P0** |
| 3 | **`CONTRIBUTING.md`** | No statement of how to build, test, branch, sign off, or what a PR must include. Blocking for any external contributor. | **P1** |
| 4 | **`SECURITY.md`** | A wearable that captures ambient audio and holds a bearer token has a real threat surface. No disclosure address, no supported-versions statement. Also the natural home for the MCUboot-sample-keys warning currently buried in `README.md:230-234`. | **P1** |
| 5 | **Getting started / first-run guide** | `README.md` is a reference, not an on-ramp. There is no "buy these parts → flash → pair → say something → see it work" path. Every existing "getting started" doc is upstream's. | **P1** |
| 6 | **Our own BOM with part numbers and sourcing** | `docs/product/HardwareSetup.md:13-22` has a good BOM table, but no prices, no distributor links, and it lives inside a soldering guide. The only *linked* BOM in the repo is upstream's, for a build we don't do. | **P1** |
| 7 | **`CODE_OF_CONDUCT.md`** | Standard for a community-facing hardware project. | **P2** |
| 8 | **`CHANGELOG.md` + a release/versioning policy** | The firmware advertises `wearable-0.1.0+dk2-2.0.10` but no document says what a release is, how it is cut, or how OTA images are signed and published. The only release process documented is upstream's. | **P2** |
| 9 | **Hardware licence statement** | CAD/enclosure files (`hardware/cad/`) have no licence. Hardware projects normally carry CERN-OHL or CC-BY-SA on physical designs, separate from the software MIT. | **P2** |
| 10 | **Architecture overview *of this repo*** | `docs/server/ARCHITECTURE.md` documents a different system. Nothing describes firmware ↔ app ↔ server-contract for this tree except the `README.md` ASCII diagram. | **P2** |
| 11 | **`docs/TOOLCHAIN.md`** | Named as a deliverable in `feature-research/own-stack/plan.md` (T0.1–T0.4) and referenced there, but not written. Currently the only build path documented is upstream's. | **P2** |
| 12 | **Privacy / data-flow statement** | The pitch is "raw audio never leaves your hardware" (`README.md:11-12`). For a listening device that claim needs its own document with the actual data flows, retention, and the cloud-STT fallback path. | **P2** |
| 13 | **Threat model for the device protocol** | The `0xCAB1AB97` GATT characteristic accepts unauthenticated writes from any paired central. Undocumented. | **P3** |

---

## 6. Rewrite plan, by priority

### Tier 0 — legal correctness (do first; blocks publishing)

| # | Action | File(s) | Justification |
|---|---|---|---|
| 0.1 | **Create `LICENSE`** — MIT, © 2025-2026 Kelvin Lee | new | Every header in the repo claims a licence that does not exist; without it our own code is un-licensed. |
| 0.2 | **Create `NOTICE`/`THIRD-PARTY.md`** listing Opus (BSD-3), Zephyr (Apache-2.0), Nordic HAL, MCUboot, and the Seeed/Adafruit doc mirrors | new | Required by those licences and by `own-stack/plan.md`'s "keep, attribute" decision for Opus. |
| 0.3 | **Strip the false copyright header** from the 3 Flutter-template iOS READMEs and from `hardware/docs/*.md`; replace the latter with an explicit "mirrored from <vendor>, © <vendor>" line | 6 files | We currently assert MIT copyright over Seeed's, Adafruit's, and Flutter's text. |
| 0.4 | **Keep `LICENSE-UPSTREAM` until Phase 1–2 land**, then remove per `own-stack/plan.md` | — | MIT requires the notice to ship while upstream code remains. Removal is earned by deletion, not by this docs pass. |
| 0.5 | **Rotate + redact the leaked pairing token**; audit `docs/screens/15-*.png` and `07-*.png`; scrub `<device token>`, `<dashboard bearer>`, `<BLE MAC>`, `<device id>`, `<adb serial>` from prose | `APP-NAVIGATION.md`, `adb-e2e/README.md`, 2 PNGs | A live device token is committed and self-labelled "real device token". |

### Tier 1 — delete outright (14 files, ~1,100 lines of upstream)

Deleting is preferred to rewriting because every one of these documents *hardware or workflows
this project does not have*. Rewriting them means inventing content; deleting them means the
repo stops claiming things that are not true.

| # | Delete | Justification |
|---|---|---|
| 1.1 | `app/Tasks.md` | Upstream's 2024 backlog. Deepgram/GCP/`AppStandalone`/"Hey Friend" — zero relevance to `lib/wearable/`. |
| 1.2 | `app/README.md` | Upstream's app README; both links are dead placeholders; the setup flow needs upstream's private cert repo. Replace later with a short README for the Wearable app (Tier 3). |
| 1.3 | `firmware/BUILD_AND_OTA_FLASH.md` | 346 lines for nRF5340 hardware we do not build. `docs/BUILD_FIRMWARE.md` is our real guide. |
| 1.4 | `firmware/kelvinlee/README.md` | Upstream's consumer-firmware diary + two GitHub-CDN screenshots. |
| 1.5 | `firmware/FLASH_3.0.8/README.md` | nRF5340 J-Link flashing for upstream's release; the download step has no URL. |
| 1.6 | `firmware/readme.md` | Describes upstream's tree (`kelvinlee/`, `boards/`) as the project. Superseded by root `README.md` §Firmware. |
| 1.7 | `firmware/scripts/docker-build.md` | Every command path is wrong (`./kelvinlee/firmware/…`). Salvage the Docker recipe into `docs/BUILD_FIRMWARE.md` if we want it. |
| 1.8 | `firmware/test/README.md` | Upstream EVT board shell commands. |
| 1.9 | `firmware/test/BLE_THROUGHPUT_TEST.md` | Upstream's throughput harness for a board we don't have. *(Keep the `.c` if it still builds; delete the doc.)* |
| 1.10 | `firmware/scripts/devkit/KelvinLeeSimulator/README.md` | Names the upstream vendor and pre-rebrand product names outright. Rewrite as 5 lines inside `docs/TEST_HARNESS.md`. |
| 1.11 | `hardware/cad/triangle v2 w memory/README.md` | Upstream's assembly guide for the speaker build `docs/PIN_MAP.md` says we diverge from. Two contradictory assembly guides. |
| 1.12 | `hardware/cad/consumer-watch-band/**/README.md` ×2 | Community designs for upstream's device; not our form factor. |
| 1.13 | `docs/server/ARCHITECTURE.md` | 882 lines about a **different repository**, 30 wrong paths, 5 dangling doc links, and it publishes the deployment host's filesystem layout and recovery commands. Replace with a ~1-page "device ↔ server contract" doc (Tier 3). |
| 1.14 | `docs/product/SERVER-CHANGES.md` | A stale server to-do list ("committed locally but not deployed") for a repo we do not ship. |

Also delete (lower confidence — confirm with the owner first):
`docs/product/PROMPT-server-device-first-pipeline.md` — it is a *prompt addressed to another AI
assistant*, not documentation. Its substance (the device-first pipeline + `/api/device/digest`)
belongs in the protocol doc.

### Tier 2 — rewrite (highest value per line)

| # | Rewrite | What changes | Justification |
|---|---|---|---|
| 2.1 | `README.md` | Drop §Provenance's fork narrative and §"A note on paths in the docs" entirely; fold the security notes into `SECURITY.md`; keep the layout, toolchain, protocol, and habitat-alert tables verbatim — they are accurate and good. | It is the best doc in the repo but currently introduces the project as a fork with a translation table. A standalone project needs neither. |
| 2.2 | `docs/HABITAT_ALERTS.md` | Fix the 5 wrong paths in `:9`, `:22`, `:37`; keep every word of the design rationale. | Genuinely original design work — the "why this specific design" section is the strongest writing in the repo. It just points at the wrong files. |
| 2.3 | `docs/BUILD_FIRMWARE.md` | Delete §"Upstream compatibility" (upstream's changelog) and §"Fallback to upstream stock"; fix the `cd` path to `firmware/devkit/`; fix `listen.py`; state our own baseline without an upstream tag or maintainer handle. | This is our real build guide and the command is correct. Only the upstream framing has to go. |
| 2.4 | `docs/TEST_HARNESS.md` | Fix the 3 `devices/wearable-kelvinlee/` paths; rewrite `:47` (the `Friend` advertising name — fix it in firmware, then document the real name); absorb a short simulator section from 1.10; drop "The upstream KelvinLee repo ships…". | Real, useful recipes; only the framing and paths are broken. |
| 2.5 | `docs/PIN_MAP.md` | Neutralise "Kelvin's build" → "this build"; replace the triangle-v2 divergence note with a plain statement of our stack; fix the `../hardware/cad/triangle v2…` reference once 1.11 lands. | Authoritative and correct; only needs de-personalising and de-forking. |
| 2.6 | `docs/product/HardwareSetup.md` | Fix 7 monorepo paths; promote the BOM out into a standalone `docs/BOM.md` with part numbers and sourcing (gap #6); drop the "omitted from the upstream KelvinLee spec" framing. | The only assembly guide for the device we actually build. Very high value. |
| 2.7 | `docs/design/design-tokens.md` | Repoint the propagation contract at `app/lib/wearable/wearable_theme.dart` + `server-contract/tests/design-tokens.test.ts`. | Small fix, and the contract is machine-enforced, so keeping it correct has teeth. |
| 2.8 | `app/lib/wearable/README.md` | Reframe from "integration layer *for the KelvinLee app*" to "the Wearable app"; fix `src/harness/…` → `server-contract/…`; move the "Integration checklist" and "Firebase — not stripped yet" sections into an issue — they are a work log, not documentation. | Describes real, current, ours-only code. Worth keeping accurate. |
| 2.9 | `tools/wearable_test/README.md` | Rename the advertised GATT profile references once firmware stops advertising as `KelvinLee`/`Friend`. | Small, ours, useful. |

### Tier 3 — write new (fills the gaps)

| # | Create | Justification |
|---|---|---|
| 3.1 | `CONTRIBUTING.md` | Gap #3. Build/test/PR expectations for three toolchains (Zephyr, Flutter, TS contract tests). |
| 3.2 | `SECURITY.md` | Gap #4. Absorbs the MCUboot-sample-keys and Firebase-config warnings from `README.md:228-240`. |
| 3.3 | `docs/GETTING_STARTED.md` | Gap #5. Parts → flash → pair → first utterance. Currently every on-ramp doc in the repo is upstream's. |
| 3.4 | `docs/BOM.md` | Gap #6. Extracted from `HardwareSetup.md` §1 with our own sourcing links (not upstream's `a.co` shorteners). |
| 3.5 | `docs/DEVICE_PROTOCOL.md` | Replaces the deleted `ARCHITECTURE.md`: the HTTP/WS endpoints, the 4-byte GATT wire format, the button byte codes, and the `commands.ts` ↔ `agent_commands.h` mirroring rule — all already stated correctly in `README.md:120-165`, just needing a home. |
| 3.6 | `docs/TOOLCHAIN.md` | Gap #11. Already a named deliverable of `own-stack` Phase 0 (T0.1–T0.4). |
| 3.7 | `docs/PRIVACY.md` | Gap #12. The "raw audio never leaves your hardware" claim needs a document behind it. |
| 3.8 | `CHANGELOG.md` + `CODE_OF_CONDUCT.md` + hardware licence file | Gaps #7, #8, #9. Low effort, expected of an open hardware project. |

### Tier 4 — archive, don't rewrite

These are ours, honest, and historically useful, but they document a monorepo and a server this
repo does not contain. Rewriting them is wasted effort; deleting them loses design history.
**Move to `docs/archive/` with a one-line header stating they describe the pre-extraction
monorepo and are retained for provenance only.**

| # | Archive | Justification |
|---|---|---|
| 4.1 | `docs/plans/wearable-one-product-pivot.md` | 782 lines, 69 wrong paths, a superseded strategy ("Status: Proposal — awaiting approval", 2026-04-20). Real thinking; wrong repo. |
| 4.2 | `docs/plans/2026-06-07-wearable-m1-shell-entry.md` | Implementation plan against a Flutter tree `own-stack` Phase 2 deletes. |
| 4.3 | `docs/product/REVIEW_FINDINGS.md` | Punch list for monorepo files; references gitignored `.claude/agents/*`. |
| 4.4 | `docs/product/APP-NAVIGATION.md` | Snapshot of a UI state that no longer holds, several findings self-annotated as fixed. **Must be scrubbed of the live token before archiving, not after.** |
| 4.5 | `docs/design/{app-design-system,per-screen-spec}.md` + the 3 `.docx` sources | Written as diffs against upstream's app, which Phase 2 deletes. The token tables are already extracted into `design-tokens.md` (kept, Tier 2.7). |
| 4.6 | `docs/design/master-reference.md` | Server-and-monorepo-centric; supersedes itself once 3.5 exists. |
| 4.7 | `docs/product/PRD-{wearable-agentic-cos,wearable-app,bug-b-ambient-classify,chat-attachments}.md` | Server-side PRDs for a backend not in this repo. Honest and ours; simply out of scope here. |
| 4.8 | `docs/screens/` (28 PNGs) | Screenshots of screens Phase 2 removes; two leak device identifiers. Keep only if `APP-NAVIGATION.md` is kept, and redact first. |

### Keep as-is (no action)

| File | Justification |
|---|---|
| `docs/product/BUTTON_FEEDBACK_SPEC.md` | Cleanest doc in the repo: fully ours, no upstream residue, no bad paths, no leaked infra. Use it as the house style reference. |
| `docs/product/WAKEWORD-ONDEVICE-PROTOTYPE.md` | Original firmware R&D with real RAM/flash budgets against our silicon. |
| `hardware/docs/{xiao-ble-nrf52840-sense,adafruit-microsd-bff,adafruit-iot-button-neopixel-bff}.md` | Correctly source-attributed vendor mirrors for parts we actually use. **Only** the copyright header needs the 0.3 fix. |
| `scripts/adb-e2e/README.md` | Ours, accurate, well-written. Scrub the device serial (0.5). |
| `feature-research/own-stack/plan.md` | The plan this audit serves. |
| `app/ios/.../*.imageset/README.md` ×3 | Flutter boilerplate. Header fix only (0.3). |

---

## 7. Suggested sequencing

1. **Tier 0** — legal + secrets. Independent of everything else; unblocks publishing.
2. **Tier 1** — deletions. Removes ~1,100 lines of upstream and, with them, most of the wrong
   paths, all eight `example.com` placeholders, and both "links silently deleted" instructions.
3. **Tier 4** — archive moves. Cheap, and shrinks Tier 2's surface before the rewrite starts.
4. **Tier 2** — rewrite the ~9 survivors. After 1 and 4, this is a small, well-scoped job.
5. **Tier 3** — write the new docs, against a tree that is finally self-consistent.

After Tiers 0–2 the repo should satisfy: **zero** `devices/wearable-*` references, **zero**
`src/harness/*` references, **zero** `example.com` URLs, **zero** occurrences of the upstream
vendor name, **zero** private hosts/tokens, and a `LICENSE` that matches every file header.

# Decision log

One entry per decision that had real alternatives. Newest first. Each entry says what was decided, why, and what would make us revisit it. Add an entry in the same PR that makes the decision.

Format:

```text
## D-NNN: <decision> (YYYY-MM-DD)
**Decided:** … **Why:** … **Alternatives:** … **Revisit if:** …
```

---

## D-046: Media generation runs on the host with the node's key, for bots allowed it (2026-10-21)

**Decided:** kie.ai calls go through a `media` tool in the bridge, on the host, with `ORPHUSBOT_KIE_KEY` from a separate `keys.env`. The node passes the key only to engines of bots with **Media generation** on, and the gate refuses the tool from others. The owner's skills, which had the key written into them, are installed without it.

**Why:** A key inside a bot's computer can be read by any command there, including one prompted by a web page or a file. On the host, the bot can spend credits but can't take the key. A file of its own keeps API keys apart from the node's settings and makes them easy to rotate.

---

## D-045: Phone actions that could commit ask every time, past any "always" rule (2026-10-21)

**Decided:** The `phone` tool's taps whose label could commit (post, reply, like, follow, send, confirm, done, …), taps by id alone, and `ENTER` skip the owner's approval rules and always ask. Looking, queueing drafts, opening apps, typing and moving about pass without asking. Bots publish by queueing a draft, which ContentSwarm posts only after the owner approves it in Social.
**Why:** the owner chose to approve every post and reply by hand. Approval rules are per tool, so one "Always" on a phone card would otherwise allow every later tap, including Post. Matching on visible labels is coarse but errs towards asking. Navigation has to pass freely, or reading comments would take dozens of approvals.
**Revisit if:** the commit list asks too often in practice, or ContentSwarm gains verified adapters that make bot taps on commit buttons unnecessary.

## D-044: Social posting goes through the owner's phone and ContentSwarm, reviewed in OrphusBot (2026-10-21)

**Decided:** X and LinkedIn are reached through the owner's own Android phone, plugged into the GPU box, using the real apps. ContentSwarm is the engine (phone kernel, profiles, review queue, delivery worker), running beside the server on loopback. The owner reviews everything in OrphusBot's Social screen, which the server passes through to ContentSwarm's owner console on a fixed allowlist. Every post and reply needs the owner's approval.
**Why:** platform APIs are costly, restricted (X) or closed to individuals (LinkedIn posting and comments), and posting from the phone looks and behaves like the owner. ContentSwarm already has the hard parts: no-shell phone control, single-send delivery with uncertainty handling, voice profiles and a review queue. Rebuilding those in OrphusBot would duplicate them. One app for the owner beats two consoles. The phone lives on the always-on box so bots can work at any hour.
**Revisit if:** a platform blocks automation from the phone, or ContentSwarm's console becomes the better place to review.

## D-043: The Omarchy desktop is Sway dressed as Omarchy, not Hyprland (2026-10-21)

**Decided:** A bot can have an Omarchy desktop (`images/omarchy`): Arch Linux, Sway on wlroots' headless backend with the pixman software renderer, wayvnc, and Omarchy v3.8.4's config files (theme, gaps, borders, wallpaper, waybar, alacritty, keys). It's a per-bot setting (`desktop`: `debian` or `omarchy`); changing it replaces the bot's container and keeps its home volume.
**Why:** Hyprland 0.56 can't start without a GPU: aquamarine's headless backend needs a GBM allocator from a DRM render node, and nesting it in a software compositor fails for lack of linux-dmabuf. Passing a render node into every bot's container would weaken its isolation and compete with the models for the box's GPUs. Sway gives the same look and keys with no device, at about 50 MiB idle. v3.8.4 is the last Omarchy release with plain config files and waybar; v4 moved to Lua and Quickshell.
**Revisit if:** Hyprland gains a software or headless renderer that needs no DRM device, or a node has a GPU to spare for bot screens.

## D-042: kev (Kev-9B) is the System 1 model; it supersedes Laya in production (2026-10-21)

**Decided:** System 1 runs on kev's Kev-9B, served by `kev.serve` on GPU 1 of the GPU box. Laya stays usable (same protocol, same setting) for machines without a big GPU. The setting keeps its name, `ORPHUSBOT_LAYA_URL` (renaming it would only break configs).
**Why:** kev is the owner's chosen Jev-family model, speaks the `/v1/systemone` protocol System 1 already uses, scores close to Jev on sources it never trained on, and comes with tools to fine-tune and recalibrate on the owner's own labels. Measured answers take tens of milliseconds on the box. Supersedes D-003's choice of runtime; D-023's rule stands: System 1 never approves an irreversible action, whatever the model.
**Revisit if:** latency or GPU memory gets tight (Kev-4B is the fallback), or fine-tuned checkpoints on the owner's labels beat it.

## D-041: Phone push through UnifiedPush on our own ntfy, not Firebase (2026-10-20)

**Decided:** the Android app registers a UnifiedPush endpoint with the server (`/api/push`); the ntfy app is the distributor, pointed at OrphusBot's own ntfy (its own container on the box, deny-all except anonymous `up*` topics, reached through the Cloudflare tunnel). The server posts each push to every endpoint as JSON and the app shows it as its own notification; a tap opens the bot.
**Why:** no Google account or Firebase project, which keeps the self-hosted stance of D-004 and the wearable; the server's ntfy sender already existed; notifications open the app rather than the browser.
**Revisit if:** a public distributor is used (then encrypt payloads with Web Push), or installing the ntfy app proves a barrier for other owners (then offer FCM as an option).

## D-040: Gallery files live on disk by content hash; the database keeps the details (2026-10-20)

- **Context:** Kelvin wants a gallery of context for the bots, including video. Attachments and artifacts are kept in Postgres, capped at 10 MB, which suits chat files but not video.
- **Decision:** gallery bytes are files in one folder (on the box, the new 2 TB SSD), named by SHA-256, streamed to disk on upload (up to 2 GB) and served with ranges; `gallery_item` holds the details. A gallery item sent in a chat is fetched by the app and attached like any file, reusing the attachment path (10 MB), rather than a second way of sending files.
- **Alternatives:** keep bytes in Postgres (simple backups, but video bloats the database and every read loads it whole); object storage such as MinIO (another service to run for one owner).
- **Revisit if:** more than one machine needs the files directly, which is when bots fetch from the gallery themselves.

## D-039: Google through `gws` on the node, gated per command (2026-10-17)

- **Context:** Kelvin keeps his documents, calendar and to-dos in Google and wants bots to use them, with everyone able to look things up and only PA able to change anything.
- **Decision (Kelvin's choice of CLI):** Google's `gws`, run on the node by a bridge `google` tool, with the owner's exported credentials kept on the node. Each bot has `google` = none, read or write. The gate classifies each gws command by its API method: reads pass, changes are refused for read bots and asked of the owner for write bots, and node file flags are refused.
- **Alternatives:** `gog` (already on the box, MIT, per-service allowlists, but not Google's); an MCP server such as the PA's (another service to run, and per-tool rather than per-bot control); giving bots the CLI inside their computers (the credentials would sit where bot-run code can read them).
- **Revisit if:** gws changes its command shape before 1.0, or the owner wants finer rights than read/write (per service).

## D-038: The bots' memory is a Karpathy-style LLM wiki, not Dossier (2026-10-17)

- **Context:** Dossier needed its own model server; the chosen Qwen3.5-27B didn't fit beside the box's other models, the two cards can't share a model, and an attempt left GPU 0 needing a reset. Kelvin pointed at karpathy-llm-wiki, an MIT Agent Skill implementing the same LLM-wiki pattern Dossier is built on.
- **Decision (Kelvin's choice):** the team's memory is one wiki in the shared folder (`/shared/raw`, `/shared/wiki`), maintained by every bot with the karpathy-llm-wiki skill and its own model; discussion verdicts are filed into it. The bridge reads skill files from the host, read only.
- **Alternatives:** Dossier on local models (better retrieval on benchmarks, but a model server and GPU memory to keep up); Dossier on a cloud API (a key and running costs); per-bot private wikis (no shared memory).
- **Revisit if:** the wiki grows past what bots can search with file tools, at which point Dossier, or EmbeddingGemma search over the wiki, can sit behind it.

## D-037: A separate Orchestrator bot coordinates the team (2026-10-17)

- **Context:** Kelvin wants a main bot that runs the others. Requests already reach Inbox, which System 1 routes from, and team bots can hand work to each other with `ask_bot`; nothing plans a job across bots or starts a discussion on its own.
- **Decision (Kelvin's choice):** a new team bot, Orchestrator, alongside Inbox: it plans and delegates with `ask_bot`, starts discussions with a new `discuss` tool (the verdict comes back to it as a message), and runs fleets. It's listed first and opened by default.
- **Alternatives:** turn Inbox into the Orchestrator (one front door, but quick triage and big jobs would share one bot and one context); hide the other bots behind the Orchestrator (simpler surface, but the owner loses direct access to specialists).
- **Revisit if:** the owner ends up sending everything to the Orchestrator, in which case Inbox can retire, or if routing between the two confuses.

## D-036: Discussions are rounds of ordinary bot runs in one Orphus room (2026-10-16)

- **Context:** Kelvin wants OrphusBot's bots to deliberate the way Orphus agents do: outside their context windows, so each task stays clean, with what was decided kept in memory. Orphus offers this inside one engine as a fleet's `deliberate` team (helper sessions in one room).
- **Decision:** the server runs the rounds. Each bot takes each round as its own run, in a session kept for that discussion, on its own model, instructions and computer, and joins one Orphus room; a chair writes the verdict as the `librarian` and files the room into memory. The gate, which already sees every tool call, records each post for the live view and allows one per bot per round.
- **Alternatives:** a generated fleet blueprint with a seat per bot (all seats then share one bot's engine, computer and approvals, and seat models are not yet honoured by Orphus); bots messaging each other's threads (every message enters every context, which is what rooms exist to avoid); reading the room server directly for the live view (an undocumented socket protocol).
- **Revisit if:** bots run on different machines (rooms are per machine), or Orphus exposes room events over RPC.

## D-035: The bar panel plays faces as pre-rendered WebPs (2026-10-16)

- **Context:** the Omarchy bar panel is QML (Quickshell), which has no Rive runtime; the faces should still move there.
- **Decision:** `design/bot-avatar/frames.sh` renders each style and state with the Rive CLI into a small looping WebP (56 px, 10–20 fps), which QML's `AnimatedImage` plays. They are committed in the plugin's `faces/` (about 1 MB).
- **Alternatives:** a community Rive plugin for Qt Quick (a native build to install alongside the shell); redrawing the faces in QML (two drawings to keep in step); a still picture per state (no animation, which was the ask).
- **Revisit if:** Quickshell gains a Rive runtime, or the files grow enough to matter.

## D-034: Bot faces are made in code with the Rive CLI and driven by one number input (2026-10-16)

- **Context:** the app wants Rive animations (D-033). The Rive editor is a hosted design tool; the Rive CLI builds `.riv` files offline from a text scene (RML).
- **Decision:** the avatar is generated by `design/bot-avatar/gen.py` into `scene.rml` and built with `rive . --once`; nothing is uploaded. The app drives it with one state-machine number input, `state` (0 to 4), using the `rive` Flutter package (MIT) with Flutter's renderer.
- **Alternatives:** draw it in the Rive editor (needs an account and isn't reviewable as text); view-model data binding, which Rive now recommends over inputs (more moving parts for one number); hand-drawn Flutter animations (no designer can edit them later).
- **Revisit if:** Rive removes number inputs (switch `state` to a view-model enum), or a designer takes over the face in the editor.

## D-033: One Flutter app for every device (2026-10-16)

- **Context:** the desktop and Android apps are Tauri windows onto the server's web UI. Kelvin wants real applications, for Omarchy, the Mac and phones, with richer chat (media, history, animations with Rive, whose Flutter runtime is native).
- **Decision:** a Flutter app in `apps/orphusbot_app`, built for Linux first and then macOS, Android and iOS. It talks to the same server API and signs in by device linking. The web UI (Leptos) stays for browsers; the Tauri apps stay until the Flutter ones cover them. AGENTS.md's "Rust first" holds for the server, node and command line.
- **Alternatives:** keep Tauri and make it a proper desktop app (smaller change, but the same web UI and no native Rive); Flutter only on phones (two UIs to keep in step on desktop).
- **Consequences:** a second UI codebase (Dart) beside Leptos, kept honest by sharing the reducer's behaviour through tests. Rive animations plug straight in. The wearable companion app is Flutter too and can merge in later.

## D-032: Fleets run with the bridge loaded in every helper; workflows stay blocked (2026-10-16)

- **Context:** D-030 blocked fleets and workflows because helper sessions skip the bridge. Testing showed helpers do load project extensions from the engine's working folder, and run in the same process as the engine.
- **Decision:** the node installs the bridge as a project extension in the engine's work folder too; the engine's bridge shares its dialog channel through a process-wide symbol, and helpers' copies ask through it. `subagent`, `fleet` and `roundtable` are then allowed; `workflow` stays refused, because a workflow's own code acts without tool calls. Fleets are started by `/fleet <name> <task>` in a message or a routine.
- **Alternatives:** an overlay agent directory holding the bridge (Orphus saves `auth.json` by rename, which would split the owner's login); waiting for Orphus to propagate extensions to helpers (still the cleaner fix, and this can be dropped then); a separate run-target field (the slash command already says it).
- **Consequences:** fleets cost one approval per helper launch unless the owner allows `subagent` always; each helper action is gated as usual. The mechanism depends on Orphus loading project extensions in helpers and running them in-process; if either changes, helpers' calls fail closed ("only runs under orphusbot-node").

## D-031: The node reaches an E2B sandbox's envd directly, with that sandbox's token (2026-10-16)

- **Context:** DESIGN §6.2 planned that a node's bridge sends each operation up the link and the server runs it against E2B, so nothing E2B-related reaches a node.
- **Decision:** the server keeps the API key and makes or resumes the sandbox; the node gets only that sandbox's envd address and access token, and the bridge calls envd itself, exactly as it calls `podman exec` for a local computer. The Connect protocol is spoken by hand in JSON (a 5-byte header per message) instead of generated stubs.
- **Alternatives:** relaying every operation through the server (a new request/response path on the node link for each read, write and streamed command, for no gain: nodes are the owner's machines and the token opens one sandbox only); the E2B SDK in the bridge (a dependency the engine would load for a few calls); generated Connect stubs (a build step for two calls).
- **Consequences:** a node needs HTTPS to E2B. A leaked envd token exposes one bot's sandbox until it's replaced, never the account. Model tokens still never reach E2B.

## D-030: Fleets and workflows are not run targets until Orphus can keep them gated (2026-10-16)

- **Context:** PRD B-RUN-06 and M6 ask that a run can launch an Orphus fleet or a Goal workflow. Both work by spawning subagents or in-process stage sessions. OrphusBot's guarantees come from the bridge: every tool call is gated, and in a bot computer every tool runs inside the container. Child sessions don't load the bridge, and Orphus has no structured RPC for fleet or workflow state (H-B6, orphus-desktop H-03).
- **Superseded for fleets by D-032.**
- **Decision:** don't offer them yet. The bridge blocks the `subagent`, `workflow` and `fleet` tools in every mode, and the gate denies them as well, even against an owner's rule. Checked 2026-10-16 with a real Orphus engine: a subagent forked from a gated session ran `bash` on the host and the bridge was never asked.
- **Alternatives:** launch them by slash command in the prompt (child tool calls would skip the gate and run on the node: breaks AGENTS.md rule 5 in spirit and DESIGN §4.4); loading the bridge into children ourselves (depends on Orphus internals that change).
- **Consequences:** a bot does one engine turn per run. Revisit when Orphus passes extensions (or a gate hook) to child sessions and exposes fleet and workflow state over RPC.

## D-029: Connections ride Orphus's MCP adapter, tokens go in by environment, MCP calls are gated per tool (2026-10-16)

- **Context:** DESIGN §11 planned MCP config per engine session, `search_tools` / `load_tool` / `call_tool` wrappers served by the server for big servers, and envelope-encrypted secrets.
- **Decision:** Orphus's built-in MCP adapter already loads servers lazily behind one `mcp` tool with search and describe, so OrphusBot only hands it a config file (`--mcp-config`) per bot, with each token passed as an environment variable the file names. The gate treats a bare `mcp` call as a read and a tool call as `mcp:<tool>`. Secrets are AES-256-GCM under a single master key, using openssl, which the build already had.
- **Alternatives:** our own rmcp wrapper endpoint (duplicates the adapter); tokens in the config file (on the node's disk); one approval rule for all of `mcp` (one "Always allow" would allow every MCP tool); envelope encryption now (only needed to rotate the master key without re-encrypting).
- **Consequences:** a new MCP server needs no OrphusBot code. Rotating the master key means re-adding tokens. Engine session files on nodes keep raw tool output.

## D-028: No in-process Laya (OrtLaya) for now; laya-serve stays System 1's runtime (2026-10-16)

- **Context:** M5 planned `OrtLaya`: Laya's ONNX graph run inside the server through ONNX Runtime, gated by parity with Laya's golden fixtures. Laya has ports in Go, Java, TypeScript and .NET, but none in Rust; the Go one is about 13,000 lines (tokenizer, CPython-exact JSON, language detection, sequence building, decoding with temperatures and binning). The graph is a 1.3 GB export the laptop doesn't have.
- **Decision:** don't build it now. laya-serve is Laya's reference implementation, already runs on the GPU box beside the server, and the HTTP hop costs milliseconds against the model's own time. Every failure already abstains safely.
- **Alternatives:** a Rust port in this repo (a fifth port that drifts every time Laya changes, for no change in answers); the `tokenizers` and `ort` crates plus a partial port (still needs exact state serialisation and decoding to pass parity).
- **Consequences:** System 1 needs the laya-serve process (Python, about 2.5 GB of memory). Revisit if that process becomes the problem (a smaller box, or a node that must decide offline); the right home then is a `laya-rs` port in Laya's own repository, sharing its fixtures.

## D-027: Thresholds are fitted in the server with Laya's cut; temperatures stay with Laya (2026-10-16)

- **Context:** DESIGN §7.5 planned to run `laya.calibrate` on the GPU box. It fits per-bucket temperatures from Laya's raw logits, which needs the model and the full state; receipts keep only the calibrated `answer_confidence`, and states are cleared after 30 days.
- **Decision:** OrphusBot fits only the thresholds it acts on (`triage.bot`, `gate.verdict`), in Rust, using Laya's conservative selective cut (`_select_abstention_threshold`) on the confidences in its receipts, with the newest fifth of labels held out. Temperature refits and fine-tuning stay with Laya's tools on the GPU box and arrive as a new checkpoint.
- **Alternatives:** a Python wrapper around `laya.calibrate` (needs the model loaded, logits re-computed from states that may be gone, and Python in the server's path); one threshold for everything (doesn't transfer between a bot pick and a gate verdict).
- **Consequences:** fitting is instant, works with no GPU and no Laya running, and is tested in Rust. A new Laya checkpoint changes the confidence scale, so its thresholds must be refitted after it is used for a while.

## D-026: The Android app is the desktop crate built for Android, and it signs in by device linking (2026-10-16)

- **Context:** M4 needs OrphusBot on the phone. The desktop app (D-019) is already a thin window onto the server's web UI.
- **Decision:** one Tauri crate for both. `crates/desktop` becomes a library with Tauri's mobile entry point, and its generated `gen/android` project is committed. Sign-in reuses device linking rather than passkeys in the WebView or a new device-token flow.
- **Alternatives:** a separate `apps/mobile` crate (a second copy of the same 100 lines); passkeys inside the Android WebView (needs a Credential Manager bridge and an assetlinks file on the server); a keystore-held device token (planned in §12, not needed for a first app that works).
- **Consequences:** the phone always matches the server's UI version, and there is nothing Android-specific to keep in step except the activity's inset padding. A linked session lasts 30 days, then the phone is linked again; long-lived device tokens and the offline outbox remain open (B-CLI-05, B-CLI-06).

## D-025: The wearable pairs with a one-time code in the app's bearer field, and its tasks become tickets (2026-10-16)

**Decided:** OrphusBot makes a one-time pairing code (10 minutes, stored hashed) from a signed-in session; the existing phone app sends it as the "bearer" on `POST /api/device/register` and gets its device token. A deliberate button capture becomes a ticket assigned by System 1 (or to the inbox), and runs, cues and asks follow from it. Until the app reports GATT write results (W-3), a habitat message counts as delivered when the app takes it from the poll.
**Why:** the app already has a bearer field and a register call, so pairing needs no app release, and a code that works once and expires can't be replayed. Making the capture a ticket means a task the wearer didn't start (double tap on "should I start?") is still on the board rather than lost, and it gets the board's status tracking for free.
**Alternatives:** an operator bearer token as in the reference server (a long-lived secret on the phone); a QR code (needs an app change); button captures as plain inbox messages.
**Revisit if:** the app gains a QR pairing flow, or button tasks need to bypass tickets.

## D-024: Routines fire from a scheduler loop over a `next_at` column, still without a job queue (2026-10-16)

**Decided:** a loop in the server wakes every 15 s and fires routines whose `next_at` has passed. Each firing is claimed by moving `next_at` to the next occurrence in the same statement that checks it, so it can't fire twice; one missed while the server was down fires once on start, then the schedule carries on from now. Cron is read in each routine's IANA time zone (`croner` + `chrono-tz`), so clock changes keep 08:00 at 08:00. This supersedes D-014's plan to add `graphile_worker` with routines.
**Why:** routines are the only timed work so far, and a single `update … where next_at <= now()` gives the same once-only guarantee a job queue would, with no extra dependency or schema.
**Alternatives:** `graphile_worker` (or `apalis`) now; cron in the operating system calling a webhook.
**Revisit if:** there are several server processes, or more kinds of timed work (computer sleep, digests, capture mining) that need retries and backoff.

## D-023: System 1 may only let through file changes inside a bot's computer; it routes inbox messages (2026-10-16)

**Decided:** in the gate, Laya is asked only about `write` and `edit` calls that run inside the bot's computer, and only when no rule decided; at 0.95 confidence or more they run without a card. Bash, anything on the host and everything else always asks the owner unless a rule says otherwise. For routing, Laya picks among the enabled bots' remits for new inbox messages and acts at 0.85 or more. Both thresholds are settings, the gate's never below 0.9. Every ask leaves a receipt.
**Why:** a file change in the bot's own container is reversible and can't reach anyone else; a shell command can send, pay or publish over the network, so it is never "reversible by construction" (AGENTS rule 5). Strict thresholds mean Laya acts only on clear cases until it's calibrated on the owner's own approvals and reassignments.
**Alternatives:** let System 1 judge bash commands too; route every message, not just the inbox's; no receipts until calibration exists.
**Revisit if:** calibration (M5) shows Laya is reliable on a wider class, such as read-only shell commands.

## D-022: One event stream for all bots, each event tagged with its bot (2026-10-16)

**Decided:** clients open one SSE stream that carries every bot's thread events and the node list, each wrapped in an `Envelope { bot, event }`. Events get a global id, which clients resume from with `Last-Event-ID`; each thread still numbers its events without gaps.
**Why:** the sidebar needs every bot's latest message and waiting count at once, so a client would subscribe to every thread anyway. One stream means one connection, one resume point and no subscription bookkeeping.
**Alternatives:** a stream per thread plus a global inbox stream (DESIGN §12's first plan).
**Revisit if:** there are enough bots or traffic that clients should only receive the threads they show.

## D-021: Screens travel through the server and the node link, into the computer with `podman exec socat` (2026-10-16)

**Decided:** the browser's noVNC connects to the server (`/api/screen`, same origin, same session cookie). The server relays the VNC bytes over the node's existing link as binary frames tagged with a stream number, and the node pipes them into the computer with `podman exec -i … socat STDIO TCP:127.0.0.1:5900`. The VNC server listens only inside the container. noVNC 1.7.0 (MPL-2.0) is vendored unmodified.
**Why:** clients only ever talk to the server, so phones and the desktop app need no route or certificate to each node, and there are no screen tokens to seal, check and expire. The computer publishes no port at all, so nothing on the network can reach its screen. Reusing the authenticated node link means no second listener on the node.
**Alternatives:** the first plan, a node listener on `:7481` with server-sealed tokens; websockify in the container with a published port; streaming screenshots instead of VNC.
**Revisit if:** screen traffic measurably slows the node link for runs, at which point give screens their own connection.

## D-020: The bridge runs tools in the bot's computer with `podman exec`, and the node drives the Podman CLI (2026-10-16)

**Decided:** the bridge re-registers `read`, `write`, `edit` and `bash` with Orphus's own tool factories and operations that run `podman exec` into the bot's container, as Orphus's `ssh.ts` example does with ssh; it offers no other tool and blocks any other at the gate. The node creates and fences the container with the `podman` CLI. Local networks are blocked with nftables rules set inside the container's network namespace from outside.
**Why:** engine and computer are on the same node, so a socket between them (the earlier plan) added a protocol, a server loop and a path to secure for nothing `podman exec` doesn't already do. The CLI needs no daemon or client library and works the same rootless. Orphus already exports tool factories that take custom operations, so the harness change H-B1 wasn't needed. Rules in the container's own namespace work rootless, where a host firewall would need root.
**Alternatives:** the bridge socket with `Op` frames (DESIGN's first plan); `bollard` against the Podman API socket; a dedicated Podman network with host nftables rules (needs root).
**Revisit if:** computers live on a different machine from their engine (E2B, M4), which needs operations to travel through the server.

## D-019: The desktop app is a window onto the server's UI, signed in by device linking (2026-10-16)

**Decided:** the Tauri desktop app loads the server's web UI from the server, locked to its origin, instead of bundling the UI. Because WebKitGTK (Tauri's Linux webview) has no WebAuthn, devices without passkeys sign in by **linking**: the device shows a short code, the owner approves it from a device that has a passkey, and the device's poll receives its own session tied to that passkey. The same flow will sign in the Android app.
**Why:** loading from the server keeps the session cookie same-origin (no CORS, no bearer tokens in JavaScript, the same `SameSite=Strict` cookie as the browser) and the app can't drift from the server's version. Device linking is the standard pattern for devices that can't run the real sign-in (like a TV's "enter this code"), needs no deep-link plumbing, and each linked device stays revocable through its passkey.
**Alternatives:** bundle the UI in the app and call the server cross-origin with a bearer token; open the system browser for a passkey prompt and hand the session back through a deep link; wait for WebAuthn in WebKitGTK.
Tauri brings five more unmodified MPL-2.0 crates (Servo's CSS parsing crates and `option-ext`); `deny.toml` names each one, as in D-016.
**Revisit if:** the app needs to work offline, or WebKitGTK gains WebAuthn.

## D-018: The web UI is Leptos CSR built with Trunk and served as static files (2026-10-16)

**Decided:** `crates/ui` is a client-side Leptos app built to WebAssembly with Trunk. The server serves the built folder; the Tauri apps will load the same bundle. View state comes from one reducer in `proto` (`view::ThreadView`). The crate's dependencies are declared for `wasm32` only, so native workspace builds skip Leptos. Passkey prompts use a small inline JavaScript shim around `PublicKeyCredential.parse*OptionsFromJSON` and `toJSON()`.
**Why:** CSR needs no server-side rendering and fits Tauri, which loads static files. Trunk is the standard CSR build tool. Keeping the reducer in `proto` means it's tested natively and shared by every client. The browser's own WebAuthn JSON helpers make the shim a few lines; binding the same API through `web-sys` would be far more code.
**Alternatives:** Leptos SSR with `cargo-leptos` (needs a server render path the Tauri apps don't use); embedding the bundle in the server binary (couples server builds to the WebAssembly toolchain); `web-sys` WebAuthn bindings.
**Revisit if:** first load is too slow on the phone, at which point add SSR or split the bundle.

## D-017: Nodes prove who they are by signing a server challenge inside the link, with OpenSSL's Ed25519 (2026-10-16)

**Decided:** the shared node token is gone. Each node has its own Ed25519 key, registered once with a one-time code the owner creates while signed in. Enrolment and the signed hello both happen over the existing `/node` WebSocket: the server's first frame is a random nonce; the node answers with a signature over its name and the nonce, or with an enrolment request. Signing and verifying use the `openssl` crate.
**Why:** a stolen node token let anyone act as any node and couldn't be revoked per machine. A fresh nonce per connection means a captured hello can't be replayed. Doing enrolment inside the link means the node needs no HTTP client. OpenSSL is already compiled into both binaries (passkeys, `wss://`), so Ed25519 costs no new dependency or build time.
**Alternatives:** `ed25519-dalek` (pure Rust, but a new dependency); a signed timestamp in the upgrade request (replayable within its time window); mutual TLS with client certificates (a CA to run).
**Revisit if:** the OpenSSL dependency is dropped from the server, in which case move to `ed25519-dalek`.

## D-016: Passkeys on a real domain name pointing at a NetBird address, with a DNS-01 certificate (2026-10-16)

**Decided:** the server is reached at a subdomain of the owner's domain (for Kelvin, under `kelvinlee.io`) whose `A` record is the GPU box's private NetBird address. Caddy in front of the server gets a Let's Encrypt certificate through the DNS-01 challenge (Cloudflare API token) and listens only on the NetBird interface. Passkeys come from `webauthn-rs`. Until the first passkey exists, a setup token from the environment signs you in to add one. `webauthn-rs` is MPL-2.0, so `deny.toml` allows MPL-2.0 for its crates by name only; we use it unmodified, so OrphusBot stays MIT.
**Why:** passkeys need HTTPS and a host name that every device trusts, and the phone and desktop shouldn't need a private certificate authority installed. A DNS challenge issues a public certificate for a name that only resolves to a private address, so nothing is exposed to the internet. `webauthn-rs` is the maintained, audited Rust implementation.
**Alternatives:** NetBird's own DNS name with a private CA installed on every device; skipping passkeys for revocable device tokens only; terminating TLS in the server with `rustls` and an ACME crate (more code than one Caddyfile).
**Revisit if:** the server is ever exposed beyond NetBird, or Android needs sign-in before a passkey provider is set up.

## D-015: The approval gate uses Orphus's dialog protocol, not a socket (2026-10-16)

**Decided:** the bridge asks for approval with an Orphus `input` dialog; the node relays dialogs and the server answers them. Tool completions are read from Orphus's `tool_execution_end` events. The unix socket in DESIGN §4.3 arrives in M2, only for redirecting tool operations into bot computers.
**Why:** the dialog protocol already exists, already crosses the process boundary, and already blocks the engine until answered. Reusing it means no socket code, no extra protocol and no path to configure, and the same relay gives bots a way to ask the owner questions (B-RUN-05).
**Alternatives:** the socket from the start.
**Revisit if:** dialogs prove too slow for read-heavy work (reads skip the gate on the server, but still round-trip).

## D-014: Runs are dispatched straight from Postgres, without a job queue, until M3 (2026-10-16)

**Decided:** queued runs are claimed with `select … for update skip locked` whenever a run is queued, a node connects or a run ends, and a 30-second reconciler renews and sweeps leases. `graphile_worker` (DESIGN §3.5) arrives in M3, with routines.
**Why:** in M1 there is one kind of work and its triggers are all events the server already sees. A job queue would add a dependency and a second schema for no extra guarantee: Postgres row locks and the fence already make dispatch safe.
**Alternatives:** `graphile_worker` from M1; `apalis`.
**Revisit if:** routines, compaction or other timed work need scheduling (M3).

## D-013: M0 ships a plain HTML page; the Leptos UI starts in M1 (2026-10-16)

**Decided:** M0's browser page is one static HTML file with `EventSource`, served by the server. The Leptos UI (D-002) starts in M1, together with the Tauri desktop shell that needs it.
**Why:** M0 exists to prove the server ↔ node ↔ Orphus path. A WebAssembly toolchain and Leptos build on a 2-core laptop would add most of M0's build time for a page that M1 replaces anyway.
**Alternatives:** a bare Leptos page in M0, as the PRD first said.
**Revisit if:** never; M1 removes the page.

## D-012: The wearable is imported as a cleaned snapshot, without history (2026-10-16)

**Decided:** the OmarchyWearable repository is copied into `wearable/` as one cleaned snapshot. Its history stays in the old private repository, which is retired.
**Why:** the history contains old Firebase client keys, LAN addresses, a device MAC and token prefixes. Rewriting 200+ commits to scrub them is more work and more risk than starting clean, and nothing in OrphusBot needs the old history.
**Alternatives:** `git subtree` with full history (would publish the leaked values); `git filter-repo` rewrite then subtree.
**Revisit if:** someone needs blame for old firmware lines; the private repository still has it.

## D-011: Documentation is updated in the same PR, enforced by CI and CodeRabbit (2026-10-16)

**Decided:** every PR that changes code also changes the docs and the changelog, unless labelled `no-docs` with a reason. A CI job checks it; CodeRabbit is instructed to flag missing updates.
**Why:** design docs that drift from the code stop being trusted, and this project depends on DESIGN.md as the contract between server, node, wearable and UI.
**Alternatives:** generated API docs only; periodic doc sweeps.
**Revisit if:** the check produces more `no-docs` labels than real catches.

## D-010: Ponytail method for all code (2026-10-16)

**Decided:** follow [ponytail](https://github.com/DietrichGebert/ponytail): reuse before building, smallest working change, no speculative abstractions, never cut validation, security, data-loss handling or accessibility.
**Why:** a small team (one maintainer plus agents) can only maintain code that doesn't exist.
**Revisit if:** never; it's the working style.

## D-009: CodeRabbit reviews every pull request (2026-10-16)

**Decided:** CodeRabbit runs on every PR with repo-specific instructions in `.coderabbit.yaml` and `AGENTS.md`.
**Why:** a second reviewer on every change, including AI-written ones, without waiting for a human.
**Revisit if:** review noise outweighs catches.

## D-008: Wearable habitat is duplex; no speaker by design (2026-10-16)

**Decided:** the wearable outputs only light and vibration. Every signal is a tracked message, every ask has defined button replies, and unanswered asks escalate to the phone. A wrist tap can only confirm things the wearer already knows about. See DESIGN §9.3.
**Why:** no speaker keeps the device small, private and socially quiet; a closed loop is needed so a blind tap is never ambiguous and nothing nags forever.
**Alternatives:** speaker with spoken prompts; one-way notifications only.
**Revisit if:** never for the speaker; the reply grammar can grow if bench tests show more gestures are reliable.

## D-007: Everything is open source except personal data (2026-10-16)

**Decided:** all code and docs are MIT and public. Receipts, labels, transcripts, captures and models fine-tuned on them are never committed.
**Why:** open by default; trained weights can leak their training text.

## D-006: The OmarchyWearable joins OrphusBot through its existing device channel (2026-10-16)

**Decided:** the server implements the wearable's existing HTTP + WebSocket contract in Rust; the firmware and Flutter companion stay as they are apart from small W-1…W-5 changes. The wearable repo is brought into this repo once it has been cleaned for publication.
**Why:** the contract, button grammar and cue vocabulary already work; reuse beats rebuild.
**Alternatives:** a new protocol; rebuilding the companion in Tauri now.
**Revisit if:** two phone apps prove too awkward (DESIGN §19 D1).

## D-005: Server on the always-on GPU box; Android with self-hosted push (2026-10-16)

**Decided:** `orphusbot-server` runs on the always-on GPU box, which is also always a node. Push goes through self-hosted ntfy / UnifiedPush.
**Why:** no extra machine; no Google account; tasks only queue if the GPU box itself is down.

## D-004: Own machines first, E2B second (2026-10-16)

**Decided:** bots run in rootless containers on the owner's machines over NetBird; E2B handles overflow, offline nodes and untrusted work.
**Why:** cost, privacy and GPU access; E2B gives microVM isolation when it matters.

## D-003: Laya as the System 1 decision model (2026-10-16)

**Decided:** Laya (Apache-2.0, Jev-family) behind a `DecisionModel` trait; start with laya-serve over HTTP, move in-process via ONNX Runtime once it matches Laya's golden fixtures.
**Why:** typed decisions in one forward pass, calibrated confidence, same wire format as Orphus systemone.
**Revisit if:** calibration on real labels stays poor.

## D-002: Rust as the main language (2026-10-16)

**Decided:** server, node, decision layer and UI in Rust (axum, sqlx, Leptos, Tauri 2). The Orphus engine, subscription sign-in, the bridge extension and Laya training stay in their own languages behind process boundaries.
**Why:** owner preference; one language end to end with shared types.

## D-001: A separate app, modelled on a study of Rakazo (2026-10-16)

**Decided:** OrphusBot is its own product with web, desktop and mobile clients, separate from orphus-desktop. Rakazo (Apache-2.0) was studied for its architecture; no Rakazo code is used.
**Why:** an always-on, multi-device bot service is a different product from a local desktop workbench.

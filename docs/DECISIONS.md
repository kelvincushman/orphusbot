# Decision log

One entry per decision that had real alternatives. Newest first. Each entry says what was decided, why, and what would make us revisit it. Add an entry in the same PR that makes the decision.

Format:

```text
## D-NNN: <decision> (YYYY-MM-DD)
**Decided:** … **Why:** … **Alternatives:** … **Revisit if:** …
```

---

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

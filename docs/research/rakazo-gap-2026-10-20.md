# Rakazo → OrphusBot gap analysis (features, UX and UI)

| | |
|---|---|
| Date | 2026-10-20 |
| Rakazo studied | `github.com/elie222/rakazo`, `main` at **`38b8e713`** (2026-10-20, "add Close to the macOS Window menu"); desktop v0.3.1, mobile 1.0.6 |
| Baseline | Our earlier study, [rakazo-architecture.md](rakazo-architecture.md), was at `7d5e64c` (2026-10-15). **170 commits** have landed since; the notable ones are listed in §1.2 |
| OrphusBot studied | This repo's working tree on 2026-10-20: [DESIGN.md](../DESIGN.md), [PRD.md](../PRD.md), [DECISIONS.md](../DECISIONS.md), [CHANGELOG.md](../../CHANGELOG.md) (Unreleased), `apps/orphusbot_app`, `crates/ui`, `crates/cli`, `crates/server`, `omarchy/` |
| Method | Rakazo's source was read, not run (shallow clone, nothing installed). Every claim about Rakazo cites a file in its repo; every claim about OrphusBot cites a path here or a DESIGN section |
| Purpose | Kelvin wants OrphusBot to cover everything Rakazo does, including its UX and UI, adapted to our stack (Rust server and node, Flutter app, Leptos web, Omarchy panel, CLI, wearable) |

**Licence note.** Rakazo is Apache-2.0. Its ideas, behaviour and UX are free to follow. Code could only be reused with its licence header kept and a NOTICE added. **Our policy is unchanged from the architecture study: we copy no code, we rebuild from behaviour descriptions written in our own words, and nothing is transliterated.** We don't use Rakazo's name, logo, mascot or wordmark, and we don't imitate its brand assets (the eyes mascot, the Geist wordmark treatment, its bot shapes as drawn). This document describes; it never pastes.

**Path convention.** Unqualified paths in the "Rakazo" column are relative to Rakazo's repo root. Paths in the "OrphusBot" column are relative to this repo; "§n" means a section of our DESIGN.md.

---

## 0. TL;DR

- **Rakazo is much broader on the surface; OrphusBot is deeper underneath.** Rakazo has polished chat ergonomics (reactions, reply and quote, search, unread state, drafts, sections and pins, a command palette, Mermaid and interactive tables, file previews), voice (hold-to-talk dictation, read-aloud, calls), a real mobile app, change-watching routines, secrets cards, memory providers, skills and "teach a task". OrphusBot has things Rakazo has nothing like: System 1 with receipts and calibration, discussions with verdicts, fleets, the team wiki, the wearable, ambient capture with ADHD-first profiles, Omarchy integration, placement across Kelvin's own machines, and per-bot Google rights.
- **The biggest UX gap is the Flutter app.** It is about 2,800 lines and covers chat, discussions and settings. Tickets, routines, decisions, captures and the bot's screen exist only in the Leptos web UI, and the app has no phone layout even though it builds for Android.
- **Rakazo moved fast in five days.** Since `7d5e64c` it added change-watch routines, silent routine checks, bot fleet management, bots proposing their own instruction changes, Honcho memory, voice calls, image and video generation, a self-hosted voice provider, Mermaid in chat, cards that never block a chat, foldable and tablet layouts, swipe actions on mobile and Dutch and Hebrew UI.
- **Top gaps for Kelvin**, in order (full backlog in §5): a phone-shaped Flutter app; a needs-you inbox; tickets, routines and the bot's screen in the Flutter app; an offline outbox; voice notes and dictation; drafts that survive switching bots; search; unread state; change-watching routines; secret and login cards. Read-aloud and voice calls are deliberately left off (the wearable has no speaker, and calls are a v1 non-goal).

---

## 1. Rakazo now

### 1.1 Shape (unchanged since the architecture study)

TypeScript monorepo. Clients: `apps/web` (React 19, Vite, Tailwind v4, shadcn on Base UI), `apps/desktop` (Electron 44), `apps/mobile` (Expo SDK 57, React Native 0.86, expo-router), `apps/www` (Astro marketing site). Server: `apps/api` (Hono + oRPC), `apps/worker` (Graphile Worker and the run executor). Shared: `packages/core`, `packages/contracts`, `packages/adapters`, `packages/chat-ui`, `packages/ui-web`, `packages/ui-tokens`, `packages/memory`, `packages/db` (Prisma). There is also a hosted beta, "Rakazo Cloud", which is the Electron app's default choice (`apps/desktop/src/setup-config.ts`) and is billed per seat through Stripe (`packages/adapters/src/stripe-billing.ts`).

### 1.2 What changed since `7d5e64c`

From `git log 7d5e64c..38b8e713` (170 commits), grouped:

| Area | Notable additions (PR numbers) |
|---|---|
| Bots and models | Bots can set up the bots they created ("fleet management", #1502); public description kept distinct from private instructions (#1504); bots propose changes to their own instructions (#1316); the user's time zone is given to bots (#1446); one OpenAI-compatible connection serves several models (#1424); text-only model warning (#1468); custom models get extra-high and max thinking (#1559); popular providers listed first (#1584); drag bots into sections and groups (#1350); delete a section (#1503) |
| Memory | Honcho provider (#1361); delete memory documents (#1403); remembered facts append instead of replacing |
| Routines | Routines that run when something changes (#1462); silent unchanged checks with evals (#1551); retry once after a transient model failure (#1397); failure reason in run history (#1541); schedules described in words (#1428) |
| Delegation | Up to 10 bots per group (#1405); members-first group picker (#1434); configurable bot-to-bot hop limit (#1452); peer replies fold under a marker (#1489) |
| Integrations | Image and video generation (#1441); Parallel and Keenable web search (#1439, #1522); OpenAPI in YAML (#1528); audio attachments (#1474); Mermaid diagrams in chat (#1423); bots fill file-upload fields (#1469) |
| Messaging | Several Telegram bots (#1412); Slack 👀 when a reply is late (#1476); an emoji reaction wakes the bot (#1467) |
| Voice | Bot voice calls behind a flag (#1398); self-hosted OpenAI-compatible voice (#1495) |
| Chat UX | Cards never block a chat (#1567); new sidebar footer with account menu, Connect apps pill and update button (#1590); activity sidebar cleanup (#1573); last-message time on rows (#1463) |
| Mobile | Split view on foldables and tablets (#1435, #1442); swipe to mark read, archive or pin (#1359); collapsible inbox sections (#1538); search in a sheet (#1510); native login autofill sheet (#1582); per-bot notifications switch (#1540); battery use reduced |
| Computers | Start only when used, uptime caps on billed providers (#1465); local computer access from the desktop app (#1519); DNS servers for computers (#1521); terminal and files dock removed from the computer view (#1588) |
| Ops | Sentry-compatible errors (#1349); OpenTelemetry export (#1317); Railway private template (#1342); `/ready` checks the database (#1517); disk checks for deploys and backups (#1516) |
| i18n | Dutch (#1535) and Hebrew, right to left (#1491) |

---

## 2. Feature matrix

Status: **Have** (equivalent exists), **Partial** (some of it), **Missing**, **Better** (OrphusBot does more or does it more safely). "Non-goal" marks things PRD §3 rules out for v1; they are still listed so nothing is lost.

### 2.1 Onboarding and auth

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Public welcome page with sign-up and sign-in | `apps/web/src/pages/Welcome.tsx` | none | Missing | One owner; no public page needed. A first-run splash in the app would still help |
| Email and password sign-up, sign-in, forgot and reset password | `apps/web/src/pages/Auth.tsx`, `PasswordReset*` | Passkeys (§18.1 Sign-in) | Better | No passwords at all; passkeys plus a setup token that dies after the first passkey |
| OIDC single sign-on, link SSO to an account | `packages/auth/src/oidc.ts`, `apps/web/src/components/AccountAccess.tsx` | none | Missing | Not needed for one owner |
| Device sign-in for native apps | Bearer tokens in SecureStore (`apps/mobile/lib/session.ts`) | Device linking with an 8-character code (§18.1, D-019) | Have | Our linking works for the Flutter app, CLI and Tauri. Missing: a long-lived device token in the Android keystore (§12) |
| Onboarding step 1: connect a model (provider, model, thinking, OAuth device code or API key, OpenAI-compatible URL, "Test") | `apps/web/src/pages/Onboarding.tsx` | Model logins live on each node; the app only lists models (`/api/models`, §11.3) | Partial | No in-app sign-in to Claude or ChatGPT yet. The login relay in §8 is designed but not built |
| Onboarding step 2: server integrations (Composio, Pipedream, MCP) | `apps/web/src/components/integrations/IntegrationSetup.tsx` | Settings → Connections | Partial | No guided first run |
| Onboarding step 3: a first bot ("Chief") is created and opens with a "what do you want me on first?" choice card | `apps/web/src/pages/shell/message-cards.tsx` | House bots seeded by migration; Orchestrator opens by default (§5.4) | Partial | We seed a whole team, which is better for Kelvin; we have no first-run conversation or choice card |
| New bot introduces itself and asks for what it needs | `CHANGELOG.md`, `apps/api/src/router.ts` (`bots.create`) | none | Missing | Cheap and useful |
| Paywall and subscription gate | `apps/web/src/components/SubscriptionGate.tsx` | none | Missing | Non-goal (single owner, no billing) |
| Electron setup: Cloud, "This computer" (managed Docker Compose) or "Existing instance" | `apps/desktop/src/setup.html`, `local-stack.ts` | Tauri and Flutter ask for the server address (§12) | Partial | We have no managed local stack; the server lives on the GPU box by design (D-005) |
| Agent-assisted install prompt | `SETUP_PROMPT.md` | none | Missing | A "set up OrphusBot with your coding agent" prompt in DEVELOPMENT.md would be small |

### 2.2 Bots: creation, config, avatars, instructions, models

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Create bot: name, title, description, Team or Private computer | `apps/web/src/pages/shell/bot-panel.tsx` | `+ New bot` / Settings → Bots (`apps/orphusbot_app/lib/settings.dart`, §18.1 Bots) | Have | We also have instructions, model, thinking, Google rights at creation |
| Public description vs private instructions | `packages/adapters/src/builtin-tools.ts` (#1504) | `remit` vs `instructions` (§18.1 Bots) | Have | — |
| Instruction history with restore | `apps/web/src/components/InstructionSettings.tsx`, `packages/db/src/bot-instructions.ts` | none | Missing | — |
| Bot proposes changes to its own instructions (diff card, Apply/Edit/Dismiss, Undo) | `apps/api/src/bot-update.ts`, `packages/core/src/instruction-diff.ts` | none | Missing | Good fit: lets bots learn Kelvin's preferences without him writing prompts |
| Duplicate bot | `apps/web/src/pages/BotContextMenu.tsx` | none | Missing | — |
| Archive and restore; delete with "keep or delete memories" | `apps/web/src/pages/shell/dialogs.tsx` | Disable only (§18.1 Bots) | Partial | No delete or archive |
| Export bot as JSON | `bot-panel.tsx` | none | Missing | — |
| Clear conversation | `bot-panel.tsx`, `dialogs.tsx` | none | Missing | One lasting session per bot (§18.1 Resume); a "fresh start" would need a new Orphus session |
| Avatar: 8 shapes × colour, or an uploaded image; "robot" or "organic" style; Avatar Studio popover | `packages/contracts/src/bot-avatar.ts`, `packages/core/src/bot-avatar-shapes.ts`, `apps/web/src/pages/shell/avatar-studio-popover.tsx` | Animated Rive faces with five moods per house bot (§12 Bot faces, D-034) | Better / Partial | Ours show state (thinking, working, needs you, done), which matters more. Missing: picking a face or colour for a new bot, uploading a picture |
| Bot sets its own avatar from an image | `packages/adapters/src/bot-avatar.ts` | none | Missing | Low value |
| Model per bot and thinking level | `bot-panel.tsx`, `packages/ui-web/src/model-thinking-options.tsx` | Model drop-down from `/api/models`, thinking levels (§11.3) | Have | — |
| Provider catalogue with subscriptions (Codex, Copilot, xAI, Claude), Bedrock, OpenRouter, Cloudflare gateway, OpenAI-compatible multi-model connections, local Ollama or LM Studio | `packages/adapters/src/pi-models.ts`, `pi-oauth.ts`, `pi-local-provider.ts`, `pi-openai-compatible-provider.ts` | Whatever Orphus on a node can reach (§11.3) | Have | Same Pi underneath. Ours keeps subscription tokens on the node (G5), which is stricter |
| Models settings page: providers list with search, connect, test, disconnect | `apps/web/src/pages/ModelSettingsOverlay.tsx` | none (nodes only) | Missing | Pairs with the login relay (§8) |
| Ordered backup models | `apps/web/src/pages/ModelBackupsSettings.tsx`, `packages/db/src/model-backups.ts` | Quota tracker designed (§8) | Partial | Usage is recorded; no fallback list |
| Text-only model warning in the picker | `packages/adapters/src/model-modalities.ts` (#1468) | none | Missing | We pass images only to models that take them (§12) but don't warn |
| Disabled tools per bot | `bot-panel.tsx` | `exclude_tools` in the bot table (§18.1 Bots) | Partial | Not editable in the Flutter app |
| Per-bot notifications switch | `Bot.notifyOnFinish`, `apps/mobile/app/bot-profile.tsx` | none | Missing | All bots push the same way (§12 Push) |
| "Read replies aloud" and per-bot voice | `bot-panel.tsx` | none | Missing | Low priority for Kelvin (see §5) |
| Memory scope per bot (inherit, isolated, shared) | `bot-panel.tsx` | Team vs private computer shares `/shared` and the wiki (§4.4, §11.4) | Partial | — |
| Per-bot credentials (website login, basic, bearer, header, command variable) | `apps/web/src/pages/shell/bot-credentials.tsx` | none | Missing | See §2.10 |
| Sidebar sections, pins, drag to reorder, nested child bots | `apps/web/src/pages/Shell.tsx`, `packages/core/src/bot-sections.ts` | Fixed list, Orchestrator first (§5.4) | Missing | — |
| Bots create peer bots (`spawn_bot`) | `packages/adapters/src/child-bots.ts` | none | Missing | We hand work to existing teammates instead (§5.3) |
| Fleet management: a bot organises, instructs and schedules the bots it created, every change asks | `docs/fleet-management.md`, `packages/adapters/src/fleet-tools.ts` | Orchestrator coordinates; Settings → Fleets for Orphus fleets (§5.4, §11.2) | Partial | Different idea of "fleet": ours are Orphus helper teams. Rakazo's lets a bot edit its children |
| User's time zone given to every turn | `packages/adapters/src/current-time.ts` (#1446) | Capture profile has a time zone (§10.5) | Partial | Not passed to bots' runs |

### 2.3 Chat UX

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Live event stream with resume from a cursor | `apps/web/src/lib/rpc.ts`, `packages/core/src/events.ts` | `/api/events` SSE with `Last-Event-ID` (§18.1) | Have | The Flutter app replays from 0 on every start (`lib/api.dart`) |
| "Stream replies" switch (off by default; text appears when done) | `apps/web/src/lib/response-streaming.ts` | Always streams | Missing | Calmer default worth copying |
| Blinking cursor, temporary closing of an open code fence while streaming | `packages/chat-ui/src/markdown.web.tsx` | Growing Markdown bubble (`lib/chat.dart`) | Partial | — |
| "X is working" shimmer with the working bots' faces | `apps/web/src/components/ai/CollaborationMarker.tsx` | Face mood and header status (§12 Bot faces) | Have | Ours is arguably clearer |
| Jump to latest button; keep position when scrolled up | `Shell.tsx` (`Transcript`) | Always jumps to the bottom | Missing | Annoying when reading back |
| Load earlier messages (paging) | `Shell.tsx` | Whole history in memory | Missing | Will matter as threads grow |
| Day separators and hover timestamps | `packages/core/src/time-separators.ts` | none | Missing | — |
| Markdown: GFM, code copy button, sideways scroll | `packages/chat-ui/src/markdown.web.tsx` | `markdown_widget` with copy button (§12 Reply formatting) | Have | The Leptos UI renders plain text on purpose |
| Syntax highlighting | Mobile only (`markdown.native.tsx`) | `markdown_widget` defaults | Have | — |
| Interactive tables: sort, page, copy as TSV, download CSV, expand | `packages/chat-ui/src/markdown-table.tsx` | Plain tables | Partial | — |
| Mermaid diagrams, themed, cached | `packages/chat-ui/src/mermaid.ts` (#1423) | none | Missing | — |
| Charts (Observable Plot specs) | `apps/web/src/pages/shell/message-cards.tsx`, `render_plot` tool | none | Missing | — |
| Links: favicons, external-link confirm dialog, tap-to-load remote images | `packages/chat-ui/src/` | Plain links | Missing | Link confirm is a cheap safety win |
| Attachments: picker, drag and drop, paste; 4 files, 10 MB; images, audio, PDF, video, text, HTML, ZIP | `packages/contracts/src/attachments.ts`, `apps/web/src/lib/pending-attachments.ts` | 📎, Ctrl+V picture paste; 10 files, 10 MB (§12 Sending pictures) | Partial | Missing drag and drop; the Leptos UI has no attachments |
| Image lightbox; audio player; previews for PDF, Markdown, video and sandboxed HTML | `apps/web/src/components/ArtifactFileCard.tsx`, `SandboxedHtmlViewer.tsx`, `PdfViewer.tsx` | Inline images; other files are tiles with Save | Partial | — |
| Hold-to-talk dictation with slide-up lock | `apps/web/src/components/composer/HoldToTalk.tsx`, `apps/web/src/lib/dictation.ts` | none in clients (the wearable button is the voice path, §9.3.5) | Missing | High value on the phone |
| Voice calls with a bot (barge-in, transcript card, call back) | `apps/web/src/lib/call-session.ts`, `components/call/` (#1398) | none | Missing | Non-goal for v1 (PRD §3) |
| Read a reply aloud | `apps/web/src/lib/tts.ts` | none | Missing | — |
| Reactions (six emoji); a reaction can wake the bot; 👍/👎 answers a pending yes/no question; 👍 settles a takeover | `packages/contracts/src/reactions.ts`, `apps/api/src/thread-target.ts` | none | Missing | 👍-to-answer maps neatly onto the wearable's tap grammar |
| Reply to a message, quote selected text | `apps/web/src/pages/shell/chat-context.tsx`, `packages/core/src/message-quote.ts` | none | Missing | — |
| Copy message | `Shell.tsx` | Copy, and Save reply as Markdown (§12) | Better | — |
| Edit, regenerate, delete a message | none | none | Have (parity) | Neither has them. Rakazo leaves them out deliberately (one continuous thread per bot, VISION.md) |
| Threads or branching | none | none | Have (parity) | — |
| `@` mentions (bot, group, routine, connector, `@everyone`) | `packages/core/src/composer-mentions.ts` | `OB-12` ticket references (§18.1 Tickets) | Partial | — |
| `/` skills and actions in the composer | `packages/core/src/composer-slash.ts` | `/fleet <name> <task>` only (§11.2) | Partial | — |
| Drafts saved per thread | `apps/web/src/lib/composer-draft.ts` | none | Missing | ADHD-relevant: a half-written thought survives switching bots |
| "Send with Enter" preference | `apps/web/src/lib/composer-enter-to-send-pref.ts` | Enter sends, Shift+Enter new line | Have | — |
| Command palette (Cmd/Ctrl+K, switch bot) | `apps/web/src/pages/shell/command-palette.tsx` | none | Missing | PRD B-CLI-07 (P1) |
| Search across messages, chats, files, links and routines; jump to the hit | `apps/web/src/pages/SpaceSearch.tsx`, `packages/contracts/src/search.ts` | none | Missing | DESIGN §12 lists it as "Next" |
| Unread state, mark unread, last-message time on rows | `Shell.tsx`, `apps/web/src/lib/roster-status.ts` | "needs you" and "working" marks | Partial | — |
| Activity view: runs grouped Now / Recent, filters by status and date | `apps/web/src/pages/ActivityList.tsx` | none | Missing | — |
| Tool activity disclosure (off by default; last six steps live, folds to "Done · N tools · time") | `apps/web/src/components/ToolActivityDisclosure.tsx`, `docs/tool-activity.md` | Tool calls appear only as approval cards | Missing | Useful for trust without noise |
| Short, readable run errors that name the provider and the limit (rate limit, credit, key, model not found) | `packages/core/src/run-error.ts` | "The run failed: …" notice | Partial | — |
| Bot-to-bot replies folded under "Message from X" markers; read-only peer chat view | `packages/core/src/message-visibility.ts`, `apps/web/src/pages/PeerMessagesOverlay.tsx` | `ask_bot` answers come back as labelled messages (§5.3) | Partial | — |
| Group chats (2 to 10 bots) with handoff | `packages/adapters/src/group-handoff.ts`, `apps/web/src/pages/GroupPanel.tsx` | Discussions (§11.4) | Partial / Better | Discussions are structured debates with a verdict; we have no free-form group chat |
| Cards never block the chat | `VISION.md`, `packages/core/src/answerable-ask.ts` (#1567) | A message joins or steers the run (§3.2) | Have | — |
| Right-to-left text, 12 UI languages | `apps/web/lingui.config.ts` | English only | Missing | Not a need for Kelvin |

### 2.4 Memory

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Built-in memory documents with revisions, per bot or shared; up to 32 KB injected into each run as untrusted data | `packages/memory/src/index.ts`, `packages/adapters/src/memory-context.ts` | Team wiki in `/shared/wiki` (§11.4, D-038) | Better / Partial | Ours is a real knowledge wiki that bots query before research and file discussions into. Rakazo injects memory automatically; ours must be asked |
| `remember`, `save_shared_memory` tools | `packages/adapters/src/memory-tools.ts` | Bots write wiki articles with file tools (§11.4) | Have | — |
| Semantic memory providers: Serenity, Supermemory, Honcho | `packages/adapters/src/memory-provider-factory.ts`, `honcho-memory-provider.ts` | Dossier retired; `memory` tool kept for nodes that set it up (§11.4) | Partial | No hosted providers needed |
| Knowledge panel: view, edit, delete, export memory documents; shared skills; shared documents | `apps/web/src/pages/KnowledgeSection.tsx`, `MemorySettingsOverlay.tsx` | none | Missing | No UI to browse the wiki |
| History compaction with recall of compacted memories | `packages/adapters/src/history-compaction.ts` | Orphus compacts sessions itself | Have | Engine-side |
| Per-bot open-work list (scratchpad: open, parked, done) | `packages/adapters/src/scratchpad-tools.ts`, `apps/web/src/pages/ScratchpadSection.tsx` | Tickets only | Missing | — |

### 2.5 Routines and scheduling

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Cron schedules with time zone; presets (hourly, daily, weekdays, weekly, monthly, interval); one-off "run at" | `apps/web/src/pages/RoutineSchedule.tsx`, `packages/core/src/cron.ts` | Cron presets, one-off, IANA zone (§18.1 Routines) | Have | Only in the Leptos UI |
| Schedules described in words | `packages/core/src/cron.ts` (#1428) | none | Missing | Small and helpful |
| Webhook trigger with a rotatable key | `apps/api/src/webhook.ts` | `/hooks/routine/{token}`, shown once (§18.1 Routines) | Have | No key rotation |
| GitHub event trigger | `apps/api/src/github-webhook.ts` | none | Missing | — |
| Inbound message trigger (Slack, Teams) | `apps/api/src/messaging-inbound.ts` | none | Missing | Non-goal (messaging) |
| **Change-watch trigger:** fingerprint files, a command's output or a read-only tool every N minutes, with no model call; run only on change | `packages/adapters/src/routine-watch.ts` (#1462) | Pre-flight asks System 1 whether to fire (§18.1 Routines) | Partial | Ours still spends a decision per firing; a deterministic watch is cheaper and certain. Combine both |
| Silent unchanged checks (`NO_RESPONSE`), plus silence evals | `packages/adapters/src/silent-reply.ts`, `packages/testkit/src/evals/silence.ts` | Pre-flight skips with a notice | Partial | No "say nothing if nothing new" for runs that do fire |
| Retry once after a transient model failure | `packages/adapters/src/wakeup.ts` (#1397) | Run re-queues on node loss, three attempts (§18.1 Runs) | Partial | Not for model errors |
| Run history per routine with failure reasons, "View chat" | `apps/web/src/pages/RoutineRunHistory.tsx` | Firing notices in the bot's thread | Partial | — |
| Test run | `RoutineEditor.tsx` | Run now | Have | — |
| Model pin per routine | `Routine` model | none | Missing | Listed in §18.1 as the full design |
| Notify switch per routine | `Routine.notify` | Finished routine runs always push at priority 3 (§12 Push) | Partial | — |
| Bots schedule work themselves (`schedule_create`, `schedule_list`, `schedule_cancel`) | `packages/adapters/src/schedule-tools.ts` | none | Missing | "Remind me tomorrow" from chat or the wrist needs this |
| Routines live in the bot's side panel, under its screen | `apps/web/src/lib/right-panel-state.ts` | Separate Routines sheet (Leptos) | Partial | Flutter app has none |
| Daily cap on routine runs | none | 20 per day (§18.1 Routines) | Better | Protects subscriptions |
| Pre-flight with System 1 | none | `preflight.worth_running` (§7.2) | Better | — |

### 2.6 Computers

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Team and Private computers | `VISION.md`, sandbox providers | One container per bot; team bots share `/shared` (§4.4) | Have | — |
| Providers: Docker, E2B, Daytona, CreateOS, Boat, Railway, trusted local host | `packages/adapters/src/sandbox-factory.ts` | Podman on Kelvin's nodes, E2B (§4.4, §6.2) | Partial / Better | Fewer providers (non-goal), but placement across his own machines with battery and quiet hours is ours alone |
| Lazy start, idle sleep, uptime caps | `computer-idle.ts` (#1465) | E2B auto-pause; container reused (§6.2) | Partial | Local containers run `sleep infinity` with no idle stop |
| Screen preview in a side panel; full-window viewer; Take control and Release; "Needs you" and "You have control" pills | `apps/web/src/pages/ResizableSidePanel.tsx`, `apps/web/src/screen-proxy.ts` | noVNC sheet with view and Take control (§4.4) | Partial | Leptos only; the Flutter app has no viewer and its takeover card lacks "Open screen" |
| Takeover asked by the bot | `request_takeover` | `request_takeover` and its card (§4.4) | Have | — |
| Booting progress overlay | full-window computer overlay | none | Missing | — |
| Maintenance menu: Recover, Reset, Update computer | `apps/web/src/components/ComputerMaintenanceActions.tsx` | none | Missing | — |
| Teach a task: record a demonstration, get an editable skill draft, test it, add it to a routine | `apps/web/src/components/teach/`, `packages/adapters/src/teaching-session.ts` | none | Missing | — |
| GUI tools (`computer_observe`, `computer_act`), browser tools with secret fill | `packages/adapters/src/browser-tools.ts` | Chromium in the desktop image; bots use `bash` (§4.4) | Partial | No structured observe and act tools |
| Terminal and files dock | removed in #1588 | none | Have (parity) | Rakazo dropped it |
| Restricted egress, custom DNS for computers | `infra/compose/restrict-computer-egress.sh`, `SANDBOX_COMPUTER_DNS` (#1521) | nftables block of LAN and NetBird ranges, applied from outside (§4.4) | Better | Always on, not opt-in |
| Local host access from the desktop app with a consent dialog | `apps/desktop/src/host-computer.ts` (#1519) | `ORPHUSBOT_RUNTIME=none` (§18.1) | Partial | Still gated per call |

### 2.7 Delegation

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| `message_bot` with a hop limit | `packages/core/src/bot-messages.ts` | `ask_bot` makes a ticket, three deep (§5.3) | Have | Ours leaves a trail on the board |
| Teammate directory in the prompt | `packages/core/src/bot-messages.ts` | Roster with each teammate's model, Google rights and connections (§5.3, M10.2) | Better | — |
| Group chat handoff | `packages/adapters/src/group-handoff.ts` | none | Missing | See §2.3 |
| Short-lived subagents | `run_subagent` | Orphus subagents and fleets, gated (§11.2) | Have | — |
| `spawn_bot` and fleet management | §2.2 | none | Missing | — |
| Cursor cloud agents (launch, status, reply, cancel; PR link card) | `packages/adapters/src/cursor-cloud-agent.ts` | Fleets cover this (architecture study §11) | Missing | Skip |
| Agent connections to other people's agents | `packages/adapters/src/agent-connections.ts` | none | Missing | Single owner; skip |
| Structured debate with verdict | none (only a code-review skill's verdict, `builtin-skills.ts`) | Discussions (§11.4) | Better | — |
| An orchestrating main bot | none ("Chief" is a starter bot) | The Orchestrator (§5.4) | Better | — |

### 2.8 Integrations and tool sources

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Composio app catalogue | `packages/adapters/src/composio-connector.ts` | none | Missing | Decided against for v1 (PRD Q7) |
| Pipedream Connect (remote MCP) | `packages/adapters/src/pipedream-connector.ts` | Any remote MCP URL works (§11) | Partial | — |
| Remote MCP (HTTP, SSE), OAuth, stdio on an allow-list | `packages/adapters/src/mcp-connector.ts`, `mcp-oauth.ts` | URL and command servers, OAuth with dynamic registration, node allow-list (§11) | Have | Missing: providers without dynamic registration |
| Per-bot grants | `BotMcpServer` | Chips per bot (§11) | Have | — |
| Bots add an MCP server themselves (with an approval card) | `add_mcp_server`, `apps/api/src/mcp-approval.ts` | none | Missing | — |
| OpenAPI (JSON, YAML) and GraphQL tool sources, Treg, Executor | `packages/adapters/src/installed-connectors.ts`, `graphql-connectors.ts` | none | Missing | — |
| Lazy catalogue over 20 tools | `packages/adapters/src/lazy-tool-catalog.ts` | Orphus's `mcp` tool (§11, D-029) | Have | — |
| "Connect apps" overlay: featured tiles (Gmail, Calendar, Drive, Slack, Notion), catalogue, accounts, tools, Advanced | `apps/web/src/pages/PluginsOverlay.tsx`, `packages/core/src/featured-connectors.ts` | Settings → Connections form | Partial | Our list is a form, not a catalogue |
| Google Workspace | Composio connectors, per space | `gws` on the node with none / read / write per bot, gated per command (§11.5) | Better | Per-bot rights; writes always ask |
| Web search providers (keyless DuckDuckGo plus page extraction; Parallel; Keenable) with an SSRF-safe fetch | `packages/adapters/src/web-provider-factory.ts`, `web-ssrf.ts` | Bots browse from their computer | Partial | No search tool or reader |
| Image and video generation | `packages/adapters/src/media-generation-tools.ts` (#1441) | none | Missing | — |
| Skills shared across the space; built-in skills | `packages/adapters/src/skill-tools.ts`, `builtin-skills.ts` | Orphus skills on the node (§11.4) | Partial | No UI to see or edit them |
| Artifacts: versioned; Artifacts page with filters, card and list views, previews | `apps/web/src/pages/Artifacts.tsx`, `packages/core/src/artifact-sandbox.ts` | `share_file` with versions, download links (§11.1) | Partial | No gallery page |
| Ticket board | `apps/web/src/pages/Board.tsx`, `ticket-tools.ts` | Tickets with System 1 triage (§18.1 Tickets) | Better | Missing: comments, "won't do" column, ticket tools for bots |
| Messaging channels: Slack, Telegram, WhatsApp, Lark, iMessage, SMS (Sendblue); team-chat judge | `packages/adapters/src/messaging-platforms.ts`, `apps/api/src/team-chat-judge.ts` | none | Missing | Non-goal (PRD §3) |

### 2.9 Approvals and safety

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Approval card: Allow once / Always allow / Deny, reviewer's reason, recipient, subject, amount | `apps/web/src/components/AskCard.tsx`, `packages/adapters/src/approval-ask.ts` | Same three buttons (§18.1 Approvals) | Partial | Ours shows raw JSON input; no summary of to, subject, amount |
| Rules by tool, connector or category (email, purchase); presets "Ask before sending external email" and "Ask before purchases" | `packages/core/src/action-approval.ts`, `ApprovalRulesSettings.tsx` | Rules per tool (§7.4) | Partial | No rules screen; no categories |
| Static classes: exempt, always consequential, mandatory human approval | `action-approval.ts` | Static classes, reversible and irreversible (§7.4) | Have | — |
| **Default is to run consequential connector calls without asking** unless rules or auto-review say otherwise | `action-approval.ts` | Everything that isn't a read asks (§18.1 Approvals) | Better | Safer default |
| Auto-review: LLM, Jev (`TYPESAFE_API_KEY`), scripted; pass below 0.5 becomes ask; 10 s timeout | `packages/adapters/src/auto-review.ts`, `jev-auto-review.ts` | System 1 with fitted thresholds, never under 0.9, never for irreversible actions (§7.4, §7.5) | Better | — |
| Idempotency ledger with "uncertain" | `packages/adapters/src/approval-effect.ts` | Effect ledger with a "may already have run" card (§3.4) | Better | Rakazo shows it only through the bot's next reply |
| Webhook runs need a person for side effects | `apps/api/src/webhook-inbound.ts` | Webhook body quoted as data (§18.1 Routines) | Partial | No extra restriction on webhook-started runs |
| Prompt-injection fencing for webhooks, tickets, memory, peer messages | `packages/core/src/prompt-data.ts` | Tickets and webhooks passed as labelled data (§18.1) | Have | — |
| Secret redaction (plain, base64, URL-encoded) | `packages/core/src/events.ts` | Same three forms (§11) | Have | — |
| Loop guard (six identical calls), hop limit | `packages/adapters/src/tool-loop.ts` | Hand-offs three deep (§5.3); the engine's own guards | Partial | — |
| Shell refusals that protect the desktop, with recovery hints | `executor.ts` (#1569) | Container is the boundary | Have | Different approach |

### 2.10 Secrets and logins

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| `request_secret` card: masked field bound to one origin | `packages/adapters/src/bot-secrets.ts`, `docs/bot-secrets.md` | none | Missing | Today a bot needing a key must ask in chat, which puts it in the transcript |
| `secret_request`: server makes the authenticated HTTP call, the bot never sees the value | `bot-secrets.ts` | none | Missing | — |
| Website logins filled by `fill_secret`; mobile native sheet with password AutoFill | `packages/adapters/src/browser-tools.ts`, `apps/mobile/components/secret-ask-sheet.tsx` | Takeover for logins (§4.4) | Partial | Takeover works but costs Kelvin a context switch every time |
| Command variables exported to the bot's shell, redacted | `docs/bot-secrets.md` | none | Missing | — |
| Secret store: AES-GCM in Postgres or Infisical | `packages/adapters/src/secret-store-factory.ts` | AES-256-GCM with a key file (§11) | Have | — |

### 2.11 Notifications

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Push (Expo, FCM): finished, failed, needs help, takeover; tap opens the thread | `packages/adapters/src/expo-push.ts`, `apps/mobile/lib/open-notification.ts` | ntfy, no Google account; tap opens the bot (§12 Push) | Have | — |
| Android live "working" notification from a foreground service | `apps/mobile/modules/rakazo-notifications` | Wearable shows queued, running, done (§9.3) | Partial / Better | Phone has no ongoing status |
| Notification settings: messages, scheduled tasks, needs attention, live status | `apps/mobile/app/(settings)/account.tsx` | none | Missing | — |
| Per-bot silence | `Bot.notifyOnFinish` | none | Missing | — |
| Browser notifications when the page is hidden | `apps/web/src/lib/browser-notifications.ts` | `orphusbot watch --notify` via `notify-send` (§12) | Have | Desktop only through the CLI |
| Reminder at 4 h for waiting work; cancel at 24 h | `packages/core/src/stuck-work.ts` | Wrist asks expire after 10 min and go to push (§9.3) | Partial | No reminder for a card left open on the phone |
| Digests, quiet hours, "still open" wording | none | Focus profile digests, quiet hours on nodes, no guilt language (§10.5) | Better | — |
| Suppress banners for the open thread | `apps/mobile/lib/push.ts` | none | Missing | Small |

### 2.12 Clients

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Web app, mobile-width drawer and swipe | `apps/web/src/pages/Shell.tsx` | Leptos UI with a slide-in sidebar under 760 px (`crates/ui`) | Have | — |
| Desktop app with auto-update, menus, microphone entitlement | `apps/desktop/src/auto-update.ts`, `main.ts` | Flutter on Linux (`apps/orphusbot_app`), Tauri window (§12) | Partial | No auto-update |
| Native mobile app: inbox, chat, search sheet, bot profile, settings stack, computer view, artifacts | `apps/mobile/app/` | Flutter builds for Android but has no phone layout; Tauri Android wraps the web UI (§12) | Partial | The single biggest client gap |
| Split view on tablets and foldables with a resizable pane | `apps/mobile/lib/split-view.ts` | Fixed 220 px sidebar (`lib/chat.dart`) | Partial | Works on wide screens only |
| Swipe actions: read/unread, archive, pin | `apps/mobile/components/inbox-swipe-row.ios.tsx` | none | Missing | — |
| Long-press message menu: reply, copy, react, quote, speak, select text | `apps/mobile/components/message-context-menu.tsx` | Copy and Save buttons | Partial | — |
| Offline outbox (50 MB, retried), saved inbox shown offline | `apps/mobile/lib/outbox-disk.ts`, `saved-chats.ts` | Planned in SQLite (§12) | Missing | PRD B-CLI-05 |
| Keyboard handling, scroll-to-hide keyboard | `apps/mobile/lib/keyboard-scroll-back.ts` | none | Missing | — |
| Status-bar widget | none | Omarchy bar panel with faces, approvals and a message box (§12) | Better | — |
| CLI | none | `orphusbot link, status, watch, answer, send` (§12) | Better | — |
| Wearable | none | Full duplex habitat (§9) | Better | — |

### 2.13 Self-hosting and deploy

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| One-line installer for published images; Compose overlays; Caddy; host hardening | `infra/compose/install-images.sh`, `harden-host.sh` | DEPLOY.md over NetBird with Caddy (D-016) | Partial | No installer or release binaries yet (§16 plans them) |
| Railway template | `infra/railway/` (#1342) | none | Missing | Not wanted; the GPU box is home |
| Updater sidecar; software update in Settings | `infra/updater/`, `apps/web/src/components/SoftwareUpdateSection.tsx` | none | Missing | — |
| Backups with disk checks | `scripts/backup.sh`, `infra/compose/deploy-main.sh` | Nightly `pg_dump` planned (§16) | Partial | — |
| `/ready` health endpoint | `apps/api/src/health.ts` (#1517) | none found in `crates/server/src` | Missing | Small; useful for the bar widget |
| Sentry-compatible errors; OpenTelemetry | `apps/api/src/monitoring.ts`, `pi-telemetry-otel.ts` | `tracing` logs | Missing | Low priority for one user |
| Restricted-network installs (mirrors) | `docs/self-host-restricted-network.md` | n/a | Missing | Skip |

### 2.14 Admin, usage and billing

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Spaces as authorisation boundaries; switch in place; space settings | `apps/web/src/pages/Shell.tsx` (#1466, #1438) | One owner, one team | Missing | Non-goal |
| Members, roles, invitations, sign-up allow-list | `packages/auth/src/index.ts`, `packages/core/src/signup-policy.ts` | none | Missing | Non-goal |
| Usage: "N runs · N tokens" only | `apps/web/src/pages/AccountSettingsOverlay.tsx` | Tokens and cost by model and by bot, today and 7 days, daily budget with a wrist warning (M4.2) | Better | — |
| Stripe billing per seat, 7-day trial | `apps/api/src/billing.ts` | none | Missing | Non-goal |
| AI data-sharing consent | `packages/core/src/ai-consent.ts` | Capture consent light and kill switch (§9.4, §10) | Partial | Different scope |
| Account deletion with an emailed code | `apps/web/src/components/AccountAccess.tsx` | Remove passkeys reopens setup (§18.1) | Partial | — |
| Appearance: System, Light, Dark; sidebar density | `AccountSettingsOverlay.tsx` | Follows the system only | Partial | — |

### 2.15 Everything else

| Rakazo capability | Rakazo source | OrphusBot | Status | Note |
|---|---|---|---|---|
| Screenshot gallery on every UI PR, nightly runs, Android and iOS galleries | `packages/testkit/src/playwright-pr-screenshot-comment.ts`, `.github/workflows/playwright.yml` | Planned (§15) | Missing | — |
| Emulators and conformance tests per provider | `packages/adapters/src/*-emulator.ts` | `testkit` fakes and wiremock (§15) | Have | — |
| Evals, including silence evals | `packages/testkit/src/evals/` | none | Missing | — |
| Computer session record and replay tests | `.github/workflows/computer-replay.yml` | none | Missing | — |
| Marketing site, comparisons, blog, downloads by platform | `apps/www/` | README | Missing | Not needed |

---

## 3. Rakazo UX and UI inventory

### 3.1 Navigation structure

- **Shell** (`apps/web/src/pages/Shell.tsx`): three columns. A 316 px left sidebar, the chat, and a resizable right side panel (`ResizableSidePanel.tsx`) whose width is remembered. Below 768 px the sidebar is an off-canvas drawer (hamburger or edge swipe, dark scrim) and the side panel covers the chat.
- **Sidebar top row:** an Activity bell, "Minimize bots", and a "+" popover with a "To:" bot search and Create new Bot, Group and Space (`apps/web/src/pages/shell/bot-picker.tsx`).
- **Sidebar search box:** searches the space; in Activity mode it becomes "Search runs" with a Filters button.
- **Roster:** spaces and user sections as small uppercase collapsible headers (lock icon on private spaces, "…" menu: Settings, Rename, Delete). Rows have a 38 px avatar (28 px compact), bold name when unread, time, unread dot, title chip and a two-line preview or a blue working line. Child bots nest under their creator. Rows drag between sections; Alt+↑/↓ reorders. Right-click menu: Pin, Move to, Mark read or unread, Edit Profile, Duplicate, Clear conversation, Archive, Delete (`BotContextMenu.tsx`). A collapsed "Archived (n)" block offers Restore and Delete.
- **Sidebar footer** (`apps/web/src/components/SidebarFooter.tsx`, #1590): one row. An avatar button opens the account menu (Usage, Get the mobile app, Docs, Board, Artifacts, Settings, Log out); a "Connect apps" pill shows up to three overlapping connected-app logos; a round "Install update" button appears when an update is ready.
- **Chat header:** 74 px tall. Bot avatar with a status ring and name (click opens bot settings in the side panel); on the right only Call (when enabled) and Agent computer.
- **Side panel modes** (`apps/web/src/lib/right-panel-state.ts`): computer (screen preview, then that bot's routines), bot settings, routine editor, create bot, create or edit group.
- **Command palette:** Cmd/Ctrl+K, "Switch bot" (`apps/web/src/pages/shell/command-palette.tsx`).
- **Other full pages:** `/app/board` (ticket board, flagged), `/app/artifacts` (gallery), `/onboarding`, auth pages, `/integrations/setup`, `/desktop-settings` (Electron only).

### 3.2 Routes

| Path | Screen | Access |
|---|---|---|
| `/` | Welcome | Public |
| `/sign-in`, `/sign-up`, `/forgot-password`, `/reset-password` | Auth frame | Public |
| `/onboarding` | Connect a model, server integrations, then the first bot | Signed in |
| `/app`, `/app/:botId`, `/app/g/:groupId` | Shell (bot or group chat); `?m=` jumps to a message, `?routine=` opens a routine | Signed in |
| `/app/artifacts`, `/app/artifacts/:id` | Artifacts gallery and detail | Signed in |
| `/app/board` | Ticket board | Signed in, flag on |
| `/integrations/setup` | Server integrations (owner) | Signed in |
| `/mcp/oauth/callback`, `/sso/callback` | OAuth landing pages | — |
| `/desktop-settings` | Local server settings (Electron) | — |

Source: `apps/web/src/App.tsx`, `apps/web/src/main.tsx`.

### 3.3 Onboarding steps

1. **Welcome:** a mascot, a large wordmark, a one-line tagline about a team of always-on agents, a "Sign up" pill and a "Sign in" link.
2. **Auth frame:** a 460 px centred column with the mascot and a 36 px heading; email and password; SSO button when configured; "Check your email" when verification is on.
3. **Connect a model** (only if none): provider and model selects, a thinking select, subscription sign-in (device code with Copy, or paste a callback URL) or an API key, "Test", and an Advanced block for OpenAI-compatible servers (thinking support, reasoning effort, max output tokens, context limit, image support).
4. **Server integrations** (only if the owner still has to choose): Direct MCP, Composio, Pipedream or Executor, with Skip.
5. **First bot:** "Chief" is created and opens with a greeting and a four-way choice card: day-to-day work, inbox and email, research and writing, or a bit of everything.

There is no visible stepper; each step is a full 560 px column (`apps/web/src/pages/Onboarding.tsx`).

### 3.4 Bot setup flow

- **Create** (side panel): Name, Title, Description, a Team or Private computer toggle, Create. The new bot opens and introduces itself.
- **Bot settings** (side panel): Avatar Studio popover (Bot or Upload tab, shape, colour swatches, drop or paste an image, Reset, Done); Name, Title and Description save on blur; a Notifications switch; then an **Advanced** fold-out: Instructions (with history and Restore), Computer, Open work (scratchpad), Knowledge (memory documents, shared skills, shared documents), Model and Thinking, Memory scope, Read replies aloud, Fleet management, Voice, Disabled tools, Credentials. Footer: Save, Export, Clear conversation (red).
- **Delete:** a dialog that explains what goes and asks "What about its memories?" (keep in shared memory, or delete).

Sources: `apps/web/src/pages/shell/bot-panel.tsx`, `avatar-studio-popover.tsx`, `bot-credentials.tsx`, `dialogs.tsx`, `apps/web/src/components/InstructionSettings.tsx`, `apps/web/src/pages/KnowledgeSection.tsx`, `ScratchpadSection.tsx`.

### 3.5 Chat layout

- Owner messages on the right; bot messages on the left in a muted rounded bubble; cards span the width. In groups each bot message has a coloured speaker header.
- Day separators and separators after a 15-minute gap; hover timestamps in the margin (under the bubble on touch).
- "Load earlier messages" at the top; a round "Jump to latest" arrow that fades in; jumping to a message centres and briefly highlights it.
- Hover actions on a message: React, Reply, More (Copy, Quote, Speak). Selecting text shows a floating "Quote" pill.
- **Composer:** a pill with "Message <name>", an attach button, `@` mentions as chips, `/` for skills and three settings shortcuts, a hold-to-talk mic (only when the draft is empty and calls are enabled), and Send. While a run is live both Send (to steer) and Stop show.
- **Errors:** a red alert above the composer with a short summary, a "Details" fold and dismiss (`apps/web/src/lib/run-error.ts`).
- **Working:** "X is working" with a shimmer and the working bots' faces when no text has streamed yet.

Sources: `apps/web/src/pages/Shell.tsx`, `apps/web/src/pages/shell/chat-context.tsx`, `packages/core/src/time-separators.ts`, `apps/web/src/components/ai/`.

### 3.6 How tool calls and approvals appear in chat

- **Tool calls:** hidden by default. With Settings → General → Advanced → "Show tool activity", each run gets a collapsible row: live it reads "Working… · N tools" and lists the last six steps with a pulsing current step; done it folds to "Done · N tools · duration". Tool names are humanised. A message that is only tool calls renders as slim lines, not a bubble (`apps/web/src/components/ToolActivityDisclosure.tsx`, `docs/tool-activity.md`).
- **Approval card:** a full-width card titled "Review before …" naming the tool and target, a detail block with the reviewer's reason and the important fields (to, subject, amount, body) with secrets redacted, and **Allow once** (primary), **Always allow this tool**, **Deny**. Mandatory ones have no "Always". After answering, the card shows the result in place, or "No longer active" (`apps/web/src/components/AskCard.tsx`, `packages/adapters/src/approval-ask.ts`).
- **Question card:** option buttons, or "Send it" / "Edit first".
- **Secret card:** masked field (Code, Password or API key, plus Username for logins), the destination origin, "Saved".
- **Instruction proposal:** before and after diff, Apply / Edit / Dismiss, then "Instructions updated · Undo".
- **Computer "Needs you" card:** a status pill and Open.
- **Other cards:** app connect (Authorize), MCP server approval, skill draft (Save, Test, Add to routine), subagent, child bot, cloud agent with a PR link, charts, phone call summaries with transcript and Call back.
- **Peer messages:** small "Messaged X" / "Message from X" chips; replies from a bot-started run fold under them; cards that need you are never folded.

### 3.7 Settings

A 1080 × 760 rounded dialog with a 200 px icon nav and 24 px section titles; sections are bordered rounded cards 20 px apart (`apps/web/src/pages/SettingsOverlay.tsx`).

| Section | Contents |
|---|---|
| General | Account, password, messaging link, Appearance (System, Light, Dark; Comfortable or Compact sidebar), Language, Time zone ("use device time zone"), Avatars (Robot or Organic), server integrations link, Advanced (Send with Enter, Stream replies, Show tool activity, Load web images automatically), account access (link SSO, delete account at the bottom) |
| Models | Active model row; a 310 px provider list with search (Connected, All providers); detail pane with sign-in or key, model and thinking, "Use this model", Disconnect; Backup models (ordered, up to 10) |
| Memory | Provider (Supermemory, Serenity, Honcho) with its form; default scope |
| Voice | Providers tagged "speak and transcribe" or "speak only"; URL, key, models; "Hear a sample" |
| Confirmations | "Flag unexpected actions" (auto-review) switch; saved rules with Remove; presets for email and purchases |
| Usage | "N runs · N tokens" |
| Computer | Only when no computer provider: `.env` guidance and "Check again" |
| Billing | Billed deployments only |
| Updates | Check for updates, Update |

Separate overlays: **Connect apps** (`PluginsOverlay.tsx`: search, featured tiles, catalogue, app detail with accounts and tools, Advanced for MCP, OpenAPI, GraphQL, Executor, Treg), **MCP servers** (`McpServersOverlay.tsx`), **Messaging** (`MessagingSettingsOverlay.tsx`: link codes, channels, agent connections, per-conversation listen or mentions-only).

### 3.8 Other screens and dialogs

- **Routine editor** (side panel; `RoutineEditor.tsx`, `RoutineSchedule.tsx`, `RoutineRunHistory.tsx`): name, instruction, active, model and thinking; "When to run" with Add trigger (schedule, Slack or Teams message, when something changes, Git event, webhook); Test run, Save, Delete; run history with "View chat".
- **Board** (`Board.tsx`): To do, In progress, In review, Blocked, Done, Won't do; card shows reference, title, owner; ticket dialog with title, description, owner, status, priority and comments.
- **Artifacts** (`Artifacts.tsx`): filters (search, date, bot chips), card or list view, cards at least 260 px; detail is a 320 px index plus preview with version switcher, Maximize, Download, Delete.
- **Activity** (`ActivityList.tsx`): runs as Now and Recent with status, date and text filters as chips.
- **Group create** (`GroupPanel.tsx`): members first, with filter and "pick 2–10", then name.
- **Computer full window:** avatar, label, status pill; Stop, Take or Release control, Teach a task, maintenance menu, Close; boot overlay.
- **Calls:** floating call card (Mute, Hang up, Transcript, Settings, Minimize) and incoming-call card.
- **Dialogs:** delete bot (memories choice), clear conversation, new or rename space, new or rename section, generic delete.

### 3.9 Empty states

All are a single short line or one button, with no illustration: "Create new Bot" alone in the main area; "No tickets yet"; "No artifacts found"; "No runs match these filters" with Reset all; "Nothing remembered yet"; "No skills yet"; "No credentials saved for this bot"; "No MCP servers yet"; "Add connected models to use them as backups"; "No runs yet"; "Computer is asleep. Open it to wake." Sources are the components named in §3.7 and §3.8. The rule in Rakazo's AGENTS.md is to remove copy that repeats a heading (#1484).

### 3.10 Computer viewer

- Side panel: a 16:10 non-interactive preview in a sandboxed frame, "Open" on hover, "X's screen", placeholder states (booting, asleep, failed, stopped). Since #1592 showing the panel never boots a stopped computer; only Open does.
- Full window: noVNC through an authorising proxy (`apps/web/src/screen-proxy.ts`, `novnc-html.ts`); input accepted only while you hold control; Take control is blocked while a run is busy unless the bot asked for you.
- The terminal and files dock was removed (#1588). Mobile renders noVNC in a WebView with a keyboard bridge and landscape rotation (`apps/mobile/app/computer.tsx`).

### 3.11 Voice UI

- Hold-to-talk in the composer: hold to talk, release to send; slide up 64 px to lock; while recording a strip shows a live dot, timer and the words so far; a tap under 350 ms only shows a hint (`apps/web/src/components/composer/HoldToTalk.tsx`).
- Read aloud: a Speak or Stop button on bot bubbles; a per-bot "Read replies aloud" switch.
- Calls: ringback while the mic permission is granted, statuses Calling, Listening, Thinking, Speaking, Muted; barge-in; call summaries in the thread (`apps/web/src/lib/call-session.ts`, `components/call/`).
- Mobile: dictation only inside calls; on-device recognition with a silence end-of-turn; a persistent mini-player (`apps/mobile/lib/dictation.ts`, `call-session.ts`).

### 3.12 Mobile (Expo) differences

- **Routes** (`apps/mobile/app/`): inbox (index), thread, group thread, bot profile, chat settings, group settings, routine, artifacts, artifact, image (full-screen), computer, search (sheet), server (sheet), sign-in, new bot, new group, new space, and a settings stack (account, language, models, voice, integrations, archived bots, change password, AI data sharing).
- **Inbox:** spaces and sections that collapse (remembered); header buttons for Activity, Artifacts, Search, Create and Account; iOS rows with native swipe (right: read or unread; left: Archive, Pin) and a context menu with a preview; Android pinned chats as avatar tiles above the list. Saved to disk and shown offline.
- **Thread:** inverted list with paging; native scroll-to-bottom; keyboard follows frame by frame and hides when you scroll back; long-press menu (Reply, Copy, React, Quote, Speak, Select text); composer with mentions, skills, camera, photos, files, Call, Send, Stop.
- **Bot profile:** avatar, name, a notifications switch, links to Chat settings, Artifacts, Computer and Routines.
- **Split view** at 700 dp and wider with a draggable pane (240 dp to window minus 360 dp); content capped at 720 dp; phones locked to portrait.
- **Login autofill sheet** with iOS password AutoFill traits, emptied before closing.
- **Push** via Expo (FCM on Android); an opt-in Android live working-status notification; banners suppressed for the open thread.
- **Offline outbox** of unsent messages with attachments (50 MB), retried on reconnect, shown as failed-send bubbles.
- **Look:** iOS 26 "liquid glass" title capsules, bar buttons and controls via SwiftUI; flat fallbacks elsewhere.
- **Not present:** home-screen widgets, share extension, Siri or app shortcuts, tool activity, the ticket board.

### 3.13 Visual language

- **Stack:** Tailwind v4 and shadcn ("base-nova" style) on Base UI primitives, with class-variance helpers (`packages/ui-web/components.json`).
- **Colour:** CSS variables generated from `packages/ui-tokens/src/index.ts`. **Dark is the default**: near-black neutrals with slightly lighter sidebar and card layers, a faint border, off-white primary and grey muted text. Light is a warm off-white with a near-black primary. Accent colour is rare: blue for links, focus rings and "working"; green, amber and red for status; a separate tint for the owner's bubble. Bots get one of seven identity colours (teal, orange, indigo, violet, blue, red-orange, pink).
- **Shape:** base radius 0.75 rem; rounded-xl cards and inputs, rounded-2xl dialogs, pill buttons.
- **Type:** Geist Variable. Small, hand-set sizes: 11 px uppercase section headers, 12.5 to 16 px body, 24 px dialog titles, 32 px onboarding heading, 36 px auth heading. Monospace for codes and tool names.
- **Density:** 316 px sidebar, 74 px header, about 10 px row padding; compact mode 44 px rows. One meaningful breakpoint at 768 px.
- **Icons:** lucide at 15 to 19 px with thin strokes.
- **Motion:** short and quiet. 120 ms fade out and 220 ms fade-and-rise when switching spaces; dialogs fade and zoom from 95 % in 100 ms with a backdrop blur; side panel width animates in 150 ms; avatar eyes blink and idle; everything respects reduced motion.
- **Copy:** minimal. No explanatory text unless it changes a decision (VISION.md, "Calm on the surface").
- **Primitives** (`packages/ui-web/src/components/ui/`): alert dialog, badge, button (default, outline, secondary, ghost, destructive, link, text; sizes xs to xl), button group, card, checkbox, command, dialog, disclosure, dropdown, field, input group, kbd, popover, scroll area, select, separator, skeleton, spinner, stepper, switch, tabs, textarea, toggle, tooltip.

**What this means for us.** Kelvin's PRD principle 7 ("dense, calm UI; no decoration without state behind it") is already close to Rakazo's. Our Flutter app uses stock Material 3 seeded from one blue, default type and default density; it reads as a prototype next to Rakazo. A small token set (neutral layers, one accent, status colours, a radius scale, a type scale) in a Flutter `ThemeExtension`, mirrored as CSS variables in `crates/ui/style.css`, would close most of the visual gap without copying anything.

### 3.14 Screens to capture live later

Rakazo's Playwright specs in `apps/web/e2e/` (for example `settings-shell.spec.ts`, `spaces.spec.ts`, `board.spec.ts`, `tool-activity.spec.ts`, `mobile-sidebar-swipe.spec.ts`, `golden.spec.ts`) seed the data each screen needs. To capture with a browser, run a local instance with a scripted model and follow these steps, at 1440 px and at 390 px wide:

| # | Screen | Steps |
|---|---|---|
| 1 | Welcome, sign-up, sign-in, forgot password, invalid reset link | Open `/`, `/sign-up`, `/sign-in`, `/forgot-password`, `/reset-password?token=x` |
| 2 | Onboarding | Sign up a new account → `/onboarding` → connect a model → (integrations) → first bot chat with the choice card |
| 3 | Shell with a bot chat | `/app/<botId>` with a few messages, a table, a code block and a Mermaid diagram |
| 4 | Command palette | In `/app`, press Ctrl+K |
| 5 | Create bot | "+" → Create new Bot |
| 6 | Bot settings and Avatar Studio | Click the bot name in the header → click the avatar → open Advanced |
| 7 | Delete bot dialog | Right-click a sidebar row → Delete |
| 8 | Sections and pins | Right-click a row → Move to → New section; right-click a section header |
| 9 | Group create and group chat | "+" → Create new Group → pick bots → open `/app/g/<groupId>` |
| 10 | Activity mode with filters | Sidebar bell → Filters |
| 11 | Search results | Type in the sidebar search box |
| 12 | Computer panel and full window | Monitor icon in the header → hover the preview → Open → "…" menu |
| 13 | Teach a task | Full-window computer → Teach a task → Start recording |
| 14 | Routine editor | Computer panel → "+" in Routines → Add trigger → "When something changes" |
| 15 | Approval, question, secret and instruction cards | A scripted run that asks each in turn |
| 16 | Tool activity | Settings → General → Advanced → Show tool activity → send a message that uses tools |
| 17 | Run error alert | A scripted run that fails with a rate limit |
| 18 | Hold-to-talk | Enable calls → press and hold the mic → slide up |
| 19 | Call card | Header Call button |
| 20 | Settings sections | Footer avatar → Settings → each nav item; General → Advanced |
| 21 | Connect apps | Footer "Connect apps" pill → a tile → Advanced → Manage MCP servers |
| 22 | Artifacts | Footer avatar → Artifacts → open one → version switcher |
| 23 | Board | Footer avatar → Board → New ticket |
| 24 | Mobile web | 390 px wide → hamburger, edge swipe, side panel over chat |

Mobile (Expo) screens are best captured on an Android emulator: inbox with sections and swipe, thread with long-press menu, search sheet, bot profile, settings stack, computer view, split view on a tablet profile.

---

## 4. What OrphusBot has that Rakazo doesn't

Each item was checked against Rakazo's code at `38b8e713` by searching for the concept and its likely names.

| OrphusBot capability | Where | Rakazo's closest | Verdict |
|---|---|---|---|
| **System 1 decision layer** (Laya): routes inbox messages and tickets, sets urgency, gates reversible calls, pre-flights routines and capture windows; every ask receipted | §7, `crates/server/src/system1.rs` | Auto-review of consequential calls only (`packages/adapters/src/auto-review.ts`) and a team-chat engagement judge (`apps/api/src/team-chat-judge.ts`). No routing, no receipts beyond the reason on the effect row | Ours only |
| **Calibration from Kelvin's own labels**, with fit, apply and rollback | §7.5, `crates/server/src/calibrate.rs` | "Calibration" appears only in an eval fixture and docs | Ours only |
| **Decisions view** (health, receipts, confidence against threshold) | §18.1 Decisions view | none | Ours only |
| **System 1 never approves irreversible actions**; threshold floor of 0.9 | §7.4, AGENTS.md rule 5 | A Jev "pass" above 0.5 runs the call; default path runs consequential connector calls without asking | Ours stricter |
| **Discussions**: 2–6 bots on their own models argue in an Orphus room over rounds; the chair writes a verdict with the strongest dissent and files it into the wiki | §11.4, `crates/server/src/discussions.rs`, `apps/orphusbot_app/lib/discuss.dart` | Group chats with handoff; "verdict" only in a code-review skill | Ours only |
| **Fleets** of Orphus helpers, each seat on its own model, every helper call gated and run in the bot's computer | §11.2, `crates/server/src/fleets.rs` | Fleet management means a bot editing its child bots; subagents in-process | Different; ours is a multi-model team |
| **The Orchestrator** main bot | §5.4 | "Chief" is a generic starter bot | Ours only |
| **Team wiki** (Karpathy-style) that bots query and ingest into | §11.4, D-038 | Memory documents with revisions; not a wiki | Ours richer |
| **Wearable**: one button, LED, haptics, duplex habitat, tap and double-tap answers, no speaker | §9, `crates/device` | none | Ours only |
| **Ambient capture** with commitments, follow-ups, appointments; consent light; no audio stored | §10 | Text-only "ambient" mode in team chats | Ours only |
| **ADHD-first profiles**: Focus digests, auto-filing with Undo, resurfacing dismissed commitments once, appointment nudges, "still open" never "overdue" | §10.5 | 4 h reminders and 24 h cancel for waiting runs | Ours only |
| **Omarchy bar panel** with animated faces, approvals and a message box; `SUPER+ALT+B` | `omarchy/kelvincushman.orphusbot` | No tray or menu-bar item | Ours only |
| **CLI** (`link`, `status`, `watch --notify`, `answer`, `send`) | `crates/cli` | none | Ours only |
| **Placement across Kelvin's machines** with battery threshold and quiet hours | §6.3, `crates/server/src/placement.rs` | One trusted host from the desktop app | Ours only |
| **Subscription tokens never leave a node**, never enter a computer or E2B | §8, §14 | Credentials encrypted in Postgres and used by the worker | Ours stricter |
| **Google via `gws` with per-bot none / read / write**, writes always ask, file-sending flags refused | §11.5, `crates/server/src/google.rs` | Composio Gmail, Calendar, Drive per user or space | Ours finer-grained |
| **Animated faces that show state** (idle, thinking, working, needs you, done) | §12 Bot faces | Blinking avatar eyes and an organic idle loop | Ours more informative |
| **Usage with cost per model and per bot, daily budget warning on the wrist** | M4.2 | "N runs · N tokens" | Ours richer |
| **Effect ledger "may already have run" card** shown to the owner | §3.4 | Told only to the model | Ours clearer |
| **Routine daily cap and System 1 pre-flight** | §18.1 Routines | none | Ours only |
| **Passkeys and device linking**, no passwords | §18.1 Sign-in | Email and password, OIDC | Ours simpler and safer |
| **LAN and NetBird ranges blocked inside every computer, always** | §4.4 | Opt-in restricted egress with a host script | Ours stricter |

---

## 5. Prioritised backlog

Sized S (a day or less), M (a few days), L (a week or more). "Why Kelvin" ties each item to how he works: ADHD (lose the thread when switching; need gentle, low-friction capture and re-entry), fatigue (fewer taps, less reading, sensible defaults), and his three devices (Omarchy laptop, Android phone, one-button wearable).

### P0: makes the app usable every day on all three devices

| # | Item | Why Kelvin | Size | Where |
|---|---|---|---|---|
| 1 | **Phone layout for the Flutter app.** Below about 700 dp: bot list as the home screen, chat pushed on top with a back button, settings as a stack; at 700 dp and wider, keep the split with a draggable divider. Also fix the release builds' network permissions (Android INTERNET, macOS network client) | The phone is where nudges land; today the app is a cramped desktop window on it | M | `apps/orphusbot_app/lib/chat.dart`, `main.dart`, `android/app/src/main/AndroidManifest.xml`, `macos/Runner/*.entitlements` |
| 2 | **"Needs you" inbox screen.** One list across bots of open approvals, questions, takeovers and capture proposals, oldest first, each answerable in place | One place to clear everything when he has energy, instead of hunting through bots | M | Flutter `lib/inbox.dart` (new); reducer already has cards (`thread.dart`); DESIGN §12 Views |
| 3 | **Tickets, Routines and the screen in the Flutter app.** Port the Leptos sheets; add a noVNC view (WebView) with Take control, and "Open screen" and "I can't" on the takeover card | The app is the main client but half the product is web-only | L | `apps/orphusbot_app/lib/`; reference `crates/ui/src/app.rs` |
| 4 | **Offline outbox and a saved last state.** Queue messages and card answers while offline; show the last known threads instantly on start instead of replaying from 0 | Phone on a train; a thought sent should never be lost | M | Flutter (SQLite or a JSON file in the support folder); `api.dart` resume from last id; PRD B-CLI-05 |
| 5 | **Voice notes and dictation in the composer.** Hold to talk with slide-up lock; transcribe on the GPU box (qwen3-asr, §16) or on the phone; text lands in the draft for a glance before sending | Speaking is far cheaper than typing when tired; matches the wearable's voice path | M | Flutter composer; server `POST /api/transcribe` reusing the STT path (§9.5) |
| 6 | **Drafts that survive switching bots, and keep scroll position.** Per-bot draft; "jump to latest" button instead of forced scrolling | ADHD: a half-written thought must survive a context switch | S | `lib/chat.dart` |

### P1: closes the obvious UX gaps

| # | Item | Why Kelvin | Size | Where |
|---|---|---|---|---|
| 7 | **Search** across messages, tickets and shared files, with jump-to-message | "What did the researcher say about batteries last week?" without scrolling | M | Postgres full-text on `event`/`ticket`; `GET /api/search`; Flutter search sheet |
| 8 | **Unread state and last-activity time** on bot rows; mark unread | Know what changed since he last looked, without reading everything | S | Server: last-read per bot; `thread.dart`; sidebar row |
| 9 | **Change-watch routines.** Fingerprint a file, a command's output or a read-only MCP or `gws` call every N minutes without a model; fire only on change; then System 1 pre-flight as today | Cheaper and certain; protects subscriptions; fewer pointless pings | M | `crates/server/src/routines.rs`; node runs the check in the bot's computer |
| 10 | **"Stay quiet if nothing new"** for routine runs that fire (a reply token that posts nothing), plus a routine notify switch | Calm by default; no "nothing to report" noise | S | `routines.rs`, bot instructions, `notify.rs` |
| 11 | **Secret and login cards.** A bot asks for a key or a website login in a masked card bound to one origin; the value is stored encrypted and used without the model seeing it (command variable or filled into the page) | Today a login means a takeover every time; and keys typed in chat end up in transcripts | L | Bridge tool `request_secret`; `crates/server/src/secrets.rs`; computer-side fill helper in `images/desktop`; card in Flutter and Leptos |
| 12 | **Readable approval cards.** Summarise the action in one line ("Send email to … about …"), show the System 1 answer and confidence (PRD B-CLI-04), keep raw input behind a fold | Less reading per tap; safer decisions when tired | S | Flutter `chat.dart` card; server builds a summary per tool class in `gate.rs` |
| 13 | **Rules screen.** List, add and remove "always allow" and "always ask" rules, with presets such as "always ask before sending mail" | See and undo past "Always allow" taps | S | Settings section; `approval_rule` API |
| 14 | **Bots schedule things themselves** ("remind me Thursday", "check again in an hour"), via a bridge tool that creates a one-off or cron routine, asked once | Turns a spoken or typed "later" into something that actually happens; pairs with the wearable | M | Bridge tool; `routines.rs` |
| 15 | **Per-bot notification switch and a phone notification settings page** (needs you, finished, routines) | Fewer interruptions from bots he doesn't need to hear from | S | `bot` column; `notify.rs`; Flutter settings |
| 16 | **Reminder for a card left open** (a gentle nudge after a few hours, then a digest line, never auto-cancel without saying so) | ADHD: things wait silently otherwise; matches the Focus profile's "still open" wording | S | Reconciler in `runs.rs`; `profiles.rs` digest |
| 17 | **Tool activity fold.** Off by default; a one-line "Working · 5 steps" that expands; folds to "Done · 5 steps · 2 min" | Trust without noise; see what a bot is doing before deciding to stop it | M | Events already carry tool calls; Flutter widget; DESIGN §12 |
| 18 | **Visual tokens.** A small neutral-first token set (layers, one accent, status colours, radius and type scales, compact density) as a Flutter `ThemeExtension` and CSS variables; app icon and name ("OrphusBot") on Android | The app looks like a prototype; calm, dense design is PRD principle 7 | M | `lib/main.dart` theme, `crates/ui/style.css`, Android `strings.xml` and launcher icons |
| 19 | **Command palette and keyboard path** (Ctrl+K switch bot, Esc to stop, Alt+↑/↓ between bots) | He lives on an Omarchy keyboard; fewer mouse trips | S | Flutter `Shortcuts`/`Actions`; PRD B-CLI-07 |

### P2: depth and polish

| # | Item | Why Kelvin | Size | Where |
|---|---|---|---|---|
| 20 | **Reactions with meaning.** 👍 on a pending yes/no answers it; 👍 on a takeover means done; other reactions are labels for System 1 | One tap instead of typing; maps onto the wrist's tap grammar | S | Server intake; reducer; Flutter long-press menu |
| 21 | **Reply and quote** a message into the composer | Precise follow-ups without retyping context | S | Flutter composer; message reference in `proto` |
| 22 | **Bots propose changes to their own instructions** (diff card, Apply / Edit / Dismiss, Undo, instruction history with restore) | Bots learn his preferences without him writing prompts; always his tap | M | Bridge tool; `bot_instructions` history table; card |
| 23 | **Wiki and memory browser.** Read the team wiki in the app (index, articles, log); delete or edit an article | See what the bots "know"; fix wrong facts | M | Server reads `/shared/wiki` through the node; Flutter viewer |
| 24 | **Artifacts gallery** with previews (images, PDF, Markdown) and versions | Find "that report" days later | M | `GET /api/artifacts` list; Flutter page; preview never runs HTML in our origin (§11.1) |
| 25 | **Mermaid and better tables** (sort, copy, CSV) in replies | Bots already write tables; diagrams help planning | M | Flutter renderer (Mermaid via a WebView or server-side render) |
| 26 | **Short, readable run errors** naming the provider and the limit, with when it resets | Knows at a glance whether to wait or switch model | S | Node maps Orphus errors (§8 quota tracker); notice text |
| 27 | **Backup models** per bot, used when a subscription is rate-limited | Work keeps going when Claude or ChatGPT limits hit | M | §8 quota tracker; bot editor |
| 28 | **Time zone in every run** ("it is 14:05 Wednesday in London") | Bots stop getting "today" and "tomorrow" wrong | S | `bots.rs` instructions; capture profile time zone |
| 29 | **Bot lifecycle**: duplicate, archive, delete (with "keep its wiki notes"), clear conversation (new Orphus session), face and colour picker for new bots | Tidy the team without database edits | M | `bots.rs`; node session reset; Flutter settings |
| 30 | **First-run flow**: a short splash, server address, link, then the Orchestrator greets him with a choice card ("what should I take first?") | Re-installing on a new phone stays easy | S | Flutter `main.dart`; seeded first message |
| 31 | **Teach a task**: record himself doing a job on the bot's screen, get an editable skill, test it, attach it to a routine | Repetitive admin he can show once instead of explaining | L | Recording in `images/desktop`; skill written to the node's Orphus skills; card |
| 32 | **Health endpoint** (`/ready`, checks Postgres and node count) for the bar widget and monitoring | The bar can say "server down" instead of going quiet | S | `crates/server/src/main.rs`; `omarchy/` panel |
| 33 | **Auto-update** for the Flutter desktop and Android builds, and release binaries for server and node | Less maintenance when tired | M | §16 releases; an in-app "update available" button |
| 34 | **Desktop notifications from the Flutter app itself** (not only via the CLI) | Works on the Mac and when the bar plugin isn't running | S | Flutter local notifications |
| 35 | **Group chat** (a few bots in one free-form thread with handoff), distinct from Discussions | Casual multi-bot work without the ceremony of rounds and a verdict | L | New thread kind; `team.rs` handoff |

### Deliberately not on the backlog

| Rakazo feature | Reason |
|---|---|
| Read-aloud, voice calls | The wearable has no speaker by design (AGENTS.md rule 6) and PRD §3 rules calls out; revisit only if Kelvin asks |
| Spaces, members, invitations, billing, sign-up policy, OIDC | One owner (PRD §3) |
| Slack, Telegram, WhatsApp, iMessage and the team-chat judge | Non-goal for v1 |
| Composio and Pipedream catalogues, OpenAPI and GraphQL tool sources | Plain MCP plus `gws` covers his needs (PRD Q7); revisit if a needed app has no MCP server |
| Cursor cloud agents, agent connections to other people's bots | Fleets cover the first; single owner rules out the second |
| Daytona, CreateOS, Boat, Railway providers | Own machines plus E2B (D-004) |
| Image and video generation | No stated need; easy to add later as an MCP server |
| UI translations | English only for now |

---

## 6. Sources

- Rakazo at `38b8e713`, read only: `apps/web`, `apps/mobile`, `apps/desktop`, `apps/www`, `apps/api`, `packages/*`, `infra/`, `docs/`, `VISION.md`, `README.md`, `AGENTS.md`, `CHANGELOG.md`, and `git log 7d5e64c..38b8e713`.
- OrphusBot: [DESIGN.md](../DESIGN.md), [PRD.md](../PRD.md), [DECISIONS.md](../DECISIONS.md), [CHANGELOG.md](../../CHANGELOG.md), [rakazo-architecture.md](rakazo-architecture.md), and the code under `apps/orphusbot_app`, `crates/ui`, `crates/cli`, `crates/server`, `omarchy/`.

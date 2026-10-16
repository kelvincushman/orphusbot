<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

<!-- Converted from .docx via textutil. Source .docx in docs/plans/. -->




Wearable
Mobile App — Design System & Screen Specification
v1.0  |  April 2026  |  Kelvin Lee



This document specifies the complete design language for the Wearable Flutter application — a full rebrand and feature expansion of the upstream KelvinLee open-source app. It covers design tokens, navigation architecture, every screen layout, component library, and agent-routing UX patterns.

## 1. Overview
Wearable is a wearable-connected personal AI assistant. The Flutter app pairs with the KelvinLee-hardware BLE device (audio capture only), routes voice to the Wearable server, and surfaces responses from five specialised AI agents. The app redesign retires the original KelvinLee visual identity and adopts the Wearable design language — emerald-on-dark, Montserrat, and an agent-aware navigation structure.

Key design principles
	•	Audio-first: the hardware device captures audio only. The app is the control plane, not a second microphone.
	•	Agent-aware: every response is attributed to one of five roles. The UI surfaces the routing and makes re-routing trivial.
	•	Emerald identity: replaces KelvinLee purple (#7C3AED) with Wearable emerald (#10B981) across every interactive element.
	•	Dashboard parity: design tokens are extracted verbatim from the Wearable dashboard (wearable_theme.dart) so web and mobile share a single visual vocabulary.
	•	Minimal chrome: pure black (#0A0A0A) scaffold, dark cards (#141414), 1 px #333333 borders. No gradients unless intentional.

Scope of this document
	•	Design token reference (colours, type scale, spacing, radius, shadows)
	•	Navigation architecture (bottom bar + FAB, all tabs)
	•	Screen-by-screen layout specifications for all 9 screens
	•	Four new sections not present in the upstream KelvinLee app
	•	Component library (cards, chips, FAB, agent avatars, status indicators)
	•	Voice routing UX and @role: prefix patterns

## 2. Design Tokens
All tokens below are authoritative and already encoded in wearable_theme.dart. When the dashboard CSS shifts, update that file first; the Flutter theme inherits directly from the same hex values.

### 2.1 Colour Palette

Token
Hex
Usage

background
#0A0A0A
Scaffold / page background

card
#141414
Default card and bottom-sheet surface

cardAlt
#1F1F1F
Elevated card, chip background

muted
#1F1F1F
Chip, tag, secondary surface (alias of cardAlt)

border
#333333
1 px hairline borders on all cards

foreground
#FAFAFA
Primary text on dark backgrounds

mutedFg
#A0A0A0
Secondary text, timestamps, labels

primary
#10B981
Wearable emerald — interactive, brand, active states

primaryGlow
#14C491
Emerald glow (box-shadow on active FAB)

onPrimary
#FAFAFA
Text/icon on primary-filled elements

secondary
#334840
Lower-emphasis containers, secondary buttons

destructive
#EF4444
Delete, error, destructive actions

warning
#F59E0B
Warnings, habitat alerts, overdue tasks

info
#3B82F6
Informational badges, link blue

### 2.2 Typography
Font family: Montserrat (add google_fonts to pubspec.yaml for Phase 3). Until then the bundled Montserrat asset is used. Fallback: Arial > sans-serif.

Style
Size
Weight
Usage
displayLarge
30 sp
700
Onboarding hero text
displayMedium
26 sp
700
Splash / pairing headlines
headlineLarge
24 sp
600
Screen titles in app bar
headlineMedium
22 sp
600
Section headings within screens
titleLarge
20 sp
600
Card titles, agent names
titleMedium
18 sp
500
List item primary text
bodyLarge
16 sp
400
Conversation transcript body
bodyMedium
14 sp
400
Memory cards, settings descriptions
bodySmall
12 sp
400 / mutedFg
Timestamps, metadata
labelLarge
14 sp
500
Button labels, tab labels
labelSmall
10 sp
500 / 0.8 ls
Section caps (OVERDUE, MEMORY, etc.)

### 2.3 Spacing & Radius
Token
Value
Usage
radiusSm
6 dp
Tags, chips, small badges
radiusMd
8 dp
Text inputs, outlined buttons, search bar
radiusLg
12 dp
Cards, primary buttons, bottom sheets
paddingScreen
20 dp
Horizontal inset from screen edges
paddingCard
16 dp
Internal card padding
gapSm
8 dp
Gap between icon and label, stacked chips
gapMd
12 dp
Gap between list items (compact)
gapLg
20 dp
Gap between cards / sections

### 2.4 Shadows & Glow
Token
Value
Usage
shadowCard
0 10 30 rgba(0,0,0,0.5)
Elevation for all cards
shadowGlow
0 0 40 rgba(20,196,145,0.3)
Active microphone FAB, device connected state
shadowBtn
0 4 20 rgba(16,185,129,0.4)
Primary CTA buttons

## 3. Navigation Architecture
The bottom navigation bar retains KelvinLee's five-element structure (4 tabs + central FAB) but every label, icon, and colour is updated for the Wearable brand. Two tabs are entirely new (Agent Hub replacing the upstream Plugins tab, and Hive Mind as an additional accessible drawer route).

### 3.1 Bottom Navigation Bar
Tab
Icon
Route
Description
Home
home_outlined
/home
Conversations list — all captured sessions, date-grouped
Tasks
checklist_outlined
/tasks
Agent-generated tasks and user-captured to-dos
[FAB]
mic (emerald)
— (modal)
Central microphone action — starts voice session or routes to agent
Memory
memory_outlined
/memory
Atomic facts extracted by the curator from all conversations
Agents
smart_toy_outlined
/agents
Agent Hub — five-role roster with dispatch and status


FAB behaviour
Tap: open voice-routing bottom sheet (choose agent or auto-route). Long-press: start recording immediately, routing to main (Chief of Staff). A glowing emerald ring pulses while recording. Double-tap: replay last response.

### 3.2 Drawer / Secondary Navigation
Swipe right from the Home tab or tap the hamburger icon to open the side drawer. Contains:
	•	Hive Mind — live cross-agent activity feed
	•	Device Status — wearable BLE and audio capture state
	•	Dashboard — embedded WebView to wearable-server.local:3141
	•	Settings
	•	Kelvin (profile avatar + plan badge)

### 3.3 Back / Navigation Stack
	•	All tabs maintain independent navigation stacks.
	•	Detail screens (conversation transcript, memory detail, task detail) push onto the relevant tab's stack.
	•	The FAB sheet is always a modal bottom sheet — it does not affect stack depth.
	•	The drawer routes (Hive Mind, Device Status, Dashboard) push modally over whichever tab is active.

## 4. Screen Specifications
Each screen spec describes: app-bar content, primary layout zones, interactive elements, and key differences from the upstream KelvinLee equivalent (if any).

### 4.1 Home — Conversations

KelvinLee equivalent
"Conversations" tab. Core function is unchanged; branding and agent attribution are new.

App bar
	•	Left: Wearable wordmark (Montserrat 600, emerald) + device status dot (green = connected, amber = syncing, grey = disconnected).
	•	Right: search icon, history icon (conversation replay), settings gear.

Filter chips (horizontal scroll)
Chip
Behaviour
All
Default — shows every session
Starred
Pinned / starred sessions only
Work
Sessions tagged work by agents
Personal
Sessions tagged personal
+ (add chip)
Create custom filter tag

Conversation list item anatomy
	•	Agent attribution badge — small coloured pill showing which agent processed (e.g. "main", "comms"). Replaces KelvinLee's emoji icon.
	•	Title — AI-generated session title (titleMedium, foreground).
	•	Time + duration — bodySmall, mutedFg (e.g. "10:49 AM · 6m 34s").
	•	Tap → conversation transcript detail screen.

Ask Wearable FAB (contextual)
A secondary floating button labelled "Ask Wearable" appears on scroll-down to open the voice routing sheet without needing to reach the bottom bar FAB. Same emerald colour, 80% opacity when idle.

### 4.2 Tasks

KelvinLee equivalent
Tasks tab. Retains to-do structure; adds agent attribution and source-conversation links.

Sections
	•	Today — tasks due today, grouped at top.
	•	Upcoming — tasks with a future due date.
	•	No Deadline — undated tasks.
	•	Overdue — collapsed by default, count badge in amber.

Task item anatomy
	•	Checkbox (round, primary emerald when checked).
	•	Task text (titleMedium when incomplete, bodyMedium + strikethrough when done).
	•	Source tag — tappable pill showing which agent created the task (e.g. "ops", "main") and links back to the originating conversation.
	•	Due date — right-aligned, amber if overdue.

Top actions
	•	Export icon — export tasks to JSON.
	•	Filter icon — filter by agent source.
	•	+ FAB — add a task manually or via voice.

### 4.3 Memory

KelvinLee equivalent
"Memory" tab. Identical function; updated search bar and card styling.

Search bar
Full-width search input with emerald focus ring (radiusMd, card fill). Left icon: memory_outlined in primary. Right icons: Wearable AI brain icon (tap to summarise memories), filter sliders.

Memory card
	•	Dark card (#141414) with 1 px #333333 border and 12 dp radius.
	•	Atomic fact text — bodyMedium, foreground.
	•	Right trailing icon: speech bubble (tap to ask Wearable about this memory).
	•	Long-press: shows contextual menu — Delete, Pin, Ask Wearable, Tag.

Grouped display
	•	Default: flat list (most recent first).
	•	Grouped: tap brain icon → grouped by topic cluster (AI-generated clusters).

### 4.4 Agent Hub (New Screen)

Why new
Wearable routes every prompt to one of five AI roles. This screen is the control plane for understanding, configuring, and directly addressing each agent.

Agent roster cards
Five agent cards displayed in a 1-column list. Each card:
	•	Header stripe — unique dark-tinted colour per agent (see table below).
	•	Role badge — pill label (e.g. "@main"), tap to start a new session routed to this agent.
	•	Title — human-readable title (e.g. "Chief of Staff").
	•	Capability chips — 3–4 chips showing tools/permissions (e.g. "Read", "Dispatch", "Memory").
	•	Last active — timestamp of last task attributed to this role.
	•	Quick dispatch button — secondary outlined button labelled "Ask @[role]".

Role
Description
App Permissions
 main
Chief of Staff
Orchestrates all other agents. Routes prompts, manages memory context, handles cross-agent coordination.
Read, Grep, Glob, Dispatch
 comms
Communications
Drafts and edits outward-facing text: emails, messages, summaries. Writes to artifacts/.
Read, Write (artifacts/), Edit
 content
Content Creator
Creates long-form content, social posts, scripts, and research-backed writing. Web-fetch enabled.
Read, Write, WebFetch (allowlist)
 ops
Operations (COO)
Runs operational tasks with Bash access. Handles scheduling, automation, and LAN-scoped actions.
Bash (safety-gated), LAN network
 research
Research Analyst
Deep research with web access. Synthesises sources into structured briefs and reports.
Read, WebFetch (allowlist)

Voice routing UI
When the FAB is tapped, a bottom sheet appears with:
	•	Auto-route chip (default, selected) — Wearable's main agent decides routing.
	•	One chip per agent — tap to pre-select routing before speaking.
	•	Keyboard shortcut note: type @role: prefix in the text field to override routing without opening the sheet.

### 4.5 Hive Mind Feed (New Screen)

Why new
The hive_mind SQLite table logs the last 8 cross-agent activity entries injected into every prompt context. Surfacing this gives Kelvin visibility into what each agent has recently done.

Layout
	•	App bar: "Hive Mind" title + refresh icon.
	•	Timeline list — newest at top. Each entry is a card.

Hive Mind entry card
	•	Left: vertical timeline bar in agent colour.
	•	Agent pill — role badge (e.g. "ops") in agent accent colour.
	•	Action summary — one-line description of what was done (e.g. "Scheduled daily digest at 10 PM").
	•	Task ID — monospace small text linking to the full task in store/tasks/<ulid>.
	•	Timestamp — relative (e.g. "3 hours ago").
	•	Tap → expand to show full RESPONSE.md excerpt and originating conversation.

Filters
	•	Top chip row: All / @main / @comms / @content / @ops / @research.
	•	Long-press a chip to pin that agent's activity as a persistent widget on the Home screen.

### 4.6 Device / Wearable Status (New Screen)

Why new
The Wearable hardware is audio-only. This screen is the single source of truth for device health, sync queue, and habitat-alert configuration.

Connection hero
	•	Large animated status orb (emerald glow when connected, pulsing amber when syncing, grey when disconnected).
	•	Device name (e.g. "Wearable #1") in headlineMedium.
	•	BLE signal strength bars.
	•	Connect / Scan button if not paired.

Audio capture state
	•	Recording indicator — pulsing waveform when device mic is active.
	•	Conversation timeout setting — "Auto-end after N minutes of silence."
	•	Store on phone toggle.
	•	Store on cloud toggle.

Sync queue
	•	Pending count badge (amber if > 0).
	•	List of pending segments: timestamp + duration + status (Pending / Syncing / Done).
	•	Swipe-to-discard individual segments.

Habitat alerts
	•	Enable / disable toggle.
	•	Alert type selector: LED only / Haptic only / Both.
	•	Test button — sends a test LED + haptic command to the device immediately.
	•	Alert history — last 5 habitat alerts with timestamp and type.

### 4.7 Dashboard (Embedded WebView, New Screen)

Why new
The Wearable dashboard at wearable-server.local:3141 provides full operational visibility. Rather than forcing Kelvin to switch apps, the mobile app embeds it as a first-class screen.

Layout
	•	App bar: "Dashboard" title + open-in-browser icon (launches Safari/Chrome).
	•	Full-screen WebView via flutter_inappwebview or webview_flutter.
	•	Bottom safe-area padding preserved so the bottom nav bar remains accessible.

Auth handling
	•	The WebView shares the bearer token stored in FlutterSecureStorage. On load, the WebView injects the Authorization header so the dashboard authenticates without a second login.
	•	If the server is unreachable (not on LAN), show an offline card: "Dashboard unavailable — connect to the Wearable network."

### 4.8 Settings

KelvinLee equivalent
Settings screen. Groups are restructured; KelvinLee-specific items (Referral Program, Get KelvinLee for Mac) are removed.

Section groups
Group
Items
Account
Profile (Name, Email, Language, Custom Vocabulary), Plan & Usage
Voice & Audio
Speech Profile, Identifying Others, Conversation Display, Conversation Timeout
Notifications
Frequency, Daily Summary, Daily Reflection
Privacy & Data
Data Privacy, Offline Sync, Export All Data
Integrations
Google Calendar, Apple Health, Custom Webhooks
Wearable Advanced
AI Persona (main agent), Transcription Provider, Safety Rules viewer (read-only), Developer Settings
Support
Help Center, Feedback / Bug, What's New

Wearable Advanced replaces the upstream "Developer Settings" with a Wearable-specific section. The Safety Rules viewer shows config/safety.rules in a read-only code view — not editable from mobile.

## 5. Component Library
Components below are reusable across multiple screens. All measurements in dp (Flutter logical pixels).

### 5.1 Agent Badge
	•	Pill-shaped chip, 4 dp horizontal padding, 2 dp vertical, radiusSm (6 dp) border radius.
	•	Background: agent accent colour at 20% opacity. Text: agent accent colour, labelSmall (10 sp, 500 weight).
	•	Agents: main (#10B981), comms (#3B82F6), content (#8B5CF6), ops (#F59E0B), research (#06B6D4).
	•	Usage: conversation list items, hive mind cards, task source tags, memory attributions.

### 5.2 Wearable FAB (Microphone)
	•	56 dp circle, primary fill (#10B981).
	•	mic icon, 28 dp, onPrimary (#FAFAFA).
	•	Active state: glowing emerald ring (shadowGlow) + pulse animation (scale 1.0 → 1.08, 800 ms ease-in-out loop).
	•	Long-press: fills to 64 dp, shows waveform animation.
	•	Bottom nav bar elevation: FAB sits 8 dp above bar surface.

### 5.3 Conversation Card
	•	card fill, 12 dp radius, 1 px border (#333333).
	•	Leading: agent badge (40 × 40 dp rounded square).
	•	Title: titleMedium, foreground.
	•	Subtitle: bodySmall, mutedFg — "time · duration".
	•	Trailing: chevron_right, mutedFg.

### 5.4 Memory Card
	•	card fill, 12 dp radius, 1 px border.
	•	Body text: bodyMedium.
	•	Trailing: chat_bubble_outline, 20 dp, mutedFg.
	•	Long-press activates context menu with Delete / Pin / Ask Wearable / Tag.

### 5.5 Device Status Dot
	•	8 dp filled circle positioned top-right of the Wearable wordmark in the app bar.
	•	Green (#10B981): BLE connected, audio capture active.
	•	Amber (#F59E0B): BLE connected, sync pending.
	•	Grey (#A0A0A0): disconnected.
	•	Red (#EF4444): error (device battery critical or firmware mismatch).

### 5.6 Voice Routing Bottom Sheet
	•	Height: 60% of screen height, drag handle at top.
	•	Title: "Ask Wearable" in headlineMedium.
	•	Subtitle: "Where should this go?" in bodyMedium, mutedFg.
	•	Agent chips: horizontal scroll row. Each chip shows agent icon + "@role" label. Selected chip: primary fill, onPrimary text. Unselected: cardAlt fill, mutedFg text.
	•	Auto chip always first (default selected).
	•	Large microphone button at bottom: 72 dp, primary, tap to start recording.

### 5.7 Hive Mind Timeline Entry
	•	Left: 2 dp vertical line in agent accent colour.
	•	4 dp left gap, then card.
	•	Agent badge + action title + task ID chip + timestamp.
	•	Tap to expand: full response excerpt in a collapsible region with a scrollable text area.

### 5.8 Habitat Alert Banner
	•	Full-width banner below app bar.
	•	Warning fill (#F59E0B at 15% opacity), warning border.
	•	Icon: local_fire_department, warning colour.
	•	Text: alert message + dismiss button.
	•	Auto-dismisses after 8 seconds unless tapped.

## 6. Voice & Agent Routing UX
Because Wearable routes every prompt to a specific agent role, the UX must make routing legible at every step — before sending, during processing, and on receiving the response.

### 6.1 Pre-send routing
	•	FAB tap → Voice Routing Sheet (section 5.6). User selects agent or leaves on Auto.
	•	Text chat entry → typing @role: at the start of the message pre-selects the chip in the sheet (or sends directly if no sheet is open).
	•	Quick-select: from Agent Hub, tapping "Ask @[role]" opens the FAB sheet with that agent pre-selected.

### 6.2 In-flight state
	•	Active agent badge pulses on the app bar while a response is pending.
	•	The FAB shows a loading spinner in place of the mic icon.
	•	A status chip appears at the top of the Conversations tab: "@ops is working…"

### 6.3 Response attribution
	•	Every conversation list item carries an agent badge.
	•	Inside the transcript, each assistant message shows a small agent badge before the text bubble.
	•	If routing changed mid-session (e.g. main dispatched to research), the badge updates at the point of handoff.

### 6.4 Re-route
	•	Long-press any assistant message bubble → "Re-route this" option.
	•	Opens the routing sheet pre-populated with the original message.
	•	Sends a new request to the chosen agent; response appended to the same conversation with a new badge.

## 7. Differences from Upstream KelvinLee App
This section documents every deliberate divergence from the KelvinLee open-source Flutter app so developers can track what was changed and why.

Area
KelvinLee (upstream)
Wearable (this spec)
Brand colour
Purple #7C3AED
Emerald #10B981
Font
System default / Roboto
Montserrat 400/500/600/700
Background
#000000 (pure black)
#0A0A0A (near-black)
Card surface
#1C1C1E (iOS grey)
#141414 (slightly lighter)
4th tab
Memory (brain icon)
Memory — unchanged
5th tab
Plugins / marketplace
Agent Hub — no marketplace
Conversation items
Emoji icon from AI
Agent attribution badge
FAB label
"Ask KelvinLee"
"Ask Wearable"
Settings groups
Includes Referral, Get KelvinLee for Mac
Removed; replaced with Wearable Advanced
Integrations
Apple Health, Google Calendar, Gmail
Same + Custom Webhooks
Voice routing
Single AI persona
5-agent routing with @role: prefix
New: Hive Mind
Not present
Cross-agent activity feed (drawer)
New: Device Status
Embedded in Settings only
Dedicated drawer screen
New: Dashboard
Not present
Embedded WebView to Wearable server
Plugins
Full marketplace (1500+)
Removed from nav; KelvinLee plugin manifest still loaded internally for memory plugins

## 8. Flutter Implementation Notes
These notes are intended for the developer implementing this spec in the Wearable Flutter codebase at devices/wearable-kelvinlee/app/lib/wearable/.

### 8.1 Theme wiring
	•	WearableTheme.dark() in wearable_theme.dart already contains all colour and typography tokens.
	•	Wire in main.dart: MaterialApp(theme: WearableTheme.dark(), home: ...).
	•	For Montserrat: add google_fonts: ^6.x to pubspec.yaml and replace fontFamily: 'Montserrat' in WearableTheme with GoogleFonts.montserratTextTheme(base).

### 8.2 Navigation scaffold
	•	Implement a WearableScaffold widget wrapping the bottom NavigationBar + Drawer + FAB.
	•	Use IndexedStack (not Navigator.push) for tab bodies to preserve scroll position.
	•	The central FAB is a custom widget (WearableMicFab) placed via FloatingActionButton.location = FloatingActionButtonLocation.centerDocked.

### 8.3 Agent Hub data
	•	Agent metadata (role, title, permissions) is static; define a Dart const list in lib/wearable/agents.dart.
	•	Last active timestamp: query the Wearable server GET /api/agents/status (returns JSON with last_task_at per role).

### 8.4 Hive Mind feed
	•	Poll GET /api/hive-mind?limit=20 on mount and on pull-to-refresh.
	•	Subscribe to SSE /api/hive-mind/stream for real-time updates when the app is foregrounded.

### 8.5 Device Status
	•	Reuse WearableDeviceBridge.current from device_bridge.dart for BLE state.
	•	Offline sync data: poll GET /api/sync/queue from WearableClient.
	•	Habitat alert test: POST /api/habitat/test-alert.

### 8.6 Dashboard WebView
	•	Add flutter_inappwebview: ^6.x to pubspec.yaml.
	•	On load, inject Authorization: Bearer <token> header using InAppWebViewInitialSettings.
	•	Handle HTTP (not HTTPS) local address: add android:usesCleartextTraffic="true" to AndroidManifest.xml for local dev; restrict to LAN subnets.

### 8.7 Phased delivery
Phase
Milestone
Screens in scope
3.1
Theme + nav scaffold
WearableTheme wired, bottom bar, FAB shell, Conversations (rebrand only)
3.2
Core screens
Memory, Tasks, Settings (all rebranded)
3.3
Agent Hub + routing
Agent Hub tab, voice routing sheet, response attribution
3.4
New screens
Hive Mind, Device Status (full), Dashboard WebView


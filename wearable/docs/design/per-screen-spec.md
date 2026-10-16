<!-- Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. -->

<!-- Converted from .docx via textutil. Source .docx in docs/plans/. -->




Wearable
Per-Screen Implementation Specification
What each screen needs added, changed, and wired up for the Wearable agent system
v1.0  |  April 2026  |  Kelvin Lee



This document specifies, screen by screen, exactly what must be added to the existing KelvinLee Flutter app to integrate the Wearable agent system. For each screen it covers: the current file and state, every new widget required, every API endpoint to wire up, the provider/state changes, and Dart code sketches ready for implementation.

How to Read This Document
Each screen section is structured identically:
	•	Current file — the Dart file path to edit (relative to devices/wearable-kelvinlee/app/lib/).
	•	Current state — what the screen does today in the upstream KelvinLee app.
	•	What to ADD — every new widget, data source, and behaviour needed for Wearable.
	•	What to CHANGE — existing code that must be modified.
	•	What to REMOVE — KelvinLee-specific elements that do not belong in Wearable.
	•	New files required — new Dart files to create (not edits to existing files).
	•	API integration — Wearable server endpoints this screen consumes.
	•	Provider / state — what provider changes are needed.
	•	Code sketch — key new Dart widget or method, pseudocode-accurate.


Green callouts = new Wearable additions
These are things that do not exist at all in the KelvinLee codebase and must be built from scratch.


Amber callouts = KelvinLee elements to modify
These are things that already exist but need to be adapted for the Wearable system.

## Screen 1: App Shell & Bottom Navigation

Current file
pages/home/page.dart       — HomePageWrapper (main nav shell)
core/app_shell.dart        — AppShell (deep links + providers)
wearable/pages/wearable_home_page.dart — minimal stub (Phase 2 work)

Current state
HomePageWrapper renders an IndexedStack with tabs: Conversations, Action Items, a central capture FAB, Memories, and Chat/Apps. The FAB opens the conversation-capturing page. The AppShell bootstraps providers and deep links.

What to ADD


New: Agent Status Dot in AppBar
A live 8 dp dot next to the "Wearable" wordmark showing BLE + server connection state.
Green = device connected + server reachable. Amber = syncing. Grey = disconnected. Red = error.
Widget: WearableStatusDot — listens to WearableConnectionProvider (new).


New: Agent Hub tab replaces Apps/Chat tab
Replace the 5th tab (Chat/Apps, icon: extension) with Agent Hub (icon: smart_toy_outlined).
Tab label: "Agents". Routes to wearable/pages/agent_hub_page.dart (new file).


New: Side Drawer with Wearable sections
Add a Drawer to the Scaffold wrapping the bottom nav shell.
Drawer items: Hive Mind, Device Status, Dashboard, Settings, Profile.
Drawer header: Kelvin's name + email + Wearable logo.


New: Wearable FAB behaviour
Tap: open WearableRoutingSheet (bottom sheet — see Screen 9).
Long-press: start recording immediately routed to @main.
Double-tap: replay last Wearable response via TTS.
Active state: glowing emerald ring + waveform animation.


New: In-flight agent banner
When a Wearable request is pending, a slim banner appears below the AppBar: "@ops is working…"
Widget: WearableInFlightBanner — listens to WearableTaskProvider (new).
Auto-hides when task completes.

What to CHANGE

Modify: theme
Wrap MaterialApp with theme: WearableTheme.dark(). All KelvinLee purple (#7C3AED) becomes emerald (#10B981) automatically.

Modify: tab order and labels
Tab 4: keep Memory (brain icon). Tab 5: Agents (smart_toy_outlined). Remove Chat tab from bottom bar — Chat moves inside Agent Hub.

What to REMOVE
	•	"Ask KelvinLee" floating action label — replace with "Ask Wearable".
	•	Chat tab from bottom nav bar (it becomes part of Agent Hub).
	•	apps/page.dart tab entry — Agent Hub replaces it.

New files required
File
Purpose
wearable/providers/wearable_connection_provider.dart
BLE + server health state. Exposes connectionStatus enum.
wearable/providers/wearable_task_provider.dart
Tracks in-flight Wearable tasks. Exposes activeTasks list.
wearable/widgets/wearable_status_dot.dart
The 8 dp coloured status dot widget.
wearable/widgets/wearable_in_flight_banner.dart
Slim banner showing active agent name.
wearable/widgets/wearable_routing_sheet.dart
Bottom sheet for agent pre-selection before recording.
wearable/widgets/wearable_drawer.dart
Side drawer with Hive Mind / Device / Dashboard links.

API integration
Endpoint
When called
Purpose
GET /api/health
On mount + every 30 s
Server reachability check for status dot
GET /api/agents/status
On mount + poll 60 s
Last-active timestamp per role
GET /api/tasks/active
Poll 5 s when task in flight
In-flight task progress

Code sketch — WearableStatusDot
// wearable/widgets/wearable_status_dot.dart
class WearableStatusDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final status = context.watch<WearableConnectionProvider>().status;
    final color = switch (status) {
      WearableStatus.connected => WearableColors.primary,
      WearableStatus.syncing   => WearableColors.warning,
      WearableStatus.error     => WearableColors.destructive,
      _                    => WearableColors.mutedFg,
    };
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 8, height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color,
        boxShadow: status == WearableStatus.connected ? [WearableShadows.glow] : null),
    );
  }
}

## Screen 2: Conversations (Home Tab)

Current file
pages/conversations/conversations_page.dart
pages/conversations/widgets/conversation_list_item.dart
pages/conversations/widgets/conversations_group_widget.dart

Current state
Conversations tab shows date-grouped sessions. Each ConversationListItem has an emoji icon (from the AI-generated title emoji), the AI title, and a timestamp/duration. The ServerConversation schema comes from backend/schema/conversation.dart.

What to ADD

New: Agent attribution badge on every list item
Each ConversationListItem gets a WearableAgentBadge widget showing which role processed the session.
Source: conversation.wearableRole field (add to ServerConversation schema — see API section).
Badge sits to the right of the emoji icon, before the title text.
If wearableRole is null (old conversations), badge is hidden.


New: "Ask Wearable" contextual FAB
A secondary FAB labelled "Ask Wearable" appears when the user scrolls down > 200 px.
Tap opens WearableRoutingSheet (same as main FAB).
Positioned above the bottom nav bar, 80 % opacity when idle.


New: Filter chip — by agent
Add filter chips after the existing All / Starred / Work / Personal chips.
Agent chips: @main / @comms / @content / @ops / @research.
Selecting an agent chip filters the list to conversations processed by that role.


New: In-progress capture card at top
When a Wearable session is being captured (device connected + recording), show a live card at the top of the list.
Card shows waveform animation + "Wearable is listening…" + elapsed time.
Tap to open the capture detail view.

What to CHANGE

Modify: ConversationListItem leading icon
Replace the emoji-in-circle icon with WearableAgentBadge (40 × 40 dp rounded square in agent colour). Emoji goes inside the badge as the icon.

Modify: "Ask KelvinLee" button label
Change text from "Ask KelvinLee" to "Ask Wearable" everywhere. Search for "Ask KelvinLee" in conversations_page.dart.

What to REMOVE
	•	"Ask KelvinLee" hardcoded text string — replace with const wearableLabel = "Ask Wearable".

New files required
File
Purpose
wearable/widgets/wearable_agent_badge.dart
Coloured role pill: accepts WearableRole enum, renders chip.
wearable/widgets/wearable_capture_card.dart
Live waveform card shown at top of list during active capture.

API integration
Endpoint / Schema change
Detail
ServerConversation.wearableRole (new field)
String? — one of main/comms/content/ops/research. Add to conversation.dart schema and parse from GET /api/memories response.
GET /api/conversations?role=ops
Wearable server filter param — pass when agent chip is selected.
Wearable server must tag each conversation
When Wearable dispatches and completes a task, PATCH /api/conversations/{id} with {wearableRole: "ops"}.

Code sketch — WearableAgentBadge
// wearable/widgets/wearable_agent_badge.dart
enum WearableRole { main, comms, content, ops, research }
 
class WearableAgentBadge extends StatelessWidget {
  final WearableRole role;
  const WearableAgentBadge({required this.role});
 
  static const _colors = {
    WearableRole.main:     Color(0xFF10B981),
    WearableRole.comms:    Color(0xFF3B82F6),
    WearableRole.content:  Color(0xFF8B5CF6),
    WearableRole.ops:      Color(0xFFF59E0B),
    WearableRole.research: Color(0xFF06B6D4),
  };
 
  @override
  Widget build(BuildContext context) {
    final color = _colors[role]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text('@${role.name}',
        style: TextStyle(color: color, fontSize: 10,
          fontWeight: FontWeight.w600, letterSpacing: 0.4)),
    );
  }
}

## Screen 3: Conversation Detail / Transcript

Current file
pages/conversation_detail/page.dart
pages/conversation_detail/conversation_detail_provider.dart

Current state
Shows the full transcript of a recorded session with speaker-diarised segments, the AI-generated summary, and action items. Uses ConversationDetailProvider to load and hold state.

What to ADD

New: Agent attribution header
Below the session title, show a row: WearableAgentBadge for the role that processed this session + "Processed by @ops" label.
If the conversation was re-routed mid-session, show a timeline of which agent handled which part.

New: Per-message agent badge in transcript
When an assistant message appears in the transcript (AI-generated summary or response), prefix it with a small WearableAgentBadge.
This is visible in the AI Summary section and any inline AI comments.

New: Re-route action on AI message long-press
Long-pressing an AI response bubble shows a context menu: "Re-route to…".
Tapping "Re-route to…" opens WearableRoutingSheet pre-filled with the original prompt.
Sends a fresh request to the chosen agent; new response appended with a new badge.

New: "Ask Wearable about this" button in summary
Below the AI summary section, add an outlined button: "Ask Wearable about this conversation".
Taps open the chat interface pre-seeded with the conversation transcript as context.

What to CHANGE

Modify: action items section title
Change "Action Items" heading to "Tasks" to match Wearable language.

Modify: ActionItemTileWidget source tag
Add a source tag to each action item tile showing which Wearable agent created the task. Read from actionItem.wearableRole (new field).

API integration
Field / Endpoint
Detail
ServerConversation.agentTimeline (new)
List of {role, fromSegment, toSegment} — shows which agent handled which part of the session.
ActionItemWithMetadata.wearableRole (new)
String? — which agent created this task.
POST /api/conversations/{id}/reroute
Body: {targetRole, originalPrompt}. Dispatches a fresh agent task and returns the new response.

Code sketch — Re-route context menu
// In conversation_detail_provider.dart — new method
Future<void> rerouteToAgent(
    String conversationId, String prompt, WearableRole role) async {
  final response = await WearableClient.instance.post(
    '/api/conversations/$conversationId/reroute',
    body: {'targetRole': role.name, 'originalPrompt': prompt},
  );
  // Append new response to transcript
  addAssistantMessage(AgentMessage(role: role, text: response['text']));
}
 
// In page.dart — long-press on AI message bubble
onLongPress: () => showModalBottomSheet(
  context: context,
  builder: (_) => WearableRerouteSheet(
    onSelected: (role) => provider.rerouteToAgent(
        widget.conversation.id, message.text, role),
  ),
),

## Screen 4: Tasks (Action Items Tab)

Current file
pages/action_items/action_items_page.dart
pages/action_items/widgets/action_item_tile_widget.dart
pages/action_items/widgets/action_item_form_sheet.dart
providers/action_items_provider.dart

Current state
ActionItemsPage groups tasks into Today, Overdue, Upcoming, and No Deadline sections. ActionItemTileWidget shows checkbox + task text. ActionItemWithMetadata holds the task + conversation metadata. Tasks are synced with Apple Reminders on iOS.

What to ADD

New: Agent source tag on each tile
Below the task text, show a tappable pill: "Created by @ops · [conversation title]".
Tapping the pill navigates to the originating conversation detail screen.
Tag is hidden if task was manually created (wearableRole is null).

New: Filter by agent chip row
Horizontal chip row at the top: All / @main / @comms / @content / @ops / @research.
Filtering is client-side — filter the existing task list by wearableRole.

New: Wearable task sync badge
A badge in the app bar showing how many tasks were created by Wearable agents today.
e.g. "5 from Wearable" — tapping shows a breakdown per agent.

What to CHANGE

Modify: Section heading "Action Items" → "Tasks"
Rename all "Action Items" display strings to "Tasks". File: action_items_page.dart, all section headers.

Modify: ActionItemWithMetadata schema
Add wearableRole: String? and wearableConversationId: String? fields. These are populated when Wearable creates the task server-side and synced to the app via the existing task refresh endpoint.

What to REMOVE
	•	Export-to-Apple-Reminders button in the action bar — replace with Export icon that exports to JSON (Wearable does not depend on Apple ecosystem).

API integration
Endpoint
Detail
GET /api/action-items (existing)
Add wearableRole and wearableConversationId to response schema on Wearable server side.
PATCH /api/action-items/{id}/complete
Existing endpoint — unchanged.
GET /api/action-items?role=ops
Pass role param for agent filter chips (server-side filter).

Code sketch — Agent source tag
// In action_item_tile_widget.dart — add below existing task text
if (widget.actionItem.wearableRole != null) ...[
  const SizedBox(height: 4),
  GestureDetector(
    onTap: () => Navigator.push(context, MaterialPageRoute(
      builder: (_) => ConversationDetailPage(
          conversationId: widget.actionItem.wearableConversationId!))),
    child: Row(children: [
      WearableAgentBadge(role: WearableRole.values.byName(
          widget.actionItem.wearableRole!)),
      const SizedBox(width: 6),
      Expanded(child: Text(
        widget.actionItem.conversationTitle ?? 'View conversation',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          decoration: TextDecoration.underline),
        overflow: TextOverflow.ellipsis,
      )),
    ]),
  ),
],

## Screen 5: Memory Tab

Current file
pages/memories/page.dart
pages/memories/widgets/ (memory card widgets)
providers/memory_provider.dart (if exists) or conversation_provider.dart

Current state
Memory tab shows atomic facts extracted from conversations. Each card is a text fact with a speech-bubble icon. The tab has a search bar and a brain/AI icon. Facts are stored in the karpathy memory.md system server-side.

What to ADD

New: Memory attribution badge
Each memory card gets a small WearableAgentBadge showing which agent extracted this fact.
For Karpathy memory entries, badge shows "@main" (the curator runs under main role context).
For pinned memories: "📌 Pinned" label replaces the badge.

New: "Ask Wearable about this memory" action
The existing speech-bubble icon on each card already opens a chat. Change its action to open WearableRoutingSheet pre-seeded with the memory text as context.
This routes the query through Wearable's main agent with the memory as part of the prompt.

New: Memory source filter
Add source filter chips below the search bar: All / Karpathy / Pinned / Obsidian.
Karpathy = from memory.md (Karpathy curator). Pinned = pinned_memory table. Obsidian = vault snippets.

New: Memory summary action
Brain icon in the app bar — tapping sends all current memories to @research agent and asks for a structured summary / topic clusters.
Response displayed as a bottom sheet.

What to CHANGE

Modify: Search bar icon
Change search bar left icon from generic search_outlined to memory_outlined (or the existing brain icon). Focus ring: primary emerald.

Modify: Memory card context menu
Long-press menu: add "Ask Wearable" option below the existing Delete / Pin options.

API integration
Endpoint
Detail
GET /api/memories (Wearable server)
Returns karpathy memory entries. Add source field: "karpathy" | "pinned" | "obsidian".
GET /api/memories/pinned
Pinned memories from pinned_memory SQLite table.
POST /api/memories/summarise
Send memory IDs → @research agent returns topic clusters.
DELETE /api/memories/{id}
Delete a specific memory fact.

Code sketch — Memory source enum + card header
// wearable/models/wearable_memory.dart
enum MemorySource { karpathy, pinned, obsidian }
 
class WearableMemory {
  final String id;
  final String fact;
  final MemorySource source;
  final String? wearableRole;   // which agent context produced this
  final DateTime createdAt;
}
 
// In memory card widget — attribution row
Row(children: [
  if (memory.source == MemorySource.pinned)
    const Icon(Icons.push_pin, size: 12, color: WearableColors.warning)
  else
    WearableAgentBadge(role: WearableRole.main),
  const SizedBox(width: 6),
  Text(memory.source.name, style: Theme.of(context).textTheme.labelSmall),
]),

## Screen 6: Agent Hub (New Tab — replaces Apps)

Current file
wearable/pages/agent_hub_page.dart   — CREATE THIS FILE (does not exist)

Current state
Does not exist. The upstream KelvinLee app has an Apps/Plugins marketplace here. In Wearable, the marketplace is removed from the bottom nav and replaced with the Agent Hub.

Entire screen to build from scratch

New screen: Agent Hub
This is a fully new screen. It has no KelvinLee equivalent in the bottom nav.
Entry point: wearable/pages/agent_hub_page.dart.
Provider: wearable/providers/wearable_agent_provider.dart.

Layout structure
	•	App bar: "Agents" title + refresh icon.
	•	Overall status row: "All systems active" or warning if any agent errored.
	•	Five WearableAgentCard widgets in a ListView.
	•	Each card is tappable — opens a full-screen agent chat for that role.

WearableAgentCard widget spec
Zone
Content
Header stripe
48 dp tall strip in agent accent colour (20% opacity). Contains role badge left, title right, and last-active timestamp far right.
Body
Two-line description of what this agent does. bodyMedium, foreground.
Capability chips
Horizontal wrap of 3-4 read-only chips: tool permissions. e.g. "Read", "WebFetch", "Bash (gated)".
Footer
Two buttons side by side: "Ask @[role]" (primary emerald, opens routing sheet pre-selected) and "View history" (outlined, opens conversation list filtered to this role).

Agent data (static constants)
Role
Title
Description
Permissions
main
Chief of Staff
Routes prompts, manages memory, coordinates agents.
Read, Grep, Glob, Dispatch
comms
Communications
Drafts and edits outward-facing text and messages.
Read, Write (artifacts/), Edit
content
Content Creator
Long-form content, scripts, research writing.
Read, Write, WebFetch
ops
Operations COO
Automation, scheduling, Bash tasks on LAN.
Bash (gated), LAN network
research
Research Analyst
Deep web research, structured briefs and reports.
Read, WebFetch (allowlist)

API integration
Endpoint
Detail
GET /api/agents/status
Returns {role, lastTaskAt, taskCount24h, status: active|error} for all 5 roles.
GET /api/conversations?role={role}
Used by "View history" button to filter conversation list.
POST /api/chat (with role param)
Used by "Ask @[role]" — opens chat with target role pre-selected.

Code sketch — AgentHubPage
// wearable/pages/agent_hub_page.dart
class AgentHubPage extends StatefulWidget { ... }
 
class _AgentHubPageState extends State<AgentHubPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) =>
      context.read<WearableAgentProvider>().refresh());
  }
 
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<WearableAgentProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Agents'),
        actions: [IconButton(icon: const Icon(Icons.refresh),
          onPressed: provider.refresh)]),
      body: provider.isLoading
        ? const Center(child: CircularProgressIndicator())
        : ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: WearableAgentMeta.all.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (ctx, i) {
              final meta = WearableAgentMeta.all[i];
              final status = provider.statusFor(meta.role);
              return WearableAgentCard(meta: meta, status: status);
            }),
    );
  }
}

## Screen 7: Hive Mind Feed (New — Drawer Route)

Current file
wearable/pages/hive_mind_page.dart  — CREATE THIS FILE

Current state
Does not exist. The hive_mind SQLite table on the Wearable server stores the last N cross-agent activity entries injected into every prompt context. This screen surfaces them as a live feed.

Entire screen to build from scratch

New screen: Hive Mind
Accessible via side drawer from any tab.
Shows a reverse-chronological feed of cross-agent activity.
Real-time updates via SSE when the app is foregrounded.

Layout structure
	•	App bar: "Hive Mind" + subtitle "Cross-agent activity" + refresh icon.
	•	Filter chips: All / @main / @comms / @content / @ops / @research.
	•	ListView of WearableHiveMindEntry cards.
	•	Pull-to-refresh triggers GET /api/hive-mind.

WearableHiveMindEntry card spec
	•	Left: 2 dp vertical line in agent accent colour (full card height).
	•	12 dp gap. Then card body:
	•	Top row: WearableAgentBadge + task ID chip (monospace, mutedFg) + relative timestamp.
	•	Body: one-line action summary (e.g. "Scheduled daily digest at 10 PM").
	•	Expandable: tap card to expand and show full RESPONSE.md excerpt in a scrollable area.
	•	Expand button: chevron_down icon, rotates to chevron_up when expanded.

API integration
Endpoint
Detail
GET /api/hive-mind?limit=30
Returns list of {id, role, summary, taskId, createdAt, responseExcerpt}.
GET /api/hive-mind?role=ops
Agent-filtered view — used by filter chips.
SSE /api/hive-mind/stream
Server-sent events for real-time updates when app is foregrounded. Use http package with EventSource.

Provider needed
// wearable/providers/wearable_hive_mind_provider.dart
class WearableHiveMindProvider extends ChangeNotifier {
  List<HiveMindEntry> entries = [];
  bool isLoading = false;
  String? roleFilter;
  StreamSubscription? _sseSubscription;
 
  Future<void> refresh() async { ... fetch from /api/hive-mind }
  void setRoleFilter(String? role) { roleFilter = role; refresh(); }
  void startStreaming() { /* SSE subscription */ }
  void stopStreaming() { _sseSubscription?.cancel(); }
}

Code sketch — HiveMindEntry card
// wearable/widgets/wearable_hive_mind_entry.dart
class WearableHiveMindEntry extends StatefulWidget {
  final HiveMindEntry entry;
}
 
class _WearableHiveMindEntryState extends State<WearableHiveMindEntry> {
  bool _expanded = false;
 
  @override
  Widget build(BuildContext context) {
    final role = WearableRole.values.byName(widget.entry.role);
    final accentColor = WearableAgentBadge.colorFor(role);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(width: 2, color: accentColor),
        const SizedBox(width: 12),
        Expanded(child: Card(child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              WearableAgentBadge(role: role),
              const SizedBox(width: 8),
              Text(widget.entry.taskId.substring(0, 8),
                style: const TextStyle(fontFamily: 'Courier New', fontSize: 11, color: WearableColors.mutedFg)),
              const Spacer(),
              Text(timeAgo(widget.entry.createdAt), style: Theme.of(context).textTheme.bodySmall),
            ]),
            const SizedBox(height: 8),
            Text(widget.entry.summary),
            if (_expanded) ...[
              const Divider(height: 16),
              Text(widget.entry.responseExcerpt,
                style: const TextStyle(fontFamily: 'Courier New', fontSize: 11)),
            ],
            Align(alignment: Alignment.centerRight,
              child: IconButton(
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                onPressed: () => setState(() => _expanded = !_expanded))),
          ]),
        ))),
      ]),
    );
  }
}

## Screen 8: Device / Wearable Status (New — Drawer Route)

Current file
wearable/pages/device_status_page.dart  — CREATE THIS FILE
(extends existing wearable/device_bridge.dart + wearable/wearable_client.dart)

Current state
Device pairing is in wearable/pages/pairing_page.dart (Phase 2). A minimal device card is in wearable_home_page.dart. There is no dedicated device status screen yet. This screen replaces the minimal card with a full, dedicated view.

Entire screen to build from scratch

New screen: Device Status
Consolidates all wearable health, audio, sync queue, and habitat alert config into one place.
Entry: side drawer → "Device".
Uses existing WearableDeviceBridge.current and WearableClient.instance.

Section 1 — Connection Hero
	•	AnimatedContainer orb: 80 dp circle. Emerald glow when connected (WearableShadows.glow). Pulsing amber when syncing. Grey when disconnected.
	•	Device name text: headlineMedium.
	•	BLE signal strength: 3 bars icon, colour = signal level.
	•	Battery level: percentage + battery icon. Amber < 20 %.
	•	Buttons: "Disconnect" (if connected) or "Scan for Device" (if not).

Section 2 — Audio Capture
	•	Recording status: waveform animation if active, flat line if idle.
	•	Conversation timeout selector: "Auto-end after N minutes of silence" — stepper or dropdown.
	•	Store on phone toggle: SwitchListTile.
	•	Store on cloud toggle: SwitchListTile.

Section 3 — Sync Queue
	•	Pending count chip: amber badge if > 0.
	•	ListView of sync segments: time + duration + status chip (Pending / Syncing / Done).
	•	Swipe-to-discard: SwipeToDismiss on each pending segment.
	•	Sync now button: forces immediate sync of all pending segments.

Section 4 — Habitat Alerts
	•	Enable toggle.
	•	Alert type selector: LED only / Haptic only / Both (SegmentedButton).
	•	Test button: "Send test alert" → POST /api/habitat/test-alert.
	•	Alert history: last 5 habitat alerts list (timestamp + type).

API integration
Endpoint / Source
Detail
WearableDeviceBridge.current (local)
BLE state, device name, signal, battery level.
GET /api/sync/queue
Pending segments list from Wearable server.
POST /api/sync/now
Trigger immediate sync.
DELETE /api/sync/queue/{segmentId}
Discard a pending segment.
POST /api/habitat/test-alert
Sends test LED/haptic command to device.
GET /api/habitat/alerts?limit=5
Last N habitat alert log entries.

Code sketch — Connection hero orb
// In device_status_page.dart
Widget _buildConnectionOrb(WearableDeviceStatus status) {
  final color = switch (status) {
    WearableDeviceStatus.connected => WearableColors.primary,
    WearableDeviceStatus.syncing   => WearableColors.warning,
    WearableDeviceStatus.error     => WearableColors.destructive,
    _                          => WearableColors.mutedFg,
  };
  final isConnected = status == WearableDeviceStatus.connected;
  return AnimatedContainer(
    duration: const Duration(milliseconds: 500),
    width: 80, height: 80,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color.withOpacity(0.15),
      border: Border.all(color: color, width: 2),
      boxShadow: isConnected ? [WearableShadows.glow] : null,
    ),
    child: Icon(
      isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
      color: color, size: 36,
    ),
  );
}

## Screen 9: Dashboard WebView (New — Drawer Route)

Current file
wearable/pages/dashboard_page.dart  — CREATE THIS FILE

Current state
Does not exist. The Wearable dashboard runs at http://wearable-server.local:3141. This screen embeds it as a first-class page, injecting the bearer token so the user does not need to re-authenticate.

Entire screen to build from scratch

New screen: Dashboard WebView
Adds flutter_inappwebview: ^6.x to pubspec.yaml.
Injects bearer token from FlutterSecureStorage on load.
Handles LAN-only availability gracefully.

Layout structure
	•	App bar: "Dashboard" + open-in-browser icon (launches system browser).
	•	Full-screen InAppWebView — no padding except bottom safe area for the nav bar.
	•	Pull-to-refresh: enabled.
	•	Offline state: when server unreachable, show WearableOfflineCard widget.

WearableOfflineCard
	•	Centred in screen, card with cloud_off icon (mutedFg).
	•	"Dashboard unavailable" heading.
	•	"Connect to the Wearable network (LAN) to access the dashboard." body.
	•	"Retry" button — tries to reload the WebView.

Auth handling
	•	On loadStart, inject Authorization: Bearer <token> header via initialHeaders.
	•	Token loaded from FlutterSecureStorage using WearableClient.instance.loadCredentials().
	•	If token is missing, show a "Not paired" state with a link to the pairing flow.

pubspec.yaml additions
dependencies:
  flutter_inappwebview: ^6.1.0   # WebView with header injection
  # (already added for Phase 2)
  flutter_secure_storage: ^9.x   # already present in wearable_client.dart
 
android/app/src/main/AndroidManifest.xml:
  <application android:usesCleartextTraffic="true" ...>
  # Required for http:// local dashboard URL

Code sketch — DashboardPage
// wearable/pages/dashboard_page.dart
class DashboardPage extends StatefulWidget { ... }
 
class _DashboardPageState extends State<DashboardPage> {
  final _controller = Completer<InAppWebViewController>();
  bool _reachable = true;
 
  Future<Map<String, String>> _buildHeaders() async {
    final creds = await WearableClient.instance.loadCredentials();
    if (creds == null) return {};
    return {'Authorization': 'Bearer ${creds.bearerToken}'};
  }
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard'),
        actions: [IconButton(icon: const Icon(Icons.open_in_browser),
          onPressed: () => launchUrl(Uri.parse('http://wearable-server.local:3141')))]),
      body: _reachable
        ? FutureBuilder<Map<String, String>>(
            future: _buildHeaders(),
            builder: (_, snap) {
              if (!snap.hasData) return const CircularProgressIndicator();
              return InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri('http://wearable-server.local:3141'),
                  headers: snap.data,
                ),
                onLoadError: (_, __, ___, ____) =>
                  setState(() => _reachable = false),
              );
            })
        : const WearableOfflineCard(),
    );
  }
}

## Screen 10: Settings

Current file
pages/settings/settings_drawer.dart    — main settings entry
pages/settings/profile.dart
pages/settings/developer.dart
pages/settings/privacy.dart
pages/settings/device_settings.dart

Current state
Settings is a drawer-style sheet with groups: Profile, Notifications, Plan & Usage, Offline Sync, Integrations (Beta), Permissions, Feedback/Bug, Help Center, Developer Settings, Get KelvinLee for Mac, Referral Program.

What to ADD

New: "Wearable Advanced" group
Add a new settings group between "Integrations" and "Support".
Items: AI Persona → opens persona.dart (configure the main agent's persona). Safety Rules → read-only code viewer showing config/safety.rules content. Transcription Provider → existing STT provider selector. Session Server → shows paired Wearable server URL + change pairing option.

New: "Session Server" settings item
Shows current WearableClient baseUrl + devId.
Buttons: "Change Pairing" (opens pairing_page.dart) and "Forget Server" (calls WearableClient.instance.forget()).

What to CHANGE

Modify: Remove KelvinLee-specific items
Remove: "Get KelvinLee for Mac", "Referral Program". These are KelvinLee commercial features with no Wearable equivalent.

Modify: Rename "Developer Settings" → "Wearable Advanced"
Merge the existing developer.dart content into the new Wearable Advanced group. Keep: Persona, Transcription, Conversation Timeout, Export All Data, Debug Logs. Add: Safety Rules viewer, Session Server.

Modify: Integrations group
Remove Gmail (coming soon placeholder). Add "Custom Webhooks" (opens a simple URL input sheet for webhook configuration).

What to REMOVE
	•	"Get KelvinLee for Mac" ListTile.
	•	"Referral Program" ListTile.
	•	"Plan & Usage" (Wearable is self-hosted, no subscription tier UI needed). Can keep if billing is later added.

New files required
File
Purpose
wearable/pages/settings/wearable_advanced_page.dart
Wearable Advanced settings group UI.
wearable/pages/settings/safety_rules_page.dart
Read-only code viewer for config/safety.rules.
wearable/pages/settings/session_server_page.dart
Shows/changes Wearable server pairing.
wearable/pages/settings/custom_webhooks_page.dart
Add/remove webhook URLs for integrations.

API integration
Endpoint
Detail
GET /api/safety-rules
Returns raw content of config/safety.rules as text. Displayed in safety_rules_page.dart.
GET /api/webhooks
List of configured webhook URLs.
POST /api/webhooks
Add a new webhook URL.
DELETE /api/webhooks/{id}
Remove a webhook.

Code sketch — Safety Rules viewer
// wearable/pages/settings/safety_rules_page.dart
class SafetyRulesPage extends StatelessWidget {
  const SafetyRulesPage({super.key});
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety Rules'),
        actions: [IconButton(icon: const Icon(Icons.info_outline),
          onPressed: () => showDialog(context: context,
            builder: (_) => const AlertDialog(
              title: Text('Read-only'),
              content: Text('Safety rules can only be edited directly on the Wearable server. This is a live read-only view of config/safety.rules.'))))]),
      body: FutureBuilder<String>(
        future: WearableClient.instance.get('/api/safety-rules'),
        builder: (_, snap) {
          if (!snap.hasData) return const CircularProgressIndicator();
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(snap.data!,
              style: const TextStyle(fontFamily: 'Courier New', fontSize: 12,
                color: WearableColors.foreground)));
        }),
    );
  }
}

## Screen 11: Voice Routing Bottom Sheet (New — Shared Component)

Current file
wearable/widgets/wearable_routing_sheet.dart  — CREATE THIS FILE
(used by FAB, "Ask Wearable" contextual button, Agent Hub cards, and Re-route action)

Current state
The upstream KelvinLee app has a single-purpose chat flow with one AI persona. Wearable routes every prompt to one of five agents. This bottom sheet is the universal routing UI shared across all four entry points.

Entire component to build from scratch

New shared widget: WearableRoutingSheet
Modal bottom sheet, height 62% of screen height, drag handle visible.
Dismiss by swiping down or tapping outside.

Layout
	•	Drag handle (centred, 32 × 4 dp, borderRadius 2 dp, mutedFg colour).
	•	"Ask Wearable" — headlineMedium.
	•	"Where should this go?" — bodyMedium, mutedFg.
	•	Agent chip row: horizontal SingleChildScrollView.
	•	Chips: Auto / @main / @comms / @content / @ops / @research.
	•	Selected: primary fill, onPrimary text. Unselected: cardAlt fill, mutedFg.
	•	Auto chip is selected by default. Selecting any other chip deselects Auto.
	•	Context preview (optional): if pre-seeded with text (re-route scenario), show a card with the original prompt truncated to 2 lines.
	•	72 dp round microphone button — primary fill. Tap = start recording. Icon pulses while recording.
	•	Text input row below: "Or type a message…" input with send button (for typed queries).

Routing logic
	•	If Auto: send to Wearable intake → main agent decides routing (@role: prefix omitted).
	•	If specific role: prepend "@[role]: " to the prompt before sending to Wearable intake.
	•	Recorded audio: POST /api/audio with {role: selectedRole} in multipart body.
	•	Typed text: POST /api/chat with {message: text, role: selectedRole}.

Code sketch — agent chip row
// In wearable_routing_sheet.dart
final _roles = [null, ...WearableRole.values]; // null = Auto
 
Widget _buildChips() => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: Row(children: _roles.map((role) {
    final isSelected = _selectedRole == role;
    final label = role == null ? 'Auto' : '@${role.name}';
    final color = role == null ? WearableColors.primary
      : WearableAgentBadge.colorFor(role);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        selectedColor: color,
        onSelected: (_) => setState(() => _selectedRole = role),
        labelStyle: TextStyle(
          color: isSelected ? WearableColors.onPrimary : WearableColors.mutedFg,
          fontWeight: FontWeight.w600),
      ),
    );
  }).toList()),
);
 
// Post with routing
Future<void> _send(String text) async {
  final prefix = _selectedRole != null ? '@${_selectedRole!.name}: ' : '';
  await WearableClient.instance.post('/api/chat',
    body: {'message': '$prefix$text'});
  if (mounted) Navigator.pop(context);
}

Implementation Summary
The table below shows every new file that must be created and every existing file that must be edited.

New files to create
File
Screen
Priority
wearable/providers/wearable_connection_provider.dart
App Shell
P1
wearable/providers/wearable_task_provider.dart
App Shell
P1
wearable/providers/wearable_agent_provider.dart
Agent Hub
P1
wearable/providers/wearable_hive_mind_provider.dart
Hive Mind
P2
wearable/widgets/wearable_status_dot.dart
App Shell
P1
wearable/widgets/wearable_in_flight_banner.dart
App Shell
P1
wearable/widgets/wearable_agent_badge.dart
Conversations, Tasks, Memory
P1
wearable/widgets/wearable_routing_sheet.dart
FAB / all screens
P1
wearable/widgets/wearable_drawer.dart
App Shell
P1
wearable/widgets/wearable_capture_card.dart
Conversations
P1
wearable/widgets/wearable_offline_card.dart
Dashboard
P2
wearable/widgets/wearable_hive_mind_entry.dart
Hive Mind
P2
wearable/pages/agent_hub_page.dart
Agent Hub tab
P1
wearable/pages/hive_mind_page.dart
Hive Mind drawer
P2
wearable/pages/device_status_page.dart
Device Status drawer
P2
wearable/pages/dashboard_page.dart
Dashboard drawer
P2
wearable/pages/settings/wearable_advanced_page.dart
Settings
P2
wearable/pages/settings/safety_rules_page.dart
Settings
P3
wearable/pages/settings/session_server_page.dart
Settings
P1
wearable/pages/settings/custom_webhooks_page.dart
Settings
P3
wearable/models/wearable_memory.dart
Memory
P1
wearable/models/wearable_agent_meta.dart
Agent Hub (static data)
P1

Existing files to edit
File
What to change
pages/home/page.dart
Add WearableStatusDot, swap tab 5 from Apps to Agent Hub, add Drawer, update FAB behaviour.
core/app_shell.dart
Add WearableConnectionProvider + WearableTaskProvider to MultiProvider.
pages/conversations/conversations_page.dart
Add agent filter chips, update FAB label, add WearableInFlightBanner.
pages/conversations/widgets/conversation_list_item.dart
Add WearableAgentBadge as leading widget.
pages/action_items/action_items_page.dart
Rename "Action Items" → "Tasks", add filter chips.
pages/action_items/widgets/action_item_tile_widget.dart
Add agent source tag below task text.
pages/memories/page.dart
Add source filter chips, update speech-bubble tap to open WearableRoutingSheet.
pages/conversation_detail/page.dart
Add agent attribution header, per-message badge, re-route long-press.
pages/settings/settings_drawer.dart
Remove KelvinLee items, add Wearable Advanced group.
backend/schema/conversation.dart
Add wearableRole: String? and agentTimeline fields.
pubspec.yaml
Add flutter_inappwebview: ^6.1.0.
android/AndroidManifest.xml
Add usesCleartextTraffic for local HTTP dashboard.

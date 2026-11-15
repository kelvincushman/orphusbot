# Plan: what to take from Bot HQ

| | |
|---|---|
| Date | 2026-11-15 |
| Follows | [bot-hq-2026-11-15.md](bot-hq-2026-11-15.md) (§3 "Take" rows, §5 brief) |
| Read for this | Our `crates/proto` (`lib.rs`, `view.rs`), `crates/node/src/engine.rs`, `crates/server/src/{room,bots,team}.rs`, `bridge/orphusbot-bridge.ts`, `images/desktop`, DESIGN §3.4, §4.3, §5.3, §7.4, §11.4, §11.8, §12.4, §12.5. bot-hq at `decf9a21`: `web/src/components/{ActivityLine,Transcript}.tsx`, `web/src/lib/phrases.ts`, `web/src/voice/call.ts`, `server/src/agent/tools.ts`, `server/box/home.html` |
| Status | **A plan for Kelvin to review. Nothing here is decided or built.** The decision drafts in §7 have no numbers yet |

The harness, the gate and placement don't change. No Composio, Orgo or Bops code is used. bot-hq is MIT, but nothing below needs its code: each item is rebuilt on what we already have.

---

## 0. Summary

| # | Item | Size | New protocol or schema | Touches the gate |
|---|---|---|---|---|
| 1 | Steps: live "doing now" line and a "Worked for 2m 10s · 7 steps" fold-up | Small | Two thread events, one reducer item | No |
| 1A | Animated bots: robots show what they're doing, and bots visibly hand work to each other | Medium | A `kind` on each step, two team events, new inputs in the Rive files (Rive is the animation format the bots' faces and robots are drawn in) | No |
| 2 | Dressed screens: a home page with the bot's name, role and a clock | Small | Three env vars to the computer | No |
| 3 | Soul and notes panel per bot | Small–medium | One column on `bot`, two endpoints, two bot tools | No |
| 4 | `x_search`: research on X | Small | One bot setting, one dialog kind | Classed as a read, with a daily cap |
| 5 | Voice calls with any bot | Medium | One endpoint, one bot setting, one message flag | No (approvals stay taps) |
| 6 | Group chat; email inbox per bot | Not planned | | |

Build in that order. Kelvin asked on 2026-11-15 for more animated feedback, especially bots interacting, so 1A comes straight after 1, which it builds on. Items 2–4 are independent. Item 5 is better after 1, because the call shows its work as steps.

---

## 1. Steps and the thinking line

**What bot-hq does.** Tool calls are rows in the transcript. A run of them folds into one chip: while the turn runs it shows a status word ("Browsing"), a one-line caption and a timer; afterwards "Worked for 2m 10s · 7 steps", which opens to the list. The labels come from a small table keyed by tool (`phrases.ts`, `tools.ts`).

**What we have.** Our thread has no tool-call item at all: `view::Item` is Message, Card, Notice, Attached or Artifact, and the app's pill says only "Working". But the server already sees both ends of every tool call:

- the start, because the bridge opens an `orphusbot-gate` dialog for *each* tool call with `{toolCallId, tool, input}` (§4.3);
- the end, as `FromNode::ToolDone { tool_call_id, ok, result }`.

So this needs no change to the node, the bridge or the engine.

**Design.**

- **Server** (`runs.rs`, new `steps.rs`): when a gate dialog arrives, publish `ThreadEvent::StepStarted { run, id, label }`; on `ToolDone`, publish `ThreadEvent::StepEnded { id, ok }`. A call the gate denies ends at once with `ok: false`.
- **Labels** (`steps::label(tool, input) -> String`): one match on the tool name, written in our own words. `bash` → "Running a command"; `read` → "Reading a file"; `write`/`edit` → "Writing a file"; `ask_bot` → "Checking with `<bot name>`"; `google` → "Looking in `<service>`"; `media` → "Making an image"; `phone` → "Using the phone"; an MCP tool (Model Context Protocol: a tool from one of the bot's connections) → "Using `<connection name>`"; anything else → "Working". The label carries at most a bot's, service's or connection's name, never a file name (a name such as `token-abc123` can itself be a secret), a command line, a URL, or any other argument. Arguments stay where they are today: in approval cards and the effect ledger. That keeps secrets out of the thread (hard rule 8) without a redaction pass.
- **Reducer** (`view.rs`): a new `Item::Steps { steps: Vec<Step>, open: bool }` where `Step { id, label, done: Option<bool> }`. Consecutive step events fold into the last `Steps` item; any other item closes it to new steps. A `StepEnded` finds its step by run and `id` together, in whichever `Steps` item holds it, not only the last one. Both events carry `run`, because a tool-call id is only unique within its run (the effect ledger keys on `(run, tool_call_id)` for the same reason): a call that needed approval has its card between its start and its end, and must still be marked finished. `ThreadView` gains `doing: Option<String>` (the label of the newest unfinished step, cleared on `RunEnded`). Both clients get this from the one reducer.
- **Timing:** the fold-up's duration runs from the first step to the item that closes it, and that item can be any kind (a message, a card). Today `ThreadEvent` carries no time and `db::since` doesn't select the stored `event.created_at`, so nothing has a time after a reload. The fix is one change for every event: `since` selects `created_at` and the stream passes it to clients beside each event, so the reducer stamps every item. Live-only events use the time they arrive.
- **Flutter** (`chat.dart`, `thread.dart`): the top pill shows `doing` in place of "Working" when it is set. In the transcript, a `Steps` item is a single grey line: while running, the current label and a count; when closed, "Worked for 2m 10s · 7 steps", which expands to the labels with a tick or a cross. The **Leptos** UI (the Rust web client in `crates/ui`) gets the same line.
- **Wearable:** nothing changes. It has no use for steps.
- **Stored:** as thread events, like the rest of the thread, so the fold-up is there after a reload.

**Not taken:** rotating joke phrases, the mascot on a pill, per-step screenshots and expandable arguments.

**Tests:** reducer tests in `proto` (folding, closing, a denied call, a run that ends mid-step); a label table test, including that a label contains nothing from the input except the one name its tool is allowed (the teammate for `ask_bot`, the service for `google`, the connection for an MCP tool), and never a file name, command or URL.

---

## 1A. Animated bots, and bots working together

**Asked for by Kelvin (2026-11-15):** more animated feedback from the bots, especially when they interact with each other.

**What bot-hq does.** Little: a mascot on a pill with a pulsing status word and a lightbulb, and a "From Barbie" label on a message from another bot. Nothing moves between bots. This item goes past the video.

**What we have.** Every bot has a Rive face and a full-body robot (`design/bot-avatar`, built by `gen.py`), with a `state` input (0 idle, 1 thinking, 2 working, 3 needs you, 4 done, 5 failed) and a `poke` trigger. "Working" looks the same whatever the bot is doing. When one bot asks another (`ask_bot`), the only sign is a labelled message when the answer comes back. A discussion is a list of posts.

**Design, in three layers.**

*1. Robots show what kind of work it is.*

- Each step (item 1) gets a `kind` beside its label: `read`, `write`, `command`, `browse`, `search`, `talk` (to a teammate), `google`, `media`, `phone`, `other`. `steps::label` returns both.
- The Rive state machine `Bot` gains a number input `doing`, used while `state` is 2. `gen.py` adds a small prop per kind, drawn once and shared by every style: a book (read), a pencil (write), a terminal with a blinking cursor (command), a globe (browse), a magnifying glass (search), a speech bubble (talk), an envelope (google), a paintbrush (media), a phone (phone). `other` keeps today's swinging arms.
- `ThreadView` already drives `state` through `mood`; it gains `doing` from the newest unfinished step. The face in the chat's top pill, the robot in an empty chat and the faces in the menu all follow it.

*2. Hand-offs you can see.*

- **Events:** two new thread events, published to both bots' threads: `Asked { from, to, ticket }` when `team::ask` makes the ticket, and `Answered { from, to, ticket, ok }` when the answer goes back. System 1's `Routed` event already exists for the Inbox.
- **In the chat:** an `Asked` item is a small strip with the two faces. The asker's face leans in, a note flies across in an arc, and the teammate's face catches it and switches to working. `Answered` plays it back the other way, and the asker does its "done" wiggle. After playing once the strip rests as a plain line ("Researcher asked Coder · OB-142"), which opens the ticket.
- **Rive:** two triggers, `give` and `receive`, each about a second, generated per locomotion the way `poke` is (a drone dips, a wheeled bot rolls forward and back). The note itself and its flight are a Flutter widget, so the Rive files stay one bot each.

*3. The team stage.*

- A **Team** screen in the menu (and a strip above the bot list on wide windows): every bot's full-body robot standing in its own spot, each in its current `state` and `doing`.
- When one bot asks another, the asker moves across to the teammate (its own locomotion plays while Flutter moves it), `give` and `receive` fire, and it goes back. While the teammate works on that ticket a thin line joins the two. A routed Inbox message is the Inbox bot tossing a note to the bot it chose.
- **Discussions** use the same stage: the chosen bots gather in a ring, the one whose turn it is steps forward with a speech bubble showing the first words of its post, and the chair holds up the verdict at the end.
- Tapping a robot opens its chat. Tapping a line opens the ticket.
- **Feed:** the stage needs every bot's state at once. The stream that already feeds the menu's statuses and needs-you badges gains `doing` and the two team events. No new connection.

**Calm by default (accessibility, hard rule 3, and the ADHD-first profiles).**

- Motion happens when something changes and then stops. An idle stage is still, apart from the fidgets the robots already have.
- A setting, **Animation: full, calm or off**. Calm keeps state changes and drops travel across the stage and the idle fidgets. Off shows static faces and plain lines. The system's reduce-motion setting forces at least calm.
- Every animation has a text twin: the strip's resting line, the step label. Nothing is told by motion alone.
- No new sounds. The Ideas Room's cues stay where they are.

**Where it shows.** The Flutter app first. The Omarchy bar panel's faces get `doing` for free if it loads the same files. The Leptos web UI gets the resting lines only. The wearable is not involved.

**Not taken:** bot-hq's mascot pill and lightbulb; chat bubbles between robots on the stage beyond the first words of a discussion post (the thread is where text lives).

**Tests:** reducer tests for `Asked` and `Answered` (pairing by ticket, an answer that never comes, a denied ask); `gen.py`'s existing frame renders extended to every `doing` value and both triggers, so each style is checked by eye from one sheet.

---

## 2. Dressed screens

**What bot-hq does.** Before a bot's first turn its screen gets a wallpaper, a dock and a Chrome whose new-tab page is a home screen: clock, the bot's name and role, its apps. The agent never meets an empty desktop, and a person watching knows whose screen it is.

**What we have.** `images/desktop/start-screen` starts Xvnc and openbox on a bare grey screen. Chromium is installed and starts when the bot opens it.

**Design.**

- **Node** (`computer.rs`): pass `ORPHUSBOT_BOT_NAME`, `ORPHUSBOT_BOT_REMIT` and `ORPHUSBOT_BOT_COLOUR` (a hex colour from the bot's face, or a default) when it creates the computer.
- **Image** (`images/desktop`): `start-screen` renders `/tmp/home.html` from a template baked into the image, using the `python3` that is already there and `html.escape` on every value. The page shows a clock, the date, the bot's name and remit on a soft wash of its colour. It is one static file with inline CSS and no network requests, since the computers have no internet at build time and limited access at run time.
- **Chromium policy** baked into the image (`/etc/chromium/policies/managed/orphusbot.json`): `HomepageLocation` and `NewTabPageLocation` point at `file:///tmp/home.html`, with `RestoreOnStartup` opening it.
- **Desktop background:** `xsetroot -solid <colour>` in `start-screen`, so even an empty screen has the bot's colour.
- **Chromium is not started for the bot.** bot-hq launches a browser for every bot; ours have 2 GB each and many never browse. The home page appears when the browser first opens.
- **Other images:** `rea` is built on `desktop` and inherits it. `omarchy` keeps its own look: it takes the Chromium policy, and its own start script renders the same `/tmp/home.html` from the same template (one shared render script, copied into both images), so the policy never points at a missing page. The E2B template needs a rebuild to pick it up.

**Not taken:** the dock, app tiles, the Orgo look, or anything from Bops.

**Tests:** a script test that renders the template with a hostile name (`<script>`) and checks it is escaped.

---

## 3. Soul and notes panel

**What Muse and bot-hq do.** Muse shows SOUL and MEMORY as two cards on the agent's profile. bot-hq lists the entries of Hermes's `MEMORY.md` and lets you delete one.

**What we have.** A bot's soul is its `instructions`, edited in Settings. Memory is the team wiki in the vault (§11.4, §11.8): shared, and read only when a bot queries it. There is no small per-bot memory, and nothing on the chat screen shows what a bot has been told.

**Design.**

- **Notes per bot, kept in the database:** a `notes` text column on `bot`. It holds short standing notes: how Kelvin likes this bot to work, and things it has been corrected on. It is for preferences, not knowledge. Knowledge still goes to the wiki.
- **Why not a file in the vault.** An earlier draft kept `bots/<slug>/notes.md` there. Team bots can write in the vault, so one could swap a folder for a link and make the server write outside it, and could read or change another bot's notes, including a private bot's. A column has neither problem: only the server touches it, and a bot reaches only its own.
- **Read at run start:** `team::roster_note` already rebuilds a note for every run. It appends the bot's notes, cut to **2,000 characters**, under "Your notes". A cap this small keeps to Kelvin's rule that bots load context by choice: the wiki stays query-only. **Past the cap:** nothing is dropped silently. The run note ends with "(Your notes are longer than fits here: tidy them.)", and the Notes panel shows a count ("2,340 of 2,000 loaded") with the part that isn't loaded greyed out. Saving is limited to 16 KB.
- **Written by:** Kelvin, in the app. And the bot, through two tools the server answers as dialogs, the same pattern as `ask_bot`, so they work on whichever node the bot runs: `remember { line }` appends a line, and `rewrite_notes { text }` replaces the whole of its own notes, which is how it tidies them when told they are too long. Each acts only on the calling bot's row. The gate treats both as notes in the bot's own workspace. The bot's instructions gain one line: "When Kelvin corrects how you work, remember it."
- **Server** (`bots.rs`): `GET` and `PUT /api/bots/{slug}/notes` for the app, and the two dialogs. One migration adds the column.
- **App:** tapping the bot's pill at the top of the chat opens a panel with three parts. **Soul** is the instructions, editable (the same field as Settings). **Notes** is the bot's notes, editable. **Can do** is the line the bot is told about itself (model, Google access, connections, phone, media), read-only, taken from the same code that writes the roster.
- **Private-scope bots** work the same way and stay private: their notes are in their own row, which no other bot can read or change.
- **Obsidian:** not in the first version. If Kelvin wants to read notes there, the server can write a read-only copy of team bots' notes into the vault on change. It would never be read back, so it can't be used to change anything.

**Not taken:** Honcho or any memory service; a separate USER file (Kelvin's own Memory notes are already in the vault); bots rewriting their own instructions (a later step, by card, the way `install_skill` works).

**Open question for Kelvin (Q1):** should notes be loaded into every run (as above, predictable, 2,000 characters), or only pointed at (a tool to read them when they matter)? The first is what makes an edit take effect every time. The second is stricter about context.

---

## 4. `x_search`

**What bot-hq does.** A tool that sends one question to xAI's Responses API with the server-side `x_search` tool (optional handles and dates) and returns the written answer with links to the posts.

**What we have.** Posting to X through the phone (§11.6). No way to read X. The xAI key is already on the server for the Ideas Room (`ORPHUSBOT_XAI_KEY`).

**Design.**

- **Bridge tool** `x_search { query, handles?, exclude_handles?, from_date?, to_date? }`. Like `ask_bot` and `discuss`, it opens a dialog (`orphusbot-xsearch`) that the **server** answers. The server makes the xAI call and returns the text. The key never reaches a node, an engine or a computer, and it works the same for a bot on the laptop or in E2B.
- **Server** (new `xsearch.rs`): validates the input (query up to 1,000 characters, up to 10 handles, dates as `YYYY-MM-DD`), calls `POST https://api.x.ai/v1/responses` with `store: false`, the `x_search` tool and a system line asking for author, date and link for each post. The model is `ORPHUSBOT_XAI_MODEL` (default `grok-4.7`). The answer is cut to the usual result length.
- **Per bot:** a new setting `x_search` (boolean, off by default, migration), shown in Settings beside Media. The bridge offers the tool only when it is on, and the server refuses the dialog otherwise.
- **Gate:** it only reads, so it runs without asking. Cost is bounded by a daily cap counted on the server, `ORPHUSBOT_X_SEARCH_PER_DAY` (default 50, across all bots); past it the tool answers "today's X searches are used up". xAI charges about $5 per 1,000 posts fetched.
- **Privacy:** the query goes to xAI. The tool description tells the bot to ask about the topic and not to include Kelvin's private material.
- **Trait and fake:** the xAI call sits behind a trait with a fake in `testkit`, like every external system.

**Not taken:** xAI's `web_search`, since bots already browse with their own computers.

---

## 5. Voice calls with any bot

**What bot-hq does.** A call button on every bot. The browser talks to xAI's realtime voice with a short-lived secret. The voice hands real work to the same bot's queue, and speaks the result. Each voice turn appears in the chat as "Asked on a voice call", with the bot's steps under it. In the video the caller told the bot to open two sites, switch tab and message another bot.

**What we have.** The Ideas Room (§12.5): the same pattern, for the Orchestrator only, with brainstorming instructions, its own memory and a quick model. `live_voice.dart` already handles the audio, echo and interruptions.

**Design.**

- **Endpoint:** `POST /api/bots/{slug}/voice`, beside `/api/room/voice` and sharing its code for minting the five-minute secret. It returns a session whose instructions say: you are the voice of `<name>`, whose job is `<remit>`; keep turns short; never claim something is done until the bot says so.
- **Two tools for the voice:**
  - `ask { request }`: for questions. A message in the bot's thread, run on the quick model with thinking off (as `room::quick` does now), and the reply is the function's output. Seconds.
  - `do { task }`: for work. A normal message in the bot's thread on its own model, with its computer. It returns at once with "started". When that run ends, the server sends the reply to the app, which passes it into the call as "(`<name>` has finished: …)" at the next pause. This is how the Orchestrator's five-minute view reaches Grok today.
- **Thread:** both kinds of message carry `voice: true` and show a small "Asked on a call" label. With item 1 built, the bot's steps appear under it while Kelvin listens.
- **Approvals stay taps.** If the run needs approval, the card appears in the app as always, and the voice is told "it needs your OK on the screen". A spoken "yes" never approves anything: speech can be misheard, and hard rule 5 wants a human tap or a user rule.
- **Per bot:** a `voice` setting (one of xAI's voices; default `ORPHUSBOT_XAI_VOICE`).
- **App:** a call button in the chat's top bar opens the existing orb over that bot's chat. Ending the call leaves the transcript in the thread; no separate session table, rating or recap. Those stay with the Ideas Room.
- **The Ideas Room is unchanged.** It keeps its brainstorming instructions and memory.
- **Wearable:** not involved. It has no speaker (hard rule 6).
- **Cost and privacy:** about $0.05 a minute, and Kelvin's speech goes to xAI during a call. He accepted both for the Ideas Room (D-052); this extends that choice to every bot, so it needs its own decision entry.

**Depends on:** the bot's screen being visible in the Flutter app during a call, if Kelvin wants to watch it work as in the video. In October it was only in the Leptos web UI. Check before starting.

**Open question for Kelvin (Q2):** the PRD lists calls as a v1 non-goal. The Ideas Room already crossed that line for one bot. Is a call with any bot wanted now, or should it wait until the desktop app is settled ("build app last")?

---

## 6. Not planned

- **Group chat with @mentions.** Not taken from bot-hq, but not dropped: PRD B-BOT-02 (P1) requires a group thread as an Orphus room, and it should be built to that requirement when it is scheduled. Until then, Discussions (D-036) cover the case where several bots weigh a question, with rounds and a verdict, and `ask_bot` covers hand-offs. A casual room adds a third way for bots to talk and a new way for a thread to flood. Revisit if Kelvin finds himself wanting to address two bots at once.
- **An email inbox per bot.** It needs a mail domain, spam handling and a rule for who a bot may answer. AgentMail would do it as a service; a mailbox on the box would keep it self-hosted. Neither is small. The PA already reads and drafts in Kelvin's Gmail.
- **Honcho as a service.** Not adopted, here or for per-bot notes. Since this plan was written, the [Honcho study](honcho-2026-11-15.md) led to a decision to rebuild selected memory capabilities in Rust inside the server (learned facts about the owner, built in stages). That is separate work and nothing in this plan depends on it. The per-bot notes in item 3 stay hand-kept.

---

## 7. Decision drafts

Numbers are assigned when each is built.

**Steps come from the gate's own events.** *Decided:* the thread shows each tool call as a step, labelled by the server from the tool's name and at most a bot, service or connection name; file names and arguments are not put in the thread. *Why:* the server already sees every call start and end, so no new channel is needed, and keeping arguments out means nothing secret reaches the thread. *Alternatives:* the node forwarding Orphus's `tool_execution_start` (a second source for what the gate already has); showing arguments (needs redaction, and leaks when it misses). *Revisit if:* Kelvin wants to see commands without opening the ledger.

**Bots show their work and their hand-offs in motion, calm by default.** *Decided:* each step has a kind that the robot acts out with a prop; `ask_bot` and its answer are thread events that play as a note passing between two faces; a Team screen shows every robot and moves them when they work together; a setting offers full, calm or off, and reduce-motion is honoured. *Why:* Kelvin asked for it, and seeing who is doing what, and who is waiting on whom, is information the text hides. *Alternatives:* status words only, as bot-hq does (no sense of the team); one Rive scene holding every bot (the files are generated per style, and a shared scene would have to be rebuilt whenever a bot is added). *Revisit if:* the motion distracts more than it informs.

**A bot's screen opens on its own home page.** *Decided:* the desktop image renders a local page with the bot's name, remit and colour, set as Chromium's home and new tab; the browser is not started for the bot. *Why:* a watcher can tell whose screen it is, at no memory cost. *Alternatives:* starting a browser for every bot, as bot-hq does (memory on a 2 GB computer); a dock and app tiles (decoration). *Revisit if:* bots waste turns on an empty screen.

**Each bot has short notes in the database, read at every run.** *Decided:* a `notes` column on `bot`, 2,000 characters loaded per run, edited by Kelvin in the app and by the bot through `remember` and `rewrite_notes`. *Why:* corrections should stick without Kelvin editing instructions, and he should be able to see and fix what a bot has taken on. Keeping them out of the vault means no bot can reach another's notes or trick the server into writing elsewhere. *Alternatives:* a file per bot in the vault (readable in Obsidian, but writable by every team bot); Honcho (a service); pointing at the notes without loading them (edits don't reliably take effect). *Revisit if:* notes grow past the cap, bots stop keeping them, or Kelvin wants them in Obsidian. Depends on Q1.

**X research goes through the server.** *Decided:* an `x_search` tool answered by the server with xAI's search, per bot, off by default, read-class with a daily cap. *Why:* the key stays on the server and the cost is bounded. *Alternatives:* the key on the node, as with media (one more place for it, and no single cap); reading X through the phone (slow, and that phone is for posting). *Revisit if:* the cap is hit often or xAI's terms change.

**Any bot can be called; approvals stay taps.** *Decided:* a call with any bot through xAI's realtime voice, with `ask` for quick answers and `do` for real work in the bot's own thread; nothing is approved by voice. *Why:* it is the Ideas Room's proven path, generalised, and it keeps rule 5 intact. *Alternatives:* one voice for everything through the Orchestrator (already built, but it can't drive another bot's computer directly); a local voice model (slower, as D-050 found). *Revisit if:* Kelvin wants approvals by voice, which would need a spoken code or a wearable tap. Depends on Q2.

---

## 8. Questions for Kelvin

1. **Q1 (notes):** load a bot's notes into every run, or only point at them?
2. **Q2 (calls):** build calls with any bot now, or after the desktop app is settled?
3. **Q3 (X search):** which bots get it first? The plan assumes off by default, switched on per bot.
4. **Q4 (order):** is 1 → 1A → 2 → 3 → 4 → 5 right, or should calls move up?
5. **Q5 (animation):** should the Team stage be its own screen, the app's home, or both? And should the default be full or calm?

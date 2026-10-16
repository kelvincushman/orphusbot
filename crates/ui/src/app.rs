//! The app: sign-in, the bot sidebar, the chat with its cards, and settings.
//! Layout follows the Rakazo study (docs/research/rakazo-architecture.md).

use leptos::ev::{KeyboardEvent, SubmitEvent};
use leptos::prelude::*;
use leptos::task::spawn_local;
use std::collections::HashMap;

use orphusbot_proto::view::{Item, RunState, ThreadView};
use orphusbot_proto::{Dialog, DialogKind, Envelope, NodeView, Role, ThreadEvent};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use wasm_bindgen::prelude::*;
use web_sys::{EventSource, MessageEvent};

use crate::api;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Screen {
    Loading,
    SignIn { setup_open: bool },
    Signed,
}

/// Shared by every component.
#[derive(Clone, Copy)]
struct Ctx {
    screen: RwSignal<Screen>,
    /// Signed in with the setup token: ask for a passkey.
    needs_passkey: RwSignal<bool>,
    /// The last error or confirmation; click to dismiss.
    toast: RwSignal<String>,
    /// The bot's screen panel is open.
    bot_screen: RwSignal<bool>,
}

impl Ctx {
    fn reload(self) {
        self.run(async move {
            let s = api::auth_state().await?;
            self.needs_passkey.set(s.needs_passkey);
            self.screen.set(if s.signed_in {
                Screen::Signed
            } else {
                Screen::SignIn {
                    setup_open: s.setup_open,
                }
            });
            Ok(())
        });
    }

    /// Runs `work` in the background, showing its error if it fails.
    fn run(self, work: impl Future<Output = Result<(), String>> + 'static) {
        spawn_local(async move {
            if let Err(e) = work.await {
                self.toast.set(e);
            }
        });
    }
}

#[component]
pub fn App() -> impl IntoView {
    let ctx = Ctx {
        screen: RwSignal::new(Screen::Loading),
        needs_passkey: RwSignal::new(false),
        toast: RwSignal::new(String::new()),
        bot_screen: RwSignal::new(false),
    };
    provide_context(ctx);
    ctx.reload();
    // Messages clear themselves after a few seconds, unless a newer one replaced them.
    Effect::new(move |_| {
        let shown = ctx.toast.get();
        if !shown.is_empty() {
            set_timeout(
                move || {
                    ctx.toast.update(|now| {
                        if *now == shown {
                            now.clear()
                        }
                    })
                },
                std::time::Duration::from_secs(6),
            );
        }
    });
    // A memo, so setting the same screen again doesn't rebuild it.
    let screen = Memo::new(move |_| ctx.screen.get());
    view! {
        {move || match screen.get() {
            Screen::Loading => view! { <div class="centre muted">"Loading…"</div> }.into_any(),
            Screen::SignIn { setup_open } => view! { <SignIn setup_open /> }.into_any(),
            Screen::Signed => view! { <Shell /> }.into_any(),
        }}
        <Show when=move || !ctx.toast.get().is_empty()>
            <div class="toast" role="alert" on:click=move |_| ctx.toast.set(String::new())>
                {move || ctx.toast.get()}
            </div>
        </Show>
    }
}

#[component]
fn SignIn(setup_open: bool) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let token = RwSignal::new(String::new());
    let busy = RwSignal::new(false);
    let setup = move |ev: SubmitEvent| {
        ev.prevent_default();
        busy.set(true);
        let t = token.get_untracked();
        ctx.run(async move {
            let done = api::setup(&t).await;
            busy.set(false);
            done?;
            ctx.reload();
            Ok(())
        });
    };
    let passkey = move |_| {
        ctx.run(async move {
            api::passkey_sign_in().await?;
            ctx.reload();
            Ok(())
        })
    };
    // Linking: this device shows a code; a signed-in device approves it.
    let linking = RwSignal::new(None::<api::Link>);
    let link = move |_| {
        ctx.run(async move {
            let started = api::link_start().await?;
            let device_code = started.device_code.clone();
            linking.set(Some(started));
            loop {
                api::sleep(2000).await;
                // Stop if cancelled, or if this screen has gone.
                if linking.try_get_untracked().flatten().is_none() {
                    return Ok(());
                }
                match api::link_poll(&device_code).await {
                    Ok(true) => {
                        ctx.reload();
                        return Ok(());
                    }
                    Ok(false) => {}
                    Err(e) => {
                        linking.set(None);
                        return Err(e);
                    }
                }
            }
        })
    };
    let origin = web_sys::window()
        .and_then(|w| w.location().origin().ok())
        .unwrap_or_default();
    let passkeys = api::passkeys_work();
    let body = if setup_open {
        view! {
            <p class="muted">"First run: enter the setup token from the server's settings, then add a passkey."</p>
            <form on:submit=setup>
                <input type="password" aria-label="Setup token" placeholder="Setup token"
                    autocomplete="off" required bind:value=token />
                <button class="primary" disabled=move || busy.get()>"Continue"</button>
            </form>
        }
        .into_any()
    } else {
        view! {
            {move || match linking.get() {
                Some(l) => view! {
                    <p>"On a device where you're signed in, open"</p>
                    <pre class="link">{format!("{origin}/?link={}", l.user_code)}</pre>
                    <p>"or go to Settings → Link a device and enter"</p>
                    <p class="code" aria-label="Link code">{l.user_code}</p>
                    <p class="muted" role="status">"Waiting for approval…"</p>
                    <button on:click=move |_| linking.set(None)>"Cancel"</button>
                }
                .into_any(),
                None => view! {
                    {passkeys.then(|| view! {
                        <p class="muted">"Sign in with a passkey on this device."</p>
                        <button class="primary" on:click=passkey>"Sign in with a passkey"</button>
                    })}
                    {(!passkeys).then(|| view! {
                        <p class="muted">"This app can't use passkeys, so approve it from a device that can."</p>
                    })}
                    <button class:primary=!passkeys on:click=link>"Sign in with another device"</button>
                }
                .into_any(),
            }}
        }
        .into_any()
    };
    view! {
        <main class="centre">
            <div class="signin">
                <h1>"OrphusBot"</h1>
                {body}
            </div>
        </main>
    }
}

/// Streams the thread's events into `view` (DESIGN §12, sync).
fn connect(desk: Desk, ctx: Ctx) {
    let Ok(source) = EventSource::new("/api/events") else {
        return ctx.toast.set("This browser can't stream events".into());
    };
    let on_message = Closure::<dyn Fn(MessageEvent)>::new(move |m: MessageEvent| {
        let envelope = m
            .data()
            .as_string()
            .and_then(|d| serde_json::from_str::<Envelope>(&d).ok());
        let Some(Envelope { bot, event }) = envelope else {
            return;
        };
        match (bot, event) {
            (_, ThreadEvent::Nodes { nodes }) => desk.nodes.set(nodes),
            (Some(bot), event) => {
                // A bot made on another device: fetch the roster again.
                if !desk
                    .bots
                    .with_untracked(|b| b.iter().any(|b| b.slug == bot))
                {
                    desk.load_bots(ctx);
                }
                desk.threads
                    .update(|t| t.entry(bot).or_default().apply(event));
            }
            (None, _) => {}
        }
    });
    let retrying = source.clone();
    let on_error = Closure::<dyn Fn()>::new(move || {
        // EventSource reconnects by itself (resuming from Last-Event-ID); stop only
        // when the session has ended.
        let source = retrying.clone();
        spawn_local(async move {
            if api::signed_out().await {
                source.close();
                ctx.reload();
            }
        });
    });
    source.set_onmessage(Some(on_message.as_ref().unchecked_ref()));
    source.set_onerror(Some(on_error.as_ref().unchecked_ref()));
    // ponytail: the handlers live as long as the page; signing out reloads it.
    on_message.forget();
    on_error.forget();
}

/// A bot, as the server lists it (server `bots::Bot`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Bot {
    slug: String,
    name: String,
    remit: String,
    instructions: String,
    model: Option<String>,
    thinking: Option<String>,
    exclude_tools: Vec<String>,
    scope: String,
    disabled: bool,
}

/// Everything the signed-in screens share: the bots, which one is open, every
/// bot's thread, and the nodes.
#[derive(Clone, Copy)]
struct Desk {
    bots: RwSignal<Vec<Bot>>,
    selected: RwSignal<String>,
    threads: RwSignal<HashMap<String, ThreadView>>,
    nodes: RwSignal<Vec<NodeView>>,
}

impl Desk {
    fn load_bots(self, ctx: Ctx) {
        ctx.run(async move {
            self.bots.set(api::get("/api/bots").await?);
            Ok(())
        });
    }

    /// The open bot's thread.
    fn thread(self) -> Memo<ThreadView> {
        Memo::new(move |_| {
            let bot = self.selected.get();
            self.threads
                .with(|t| t.get(&bot).cloned().unwrap_or_default())
        })
    }

    fn bot(self) -> Memo<Bot> {
        Memo::new(move |_| {
            let slug = self.selected.get();
            self.bots
                .with(|b| b.iter().find(|b| b.slug == slug).cloned())
                .unwrap_or_default()
        })
    }
}

/// The first letter of a bot's name, for its avatar.
fn initial(name: &str) -> String {
    name.chars()
        .next()
        .map(|c| c.to_uppercase().to_string())
        .unwrap_or_default()
}

#[component]
fn Shell() -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = Desk {
        bots: RwSignal::new(Vec::new()),
        // A push opens the bot it's about (`/?bot=researcher`).
        selected: RwSignal::new(take_param("bot").unwrap_or_else(|| "inbox".to_owned())),
        threads: RwSignal::new(HashMap::new()),
        nodes: RwSignal::new(Vec::new()),
    };
    provide_context(desk);
    desk.load_bots(ctx);
    let settings = RwSignal::new(false);
    let routines = RwSignal::new(false);
    let tickets = RwSignal::new(false);
    let decisions = RwSignal::new(false);
    let captures_open = RwSignal::new(false);
    // Hands-free state and waiting proposals, shown on every screen (PRD B-CAP-07).
    let captures = RwSignal::new(Value::Null);
    let load_captures = move || {
        ctx.run(async move {
            captures.set(api::get("/api/captures").await?);
            Ok(())
        })
    };
    load_captures();
    if let Ok(timer) = set_interval_with_handle(load_captures, std::time::Duration::from_secs(15)) {
        on_cleanup(move || timer.clear());
    }
    let waiting_proposals = move || {
        captures.with(|c| {
            c["proposals"]
                .as_array()
                .map_or(0, |p| p.iter().filter(|p| p["state"] == "proposed").count())
        })
    };
    let menu = RwSignal::new(false);
    // `None`: closed; `Some(None)`: a new bot; `Some(Some(bot))`: editing it.
    let editing = RwSignal::new(None::<Option<Bot>>);
    // Opened from a device's link (`/?link=CODE`): go straight to approving it.
    let link_code = RwSignal::new(take_param("link").unwrap_or_default());
    if !link_code.get_untracked().is_empty() {
        settings.set(true);
    }
    connect(desk, ctx);
    let thread = desk.thread();
    let bot = desk.bot();
    let status = Memo::new(move |_| desk.nodes.with(|n| thread.with(|v| v.status(n))));
    view! {
        <div class="shell">
            <nav class="sidebar" class:open=move || menu.get() aria-label="Bots">
                <div class="brand">"OrphusBot"</div>
                <For each=move || desk.bots.get() key=|b| (b.slug.clone(), b.name.clone(), b.disabled) children=move |b| {
                    let slug = b.slug.clone();
                    let select = slug.clone();
                    let current = slug.clone();
                    let badge = slug.clone();
                    let waiting = Memo::new(move |_| desk.threads.with(|t| t.get(&badge).map_or(0, ThreadView::waiting)));
                    let preview = Memo::new(move |_| {
                        desk.threads.with(|t| {
                            let last = t.get(&slug).and_then(|v| v.last_message().map(str::to_owned));
                            last.unwrap_or_else(|| "No messages yet".into()).chars().take(80).collect::<String>()
                        })
                    });
                    view! {
                        <button class="bot" class:active=move || desk.selected.get() == current class:disabled=b.disabled
                            aria-current=move || (desk.selected.get() == select).then_some("page")
                            on:click={
                                let slug = b.slug.clone();
                                move |_| { desk.selected.set(slug.clone()); menu.set(false); }
                            }>
                            <span class="avatar" aria-hidden="true">{initial(&b.name)}</span>
                            <span class="text">
                                <strong>{b.name.clone()}</strong>
                                <small>{move || preview.get()}</small>
                            </span>
                            <Show when=move || { waiting.get() > 0 }>
                                <span class="badge" title="Waiting for you">{move || waiting.get()}</span>
                            </Show>
                        </button>
                    }
                } />
                <button class="new-bot" on:click=move |_| { editing.set(Some(None)); menu.set(false); }>"+ New bot"</button>
                <div class="spacer"></div>
                <button on:click=move |_| { tickets.set(true); menu.set(false); }>"Tickets"</button>
                <button on:click=move |_| { routines.set(true); menu.set(false); }>"Routines"</button>
                <button on:click=move |_| { decisions.set(true); menu.set(false); }>"Decisions"</button>
                <button on:click=move |_| { captures_open.set(true); menu.set(false); }>
                    "Captures" {move || (waiting_proposals() > 0).then(|| view! { <span class="badge">{waiting_proposals()}</span> })}
                </button>
                <button on:click=move |_| settings.set(true)>"Settings"</button>
            </nav>
            <main class="chat">
                <header>
                    <button class="menu" aria-label="Show bots" on:click=move |_| menu.update(|m| *m = !*m)>"☰"</button>
                    <span class="avatar" aria-hidden="true">{move || initial(&bot.get().name)}</span>
                    <div class="title">
                        <h1>{move || bot.get().name}</h1>
                        <span class="status" role="status">{move || status.get()}</span>
                    </div>
                    <button aria-label="Edit this bot" on:click=move |_| editing.set(Some(Some(bot.get_untracked())))>"Edit"</button>
                    <button aria-label="Show the bot's screen" on:click=move |_| ctx.bot_screen.set(true)>"Screen"</button>
                    <button aria-label="Settings" on:click=move |_| settings.set(true)>"⚙"</button>
                </header>
                <Show when=move || ctx.needs_passkey.get()>
                    <div class="banner">
                        <span>"You're signed in with the setup token for one hour. Add a passkey to keep access."</span>
                        <button class="primary" on:click=move |_| settings.set(true)>"Add a passkey"</button>
                    </div>
                </Show>
                {move || {
                    let on = captures.with(|c| c["listening"].as_array().cloned().unwrap_or_default());
                    (!on.is_empty()).then(|| {
                        let names: Vec<String> = on.iter().map(|d| d["label"].as_str().filter(|l| !l.is_empty()).or(d["id"].as_str()).unwrap_or_default().to_owned()).collect();
                        let ids: Vec<String> = on.iter().filter_map(|d| d["id"].as_str().map(str::to_owned)).collect();
                        view! {
                            <div class="banner listening" role="status">
                                <span>{format!("Hands-free listening is on: {}. Nothing heard makes a bot act; you'll get suggestions to accept.", names.join(", "))}</span>
                                <button on:click=move |_| {
                                    let ids = ids.clone();
                                    ctx.run(async move {
                                        for id in ids {
                                            api::post("/api/devices/hands-free", &json!({ "id": id, "on": false })).await?;
                                        }
                                        load_captures();
                                        Ok(())
                                    })
                                }>"Pause"</button>
                            </div>
                        }
                    })
                }}
                <Show when=move || bot.get().disabled>
                    <div class="banner">"This bot is disabled. Edit it to turn it back on."</div>
                </Show>
                <Log thread />
                <Composer thread />
            </main>
            <Show when=move || settings.get()>
                <Settings open=settings link_code />
            </Show>
            <Show when=move || ctx.bot_screen.get()>
                <BotScreen />
            </Show>
            <Show when=move || routines.get()>
                <Routines open=routines />
            </Show>
            <Show when=move || tickets.get()>
                <Tickets open=tickets />
            </Show>
            <Show when=move || decisions.get()>
                <Decisions open=decisions />
            </Show>
            <Show when=move || captures_open.get()>
                <Captures open=captures_open captures reload=Callback::new(move |_| load_captures()) />
            </Show>
            {move || editing.get().map(|bot| view! { <BotSheet bot editing /> })}
        </div>
    }
}

/// Create a bot, or edit one (PRD B-BOT-01).
#[component]
fn BotSheet(bot: Option<Bot>, editing: RwSignal<Option<Option<Bot>>>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = expect_context::<Desk>();
    let is_new = bot.is_none();
    let bot = bot.unwrap_or_else(|| Bot {
        scope: "private".into(),
        ..Bot::default()
    });
    let is_inbox = bot.slug == "inbox";
    let name = RwSignal::new(bot.name.clone());
    let remit = RwSignal::new(bot.remit.clone());
    let instructions = RwSignal::new(bot.instructions.clone());
    let model = RwSignal::new(bot.model.clone().unwrap_or_default());
    let thinking = RwSignal::new(bot.thinking.clone().unwrap_or_default());
    let team = RwSignal::new(bot.scope == "team");
    let disabled = RwSignal::new(bot.disabled);
    let save = move |ev: SubmitEvent| {
        ev.prevent_default();
        let model = model.get_untracked();
        let thinking = thinking.get_untracked();
        let edited = Bot {
            name: name.get_untracked(),
            remit: remit.get_untracked(),
            instructions: instructions.get_untracked(),
            model: (!model.trim().is_empty()).then_some(model),
            thinking: (!thinking.is_empty()).then_some(thinking),
            scope: if team.get_untracked() {
                "team"
            } else {
                "private"
            }
            .into(),
            disabled: disabled.get_untracked(),
            ..bot.clone()
        };
        ctx.run(async move {
            let path = if is_new {
                "/api/bots"
            } else {
                "/api/bots/update"
            };
            let saved: Bot = api::post(
                path,
                &serde_json::to_value(&edited).map_err(|e| e.to_string())?,
            )
            .await?
            .json()
            .await
            .map_err(|e| e.to_string())?;
            desk.load_bots(ctx);
            desk.selected.set(saved.slug);
            editing.set(None);
            Ok(())
        });
    };
    let thinking_levels = [
        "", "off", "minimal", "low", "medium", "high", "xhigh", "max",
    ];
    view! {
        <div class="overlay" on:keydown=move |ev: KeyboardEvent| if ev.key() == "Escape" { editing.set(None) }>
            <form class="sheet" role="dialog" aria-modal="true" aria-labelledby="bot-title" on:submit=save>
                <header>
                    <h2 id="bot-title">{if is_new { "New bot" } else { "Edit bot" }}</h2>
                    <button type="button" on:click=move |_| editing.set(None)>"Cancel"</button>
                </header>
                <label>"Name"<input required maxlength="40" bind:value=name autofocus /></label>
                <label>"What it's for (one line; used to route work to it)"
                    <input maxlength="200" bind:value=remit placeholder="Researches topics and writes short briefs" /></label>
                <label>"Instructions"<textarea rows=5 maxlength="8000" bind:value=instructions
                    placeholder="How it should work, what to avoid, who it works for"></textarea></label>
                <div class="row two">
                    <label>"Model"<input maxlength="100" bind:value=model placeholder="Orphus default" /></label>
                    <label>"Thinking"
                        // The chosen option is marked on the option itself: a select's value set
                        // before its options exist falls back to the first one.
                        <select on:change=move |ev| thinking.set(event_target_value(&ev))>
                            {thinking_levels.map(|t| view! {
                                <option value=t selected=move || thinking.get() == t>{if t.is_empty() { "Default" } else { t }}</option>
                            })}
                        </select>
                    </label>
                </div>
                <fieldset>
                    <legend>"Computer"</legend>
                    <label class="inline"><input type="radio" name="scope" prop:checked=move || !team.get()
                        on:change=move |_| team.set(false) />"Private: its own home"</label>
                    <label class="inline"><input type="radio" name="scope" prop:checked=move || team.get()
                        on:change=move |_| team.set(true) />"Team: also shares the team folder"</label>
                </fieldset>
                {(!is_new && !is_inbox).then(|| view! {
                    <label class="inline"><input type="checkbox" bind:checked=disabled />"Disabled: takes no new work"</label>
                })}
                <div class="row">
                    <button class="primary">{if is_new { "Create bot" } else { "Save" }}</button>
                </div>
            </form>
        </div>
    }
}

#[component]
fn Log(thread: Memo<ThreadView>) -> impl IntoView {
    let items = Memo::new(move |_| thread.with(|v| v.items.clone()));
    let streaming = Memo::new(move |_| thread.with(|v| v.streaming.clone()));
    let log = NodeRef::<leptos::html::Div>::new();
    Effect::new(move |_| {
        items.track();
        streaming.track();
        if let Some(el) = log.get() {
            el.set_scroll_top(el.scroll_height());
        }
    });
    view! {
        <div class="log" role="log" aria-live="polite" aria-label="Conversation" node_ref=log>
            // ponytail: the whole list re-renders when an item changes; key it when threads get long.
            {move || {
                let items = items.get();
                if items.is_empty() && streaming.get().is_none() {
                    return view! { <p class="empty">"Ask Orphus to do something."</p> }.into_any();
                }
                items.into_iter().map(item).collect_view().into_any()
            }}
            {move || streaming.get().map(|text| view! { <div class="msg assistant">{text}</div> })}
        </div>
    }
}

/// Bot text always goes in as text, never as HTML.
fn item(item: Item) -> AnyView {
    match item {
        Item::Message { role, text } => {
            let class = if role == Role::User {
                "msg user"
            } else {
                "msg assistant"
            };
            view! { <div class=class>{text}</div> }.into_any()
        }
        Item::Notice { text, error } => {
            view! { <p class="notice" class:error=error>{text}</p> }.into_any()
        }
        Item::Card { dialog, outcome } => view! { <Card dialog outcome /> }.into_any(),
    }
}

/// A button that sends one answer to a card.
fn choice(label: impl Into<String>, body: Value, class: &'static str) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let send = move |_| {
        let body = body.clone();
        ctx.run(async move { api::post("/api/dialogs/answer", &body).await.map(drop) });
    };
    view! { <button type="button" class=class on:click=send>{label.into()}</button> }
}

#[component]
fn Card(dialog: Dialog, outcome: Option<String>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = expect_context::<Desk>();
    let id = dialog.id;
    let open = outcome.is_none();
    let body = match dialog.kind {
        DialogKind::Approval {
            tool,
            input,
            uncertain,
        } => view! {
            <h2>{format!("Allow {} to use {tool}?", desk.bot().get_untracked().name)}</h2>
            {uncertain.then(|| view! {
                <p class="warn">"An interrupted attempt may already have run this. Check before allowing it again."</p>
            })}
            <pre>{serde_json::to_string_pretty(&input).unwrap_or_default()}</pre>
            {open.then(|| view! {
                <div class="row">
                    {choice("Allow once", json!({ "id": id, "decision": "allow" }), "primary")}
                    {choice(format!("Always allow {tool}"), json!({ "id": id, "decision": "always" }), "")}
                    {choice("Deny", json!({ "id": id, "decision": "deny" }), "danger")}
                </div>
            })}
        }
        .into_any(),
        DialogKind::Takeover { reason } => view! {
            <h2>{move || format!("{} needs you on its screen", desk.bot().get().name)}</h2>
            <p>{reason}</p>
            {open.then(|| view! {
                <div class="row">
                    <button type="button" class="primary" on:click=move |_| ctx.bot_screen.set(true)>"Open screen"</button>
                    {choice("Done", json!({ "id": id, "confirmed": true }), "")}
                    {choice("I can't", json!({ "id": id, "confirmed": false }), "")}
                </div>
            })}
        }
        .into_any(),
        DialogKind::Question {
            method,
            title,
            message,
            options,
        } => {
            let text = RwSignal::new(String::new());
            let answers = match method.as_str() {
                "select" => options
                    .into_iter()
                    .map(|o| choice(o.clone(), json!({ "id": id, "value": o }), ""))
                    .collect_view()
                    .into_any(),
                "confirm" => view! {
                    {choice("Yes", json!({ "id": id, "confirmed": true }), "primary")}
                    {choice("No", json!({ "id": id, "confirmed": false }), "")}
                }
                .into_any(),
                _ => {
                    let id = id.clone();
                    let send = move |_| {
                        let body = json!({ "id": id, "value": text.get_untracked() });
                        ctx.run(async move { api::post("/api/dialogs/answer", &body).await.map(drop) });
                    };
                    view! {
                        <textarea rows=3 aria-label="Your answer" bind:value=text></textarea>
                        <button type="button" class="primary" on:click=send>"Send answer"</button>
                    }
                    .into_any()
                }
            };
            let title = if title.is_empty() { "Orphus has a question".to_owned() } else { title };
            view! {
                <h2>{title}</h2>
                {message.map(|m| view! { <p>{m}</p> })}
                {open.then(|| view! {
                    <div class="row">
                        {answers}
                        {choice("Dismiss", json!({ "id": id }), "")}
                    </div>
                })}
            }
            .into_any()
        }
    };
    view! {
        <section class="card" aria-label="Needs your answer">
            {body}
            {outcome.map(|o| view! { <p class="outcome">{o}</p> })}
        </section>
    }
}

#[component]
fn Composer(thread: Memo<ThreadView>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = expect_context::<Desk>();
    let text = RwSignal::new(String::new());
    let busy = RwSignal::new(false);
    let running = Memo::new(move |_| thread.with(|v| v.run != RunState::Idle));
    let send = move || {
        let t = text.get_untracked().trim().to_owned();
        if t.is_empty() || busy.get_untracked() {
            return;
        }
        busy.set(true);
        let bot = desk.selected.get_untracked();
        ctx.run(async move {
            let sent = api::post("/api/messages", &json!({ "bot": bot, "text": t })).await;
            busy.set(false);
            sent?;
            text.set(String::new());
            Ok(())
        });
    };
    let stop = move |_| {
        let bot = desk.selected.get_untracked();
        ctx.run(async move {
            api::post("/api/runs/cancel", &json!({ "bot": bot }))
                .await
                .map(drop)
        })
    };
    view! {
        <div class="composer">
            <form on:submit=move |ev: SubmitEvent| {
                ev.prevent_default();
                send();
            }>
                <textarea rows=1 aria-label="Message" placeholder=move || format!("Message {}", desk.bot().get().name) title="Enter to send, Shift+Enter for a new line"
                    bind:value=text
                    on:keydown=move |ev: KeyboardEvent| {
                        if ev.key() == "Enter" && !ev.shift_key() {
                            ev.prevent_default();
                            send();
                        }
                    }></textarea>
                <Show when=move || running.get()>
                    <button type="button" on:click=stop>"Stop"</button>
                </Show>
                <button class="primary" disabled=move || busy.get()>"Send"</button>
            </form>
        </div>
    }
}

/// The bot's screen, watched live; "Take control" lets your mouse and keyboard through.
#[component]
fn BotScreen() -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = expect_context::<Desk>();
    let bot = desk.bot();
    let control = RwSignal::new(false);
    let ended = RwSignal::new(false);
    let host = NodeRef::<leptos::html::Div>::new();
    let rfb = StoredValue::new_local(None::<JsValue>);
    Effect::new(move |_| {
        let Some(el) = host.get() else { return };
        if rfb.with_value(Option::is_some) {
            return;
        }
        let on_end = Closure::<dyn Fn()>::new(move || ended.set(true));
        let slug = bot.get_untracked().slug;
        let screen = api::open_screen(&el, &slug, true, on_end.as_ref().unchecked_ref());
        // ponytail: one small closure per opened panel is left for the page's lifetime.
        on_end.forget();
        rfb.set_value(Some(screen));
    });
    Effect::new(move |_| {
        let view_only = !control.get();
        rfb.with_value(|r| {
            if let Some(r) = r {
                api::set_view_only(r, view_only);
            }
        });
    });
    let close = move |_| {
        rfb.with_value(|r| {
            if let Some(r) = r {
                api::close_screen(r);
            }
        });
        ctx.bot_screen.set(false);
    };
    view! {
        <div class="overlay">
            <section class="sheet screen" role="dialog" aria-modal="true" aria-labelledby="screen-title">
                <header>
                    <h2 id="screen-title">{move || format!("{}'s screen", bot.get().name)}</h2>
                    <div class="row">
                        <button class:primary=move || control.get() aria-pressed=move || control.get().to_string()
                            on:click=move |_| control.update(|c| *c = !*c)>
                            {move || if control.get() { "Release control" } else { "Take control" }}
                        </button>
                        <button on:click=close>"Close"</button>
                    </div>
                </header>
                <p class="muted" role="status">{move || {
                    if ended.get() {
                        "The screen closed. The bot's computer may have no screen, or its node went away."
                    } else if control.get() {
                        "You have control: your mouse and keyboard go to the bot's computer."
                    } else {
                        "Watching. Take control to use the screen yourself."
                    }
                }}</p>
                <div class="vnc" node_ref=host></div>
            </section>
        </div>
    }
}

/// A ticket, as the server lists it (server `tickets::Ticket`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Ticket {
    id: i64,
    title: String,
    body: String,
    status: String,
    urgency: String,
    bot: Option<String>,
    act_now: bool,
}

const STATUSES: [(&str, &str); 5] = [
    ("todo", "To do"),
    ("doing", "Doing"),
    ("review", "Review"),
    ("blocked", "Blocked"),
    ("done", "Done"),
];
const URGENCIES: [(&str, &str); 4] = [
    ("now", "Now"),
    ("hour", "Within the hour"),
    ("today", "Today"),
    ("whenever", "Whenever"),
];

/// The ticket board (PRD B-TKT-01..03).
#[component]
fn Tickets(open: RwSignal<bool>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = expect_context::<Desk>();
    let list = RwSignal::new(Vec::<Ticket>::new());
    let title = RwSignal::new(String::new());
    let body = RwSignal::new(String::new());
    let load = move || {
        ctx.run(async move {
            list.set(api::get("/api/tickets").await?);
            Ok(())
        })
    };
    // Reload whenever a thread changes, so tickets move as their runs do, and every few
    // seconds, for changes no thread sees (System 1 filling in a new ticket).
    Effect::new(move |_| {
        desk.threads.track();
        load();
    });
    if let Ok(timer) = set_interval_with_handle(load, std::time::Duration::from_secs(4)) {
        on_cleanup(move || timer.clear());
    }
    let create = move |ev: SubmitEvent| {
        ev.prevent_default();
        let new = json!({ "title": title.get_untracked(), "body": body.get_untracked() });
        ctx.run(async move {
            api::post("/api/tickets", &new).await?;
            title.set(String::new());
            body.set(String::new());
            load();
            Ok(())
        })
    };
    let save = move |t: Ticket| {
        ctx.run(async move {
            api::post(
                "/api/tickets/update",
                &serde_json::to_value(&t).map_err(|e| e.to_string())?,
            )
            .await?;
            load();
            Ok(())
        })
    };
    let column = move |status: &'static str| -> Vec<Ticket> {
        list.get()
            .into_iter()
            .filter(|t| t.status == status)
            .collect()
    };
    let start = move |id: i64| {
        ctx.run(async move {
            api::post("/api/tickets/start", &json!({ "id": id })).await?;
            load();
            Ok(())
        })
    };
    view! {
        <div class="overlay" on:keydown=move |ev: KeyboardEvent| if ev.key() == "Escape" { open.set(false) }>
            <section class="sheet board-sheet" role="dialog" aria-modal="true" aria-labelledby="tickets-title">
                <header>
                    <h2 id="tickets-title">"Tickets"</h2>
                    <button autofocus on:click=move |_| open.set(false)>"Close"</button>
                </header>
                <form class="row new-ticket" on:submit=create>
                    <input required maxlength="200" aria-label="New ticket" placeholder="New ticket: what needs doing?" bind:value=title style="flex: 2" />
                    <input maxlength="8000" aria-label="Details" placeholder="Details (optional)" bind:value=body style="flex: 3" />
                    <button class="primary">"Add"</button>
                </form>
                <div class="board">
                    {STATUSES.map(|(status, label)| view! {
                        <section class="column" aria-label=label>
                            <h3>{label}" "<span class="muted">{move || column(status).len()}</span></h3>
                            <For each=move || column(status)
                                key=|t| (t.id, t.status.clone(), t.bot.clone(), t.urgency.clone())
                                children=move |t| {
                                    let (for_bot, for_urgency, for_status) = (t.clone(), t.clone(), t.clone());
                                    let can_start = t.bot.is_some() && t.status == "todo";
                                    let id = t.id;
                                    view! {
                                        <article class="ticket" class:urgent=t.urgency == "now" || t.urgency == "hour">
                                            <strong>{format!("OB-{} {}", t.id, t.title)}</strong>
                                            {(!t.body.is_empty()).then(|| view! { <p class="muted">{t.body.clone()}</p> })}
                                            <select aria-label="Bot" on:change=move |ev| {
                                                let v = event_target_value(&ev);
                                                save(Ticket { bot: (!v.is_empty()).then_some(v), ..for_bot.clone() });
                                            }>
                                                <option value="" selected=t.bot.is_none()>"Unassigned"</option>
                                                {desk.bots.get_untracked().into_iter().filter(|b| !b.disabled).map(|b| {
                                                    let chosen = t.bot.as_deref() == Some(b.slug.as_str());
                                                    view! { <option value=b.slug.clone() selected=chosen>{b.name.clone()}</option> }
                                                }).collect_view()}
                                            </select>
                                            <select aria-label="Urgency" on:change=move |ev| {
                                                save(Ticket { urgency: event_target_value(&ev), ..for_urgency.clone() });
                                            }>
                                                {URGENCIES.map(|(u, l)| view! { <option value=u selected=t.urgency == u>{l}</option> })}
                                            </select>
                                            <select aria-label="Status" on:change=move |ev| {
                                                save(Ticket { status: event_target_value(&ev), ..for_status.clone() });
                                            }>
                                                {STATUSES.map(|(st, l)| view! { <option value=st selected=t.status == st>{l}</option> })}
                                            </select>
                                            {can_start.then(|| view! { <button class="primary" on:click=move |_| start(id)>"Start"</button> })}
                                        </article>
                                    }
                                } />
                        </section>
                    })}
                </div>
            </section>
        </div>
    }
}

/// A routine, as the server lists it (server `routines::Routine`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Routine {
    id: i64,
    bot: String,
    name: String,
    prompt: String,
    cron: Option<String>,
    timezone: String,
    once_at: Option<String>,
    webhook: bool,
    preflight: bool,
    active: bool,
    next_at: Option<String>,
    last_fired_at: Option<String>,
}

impl Routine {
    fn when(&self) -> String {
        let mut parts = Vec::new();
        if let Some(cron) = &self.cron {
            let preset = PRESETS
                .iter()
                .find(|(c, _)| c == cron)
                .map(|(_, l)| (*l).to_owned());
            parts.push(preset.unwrap_or_else(|| format!("cron {cron}")));
        }
        if let Some(once) = &self.once_at {
            parts.push(format!("once at {}", once.replace('T', " ")));
        }
        if self.webhook {
            parts.push("webhook".to_owned());
        }
        parts.join(" · ")
    }
}

/// Schedules most people want, as cron (read in the routine's time zone).
const PRESETS: [(&str, &str); 5] = [
    ("0 8 * * *", "every day at 8:00"),
    ("0 8 * * 1-5", "weekdays at 8:00"),
    ("0 18 * * 5", "Fridays at 18:00"),
    ("0 * * * *", "every hour"),
    ("*/15 * * * *", "every 15 minutes"),
];

/// Routines: what each bot does on its own, and when (PRD B-RTN-01..03).
#[component]
fn Routines(open: RwSignal<bool>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = expect_context::<Desk>();
    let list = RwSignal::new(Vec::<Routine>::new());
    let editing = RwSignal::new(None::<Routine>);
    let hook_url = RwSignal::new(None::<String>);
    let load = move || {
        ctx.run(async move {
            list.set(api::get("/api/routines").await?);
            Ok(())
        })
    };
    load();
    let blank = move || Routine {
        bot: desk.selected.get_untracked(),
        cron: Some(PRESETS[0].0.to_owned()),
        timezone: api::time_zone(),
        active: true,
        ..Routine::default()
    };
    let act = move |path: &'static str, id: i64, done: &'static str| {
        ctx.run(async move {
            api::post(path, &json!({ "id": id })).await?;
            ctx.toast.set(done.into());
            load();
            Ok(())
        })
    };
    let bot_name = move |slug: &str| {
        desk.bots
            .with(|b| b.iter().find(|b| b.slug == slug).map(|b| b.name.clone()))
            .unwrap_or_else(|| slug.to_owned())
    };
    view! {
        <div class="overlay" on:keydown=move |ev: KeyboardEvent| if ev.key() == "Escape" { open.set(false) }>
            <section class="sheet" role="dialog" aria-modal="true" aria-labelledby="routines-title">
                <header>
                    <h2 id="routines-title">"Routines"</h2>
                    <button autofocus on:click=move |_| open.set(false)>"Close"</button>
                </header>
                <p class="muted">"Things a bot does on its own: on a schedule, once, or when something calls its webhook."</p>
                <ul>
                    <For each=move || list.get() key=|r| (r.id, r.active, r.next_at.clone(), r.last_fired_at.clone()) children=move |r| {
                        let (id, edit) = (r.id, r.clone());
                        let next = r.next_at.as_deref().map(|n| n.chars().take(16).collect::<String>()).unwrap_or_else(|| "—".into());
                        view! {
                            <li class="routine" class:off=!r.active>
                                <span>
                                    {r.name.clone()}
                                    <small>{format!("{} · {}{}", bot_name(&r.bot), r.when(), if r.active { format!(" · next {next}") } else { " · paused".to_owned() })}</small>
                                </span>
                                <span class="row">
                                    <button on:click=move |_| act("/api/routines/run", id, "Started.")>"Run now"</button>
                                    <button on:click=move |_| { hook_url.set(None); editing.set(Some(edit.clone())); }>"Edit"</button>
                                    <button class="danger" on:click=move |_| if confirmed("Delete this routine?") { act("/api/routines/delete", id, "Deleted.") }>"Delete"</button>
                                </span>
                            </li>
                        }
                    } />
                </ul>
                {move || list.with(Vec::is_empty).then(|| view! { <p class="muted">"No routines yet."</p> })}
                {move || hook_url.get().map(|url| view! {
                    <div class="card">
                        <h2>"Webhook address"</h2>
                        <p class="muted">"Shown once. Anything that POSTs here starts the routine; what it sends is given to the bot as data."</p>
                        <pre>{url}</pre>
                    </div>
                })}
                {move || match editing.get() {
                    Some(r) => view! { <RoutineForm routine=r editing hook_url saved=Callback::new(move |_| load()) /> }.into_any(),
                    None => view! { <button class="primary" on:click=move |_| { hook_url.set(None); editing.set(Some(blank())); }>"New routine"</button> }.into_any(),
                }}
            </section>
        </div>
    }
}

#[component]
fn RoutineForm(
    routine: Routine,
    editing: RwSignal<Option<Routine>>,
    hook_url: RwSignal<Option<String>>,
    saved: Callback<()>,
) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let desk = expect_context::<Desk>();
    // "schedule", "once" or "webhook".
    let mode = RwSignal::new(if routine.cron.is_some() {
        "schedule"
    } else if routine.once_at.is_some() {
        "once"
    } else {
        "webhook"
    });
    let name = RwSignal::new(routine.name.clone());
    let bot = RwSignal::new(routine.bot.clone());
    let prompt = RwSignal::new(routine.prompt.clone());
    let cron = RwSignal::new(
        routine
            .cron
            .clone()
            .unwrap_or_else(|| PRESETS[0].0.to_owned()),
    );
    let once = RwSignal::new(routine.once_at.clone().unwrap_or_default());
    let timezone = RwSignal::new(routine.timezone.clone());
    let webhook = RwSignal::new(routine.webhook);
    let preflight = RwSignal::new(routine.preflight);
    let active = RwSignal::new(routine.active);
    let is_new = routine.id == 0;
    let save = move |ev: SubmitEvent| {
        ev.prevent_default();
        let m = mode.get_untracked();
        let body = Routine {
            name: name.get_untracked(),
            bot: bot.get_untracked(),
            prompt: prompt.get_untracked(),
            cron: (m == "schedule").then(|| cron.get_untracked()),
            once_at: (m == "once").then(|| once.get_untracked()),
            timezone: timezone.get_untracked(),
            webhook: m == "webhook" || webhook.get_untracked(),
            preflight: preflight.get_untracked(),
            active: active.get_untracked(),
            ..routine.clone()
        };
        ctx.run(async move {
            let res: serde_json::Value = api::post(
                "/api/routines",
                &serde_json::to_value(&body).map_err(|e| e.to_string())?,
            )
            .await?
            .json()
            .await
            .map_err(|e| e.to_string())?;
            if let Some(why) = res["error"].as_str() {
                return Err(why.to_owned());
            }
            if let (Some(path), Some(w)) = (res["hook_path"].as_str(), web_sys::window()) {
                hook_url.set(Some(format!(
                    "{}{path}",
                    w.location().origin().unwrap_or_default()
                )));
            }
            editing.set(None);
            saved.run(());
            Ok(())
        });
    };
    view! {
        <form class="card routine-form" on:submit=save>
            <h2>{if is_new { "New routine" } else { "Edit routine" }}</h2>
            <label>"Name"<input required maxlength="60" bind:value=name placeholder="Morning customer check" /></label>
            <label>"Bot"
                <select on:change=move |ev| bot.set(event_target_value(&ev))>
                    <For each=move || desk.bots.get().into_iter().filter(|b| !b.disabled) key=|b| b.slug.clone()
                        children=move |b| {
                            let slug = b.slug.clone();
                            view! { <option value=b.slug.clone() selected=move || bot.get() == slug>{b.name.clone()}</option> }
                        } />
                </select>
            </label>
            <label>"Instruction"<textarea rows=3 required maxlength="8000" bind:value=prompt
                placeholder="Check my inbox for anything from customers and summarise it"></textarea></label>
            <fieldset>
                <legend>"When"</legend>
                {[("schedule", "On a schedule"), ("once", "Once"), ("webhook", "Only when its webhook is called")].map(|(m, label)| view! {
                    <label class="inline"><input type="radio" name="mode" prop:checked=move || mode.get() == m on:change=move |_| mode.set(m) />{label}</label>
                })}
            </fieldset>
            <Show when=move || mode.get() == "schedule">
                <label>"Schedule"
                    <select on:change=move |ev| { let v = event_target_value(&ev); if !v.is_empty() { cron.set(v) } }>
                        {PRESETS.map(|(c, l)| view! { <option value=c selected=move || cron.get() == c>{l}</option> })}
                        <option value="" selected=move || !PRESETS.iter().any(|(c, _)| *c == cron.get())>"Custom (cron)"</option>
                    </select>
                </label>
                <label>"Cron (minute hour day month weekday)"<input bind:value=cron /></label>
            </Show>
            <Show when=move || mode.get() == "once">
                <label>"At"<input type="datetime-local" bind:value=once /></label>
            </Show>
            <Show when=move || mode.get() != "webhook">
                <label>"Time zone"<input bind:value=timezone /></label>
                <label class="inline"><input type="checkbox" bind:checked=webhook />"Also give it a webhook"</label>
            </Show>
            <label class="inline"><input type="checkbox" bind:checked=preflight />"Ask System 1 first, and skip runs with nothing new"</label>
            <label class="inline"><input type="checkbox" bind:checked=active />"Active"</label>
            <div class="row">
                <button class="primary">"Save routine"</button>
                <button type="button" on:click=move |_| editing.set(None)>"Cancel"</button>
            </div>
        </form>
    }
}

/// A System 1 receipt (DESIGN §7.6).
#[derive(Clone, Deserialize, PartialEq)]
struct Decision {
    id: i64,
    catalogue: String,
    state: Option<String>,
    abstained: bool,
    threshold: f32,
    confidence: Option<f32>,
    latency_ms: i32,
    outcome: String,
    created_at: String,
    label: Option<Value>,
    agrees: Option<bool>,
    label_source: Option<String>,
}

/// Things heard in hands-free mode, waiting to be accepted or dismissed (DESIGN §10).
#[component]
fn Captures(
    open: RwSignal<bool>,
    captures: RwSignal<Value>,
    reload: Callback<()>,
) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let devices = RwSignal::new(Vec::<Value>::new());
    let load_devices = move || {
        ctx.run(async move {
            let d: Value = api::get("/api/devices").await?;
            devices.set(d["devices"].as_array().cloned().unwrap_or_default());
            Ok(())
        })
    };
    load_devices();
    let act = move |path: &'static str, id: i64| {
        ctx.run(async move {
            api::post(path, &json!({ "id": id })).await?;
            reload.run(());
            Ok(())
        })
    };
    view! {
        <div class="overlay" on:keydown=move |ev: KeyboardEvent| if ev.key() == "Escape" { open.set(false) }>
            <section class="sheet" role="dialog" aria-modal="true" aria-labelledby="captures-title">
                <header>
                    <h2 id="captures-title">"Captures"</h2>
                    <button autofocus on:click=move |_| open.set(false)>"Close"</button>
                </header>
                <p class="muted">"With hands-free on, what you say and hear is turned into suggestions. Nothing becomes a task until you accept it; no audio is kept, and the words are deleted after a week."</p>
                {move || (captures.with(|c| c["allowed"] == false)).then(|| view! { <p class="warn">"Hands-free is switched off on the server (ORPHUSBOT_HANDS_FREE_ALLOWED)."</p> })}
                <ul>
                    {move || devices.get().into_iter().map(|d| {
                        let id = d["id"].as_str().unwrap_or_default().to_owned();
                        let on = d["hands_free"] == true;
                        let label = d["label"].as_str().filter(|l| !l.is_empty()).unwrap_or(&id).to_owned();
                        view! {
                            <li><span>{label}<small>{if on { "hands-free on" } else { "hands-free off" }}</small></span>
                                <button class:primary=!on on:click=move |_| {
                                    let id = id.clone();
                                    ctx.run(async move {
                                        api::post("/api/devices/hands-free", &json!({ "id": id, "on": !on })).await?;
                                        load_devices();
                                        reload.run(());
                                        Ok(())
                                    })
                                }>{if on { "Pause" } else { "Turn on" }}</button></li>
                        }
                    }).collect_view()}
                </ul>
                <ul class="proposals">
                    {move || captures.with(|c| c["proposals"].as_array().cloned().unwrap_or_default()).into_iter().map(|p| {
                        let id = p["id"].as_i64().unwrap_or_default();
                        let open_now = p["state"] == "proposed";
                        let s = |k: &str| p[k].as_str().unwrap_or_default().to_owned();
                        let meta: Vec<String> = [("with", s("who")), ("due", s("due"))].into_iter()
                            .filter(|(_, v)| !v.is_empty()).map(|(k, v)| format!("{k} {v}")).collect();
                        view! {
                            <li class:closed=!open_now>
                                <span>
                                    <strong>{format!("{} · {}", s("kind"), s("title"))}</strong>
                                    {(!s("detail").is_empty()).then(|| view! { <small>{s("detail")}</small> })}
                                    {(!meta.is_empty()).then(|| view! { <small>{meta.join(" · ")}</small> })}
                                    {(!s("quote").is_empty()).then(|| view! { <small class="quote">{format!("“{}”", s("quote"))}</small> })}
                                    {(!open_now).then(|| view! { <small>{s("state")}</small> })}
                                </span>
                                {open_now.then(|| view! {
                                    <span class="row">
                                        <button class="primary" on:click=move |_| act("/api/proposals/accept", id)>"Accept"</button>
                                        <button on:click=move |_| act("/api/proposals/dismiss", id)>"Dismiss"</button>
                                    </span>
                                })}
                            </li>
                        }
                    }).collect_view()}
                </ul>
                {move || captures.with(|c| c["proposals"].as_array().is_none_or(Vec::is_empty)).then(|| view! { <p class="muted">"No captures yet."</p> })}
            </section>
        </div>
    }
}

fn catalogue_name(catalogue: &str) -> &'static str {
    match catalogue {
        "triage" => "Routing",
        "gate" => "Tool calls",
        "preflight" => "Routines",
        _ => "Other",
    }
}

/// System 1's receipts and how well it's doing (PRD B-CLI-03, DESIGN §7.5–§7.6).
#[component]
fn Decisions(open: RwSignal<bool>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let list = RwSignal::new(Vec::<Decision>::new());
    let health = RwSignal::new(Vec::<Value>::new());
    let filter = RwSignal::new(String::new());
    let calibrations = RwSignal::new(Vec::<Value>::new());
    let note = RwSignal::new(String::new());
    ctx.run(async move {
        list.set(api::get("/api/decisions").await?);
        health.set(api::get("/api/decisions/health").await?);
        calibrations.set(api::get("/api/decisions/calibrations").await?);
        Ok(())
    });
    // Apply, roll back or fit, then show the calibrations as they now are.
    let change = move |path: &'static str, body: Value| {
        ctx.run(async move {
            let res: Value = api::post(path, &body)
                .await?
                .json()
                .await
                .unwrap_or_default();
            if path.ends_with("/fit") {
                note.set(match res["model"].is_null() {
                    true => format!(
                        "Not enough labels to fit yet: {}.",
                        label_counts(&res["report"])
                    ),
                    false => {
                        "Fitted. See how it does on your newest labels below, then apply it.".into()
                    }
                });
            }
            calibrations.set(api::get("/api/decisions/calibrations").await?);
            Ok(())
        })
    };
    let shown = move || -> Vec<Decision> {
        let f = filter.get();
        list.get()
            .into_iter()
            .filter(|d| f.is_empty() || d.catalogue == f)
            .collect()
    };
    view! {
        <div class="overlay" on:keydown=move |ev: KeyboardEvent| if ev.key() == "Escape" { open.set(false) }>
            <section class="sheet" role="dialog" aria-modal="true" aria-labelledby="decisions-title">
                <header>
                    <h2 id="decisions-title">"Decisions"</h2>
                    <button autofocus on:click=move |_| open.set(false)>"Close"</button>
                </header>
                <p class="muted">"What System 1 (Laya) decided. It only acts when it's sure enough; otherwise you're asked. Your approvals and corrections are kept as labels to calibrate it."</p>
                <ul class="health">
                    {move || health.get().into_iter().map(|h| {
                        let asked = h["asked"].as_i64().unwrap_or(0);
                        let labelled = h["labelled"].as_i64().unwrap_or(0);
                        let agree = if labelled > 0 { format!(" · agrees with you {}%", h["agreed"].as_i64().unwrap_or(0) * 100 / labelled) } else { String::new() };
                        let latency = h["latency_ms"].as_f64().map(|l| format!(" · {:.1} s average", l / 1000.0)).unwrap_or_default();
                        view! { <li><span><strong>{catalogue_name(h["catalogue"].as_str().unwrap_or_default())}</strong>
                            <small>{format!("{asked} asked · {} abstained · {labelled} labelled{agree}{latency}", h["abstained"].as_i64().unwrap_or(0))}</small></span></li> }
                    }).collect_view()}
                </ul>
                <h3>"Calibration"</h3>
                <p class="muted">"Fitting sets how sure System 1 must be from your labels, so it's wrong at most 1 time in 10 when picking a bot and 1 in 20 when letting a tool call through (never less than 90% sure). It's checked on your newest labels, which it doesn't learn from. Nothing changes until you apply it."</p>
                <div class="row">
                    <button on:click=move |_| change("/api/decisions/fit", json!({}))>"Fit from labels"</button>
                    {move || calibrations.with(|c| c.iter().any(|c| c["active"] == true)).then(|| view! {
                        <button on:click=move |_| change("/api/decisions/rollback", json!({}))>"Roll back"</button>
                    })}
                </div>
                {move || (!note.get().is_empty()).then(|| view! { <p role="status">{note.get()}</p> })}
                <ul class="calibrations">
                    {move || calibrations.get().into_iter().map(|c| {
                        let id = c["id"].as_i64().unwrap_or_default();
                        let active = c["active"] == true;
                        let when = day(c["fitted_at"].as_str().unwrap_or_default());
                        view! {
                            <li>
                                <span>
                                    <strong>{format!("Calibration {id}")}</strong>
                                    <small>{if active { format!("fitted {when} · in use") } else { format!("fitted {when}") }}</small>
                                    {calibration_lines(&c).into_iter().map(|l| view! { <small>{l}</small> }).collect_view()}
                                </span>
                                {(!active).then(|| view! {
                                    <button on:click=move |_| change("/api/decisions/apply", json!({ "id": id }))>"Apply"</button>
                                })}
                            </li>
                        }
                    }).collect_view()}
                </ul>
                <div class="row">
                    {[("", "All"), ("triage", "Routing"), ("gate", "Tool calls"), ("preflight", "Routines")].map(|(c, l)| view! {
                        <button class:primary=move || filter.get() == c aria-pressed=move || (filter.get() == c).to_string()
                            on:click=move |_| filter.set(c.to_owned())>{l}</button>
                    })}
                </div>
                <ul class="decisions">
                    <For each=shown key=|d| d.id children=move |d| {
                        let state: String = d.state.clone().unwrap_or_default().chars().take(120).collect();
                        let label = d.label_source.clone().map(|source| {
                            let verdict = if d.agrees == Some(true) { "System 1 agreed" } else { "System 1 had it differently" };
                            format!("You {source} · {verdict}")
                        });
                        view! {
                            <li>
                                <span>{format!("{}: {}", catalogue_name(&d.catalogue), d.summary())}
                                    <small>{format!("{} · {state}", day(&d.created_at))}</small>
                                    {label.map(|l| view! { <small class="label">{l}</small> })}
                                </span>
                            </li>
                        }
                    } />
                </ul>
                {move || list.with(Vec::is_empty).then(|| view! { <p class="muted">"No decisions yet. Turn System 1 on with ORPHUSBOT_LAYA_URL."</p> })}
            </section>
        </div>
    }
}

fn question_name(key: &str) -> &'static str {
    match key {
        "triage.bot" => "Which bot",
        "gate.verdict" => "Tool calls",
        _ => "Other",
    }
}

/// "Which bot has 12 of 30 labels, Tool calls has 3 of 30 labels".
fn label_counts(report: &Value) -> String {
    let counts = report.as_object().into_iter().flatten();
    let parts: Vec<String> = counts
        .map(|(k, v)| {
            format!(
                "{} has {} of {} labels",
                question_name(k),
                v["labels"],
                v["needs"]
            )
        })
        .collect();
    parts.join(", ")
}

/// One line per question: the new threshold and how it did on the held-out labels.
fn calibration_lines(c: &Value) -> Vec<String> {
    let pct = |v: &Value| v.as_f64().unwrap_or(0.0) * 100.0;
    let report = c["report"].as_object().into_iter().flatten();
    report
        .map(|(k, v)| {
            let name = question_name(k);
            let (b, a) = (&v["before"], &v["after"]);
            if a.is_null() {
                return format!("{name}: kept as it was ({} of {} labels)", v["labels"], v["needs"]);
            }
            format!(
                "{name}: needs {:.0}% sure (was {:.0}%). On your newest {} labels it would act {} times with {} wrong (was {} with {} wrong).",
                pct(&a["threshold"]), pct(&b["threshold"]), v["held_out"], a["accepted"], a["errors"], b["accepted"], b["errors"]
            )
        })
        .collect()
}

impl Decision {
    /// "Sent to Researcher · 92% sure (needs 85%) · 0.4 s".
    fn summary(&self) -> String {
        let sure = match (self.abstained, self.confidence) {
            (true, _) => "abstained".to_owned(),
            (false, Some(c)) => format!(
                "{:.0}% sure (needs {:.0}%)",
                c * 100.0,
                self.threshold * 100.0
            ),
            (false, None) => "no confidence".to_owned(),
        };
        format!(
            "{} · {sure} · {:.1} s",
            self.outcome,
            f64::from(self.latency_ms) / 1000.0
        )
    }
}

#[derive(Clone, Deserialize, PartialEq)]
struct Passkey {
    id: i64,
    name: String,
    created_at: String,
    last_used_at: Option<String>,
}

#[derive(Clone, Deserialize, PartialEq)]
struct Node {
    id: i64,
    name: String,
    created_at: String,
    last_seen_at: Option<String>,
}

/// Reads `?name=…` (a device link code, or the bot a push opens) and clears the
/// query from the address bar.
fn take_param(name: &str) -> Option<String> {
    let w = web_sys::window()?;
    let search = w.location().search().ok()?;
    let code = web_sys::UrlSearchParams::new_with_str(&search)
        .ok()?
        .get(name)?;
    if let Ok(history) = w.history() {
        let _ = history.replace_state_with_url(&JsValue::NULL, "", Some("/"));
    }
    Some(code)
}

/// "2026-10-16 03:35:05+00" → "2026-10-16".
fn day(timestamp: &str) -> &str {
    timestamp.get(..10).unwrap_or(timestamp)
}

fn confirmed(question: &str) -> bool {
    web_sys::window().is_some_and(|w| w.confirm_with_message(question).unwrap_or(false))
}

#[component]
fn Settings(open: RwSignal<bool>, link_code: RwSignal<String>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let passkeys = RwSignal::new(Vec::<Passkey>::new());
    let nodes = RwSignal::new(Vec::<Node>::new());
    let wearables = RwSignal::new(Value::Null);
    let usage = RwSignal::new(Value::Null);
    let pairing = RwSignal::new(None::<String>);
    let name = RwSignal::new("This device".to_owned());
    let command = RwSignal::new(None::<String>);

    let load = move || {
        ctx.run(async move {
            passkeys.set(api::get("/api/passkeys").await?);
            nodes.set(api::get("/api/nodes").await?);
            wearables.set(api::get("/api/devices").await?);
            usage.set(api::get("/api/usage").await?);
            Ok(())
        })
    };
    load();
    let remove = move |path: &'static str, id: i64, question: &'static str| {
        if !confirmed(question) {
            return;
        }
        ctx.run(async move {
            api::post(path, &json!({ "id": id })).await?;
            // Removing this device's own passkey signs it out.
            ctx.reload();
            load();
            Ok(())
        })
    };
    let add_passkey = move |_| {
        ctx.run(async move {
            api::add_passkey(&name.get_untracked()).await?;
            ctx.needs_passkey.set(false);
            ctx.toast.set("Passkey added.".into());
            load();
            Ok(())
        })
    };
    let add_node = move |_| {
        ctx.run(async move {
            let res: Value = api::post("/api/nodes/code", &json!({}))
                .await?
                .json()
                .await
                .map_err(|e| e.to_string())?;
            let code = res["code"].as_str().unwrap_or_default();
            command.set(Some(format!("orphusbot-node enrol {code}")));
            Ok(())
        })
    };
    let copy = move |_| {
        if let (Some(w), Some(c)) = (web_sys::window(), command.get_untracked()) {
            let _ = w.navigator().clipboard().write_text(&c);
            ctx.toast.set("Copied.".into());
        }
    };
    // Linking a device: look the code up first, so the owner sees what they approve.
    let waiting_device = RwSignal::new(None::<(String, String)>);
    let check_link = move || {
        let code = link_code.get_untracked();
        if code.trim().is_empty() {
            return;
        }
        ctx.run(async move {
            let path = format!("/api/links/{}", js_sys::encode_uri_component(code.trim()));
            let found: Value = api::get(&path).await?;
            let code = found["user_code"].as_str().unwrap_or_default().to_owned();
            let label = found["label"].as_str().unwrap_or_default().to_owned();
            waiting_device.set(Some((code, label)));
            Ok(())
        })
    };
    check_link();
    let approve_link = move |_| {
        let Some((code, _)) = waiting_device.get_untracked() else {
            return;
        };
        ctx.run(async move {
            api::post("/api/links/approve", &json!({ "user_code": code })).await?;
            waiting_device.set(None);
            link_code.set(String::new());
            ctx.toast.set("Device linked.".into());
            Ok(())
        })
    };
    let sign_out = move |_| {
        ctx.run(async move {
            api::post("/api/logout", &json!({})).await?;
            if let Some(w) = web_sys::window() {
                let _ = w.location().reload();
            }
            Ok(())
        })
    };

    view! {
        <div class="overlay" on:keydown=move |ev: KeyboardEvent| {
            if ev.key() == "Escape" {
                open.set(false);
            }
        }>
            <section class="sheet" role="dialog" aria-modal="true" aria-labelledby="settings-title">
                <header>
                    <h2 id="settings-title">"Settings"</h2>
                    <button autofocus on:click=move |_| open.set(false)>"Close"</button>
                </header>
                <div>
                    <h3>"Passkeys"</h3>
                    <ul>
                        <For each=move || passkeys.get() key=|p| p.id children=move |p| {
                            let used = p.last_used_at.as_deref().map(day).unwrap_or("never").to_owned();
                            view! {
                                <li>
                                    <span>{p.name}<small>{format!("Added {} · last used {used}", day(&p.created_at))}</small></span>
                                    <button class="danger" on:click=move |_| remove("/api/passkeys/remove", p.id,
                                        "Remove this passkey? Every device signed in with it is signed out.")>"Remove"</button>
                                </li>
                            }
                        } />
                    </ul>
                    <div class="row">
                        <input aria-label="Passkey name" maxlength="60" bind:value=name style="flex: 1" />
                        <button class="primary" on:click=add_passkey>"Add a passkey"</button>
                    </div>
                </div>
                <div>
                    <h3>"Nodes"</h3>
                    <ul>
                        <For each=move || nodes.get() key=|n| n.id children=move |n| {
                            let seen = n.last_seen_at.as_deref().map(day).unwrap_or("never").to_owned();
                            view! {
                                <li>
                                    <span>{n.name}<small>{format!("Enrolled {} · last seen {seen}", day(&n.created_at))}</small></span>
                                    <button class="danger" on:click=move |_| remove("/api/nodes/remove", n.id,
                                        "Remove this node? It is disconnected and can't come back without enrolling again.")>"Remove"</button>
                                </li>
                            }
                        } />
                    </ul>
                    <button on:click=add_node>"Add a node"</button>
                    {move || command.get().map(|c| view! {
                        <p class="muted">"On the machine, run this within 10 minutes. The code works once."</p>
                        <pre>{c}</pre>
                        <button on:click=copy>"Copy"</button>
                    })}
                </div>
                <div>
                    <h3>"Usage"</h3>
                    <p class="muted">{move || usage.with(|u| {
                        let today = u["today_tokens"].as_i64().unwrap_or(0);
                        match u["budget"].as_i64() {
                            Some(b) => format!("{today} tokens today of a {b} budget."),
                            None => format!("{today} tokens today. Set ORPHUSBOT_DAILY_TOKEN_BUDGET to be warned."),
                        }
                    })}</p>
                    <ul class="decisions">
                        {move || {
                            let rows = |key: &str, when: &str| usage.with(|u| u[key].as_array().cloned().unwrap_or_default())
                                .into_iter()
                                .map(|m| {
                                    let text = format!("{} {} · {} turns · {} in / {} out · ${:.2}", m["provider"].as_str().unwrap_or_default(),
                                        m["model"].as_str().unwrap_or_default(), m["turns"], m["input"], m["output"], m["cost"].as_f64().unwrap_or(0.0));
                                    let when = when.to_owned();
                                    view! { <li><span>{text}<small>{when}</small></span></li> }
                                })
                                .collect::<Vec<_>>();
                            let mut all = rows("today", "today");
                            all.extend(rows("week", "last 7 days"));
                            all.collect_view()
                        }}
                        {move || usage.with(|u| u["bots_today"].as_array().cloned().unwrap_or_default()).into_iter().map(|b| view! {
                            <li><span>{format!("{} · {} turns · {} tokens", b["bot"].as_str().unwrap_or_default(), b["turns"], b["tokens"])}<small>"today, by bot"</small></span></li>
                        }).collect_view()}
                    </ul>
                </div>
                <div>
                    <h3>"Wearable"</h3>
                    <ul>
                        {move || wearables.with(|w| w["devices"].as_array().cloned().unwrap_or_default()).into_iter().map(|d| {
                            let seen = d["last_seen"].as_str().map_or("never", day).to_owned();
                            view! { <li><span>{d["label"].as_str().filter(|l| !l.is_empty()).or(d["id"].as_str()).unwrap_or_default().to_owned()}
                                <small>{format!("last seen {seen}{}", if d["hands_free"] == true { " · hands-free on" } else { "" })}</small></span></li> }
                        }).collect_view()}
                    </ul>
                    <button on:click=move |_| ctx.run(async move {
                        let res: Value = api::post("/api/devices/pairing-code", &json!({})).await?.json().await.map_err(|e| e.to_string())?;
                        pairing.set(res["code"].as_str().map(str::to_owned));
                        Ok(())
                    })>"Pair a wearable"</button>
                    {move || pairing.get().map(|code| {
                        let origin = web_sys::window().and_then(|w| w.location().origin().ok()).unwrap_or_default();
                        view! {
                            <p class="muted">"In the wearable app's pairing page, use this server address and paste the code as the token. It works once, for 10 minutes."</p>
                            <pre>{format!("Server: {origin}\nToken:  {code}")}</pre>
                        }
                    })}
                    <h3>"Signals to the wrist"</h3>
                    <ul class="decisions">
                        {move || wearables.with(|w| w["messages"].as_array().cloned().unwrap_or_default()).into_iter().take(12).map(|m| {
                            let text = format!("{} · {} · {}", m["cue"].as_str().unwrap_or_default().replace('_', " "),
                                m["state"].as_str().unwrap_or_default(), m["outcome"].as_str().unwrap_or(""));
                            view! { <li><span>{text}<small>{format!("{} · {}", m["kind"].as_str().unwrap_or_default(), m["subject"].as_str().unwrap_or_default())}</small></span></li> }
                        }).collect_view()}
                    </ul>
                </div>
                <div>
                    <h3>"Link a device"</h3>
                    <p class="muted">"For a device that can't use passkeys, such as the desktop app on Linux. Enter the code it shows."</p>
                    <div class="row">
                        <input aria-label="Device code" placeholder="ABCD-EFGH" bind:value=link_code style="flex: 1" />
                        <button on:click=move |_| check_link()>"Check"</button>
                    </div>
                    {move || waiting_device.get().map(|(code, label)| view! {
                        <p>"Approve " <strong>{code}</strong> " from " <strong>{label}</strong> "? It gets its own sign-in, ended when you remove this passkey."</p>
                        <button class="primary" on:click=approve_link>"Approve"</button>
                    })}
                </div>
                <div>
                    <button class="danger" on:click=sign_out>"Sign out"</button>
                </div>
            </section>
        </div>
    }
}

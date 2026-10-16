//! The app: sign-in, the bot sidebar, the chat with its cards, and settings.
//! Layout follows the Rakazo study (docs/research/rakazo-architecture.md).

use leptos::ev::{KeyboardEvent, SubmitEvent};
use leptos::prelude::*;
use leptos::task::spawn_local;
use orphusbot_proto::view::{Item, RunState, ThreadView};
use orphusbot_proto::{Dialog, DialogKind, Role, ThreadEvent};
use serde::Deserialize;
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
fn connect(view: RwSignal<ThreadView>, ctx: Ctx) {
    let Ok(source) = EventSource::new("/api/events") else {
        return ctx.toast.set("This browser can't stream events".into());
    };
    let on_message = Closure::<dyn Fn(MessageEvent)>::new(move |m: MessageEvent| {
        let event = m
            .data()
            .as_string()
            .and_then(|d| serde_json::from_str::<ThreadEvent>(&d).ok());
        if let Some(event) = event {
            view.update(|v| v.apply(event));
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

#[component]
fn Shell() -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let thread = RwSignal::new(ThreadView::default());
    let settings = RwSignal::new(false);
    let menu = RwSignal::new(false);
    // Opened from a device's link (`/?link=CODE`): go straight to approving it.
    let link_code = RwSignal::new(take_link_param().unwrap_or_default());
    if !link_code.get_untracked().is_empty() {
        settings.set(true);
    }
    connect(thread, ctx);
    let status = Memo::new(move |_| thread.with(|v| v.status()));
    let waiting = Memo::new(move |_| thread.with(|v| v.waiting()));
    let preview = Memo::new(move |_| {
        thread.with(|v| {
            let last = v.last_message().unwrap_or("No messages yet");
            last.chars().take(80).collect::<String>()
        })
    });
    view! {
        <div class="shell">
            <nav class="sidebar" class:open=move || menu.get() aria-label="Bots">
                <div class="brand">"OrphusBot"</div>
                // ponytail: one bot until M3 adds bots; this list grows then.
                <button class="bot active" aria-current="page" on:click=move |_| menu.set(false)>
                    <span class="avatar" aria-hidden="true">"O"</span>
                    <span class="text">
                        <strong>"Orphus"</strong>
                        <small>{move || preview.get()}</small>
                    </span>
                    <Show when=move || { waiting.get() > 0 }>
                        <span class="badge" title="Waiting for you">{move || waiting.get()}</span>
                    </Show>
                </button>
                <div class="spacer"></div>
                <button on:click=move |_| settings.set(true)>"Settings"</button>
            </nav>
            <main class="chat">
                <header>
                    <button class="menu" aria-label="Show bots" on:click=move |_| menu.update(|m| *m = !*m)>"☰"</button>
                    <span class="avatar" aria-hidden="true">"O"</span>
                    <div class="title">
                        <h1>"Orphus"</h1>
                        <span class="status" role="status">{move || status.get()}</span>
                    </div>
                    <button aria-label="Settings" on:click=move |_| settings.set(true)>"⚙"</button>
                </header>
                <Show when=move || ctx.needs_passkey.get()>
                    <div class="banner">
                        <span>"You're signed in with the setup token for one hour. Add a passkey to keep access."</span>
                        <button class="primary" on:click=move |_| settings.set(true)>"Add a passkey"</button>
                    </div>
                </Show>
                <Log thread />
                <Composer thread />
            </main>
            <Show when=move || settings.get()>
                <Settings open=settings link_code />
            </Show>
        </div>
    }
}

#[component]
fn Log(thread: RwSignal<ThreadView>) -> impl IntoView {
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
    let id = dialog.id;
    let open = outcome.is_none();
    let body = match dialog.kind {
        DialogKind::Approval {
            tool,
            input,
            uncertain,
        } => view! {
            <h2>{format!("Allow Orphus to use {tool}?")}</h2>
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
fn Composer(thread: RwSignal<ThreadView>) -> impl IntoView {
    let ctx = expect_context::<Ctx>();
    let text = RwSignal::new(String::new());
    let busy = RwSignal::new(false);
    let running = Memo::new(move |_| thread.with(|v| v.run != RunState::Idle));
    let send = move || {
        let t = text.get_untracked().trim().to_owned();
        if t.is_empty() || busy.get_untracked() {
            return;
        }
        busy.set(true);
        ctx.run(async move {
            let sent = api::post("/api/messages", &json!({ "text": t })).await;
            busy.set(false);
            sent?;
            text.set(String::new());
            Ok(())
        });
    };
    let stop =
        move |_| ctx.run(async { api::post("/api/runs/cancel", &json!({})).await.map(drop) });
    view! {
        <div class="composer">
            <form on:submit=move |ev: SubmitEvent| {
                ev.prevent_default();
                send();
            }>
                <textarea rows=1 aria-label="Message" placeholder="Message Orphus" title="Enter to send, Shift+Enter for a new line"
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

/// Reads `?link=CODE` and removes it from the address bar.
fn take_link_param() -> Option<String> {
    let w = web_sys::window()?;
    let search = w.location().search().ok()?;
    let code = web_sys::UrlSearchParams::new_with_str(&search)
        .ok()?
        .get("link")?;
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
    let name = RwSignal::new("This device".to_owned());
    let command = RwSignal::new(None::<String>);

    let load = move || {
        ctx.run(async move {
            passkeys.set(api::get("/api/passkeys").await?);
            nodes.set(api::get("/api/nodes").await?);
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

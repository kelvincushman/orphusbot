//! Push to the phone through self-hosted ntfy (PRD B-CLI-05, DESIGN §12).
//!
//! No Google account: the ntfy server runs on the GPU box, and the phone gets
//! pushes through the ntfy app or UnifiedPush. OrphusBot publishes to one topic
//! (`ORPHUSBOT_NTFY_URL`, such as `https://ntfy.example.com/orphusbot-<random>`),
//! optionally with an access token (`ORPHUSBOT_NTFY_TOKEN`). Nothing is sent
//! there while it isn't set.
//!
//! The phone app registers a UnifiedPush endpoint (`/api/push`), which its
//! distributor (the ntfy app, on our own ntfy) hands it. Every push is also
//! posted to each endpoint as JSON (`title`, `body`, `bot`, `priority`), and
//! the app shows it as its own notification; tapping opens the bot. An
//! endpoint the distributor says is gone (404 or 410) is forgotten.
//!
//! What pushes: anything that needs the owner (an approval, a question, a
//! takeover, an ask that expired on the wrist), any failed run, and finished
//! work the owner didn't start from a chat (a routine, a ticket, the wearable).
//! Quiet hours and the Focus profile's digests arrive with capture profiles.

use std::time::Duration;

use serde_json::json;
use sqlx::PgPool;
use tracing::warn;

pub struct Notifier {
    http: reqwest::Client,
    topic: Option<String>,
    token: Option<String>,
    /// Where taps on a push should open, such as `https://bots.example.com`.
    origin: String,
    /// Where the UnifiedPush endpoints are kept; none in tests that don't need them.
    db: Option<PgPool>,
}

/// One push. `bot` makes a tap open that bot's thread.
pub struct Push<'a> {
    pub title: String,
    pub body: String,
    /// ntfy priority: 1 (min) to 5 (max).
    pub priority: u8,
    pub tags: &'a str,
    pub bot: Option<&'a str>,
}

impl Notifier {
    pub fn from_env(origin: &str, db: PgPool) -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        Self {
            http: reqwest::Client::new(),
            topic: var("ORPHUSBOT_NTFY_URL"),
            token: var("ORPHUSBOT_NTFY_TOKEN"),
            origin: origin.trim_end_matches('/').to_owned(),
            db: Some(db),
        }
    }

    #[cfg(test)]
    pub fn to(topic: &str) -> Self {
        Self {
            http: reqwest::Client::new(),
            topic: Some(topic.to_owned()),
            token: None,
            origin: "https://bots.example.com".into(),
            db: None,
        }
    }

    #[cfg(test)]
    pub fn off() -> Self {
        Self {
            http: reqwest::Client::new(),
            topic: None,
            token: None,
            origin: String::new(),
            db: None,
        }
    }

    /// Sends in the background; a push that fails is logged, never retried.
    pub fn send(&self, push: Push<'_>) {
        self.to_endpoints(&push);
        let Some(topic) = self.topic.clone() else {
            return;
        };
        let click = match push.bot {
            Some(bot) => format!("{}/?bot={bot}", self.origin),
            None => format!("{}/", self.origin),
        };
        // ntfy takes the title and tags as headers, which must be ASCII-safe; the body is UTF-8.
        let title: String = push
            .title
            .chars()
            .filter(|c| c.is_ascii() && !c.is_ascii_control())
            .collect();
        let mut req = self
            .http
            .post(topic)
            .timeout(Duration::from_secs(10))
            .header("Title", title)
            .header("Priority", push.priority.clamp(1, 5).to_string())
            .header("Tags", push.tags)
            .header("Click", click)
            .body(push.body.chars().take(1_000).collect::<String>());
        if let Some(token) = &self.token {
            req = req.bearer_auth(token);
        }
        tokio::spawn(async move {
            match req
                .send()
                .await
                .and_then(reqwest::Response::error_for_status)
            {
                Ok(_) => {}
                Err(e) => warn!("sending a push: {e}"),
            }
        });
    }

    /// Posts the push to every registered UnifiedPush endpoint.
    fn to_endpoints(&self, push: &Push<'_>) {
        let Some(db) = self.db.clone() else { return };
        let http = self.http.clone();
        let msg = json!({
            "title": push.title,
            "body": push.body.chars().take(1_000).collect::<String>(),
            "bot": push.bot,
            "priority": push.priority.clamp(1, 5),
        })
        .to_string();
        tokio::spawn(async move {
            let urls = match sqlx::query_scalar!("select url from push_endpoint")
                .fetch_all(&db)
                .await
            {
                Ok(urls) => urls,
                Err(e) => return warn!("reading push endpoints: {e}"),
            };
            for url in urls {
                let sent = http
                    .post(&url)
                    .timeout(Duration::from_secs(10))
                    .header("TTL", "86400")
                    .body(msg.clone())
                    .send()
                    .await;
                match sent.map(|r| r.status().as_u16()) {
                    Ok(404 | 410) => {
                        let _ = sqlx::query!("delete from push_endpoint where url = $1", url)
                            .execute(&db)
                            .await;
                    }
                    Ok(s) if s >= 400 => warn!("a push endpoint answered {s}"),
                    Ok(_) => {}
                    Err(e) => warn!("sending a push to an endpoint: {e}"),
                }
            }
        });
    }
}

#[derive(serde::Deserialize)]
pub struct Endpoint {
    endpoint: String,
}

/// The phone app registers the endpoint its UnifiedPush distributor gave it.
pub async fn register(
    axum::extract::State(app): axum::extract::State<crate::Shared>,
    axum::Json(e): axum::Json<Endpoint>,
) -> Result<axum::http::StatusCode, crate::ApiError> {
    let url = e.endpoint.trim();
    if !url.starts_with("https://") || url.len() > 1000 || reqwest::Url::parse(url).is_err() {
        return Err((
            axum::http::StatusCode::UNPROCESSABLE_ENTITY,
            "A push endpoint must be an https address",
        ));
    }
    let hosts = std::env::var("ORPHUSBOT_PUSH_HOSTS").unwrap_or_default();
    if !push_host_allowed(url, &hosts) {
        return Err((
            axum::http::StatusCode::UNPROCESSABLE_ENTITY,
            "Pushes must go through your own ntfy server. In the ntfy app, set Settings, Default server to your push address, then open OrphusBot again",
        ));
    }
    sqlx::query!(
        "insert into push_endpoint (url) values ($1) on conflict do nothing",
        url
    )
    .execute(&app.db)
    .await
    .map_err(|e| crate::internal("saving the push endpoint", e))?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

/// Whether an endpoint is on one of the owner's push servers
/// (`ORPHUSBOT_PUSH_HOSTS`, comma-separated host names). Unset allows any
/// https host; set, a phone whose ntfy app still points at a public server
/// (ntfy.sh) is refused, so pushes never pass through someone else's server.
fn push_host_allowed(url: &str, hosts: &str) -> bool {
    let allowed: Vec<&str> = hosts
        .split(',')
        .map(str::trim)
        .filter(|h| !h.is_empty())
        .collect();
    allowed.is_empty()
        || reqwest::Url::parse(url)
            .ok()
            .and_then(|u| u.host_str().map(str::to_ascii_lowercase))
            .is_some_and(|h| allowed.iter().any(|a| a.eq_ignore_ascii_case(&h)))
}

/// The app stops pushes to this phone (signing out, or the distributor dropped it).
pub async fn unregister(
    axum::extract::State(app): axum::extract::State<crate::Shared>,
    axum::Json(e): axum::Json<Endpoint>,
) -> Result<axum::http::StatusCode, crate::ApiError> {
    sqlx::query!(
        "delete from push_endpoint where url = $1",
        e.endpoint.trim()
    )
    .execute(&app.db)
    .await
    .map_err(|e| crate::internal("removing the push endpoint", e))?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pushes_only_go_through_the_owners_servers_when_set() {
        let mine = "push.example.com";
        assert!(push_host_allowed(
            "https://push.example.com/upAbC?up=1",
            mine
        ));
        assert!(push_host_allowed("https://PUSH.example.com/up1", mine));
        assert!(!push_host_allowed("https://ntfy.sh/upAbC?up=1", mine));
        assert!(!push_host_allowed(
            "https://push.example.com.evil.io/up",
            mine
        ));
        assert!(push_host_allowed("https://ntfy.sh/upAbC", ""));
        assert!(push_host_allowed(
            "https://b.example/x",
            " a.example , b.example "
        ));
    }
    use axum::http::HeaderMap;
    use std::sync::{Arc, Mutex};

    #[tokio::test]
    async fn pushes_reach_the_topic_with_ntfy_headers() {
        let got: Arc<Mutex<Vec<(HeaderMap, String)>>> = Arc::default();
        let seen = got.clone();
        let app = axum::Router::new().route(
            "/orphusbot-test",
            axum::routing::post(move |headers: HeaderMap, body: String| {
                let seen = seen.clone();
                async move {
                    seen.lock().unwrap().push((headers, body));
                    "ok"
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let topic = format!("http://{}/orphusbot-test", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        Notifier::to(&topic).send(Push {
            title: "Researcher needs you — “quotes”".into(),
            body: "Allow Researcher to use bash?".into(),
            priority: 4,
            tags: "raising_hand",
            bot: Some("researcher"),
        });
        Notifier::off().send(Push {
            title: "x".into(),
            body: "x".into(),
            priority: 3,
            tags: "",
            bot: None,
        });
        for _ in 0..50 {
            if !got.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let got = got.lock().unwrap();
        assert_eq!(got.len(), 1, "off sends nothing");
        let (headers, body) = &got[0];
        let h = |n: &str| headers.get(n).unwrap().to_str().unwrap().to_owned();
        assert_eq!(h("title"), "Researcher needs you  quotes");
        assert_eq!(h("priority"), "4");
        assert_eq!(h("click"), "https://bots.example.com/?bot=researcher");
        assert_eq!(body, "Allow Researcher to use bash?");
    }

    #[sqlx::test]
    async fn pushes_reach_endpoints_and_gone_ones_are_forgotten(db: PgPool) {
        let got: Arc<Mutex<Vec<String>>> = Arc::default();
        let seen = got.clone();
        let app = axum::Router::new()
            .route(
                "/up-live",
                axum::routing::post(move |body: String| {
                    let seen = seen.clone();
                    async move {
                        seen.lock().unwrap().push(body);
                        "ok"
                    }
                }),
            )
            .route(
                "/up-gone",
                axum::routing::post(|| async { axum::http::StatusCode::GONE }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        for path in ["up-live", "up-gone"] {
            sqlx::query("insert into push_endpoint (url) values ($1)")
                .bind(format!("{base}/{path}"))
                .execute(&db)
                .await
                .unwrap();
        }

        let mut n = Notifier::off();
        n.db = Some(db.clone());
        n.send(Push {
            title: "Coder failed".into(),
            body: "The build broke.".into(),
            priority: 4,
            tags: "",
            bot: Some("coder"),
        });
        let mut left = 2;
        for _ in 0..100 {
            left = sqlx::query_scalar!("select count(*) from push_endpoint")
                .fetch_one(&db)
                .await
                .unwrap()
                .unwrap_or(0);
            if left == 1 && !got.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert_eq!(left, 1, "the gone endpoint is forgotten");
        let msg: serde_json::Value = serde_json::from_str(&got.lock().unwrap()[0]).unwrap();
        assert_eq!(msg["title"], "Coder failed");
        assert_eq!(msg["bot"], "coder");
        assert_eq!(msg["priority"], 4);
    }
}

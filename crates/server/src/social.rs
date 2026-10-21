//! Social (DESIGN §11.6, D-044): the app's Social screen on ContentSwarm.
//!
//! ContentSwarm runs beside the server on the same machine (loopback only) and
//! owns the phone, the social profiles and the review queue. OrphusBot signs in
//! to its owner console with the console token (`ORPHUSBOT_CONTENTSWARM_URL`,
//! `ORPHUSBOT_CONTENTSWARM_CONSOLE_TOKEN`) and passes the owner's requests
//! through `/api/social/…`, but only those on `ALLOWED`: reading the queue,
//! profiles, memory, schedules, jobs and the phone's screen, and the owner's
//! own decisions (approve, edit, schedule, reject, cancel). Claiming and
//! delivering stay with ContentSwarm's worker; tapping on the phone stays with
//! the phone bot, behind the gate. Bots never see the console token.
//!
//! New drafts waiting for approval raise a push.

use std::collections::HashSet;
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::extract::{Path, RawQuery, State};
use axum::http::{Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::Value;
use tokio::sync::Mutex;
use tracing::warn;

use crate::Shared;

pub struct Social {
    http: reqwest::Client,
    /// Such as `http://127.0.0.1:5055`; none when Social isn't set up.
    base: Option<String>,
    token: Option<String>,
    session: Mutex<Option<Session>>,
}

#[derive(Clone)]
struct Session {
    /// `name=value` from the login's `Set-Cookie`.
    cookie: String,
    csrf: String,
}

/// What the owner may do through OrphusBot, as `(method, path)` with `*` for
/// one id segment. Paths are under ContentSwarm's `/api/v1/`.
const ALLOWED: &[(&str, &str)] = &[
    ("GET", "reviews"),
    ("POST", "reviews/*/approve"),
    ("POST", "reviews/*/reject"),
    ("POST", "reviews/*/edit"),
    ("POST", "reviews/*/schedule"),
    ("POST", "reviews/*/cancel"),
    ("GET", "social/accounts"),
    ("POST", "social/accounts"),
    ("GET", "social/accounts/*/memory"),
    ("POST", "social/accounts/*/memory"),
    ("GET", "social/schedules"),
    ("POST", "social/schedules"),
    ("POST", "social/schedules/*/pause"),
    ("GET", "social/jobs"),
    ("POST", "social/jobs"),
    ("GET", "phones"),
    ("GET", "phones/*/screenshot"),
    ("GET", "phones/*/current_app"),
    ("GET", "status"),
];

/// Whether `path` is on the list; ids are letters, digits, `.`, `_` and `-`.
pub fn allowed(method: &Method, path: &str) -> bool {
    let parts: Vec<&str> = path.split('/').collect();
    let id_ok = |s: &str| {
        !s.is_empty()
            && s != "."
            && s != ".."
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    };
    ALLOWED.iter().any(|(m, pattern)| {
        let want: Vec<&str> = pattern.split('/').collect();
        *m == method.as_str()
            && want.len() == parts.len()
            && want
                .iter()
                .zip(&parts)
                .all(|(w, p)| if *w == "*" { id_ok(p) } else { w == p })
    })
}

impl Social {
    pub fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        Self::new(
            var("ORPHUSBOT_CONTENTSWARM_URL"),
            var("ORPHUSBOT_CONTENTSWARM_CONSOLE_TOKEN"),
        )
    }

    fn new(base: Option<String>, token: Option<String>) -> Self {
        Self {
            http: reqwest::Client::new(),
            base: base.map(|b| b.trim_end_matches('/').to_owned()),
            token,
            session: Mutex::default(),
        }
    }

    #[cfg(test)]
    pub fn off() -> Self {
        Self::new(None, None)
    }

    fn enabled(&self) -> bool {
        self.base.is_some() && self.token.is_some()
    }

    async fn login(&self, base: &str) -> anyhow::Result<Session> {
        let res = self
            .http
            .post(format!("{base}/api/console/login"))
            .timeout(Duration::from_secs(30))
            .json(&serde_json::json!({ "token": self.token }))
            .send()
            .await?;
        anyhow::ensure!(
            res.status().is_success(),
            "ContentSwarm refused the console token ({})",
            res.status()
        );
        let cookie = res
            .headers()
            .get(header::SET_COOKIE)
            .and_then(|c| c.to_str().ok())
            .and_then(|c| c.split(';').next())
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("ContentSwarm's login set no cookie"))?;
        let csrf = res.json::<Value>().await?["csrf"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("ContentSwarm's login gave no csrf"))?;
        Ok(Session { cookie, csrf })
    }

    /// One request as the owner. Signs in when needed, and once more when the
    /// session is refused (ContentSwarm forgets sessions when it restarts).
    pub async fn call(
        &self,
        method: Method,
        path: &str,
        query: Option<&str>,
        body: Option<Bytes>,
    ) -> anyhow::Result<reqwest::Response> {
        let (Some(base), true) = (&self.base, self.enabled()) else {
            anyhow::bail!("Social isn't set up");
        };
        let mut url = format!("{base}/api/v1/{path}");
        if let Some(q) = query.filter(|q| !q.is_empty()) {
            url = format!("{url}?{q}");
        }
        for fresh in [false, true] {
            let session = {
                let mut held = self.session.lock().await;
                match held.as_ref() {
                    Some(s) if !fresh => s.clone(),
                    _ => {
                        let s = self.login(base).await?;
                        *held = Some(s.clone());
                        s
                    }
                }
            };
            let mut req = self
                .http
                .request(method.clone(), &url)
                .timeout(Duration::from_secs(30))
                .header(header::COOKIE, &session.cookie)
                .header("X-CSRF-Token", &session.csrf);
            if method == Method::POST {
                let body = body.clone().filter(|b| !b.is_empty());
                req = req
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(body.unwrap_or_else(|| Bytes::from_static(b"{}")));
            }
            let res = req.send().await?;
            if !fresh && matches!(res.status().as_u16(), 401 | 403) {
                continue;
            }
            return Ok(res);
        }
        unreachable!("the second try always returns")
    }
}

/// `/api/social/{*path}`: passes an allowed request through and returns
/// ContentSwarm's answer as it is (JSON, or a PNG for a screenshot).
pub async fn proxy(
    State(app): State<Shared>,
    method: Method,
    Path(path): Path<String>,
    RawQuery(query): RawQuery,
    body: Bytes,
) -> Response {
    if !app.social.enabled() {
        return (
            StatusCode::NOT_FOUND,
            "Social isn't set up: set ORPHUSBOT_CONTENTSWARM_URL and ORPHUSBOT_CONTENTSWARM_CONSOLE_TOKEN",
        )
            .into_response();
    }
    if !allowed(&method, &path) {
        return (StatusCode::FORBIDDEN, "OrphusBot doesn't pass that on").into_response();
    }
    match app
        .social
        .call(method, &path, query.as_deref(), Some(body))
        .await
    {
        Ok(res) => {
            let status =
                StatusCode::from_u16(res.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
            let kind = res
                .headers()
                .get(header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("application/json")
                .to_owned();
            match res.bytes().await {
                Ok(bytes) => Response::builder()
                    .status(status)
                    .header(header::CONTENT_TYPE, kind)
                    .header(header::CACHE_CONTROL, "no-store")
                    .body(Body::from(bytes))
                    .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response()),
                Err(e) => {
                    warn!("reading ContentSwarm's answer: {e}");
                    StatusCode::BAD_GATEWAY.into_response()
                }
            }
        }
        Err(e) => {
            warn!("calling ContentSwarm: {e}");
            (StatusCode::BAD_GATEWAY, "ContentSwarm isn't answering").into_response()
        }
    }
}

/// The ids of reviews waiting for the owner.
async fn pending(app: &Shared) -> anyhow::Result<HashSet<String>> {
    let res = app.social.call(Method::GET, "reviews", None, None).await?;
    anyhow::ensure!(res.status().is_success(), "{}", res.status());
    let all: Value = res.json().await?;
    Ok(all["reviews"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| r["status"] == "pending")
        .filter_map(|r| r["id"].as_str().map(str::to_owned))
        .collect())
}

/// Every minute: a push when drafts arrive that weren't waiting before.
pub async fn watch_forever(app: Shared) {
    if !app.social.enabled() {
        return;
    }
    let mut seen: Option<HashSet<String>> = None;
    loop {
        match pending(&app).await {
            Ok(now) => {
                if let Some(before) = &seen {
                    let new = now.difference(before).count();
                    if new > 0 {
                        app.notifier.send(crate::notify::Push {
                            title: format!(
                                "{new} new draft{} to approve",
                                if new == 1 { "" } else { "s" }
                            ),
                            body: format!("{} waiting in Social altogether.", now.len()),
                            priority: 3,
                            tags: "memo",
                            bot: None,
                        });
                    }
                }
                seen = Some(now);
            }
            Err(e) => warn!("checking ContentSwarm's review queue: {e}"),
        }
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::Router;
    use axum::routing::{get, post};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn only_the_owners_own_actions_pass() {
        let get = Method::GET;
        let post = Method::POST;
        assert!(allowed(&get, "reviews"));
        assert!(allowed(&post, "reviews/r-1a2b/approve"));
        assert!(allowed(&get, "phones/note10/screenshot"));
        assert!(allowed(&post, "social/accounts/abc/memory"));
        // The worker's and the phone bot's jobs, not the owner's screen.
        assert!(!allowed(&post, "reviews/r1/claim"));
        assert!(!allowed(&post, "reviews/r1/complete"));
        assert!(!allowed(&post, "phones/note10/action"));
        assert!(!allowed(&post, "phones/note10/app"));
        // Wrong method, odd ids, nothing smuggled in.
        assert!(!allowed(&get, "reviews/r1/approve"));
        assert!(!allowed(&post, "reviews/../approve"));
        assert!(!allowed(&post, "reviews//approve"));
        assert!(!allowed(&get, "phones/a b/screenshot"));
        assert!(!allowed(&get, "reviews/"));
    }

    /// A ContentSwarm stand-in whose sessions expire after one use.
    async fn fake() -> (String, Arc<AtomicUsize>) {
        let logins = Arc::new(AtomicUsize::new(0));
        let n = logins.clone();
        let router = Router::new()
            .route(
                "/api/console/login",
                post(move |body: axum::Json<Value>| {
                    let n = n.clone();
                    async move {
                        if body["token"] != "console" {
                            return StatusCode::UNAUTHORIZED.into_response();
                        }
                        let i = n.fetch_add(1, Ordering::SeqCst);
                        (
                            [(
                                header::SET_COOKIE,
                                format!("session=s{i}; HttpOnly; Path=/"),
                            )],
                            axum::Json(serde_json::json!({ "csrf": format!("c{i}") })),
                        )
                            .into_response()
                    }
                }),
            )
            .route(
                "/api/v1/reviews",
                get(|headers: axum::http::HeaderMap| async move {
                    // Only the second session is good, as after a restart.
                    if headers.get(header::COOKIE).map(|c| c.as_bytes()) == Some(b"session=s1")
                        && headers.get("x-csrf-token").map(|c| c.as_bytes()) == Some(b"c1")
                    {
                        axum::Json(serde_json::json!({ "reviews": [
                            { "id": "a", "status": "pending" },
                            { "id": "b", "status": "approved" },
                        ]}))
                        .into_response()
                    } else {
                        StatusCode::UNAUTHORIZED.into_response()
                    }
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, router).await });
        (format!("http://{addr}"), logins)
    }

    #[tokio::test]
    async fn signs_in_again_when_the_session_is_refused() {
        let (base, logins) = fake().await;
        let social = Social::new(Some(base), Some("console".into()));
        let res = social
            .call(Method::GET, "reviews", None, None)
            .await
            .unwrap();
        assert_eq!(res.status(), 200);
        assert_eq!(logins.load(Ordering::SeqCst), 2);
        let body: Value = res.json().await.unwrap();
        assert_eq!(body["reviews"][0]["id"], "a");
    }

    #[tokio::test]
    async fn a_wrong_token_is_an_error_not_a_loop() {
        let (base, _) = fake().await;
        let social = Social::new(Some(base), Some("wrong".into()));
        assert!(
            social
                .call(Method::GET, "reviews", None, None)
                .await
                .is_err()
        );
    }
}

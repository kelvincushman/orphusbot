//! Push to the phone through self-hosted ntfy (PRD B-CLI-05, DESIGN §12).
//!
//! No Google account: the ntfy server runs on the GPU box, and the phone gets
//! pushes through the ntfy app or UnifiedPush. OrphusBot publishes to one topic
//! (`ORPHUSBOT_NTFY_URL`, such as `https://ntfy.example.com/orphusbot-<random>`),
//! optionally with an access token (`ORPHUSBOT_NTFY_TOKEN`). Nothing is sent
//! while it isn't set.
//!
//! What pushes: anything that needs the owner (an approval, a question, a
//! takeover, an ask that expired on the wrist), any failed run, and finished
//! work the owner didn't start from a chat (a routine, a ticket, the wearable).
//! Quiet hours and the Focus profile's digests arrive with capture profiles.

use std::time::Duration;

use tracing::warn;

pub struct Notifier {
    http: reqwest::Client,
    topic: Option<String>,
    token: Option<String>,
    /// Where taps on a push should open, such as `https://bots.example.com`.
    origin: String,
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
    pub fn from_env(origin: &str) -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        Self {
            http: reqwest::Client::new(),
            topic: var("ORPHUSBOT_NTFY_URL"),
            token: var("ORPHUSBOT_NTFY_TOKEN"),
            origin: origin.trim_end_matches('/').to_owned(),
        }
    }

    #[cfg(test)]
    pub fn to(topic: &str) -> Self {
        Self {
            http: reqwest::Client::new(),
            topic: Some(topic.to_owned()),
            token: None,
            origin: "https://bots.example.com".into(),
        }
    }

    #[cfg(test)]
    pub fn off() -> Self {
        Self {
            http: reqwest::Client::new(),
            topic: None,
            token: None,
            origin: String::new(),
        }
    }

    /// Sends in the background; a push that fails is logged, never retried.
    pub fn send(&self, push: Push<'_>) {
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
}

#[cfg(test)]
mod tests {
    use super::*;
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
}

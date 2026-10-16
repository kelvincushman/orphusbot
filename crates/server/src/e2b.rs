//! E2B computers (DESIGN §6.2, PRD B-CMP-07): a bot whose computer is in E2B
//! gets one sandbox that pauses itself when idle and resumes on its next run,
//! so its files last. The server holds the API key; the node gets only that
//! sandbox's envd address and access token, and the engine (with the model
//! subscription) stays on the node (AGENTS.md rule 4).

use anyhow::{Context, bail};
use orphusbot_proto::E2bComputer;
use serde_json::{Value, json};
use sqlx::PgPool;

/// envd, the agent inside every sandbox, listens here.
const ENVD_PORT: u16 = 49983;

pub struct E2b {
    http: reqwest::Client,
    api_url: String,
    api_key: Option<String>,
    template: String,
    /// Seconds a sandbox stays up after each run starts before it pauses itself.
    timeout: u32,
    /// Replaces `https://49983-<id>.<domain>` (tests and self-hosted E2B).
    sandbox_url: Option<String>,
}

impl E2b {
    /// `ORPHUSBOT_E2B_API_KEY` turns it on. Optional: `ORPHUSBOT_E2B_API_URL`
    /// (default `https://api.e2b.app`), `ORPHUSBOT_E2B_TEMPLATE` (default `base`),
    /// `ORPHUSBOT_E2B_TIMEOUT_SECS` (default 3600), `ORPHUSBOT_E2B_SANDBOX_URL`.
    pub fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        Self {
            http: reqwest::Client::new(),
            api_url: var("ORPHUSBOT_E2B_API_URL")
                .unwrap_or_else(|| "https://api.e2b.app".into())
                .trim_end_matches('/')
                .to_owned(),
            api_key: var("ORPHUSBOT_E2B_API_KEY"),
            template: var("ORPHUSBOT_E2B_TEMPLATE").unwrap_or_else(|| "base".into()),
            timeout: var("ORPHUSBOT_E2B_TIMEOUT_SECS")
                .and_then(|v| v.parse().ok())
                .unwrap_or(3600),
            sandbox_url: var("ORPHUSBOT_E2B_SANDBOX_URL"),
        }
    }

    #[cfg(test)]
    pub fn off() -> Self {
        Self {
            http: reqwest::Client::new(),
            api_url: String::new(),
            api_key: None,
            template: "base".into(),
            timeout: 60,
            sandbox_url: None,
        }
    }

    pub fn enabled(&self) -> bool {
        self.api_key.is_some()
    }

    async fn call(&self, path: &str, body: Value) -> anyhow::Result<(u16, Value)> {
        let key = self
            .api_key
            .as_deref()
            .context("ORPHUSBOT_E2B_API_KEY isn't set on the server")?;
        let res = self
            .http
            .post(format!("{}{path}", self.api_url))
            .header("X-API-KEY", key)
            .json(&body)
            .timeout(std::time::Duration::from_secs(60))
            .send()
            .await
            .context("reaching E2B")?;
        let status = res.status().as_u16();
        let body = res.json::<Value>().await.unwrap_or_default();
        Ok((status, body))
    }

    /// The bot's sandbox, resumed or made, ready for this run.
    pub async fn computer(&self, db: &PgPool, slug: &str) -> anyhow::Result<E2bComputer> {
        let existing = sqlx::query_scalar!(
            "select s.sandbox_id from bot_sandbox s join bot b on b.id = s.bot_id where b.slug = $1",
            slug
        )
        .fetch_optional(db)
        .await?;
        if let Some(id) = existing {
            let path = format!("/v2/sandboxes/{id}/connect");
            match self.call(&path, json!({ "timeout": self.timeout })).await? {
                (200 | 201, sandbox) => return self.reach(&sandbox),
                // Gone (killed, or kept past E2B's limit): start a new one.
                (404, _) => {}
                (status, body) => bail!("E2B couldn't resume the sandbox ({status}): {body}"),
            }
        }
        let body = json!({
            "templateID": self.template,
            "timeout": self.timeout,
            "autoPause": true,
            "metadata": { "orphusbot_bot": slug },
        });
        let sandbox = match self.call("/v2/sandboxes", body).await? {
            (200 | 201, sandbox) => sandbox,
            (status, body) => bail!("E2B couldn't create a sandbox ({status}): {body}"),
        };
        let computer = self.reach(&sandbox)?;
        sqlx::query!(
            "insert into bot_sandbox (bot_id, sandbox_id) select id, $2 from bot where slug = $1
             on conflict (bot_id) do update set sandbox_id = excluded.sandbox_id, created_at = now()",
            slug,
            computer.sandbox
        )
        .execute(db)
        .await?;
        Ok(computer)
    }

    /// Where envd answers for this sandbox, and its access token.
    fn reach(&self, sandbox: &Value) -> anyhow::Result<E2bComputer> {
        let id = sandbox["sandboxID"]
            .as_str()
            .context("E2B's answer had no sandboxID")?;
        let domain = sandbox["domain"].as_str().unwrap_or("e2b.app");
        let url = match &self.sandbox_url {
            Some(url) => url.trim_end_matches('/').to_owned(),
            None => format!("https://{ENVD_PORT}-{id}.{domain}"),
        };
        Ok(E2bComputer {
            sandbox: id.to_owned(),
            url,
            token: sandbox["envdAccessToken"].as_str().map(str::to_owned),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::Json;
    use axum::extract::Path;
    use axum::http::{HeaderMap, StatusCode};
    use axum::routing::post;
    use std::sync::{Arc, Mutex};

    /// A stand-in for E2B's API: records calls, knows one live sandbox.
    async fn fake_e2b(live: &'static str) -> (E2b, Arc<Mutex<Vec<String>>>) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let (c1, c2) = (calls.clone(), calls.clone());
        let app = axum::Router::new()
            .route(
                "/v2/sandboxes",
                post(move |h: HeaderMap, Json(body): Json<Value>| async move {
                    c1.lock().unwrap().push(format!(
                        "create {} key={}",
                        body["templateID"],
                        h["x-api-key"].to_str().unwrap()
                    ));
                    (
                        StatusCode::CREATED,
                        Json(json!({ "sandboxID": "sbx-new", "envdAccessToken": "envd-tok", "domain": "e2b.app" })),
                    )
                }),
            )
            .route(
                "/v2/sandboxes/{id}/connect",
                post(move |Path(id): Path<String>| async move {
                    c2.lock().unwrap().push(format!("connect {id}"));
                    if id == live {
                        (StatusCode::CREATED, Json(json!({ "sandboxID": id, "envdAccessToken": "envd-tok2" })))
                    } else {
                        (StatusCode::NOT_FOUND, Json(json!({ "code": 404 })))
                    }
                }),
            );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let e2b = E2b {
            api_url: url,
            api_key: Some("test-key".into()),
            ..E2b::off()
        };
        (e2b, calls)
    }

    #[sqlx::test]
    async fn makes_a_sandbox_then_resumes_it_and_replaces_a_lost_one(db: PgPool) {
        let (e2b, calls) = fake_e2b("sbx-new").await;
        let first = e2b.computer(&db, "inbox").await.unwrap();
        assert_eq!(first.sandbox, "sbx-new");
        assert_eq!(first.url, "https://49983-sbx-new.e2b.app");
        assert_eq!(first.token.as_deref(), Some("envd-tok"));
        let again = e2b.computer(&db, "inbox").await.unwrap();
        assert_eq!(
            (again.sandbox.as_str(), again.token.as_deref()),
            ("sbx-new", Some("envd-tok2"))
        );
        // The sandbox is gone on E2B's side: a new one replaces it.
        sqlx::query!("update bot_sandbox set sandbox_id = 'sbx-gone'")
            .execute(&db)
            .await
            .unwrap();
        assert_eq!(e2b.computer(&db, "inbox").await.unwrap().sandbox, "sbx-new");
        assert_eq!(
            *calls.lock().unwrap(),
            [
                "create \"base\" key=test-key",
                "connect sbx-new",
                "connect sbx-gone",
                "create \"base\" key=test-key"
            ]
        );
        assert!(E2b::off().computer(&db, "inbox").await.is_err());
    }

    /// Live, opt-in, a cent or so: `ORPHUSBOT_E2B_API_KEY=… cargo test -p orphusbot-server
    /// live_e2b -- --ignored`. Makes a real sandbox, runs a command in it, deletes it.
    #[sqlx::test]
    #[ignore]
    async fn live_e2b(db: PgPool) {
        let e2b = E2b::from_env();
        let c = e2b.computer(&db, "inbox").await.unwrap();
        let mut request = serde_json::to_vec(&json!({
            "process": { "cmd": "/bin/bash", "args": ["-l", "-c", "echo live-ok"], "envs": {} },
            "stdin": false,
        }))
        .unwrap();
        let mut frame = vec![0u8];
        frame.extend((request.len() as u32).to_be_bytes());
        frame.append(&mut request);
        let mut call = e2b
            .http
            .post(format!("{}/process.Process/Start", c.url))
            .header("Content-Type", "application/connect+json")
            .header("Connect-Protocol-Version", "1")
            .header("Authorization", "Basic dXNlcjo=")
            .body(frame);
        if let Some(token) = &c.token {
            call = call.header("X-Access-Token", token);
        }
        let body = call.send().await.unwrap().bytes().await.unwrap();
        let killed = e2b
            .http
            .delete(format!("{}/sandboxes/{}", e2b.api_url, c.sandbox))
            .header("X-API-KEY", e2b.api_key.clone().unwrap())
            .send()
            .await
            .unwrap();
        assert!(killed.status().is_success());
        // "live-ok\n" in base64, inside a stdout event.
        assert!(
            String::from_utf8_lossy(&body).contains("bGl2ZS1vawo="),
            "{body:?}"
        );
    }
}

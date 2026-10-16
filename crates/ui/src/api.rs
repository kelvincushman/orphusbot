//! Talking to the server: JSON over `fetch`, and the passkey prompts.
//!
//! The page is served by the server, so every path is same-origin and the
//! session cookie goes along by itself.

use gloo_net::http::{Request, Response};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use wasm_bindgen::prelude::*;

// The browser's own WebAuthn JSON helpers do the base64 work, so this is all
// the JavaScript the passkey flow needs.
#[wasm_bindgen(inline_js = r#"
export function passkeysWork() {
  return !!window.PublicKeyCredential?.parseCreationOptionsFromJSON;
}
export async function createPasskey(options) {
  const publicKey = PublicKeyCredential.parseCreationOptionsFromJSON(JSON.parse(options).publicKey);
  return JSON.stringify((await navigator.credentials.create({ publicKey })).toJSON());
}
export async function getPasskey(options) {
  const publicKey = PublicKeyCredential.parseRequestOptionsFromJSON(JSON.parse(options).publicKey);
  return JSON.stringify((await navigator.credentials.get({ publicKey })).toJSON());
}
"#)]
extern "C" {
    #[wasm_bindgen(js_name = passkeysWork)]
    fn passkeys_work() -> bool;
    #[wasm_bindgen(catch, js_name = createPasskey)]
    async fn create_passkey(options: &str) -> Result<JsValue, JsValue>;
    #[wasm_bindgen(catch, js_name = getPasskey)]
    async fn get_passkey(options: &str) -> Result<JsValue, JsValue>;
}

const OFFLINE: &str = "Could not reach the server";

/// Turns a non-2xx response into the server's message.
async fn checked(res: Result<Response, gloo_net::Error>) -> Result<Response, String> {
    let res = res.map_err(|_| OFFLINE.to_owned())?;
    if res.ok() {
        return Ok(res);
    }
    let text = res.text().await.unwrap_or_default();
    Err(if text.is_empty() {
        format!("The server said {}", res.status())
    } else {
        text
    })
}

pub async fn get<T: DeserializeOwned>(path: &str) -> Result<T, String> {
    let res = checked(Request::get(path).send().await).await?;
    res.json().await.map_err(|e| e.to_string())
}

pub async fn post(path: &str, body: &Value) -> Result<Response, String> {
    let req = Request::post(path).json(body).map_err(|e| e.to_string())?;
    checked(req.send().await).await
}

/// 401 means the session ended; anything else (or no answer) doesn't.
pub async fn signed_out() -> bool {
    matches!(Request::get("/api/passkeys").send().await, Ok(r) if r.status() == 401)
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
pub struct AuthState {
    pub signed_in: bool,
    pub needs_passkey: bool,
    pub setup_open: bool,
}

pub async fn auth_state() -> Result<AuthState, String> {
    get("/auth/state").await
}

pub async fn setup(token: &str) -> Result<(), String> {
    let body = format!("token={}", js_sys::encode_uri_component(token));
    let req = Request::post("/auth/setup")
        .header("content-type", "application/x-www-form-urlencoded")
        .body(body)
        .map_err(|e| e.to_string())?;
    checked(req.send().await).await.map(drop)
}

fn prompt_error(e: JsValue) -> String {
    let why = e
        .dyn_into::<js_sys::Error>()
        .map(|e| String::from(e.message()))
        .unwrap_or_else(|_| "it was cancelled".into());
    format!("The passkey prompt didn't finish: {why}")
}

/// Runs one passkey prompt: start on the server, ask the browser, finish on the server.
async fn ceremony(start: &str, finish: &str, extra: Value, create: bool) -> Result<(), String> {
    if !passkeys_work() {
        return Err("This browser is too old for passkeys.".into());
    }
    let started: Value = post(start, &json!({}))
        .await?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    let options = started["options"].to_string();
    let credential = if create {
        create_passkey(&options).await
    } else {
        get_passkey(&options).await
    }
    .map_err(prompt_error)?;
    let credential: Value = credential
        .as_string()
        .and_then(|c| serde_json::from_str(&c).ok())
        .ok_or("The browser returned no passkey")?;
    let mut body = json!({ "id": started["id"], "credential": credential });
    if let (Some(body), Some(extra)) = (body.as_object_mut(), extra.as_object()) {
        body.extend(extra.clone());
    }
    post(finish, &body).await.map(drop)
}

pub async fn passkey_sign_in() -> Result<(), String> {
    ceremony("/auth/login/start", "/auth/login/finish", json!({}), false).await
}

pub async fn add_passkey(name: &str) -> Result<(), String> {
    let extra = json!({ "name": name });
    ceremony("/api/passkeys/start", "/api/passkeys/finish", extra, true).await
}

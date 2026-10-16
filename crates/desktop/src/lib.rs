//! The OrphusBot app for desktop and Android (DESIGN §12): a native window onto
//! your OrphusBot server.
//!
//! The window shows the server's own web UI, so the app carries no copy of it
//! and always matches the server's version. The window stays on that server;
//! any other link opens in the system browser. On first run a small bundled
//! page asks for the server's address. Sign-in uses device linking (D-019),
//! because WebKitGTK has no passkeys.

use std::fs;
use std::path::PathBuf;

use tauri::webview::NewWindowResponse;
use tauri::{AppHandle, Manager, Url, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_opener::OpenerExt;

/// Where the chosen server address is kept, in the app's config folder.
fn config_file(app: &AppHandle) -> Option<PathBuf> {
    app.path()
        .app_config_dir()
        .ok()
        .map(|dir| dir.join("server.txt"))
}

/// Accepts an https address, or http for this machine only (development).
fn parse_server(input: &str) -> Result<Url, String> {
    let mut url = Url::parse(input.trim()).map_err(|_| "That isn't a web address".to_owned())?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    match url.scheme() {
        "https" => {}
        "http" if local => {}
        _ => return Err("Use an https:// address (http:// only works for localhost)".into()),
    }
    url.set_path("/");
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}

/// `ORPHUSBOT_URL` wins over the saved address.
fn saved_server(app: &AppHandle) -> Option<Url> {
    let text = std::env::var("ORPHUSBOT_URL")
        .ok()
        .or_else(|| fs::read_to_string(config_file(app)?).ok())?;
    parse_server(&text).ok()
}

fn open_externally(app: &AppHandle, url: &Url) {
    if let Err(e) = app.opener().open_url(url.as_str(), None::<&str>) {
        eprintln!("couldn't open {url} in the browser: {e}");
    }
}

/// The main window, locked to the server's origin.
fn open_server(app: &AppHandle, server: Url) -> tauri::Result<()> {
    let origin = server.origin();
    let (nav, popup) = (app.clone(), app.clone());
    WebviewWindowBuilder::new(app, "main", WebviewUrl::External(server))
        .title("OrphusBot")
        .inner_size(1100.0, 780.0)
        .min_inner_size(360.0, 480.0)
        // Shown on the approve screen when this device is linked (D-019).
        .user_agent(if cfg!(target_os = "android") {
            "OrphusBot Android app"
        } else if cfg!(target_os = "macos") {
            "OrphusBot desktop app (macOS)"
        } else {
            "OrphusBot desktop app (linux)"
        })
        .on_navigation(move |url| {
            let same = url.origin() == origin;
            if !same {
                open_externally(&nav, url);
            }
            same
        })
        .on_new_window(move |url, _| {
            open_externally(&popup, &url);
            NewWindowResponse::Deny
        })
        .build()?;
    Ok(())
}

/// From the first-run page: check and save the address, then open it.
/// Async so it runs off the main thread: on Android a sync command that opens
/// a window or asks for a path waits on the main thread and never returns.
#[tauri::command]
async fn connect(app: AppHandle, url: String) -> Result<(), String> {
    let server = parse_server(&url)?;
    let file = config_file(&app).ok_or("No config folder for the app")?;
    if let Some(dir) = file.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    fs::write(&file, server.as_str()).map_err(|e| e.to_string())?;
    open_server(&app, server).map_err(|e| e.to_string())?;
    if let Some(setup) = app.get_webview_window("setup") {
        let _ = setup.close();
    }
    Ok(())
}

/// Starts the app. On Android this is the entry point Tauri's Activity calls.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let reset = std::env::args().any(|a| a == "--reset");
    let built = tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![connect])
        .setup(move |app| {
            let handle = app.handle();
            if reset {
                // Forget the server so the first-run page asks again.
                if let Some(file) = config_file(handle) {
                    let _ = fs::remove_file(file);
                }
            }
            match saved_server(handle).filter(|_| !reset) {
                Some(server) => open_server(handle, server)?,
                None => {
                    WebviewWindowBuilder::new(app, "setup", WebviewUrl::App("index.html".into()))
                        .title("OrphusBot")
                        .inner_size(480.0, 360.0)
                        .build()?;
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!());
    if let Err(e) = built {
        eprintln!("OrphusBot desktop couldn't start: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_addresses() {
        assert_eq!(
            parse_server(" https://bots.example.com/some/path?x#y ")
                .unwrap()
                .as_str(),
            "https://bots.example.com/"
        );
        assert!(parse_server("http://localhost:7480").is_ok());
        assert!(
            parse_server("http://bots.example.com").is_err(),
            "plain http off this machine"
        );
        assert!(parse_server("ftp://bots.example.com").is_err());
        assert!(parse_server("bots.example.com").is_err());
    }
}

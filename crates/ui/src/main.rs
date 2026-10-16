//! orphusbot-ui: the Leptos web app (DESIGN §12). Built for the browser with
//! Trunk (`trunk build` in this folder); the server serves the result, and
//! the desktop and Android apps load the same bundle.

#[cfg(target_arch = "wasm32")]
mod api;
#[cfg(target_arch = "wasm32")]
mod app;

fn main() {
    #[cfg(target_arch = "wasm32")]
    {
        console_error_panic_hook::set_once();
        leptos::mount::mount_to_body(app::App);
    }
}

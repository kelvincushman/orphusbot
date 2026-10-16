//! The desktop launcher; the app itself is in lib.rs, shared with Android.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    orphusbot_desktop_lib::run();
}

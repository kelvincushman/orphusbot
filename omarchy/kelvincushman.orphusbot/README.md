# OrphusBot for Omarchy

A bar widget for the Omarchy shell: your bots at a glance, approvals to answer, and a box to message any bot. It turns the urgent colour when a bot needs you, and sends a desktop notification then and when a bot finishes.

## Install

1. Build and install the command: `cargo build --release -p orphusbot-cli && install -m755 target/release/orphusbot ~/.local/bin/`.
2. Sign this machine in: `orphusbot link http://localhost:7480` (or your server's address), then approve the code from a browser where you have a passkey.
3. Copy this folder (plugins can't be symlinks): `cp -r omarchy/kelvincushman.orphusbot ~/.config/omarchy/plugins/`.
4. Add the widget to the bar from Omarchy's settings, or add `{ "id": "kelvincushman.orphusbot" }` to a bar section in `~/.config/omarchy/shell.json`, then `omarchy restart shell`.
5. Hotkey: add to `~/.config/hypr/bindings.lua`:

   ```lua
   o.bind("SUPER + ALT + B", "OrphusBot", "omarchy-shell kelvincushman.orphusbot toggle")
   ```

Click the icon (or press the hotkey) to open the panel. Pick a bot in the list to message it.

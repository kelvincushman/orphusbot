#!/bin/sh
# Builds the OrphusBot app on a Mac, installs it in /Applications, and keeps an
# SSH tunnel to the server open so the app can use http://localhost:7480 until
# the HTTPS address is set up (docs/DEPLOY.md). Run from a clone of the repo:
#
#   sh scripts/macos-setup.sh <user>@<gpu-box>
#
# Needs: Xcode command line tools (xcode-select --install), Rust (rustup) and
# Node.js. The Mac's SSH key must already be on the GPU box (ssh-copy-id).
set -eu
target=${1:?usage: sh scripts/macos-setup.sh <user>@<gpu-box>}

command -v cargo >/dev/null || { echo "Install Rust first: https://rustup.rs"; exit 1; }
command -v npm >/dev/null || { echo "Install Node.js first: https://nodejs.org"; exit 1; }
ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" true || {
  echo "Can't reach $target with a key. Run: ssh-copy-id $target"; exit 1; }

# The app.
cd "$(dirname "$0")/../crates/desktop"
npm install --no-fund --no-audit
npm run tauri -- build --bundles app
app=$(find ../../target/release/bundle/macos -maxdepth 1 -name '*.app' | head -n 1)
rm -rf /Applications/OrphusBot.app
cp -R "$app" /Applications/OrphusBot.app
echo "Installed /Applications/OrphusBot.app"

# The tunnel, kept up by launchd and started at login.
plist=~/Library/LaunchAgents/io.github.kelvincushman.orphusbot.tunnel.plist
mkdir -p ~/Library/LaunchAgents
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.github.kelvincushman.orphusbot.tunnel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string><string>-N</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-L</string><string>127.0.0.1:7480:127.0.0.1:7480</string>
    <string>$target</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
PLIST
launchctl unload "$plist" 2>/dev/null || true
launchctl load "$plist"
sleep 3
curl -fsS http://localhost:7480/auth/state >/dev/null && echo "Tunnel up: the server answers at http://localhost:7480" \
  || echo "The tunnel isn't answering yet; check: launchctl list | grep orphusbot"
echo "Open OrphusBot, enter http://localhost:7480, and choose Sign in with another device."

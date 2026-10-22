#!/usr/bin/env bash
# Builds the app for Android and Linux from this commit, publishes the Android
# build on the server (DESIGN §12.3), and updates this machine's Linux copy.
# Every build is stamped with the commit, so older copies offer to update.
#
#   scripts/publish-app.sh <user>@<server-host>
#
# Run on the machine whose Android debug key signed the installed app: Android
# only installs an update signed with the same key (ponytail: debug key until a
# release keystore is set up in android/key.properties).
set -euo pipefail
target=${1:?usage: scripts/publish-app.sh <user>@<server-host>}
cd "$(dirname "$0")/../apps/orphusbot_app"
build=$(git rev-parse --short HEAD)
[ -z "$(git status --porcelain)" ] || echo "warning: uncommitted changes are in build $build"

flutter build apk --release --dart-define=ORPHUSBOT_BUILD="$build"
flutter build linux --release --dart-define=ORPHUSBOT_BUILD="$build"

# The server serves this folder at /app (ORPHUSBOT_APP_DIR).
dir='~/.local/share/orphusbot/app'
printf '{"build":"%s","android":"orphusbot.apk","built_at":"%s"}\n' \
  "$build" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > build/latest.json
ssh "$target" "mkdir -p $dir"
scp -q build/app/outputs/flutter-apk/app-release.apk "$target:$dir/orphusbot.apk.new"
ssh "$target" "mv $dir/orphusbot.apk.new $dir/orphusbot.apk"
scp -q build/latest.json "$target:$dir/latest.json"

# This machine's copy.
rsync -a --delete build/linux/x64/release/bundle/ ~/.local/share/orphusbot-app/
echo "Published build $build. Restart the app here to use it; phones offer the update."

#!/bin/sh
# Builds the OrphusBot app (the same Flutter app as on Linux and Android) on a
# Mac and installs it as /Applications/OrphusBot.app. Run it again to update:
# it pulls the newest code first. Paste into Terminal on the Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/kelvincushman/orphusbot/main/scripts/macos-setup.sh | sh
#
# Needs Xcode from the App Store (opened once, licence accepted). The script
# installs CocoaPods (with Homebrew) and its own copy of Flutter if missing.
# Then open OrphusBot, enter the server's address, and choose
# "Sign in with another device" (docs/DEPLOY.md).
set -eu

FLUTTER_VERSION=3.47.7
src="$HOME/.local/share/orphusbot-src"
flutter_dir="$HOME/.local/share/orphusbot-flutter"

xcodebuild -version >/dev/null 2>&1 || {
  echo "Install Xcode from the App Store, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept"
  exit 1; }
if ! command -v pod >/dev/null; then
  command -v brew >/dev/null || {
    echo "Install Homebrew first (https://brew.sh), then run this again."; exit 1; }
  brew install cocoapods
fi

# Flutter, pinned to the version the other builds use.
if [ ! -x "$flutter_dir/bin/flutter" ]; then
  git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$flutter_dir"
fi
export PATH="$flutter_dir/bin:$PATH"

# The code.
if [ -d "$src/.git" ]; then
  git -C "$src" pull -q --ff-only
else
  git clone -q --depth 1 https://github.com/kelvincushman/orphusbot.git "$src"
fi
build=$(git -C "$src" rev-parse --short HEAD)

# The app, stamped with its commit so it can tell when it's out of date.
cd "$src/apps/orphusbot_app"
flutter build macos --release --dart-define=ORPHUSBOT_BUILD="$build"
rm -rf /Applications/OrphusBot.app
cp -R build/macos/Build/Products/Release/OrphusBot.app /Applications/OrphusBot.app
echo "Installed /Applications/OrphusBot.app (build $build)."
echo "Open it and use the server address, such as https://bots.example.com."

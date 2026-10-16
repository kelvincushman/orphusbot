#!/usr/bin/env bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Common ADB helpers for the Wearable mobile E2E suite.
# Each scenario sources this. Keep functions side-effect-free unless their
# name implies action — easier to compose, easier to debug.

set -euo pipefail

PKG="${WEARABLE_APP_PKG:-com.kelvinlee.wearable.dev}"
ACTIVITY="${WEARABLE_APP_ACTIVITY:-com.friend.ios.MainActivity}"
ARTIFACTS_DIR="${WEARABLE_E2E_ARTIFACTS:-/tmp/wearable-adb-e2e}"
mkdir -p "$ARTIFACTS_DIR"

# Single-line stamped log so you can grep for a specific scenario in CI.
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Confirm one (and only one) ADB device is attached. Multi-device runs
# require explicit -s <serial>; we don't support that yet.
require_one_device() {
  local n
  n=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')
  if [ "$n" != "1" ]; then
    log "expected exactly 1 ADB device, found $n. Run \`adb devices\` to inspect."
    exit 2
  fi
  # Wake the screen and verify the device is interactive. We don't try to
  # bypass a lock screen — the operator unlocks once before running.
  adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  sleep 0.5
  local wake
  wake=$(adb shell dumpsys power 2>/dev/null | grep -E '^[[:space:]]*mWakefulness=' | head -1 | tr -d ' ')
  if [[ "$wake" != *"Awake"* ]]; then
    log "device is not Awake ($wake). Unlock the phone manually then re-run."
    exit 3
  fi
  local focus
  focus=$(adb shell dumpsys window 2>/dev/null | grep mCurrentFocus | head -1)
  if printf '%s' "$focus" | grep -qE 'Keyguard|NotificationShade|StatusBar'; then
    log "lock screen / notification shade is active. Unlock the phone, then re-run."
    log "  current focus: $focus"
    exit 3
  fi
}

# Tap by physical pixel coordinates. Prefer tap_text/tap_desc when possible —
# coordinates rot the moment a layout shifts.
tap_xy() { adb shell input tap "$1" "$2"; }

# Resolve a UI element by visible text and tap its center. Uses uiautomator
# dump as the source of truth for element bounds (works in release builds,
# unlike Flutter's semantic tree which needs `flutter run --observatory`).
ui_dump() {
  adb exec-out uiautomator dump /dev/tty 2>/dev/null \
    | grep -o 'UI hierchary dumped to:.*\|<hierarchy.*</hierarchy>' \
    | grep '^<hierarchy' || {
    # Fallback: dump to file, pull, cat.
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null
    adb exec-out cat /sdcard/ui.xml
  }
}

# Tap an element whose `text` attribute matches the given string. Uses
# uiautomator XML parsing in pure bash so we don't take a Python dep.
tap_text() {
  local needle="$1"
  local xml; xml=$(ui_dump)
  # Find the first node containing text="<needle>" and extract bounds.
  # Bounds format: bounds="[x1,y1][x2,y2]"
  local node; node=$(printf '%s' "$xml" | grep -o "<node[^/]*text=\"[^\"]*${needle}[^\"]*\"[^/]*/>" | head -1 || true)
  if [ -z "$node" ]; then
    log "tap_text: '$needle' not found in UI"
    return 1
  fi
  local bounds; bounds=$(printf '%s' "$node" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
  local nums; nums=$(printf '%s' "$bounds" | grep -oE '[0-9]+' | tr '\n' ' ')
  set -- $nums
  local x=$(( ($1 + $3) / 2 ))
  local y=$(( ($2 + $4) / 2 ))
  log "tap_text '$needle' at ($x, $y)"
  tap_xy "$x" "$y"
}

# Type text into the currently-focused field. Spaces use %s ADB escape.
type_text() {
  local s="${1//\ /%s}"
  adb shell input text "$s"
}

# Take a screenshot into the artifacts dir, named by step.
shot() {
  local name="$1"
  local out="${ARTIFACTS_DIR}/$(date +%H%M%S)-${name}.png"
  adb exec-out screencap -p > "$out"
  log "shot → $out"
  printf '%s' "$out"
}

# Force-stop and re-launch the app. Fresh state = repeatable scenarios.
relaunch() {
  log "force-stop $PKG, relaunch ${PKG}/${ACTIVITY}"
  adb shell am force-stop "$PKG"
  sleep 1
  adb shell am start -n "${PKG}/${ACTIVITY}" >/dev/null
  sleep 4   # Flutter cold-start
}

# Wait for a UI element by text. Polls every 0.5s up to $timeout seconds.
wait_for_text() {
  local needle="$1"
  local timeout="${2:-20}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if ui_dump | grep -q "text=\"[^\"]*${needle}"; then return 0; fi
    sleep 0.5
    elapsed=$(( elapsed + 1 ))
  done
  log "wait_for_text: '$needle' not seen within ${timeout}s"
  return 1
}

# Assert the package is currently in the foreground.
assert_foreground() {
  local cur; cur=$(adb shell dumpsys window | grep mCurrentFocus | head -1)
  if ! printf '%s' "$cur" | grep -q "$PKG"; then
    log "assert_foreground failed. mCurrentFocus=$cur"
    return 1
  fi
}

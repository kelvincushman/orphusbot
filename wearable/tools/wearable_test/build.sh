#!/bin/bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Build the BLE wearable emulator as a signed .app bundle. macOS only honors the
# Bluetooth usage description (TCC) when CoreBluetooth runs inside a real bundle,
# so we package the native ObjC binary into WearableSim.app and run the inner
# executable directly (it's native, so NSBundle.mainBundle resolves to the .app).
set -e
cd "$(dirname "$0")"
APP="WearableSim.app"
clang -fobjc-arc -O2 wearable_sim.m -o /tmp/wearable-sim \
  -framework Foundation -framework CoreBluetooth
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp /tmp/wearable-sim "$APP/Contents/MacOS/wearable-sim"
codesign --force --sign - --identifier com.wearable.wearablesim "$APP" >/dev/null 2>&1
echo "built $APP"
echo "run:  ./run.sh --name KelvinLee      (or: $APP/Contents/MacOS/wearable-sim --name KelvinLee)"

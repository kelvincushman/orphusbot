#!/bin/bash

# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.

# Launch the BLE wearable emulator as a registered .app (so macOS grants it
# Bluetooth) and tail its log. Control it from another terminal with wearable_ctl.py.
cd "$(dirname "$0")"
[ -d WearableSim.app ] || ./build.sh
pkill -f WearableSim.app/Contents/MacOS/wearable-sim 2>/dev/null
open WearableSim.app --args --name "${1:-KelvinLee}"
echo "launched WearableSim.app (name=${1:-KelvinLee}). Control: python3 wearable_ctl.py"
echo "tailing /tmp/wearable-sim.log (Ctrl-C to stop tailing; app keeps running):"
sleep 1; tail -f /tmp/wearable-sim.log

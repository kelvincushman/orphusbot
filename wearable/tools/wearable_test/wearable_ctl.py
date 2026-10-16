#!/usr/bin/env python3
# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
"""
wearable_ctl.py — controller for the BLE wearable emulator (WearableSim.app).

The emulator runs as a LaunchServices .app (so macOS grants it Bluetooth) and
listens for commands on 127.0.0.1:8765. This sends commands to it. Stdlib-only.

Usage:
  ./run.sh                       # launches WearableSim.app (grant Bluetooth once)
  python3 wearable_ctl.py        # interactive REPL
  python3 wearable_ctl.py say samples/remind_alice.wav   # one-shot

Commands: audio <wav> | say <wav> | button [agent|single|double|long] | status | quit
Tip: tail the sim log with `tail -f /tmp/wearable-sim.log`.
"""
from __future__ import annotations
import os
import socket
import sys

HOST, PORT = "127.0.0.1", 8765


def _absolutize(line: str) -> str:
    # The sim runs from a different cwd (launched via `open`), so audio/say file
    # args must be absolute paths.
    parts = line.split(maxsplit=1)
    if len(parts) == 2 and parts[0].lower() in ("audio", "say"):
        return f"{parts[0]} {os.path.abspath(os.path.expanduser(parts[1].strip()))}"
    return line


def send(line: str) -> str:
    line = _absolutize(line)
    with socket.create_connection((HOST, PORT), timeout=5) as s:
        s.sendall((line.strip() + "\n").encode())
        s.settimeout(2)
        try:
            return s.recv(4096).decode().strip()
        except socket.timeout:
            return "(no reply)"


def main() -> None:
    if len(sys.argv) > 1:
        print(send(" ".join(sys.argv[1:])))
        return
    print("wearable controller — type commands (audio/say/button/status/quit). Ctrl-D to exit.")
    print("the sim's own log: tail -f /tmp/wearable-sim.log")
    while True:
        try:
            line = input("sim> ").strip()
        except (EOFError, KeyboardInterrupt):
            print(); break
        if not line:
            continue
        try:
            print(send(line))
        except ConnectionRefusedError:
            print("error: WearableSim not running. Start it with ./run.sh first.")
        if line.split()[0].lower() in ("quit", "exit"):
            break


if __name__ == "__main__":
    main()

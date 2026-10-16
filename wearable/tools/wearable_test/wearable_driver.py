#!/usr/bin/env python3
# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
"""
wearable_driver.py — Mac-side test driver for the Wearable device channel.

Exercises the on-device-STT backend end to end WITHOUT a phone or wearable:
registers a device, simulates the cleaned transcript the phone would POST after
on-device Gemma transcription, fires button events, polls LED/haptic commands,
and streams the agent's reply. Stdlib-only (no pip install).

Config (env vars or flags):
  WEARABLE_BASE_URL   e.g. http://wearable-server.local:3141   (--base-url)
  WEARABLE_BEARER     dashboard token for operator routes (--bearer)
  WEARABLE_DEV_ID     device id (default: test-mac-sim)   (--dev-id)
  WEARABLE_DEV_TOKEN  device pairing token                 (--token)
Credentials from `register` are cached in ./.wearable_test.json next to this script.

Examples:
  python3 wearable_driver.py register --label "Mac sim"
  python3 wearable_driver.py button AGENT_REQUEST
  python3 wearable_driver.py text "remind me to call Alice tomorrow"
  python3 wearable_driver.py poll
  python3 wearable_driver.py turn "what's on my calendar today"   # button+text+reply+poll
  python3 wearable_driver.py stream                                # tail the device chat SSE
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CONFIG_PATH = Path(__file__).resolve().parent / ".wearable_test.json"


def load_config() -> dict:
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except Exception:
            return {}
    return {}


def save_config(cfg: dict) -> None:
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2))
    try:
        CONFIG_PATH.chmod(0o600)  # token inside — keep it private
    except OSError:
        pass


def resolve(args, cfg: dict):
    base = args.base_url or os.environ.get("WEARABLE_BASE_URL") or cfg.get("baseUrl")
    bearer = args.bearer or os.environ.get("WEARABLE_BEARER") or cfg.get("bearer")
    dev_id = args.dev_id or os.environ.get("WEARABLE_DEV_ID") or cfg.get("devId") or "test-mac-sim"
    token = args.token or os.environ.get("WEARABLE_DEV_TOKEN") or cfg.get("token")
    chat_id = cfg.get("chatId") or f"device:{dev_id}"
    if not base:
        sys.exit("error: set --base-url or WEARABLE_BASE_URL (e.g. http://<wearable-host>:3141)")
    return base.rstrip("/"), bearer, dev_id, token, chat_id


def _request(method: str, url: str, headers: dict, body: dict | None = None, timeout: float = 60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw.strip().startswith(("{", "[")) else raw)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except urllib.error.URLError as e:
        sys.exit(f"network error reaching {url}: {e.reason}")


def device_headers(dev_id: str, token: str) -> dict:
    if not token:
        sys.exit("error: no device token. Run `register` first, or pass --token / WEARABLE_DEV_TOKEN.")
    return {"X-Device-Id": dev_id, "X-Device-Token": token, "Content-Type": "application/json"}


def bearer_headers(bearer: str) -> dict:
    if not bearer:
        sys.exit("error: no dashboard bearer. Pass --bearer or set WEARABLE_BEARER.")
    return {"Authorization": f"Bearer {bearer}", "Content-Type": "application/json"}


def cmd_register(args, cfg):
    base, bearer, dev_id, _token, _chat = resolve(args, cfg)
    status, body = _request(
        "POST", f"{base}/api/device/register", bearer_headers(bearer),
        {"devId": dev_id, "label": args.label or "Mac test sim"},
    )
    if status >= 400:
        sys.exit(f"register failed ({status}): {body}")
    dev = body.get("device", {})
    cfg.update({
        "baseUrl": base, "bearer": bearer,
        "devId": dev.get("devId", dev_id),
        "token": body.get("pairingToken"),
        "chatId": dev.get("chatId") or f"device:{dev.get('devId', dev_id)}",
    })
    save_config(cfg)
    print(f"registered devId={cfg['devId']} chatId={cfg['chatId']}")
    print(f"pairing token saved to {CONFIG_PATH.name} (chmod 600)")


def cmd_text(args, cfg):
    base, _b, dev_id, token, _chat = resolve(args, cfg)
    status, body = _request(
        "POST", f"{base}/api/device/text", device_headers(dev_id, token),
        {"text": args.text, "overheard": args.overheard, "at": int(time.time() * 1000)},
    )
    print(f"[text] {status} {body}")
    return body if isinstance(body, dict) else {}


def cmd_button(args, cfg):
    base, _b, dev_id, token, _chat = resolve(args, cfg)
    status, body = _request(
        "POST", f"{base}/api/device/event", device_headers(dev_id, token),
        {"kind": "button", "code": args.code, "at": int(time.time() * 1000)},
    )
    print(f"[button {args.code}] {status} {body}")


def cmd_poll(args, cfg):
    base, _b, dev_id, token, _chat = resolve(args, cfg)
    status, body = _request("POST", f"{base}/api/device/command/poll", device_headers(dev_id, token), {})
    cmds = body.get("commands", []) if isinstance(body, dict) else []
    print(f"[poll] {status} — {len(cmds)} command(s): {json.dumps(cmds)}")
    return cmds


def cmd_stream(args, cfg, *, idle_timeout: float = 30):
    """Tail the device chat SSE stream and print assistant_message frames."""
    base, bearer, _d, _t, chat_id = resolve(args, cfg)
    url = f"{base}/api/chat/stream?chatId={urllib.parse.quote(chat_id)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {bearer}", "Accept": "text/event-stream"})
    print(f"[stream] subscribing {chat_id} (Ctrl-C to stop)…")
    deadline = time.time() + idle_timeout
    try:
        with urllib.request.urlopen(req, timeout=idle_timeout + 5) as resp:
            for raw in resp:
                line = raw.decode(errors="replace").rstrip("\n")
                if line.startswith("data:"):
                    payload = line[5:].strip()
                    try:
                        evt = json.loads(payload)
                        kind = evt.get("type") or evt.get("event") or "?"
                        text = evt.get("text") or evt.get("message") or evt.get("output") or ""
                        print(f"  <{kind}> {text}")
                        if kind in ("assistant_message", "done", "error"):
                            deadline = time.time() + idle_timeout
                    except json.JSONDecodeError:
                        print(f"  {payload}")
                if time.time() > deadline:
                    print("[stream] idle timeout"); break
    except KeyboardInterrupt:
        print("\n[stream] stopped")
    except urllib.error.HTTPError as e:
        print(f"[stream] HTTP {e.code}: {e.read().decode(errors='replace')[:200]}")


def cmd_turn(args, cfg):
    """Full simulated wearable turn: AGENT_REQUEST → transcript → reply + LED/haptic."""
    class _A:  # tiny shim to reuse sub-commands
        code = "AGENT_REQUEST"; text = args.text; overheard = False
        base_url = args.base_url; bearer = args.bearer; dev_id = args.dev_id; token = args.token
    cmd_button(_A, cfg)
    time.sleep(0.3)
    cmd_text(_A, cfg)
    print("[turn] waiting for agent reply…")
    cmd_stream(_A, cfg, idle_timeout=args.wait)
    cmd_poll(_A, cfg)


def main():
    p = argparse.ArgumentParser(description="Wearable device-channel test driver")
    p.add_argument("--base-url"); p.add_argument("--bearer")
    p.add_argument("--dev-id"); p.add_argument("--token")
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("register"); r.add_argument("--label")
    t = sub.add_parser("text"); t.add_argument("text"); t.add_argument("--overheard", action="store_true")
    b = sub.add_parser("button"); b.add_argument("code", nargs="?", default="AGENT_REQUEST",
                                                 choices=["AGENT_REQUEST", "SINGLE", "DOUBLE", "LONG"])
    sub.add_parser("poll")
    sub.add_parser("stream")
    tn = sub.add_parser("turn"); tn.add_argument("text"); tn.add_argument("--wait", type=float, default=45)

    args = p.parse_args()
    cfg = load_config()
    {
        "register": cmd_register, "text": cmd_text, "button": cmd_button,
        "poll": cmd_poll, "stream": cmd_stream, "turn": cmd_turn,
    }[args.cmd](args, cfg)


if __name__ == "__main__":
    import urllib.parse  # noqa: E402 (used in cmd_stream)
    main()

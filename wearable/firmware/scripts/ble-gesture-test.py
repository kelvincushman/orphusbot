#!/usr/bin/env python3
# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
#
# Walk a human through the A2 button grammar and check what the firmware
# actually sends, over a plain RTL8761B dongle via raw HCI.
#
# This is the only way to test the grammar: the firmware ships with
# CONFIG_CONSOLE=n and no log output, so a button press is observable only as a
# GATT notify, an LED, or a buzz.
#
# It also plays the app's half of the loop. The firmware arms a 1500 ms
# watchdog on every committed gesture and plays an error cue if no cue write
# comes back, so a listener that only listens would make every correct gesture
# look like a failure.
#
#   ble-gesture-test.py                 # scripted session, all steps
#   ble-gesture-test.py --listen 120    # just watch for 120 s, no prompts
#   ble-gesture-test.py --cues          # play every habitat cue in turn

import argparse, importlib.util, os, struct, subprocess, sys, time

BTN_UUID = "23BA7925-0000-1000-7450-346EAC492E92"
CMD_UUID = "CAB1AB97-0000-1000-8000-00805F9B34FB"

CODES = {1: "D5 SINGLE", 2: "D5 DOUBLE", 3: "D5 LONG", 4: "D5 PRESS", 5: "D5 RELEASE",
         6: "CANCEL (A2 double tap)", 7: "CAPTURE (A2 single tap)",
         8: "LINK_RECOVER (A2 triple tap)", 9: "POWER_OFF_ARMED",
         10: "POWER_OFF_ABORTED", 11: "POWER_OFF_COMMITTED"}

# What the app writes back for each gesture, so the watchdog stays quiet.
CUE_FOR = {7: 0x01, 6: 0x03, 8: 0x07}          # capture_open, discarded, ble_connected
CUES = {0x01: "capture_open", 0x02: "note_filed", 0x03: "discarded", 0x04: "ack",
        0x05: "nop", 0x06: "ble_searching", 0x07: "ble_connected", 0x08: "ble_idle",
        0x09: "budget_warn", 0x0A: "error", 0x0B: "task_running", 0x0C: "awaiting_input"}

STEPS = [
    ("Press and release the button ONCE.", [7], 20),
    ("Press it TWICE quickly.", [6], 20),
    ("Press it THREE times quickly.", [8], 20),
    ("Hold for about 2 seconds, then let go.\n"
     "    (amber ramp at 1.5 s; letting go before 4 s aborts)", [9, 10], 30),
    ("Hold for 5 FULL seconds and keep holding until the light dies.\n"
     "    (this powers the device OFF — that is the test)", [9, 11], 30),
]


def load_client(path):
    spec = importlib.util.spec_from_file_location("gt", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def open_dongle(gt):
    """The RTL8761B forgets its firmware on every power cycle and comes back as a
    ROM that answers HCI but reports no advertisers. Upload before assuming the
    device is missing."""
    d = gt.Dongle()
    d.open(); d.cmd_sync(0x0C03)
    ev = d.cmd_sync(0x1001)
    if not (ev and len(ev) >= 14 and int.from_bytes(ev[7:9], "little") == 0xDFC6):
        d.close()
        r = subprocess.run([sys.executable, gt.RTL_LOAD], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout.strip(), r.stderr.strip())
            raise SystemExit("dongle firmware upload failed")
        time.sleep(1.0)
        d.__init__(); d.open(); d.cmd_sync(0x0C03)
    d.start_readers()
    for op, p in ((0x0C03, b""), (0x0C01, bytes.fromhex("ffffffffffffff3f")),
                  (0x2001, bytes.fromhex("ff00000000000000"))):
        d.cmd(op, p)
    e = d.cmd(0x2002)
    if e and len(e) >= 9:
        d.le_acl_len = int.from_bytes(e[6:8], "little")
        d.acl_credits = e[8] or 4
    return d


def scan(gt, d, addr, secs=20.0):
    d.scanning = True
    d.cmd(0x200B, bytes([0x01, 0x60, 0x00, 0x60, 0x00, 0x00, 0x00]))
    d.cmd(0x200C, bytes([0x01, 0x00]))
    hit, t0 = None, time.time()
    while time.time() - t0 < secs and hit is None:
        ev = d.get_event(lambda e: e and e[0] == 0x3E and len(e) > 2 and e[2] == 0x02, 0.5)
        if not ev:
            continue
        for _et, at, a, _data, _rssi, _raw in gt.parse_adv_reports(ev):
            if a == addr:
                hit = (a, at); break
    d.cmd(0x200C, bytes([0x00, 0x00])); d.scanning = False
    d.evbuf = [e for e in d.evbuf if not (e[0] == 0x3E and len(e) > 2 and e[2] == 0x02)]
    return hit


def discover(gt, d):
    """{uuid: (value_handle, cccd_handle_or_None)} across every service."""
    svcs, start = [], 1
    while True:
        r = d.att(bytes([gt.ATT_READ_GROUP_REQ]) + struct.pack("<HHH", start, 0xFFFF, 0x2800),
                  (gt.ATT_READ_GROUP_RSP,), tmo=5.0)
        if r is None or r[0] == gt.ATT_ERROR_RSP:
            break
        ln, last = r[1], start
        for off in range(2, len(r), ln):
            rec = r[off:off + ln]
            if len(rec) < ln:
                break
            svcs.append((int.from_bytes(rec[0:2], "little"),
                         int.from_bytes(rec[2:4], "little"), gt.uuid_str(rec[4:])))
            last = svcs[-1][1]
        start = last + 1
        if last >= 0xFFFF:
            break
    out = {}
    for sh, eh, _u in svcs:
        chars, s = [], sh
        while s <= eh:
            r = d.att(bytes([gt.ATT_READ_BY_TYPE_REQ]) + struct.pack("<HHH", s, eh, 0x2803),
                      (gt.ATT_READ_BY_TYPE_RSP,), tmo=5.0)
            if r is None or r[0] == gt.ATT_ERROR_RSP:
                break
            ln, last = r[1], s
            for off in range(2, len(r), ln):
                rec = r[off:off + ln]
                if len(rec) < ln:
                    break
                chars.append({"decl": int.from_bytes(rec[0:2], "little"),
                              "vh": int.from_bytes(rec[3:5], "little"),
                              "uuid": gt.uuid_str(rec[5:])})
                last = chars[-1]["decl"]
            s = last + 1
        for i, c in enumerate(chars):
            stop = chars[i + 1]["decl"] - 1 if i + 1 < len(chars) else eh
            cccd = None
            if c["vh"] < stop:
                r = d.att(bytes([gt.ATT_FIND_INFO_REQ]) + struct.pack("<HH", c["vh"] + 1, stop),
                          (gt.ATT_FIND_INFO_RSP,), tmo=5.0)
                if r is not None and r[0] == gt.ATT_FIND_INFO_RSP and r[1] == 0x01:
                    for off in range(2, len(r), 4):
                        rec = r[off:off + 4]
                        if len(rec) == 4 and int.from_bytes(rec[2:4], "little") == 0x2902:
                            cccd = int.from_bytes(rec[0:2], "little")
            out[c["uuid"].upper()] = (c["vh"], cccd)
    return out


def decode(val):
    """Firmware sends int32 LE code + int32 LE sequence."""
    if len(val) >= 8:
        return int.from_bytes(val[0:4], "little"), int.from_bytes(val[4:8], "little")
    if len(val) >= 4:
        return int.from_bytes(val[0:4], "little"), None
    return (val[0] if val else None), None


def collect(d, btn_h, cmd_h, secs, reply_cues=True):
    """Return [(t, code)] seen in the window, answering the watchdog as we go."""
    seen, end = [], time.time() + secs
    while time.time() < end:
        d.drain_acl(0.05)
        while d.notifs:
            ts, h, val = d.notifs.pop(0)
            if h != btn_h:
                continue
            code, seq = decode(val)
            seen.append((time.time(), code))
            print("      -> %-28s raw=%s seq=%s" % (CODES.get(code, "UNKNOWN %s" % code),
                                                    val.hex(), seq))
            cue = CUE_FOR.get(code)
            if reply_cues and cue is not None and cmd_h is not None:
                d.send_acl(bytes([0x52]) + struct.pack("<H", cmd_h) + bytes([0x06, cue, 0, 0]))
                print("         (replied %s, disarming the 1500 ms watchdog)" % CUES[cue])
        if d.get_event(lambda e: e and e[0] == 0x05, 0.0):
            print("      -> LINK DROPPED (the device powered off)")
            d.conn_handle = None
            seen.append((time.time(), "DISCONNECT"))
            return seen
    return seen


def main():
    ap = argparse.ArgumentParser(description="Hardware test for the A2 button grammar.")
    ap.add_argument("--addr", required=True, help="wearable BLE address, e.g. AA:BB:CC:DD:EE:FF")
    ap.add_argument("--client", default=os.path.expanduser("~/dev/ble-gatt-test.py"))
    ap.add_argument("--listen", type=float, metavar="SECS",
                    help="just watch for this long, no prompts")
    ap.add_argument("--cues", action="store_true", help="play every habitat cue in turn")
    a = ap.parse_args()

    gt = load_client(a.client)
    d = open_dongle(gt)
    try:
        hit = scan(gt, d, a.addr)
        if not hit:
            raise SystemExit("wearable not advertising at %s" % a.addr)
        addr, at = hit
        params = (struct.pack("<HH", 0x60, 0x30) + bytes([0x00, at]) + gt.addr_le(addr)
                  + bytes([0x00]) + struct.pack("<HHHHHH", 0x18, 0x28, 0, 0x1F4, 0, 0))
        d.cmd(0x200D, params, tmo=3.0)
        cc = d.get_event(lambda e: e and e[0] == 0x3E and len(e) > 2 and e[2] == 0x01, 10.0)
        if not cc or cc[3] != 0:
            d.cmd(0x200E); raise SystemExit("could not connect")
        d.conn_handle = int.from_bytes(cc[4:6], "little") & 0x0FFF
        d.att(bytes([gt.ATT_MTU_REQ]) + struct.pack("<H", 247), (gt.ATT_MTU_RSP,), tmo=5.0)

        chars = discover(gt, d)
        btn = chars.get(BTN_UUID.upper())
        cmd = chars.get(CMD_UUID.upper())
        if not btn:
            raise SystemExit("no button characteristic; have %s" % list(chars)[:8])
        btn_h, btn_cccd = btn
        cmd_h = cmd[0] if cmd else None
        print("connected. button vh=0x%04X cccd=%s   cmd vh=%s\n"
              % (btn_h, "0x%04X" % btn_cccd if btn_cccd else "none",
                 "0x%04X" % cmd_h if cmd_h else "none"))
        if btn_cccd:
            d.att(bytes([gt.ATT_WRITE_REQ]) + struct.pack("<H", btn_cccd) + bytes([0x01, 0x00]),
                  (gt.ATT_WRITE_RSP,), tmo=6.0)

        if a.cues:
            for cid, name in CUES.items():
                print("  cue 0x%02X %s" % (cid, name))
                d.send_acl(bytes([0x52]) + struct.pack("<H", cmd_h) + bytes([0x06, cid, 0, 0]))
                time.sleep(3.0)
            return 0

        if a.listen:
            print("listening %.0f s — press the button however you like\n" % a.listen)
            collect(d, btn_h, cmd_h, a.listen)
            return 0

        failures = 0
        for i, (prompt, expect, secs) in enumerate(STEPS, 1):
            print("STEP %d/%d  %s" % (i, len(STEPS), prompt))
            print("    expecting %s   (%.0f s)" % ([CODES[c] for c in expect], secs))
            seen = [c for _t, c in collect(d, btn_h, cmd_h, secs)]
            codes = [c for c in seen if c != "DISCONNECT"]
            ok = codes == expect
            print("    %s  expected %s got %s\n" % ("PASS" if ok else "FAIL", expect, codes))
            if not ok:
                failures += 1
            if d.conn_handle is None:
                print("    (link gone — the device is off, which is the last step's pass condition)")
                break
        print("=" * 60)
        print("%d/%d steps passed" % (len(STEPS) - failures, len(STEPS)))
        return 1 if failures else 0
    finally:
        try:
            if d.conn_handle is not None:
                d.cmd(0x0406, struct.pack("<H", d.conn_handle) + bytes([0x13]), tmo=3.0)
        finally:
            d.close(); print("[finally] USB released")


if __name__ == "__main__":
    sys.exit(main())

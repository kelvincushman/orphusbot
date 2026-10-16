#!/usr/bin/env python3
# Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT.
#
# Flash the wearable over BLE using the legacy Nordic DFU protocol (SDK 11 /
# Adafruit nRF52 bootloader), driven from a plain Realtek RTL8761B dongle over
# raw HCI.
#
# Why this exists: the two documented ways in are a physical double-tap into the
# UF2 volume, and `adafruit-nrfutil dfu ble`, which needs a Nordic dongle running
# connectivity firmware. Neither suits an open-source project on generic
# hardware, and neither works unattended. Writing 0x06 to the running firmware's
# DFU control point (transport.c) sets GPREGRET 0xA8 and resets into the
# bootloader's OTA mode -- at which point this script can finish the job with no
# hands on the device.
#
# STATUS: THE TRANSPORT WORKS; THE RESULT DOES NOT BOOT. On 2026-09-07 this
# script drove a complete legacy DFU against the Adafruit bootloader -- START_DFU,
# init packet, 12709 data packets (254168 B in 183 s at 1.4 kB/s), VALIDATE and
# ACTIVATE_AND_RESET all ACKed with success -- and the application never came back.
# Leading explanation, NOT yet proven: legacy DFU transports a raw .bin with no
# address in it, so the bootloader writes it at whatever it considers the
# application start, while this Zephyr image is linked at 0x27000 (see the
# segment record at the top of zephyr.hex). UF2 carries an absolute address per
# 256-byte block, which is why double-tap flashing of the same image works.
# Until someone confirms the bootloader's application start and either relinks or
# offsets to match, USE UF2: double-tap reset and copy zephyr.uf2 to XIAO-SENSE.
# --i-know-it-does-not-boot exists so the next person can re-test in one command.
#
# ponytail: the ATT/L2CAP/HCI plumbing is imported from ble-gatt-test.py rather
# than copied. If that file ever moves into this directory, drop --client.
#
#   ./ble-dfu-flash.py --package fw.zip                 # find AdaDFU and flash
#   ./ble-dfu-flash.py --package fw.zip --addr CC:..:F0 # or name the target
#   ./ble-dfu-flash.py --package fw.zip --enter CC:..:EF # reboot the app first

import argparse, importlib.util, json, os, struct, subprocess, sys, time, zipfile

# --- legacy DFU (00001530-1212-EFDE-1523-785FEABCD123) ----------------------
DFU_SVC    = "00001530-1212-EFDE-1523-785FEABCD123"
DFU_CTRL   = "00001531-1212-EFDE-1523-785FEABCD123"
DFU_PACKET = "00001532-1212-EFDE-1523-785FEABCD123"

START_DFU, INIT_DFU, RECEIVE_FW, VALIDATE, ACTIVATE_RESET = 0x01, 0x02, 0x03, 0x04, 0x05
PRN_REQ, RESPONSE, PKT_RECEIPT = 0x08, 0x10, 0x11
APP_IMAGE = 0x04
DFU_OK = 0x01
DFU_ERRS = {1: "success", 2: "invalid state", 3: "not supported", 4: "data size exceeds limit",
            5: "CRC error", 6: "operation failed"}

CHUNK = 20          # legacy DFU is defined in 20-byte packets; do not raise
PRN_EVERY = 10      # receipt every N packets -- flow control for flash erase/write


def load_client(path):
    spec = importlib.util.spec_from_file_location("gt", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def open_dongle(gt):
    """Open the dongle, uploading the RTL8761B patch first if it is in ROM mode.

    The dongle forgets its firmware on every power cycle and comes back as a
    bare ROM that answers HCI but never reports an advertiser. Skipping this
    step looks exactly like "the device is not there", which cost an evening.
    """
    d = gt.Dongle()
    d.open(); d.cmd_sync(0x0C03)
    ev = d.cmd_sync(0x1001)                                   # local version
    loaded = bool(ev and len(ev) >= 14
                  and int.from_bytes(ev[7:9], "little") == 0xDFC6
                  and int.from_bytes(ev[12:14], "little") == 0xD922)
    if not loaded:
        print("  dongle in ROM mode; uploading patch via %s" % gt.RTL_LOAD)
        d.close()
        r = subprocess.run([sys.executable, gt.RTL_LOAD], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout.strip()); print(r.stderr.strip())
            raise SystemExit("dongle firmware upload failed")
        time.sleep(1.0)
        d.__init__(); d.open(); d.cmd_sync(0x0C03)
    d.start_readers()
    d.cmd(0x0C03)                                             # reset
    d.cmd(0x0C01, bytes.fromhex("ffffffffffffff3f"))          # event mask
    d.cmd(0x2001, bytes.fromhex("ff00000000000000"))          # LE event mask
    e = d.cmd(0x2002)                                         # LE read buffer size
    if e and len(e) >= 9:
        d.le_acl_len = int.from_bytes(e[6:8], "little")
        d.acl_credits = e[8] or 4
    return d


def scan(gt, d, want_addr=None, want_name=None, secs=20.0):
    d.scanning = True
    d.cmd(0x200B, bytes([0x01, 0x30, 0x00, 0x30, 0x00, 0x00, 0x00]))
    d.cmd(0x200C, bytes([0x01, 0x00]))
    hit, t0 = None, time.time()
    try:
        while time.time() - t0 < secs and hit is None:
            ev = d.get_event(lambda e: e and e[0] == 0x3E and len(e) > 2 and e[2] == 0x02, 0.5)
            if not ev:
                continue
            for _et, at, a, data, _rssi, _raw in gt.parse_adv_reports(ev):
                nm = gt.ad_name(data)
                if want_addr and a.upper() == want_addr.upper():
                    hit = (a, at, nm); break
                if want_name and nm and want_name.lower() in nm.lower():
                    hit = (a, at, nm); break
    finally:
        d.cmd(0x200C, bytes([0x00, 0x00])); d.scanning = False
        d.evbuf = [e for e in d.evbuf if not (e[0] == 0x3E and len(e) > 2 and e[2] == 0x02)]
    return hit


def connect(gt, d, addr, addr_type, fast=True):
    """fast=True asks for a 7.5-15 ms interval; DFU throughput lives or dies on this."""
    lo, hi = (0x06, 0x0C) if fast else (0x18, 0x28)
    params = (struct.pack("<HH", 0x60, 0x30) + bytes([0x00, addr_type]) + gt.addr_le(addr)
              + bytes([0x00]) + struct.pack("<HHHHHH", lo, hi, 0, 0x1F4, 0, 0))
    d.cmd(0x200D, params, tmo=3.0)
    cc = d.get_event(lambda e: e and e[0] == 0x3E and len(e) > 2 and e[2] == 0x01, 12.0)
    if not cc or cc[3] != 0:
        d.cmd(0x200E)
        return False
    d.conn_handle = int.from_bytes(cc[4:6], "little") & 0x0FFF
    return True


def discover(gt, d):
    """Return {uuid: (value_handle, cccd_handle_or_None)} for the DFU service."""
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
    m = [s for s in svcs if s[2].upper() == DFU_SVC.upper()]
    if not m:
        raise SystemExit("no legacy DFU service on this device; services=%s"
                         % [s[2] for s in svcs])
    sh, eh, _ = m[0]

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
            decl = int.from_bytes(rec[0:2], "little")
            chars.append({"decl": decl, "props": rec[2],
                          "vh": int.from_bytes(rec[3:5], "little"),
                          "uuid": gt.uuid_str(rec[5:])})
            last = decl
        s = last + 1

    # CCCD for each char: the 0x2902 descriptor between this value handle and the next decl.
    out = {}
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


class Dfu:
    def __init__(self, gt, d, ctrl, ctrl_cccd, packet):
        self.gt, self.d = gt, d
        self.ctrl, self.ctrl_cccd, self.packet = ctrl, ctrl_cccd, packet

    def _wait_notify(self, tmo, want_op=None):
        end = time.time() + tmo
        while time.time() < end:
            self.d.drain_acl(0.05)
            while self.d.notifs:
                _ts, h, val = self.d.notifs.pop(0)
                if h != self.ctrl or not val:
                    continue
                if want_op is None or val[0] == want_op:
                    return val
            if self.d.get_event(lambda e: e and e[0] == 0x05, 0.0):
                raise SystemExit("link dropped mid-DFU")
        return None

    def ctrl_write(self, payload):
        r = self.d.att(bytes([self.gt.ATT_WRITE_REQ]) + struct.pack("<H", self.ctrl) + payload,
                       (self.gt.ATT_WRITE_RSP,), tmo=6.0)
        if r is None or r[0] == self.gt.ATT_ERROR_RSP:
            raise SystemExit("control-point write %s failed: %s"
                             % (payload.hex(), r.hex() if r else "no response"))

    def pkt_write(self, payload):
        self.d.send_acl(bytes([0x52]) + struct.pack("<H", self.packet) + payload)

    def expect(self, req_op, tmo=25.0):
        n = self._wait_notify(tmo, RESPONSE)
        if n is None:
            raise SystemExit("no DFU response to op 0x%02X within %.0fs" % (req_op, tmo))
        if len(n) < 3 or n[1] != req_op:
            raise SystemExit("unexpected DFU response %s to op 0x%02X" % (n.hex(), req_op))
        if n[2] != DFU_OK:
            raise SystemExit("DFU op 0x%02X rejected: %s"
                             % (req_op, DFU_ERRS.get(n[2], "code %d" % n[2])))

    def run(self, image, init_packet):
        print("  enabling control-point notifications (CCCD 0x%04X)" % self.ctrl_cccd)
        r = self.d.att(bytes([self.gt.ATT_WRITE_REQ]) + struct.pack("<H", self.ctrl_cccd)
                       + bytes([0x01, 0x00]), (self.gt.ATT_WRITE_RSP,), tmo=6.0)
        if r is None or r[0] == self.gt.ATT_ERROR_RSP:
            raise SystemExit("could not subscribe to the DFU control point")

        print("  START_DFU (application, %d bytes)" % len(image))
        self.ctrl_write(bytes([START_DFU, APP_IMAGE]))
        self.pkt_write(struct.pack("<III", 0, 0, len(image)))
        self.expect(START_DFU)

        print("  init packet (%d bytes)" % len(init_packet))
        self.ctrl_write(bytes([INIT_DFU, 0x00]))
        for i in range(0, len(init_packet), CHUNK):
            self.pkt_write(init_packet[i:i + CHUNK])
        self.ctrl_write(bytes([INIT_DFU, 0x01]))
        self.expect(INIT_DFU)

        print("  packet-receipt every %d packets" % PRN_EVERY)
        self.ctrl_write(bytes([PRN_REQ]) + struct.pack("<H", PRN_EVERY))

        print("  RECEIVE_FIRMWARE_IMAGE")
        self.ctrl_write(bytes([RECEIVE_FW]))

        total = (len(image) + CHUNK - 1) // CHUNK
        t0, sent, last_pct = time.time(), 0, -1
        for i in range(0, len(image), CHUNK):
            self.pkt_write(image[i:i + CHUNK])
            sent += 1
            if sent % PRN_EVERY == 0:
                n = self._wait_notify(20.0, PKT_RECEIPT)
                if n is None:
                    raise SystemExit("no packet receipt after %d/%d packets" % (sent, total))
            pct = sent * 100 // total
            if pct != last_pct and pct % 5 == 0:
                el = time.time() - t0
                print("    %3d%%  %6d/%d packets  %5.1fs  %.1f kB/s"
                      % (pct, sent, total, el, (sent * CHUNK / 1024) / max(el, 0.001)))
                last_pct = pct
        print("  image sent in %.1fs" % (time.time() - t0))
        self.expect(RECEIVE_FW, tmo=40.0)

        print("  VALIDATE")
        self.ctrl_write(bytes([VALIDATE]))
        self.expect(VALIDATE, tmo=40.0)

        print("  ACTIVATE_AND_RESET")
        self.ctrl_write(bytes([ACTIVATE_RESET]))


def enter_bootloader(gt, d, addr):
    """Write 0x06 to the RUNNING firmware's DFU control point: GPREGRET 0xA8 + reset."""
    hit = scan(gt, d, want_addr=addr, secs=15.0)
    if not hit:
        print("  app not advertising at %s -- assuming it is already in the bootloader" % addr)
        return
    a, at, nm = hit
    print("  found app %s (%r); asking it to reboot into DFU" % (a, nm))
    if not connect(gt, d, a, at, fast=False):
        raise SystemExit("could not connect to the app")
    try:
        d.att(bytes([gt.ATT_MTU_REQ]) + struct.pack("<H", 247), (gt.ATT_MTU_RSP,), tmo=5.0)
        chars = discover(gt, d)
        ctrl = chars.get(DFU_CTRL.upper())
        if not ctrl:
            raise SystemExit("running firmware exposes no DFU control point")
        d.send_acl(bytes([0x52]) + struct.pack("<H", ctrl[0]) + bytes([0x06]))
        d.get_event(lambda e: e and e[0] == 0x05, 8.0)
        print("  reset into bootloader")
    finally:
        d.conn_handle = None
    time.sleep(2.0)


def main():
    ap = argparse.ArgumentParser(description="Flash the wearable over BLE legacy DFU.")
    ap.add_argument("--package", required=True, help="DFU .zip from adafruit-nrfutil dfu genpkg")
    ap.add_argument("--addr", help="bootloader address (default: first AdaDFU advertiser)")
    ap.add_argument("--enter", metavar="APP_ADDR",
                    help="first ask the running firmware at this address to reboot into DFU")
    ap.add_argument("--client", default=os.path.expanduser("~/dev/ble-gatt-test.py"),
                    help="path to the raw-HCI GATT client this borrows its transport from")
    ap.add_argument("--i-know-it-does-not-boot", action="store_true",
                    help="run anyway (see the STATUS block at the top of this file)")
    a = ap.parse_args()

    if not a.i_know_it_does_not_boot:
        raise SystemExit(
            "Refusing to run: a full DFU through this script has completed successfully\n"
            "and left the device unbootable. See the STATUS block at the top of this file.\n"
            "To flash: double-tap reset and copy zephyr.uf2 to /Volumes/XIAO-SENSE.\n"
            "To re-test this path anyway: pass --i-know-it-does-not-boot.")

    with zipfile.ZipFile(a.package) as z:
        man = json.loads(z.read("manifest.json"))["manifest"]
        app = man.get("application") or {}
        if not app:
            raise SystemExit("package has no application image")
        image = z.read(app["bin_file"])
        init_packet = z.read(app["dat_file"])
    print("package %s: %s (%d B) + %s (%d B)"
          % (os.path.basename(a.package), app["bin_file"], len(image),
             app["dat_file"], len(init_packet)))

    gt = load_client(a.client)
    d = open_dongle(gt)
    try:
        if a.enter:
            enter_bootloader(gt, d, a.enter)

        print("scanning for the bootloader...")
        hit = scan(gt, d, want_addr=a.addr, want_name=None if a.addr else "AdaDFU", secs=25.0)
        if not hit:
            raise SystemExit("no bootloader found. Double-tap reset, or pass --enter <app addr>.")
        addr, at, nm = hit
        print("bootloader %s (%r)" % (addr, nm))

        if not connect(gt, d, addr, at, fast=True):
            raise SystemExit("could not connect to the bootloader")
        print("connected, handle 0x%04X" % d.conn_handle)
        d.att(bytes([gt.ATT_MTU_REQ]) + struct.pack("<H", 247), (gt.ATT_MTU_RSP,), tmo=5.0)

        chars = discover(gt, d)
        ctrl = chars.get(DFU_CTRL.upper())
        packet = chars.get(DFU_PACKET.upper())
        if not ctrl or not packet:
            raise SystemExit("bootloader is missing the DFU characteristics: %s" % list(chars))
        if ctrl[1] is None:
            raise SystemExit("DFU control point has no CCCD; cannot receive responses")
        print("  ctrl vh=0x%04X cccd=0x%04X   packet vh=0x%04X" % (ctrl[0], ctrl[1], packet[0]))

        Dfu(gt, d, ctrl[0], ctrl[1], packet[0]).run(image, init_packet)
        d.conn_handle = None          # the device resets; do not try to disconnect politely
        print("\nflashed. waiting for the application to come back...")

        time.sleep(3.0)
        back = scan(gt, d, want_name="wearable", secs=30.0)
        print("application advertising: %s" % ("yes, %s (%r)" % (back[0], back[2]) if back else "NOT SEEN within 30 s"))
        return 0 if back else 1
    finally:
        try:
            if d.conn_handle is not None:
                d.cmd(0x0406, struct.pack("<H", d.conn_handle) + bytes([0x13]), tmo=3.0)
        finally:
            d.close()
            print("[finally] USB released")


if __name__ == "__main__":
    sys.exit(main())

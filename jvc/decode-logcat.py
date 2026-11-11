#!/usr/bin/env python3
"""Decode JVC Remote frames from an Android logcat capture.

JVC Remote logs every RFCOMM frame it sends and receives (tag OpenLinkService_BT,
"Outstream values" / "Instream values"), with bytes printed as signed hex. This
unescapes them, checks the CRC-16/ARC and prints one line per frame, plus touch
events so presses can be matched to frames. See PROTOCOL.md.

Capture on the PC:   adb logcat -c; adb logcat -v time > jvc-logcat.txt
Decode:              python decode-logcat.py jvc-logcat.txt [--after HH:MM:SS] [--all]
"""
import argparse
import re

FRAME_RE = re.compile(r"(Outstream values <--|Instream values->)\s*(.*)$")
TOUCH_RE = re.compile(r"Delivering touch to \(\d+\): action: 0x0")
NOTIFY_RE = re.compile(r"Inside (ntfy_\w+)")


def crc16_arc(data: bytes) -> int:
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c


def unescape(raw: bytes) -> bytes:
    """Strip the 7e/7c flags and undo 7d-escaping."""
    body, i = bytearray(), 1
    while i < len(raw) - 1:
        if raw[i] == 0x7D:
            body.append(raw[i + 1] ^ 0x20)
            i += 2
        else:
            body.append(raw[i])
            i += 1
    return bytes(body)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("logfile")
    ap.add_argument("--after", default="", help="only lines after this HH:MM:SS[.mmm]")
    ap.add_argument("--all", action="store_true", help="also show ACKs and the 3b/5b 02 hello")
    args = ap.parse_args()

    bad = 0
    with open(args.logfile, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2 or parts[1] <= args.after:
                continue
            t = parts[1]
            if TOUCH_RE.search(line):
                print(t, " ---- TOUCH ----")
                continue
            m = NOTIFY_RE.search(line)
            if m:
                print(t, " #", m.group(1))
                continue
            m = FRAME_RE.search(line)
            if not m:
                continue
            raw = bytes(int(x, 16) & 0xFF for x in m.group(2).split())
            if len(raw) < 14 or raw[0] != 0x7E or raw[-1] != 0x7C:
                continue
            body = unescape(raw)
            crc_ok = crc16_arc(body[:-2]) == int.from_bytes(body[-2:], "big")
            bad += not crc_ok
            src, grp, cmd, seq, ack, ln = body[2], body[4], body[5], body[6], body[7], body[10]
            if not args.all and (ack or (grp in (0x3B, 0x5B) and cmd == 0x02)):
                continue
            pl = body[11:11 + ln]
            who = {0xA4: "phone", 0x50: "radio", 0x16: "tuner", 0x4C: "radio-bt"}.get(src, f"{src:02x}")
            d = "TX" if m.group(1).startswith("Out") else "RX"
            txt = "".join(chr(c) if 32 <= c < 127 else "." for c in pl).strip(". ")
            print(t, f" {d} {who:8} {grp:02x} {cmd:02x} seq={seq:02x}{' ACK' if ack else ''}"
                     f" [{pl.hex(' ')}]" + (f" '{txt}'" if len(txt) > 2 else "")
                     + ("" if crc_ok else "  CRC MISMATCH"))
    if bad:
        print(f"{bad} frame(s) failed the CRC check")


if __name__ == "__main__":
    main()

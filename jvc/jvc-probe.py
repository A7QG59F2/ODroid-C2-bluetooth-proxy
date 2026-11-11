#!/usr/bin/env python3
"""
jvc-probe.py – talk to a JVC car receiver (e.g. KD-SX38MBT) over Bluetooth
Classic SPP / RFCOMM from the Odroid.

The receiver must already be paired + trusted with this Odroid (see jvc/README.md).

Examples
  # find which RFCOMM channel the receiver answers on
  sudo ./jvc-probe.py scan

  # open the link and just print everything the receiver sends (status packets)
  sudo ./jvc-probe.py listen --channel 1

  # send captured bytes (hex) and print the reply; repeat --send to replay a handshake
  sudo ./jvc-probe.py send --channel 1 --send "aa 55 01 02" --send "aa 55 10 01"

  # speak the protocol (see PROTOCOL.md): answer the hello, ACK everything, then run
  # commands given as "grp cmd [payload…]" hex, or "sleep N"
  sudo ./jvc-probe.py talk --do "11 05 08" --do "sleep 2" --do "11 05 07"

The MAC defaults to JVC_MAC from /etc/odroid-ha/odroid-ha.conf.
"""
import argparse
import re
import socket
import sys
import time

PHONE, RADIO = 0xA4, 0x50
UNITS = {0xA4: "us", 0x50: "radio", 0x16: "tuner", 0x4C: "radio-bt"}

CONF = "/etc/odroid-ha/odroid-ha.conf"


def conf_value(key, pattern):
    try:
        with open(CONF) as f:
            for line in f:
                m = re.match(r'\s*' + key + r'="?(' + pattern + r')"?', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def conf_mac():
    return conf_value("JVC_MAC", r"[0-9A-Fa-f:]{17}")


def conf_channel():
    ch = conf_value("JVC_CHANNEL", r"\d+")
    return int(ch) if ch else None


def connect(mac, channel, timeout=8.0):
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
    s.settimeout(timeout)
    s.connect((mac, channel))
    return s


def hexdump(b):
    return " ".join(f"{x:02x}" for x in b)


def read_for(s, seconds):
    end = time.time() + seconds
    s.settimeout(0.3)
    while time.time() < end:
        try:
            data = s.recv(1024)
        except socket.timeout:
            continue
        except OSError as e:
            print(f"<< link dropped by receiver ({e.strerror or e})")
            return False
        if not data:
            print("<< link closed by receiver")
            return False
        print(f"<< [{time.strftime('%H:%M:%S')}] {hexdump(data)}   {data!r}")
    return True


def cmd_scan(a):
    print(f"Scanning RFCOMM channels 1-30 on {a.mac} ...")
    found = []
    for ch in range(1, 31):
        try:
            s = connect(a.mac, ch, timeout=4)
            print(f"  channel {ch}: OPEN")
            found.append(ch)
            read_for(s, 1.5)
            s.close()
        except OSError as e:
            print(f"  channel {ch}: {e.strerror or e}")
    print("Open channels:", found or "none (is the receiver on, paired, trusted, and the phone's Bluetooth off?)")


def cmd_listen(a):
    s = connect(a.mac, a.channel)
    print(f"Connected to {a.mac} ch {a.channel}. Ctrl+C to stop.")
    try:
        while read_for(s, 3600):
            pass
    except KeyboardInterrupt:
        pass
    s.close()


def cmd_send(a):
    s = connect(a.mac, a.channel)
    print(f"Connected to {a.mac} ch {a.channel}")
    for h in a.send:
        payload = bytes.fromhex(h.replace(":", " "))
        print(f">> {hexdump(payload)}")
        s.sendall(payload)
        if not read_for(s, a.wait):
            break
    s.close()


# ---------------------------------------------------------------- protocol (PROTOCOL.md)

def crc16_arc(data):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c


def build_frame(src, dst, grp, cmd, seq, payload=b"", ack=False):
    body = bytes([0x0B, 0x01, src, dst, grp, cmd, seq & 0xFF, 1 if ack else 0, 0x01, 0x00, len(payload)]) + payload
    body += crc16_arc(body).to_bytes(2, "big")
    out = bytearray([0x7E])
    for b in body:
        out += bytes([0x7D, b ^ 0x20]) if b in (0x7D, 0x7E) else bytes([b])
    out.append(0x7C)
    return bytes(out)


class Frame:
    def __init__(self, body):
        self.src, self.dst, self.grp, self.cmd = body[2], body[3], body[4], body[5]
        self.seq, self.ack = body[6], bool(body[7])
        self.payload = body[11:11 + body[10]]
        self.crc_ok = crc16_arc(body[:-2]) == int.from_bytes(body[-2:], "big")

    def __str__(self):
        txt = "".join(chr(c) if 32 <= c < 127 else "." for c in self.payload).strip(". ")
        return (f"{UNITS.get(self.src, f'{self.src:02x}'):8} {self.grp:02x} {self.cmd:02x} seq={self.seq:02x}"
                f"{' ACK' if self.ack else ''} [{hexdump(self.payload)}]"
                + (f" '{txt}'" if len(txt) > 2 else "") + ("" if self.crc_ok else "  CRC MISMATCH"))


def describe(f):
    """Human meaning of the notifications we know (PROTOCOL.md), or ''."""
    p, key = f.payload, (f.grp, f.cmd)
    if key == (0x12, 0x04) and p:
        return f"volume = {p[0]}"
    if key == (0x12, 0x02):
        return f"EQ = {p.decode('ascii', 'replace').strip()}"
    if key == (0x12, 0x01) and len(p) >= 3:
        return f"source = {p[1]:02x} {p[2]:02x}"
    if key == (0x8C, 0x01) and len(p) == 4:
        f_ = int.from_bytes(p[2:4], "big")
        return f"FM {f_ / 100:.1f} MHz" if p[0] == 2 else f"AM {f_} kHz" if p[0] == 1 else ""
    if key == (0x5C, 0x20) and p:
        return f"RDS '{p[1:].decode('ascii', 'replace')}'"
    if key in ((0x5B, 0x80), (0x5B, 0x81), (0x5B, 0x91)) and len(p) > 18:
        what = {0x80: "title", 0x81: "artist", 0x91: "album"}[f.cmd]
        return f"{what} '{p[18:].split(b'\0')[0].decode('utf-8', 'replace')}'"
    return ""


class Link:
    """RFCOMM link that frames, ACKs and answers the radio like JVC Remote does."""

    def __init__(self, sock, quiet_grp=()):
        self.s, self.buf, self.seq = sock, bytearray(), 0
        self.acked, self.quiet = set(), set(quiet_grp)
        self.alive = True

    def send(self, grp, cmd, payload=b"", show=True):
        seq = self.seq
        self.seq = (self.seq + 1) & 0xFF
        frame = build_frame(PHONE, RADIO, grp, cmd, seq, payload)
        if show:
            print(f">> [{time.strftime('%H:%M:%S')}] {grp:02x} {cmd:02x} seq={seq:02x} [{hexdump(payload)}]")
        self.s.sendall(frame)
        return seq

    def request(self, grp, cmd, payload=b"", wait=1.0, show=True):
        """Send and wait for the radio's ACK (then keep reading for `wait` s)."""
        seq = self.send(grp, cmd, payload, show)
        end = time.time() + 2.0
        while self.alive and seq not in self.acked and time.time() < end:
            self.pump(0.1)
        if seq not in self.acked:
            print(f"   (no ACK for seq={seq:02x})")
        self.pump(wait)
        return seq in self.acked

    def pump(self, seconds):
        end = time.time() + seconds
        while self.alive and time.time() < end:
            self.s.settimeout(max(0.05, min(0.3, end - time.time())))
            try:
                data = self.s.recv(4096)
            except socket.timeout:
                continue
            except OSError as e:
                print(f"<< link dropped by receiver ({e.strerror or e})")
                self.alive = False
                return
            if not data:
                print("<< link closed by receiver")
                self.alive = False
                return
            self.buf += data
            self._frames()

    def _frames(self):
        while True:
            start = self.buf.find(0x7E)
            if start < 0:
                self.buf.clear()
                return
            end = self.buf.find(0x7C, start + 1)
            if end < 0:
                del self.buf[:start]
                return
            raw = bytes(self.buf[start + 1:end])
            del self.buf[:end + 1]
            body, i = bytearray(), 0
            while i < len(raw):
                if raw[i] == 0x7D and i + 1 < len(raw):
                    body.append(raw[i + 1] ^ 0x20)
                    i += 2
                else:
                    body.append(raw[i])
                    i += 1
            if len(body) < 13:
                print(f"<< short frame: {hexdump(body)}")
                continue
            self._handle(Frame(bytes(body)))

    def _handle(self, f):
        if f.ack:
            self.acked.add(f.seq)
            return
        # ACK it, keeping the radio's src/dst order, like the app does
        self.s.sendall(build_frame(f.src, f.dst, f.grp, f.cmd, f.seq, b"\x00", ack=True))
        if (f.grp, f.cmd) == (0x3B, 0x02):
            print(f"<< [{time.strftime('%H:%M:%S')}] hello from {UNITS.get(f.src, f.src)}, answering")
            self.send(0x5B, 0x02, bytes([0, 0, 1, 1]), show=False)
            return
        if f.grp in self.quiet:
            return
        d = describe(f)
        print(f"<< [{time.strftime('%H:%M:%S')}] {f}" + (f"   => {d}" if d else ""))


def app_handshake(link, set_clock=False):
    """The queries JVC Remote sends after the hello (PROTOCOL.md → Connect handshake).

    Like the app, it sets the radio's clock (3b 35 / 3b 37) from local time, so the board's
    TIMEZONE must be right (install.sh sets it)."""
    steps = [(0x3B, 0x01, b""), (0x3B, 0x34, b""), (0x3B, 0x36, b"")]
    if set_clock:
        t = time.localtime()
        dow = (t.tm_wday + 1) % 7  # Python Mon=0 → radio Sun=0 … Wed=3
        steps += [(0x3B, 0x35, bytes([dow, t.tm_hour, t.tm_min, t.tm_sec])),
                  (0x3B, 0x37, bytes([t.tm_year // 100, t.tm_year % 100, t.tm_mon, t.tm_mday]))]
    steps += [(0x3B, 0x12, b""), (0x3B, 0x30, b"")]
    for grp, cmd, pl in steps:
        link.request(grp, cmd, pl, wait=0.3)


def cmd_talk(a):
    s = connect(a.mac, a.channel)
    print(f"Connected to {a.mac} ch {a.channel}")
    quiet = {0x5C} if a.no_rds else set()
    link = Link(s, quiet_grp=quiet)
    # the radio says hello first; wait for it
    end = time.time() + 5
    while link.alive and link.seq == 0 and time.time() < end:
        link.pump(0.2)
    if link.seq == 0:
        print("No hello from the radio within 5 s; carrying on anyway")
    if a.handshake and link.alive:
        print("-- handshake")
        app_handshake(link, a.set_clock)
    try:
        for step in a.do or []:
            if not link.alive:
                break
            if step.startswith("sleep"):
                link.pump(float(step.split()[1]))
                continue
            b = bytes.fromhex(step)
            print("--")
            link.request(b[0], b[1], b[2:], wait=a.wait)
        if a.listen and link.alive:
            print(f"-- listening {a.listen:g} s")
            link.pump(a.listen)
    except KeyboardInterrupt:
        pass
    s.close()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mac", default=conf_mac(), help="receiver Bluetooth MAC")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    l = sub.add_parser("listen")
    l.add_argument("--channel", type=int, default=conf_channel(), help="default: JVC_CHANNEL from config")
    sd = sub.add_parser("send")
    sd.add_argument("--channel", type=int, default=conf_channel(), help="default: JVC_CHANNEL from config")
    sd.add_argument("--send", action="append", required=True, help="hex bytes, e.g. 'aa 55 01'")
    sd.add_argument("--wait", type=float, default=1.5, help="seconds to read after each send")
    t = sub.add_parser("talk", help="speak the protocol: hello, ACKs, handshake, then --do steps")
    t.add_argument("--channel", type=int, default=conf_channel(), help="default: JVC_CHANNEL from config")
    t.add_argument("--do", action="append", help="'grp cmd [payload]' hex (e.g. '11 05 08' = Vol+), or 'sleep N'")
    t.add_argument("--wait", type=float, default=1.5, help="seconds to read after each step")
    t.add_argument("--listen", type=float, default=3.0, help="seconds to keep reading at the end")
    t.add_argument("--no-handshake", dest="handshake", action="store_false", help="skip the app's startup queries")
    t.add_argument("--no-rds", action="store_true", help="hide RDS text frames")
    t.add_argument("--no-set-clock", dest="set_clock", action="store_false",
                   help="don't set the radio's clock/date from this board's local time (TIMEZONE)")
    a = p.parse_args()
    if not a.mac:
        sys.exit("No MAC: pass --mac or set JVC_MAC in " + CONF)
    if a.cmd in ("listen", "send", "talk") and not a.channel:
        sys.exit("No channel: pass --channel or set JVC_CHANNEL in " + CONF)
    {"scan": cmd_scan, "listen": cmd_listen, "send": cmd_send, "talk": cmd_talk}[a.cmd](a)


if __name__ == "__main__":
    main()

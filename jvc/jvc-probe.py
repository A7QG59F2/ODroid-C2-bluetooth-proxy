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

The MAC defaults to JVC_MAC from /etc/odroid-ha/odroid-ha.conf.
"""
import argparse
import re
import socket
import sys
import time

CONF = "/etc/odroid-ha/odroid-ha.conf"


def conf_mac():
    try:
        with open(CONF) as f:
            for line in f:
                m = re.match(r'\s*JVC_MAC="?([0-9A-Fa-f:]{17})"?', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


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


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mac", default=conf_mac(), help="receiver Bluetooth MAC")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    l = sub.add_parser("listen")
    l.add_argument("--channel", type=int, required=True)
    sd = sub.add_parser("send")
    sd.add_argument("--channel", type=int, required=True)
    sd.add_argument("--send", action="append", required=True, help="hex bytes, e.g. 'aa 55 01'")
    sd.add_argument("--wait", type=float, default=1.5, help="seconds to read after each send")
    a = p.parse_args()
    if not a.mac:
        sys.exit("No MAC: pass --mac or set JVC_MAC in " + CONF)
    {"scan": cmd_scan, "listen": cmd_listen, "send": cmd_send}[a.cmd](a)


if __name__ == "__main__":
    main()

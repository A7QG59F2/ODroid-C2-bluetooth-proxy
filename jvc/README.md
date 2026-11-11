# JVC KD-SX38MBT over Bluetooth Classic (SPP)

The JVC Remote app talks to the receiver over **Bluetooth Classic SPP** (a serial link over RFCOMM).
That is **not** BLE, so the Bluetooth proxy can't carry it. The Odroid has to connect to the
receiver itself, using the same UB500 dongle.

The command bytes aren't published anywhere. The plan:

1. **Capture** what JVC Remote sends, using the Android Bluetooth HCI snoop log.
2. **Replay** those bytes from the Odroid with `jvc-probe.py`.
3. **Build the bridge** (`jvc2mqtt`), which turns the receiver into Home Assistant entities over MQTT.

## Status (2026-11-11): protocol decoded

**The full protocol is in [`PROTOCOL.md`](PROTOCOL.md):** frame format, CRC-16/ARC checksum,
connect handshake, key codes, source IDs, notifications (volume, frequency, RDS, track info)
and the settings get/set commands.

- Pairing works with `bluetoothctl` as below. After pairing, the Odroid shows up in the radio's **ANDROID LIST**.
- `scan` found open RFCOMM channels **7, 9 and 16**. **Channel 16 is the JVC Remote link.**
  Channels 7 and 9 are most likely hands-free (HFP) and another profile. Not needed.
- The frame the radio repeats every ~2 s after connecting (`… 3b 02 …`) is its **hello**. It stops
  once it is ACKed and answered with `5b 02 [00 00 01 01]`; unanswered, the radio drops the link
  after ~20 s. See PROTOCOL.md → Connect handshake.

## 1. Pair the Odroid with the receiver

Turn the **phone's Bluetooth off** first, because the receiver only accepts one remote at a time.

```bash
sudo bluetoothctl
  power on
  agent on
  default-agent
  scan on            # wait for KD-SX38MBT  88:E0:34:B7:98:6C
  scan off
  pair 88:E0:34:B7:98:6C
  trust 88:E0:34:B7:98:6C
  quit
```

On the receiver: **[REMOTE APP] → [SELECT] → [ANDROID] → [ANDROID LIST]** and pick the Odroid (`odroid-c2-btproxy` / its hostname).

## 2. Find the SPP channel

```bash
sudo /opt/odroid-ha/jvc/jvc-probe.py scan
```

## 3. Watch what the receiver says

```bash
sudo /opt/odroid-ha/jvc/jvc-probe.py listen --channel <N>
```

Change source or volume on the receiver itself. If status packets show up, the link works.

## 4. Capture the app's commands (phone + PC)

JVC Remote logs every frame it sends and receives to logcat, so no HCI snoop log or Wireshark
is needed. On the PC, with the phone on USB debugging (on Samsung, **Auto Blocker must be off**
or adb is blocked):

```powershell
adb logcat -c; adb logcat -v time > jvc-logcat.txt
```

Press buttons in JVC Remote **one at a time**, noting the order, then stop with Ctrl+C and decode:

```powershell
python jvc\decode-logcat.py jvc-logcat.txt              # frames + touch events
python jvc\decode-logcat.py jvc-logcat.txt --after 00:20:00 --all
```

The log contains whatever the phone is playing (track names etc.), so don't commit it.

Fallback if a future app version stops logging: **Developer options → Enable Bluetooth HCI snoop
log**, Bluetooth off/on, capture, then `adb bugreport` and open `btsnoop_hci.log` in Wireshark
(`btrfcomm || btspp`).

## 5. Replay a command

```bash
sudo /opt/odroid-ha/jvc/jvc-probe.py send --channel 16 --send "<handshake hex>" --send "<vol up hex>"
```

Raw replay only works for frames whose sequence number and checksum still fit; every frame needs
a fresh seq and CRC (see PROTOCOL.md), and the radio's `3b 02` hello must be answered first.
`jvc-probe.py` doesn't build frames yet.

## 6. Bridge (to do)

`jvc2mqtt` will:

- keep the RFCOMM link open, answer the hello, ACK every frame, reconnect when the link drops
- map MQTT topics to commands (keys, source select, EQ/loudness/bass settings)
- publish status from the radio's notifications (volume, source, frequency, RDS, track info, EQ)
- use MQTT Discovery so HA creates the entities on its own

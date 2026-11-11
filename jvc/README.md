# JVC KD-SX38MBT over Bluetooth Classic (SPP)

The JVC Remote app talks to the receiver over **Bluetooth Classic SPP** (a serial link over RFCOMM).
That is **not** BLE, so the Bluetooth proxy can't carry it. The Odroid has to connect to the
receiver itself, using the same UB500 dongle.

The command bytes aren't published anywhere. The plan:

1. **Capture** what JVC Remote sends, using the Android Bluetooth HCI snoop log.
2. **Replay** those bytes from the Odroid with `jvc-probe.py`.
3. **Build the bridge** (`jvc2mqtt`), which turns the receiver into Home Assistant entities over MQTT.

## Findings so far (2026-11-10)

- Pairing works with `bluetoothctl` as below. After pairing, the Odroid shows up in the radio's **ANDROID LIST**.
- `scan` found open RFCOMM channels **7, 9 and 16**. **Channel 16 is the JVC Remote link.**
- Once connected on ch 16, the radio sends this frame every **~2 s**:
  ```
  7e 0b 01 50 a4 3b 02 00 00 01 00 00 88 59 7c
  ```
  - starts `0x7E` and ends `0x7C`
  - byte 2 (`0x0B` = 11) matches the 11 bytes `01 … 88` that follow it
  - the byte before `0x7C` (`0x59`) is probably a checksum; it isn't a plain sum, XOR or CRC-16 of the obvious ranges
- If nothing answers, the radio **drops the link after ~20 s** (`Connection reset by peer`). That looks like a heartbeat/poll that the app has to reply to. The phone capture will show the reply, and the bridge must send it on the same schedule.
- Channels 7 and 9 are most likely hands-free (HFP) and another profile. Not needed.

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

On the PC with adb:

```powershell
adb shell settings put global bluetooth_btsnoop_default_mode full
adb shell svc bluetooth disable; Start-Sleep 3; adb shell svc bluetooth enable
```

Or use **Developer options → Enable Bluetooth HCI snoop log**. Then connect JVC Remote and press each
button **slowly, one at a time**, writing down the order. Afterwards:

```powershell
adb bugreport C:\jvc\bug.zip
```

Open `btsnoop_hci.log` from the zip in **Wireshark**, filter `btrfcomm || btspp`, and note the bytes
sent for each button.

## 5. Replay a command

```bash
sudo /opt/odroid-ha/jvc/jvc-probe.py send --channel <N> --send "<handshake hex>" --send "<vol up hex>"
```

If the receiver ignores a lone command, replay the first few packets the app sent right after it connected
(the handshake), then the command.

## 6. Bridge (to do)

Once the commands are known, `jvc2mqtt` will:

- keep the RFCOMM link open
- map MQTT topics to commands
- publish status
- use MQTT Discovery so HA creates the entities on its own

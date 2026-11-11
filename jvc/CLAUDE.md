# JVC work: next steps

The protocol is decoded (2026-11-11): see `PROTOCOL.md`. It came from JVC Remote's own logcat
output (`OpenLinkService_BT`), decoded with `decode-logcat.py`; no HCI snoop/Wireshark needed.
Adam's phone is a Samsung SM-S938U1; adb needs **Auto Blocker off**. With adb you can screenshot
the phone (`adb shell screencap`) and tap the app (`adb shell input tap/swipe`), but ask first and
put back any radio setting you change.

1. **Frame builder + first live test from the Odroid.** Teach `jvc-probe.py` to build frames
   (seq, CRC-16/ARC, 7d-escaping), answer the `3b 02` hello, ACK every frame, then send Vol+/Vol−.
   While connected, settle the open points in PROTOCOL.md:
   - subwoofer level scale (`3d 43` / `3d 44`)
   - other `3d 14` parameters for the second color zone / night colors
   - key codes `09`+ (power?), Up/Down on BT audio, play/pause on BT
2. **`jvc2mqtt` bridge.** A Python systemd service on the Odroid that holds the RFCOMM link
   (reconnecting: the link drops on its own now and then), maps MQTT topics to commands and
   publishes the notifications, with MQTT Discovery. It shares the UB500 with bt-proxy through
   BlueZ. Add a second BT dongle only if Classic + BLE scanning on one adapter proves flaky.

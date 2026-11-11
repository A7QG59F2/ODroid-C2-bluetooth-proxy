# CLAUDE.md

Context for Claude Code working in this repo. Read this first; the README has the user-facing details.

## What this project is

One **DietPi** install on an **Odroid C2** that is, at the same time:

1. a **Home Assistant Bluetooth proxy**: `denvera/bt-proxy` runs natively (uv venv in `/opt/bt-proxy`) as `bt-proxy.service`, ESPHome Native API on port 6053, plaintext only (no Noise encryption)
2. a **dashboard kiosk** on a MAGEX 10.1" HDMI touch screen: tty1 autologin as user `kiosk` → `startx` → `kiosk/kiosk-session.sh` → Chromium `--kiosk`, with the **Onboard** on-screen keyboard
3. groundwork for controlling a **JVC KD-SX38MBT** car receiver over Bluetooth Classic SPP (`jvc/`)

The owner is Adam (GitHub `A7QG59F2`). He runs things from a **Windows PC**, so PowerShell for anything on the PC side.

## Hardware (all fixed, don't make the script generic)

| Part | IDs / driver | Notes |
|---|---|---|
| Odroid C2 | Amlogic S905 (`meson-gxbb`), 2 GB, Mali-450 (lima, GLES 2.0 only) | Weak GPU; Chromium mostly software-renders. 4× USB 2.0. |
| TP-Link UB500 | `2357:0604`, RTL8761BU, btusb/btrtl, `firmware-realtek` | Always `hci0` (C2 has no onboard BT) |
| TP-Link TL-WN821N, **RT5572 version** | `148f:5572`, `rt2800usb`, `firmware-mediatek` (`rt2870.bin`; not in misc-nonfree on trixie) | Dual-band; must use **5 GHz** to avoid fighting BT. Power-save disabled by udev rule. |
| MAGEX 10.1" touch monitor + case | HDMI + USB HID touch (`0416:c168` Winbond MTouch) | Native **1920×1200** (confirmed, 220×132 mm), auto-detected |
| JVC KD-SX38MBT | BT MAC `88:E0:34:B7:98:6C` | Phone app "JVC Remote" uses SPP; protocol undocumented |

## Repo layout

- `install.sh`: the whole installer, idempotent, run as root. `--check` prints a health report. `--configure` asks which parts the board has (bt-proxy, Wi-Fi + SSID/password, kiosk + URL/keyboard, JVC) and writes the answers into the config; a first install from a terminal asks automatically, and a run without a terminal (DietPi first boot) never asks. It installs itself as `/usr/local/sbin/odroid-ha-install` (which re-clones the latest repo and re-applies, passing flags through) and adds `odroid-ha-check`.
- `config/odroid-ha.conf.example`: all settings. The live copy is `/etc/odroid-ha/odroid-ha.conf` (or `/boot/odroid-ha.conf` is picked up on first install).
- `kiosk/kiosk-session.sh`: the X session. It re-execs itself under `dbus-run-session`, sets up xrandr and the touch matrix, starts the AT-SPI bus and Onboard, waits for HA, then runs Chromium in a restart loop.
- `dietpi/`: `dietpi.txt.settings` and `Automation_Custom_Script.sh` for hands-off first boot.
- `jvc/jvc-probe.py`: RFCOMM `scan` / `listen` / `send`. `jvc/README.md` covers the capture and replay workflow.

## Key decisions (don't undo without asking)

- **DietPi, not Armbian.** DietPi-Autostart must stay on **0 (Console)**. `install.sh` owns tty1 via `getty@tty1.service.d/zz-odroid-ha-kiosk.conf`.
- **Our own kiosk, not DietPi's Chromium autostart (index 11)**, so flags, the keyboard and the restart loop stay under our control.
- **bt-proxy native via uv, not Docker**, to save RAM on a 2 GB board.
- **On-screen keyboard = Onboard via AT-SPI.** Auto-show needs all of these together:
  - a session D-Bus
  - `at-spi-bus-launcher`
  - `libatk-adaptor`, `GTK_MODULES=gail:atk-bridge`, `gir1.2-atspi-2.0`
  - Chromium `--force-renderer-accessibility`
  - `toolkit-accessibility=true`

  Onboard settings are **system dconf defaults** in `/etc/dconf/db/odroidha.d/00-onboard` (profile `/etc/dconf/profile/user`), with `force-to-top` (no WM) and `touch-input='none'`. Chrome-extension keyboards were rejected: HA inputs live in shadow DOM, and the old MV2 extensions are dead. Adam's earlier DietPi kiosk attempt failed on exactly this keyboard, so treat it as important.
- No window manager. Chromium runs fullscreen under bare Xorg (`xserver-xorg-legacy`, `Xwrapper.config` `allowed_users=console`).
- **Several boards, optional parts.** Adam is flashing multiple C2s; some lack the UB500, the RT5572 or the JVC. Each part has an `ENABLE_*` switch (`ENABLE_BT_PROXY`, `ENABLE_WIFI`, `ENABLE_KIOSK`, `ENABLE_JVC_TOOLS`) chosen by the user through `--configure`, never by auto-detection. Switching a part off must undo what it set up, and `--check` only reports enabled parts. Proxy names default to `odroid-c2-<last 4 hex of eth0 MAC>` so boards don't collide in HA. The Wi-Fi password is only read from the terminal and stored as the derived 64-hex key; never write plaintext anywhere.

## Status (as of 2026-11-11)

- **First install done on the real hardware** (DietPi on Debian 13 trixie, kernel 6.18 meson64, HA at 192.168.1.3:8123). Verified:
  - Firmware packages install fine from DietPi's apt sources (non-free-firmware is enabled). They replace DietPi's `armbian-firmware` (conflict); that's expected.
  - `uv sync` uses the system Python 3.13; bt-proxy builds and runs.
  - UB500 loads `rtl8761bu_fw.bin`; RT5572 shows as "RT chipset 5592" in dmesg (normal for rt2800usb) and is dual-band.
  - Xorg needs `/etc/X11/xorg.conf.d/10-odroid-ha-meson.conf` (kmsdev = meson-drm by-path, `AutoAddGPU` off). Without it, the two DRM devices (meson-drm card0, lima card1) make X die with "Cannot run in framebuffer mode".
  - With no WM, Chromium needs an explicit `--window-size` or it only fills half the screen.
  - Chromium's GPU process fails on lima (it wants GLES 3) and falls back to software by itself; `--disable-gpu` hasn't been needed.
  - HA login page renders; Onboard auto-show docks it at the bottom. The floating button is off (now the repo default too).
- **First board's network:** on Wi-Fi at **192.168.1.127** (SSID ABoy, 5 GHz only via `freq_list`, country US); it was .144 on Ethernet. install.sh manages it: `wpa_supplicant.conf` (derived PSK only) and `/etc/network/interfaces.d/wlan0.conf` (`metric 100`, so Ethernet wins while plugged in). `eth0` stays DietPi's `allow-hotplug` fallback, and `ignore_routes_with_linkdown=1` keeps a pulled cable from stranding the default route. This board keeps `ENABLE_JVC_TOOLS="1"` and `BT_PROXY_NAME="odroid-c2-btproxy"` in its live config.
- `iw reg set` drops the Wi-Fi link, so install.sh only sets the country when it differs and then waits for the link before network steps.
- DietPi's SSH is Dropbear without SFTP: `scp` fails, so copy files with `ssh host 'cat > file' < file`. DietPi also masks `systemd-logind` (Xorg logs an error about it, harmless).
- Still to check: the touch matrix after rotation, which Onboard `OSK_TOUCH_INPUT` mode suits the MAGEX panel, and the final `HA_URL` dashboard path (still the placeholder `/lovelace/0`).

## Next work

1. **First-install debugging.** SSH to the Odroid (`root@<odroid-ip>`), run `install.sh` and `odroid-ha-check`, fix what breaks, and commit fixes back here.
2. **Home Assistant side.**
   - ESPHome integration → host `<odroid-ip>`, port 6053
   - HA user `kiosk` + `trusted_networks` for the Odroid's IP (see README)
   - HACS kiosk-mode
3. **JVC capture.** Adam's phone is a Samsung SM-S938U1 with JVC Remote. On the PC:
   - turn on the HCI snoop log (`adb shell settings put global bluetooth_btsnoop_default_mode full` + Bluetooth off/on)
   - watch `adb logcat` while Adam presses buttons one at a time, noting the order
   - `adb bugreport` → `btsnoop_hci.log` → Wireshark `btrfcomm || btspp`
   - replay with `jvc-probe.py send`

   The phone also has APK Extractor if decompiling JVC Remote (jadx) is faster.
4. **`jvc2mqtt` bridge.** A Python systemd service on the Odroid that holds the RFCOMM link and maps MQTT topics to commands, with MQTT Discovery. It shares the UB500 with bt-proxy through BlueZ. Add a second BT dongle only if Classic + BLE scanning on one adapter proves flaky.

Planning notes also live in the claude.ai Project "ODroid C2 - home assistant".

## Conventions

- Shell scripts must pass `shellcheck -S warning` and `bash -n`. Keep `install.sh` idempotent and re-runnable.
- LF line endings (enforced by `.gitattributes`). Adam edits on Windows.
- New settings go in `config/odroid-ha.conf.example` **and** the README settings table, with safe defaults in the scripts (`${VAR:-default}`). install.sh appends any example key missing from a board's live config (with the example's value), so existing boards pick new settings up on the next `odroid-ha-install`. If a new setting is a per-board choice, also ask it in `configure()`.
- Don't add hardware auto-detection or other boards. This repo targets exactly the hardware above.

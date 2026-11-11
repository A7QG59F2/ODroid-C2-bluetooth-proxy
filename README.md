# Odroid C2 – Home Assistant Bluetooth Proxy + Dashboard Kiosk

One **DietPi** install on an Odroid C2 that does three jobs:

| Job | How |
|---|---|
| **Bluetooth proxy** for Home Assistant | [`denvera/bt-proxy`](https://github.com/denvera/bt-proxy) runs natively as a systemd service. HA sees it as an ESPHome Bluetooth proxy, with active connections supported. |
| **Wall/desk dashboard kiosk** | Auto-login on tty1 → X → Chromium in kiosk mode on the MAGEX 10.1" touch screen, with an **on-screen keyboard** that pops up on its own. Restarts itself if it crashes. |
| **JVC KD-SX38MBT groundwork** | `jvc-probe.py` pairs and talks to the receiver over Bluetooth Classic SPP, to replay the JVC Remote app's commands. See [`jvc/README.md`](jvc/README.md). |

## Hardware this targets

| Part | Notes |
|---|---|
| Odroid C2 (S905, 2 GB, Mali-450) | Weak GPU (GLES 2.0). Keep the kiosk dashboard light: tiles and buttons, no live camera streams. |
| **TP-Link UB500** (RTL8761BU, `2357:0604`) | Needs `firmware-realtek` (installed). It is `hci0`, since the C2 has no built-in BT. |
| **TP-Link TL-WN821N, RT5572 version** (`148f:5572`) | Dual-band. Driver `rt2800usb` + `firmware-mediatek` (`rt2870.bin`, installed). **Use 5 GHz**, because 2.4 GHz fights the Bluetooth dongle. |
| **MAGEX 10.1" touch monitor w/ case** | HDMI video, USB touch (driver-free). Power the screen from its own supply, not a C2 USB port. |

USB ports: touch, UB500 and Wi-Fi take 3 of the 4. Ethernet is still the most reliable option if you can run a cable.
Put the UB500 on a short USB extension, away from the Wi-Fi dongle.

## Install

### Option 1: Flash, boot, run one command (simplest)

1. Download the **DietPi Odroid C2** image from <https://dietpi.com/#download> and flash it with balenaEtcher (microSD or eMMC).
2. Boot with **Ethernet** plugged in and finish DietPi's first-run setup (SSH: `root` / `dietpi`).
   When asked about autostart, leave it on **Console**.
3. Run (over SSH use `ssh -t` so it can ask questions):
   ```bash
   apt-get update && apt-get install -y git
   git clone https://github.com/A7QG59F2/ODroid-C2-bluetooth-proxy /opt/odroid-ha/src
   cd /opt/odroid-ha/src && ./install.sh
   ```
4. The first run asks which parts this board has, then installs only those:
   ```
   Home Assistant Bluetooth proxy (TP-Link UB500)? [Y/n]
     Name in Home Assistant (lowercase, unique per board) [odroid-c2-07bc]
   Wi-Fi (TL-WN821N, RT5572)? [Y/n]
     Network name (SSID, empty = leave Wi-Fi unconfigured) []
     Wi-Fi password for MyNetwork:            (not echoed, never stored in plain text)
   Dashboard kiosk on the touch screen (MAGEX 10.1")? [Y/n]
     Dashboard URL [http://homeassistant.local:8123/lovelace/0]
   JVC KD-SX38MBT car receiver tools (needs the UB500)? [y/N]
   ```

### Several boards, and adding parts later

Every board gets its own proxy name by default (`odroid-c2-` plus the end of its Ethernet MAC), so
several C2s can sit in the same Home Assistant. To add or remove a part later, for example after
plugging in a UB500, run the questions again. Enter keeps each current answer:

```bash
ssh -t root@<odroid-ip> odroid-ha-install --configure
```

Switching a part off removes what it set up (the bt-proxy service, the kiosk autologin, the JVC
tool, our Wi-Fi config). `odroid-ha-check` only reports on the parts that are switched on.

**Moving to Wi-Fi:** answer the Wi-Fi questions while still on Ethernet. The installer brings
`wlan0` up next to Ethernet and prints its address; then unplug the cable. Ethernet stays
configured as a fallback: it's preferred while plugged in, and Wi-Fi takes over when it isn't.

### Option 2: Hands-off first boot

Before the first boot, edit `dietpi.txt` on the card using [`dietpi/dietpi.txt.settings`](dietpi/dietpi.txt.settings).
DietPi then sets itself up, and the last step runs [`dietpi/Automation_Custom_Script.sh`](dietpi/Automation_Custom_Script.sh), which clones this repo and runs `install.sh`.

- The URL form of `AUTO_SETUP_CUSTOM_SCRIPT_EXEC` only works while this repo is **public**. Otherwise copy the script to the boot partition as `Automation_Custom_Script.sh`.
- First boot has no terminal, so nothing is asked. To choose the parts, copy your edited [`config/odroid-ha.conf.example`](config/odroid-ha.conf.example) to the boot partition as **`odroid-ha.conf`**, or run `odroid-ha-install --configure` afterwards.
- For Wi-Fi on first boot, use DietPi's `dietpi-wifi.txt` and set `WIFI_SSID` in `odroid-ha.conf` to the same network. install.sh then converts DietPi's plain-text key to the derived WPA key and adds the 5 GHz and country settings. The plain-text copy in `dietpi-wifi.txt` on the boot partition is DietPi's; blank it once the board is online.
- If Windows can't see a boot partition on the flashed card, use Option 1.

## What `install.sh` does

Each step runs only for the parts that are switched on.

1. Installs the firmware (`firmware-realtek` for the UB500; `firmware-mediatek` + `firmware-misc-nonfree` for the RT5572), plus BlueZ, Xorg, Chromium and `xinput`.
2. Unblocks Bluetooth (removes DietPi's Bluetooth blacklist if set), sets BlueZ `AutoEnable=true` and powers on the UB500.
3. Wi-Fi: sets the country, turns off RT5572 power saving (udev rule) so the proxy doesn't drop off the network, and, if `WIFI_SSID` is set, joins it (5 GHz only by default) with Ethernet kept as a fallback.
4. Installs **bt-proxy** in `/opt/bt-proxy` using `uv`, then creates and starts **`bt-proxy.service`** (port **6053**, mDNS-advertised).
5. Creates user **`kiosk`** and sets up autologin on tty1 → `startx` → `/opt/odroid-ha/kiosk-session.sh`, which:
   - applies screen mode and rotation, and rotates touch to match
   - disables blanking (or sets a timeout)
   - hides the cursor
   - starts the on-screen keyboard (Onboard) with its accessibility bus
   - waits for HA, then runs Chromium `--kiosk` in a restart loop
6. Installs `/opt/odroid-ha/jvc/jvc-probe.py`.
7. Adds two commands: **`odroid-ha-check`** (health report) and **`odroid-ha-install`** (pull latest repo + re-apply; `--configure` to re-answer the questions).

It's safe to re-run as often as you like. Install log: `/var/log/odroid-ha-install.log`.

## Home Assistant side

**Bluetooth proxy:** Settings → Devices & Services. ESPHome should offer *Odroid C2 Bluetooth Proxy*.
If not: **Add Integration → ESPHome → host `<odroid-ip>`, port `6053`**. bt-proxy uses the plain (unencrypted) Native API, so leave the encryption key empty.

**Kiosk login without typing a password on the touch screen:**

1. In HA create a user, e.g. **kiosk**: non-admin, and "local access only" if you like.
2. Give the Odroid a fixed IP (DHCP reservation), then add to `configuration.yaml`:
   ```yaml
   homeassistant:
     auth_providers:
       - type: trusted_networks
         trusted_networks:
           - 192.168.1.50/32          # the Odroid
         trusted_users:
           192.168.1.50/32: <kiosk user id>   # Settings → People → Users → kiosk (ID in the URL/advanced view)
         allow_bypass_login: true
       - type: homeassistant
   ```
3. Restart HA.

**Clean screen:** install [kiosk-mode](https://github.com/NemesisRE/kiosk-mode) from HACS to hide the header and sidebar for the kiosk user.
Make a dashboard laid out for the panel (1920×1200 landscape).

## On-screen keyboard

Uses **Onboard**. Tap any text field in Home Assistant (search, login, a text helper, the Assist box) and the
keyboard slides up from the bottom. It hides again when the field loses focus. If auto-show ever misses a field,
`OSK_FLOATING_BUTTON="1"` adds a small floating button to open it by hand (off by default).

Auto-show in a bare X kiosk usually fails in silence. These are the pieces this setup puts in place for it to work:

| Piece | Why it's needed |
|---|---|
| A D-Bus **session bus** (`dbus-run-session` around the whole kiosk session) | Onboard and Chromium have to share it, or they can't talk |
| **AT-SPI** accessibility bus (`at-spi2-core`, `at-spi-bus-launcher`) | Carries "a text field got focus" from Chromium to Onboard |
| GTK/ATK bridge (`libatk-adaptor`, `GTK_MODULES=gail:atk-bridge`) + `gir1.2-atspi-2.0` | How Chromium reports focus, and how Onboard listens for it |
| Chromium `--force-renderer-accessibility` | Without it, Chromium never reports web-page text fields |
| `toolkit-accessibility=true` + all Onboard settings as **system dconf defaults** | No clicking through `onboard-settings` on the touch screen, and no "enable accessibility?" pop-up |
| Onboard `force-to-top` + docking | Keeps the keyboard above full-screen Chromium even with no window manager |

Settings live in `odroid-ha.conf`: `ONSCREEN_KEYBOARD`, `OSK_LAYOUT`, `OSK_THEME`, `OSK_EDGE`, `OSK_FLOATING_BUTTON` and
`OSK_TOUCH_INPUT`. Re-run `install.sh` after changing them, then reboot.

**If the keyboard misbehaves:**

- **Never pops up:** run `odroid-ha-check`. "keyboard" and "a11y bus" should both say running.
  Check `~kiosk/.onboard.log` for `AT-SPI` errors. Turn on `OSK_FLOATING_BUTTON` as a fallback.
- **Keys type twice, or not at all:** set `OSK_TOUCH_INPUT` to `single` or `multi` (default `none` treats touch as a mouse).
- **Covers the field you're typing in:** set `OSK_EDGE="top"`, or keep text inputs near the top of the dashboard.
- **Turn it off:** `ONSCREEN_KEYBOARD="0"`.

## Settings (`/etc/odroid-ha/odroid-ha.conf`)

| Key | Default | Meaning |
|---|---|---|
| `HA_URL` | `http://homeassistant.local:8123/lovelace/0` | Page the kiosk opens |
| `TIMEZONE` | empty (keep the system's) | Local time zone, e.g. `America/Indiana/Indianapolis`; asked by `--configure`. The JVC radio's clock is set from it |
| `ENABLE_BT_PROXY` / `ENABLE_WIFI` / `ENABLE_KIOSK` | `1` | Turn each part on or off |
| `ENABLE_JVC_TOOLS` | `0` | JVC probe tool (needs the UB500) |
| `BT_PROXY_NAME`, `BT_PROXY_FRIENDLY_NAME` | `odroid-c2-<mac4>` | Name in HA; must be unique per board |
| `BT_ADAPTER` / `BT_MAX_CONNECTIONS` | `hci0` / `3` | Which dongle; active-connection slots |
| `SCREEN_ROTATION` | `normal` | `normal`/`left`/`right`/`inverted` (touch follows) |
| `SCREEN_MODE` | auto | Force a mode, e.g. `1920x1200` (the panel's native mode) |
| `SCREEN_ALWAYS_ON` / `SCREEN_BLANK_SECONDS` | `1` / `600` | Blanking |
| `CHROMIUM_ZOOM` | `1.0` | e.g. `1.25` on a 1920×1200 panel |
| `CHROMIUM_EXTRA_FLAGS` | empty | Add `--disable-gpu` if the page is blank/white |
| `ONSCREEN_KEYBOARD` | `1` | Onboard keyboard with auto-show |
| `OSK_LAYOUT` / `OSK_THEME` / `OSK_EDGE` | `Compact` / `Droid` / `bottom` | Keyboard look and position |
| `OSK_FLOATING_BUTTON` / `OSK_TOUCH_INPUT` | `0` / `none` | Manual-open button; touch handling |
| `WIFI_SSID` | empty | Network to join (password via `--configure`, never stored in plain text) |
| `WIFI_COUNTRY` / `WIFI_5GHZ_ONLY` | `US` / `1` | Regulatory domain; stay off 2.4 GHz |
| `WIFI_DISABLE_POWERSAVE` | `1` | Keep RT5572 awake |
| `JVC_MAC` | empty | The radio's Bluetooth address (asked by `--configure`) |
| `JVC_CHANNEL` | `16` | RFCOMM channel of the JVC Remote (SPP) service |
| `ENABLE_RADIO_AUDIO` | `0` | Music Assistant player that plays through the radio (Squeezelite → BlueALSA → A2DP) |
| `RADIO_AUDIO_NAME` | `Car-Radio` | Player name in Music Assistant |
| `RADIO_AUDIO_SERVER` | empty (auto) | Music Assistant host, if auto-discovery fails |
| `RADIO_RECONNECT_SECONDS` | `15` | Retry interval while the radio is off |
| `RADIO_HA_ENTITY` | empty (`media_player.<name>`) | HA media_player whose state and track the radio shows, and that its buttons control. Needs the HA token `--configure` asks for (kept in `/etc/odroid-ha/ha-token`) |
| `HA_API_URL` | empty (from `HA_URL`) | Home Assistant base URL for the API, e.g. `http://192.168.1.3:8123` |

## Troubleshooting

```bash
odroid-ha-check                          # hardware, BT, Wi-Fi, services, temps
journalctl -u bt-proxy -f                # proxy log
cat /home/kiosk/.kiosk-x.log             # X / Chromium log
dmesg | grep -iE 'rtl|bluetooth|rt2800'  # driver + firmware messages
```

- **`Bluetooth adapter powered off`**: run `rfkill unblock bluetooth && systemctl restart bt-proxy`.
- **Kiosk shows a login prompt instead of Chromium**: DietPi-Autostart must be **0: Console** (`dietpi-autostart`). Re-run `install.sh`.
- **Blank/white Chromium window**: set `CHROMIUM_EXTRA_FLAGS="--disable-gpu"` and re-run.
- **Touch is offset after rotating**: re-run after changing `SCREEN_ROTATION`, or reboot.
- **Dashboard is sluggish**: simplify it. The Mali-450 can't accelerate modern Chromium well.
- **Leave the kiosk to get a shell on the screen**: Ctrl+Alt+F2 switches to another console.

## JVC KD-SX38MBT

Bluetooth Classic (SPP) control isn't something the BLE proxy can carry. Pairing, the channel scan, the capture
workflow and replay are in [`jvc/README.md`](jvc/README.md). The MQTT bridge is the next milestone, once the command
bytes are captured.

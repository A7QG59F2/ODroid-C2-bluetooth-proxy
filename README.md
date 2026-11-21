# Odroid C2 – Home Assistant kiosk, car radio and Bluetooth proxy

One **DietPi** install on an Odroid C2 that does these jobs (each one optional), plus the Bluetooth groundwork for the car radio:

| Job | How |
|---|---|
| **Bluetooth proxy** for Home Assistant | [`denvera/bt-proxy`](https://github.com/denvera/bt-proxy) runs natively as a systemd service. HA sees it as an ESPHome Bluetooth proxy, with active connections supported. |
| **Wall/desk dashboard kiosk** | Auto-login on tty1 → X → Chromium in kiosk mode on the MAGEX 10.1" touch screen, with an **on-screen keyboard** that pops up on its own. Restarts itself if it crashes. |
| **Bluetooth dongle** for other software | Firmware + BlueZ for the UB500. The JVC car radio integration runs on it from its own repo, [**jvc2mqtt**](https://github.com/A7QG59F2/jvc2mqtt). |
| **Winamp remote** | Winamp 2 ([Webamp](https://github.com/captbaritone/webamp)) on the touch screen, driving a Music Assistant player: skins, equalizer, playlist, visualizer. See [Winamp remote](#winamp-remote). |

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
   git clone https://github.com/A7QG59F2/ODroid-C2 /opt/odroid-ha/src
   cd /opt/odroid-ha/src && ./install.sh
   ```
4. The first run asks which parts this board has, then installs only those:
   ```
   Bluetooth dongle (TP-Link UB500)? [Y/n]
     Home Assistant Bluetooth proxy on it? [Y/n]
     Name in Home Assistant (lowercase, unique per board) [odroid-c2-07bc]
   Wi-Fi (TL-WN821N, RT5572)? [Y/n]
     Network name (SSID, empty = leave Wi-Fi unconfigured) []
     Wi-Fi password for MyNetwork:            (not echoed, never stored in plain text)
   Dashboard kiosk on the touch screen (MAGEX 10.1")? [Y/n]
     Dashboard URL [http://homeassistant.local:8123/lovelace/0]
   ```

### Several boards, and adding parts later

Every board gets its own proxy name by default (`odroid-c2-` plus the end of its Ethernet MAC), so
several C2s can sit in the same Home Assistant. To add or remove a part later, for example after
plugging in a UB500, run the questions again. Enter keeps each current answer:

```bash
ssh -t root@<odroid-ip> odroid-ha-install --configure
```

Switching a part off removes what it set up (the bt-proxy service, the kiosk autologin, our Wi-Fi
config). `odroid-ha-check` only reports on the parts that are switched on.

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
6. Winamp remote: `/opt/odroid-ha/winamp`, Webamp itself (downloaded once, checked by hash), **`odroid-ha-winamp.service`** on `localhost:8099`, and a Squeezelite drop-in that adds `-v` for the visualizer.
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

## Winamp remote

Winamp 2 on the touch screen, but it plays nothing itself. Every control acts on one Music Assistant
player (by default `Car-Radio`, jvc2mqtt's radio player), and Music Assistant's state is drawn back into the
Winamp windows, so the radio's buttons, Home Assistant and the MA app all stay in step with it.

| Winamp | Music Assistant |
|---|---|
| Play / pause / stop / previous / next, seek bar | The player's queue (next and previous follow MA's own shuffle order) |
| Playlist window | The queue. Made for touch: drag to scroll, tap to select, double-tap to play, hold for a track's menu (play, add to playlist, move to top, remove), drag the **≡** handle to move a track, **+** adds it to an MA playlist (an existing one or a new one) |
| Shuffle / repeat | The queue's shuffle and repeat (the button is repeat all; *Settings* also has repeat one) |
| Volume | The player's volume |
| Balance (the fader) | A balance filter in the player's DSP settings |
| MONO / STEREO (tap them) | Mono on or off: a stereo width 0 filter in the player's DSP settings |
| Equalizer (10 bands + preamp, on/off; presets in *Settings*) | A 10-band parametric EQ in the player's DSP settings (Settings → Players → the player → DSP), ±12 dB, at Winamp's frequencies. It shows up there and is kept when you change other DSP filters |
| Eject, *Load list*, the Library button | A picker for MA playlists, albums and radio stations: tap to play, *+ Queue* to add |
| *Add URL* / *Save list* | Adds a stream URL to the queue / saves the queue as an MA playlist |
| Visualizer (spectrum and oscilloscope) | The real audio, read from Squeezelite (`-v`, added by a drop-in). Only when the player is this board's Squeezelite (jvc2mqtt's radio player) |
| The Visualizer button | The same audio full screen as **Milkdrop** (butterchurn, 100 presets), or as bars or an oscilloscope in the skin's colors. Tap for the controls: previous/next preset, style, close |
| The Settings button (and Winamp's own menu buttons) | A full-screen page, made for touch, with what Winamp keeps in its small menus. Sections: Playback (transport, skip, repeat one, shuffle, time display), Playlist (select all/none/invert, remove or keep the selection, add the selection to a playlist, save/clear the queue, stream URL), Sound & EQ (volume, balance, mono, EQ on/off and presets), Skin & look, Visualizer (Milkdrop options and preset list). Winamp's O, I, V, EQ *Presets* and playlist ADD/REM/SEL/MISC/LIST buttons open the matching section; long-presses open nothing |
| *Settings* → Skin | Every `.wsz` in `/etc/odroid-ha/winamp-skins` (the choice is remembered) |

Balance, mono and the EQ are kept together with any other DSP filters you set up for the player in MA.

**Milkdrop on the C2** runs on the CPU: the Mali-450 has no WebGL 2, so Chromium renders it with SwiftShader
(the kiosk adds `--enable-unsafe-swiftshader` while the Winamp remote is on). Expect about 5–10 frames a second,
drawn small and scaled up. A preset that runs slower than the *Skip presets under* setting is skipped from then on;
*Retry skipped* in Settings brings them back. The bars and oscilloscope styles run smoothly.

**Set it up:**

1. In Music Assistant's web UI, create a long-lived token for your user.
2. Run `ssh -t root@<odroid-ip> odroid-ha-install --configure` and answer yes to the Winamp remote. It asks for the
   player and the token (kept in `/etc/odroid-ha/ma-token`, root only, handed to the service as a systemd credential).
3. Put a button on the kiosk's dashboard that opens `http://localhost:8099/`, e.g.:
   ```yaml
   type: button
   name: Winamp
   icon: mdi:music-box
   tap_action:
     action: url
     url_path: http://localhost:8099/
   ```
   On the kiosk this opens Winamp full screen. Its **Dashboard** button goes back. (`localhost` is the board
   itself, so the button only works on the kiosk. A Webpage card showing the same URL also works.)

**Skins:** copy `.wsz` files to `/etc/odroid-ha/winamp-skins/`, or list download URLs in `WINAMP_SKIN_URLS`
(the [Winamp Skin Museum](https://skins.webamp.org/) has thousands). `WINAMP_SKIN` picks the starting skin.

**If something's off:** `journalctl -u odroid-ha-winamp -f` shows the Music Assistant connection and the player
it follows. The status line at the bottom left of the page shows the same errors. If the visualizer runs ahead of
or behind the music, change `WINAMP_VIS_DELAY_MS`.

**Stuck on a page with no way back** (e.g. an error page): `ssh root@<odroid-ip> pkill -x chromium`. The kiosk restarts
Chromium on the dashboard within a few seconds.

## Settings (`/etc/odroid-ha/odroid-ha.conf`)

| Key | Default | Meaning |
|---|---|---|
| `HA_URL` | `http://homeassistant.local:8123/lovelace/0` | Page the kiosk opens |
| `TIMEZONE` | empty (keep the system's) | Local time zone, e.g. `America/Indiana/Indianapolis`; asked by `--configure`. The kiosk's clock and (with jvc2mqtt) the JVC radio's clock follow it |
| `ENABLE_BLUETOOTH` | `1` | UB500 firmware + BlueZ, powered on at boot |
| `ENABLE_BT_PROXY` / `ENABLE_WIFI` / `ENABLE_KIOSK` | `1` | Turn each part on or off (the proxy needs `ENABLE_BLUETOOTH`) |
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
| `ENABLE_WINAMP` | `0` | [Winamp remote](#winamp-remote) for a Music Assistant player. Needs the MA token `--configure` asks for (kept in `/etc/odroid-ha/ma-token`) |
| `WINAMP_PLAYER` | empty (`Car-Radio`) | Music Assistant player it controls (name or id) |
| `MA_URL` | empty (HA's host, port 8095) | Music Assistant address, e.g. `http://192.168.1.3:8095` |
| `WINAMP_LISTEN` / `WINAMP_PORT` | `127.0.0.1` / `8099` | Where the page is served. `0.0.0.0` lets other devices use it too |
| `WINAMP_SCALE` | `auto` | Size of the Winamp windows; `auto` fills the screen, or a factor like `3` |
| `WINAMP_SKIN` / `WINAMP_SKIN_URLS` | empty | Starting skin (file name without `.wsz`); skin URLs to download |
| `WINAMP_VIS_DELAY_MS` | `300` | Delay the visualizer to match the Bluetooth latency |

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

## JVC KD-SX38MBT car radio

Moved to its own repo, [**jvc2mqtt**](https://github.com/A7QG59F2/jvc2mqtt): the decoded JVC Remote protocol,
`jvc-probe`, Music Assistant through the radio, and the MQTT bridge. It runs on this board's UB500: keep
`ENABLE_BLUETOOTH="1"` and `ENABLE_BT_PROXY="0"`, since the proxy's BLE scanning stops the dongle from
connecting to the radio.

A board that had `ENABLE_JVC_TOOLS` or `ENABLE_RADIO_AUDIO` on here keeps running those parts until
jvc2mqtt's installer takes them over (it moves the settings and the HA token across):

```bash
git clone https://github.com/A7QG59F2/jvc2mqtt /opt/jvc2mqtt/src && /opt/jvc2mqtt/src/install.sh
```

#!/bin/bash
# =============================================================================
#  Odroid C2  →  Home Assistant Bluetooth proxy  +  dashboard kiosk
#               (or a Winamp-style Music Assistant player on the touch screen)
#  Target: DietPi (Debian) on Odroid C2
#          TP-Link UB500 (RTL8761BU)  ·  TL-WN821N (RT5572)  ·  MAGEX 10.1" touch
#
#  Usage (as root, from a clone of this repo):
#      sudo ./install.sh              # install / update everything
#      sudo ./install.sh --configure  # (re)choose which parts this board has, then install
#      sudo ./install.sh --check      # just print a health report
#
#  A first install run from a terminal asks which parts this board has. With no
#  terminal (DietPi first boot) it uses /boot/odroid-ha.conf or the defaults.
#  Safe to re-run: every step is idempotent. Settings: /etc/odroid-ha/odroid-ha.conf
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/A7QG59F2/ODroid-C2-bluetooth-proxy"
BT_PROXY_REPO="https://github.com/denvera/bt-proxy.git"
CONF_DIR=/etc/odroid-ha
CONF="$CONF_DIR/odroid-ha.conf"
APP_DIR=/opt/odroid-ha
BTP_DIR=/opt/bt-proxy
WPA_CONF=/etc/wpa_supplicant/wpa_supplicant.conf
WLAN_IFACE_CONF=/etc/network/interfaces.d/wlan0.conf
LOG=/var/log/odroid-ha-install.log
WA_DIR=/opt/odroid-winamp
WA_PORT=8590
MA_TOKEN_FILE="$CONF_DIR/music-assistant.token"
# Webamp (MIT, github.com/captbaritone/webamp) from the npm registry, pinned
WEBAMP_VERSION=2.3.1
WEBAMP_TGZ_SHA256=d45a3d46cbd3e4bdd39a9b71656d87341ddac48b4a4c4a61356ec065a6bba7c0

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
say()  { echo "${c_ok}==>${c_off} $*"; }
warn() { echo "${c_warn}[!]${c_off} $*"; }
die()  { echo "${c_err}[x]${c_off} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo $0"

# ─── Settings: read the config, then fill in defaults for anything missing ────
load_conf() {
    # shellcheck source=/dev/null
    if [ -r "$CONF" ]; then . "$CONF"; fi
    # A short per-board ID (end of the Ethernet MAC) keeps names unique when
    # several C2s talk to the same Home Assistant.
    BOARD_ID=$( { tr -d ':\n' </sys/class/net/eth0/address | tail -c 4; } 2>/dev/null || true)
    BOARD_ID=${BOARD_ID:-0000}
    : "${ENABLE_BLUETOOTH:=1}" "${ENABLE_BT_PROXY:=1}" "${ENABLE_WIFI:=1}" "${ENABLE_KIOSK:=1}"
    : "${BT_PROXY_NAME:=odroid-c2-$BOARD_ID}"
    : "${BT_PROXY_FRIENDLY_NAME:=Odroid C2 Bluetooth Proxy $BOARD_ID}"
    : "${WIFI_SSID:=}" "${WIFI_COUNTRY:=US}" "${WIFI_5GHZ_ONLY:=1}" "${WIFI_DISABLE_POWERSAVE:=1}"
    : "${HA_URL:=http://homeassistant.local:8123/lovelace/0}"
    : "${TIMEZONE:=}"
    : "${ONSCREEN_KEYBOARD:=1}" "${OSK_FLOATING_BUTTON:=0}"
    : "${ENABLE_WINAMP:=0}" "${MA_URL:=http://homeassistant.local:8095}" "${WINAMP_LOCAL_PLAYER:=1}"
    : "${WINAMP_PLAYER_NAME:=Odroid C2 $BOARD_ID}" "${WINAMP_PLAYER:=}" "${WINAMP_AUDIO_DEVICE:=}" "${WINAMP_SKIN:=}"
}
on() { [ "${!1:-0}" = "1" ]; }
onoff() { on "$1" && echo on || echo off; }
bt_needed() { on ENABLE_BLUETOOTH || on ENABLE_BT_PROXY; }
winamp_on() { on ENABLE_KIOSK && on ENABLE_WINAMP; }
# The JVC radio parts moved to their own repo (jvc2mqtt) on 2026-11-17. A board
# that had them keeps running them until jvc2mqtt's installer takes them over.
JVC2MQTT_URL="https://github.com/A7QG59F2/jvc2mqtt"
old_radio_parts() {
    [ ! -d /etc/jvc2mqtt ] && { [ -f /etc/systemd/system/odroid-ha-radio-link.service ] || [ -d "$APP_DIR/jvc" ]; }
}

# ─── Health report ────────────────────────────────────────────────────────────
check() {
    echo "── Features ──"
    echo "  bluetooth: $(onoff ENABLE_BLUETOOTH)   bt-proxy: $(onoff ENABLE_BT_PROXY)   wifi: $(onoff ENABLE_WIFI)   kiosk: $(onoff ENABLE_KIOSK)   winamp: $(winamp_on && echo on || echo off)"
    echo "── Hardware ──"
    lsusb 2>/dev/null | grep -Ei '2357:0604|148f:5572|0bda|touch|hid' | sed 's/^/  /' || echo "  (lsusb shows none of the expected devices)"
    if bt_needed; then
        echo "  UB500 (2357:0604):  $(lsusb 2>/dev/null | grep -qi 2357:0604 && echo found || echo MISSING)"
    fi
    if on ENABLE_WIFI; then
        echo "  RT5572 (148f:5572): $(lsusb 2>/dev/null | grep -qi 148f:5572 && echo found || echo MISSING)"
        echo "  RT5572 firmware:    $([ -f /lib/firmware/rt2870.bin ] && echo present || echo 'MISSING (apt install firmware-mediatek)')"
    fi
    if bt_needed; then
        echo "── Bluetooth ──"
        rfkill list bluetooth 2>/dev/null | sed 's/^/  /' || true
        bluetoothctl show 2>/dev/null | grep -E 'Controller|Powered|Name' | sed 's/^/  /' || echo "  bluetoothctl: no controller"
    fi
    if on ENABLE_WIFI; then
        echo "── Wi-Fi ──"
        if iw dev wlan0 link 2>/dev/null | grep -q Connected; then
            iw dev wlan0 link | grep -E 'SSID|freq|signal' | sed 's/^\s*/  /'
            echo "  address: $(ip -4 -br addr show wlan0 2>/dev/null | awk '{print $3}')"
        else
            echo "  wlan0 not connected${WIFI_SSID:+ (SSID $WIFI_SSID)}"
        fi
    fi
    echo "── Services ──"
    if bt_needed; then
        printf "  %-10s %s\n" bluetooth "$(systemctl is-active bluetooth 2>/dev/null || true)"
    fi
    if on ENABLE_BT_PROXY; then
        printf "  %-10s %s
" bt-proxy "$(systemctl is-active bt-proxy 2>/dev/null || true)"
        printf "  %-10s %s\n" "port 6053" "$(ss -ltn 2>/dev/null | grep -q ':6053 ' && echo listening || echo 'not listening')"
    fi
    if on ENABLE_KIOSK; then
        printf "  %-10s %s\n" kiosk "$(pgrep -x chromium >/dev/null && echo 'chromium running' || echo 'chromium not running')"
        if on ONSCREEN_KEYBOARD; then
            printf "  %-10s %s\n" keyboard "$(pgrep -f 'bin/onboard' >/dev/null && echo 'onboard running' || echo 'onboard not running')"
            printf "  %-10s %s\n" "a11y bus" "$(pgrep -f at-spi-bus-launcher >/dev/null && echo running || echo 'not running')"
        fi
    fi
    if winamp_on; then
        printf "  %-10s %s\n" winamp-web "$(systemctl is-active odroid-winamp-web 2>/dev/null || true)"
        printf "  %-10s %s\n" "MA server" "$(curl -fsS -m 3 -o /dev/null "$MA_URL" && echo "reachable ($MA_URL)" || echo "NOT reachable ($MA_URL)")"
        printf "  %-10s %s\n" "MA token" "$([ -s "$MA_TOKEN_FILE" ] && echo saved || echo 'MISSING (odroid-ha-install --configure)')"
        if on WINAMP_LOCAL_PLAYER; then
            printf "  %-10s %s\n" squeezelite "$(systemctl is-active squeezelite 2>/dev/null || true) (\"$WINAMP_PLAYER_NAME\")"
        fi
    fi
    if [ -d /etc/jvc2mqtt ]; then
        printf "  %-10s %s\n" "JVC radio" "jvc2mqtt installed (jvc2mqtt-check)"
    elif old_radio_parts; then
        printf "  %-10s %s\n" "JVC radio" "old odroid-ha radio parts still running; install $JVC2MQTT_URL"
    fi
    echo "── Temperature ──"
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] && echo "  $(( $(cat "$z") / 1000 )) °C"
    done
}
if [ "${1:-}" = "--check" ]; then
    load_conf; check; exit 0
fi

# ─── If run standalone (e.g. DietPi first-boot custom script), fetch the repo ─
if [ ! -f "$SRC_DIR/kiosk/kiosk-session.sh" ]; then
    say "Repo files not next to the script, cloning $REPO_URL"
    command -v git >/dev/null || { apt-get update; apt-get install -y git; }
    rm -rf "$APP_DIR/src"
    git clone --depth 1 "$REPO_URL" "$APP_DIR/src"
    exec bash "$APP_DIR/src/install.sh" "$@"
fi

# ─── Wi-Fi credentials helpers ────────────────────────────────────────────────
# The password is only ever read from the terminal and turned into the 64-hex
# WPA key; the plaintext is never written anywhere or put on a command line.
WIFI_PSK=""
need_wpa_tools() {
    command -v wpa_passphrase >/dev/null || { apt-get update -qq; apt-get install -y wpasupplicant >/dev/null; }
}
psk_from_password() {   # stdin: password   $1: SSID
    wpa_passphrase "$1" | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p'
}
read_wifi_password() {
    local pw pw2
    need_wpa_tools
    while true; do
        read -rsp "  Wi-Fi password for $WIFI_SSID: " pw; echo
        if [ "${#pw}" -lt 8 ] || [ "${#pw}" -gt 63 ]; then echo "  WPA passwords are 8-63 characters."; continue; fi
        read -rsp "  Again: " pw2; echo
        [ "$pw" = "$pw2" ] && break
        echo "  They don't match, try again."
    done
    WIFI_PSK=$(printf '%s\n' "$pw" | psk_from_password "$WIFI_SSID")
    [ -n "$WIFI_PSK" ] || die "Couldn't derive the Wi-Fi key"
}
# Print the psk= value stored for an SSID in wpa_supplicant.conf (hex or "quoted")
existing_psk() {
    [ -r "$WPA_CONF" ] || return 0
    S="$1" awk '
        BEGIN { want = "ssid=\"" ENVIRON["S"] "\"" }
        { l = $0; sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l) }
        l ~ /^network=\{/ { inb = 1; m = 0; p = ""; next }
        inb && l == want  { m = 1 }
        inb && l ~ /^psk=/ { p = substr(l, 5) }
        inb && l == "}"   { if (m && p != "") { print p; exit } inb = 0 }
    ' "$WPA_CONF"
}
write_wpa_conf() {   # $1: SSID  $2: 64-hex key
    local freqs=""
    if on WIFI_5GHZ_ONLY; then
        freqs="    # 5 GHz only, so Wi-Fi doesn't fight the Bluetooth dongle on 2.4 GHz
    freq_list=5180 5200 5220 5240 5260 5280 5300 5320 5500 5520 5540 5560 5580 5600 5620 5640 5660 5680 5700 5720 5745 5765 5785 5805 5825"
    fi
    [ -f "$WPA_CONF" ] && cp -p "$WPA_CONF" "$WPA_CONF.bak"
    (umask 077; cat > "$WPA_CONF" <<EOF
# Generated by odroid-ha install.sh (odroid-ha-install --configure to change)
country=$WIFI_COUNTRY
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$1"
    psk=$2
    key_mgmt=WPA-PSK
$freqs
}
EOF
    )
    chmod 600 "$WPA_CONF" "$WPA_CONF.bak" 2>/dev/null || true
}

# ─── Interactive setup: which parts does this board have? ─────────────────────
# KEY="value" into the config, replacing the existing line or appending one.
set_conf() {
    local key=$1 val=$2
    val=${val//\\/\\\\}; val=${val//\"/\\\"}; val=${val//\$/\\\$}; val=${val//\`/\\\`}
    if grep -q "^$key=" "$CONF"; then
        K="$key" V="$val" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
            index($0, k "=") == 1 { print k "=\"" v "\""; next } { print }' "$CONF" >"$CONF.tmp"
        cat "$CONF.tmp" >"$CONF"; rm -f "$CONF.tmp"
    else
        printf '%s="%s"\n' "$key" "$val" >>"$CONF"
    fi
}
ask_yn() {   # $1: variable  $2: question   (Enter keeps the current value)
    local var=$1 cur=${!1:-0} ans hint
    [ "$cur" = 1 ] && hint="Y/n" || hint="y/N"
    while true; do
        read -rp "$2 [$hint] " ans
        case "${ans,,}" in
            "")     break ;;
            y|yes)  cur=1; break ;;
            n|no)   cur=0; break ;;
        esac
    done
    printf -v "$var" '%s' "$cur"; set_conf "$var" "$cur"
}
ask_str() {  # $1: variable  $2: question
    local var=$1 ans
    read -rp "$2 [${!1:-}] " ans
    [ -n "$ans" ] && printf -v "$var" '%s' "$ans"
    set_conf "$var" "${!var:-}"
}
read_ma_token() {
    local t
    echo "    Music Assistant token: in Music Assistant's web UI open your user profile and"
    echo "    create a long-lived token (an admin user's, so the equalizer can change DSP settings)."
    read -rsp "    Paste it here (not echoed): " t; echo
    if [ -n "$t" ]; then
        (umask 077; printf '%s\n' "$t" >"$MA_TOKEN_FILE")
        chmod 600 "$MA_TOKEN_FILE"
    fi
}
system_tz() { readlink -f /etc/localtime 2>/dev/null | sed 's|^.*/zoneinfo/||'; }
configure() {
    [ -t 0 ] || die "--configure needs a terminal (use: ssh -t root@<odroid> odroid-ha-install --configure)"
    echo
    echo "Which parts does this Odroid have? Press Enter to keep the value in [brackets]."
    echo
    TIMEZONE=${TIMEZONE:-$(system_tz)}
    while true; do
        ask_str TIMEZONE "Time zone (e.g. America/Indiana/Indianapolis, Europe/London)"
        [ -f "/usr/share/zoneinfo/$TIMEZONE" ] && break
        warn "'$TIMEZONE' isn't a known zone. Names are listed under /usr/share/zoneinfo."
        TIMEZONE=$(system_tz)
    done
    ask_yn ENABLE_BLUETOOTH "Bluetooth dongle (TP-Link UB500)?"
    if on ENABLE_BLUETOOTH; then
        ask_yn ENABLE_BT_PROXY "  Home Assistant Bluetooth proxy on it?"
    else
        ENABLE_BT_PROXY=0; set_conf ENABLE_BT_PROXY 0
    fi
    if on ENABLE_BT_PROXY; then
        ask_str BT_PROXY_NAME "  Name in Home Assistant (lowercase, unique per board)"
        BT_PROXY_NAME=$(echo "$BT_PROXY_NAME" | tr 'A-Z_ ' 'a-z--' | tr -cd 'a-z0-9-')
        BT_PROXY_NAME=${BT_PROXY_NAME:-odroid-c2-$BOARD_ID}
        set_conf BT_PROXY_NAME "$BT_PROXY_NAME"
        ask_str BT_PROXY_FRIENDLY_NAME "  Display name"
    fi
    ask_yn ENABLE_WIFI "Wi-Fi (TL-WN821N, RT5572)?"
    if on ENABLE_WIFI; then
        ask_str WIFI_SSID "  Network name (SSID, empty = leave Wi-Fi unconfigured)"
        if [ -n "$WIFI_SSID" ]; then
            ask_str WIFI_COUNTRY "  Country code"
            ask_yn WIFI_5GHZ_ONLY "  5 GHz only (recommended next to Bluetooth)?"
            local change=y
            if [ -n "$(existing_psk "$WIFI_SSID")" ]; then
                read -rp "  A password for $WIFI_SSID is already saved. Change it? [y/N] " change
            fi
            case "${change,,}" in y|yes) read_wifi_password ;; esac
        fi
    fi
    ask_yn ENABLE_KIOSK "Dashboard kiosk on the touch screen (MAGEX 10.1\")?"
    if on ENABLE_KIOSK; then
        ask_yn ENABLE_WINAMP "  Winamp music player (Music Assistant) on the screen instead of the dashboard?"
    else
        ENABLE_WINAMP=0; set_conf ENABLE_WINAMP 0
    fi
    if winamp_on; then
        ask_str MA_URL "    Music Assistant URL (port 8095)"
        local change=y
        if [ -s "$MA_TOKEN_FILE" ]; then
            read -rp "    A Music Assistant token is already saved. Change it? [y/N] " change
        fi
        case "${change,,}" in y|yes) read_ma_token ;; esac
        ask_yn WINAMP_LOCAL_PLAYER "    Play the music on this Odroid (squeezelite player for Music Assistant)?"
        if on WINAMP_LOCAL_PLAYER; then
            ask_str WINAMP_PLAYER_NAME "      Player name in Music Assistant"
            ask_str WINAMP_AUDIO_DEVICE "      ALSA output device (empty = default; list with: squeezelite -l)"
        fi
        ask_str WINAMP_PLAYER "    Music Assistant player to control (empty = this Odroid's own)"
        [ "${SCREEN_ROTATION:-normal}" = normal ] && SCREEN_ROTATION=left
        ask_str SCREEN_ROTATION "    Screen rotation (left or right = portrait)"
    elif on ENABLE_KIOSK; then
        ask_str HA_URL "  Dashboard URL"
        ask_yn ONSCREEN_KEYBOARD "  On-screen keyboard?"
        on ONSCREEN_KEYBOARD && ask_yn OSK_FLOATING_BUTTON "  Floating button to open the keyboard by hand?"
    fi
    if on ENABLE_BT_PROXY && [ -d /etc/jvc2mqtt ]; then
        warn "The BLE proxy's constant scanning stops the dongle from connecting to the JVC radio (jvc2mqtt)."
        warn "The radio parts only reconnect reliably with the proxy off."
    fi
    echo
    say "Saved to $CONF. Change it any time with:  odroid-ha-install --configure"
    echo
}

# ─── Config ───────────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR"
NEW_CONF=0
if [ ! -f "$CONF" ]; then
    # Allow a pre-made config on the boot partition (handy for unattended installs)
    if [ -f /boot/odroid-ha.conf ]; then
        cp /boot/odroid-ha.conf "$CONF"
        say "Using /boot/odroid-ha.conf"
    else
        cp "$SRC_DIR/config/odroid-ha.conf.example" "$CONF"
        NEW_CONF=1
    fi
fi
# ENABLE_BLUETOOTH is new (2026-11-17): the dongle used to be set up whenever the
# proxy or the JVC parts were on, so keep it on for boards that had any of them.
if ! grep -q '^ENABLE_BLUETOOTH=' "$CONF"; then
    BT_WAS=$( (set +u
               # shellcheck source=/dev/null
               . "$CONF"
               [ "${ENABLE_BT_PROXY:-1}${ENABLE_JVC_TOOLS:-0}${ENABLE_RADIO_AUDIO:-0}" = 000 ] && echo 0 || echo 1) )
    set_conf ENABLE_BLUETOOTH "$BT_WAS"
fi
# Settings added to the repo after this board was set up: append them with
# their example defaults so they're visible and editable. Existing values stay.
ADDED=""
while IFS= read -r line; do
    key=${line%%=*}
    if ! grep -q "^$key=" "$CONF"; then
        [ -z "$ADDED" ] && printf '\n# Added by install.sh (new settings, defaults from the repo)\n' >>"$CONF"
        echo "$line" >>"$CONF"; ADDED="$ADDED $key"
    fi
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$SRC_DIR/config/odroid-ha.conf.example")
load_conf
[ -n "$ADDED" ] && say "New settings added to $CONF:$ADDED"
if [ "${1:-}" = "--configure" ] || { [ "$NEW_CONF" = 1 ] && [ -t 0 ]; }; then
    configure
    load_conf
elif [ "$NEW_CONF" = 1 ]; then
    warn "Created $CONF with defaults. Run  odroid-ha-install --configure  to choose this board's parts."
fi
if on ENABLE_BT_PROXY && ! on ENABLE_BLUETOOTH; then
    warn "ENABLE_BT_PROXY needs the Bluetooth dongle; turning ENABLE_BLUETOOTH on"
    ENABLE_BLUETOOTH=1; set_conf ENABLE_BLUETOOTH 1
fi
if on ENABLE_WINAMP && ! on ENABLE_KIOSK; then
    warn "ENABLE_WINAMP shows the player on the kiosk screen; it does nothing with ENABLE_KIOSK=0"
fi
BT_NEEDED=0; bt_needed && BT_NEEDED=1

exec > >(tee -a "$LOG") 2>&1
say "Install started $(date)  (log: $LOG)"
say "Features: bluetooth $(onoff ENABLE_BLUETOOTH), bt-proxy $(onoff ENABLE_BT_PROXY), wifi $(onoff ENABLE_WIFI), kiosk $(onoff ENABLE_KIOSK), winamp $(winamp_on && echo on || echo off)"

# Basic sanity: is this an Odroid C2?
if ! grep -qi 'odroid-c2\|odroid c2\|meson-gxbb' /proc/device-tree/model /proc/device-tree/compatible 2>/dev/null; then
    warn "This doesn't look like an Odroid C2 ($(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)). Continuing anyway."
fi

# Local time zone: the kiosk clock follows it, and so does the JVC radio's
# clock when jvc2mqtt runs on this board (set on every connect). DietPi only sets it on first boot;
# an empty TIMEZONE leaves whatever the system has.
if [ -z "$TIMEZONE" ]; then
    :
elif [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    if [ "$(readlink -f /etc/localtime)" != "$(readlink -f "/usr/share/zoneinfo/$TIMEZONE")" ]; then
        say "Setting time zone to $TIMEZONE"
        timedatectl set-timezone "$TIMEZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    fi
    echo "$TIMEZONE" > /etc/timezone
    [ -f /boot/dietpi.txt ] && sed -i "s|^AUTO_SETUP_TIMEZONE=.*|AUTO_SETUP_TIMEZONE=$TIMEZONE|" /boot/dietpi.txt
else
    warn "Unknown TIMEZONE '$TIMEZONE' (see /usr/share/zoneinfo); leaving the time zone as it is."
fi

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# ─── 1. Packages ──────────────────────────────────────────────────────────────
say "Installing packages"
apt-get update
$APT install rfkill usbutils iw curl git ca-certificates python3
# Firmware: Realtek = UB500 (rtl8761bu_fw.bin), mediatek = RT5572 (rt2870.bin;
# trixie moved the Ralink files out of firmware-misc-nonfree). These replace
# DietPi's armbian-firmware package (they conflict), which is expected.
FW=()
[ "$BT_NEEDED" = 1 ] && FW+=(firmware-realtek)
on ENABLE_WIFI && FW+=(firmware-mediatek firmware-misc-nonfree)
if [ "${#FW[@]}" -gt 0 ]; then
    $APT install "${FW[@]}" || warn "firmware packages failed: check non-free-firmware is enabled in /etc/apt/sources.list"
fi
[ "$BT_NEEDED" = 1 ] && $APT install bluez
on ENABLE_WIFI && $APT install wpasupplicant

if on ENABLE_KIOSK; then
    $APT install --no-install-recommends \
        xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-legacy xinit \
        x11-xserver-utils xinput dbus-x11 chromium fonts-dejavu-core fonts-noto-color-emoji
    if on ONSCREEN_KEYBOARD; then
        # Onboard + everything its auto-show needs: the AT-SPI bus, the GTK/ATK
        # bridge Chromium talks through, GObject bindings, and dconf for settings.
        $APT install --no-install-recommends \
            onboard onboard-data at-spi2-core libatk-adaptor gir1.2-atspi-2.0 \
            dconf-cli dconf-gsettings-backend gsettings-desktop-schemas dbus-bin
    fi
fi
winamp_on && on WINAMP_LOCAL_PLAYER && $APT install --no-install-recommends squeezelite alsa-utils

# ─── 2. Bluetooth (UB500): for the proxy and/or jvc2mqtt ────────────────────
if [ "$BT_NEEDED" = 1 ]; then
    say "Enabling Bluetooth"
    # DietPi can blacklist Bluetooth via dietpi-config; undo that
    rm -f /etc/modprobe.d/dietpi-disable_bluetooth.conf
    modprobe btusb 2>/dev/null || true
    rfkill unblock bluetooth || true
    # Power the controller on at boot, and don't let BlueZ go idle
    if [ -f /etc/bluetooth/main.conf ]; then
        sed -i 's/^#\?\s*AutoEnable\s*=.*/AutoEnable=true/' /etc/bluetooth/main.conf
        grep -q '^AutoEnable=true' /etc/bluetooth/main.conf || sed -i '/^\[Policy\]/a AutoEnable=true' /etc/bluetooth/main.conf
    fi
    systemctl enable --now bluetooth
    # Reload the dongle so freshly installed firmware is picked up
    if lsusb | grep -qi 2357:0604; then
        say "UB500 found"
        if ! bluetoothctl show 2>/dev/null | grep -q Controller; then
            modprobe -r btusb 2>/dev/null || true; sleep 1; modprobe btusb; sleep 3
        fi
    else
        warn "UB500 (2357:0604) not found on USB. Plug it in (a short USB extension cable helps reception)."
    fi
    bluetoothctl power on >/dev/null 2>&1 || true
fi

# ─── 3. Wi-Fi (RT5572) ────────────────────────────────────────────────────────
if on ENABLE_WIFI; then
    say "Setting up Wi-Fi"
    if on WIFI_DISABLE_POWERSAVE; then
        # Power saving makes the proxy drop off the network
        cat > /etc/udev/rules.d/70-odroid-ha-wifi-powersave.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set power_save off"
EOF
        for w in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do iw dev "$w" set power_save off 2>/dev/null || true; done
    else
        rm -f /etc/udev/rules.d/70-odroid-ha-wifi-powersave.rules
    fi
    # Ethernet stays as a fallback. ifupdown leaves eth0's default route behind
    # when the cable is pulled, so have the kernel skip routes on a dead port;
    # Wi-Fi gets metric 100 so Ethernet wins while it is plugged in.
    cat > /etc/sysctl.d/90-odroid-ha-net.conf <<'EOF'
# Skip routes on an unplugged port (Ethernet preferred, Wi-Fi when unplugged)
net.ipv4.conf.all.ignore_routes_with_linkdown = 1
net.ipv6.conf.all.ignore_routes_with_linkdown = 1
EOF
    sysctl -p /etc/sysctl.d/90-odroid-ha-net.conf >/dev/null || true
    # Regulatory domain: the 5 GHz channels stay "no IR" until it's set.
    # Changing it drops the Wi-Fi link, so only touch it when it differs.
    if ! iw reg get 2>/dev/null | grep -q "^country $WIFI_COUNTRY:"; then
        iw reg set "$WIFI_COUNTRY" 2>/dev/null || true
    fi
    [ -f /boot/dietpi.txt ] && sed -i "s/^AUTO_SETUP_NET_WIFI_COUNTRY_CODE=.*/AUTO_SETUP_NET_WIFI_COUNTRY_CODE=$WIFI_COUNTRY/" /boot/dietpi.txt

    lsusb | grep -qi 148f:5572 || warn "RT5572 (148f:5572) not found on USB."
    if [ -n "$WIFI_SSID" ]; then
        PSK=${WIFI_PSK:-$(existing_psk "$WIFI_SSID")}
        # A "quoted" plaintext key (e.g. written by dietpi-config) becomes the hex key
        case "$PSK" in
            \"*\") PW=${PSK#\"}; PW=${PW%\"}; PSK=$(printf '%s\n' "$PW" | psk_from_password "$WIFI_SSID"); unset PW ;;
        esac
        if [ -z "$PSK" ]; then
            warn "No Wi-Fi password saved for $WIFI_SSID. Run:  odroid-ha-install --configure"
        else
            OLD_SUM=$(cksum <"$WPA_CONF" 2>/dev/null || true)
            write_wpa_conf "$WIFI_SSID" "$PSK"
            unset PSK
            if [ ! -f "$WLAN_IFACE_CONF" ] || grep -q 'odroid-ha' "$WLAN_IFACE_CONF"; then
                cat > "$WLAN_IFACE_CONF" <<EOF
# Generated by odroid-ha install.sh. Credentials: $WPA_CONF
allow-hotplug wlan0
iface wlan0 inet dhcp
    metric 100
    wpa-conf $WPA_CONF
EOF
            else
                warn "$WLAN_IFACE_CONF wasn't made by this script; leaving it alone"
            fi
            if [ ! -e /sys/class/net/wlan0 ]; then
                warn "No wlan0 interface yet; Wi-Fi will come up when the RT5572 is plugged in."
            elif ! iw dev wlan0 link 2>/dev/null | grep -q Connected; then
                ifdown wlan0 2>/dev/null || true
                ifup wlan0 || warn "Wi-Fi didn't come up; check the SSID/password with  odroid-ha-install --configure"
            elif [ "$OLD_SUM" != "$(cksum <"$WPA_CONF")" ]; then
                wpa_cli -i wlan0 reconfigure >/dev/null 2>&1 || true
            fi
            # Give the link time to (re)connect before steps that need the network
            for _ in $(seq 1 30); do
                iw dev wlan0 link 2>/dev/null | grep -q Connected && ip -4 route show default | grep -q . && break
                sleep 1
            done
            if iw dev wlan0 link 2>/dev/null | grep -q Connected; then
                say "Wi-Fi connected to $WIFI_SSID: $(ip -4 -br addr show wlan0 | awk '{print $3}')"
            else
                warn "Wi-Fi isn't connected to $WIFI_SSID (yet)"
            fi
        fi
    fi
else
    rm -f /etc/udev/rules.d/70-odroid-ha-wifi-powersave.rules /etc/sysctl.d/90-odroid-ha-net.conf
    if [ -f "$WLAN_IFACE_CONF" ] && grep -q 'odroid-ha' "$WLAN_IFACE_CONF"; then
        ifdown wlan0 2>/dev/null || true
        rm -f "$WLAN_IFACE_CONF"
    fi
fi

# ─── 4. Bluetooth proxy (denvera/bt-proxy, native, no Docker) ────────────────
if on ENABLE_BT_PROXY; then
    say "Installing bt-proxy"
    if ! command -v uv >/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
    fi
    if [ -d "$BTP_DIR/.git" ]; then
        git -C "$BTP_DIR" pull --ff-only || warn "bt-proxy update failed, keeping current version"
    else
        rm -rf "$BTP_DIR"
        git clone --depth 1 "$BT_PROXY_REPO" "$BTP_DIR"
    fi
    (cd "$BTP_DIR" && UV_PYTHON_INSTALL_DIR=/opt/uv-python uv sync)

    cat > /etc/systemd/system/bt-proxy.service <<EOF
[Unit]
Description=ESPHome-compatible Bluetooth proxy for Home Assistant (UB500)
After=bluetooth.service network-online.target
Wants=network-online.target
Requires=bluetooth.service

[Service]
Type=simple
WorkingDirectory=$BTP_DIR
ExecStartPre=-/usr/sbin/rfkill unblock bluetooth
ExecStartPre=-/usr/bin/bluetoothctl power on
ExecStart=$BTP_DIR/.venv/bin/python -m bt_proxy \\
    --name "$BT_PROXY_NAME" \\
    --friendly-name "$BT_PROXY_FRIENDLY_NAME" \\
    --adapter "${BT_ADAPTER:-hci0}" \\
    --max-connections "${BT_MAX_CONNECTIONS:-3}" \\
    --log-level "${BT_PROXY_LOG_LEVEL:-INFO}"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable bt-proxy
    systemctl restart bt-proxy
else
    systemctl disable --now bt-proxy 2>/dev/null || true
fi

# ─── 5. Kiosk (auto-login on tty1 → startx → Chromium) ───────────────────────
install -d -m 755 "$APP_DIR"
install -m 755 "$SRC_DIR/kiosk/kiosk-session.sh" "$APP_DIR/kiosk-session.sh"

if on ENABLE_KIOSK; then
    say "Setting up kiosk for user ${KIOSK_USER:=kiosk}"
    id "$KIOSK_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$KIOSK_USER"
    usermod -aG video,input,render,tty,audio "$KIOSK_USER" 2>/dev/null || usermod -aG video,input,tty,audio "$KIOSK_USER"

    # Let a console user start Xorg
    cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=console
needs_root_rights=yes
EOF

    # The C2 has two DRM devices: card0 = meson-drm (HDMI out) and card1 =
    # lima (render-only GPU). Left alone, Xorg ends up with two screens on
    # card0 (the fallback probe + an auto-added GPU screen) and dies with
    # "Cannot run in framebuffer mode". Pin modesetting to the display
    # controller by its stable by-path name and stop GPU auto-adding.
    mkdir -p /etc/X11/xorg.conf.d
    cat > /etc/X11/xorg.conf.d/10-odroid-ha-meson.conf <<'EOF'
# Generated by odroid-ha install.sh
Section "ServerFlags"
    Option     "AutoAddGPU" "false"
EndSection

Section "Device"
    Identifier "meson"
    Driver     "modesetting"
    Option     "kmsdev" "/dev/dri/by-path/platform-d0100000.vpu-card"
EndSection
EOF

    # Hand tty1 to the kiosk user. DietPi-Autostart must stay on "0: Console",
    # otherwise it fights over tty1. The zz- name makes this override load last.
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/zz-odroid-ha-kiosk.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF
    [ -f /boot/dietpi/.dietpi-autostart_index ] && echo 0 > /boot/dietpi/.dietpi-autostart_index

    CURSOR_ARG=""; [ "${HIDE_CURSOR:-1}" = "1" ] && CURSOR_ARG="-nocursor"
    KHOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)
    cat > "$KHOME/.bash_profile" <<EOF
# Odroid HA kiosk: start X + Chromium on tty1 only (SSH logins get a normal shell)
if [ -z "\${DISPLAY:-}" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    startx $APP_DIR/kiosk-session.sh -- $CURSOR_ARG -nolisten tcp vt1 >"\$HOME/.kiosk-x.log" 2>&1
    # X only returns if it failed; pause so getty doesn't hit systemd's start limit
    sleep 10
    logout
fi
EOF
    chown "$KIOSK_USER:" "$KHOME/.bash_profile"

    # On-screen keyboard settings as system-wide dconf defaults, so nothing has
    # to be clicked through onboard-settings on the touch screen.
    if on ONSCREEN_KEYBOARD; then
        say "Configuring on-screen keyboard (Onboard)"
        mkdir -p /etc/dconf/profile /etc/dconf/db/odroidha.d
        printf 'user-db:user\nsystem-db:odroidha\n' > /etc/dconf/profile/user
        b() { [ "$1" = "1" ] && echo true || echo false; }
        cat > /etc/dconf/db/odroidha.d/00-onboard <<EOF
# Generated by odroid-ha install.sh – edit /etc/odroid-ha/odroid-ha.conf instead
[org/gnome/desktop/interface]
toolkit-accessibility=true

[org/onboard]
layout='${OSK_LAYOUT:-Compact}'
theme='${OSK_THEME:-Droid}'
show-status-icon=false
start-minimized=true
use-system-defaults=false

[org/onboard/auto-show]
enabled=true

[org/onboard/window]
docking-enabled=true
docking-edge='${OSK_EDGE:-bottom}'
force-to-top=true
keep-aspect-ratio=false

[org/onboard/window/landscape]
dock-expand=true

[org/onboard/window/portrait]
dock-expand=true

[org/onboard/icon-palette]
in-use=$(b "$OSK_FLOATING_BUTTON")

[org/onboard/keyboard]
touch-input='${OSK_TOUCH_INPUT:-none}'
EOF
        dconf update
        # Drop any per-user Onboard settings left by an earlier attempt, so the
        # defaults above win (user-db would otherwise override them).
        rm -f "$KHOME/.config/dconf/user"
    else
        rm -f /etc/dconf/db/odroidha.d/00-onboard
        if command -v dconf >/dev/null; then dconf update || true; fi
    fi

    # Quiet console: no kernel messages / cursor blink over the dashboard
    echo 'kernel.printk = 3 3 3 3' > /etc/sysctl.d/90-odroid-ha-quiet.conf
    sysctl -p /etc/sysctl.d/90-odroid-ha-quiet.conf >/dev/null || true

    systemctl daemon-reload
    systemctl reset-failed getty@tty1 2>/dev/null || true
    systemctl restart getty@tty1 || true
else
    if [ -f /etc/systemd/system/getty@tty1.service.d/zz-odroid-ha-kiosk.conf ]; then
        rm -f /etc/systemd/system/getty@tty1.service.d/zz-odroid-ha-kiosk.conf
        systemctl daemon-reload
        systemctl restart getty@tty1 || true
    fi
fi

# ─── 5b. Winamp player for Music Assistant (on the kiosk screen) ─────────────
# Webamp (a Winamp 2 clone) served from localhost; kiosk-session.sh opens it
# instead of the dashboard. Its buttons, playlist and equalizer drive a Music
# Assistant player over MA's WebSocket API (winamp/www/ma-winamp.js). The
# music itself plays on that player: by default squeezelite on this board.
if winamp_on; then
    say "Setting up the Winamp player"
    install -d -m 755 "$WA_DIR" "$WA_DIR/www"
    TGZ="$WA_DIR/webamp-$WEBAMP_VERSION.tgz"
    if ! echo "$WEBAMP_TGZ_SHA256  $TGZ" | sha256sum -c --status 2>/dev/null; then
        curl -fsSL -o "$TGZ.part" "https://registry.npmjs.org/webamp/-/webamp-$WEBAMP_VERSION.tgz" \
            || die "Couldn't download Webamp from registry.npmjs.org"
        echo "$WEBAMP_TGZ_SHA256  $TGZ.part" | sha256sum -c --status || { rm -f "$TGZ.part"; die "Webamp download failed its checksum"; }
        mv "$TGZ.part" "$TGZ"
    fi
    tar -xzf "$TGZ" -O package/built/webamp.bundle.min.js >"$WA_DIR/www/webamp.bundle.min.js"
    install -m 644 "$SRC_DIR/winamp/www/index.html" "$SRC_DIR/winamp/www/ma-winamp.js" "$WA_DIR/www/"
    install -d -m 755 "$WA_DIR/www/skins"

    # Settings for the page. The token is only readable by root and the kiosk user.
    [ -s "$MA_TOKEN_FILE" ] || warn "No Music Assistant token saved yet: run  odroid-ha-install --configure"
    WA_TARGET="$WINAMP_PLAYER"
    [ -z "$WA_TARGET" ] && on WINAMP_LOCAL_PLAYER && WA_TARGET="$WINAMP_PLAYER_NAME"
    WA_SKIN="$WINAMP_SKIN"
    # A bare file name means a skin dropped into /opt/odroid-winamp/www/skins
    case "$WA_SKIN" in ""|*/*) ;; *) WA_SKIN="skins/$WA_SKIN" ;; esac
    MA_TOKEN="$(cat "$MA_TOKEN_FILE" 2>/dev/null || true)" MA_URL="$MA_URL" WA_TARGET="$WA_TARGET" WA_SKIN="$WA_SKIN" \
        python3 -c 'import json, os
cfg = {"maUrl": os.environ["MA_URL"], "token": os.environ["MA_TOKEN"].strip(),
       "player": os.environ["WA_TARGET"], "skin": os.environ["WA_SKIN"]}
print("// Generated by odroid-ha install.sh from /etc/odroid-ha/odroid-ha.conf")
print("window.WINAMP_CONFIG = " + json.dumps(cfg) + ";")' >"$WA_DIR/www/config.js.tmp"
    chown "root:$KIOSK_USER" "$WA_DIR/www/config.js.tmp"; chmod 640 "$WA_DIR/www/config.js.tmp"
    mv "$WA_DIR/www/config.js.tmp" "$WA_DIR/www/config.js"

    cat > /etc/systemd/system/odroid-winamp-web.service <<EOF
[Unit]
Description=Odroid Winamp page for the kiosk (localhost only)

[Service]
User=$KIOSK_USER
ExecStart=/usr/bin/python3 -m http.server $WA_PORT --bind 127.0.0.1 --directory $WA_DIR/www
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    if on WINAMP_LOCAL_PLAYER; then
        # Our own unit rather than the package's: fixed name, and the Ethernet MAC
        # as player ID so MA keeps seeing the same player when the board is on Wi-Fi.
        SL_NAME=$(printf '%s' "$WINAMP_PLAYER_NAME" | tr -cd 'A-Za-z0-9 ._-')
        SL_MAC=$(cat /sys/class/net/eth0/address 2>/dev/null || true)
        SL_ARGS="-n \"${SL_NAME:-Odroid C2 $BOARD_ID}\" -C 5"
        [ -n "$SL_MAC" ] && SL_ARGS="$SL_ARGS -m $SL_MAC"
        [ -n "$WINAMP_AUDIO_DEVICE" ] && SL_ARGS="$SL_ARGS -o $(printf '%s' "$WINAMP_AUDIO_DEVICE" | tr -cd 'A-Za-z0-9:,=._-')"
        cat > /etc/systemd/system/odroid-squeezelite.service <<EOF
[Unit]
Description=Squeezelite: this Odroid as a Music Assistant player
After=network-online.target sound.target
Wants=network-online.target

[Service]
DynamicUser=yes
SupplementaryGroups=audio
# -C 5 releases the sound card after 5 s of silence, for anything else using it
ExecStart=/usr/bin/squeezelite $SL_ARGS
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl disable --now squeezelite 2>/dev/null || true
        systemctl daemon-reload
        systemctl enable odroid-squeezelite
        systemctl restart odroid-squeezelite
    else
        systemctl disable --now odroid-squeezelite 2>/dev/null || true
        rm -f /etc/systemd/system/odroid-squeezelite.service
    fi
    systemctl daemon-reload
    systemctl enable odroid-winamp-web
    systemctl restart odroid-winamp-web
else
    for u in odroid-winamp-web odroid-squeezelite; do
        if [ -f "/etc/systemd/system/$u.service" ]; then
            systemctl disable --now "$u" 2>/dev/null || true
            rm -f "/etc/systemd/system/$u.service"
        fi
    done
    systemctl daemon-reload
    rm -rf "$WA_DIR"
fi

# ─── 6. JVC radio: moved to jvc2mqtt ─────────────────────────────────────────
# Its installer takes over the old odroid-ha radio services and settings, so
# leave them running here until then.
if old_radio_parts; then
    warn "The JVC radio parts moved to $JVC2MQTT_URL and are no longer updated here."
    warn "They keep running as they are. To take them over (settings and token move across):"
    warn "  git clone $JVC2MQTT_URL /opt/jvc2mqtt/src && /opt/jvc2mqtt/src/install.sh"
fi

# ─── 7. Convenience commands ──────────────────────────────────────────────────
install -m 755 "$SRC_DIR/install.sh" /usr/local/sbin/odroid-ha-install
cat > /usr/local/bin/odroid-ha-check <<'EOF'
#!/bin/sh
exec sudo /usr/local/sbin/odroid-ha-install --check
EOF
chmod 755 /usr/local/bin/odroid-ha-check

say "Done."
check
IP=$( { ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}'; } 2>/dev/null || true)
echo
echo "Next steps"
if on ENABLE_BT_PROXY; then
    echo "  - Home Assistant → Settings → Devices & Services: ESPHome should discover"
    echo "    \"$BT_PROXY_FRIENDLY_NAME\". If not: Add Integration → ESPHome → host ${IP:-<odroid-ip>}, port 6053."
fi
if winamp_on; then
    if on WINAMP_LOCAL_PLAYER; then
        echo "  - Music Assistant → Settings → Providers: make sure \"Squeezelite\" (slimproto) is added;"
        echo "    \"$WINAMP_PLAYER_NAME\" then shows up as a player. Queue music to it from MA or HA."
    fi
    [ -s "$MA_TOKEN_FILE" ] || echo "  - Save a Music Assistant token:  odroid-ha-install --configure"
elif on ENABLE_KIOSK; then
    echo "  - Kiosk login: see README.md \"Home Assistant side\" (trusted_networks for ${IP:-<odroid-ip>})."
fi
if on ENABLE_BLUETOOTH && ! on ENABLE_BT_PROXY && [ ! -d /etc/jvc2mqtt ]; then
    echo "  - JVC car radio on this dongle: install $JVC2MQTT_URL"
fi
cat <<EOF
  - Add or remove parts:  odroid-ha-install --configure
  - Health report:        odroid-ha-check
  - Pull latest + re-apply: odroid-ha-install
EOF

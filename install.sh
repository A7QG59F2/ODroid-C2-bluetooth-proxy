#!/bin/bash
# =============================================================================
#  Odroid C2  →  Home Assistant Bluetooth proxy  +  dashboard kiosk
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
    : "${ENABLE_BT_PROXY:=1}" "${ENABLE_WIFI:=1}" "${ENABLE_KIOSK:=1}" "${ENABLE_JVC_TOOLS:=0}"
    : "${BT_PROXY_NAME:=odroid-c2-$BOARD_ID}"
    : "${BT_PROXY_FRIENDLY_NAME:=Odroid C2 Bluetooth Proxy $BOARD_ID}"
    : "${WIFI_SSID:=}" "${WIFI_COUNTRY:=US}" "${WIFI_5GHZ_ONLY:=1}" "${WIFI_DISABLE_POWERSAVE:=1}"
    : "${HA_URL:=http://homeassistant.local:8123/lovelace/0}"
    : "${TIMEZONE:=}"
    : "${ONSCREEN_KEYBOARD:=1}" "${OSK_FLOATING_BUTTON:=0}"
}
on() { [ "${!1:-0}" = "1" ]; }
onoff() { on "$1" && echo on || echo off; }

# ─── Health report ────────────────────────────────────────────────────────────
check() {
    echo "── Features ──"
    echo "  bt-proxy: $(onoff ENABLE_BT_PROXY)   wifi: $(onoff ENABLE_WIFI)   kiosk: $(onoff ENABLE_KIOSK)   jvc: $(onoff ENABLE_JVC_TOOLS)"
    echo "── Hardware ──"
    lsusb 2>/dev/null | grep -Ei '2357:0604|148f:5572|0bda|touch|hid' | sed 's/^/  /' || echo "  (lsusb shows none of the expected devices)"
    if on ENABLE_BT_PROXY || on ENABLE_JVC_TOOLS; then
        echo "  UB500 (2357:0604):  $(lsusb 2>/dev/null | grep -qi 2357:0604 && echo found || echo MISSING)"
    fi
    if on ENABLE_WIFI; then
        echo "  RT5572 (148f:5572): $(lsusb 2>/dev/null | grep -qi 148f:5572 && echo found || echo MISSING)"
        echo "  RT5572 firmware:    $([ -f /lib/firmware/rt2870.bin ] && echo present || echo 'MISSING (apt install firmware-mediatek)')"
    fi
    if on ENABLE_BT_PROXY || on ENABLE_JVC_TOOLS; then
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
    if on ENABLE_BT_PROXY || on ENABLE_JVC_TOOLS; then
        printf "  %-10s %s\n" bluetooth "$(systemctl is-active bluetooth 2>/dev/null || true)"
    fi
    if on ENABLE_BT_PROXY; then
        printf "  %-10s %s\n" bt-proxy "$(systemctl is-active bt-proxy 2>/dev/null || true)"
        printf "  %-10s %s\n" "port 6053" "$(ss -ltn 2>/dev/null | grep -q ':6053 ' && echo listening || echo 'not listening')"
    fi
    if on ENABLE_KIOSK; then
        printf "  %-10s %s\n" kiosk "$(pgrep -x chromium >/dev/null && echo 'chromium running' || echo 'chromium not running')"
        if on ONSCREEN_KEYBOARD; then
            printf "  %-10s %s\n" keyboard "$(pgrep -f 'bin/onboard' >/dev/null && echo 'onboard running' || echo 'onboard not running')"
            printf "  %-10s %s\n" "a11y bus" "$(pgrep -f at-spi-bus-launcher >/dev/null && echo running || echo 'not running')"
        fi
    fi
    if on ENABLE_JVC_TOOLS; then
        printf "  %-10s %s\n" jvc "$([ -x "$APP_DIR/jvc/jvc-probe.py" ] && echo 'jvc-probe installed' || echo 'jvc-probe missing')"
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
    ask_yn ENABLE_BT_PROXY "Home Assistant Bluetooth proxy (TP-Link UB500)?"
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
        ask_str HA_URL "  Dashboard URL"
        ask_yn ONSCREEN_KEYBOARD "  On-screen keyboard?"
        on ONSCREEN_KEYBOARD && ask_yn OSK_FLOATING_BUTTON "  Floating button to open the keyboard by hand?"
    fi
    ask_yn ENABLE_JVC_TOOLS "JVC KD-SX38MBT car receiver tools (needs the UB500)?"
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
BT_NEEDED=0; { on ENABLE_BT_PROXY || on ENABLE_JVC_TOOLS; } && BT_NEEDED=1

exec > >(tee -a "$LOG") 2>&1
say "Install started $(date)  (log: $LOG)"
say "Features: bt-proxy $(onoff ENABLE_BT_PROXY), wifi $(onoff ENABLE_WIFI), kiosk $(onoff ENABLE_KIOSK), jvc $(onoff ENABLE_JVC_TOOLS)"

# Basic sanity: is this an Odroid C2?
if ! grep -qi 'odroid-c2\|odroid c2\|meson-gxbb' /proc/device-tree/model /proc/device-tree/compatible 2>/dev/null; then
    warn "This doesn't look like an Odroid C2 ($(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)). Continuing anyway."
fi

# Local time zone: the kiosk clock and the JVC radio's clock (set from this
# board on every connect) both follow it. DietPi only sets it on first boot;
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

# ─── 2. Bluetooth (UB500): for the proxy and/or the JVC tools ────────────────
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

# ─── 6. JVC tools ─────────────────────────────────────────────────────────────
if on ENABLE_JVC_TOOLS; then
    say "Installing JVC probe tool"
    install -d "$APP_DIR/jvc"
    install -m 755 "$SRC_DIR/jvc/jvc-probe.py" "$APP_DIR/jvc/jvc-probe.py"
    install -m 644 "$SRC_DIR/jvc/README.md" "$APP_DIR/jvc/README.md"
else
    rm -rf "$APP_DIR/jvc"
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
if on ENABLE_KIOSK; then
    echo "  - Kiosk login: see README.md \"Home Assistant side\" (trusted_networks for ${IP:-<odroid-ip>})."
fi
cat <<EOF
  - Add or remove parts:  odroid-ha-install --configure
  - Health report:        odroid-ha-check
  - Pull latest + re-apply: odroid-ha-install
EOF

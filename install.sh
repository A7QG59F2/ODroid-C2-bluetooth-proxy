#!/bin/bash
# =============================================================================
#  Odroid C2  →  Home Assistant Bluetooth proxy  +  dashboard kiosk
#  Target: DietPi (Debian) on Odroid C2
#          TP-Link UB500 (RTL8761BU)  ·  TL-WN821N (RT5572)  ·  MAGEX 10.1" touch
#
#  Usage (as root, from a clone of this repo):
#      sudo ./install.sh              # install / update everything
#      sudo ./install.sh --check      # just print a health report
#
#  Safe to re-run: every step is idempotent. Settings: /etc/odroid-ha/odroid-ha.conf
# =============================================================================
set -euo pipefail

REPO_URL="https://github.com/A7QG59F2/ODroid-C2-bluetooth-proxy"
BT_PROXY_REPO="https://github.com/denvera/bt-proxy.git"
CONF_DIR=/etc/odroid-ha
CONF="$CONF_DIR/odroid-ha.conf"
APP_DIR=/opt/odroid-ha
BTP_DIR=/opt/bt-proxy
LOG=/var/log/odroid-ha-install.log

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
say()  { echo "${c_ok}==>${c_off} $*"; }
warn() { echo "${c_warn}[!]${c_off} $*"; }
die()  { echo "${c_err}[x]${c_off} $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo $0"

# ─── Health report ────────────────────────────────────────────────────────────
check() {
    echo "── Hardware ──"
    lsusb 2>/dev/null | grep -Ei '2357:0604|148f:5572|0bda|touch|hid' || echo "  (lsusb shows none of the expected devices)"
    echo "  UB500 (2357:0604):  $(lsusb 2>/dev/null | grep -qi 2357:0604 && echo found || echo MISSING)"
    echo "  RT5572 (148f:5572): $(lsusb 2>/dev/null | grep -qi 148f:5572 && echo found || echo 'not found (ok if using Ethernet)')"
    echo "── Bluetooth ──"
    rfkill list bluetooth 2>/dev/null | sed 's/^/  /' || true
    bluetoothctl show 2>/dev/null | grep -E 'Controller|Powered|Name' | sed 's/^/  /' || echo "  bluetoothctl: no controller"
    dmesg 2>/dev/null | grep -iE 'rtl8761|rtl_bt' | tail -3 | sed 's/^/  /' || true
    echo "── Wi-Fi ──"
    iw dev 2>/dev/null | grep -E 'Interface|channel|ssid' | sed 's/^/  /' || echo "  no wireless interface"
    echo "── Services ──"
    for s in bluetooth bt-proxy; do
        printf "  %-10s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"
    done
    printf "  %-10s %s\n" "port 6053" "$(ss -ltn 2>/dev/null | grep -q ':6053 ' && echo listening || echo 'not listening')"
    printf "  %-10s %s\n" "kiosk" "$(pgrep -x chromium >/dev/null && echo 'chromium running' || echo 'chromium not running')"
    printf "  %-10s %s\n" "keyboard" "$(pgrep -f 'bin/onboard' >/dev/null && echo 'onboard running' || echo 'onboard not running')"
    printf "  %-10s %s\n" "a11y bus" "$(pgrep -f at-spi-bus-launcher >/dev/null && echo running || echo 'not running')"
    echo "── Temperature ──"
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] && echo "  $(( $(cat "$z") / 1000 )) °C"
    done
}
if [ "${1:-}" = "--check" ]; then
    # shellcheck source=/dev/null
    [ -r "$CONF" ] && . "$CONF"
    check; exit 0
fi

# ─── If run standalone (e.g. DietPi first-boot custom script), fetch the repo ─
if [ ! -f "$SRC_DIR/kiosk/kiosk-session.sh" ]; then
    say "Repo files not next to the script, cloning $REPO_URL"
    command -v git >/dev/null || { apt-get update; apt-get install -y git; }
    rm -rf "$APP_DIR/src"
    git clone --depth 1 "$REPO_URL" "$APP_DIR/src"
    exec bash "$APP_DIR/src/install.sh" "$@"
fi

# ─── Config ───────────────────────────────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF" ]; then
    # Allow a pre-made config on the boot partition (handy for unattended installs)
    if [ -f /boot/odroid-ha.conf ]; then
        cp /boot/odroid-ha.conf "$CONF"
        say "Using /boot/odroid-ha.conf"
    else
        cp "$SRC_DIR/config/odroid-ha.conf.example" "$CONF"
        warn "Created $CONF with defaults. Set HA_URL in it, then re-run this script."
    fi
fi
# shellcheck source=/dev/null
. "$CONF"


exec > >(tee -a "$LOG") 2>&1
say "Install started $(date)  (log: $LOG)"

# Basic sanity: is this an Odroid C2?
if ! grep -qi 'odroid-c2\|odroid c2\|meson-gxbb' /proc/device-tree/model /proc/device-tree/compatible 2>/dev/null; then
    warn "This doesn't look like an Odroid C2 ($(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)). Continuing anyway."
fi

export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# ─── 1. Packages ──────────────────────────────────────────────────────────────
say "Installing packages"
apt-get update
# Firmware: Realtek = UB500 (rtl8761bu_fw.bin), misc-nonfree = RT5572 (rt2870.bin)
$APT install firmware-realtek firmware-misc-nonfree || warn "firmware packages failed: check non-free-firmware is enabled in /etc/apt/sources.list"
$APT install bluez rfkill usbutils iw curl git ca-certificates python3

if [ "${ENABLE_KIOSK:-1}" = "1" ]; then
    $APT install --no-install-recommends \
        xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-legacy xinit \
        x11-xserver-utils xinput dbus-x11 chromium fonts-dejavu-core fonts-noto-color-emoji
    if [ "${ONSCREEN_KEYBOARD:-1}" = "1" ]; then
        # Onboard + everything its auto-show needs: the AT-SPI bus, the GTK/ATK
        # bridge Chromium talks through, GObject bindings, and dconf for settings.
        $APT install --no-install-recommends \
            onboard onboard-data at-spi2-core libatk-adaptor gir1.2-atspi-2.0 \
            dconf-cli dconf-gsettings-backend gsettings-desktop-schemas dbus-bin
    fi
fi

# ─── 2. Bluetooth (UB500) ─────────────────────────────────────────────────────
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

# ─── 3. Wi-Fi (RT5572) ────────────────────────────────────────────────────────
if [ "${WIFI_DISABLE_POWERSAVE:-1}" = "1" ]; then
    say "Disabling Wi-Fi power saving (keeps the proxy reachable)"
    cat > /etc/udev/rules.d/70-odroid-ha-wifi-powersave.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set power_save off"
EOF
    for w in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do iw dev "$w" set power_save off 2>/dev/null || true; done
fi
lsusb | grep -qi 148f:5572 && say "RT5572 Wi-Fi found. Join your 5 GHz network with dietpi-config if not already."

# ─── 4. Bluetooth proxy (denvera/bt-proxy, native, no Docker) ────────────────
if [ "${ENABLE_BT_PROXY:-1}" = "1" ]; then
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
    --name "${BT_PROXY_NAME:-odroid-c2-btproxy}" \\
    --friendly-name "${BT_PROXY_FRIENDLY_NAME:-Odroid C2 Bluetooth Proxy}" \\
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

if [ "${ENABLE_KIOSK:-1}" = "1" ]; then
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
    if [ "${ONSCREEN_KEYBOARD:-1}" = "1" ]; then
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
in-use=$(b "${OSK_FLOATING_BUTTON:-1}")

[org/onboard/keyboard]
touch-input='${OSK_TOUCH_INPUT:-none}'
EOF
        dconf update
        # Drop any per-user Onboard settings left by an earlier attempt, so the
        # defaults above win (user-db would otherwise override them).
        KHOME_OSK=$(getent passwd "$KIOSK_USER" | cut -d: -f6)
        rm -f "$KHOME_OSK/.config/dconf/user"
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
    rm -f /etc/systemd/system/getty@tty1.service.d/zz-odroid-ha-kiosk.conf
    systemctl daemon-reload
fi

# ─── 6. JVC tools ─────────────────────────────────────────────────────────────
if [ "${ENABLE_JVC_TOOLS:-1}" = "1" ]; then
    say "Installing JVC probe tool"
    install -d "$APP_DIR/jvc"
    install -m 755 "$SRC_DIR/jvc/jvc-probe.py" "$APP_DIR/jvc/jvc-probe.py"
    install -m 644 "$SRC_DIR/jvc/README.md" "$APP_DIR/jvc/README.md"
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
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
cat <<EOF

Next steps
  1. Home Assistant → Settings → Devices & Services: the ESPHome integration should
     discover "${BT_PROXY_FRIENDLY_NAME:-Odroid C2 Bluetooth Proxy}". If not: Add Integration →
     ESPHome → host ${IP:-<odroid-ip>}, port 6053.
  2. Kiosk login: see README.md "Home Assistant side" (trusted_networks for ${IP:-<odroid-ip>}).
  3. Change settings:  sudo nano $CONF  then  sudo ./install.sh
  4. Health report:     odroid-ha-check
  5. Pull latest repo + re-apply:  sudo odroid-ha-install
EOF

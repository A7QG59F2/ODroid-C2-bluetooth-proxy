#!/bin/bash
# X session for the Home Assistant kiosk. Started by startx from the kiosk
# user's ~/.bash_profile on tty1. Keeps Chromium running forever.
set -u

# Onboard (on-screen keyboard) and Chromium must share one D-Bus session so the
# accessibility (AT-SPI) bus can tell Onboard when a text field gets focus.
# Without a session bus, auto-show silently never fires.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null; then
    exec dbus-run-session -- "$0" "$@"
fi

CONF=/etc/odroid-ha/odroid-ha.conf
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
ONSCREEN_KEYBOARD="${ONSCREEN_KEYBOARD:-1}"

HA_URL="${HA_URL:-http://homeassistant.local:8123}"
SCREEN_ROTATION="${SCREEN_ROTATION:-normal}"
SCREEN_MODE="${SCREEN_MODE:-}"
SCREEN_ALWAYS_ON="${SCREEN_ALWAYS_ON:-1}"
SCREEN_BLANK_SECONDS="${SCREEN_BLANK_SECONDS:-600}"
CHROMIUM_ZOOM="${CHROMIUM_ZOOM:-1.0}"
CHROMIUM_EXTRA_FLAGS="${CHROMIUM_EXTRA_FLAGS:-}"

log() { echo "[kiosk] $*"; logger -t ha-kiosk "$*" 2>/dev/null || true; }

# ── Display output, mode, rotation ──────────────────────────────────────────
OUTPUT=$(xrandr --query 2>/dev/null | awk '/ connected/{print $1; exit}')
if [ -n "$OUTPUT" ]; then
    if [ -n "$SCREEN_MODE" ]; then
        xrandr --output "$OUTPUT" --mode "$SCREEN_MODE" || log "mode $SCREEN_MODE not available on $OUTPUT"
    fi
    xrandr --output "$OUTPUT" --rotate "$SCREEN_ROTATION" || log "rotation $SCREEN_ROTATION failed"
fi

# There's no window manager to maximise Chromium, so --kiosk alone leaves it
# at its default window size (about half the screen). Give it the real
# screen size, read after rotation.
SCREEN_WH=$(xrandr --query 2>/dev/null | awk '/^Screen 0:/{for(i=1;i<=NF;i++) if($i=="current"){w=$(i+1); h=$(i+3); sub(",","",h); print w "," h; exit}}')
SCREEN_WH="${SCREEN_WH:-1920,1200}"

# Rotate touch input to match the screen
case "$SCREEN_ROTATION" in
    left)     MATRIX="0 -1 1 1 0 0 0 0 1" ;;
    right)    MATRIX="0 1 0 -1 0 1 0 0 1" ;;
    inverted) MATRIX="-1 0 1 0 -1 1 0 0 1" ;;
    *)        MATRIX="1 0 0 0 1 0 0 0 1" ;;
esac
if command -v xinput >/dev/null; then
    # Every pointer device (touch panel included) gets the same matrix
    xinput list --id-only 2>/dev/null | while read -r id; do
        if xinput list-props "$id" 2>/dev/null | grep -q "Coordinate Transformation Matrix"; then
            # shellcheck disable=SC2086
            xinput set-prop "$id" "Coordinate Transformation Matrix" $MATRIX 2>/dev/null || true
        fi
    done
fi

# ── Screen blanking ─────────────────────────────────────────────────────────
if [ "$SCREEN_ALWAYS_ON" = "1" ]; then
    xset s off; xset s noblank; xset -dpms
else
    xset s "$SCREEN_BLANK_SECONDS" "$SCREEN_BLANK_SECONDS"; xset +dpms
    xset dpms "$SCREEN_BLANK_SECONDS" "$SCREEN_BLANK_SECONDS" "$SCREEN_BLANK_SECONDS"
fi

# ── Wait (max ~2 min) for Home Assistant so we don't show an error page ────
for _ in $(seq 1 60); do
    curl -fsS -m 3 -o /dev/null "$HA_URL" && break
    sleep 2
done

# ── On-screen keyboard (Onboard) ────────────────────────────────────────────
A11Y_FLAGS=""
if [ "$ONSCREEN_KEYBOARD" = "1" ] && command -v onboard >/dev/null; then
    # Turn on the accessibility stack for this session
    export ACCESSIBILITY_ENABLED=1 NO_AT_BRIDGE=0 GTK_MODULES="${GTK_MODULES:+$GTK_MODULES:}gail:atk-bridge"
    gsettings set org.gnome.desktop.interface toolkit-accessibility true 2>/dev/null || true
    for l in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
        [ -x "$l" ] && { "$l" --launch-immediately & break; }
    done
    sleep 1
    # Keep Onboard alive. Its settings come from /etc/dconf/db/odroidha.d (install.sh).
    (
        while true; do
            onboard >>"$HOME/.onboard.log" 2>&1
            log "onboard exited ($?), restarting in 3s"
            sleep 3
        done
    ) &
    # Chromium only exposes text fields to AT-SPI when told to
    A11Y_FLAGS="--force-renderer-accessibility"
    log "on-screen keyboard enabled"
fi

# ── Chromium, restarted if it ever exits or crashes ─────────────────────────
PROFILE="$HOME/.config/chromium-kiosk"
mkdir -p "$PROFILE"
while true; do
    # Clear "Chromium didn't shut down correctly" bubble after a power cut
    PREFS="$PROFILE/Default/Preferences"
    if [ -f "$PREFS" ]; then
        sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"Crashed"/"exit_type":"Normal"/' "$PREFS"
    fi
    log "starting chromium -> $HA_URL"
    # shellcheck disable=SC2086
    chromium \
        --kiosk "$HA_URL" \
        --start-fullscreen \
        --window-position=0,0 \
        --window-size="$SCREEN_WH" \
        --user-data-dir="$PROFILE" \
        --no-first-run \
        --noerrdialogs \
        --disable-infobars \
        --disable-session-crashed-bubble \
        --disable-features=TranslateUI,Translate \
        --check-for-update-interval=31536000 \
        --overscroll-history-navigation=0 \
        --disable-pinch \
        --password-store=basic \
        --force-device-scale-factor="$CHROMIUM_ZOOM" \
        --touch-events=enabled \
        $A11Y_FLAGS \
        $CHROMIUM_EXTRA_FLAGS
    log "chromium exited ($?), restarting in 5s"
    sleep 5
done

#!/bin/bash
# Keep the JVC radio's Bluetooth audio (A2DP) connected, so the Music Assistant
# player (Squeezelite → BlueALSA) always has somewhere to play. When the radio
# is off or out of range the connect attempt just fails, and we try again later.
# Run by odroid-ha-radio-link.service; settings come from the odroid-ha config.
set -u
CONF=/etc/odroid-ha/odroid-ha.conf
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
MAC=${JVC_MAC:-}
INTERVAL=${RADIO_RECONNECT_SECONDS:-15}
[ -n "$MAC" ] || { echo "JVC_MAC is not set in $CONF" >&2; exit 1; }

A2DP_SINK=0000110b-0000-1000-8000-00805f9b34fb
DEV_PATH=/org/bluez/hci0/dev_${MAC//:/_}

a2dp_up() {   # BlueALSA has a playback PCM for the radio
    bluealsa-aplay -L 2>/dev/null | grep -qi "DEV=$MAC,PROFILE=a2dp"
}

last=""
while true; do
    if a2dp_up; then
        state=connected
    else
        # Connect just the audio profile; works whether or not the control
        # (SPP) link is already up. Fails after a few seconds if the radio is off.
        timeout 20 dbus-send --system --print-reply --dest=org.bluez "$DEV_PATH" \
            org.bluez.Device1.ConnectProfile "string:$A2DP_SINK" >/dev/null 2>&1 || true
        sleep 2
        a2dp_up && state=connected || state=unreachable
    fi
    if [ "$state" != "$last" ]; then
        echo "radio $MAC audio: $state"
        last=$state
    fi
    sleep "$INTERVAL"
done

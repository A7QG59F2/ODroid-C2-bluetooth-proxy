#!/usr/bin/env python3
"""avrcp-player.py: tell the JVC radio what Music Assistant is playing.

The radio plays our Bluetooth audio (A2DP) but only shows play state and track
info, and only sends its play/pause/next buttons somewhere, when the source also
offers an AVRCP media player. This registers one with BlueZ (an MPRIS-style
player, the same thing BlueZ's mpris-proxy does for desktop players):

  Home Assistant media_player (Music Assistant's player for the radio)
      → polled over the REST API → PlaybackStatus / Metadata / Position → radio
  radio buttons → BlueZ → Play/Pause/Next/Previous here → HA media_player services

Settings come from /etc/odroid-ha/odroid-ha.conf (HA_API_URL, RADIO_HA_ENTITY);
the Home Assistant long-lived token from /etc/odroid-ha/ha-token.
Run by odroid-ha-radio-avrcp.service.
"""
import datetime
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import dbus
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

CONF = "/etc/odroid-ha/odroid-ha.conf"
TOKEN_FILE = "/etc/odroid-ha/ha-token"
PLAYER_PATH = "/org/odroidha/radio/player"
MPRIS = "org.mpris.MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
POLL_SECONDS = 2


def log(msg):
    print(msg, flush=True)


def read_conf():
    conf = {}
    try:
        with open(CONF) as f:
            for line in f:
                m = re.match(r'\s*([A-Z_][A-Z0-9_]*)="(.*)"\s*$', line)
                if m:
                    conf[m.group(1)] = re.sub(r'\\(.)', r'\1', m.group(2))
    except OSError:
        pass
    return conf


def ha_base_url(conf):
    """HA_API_URL, else scheme://host:port taken from the kiosk's HA_URL."""
    if conf.get("HA_API_URL"):
        return conf["HA_API_URL"].rstrip("/")
    u = urllib.parse.urlsplit(conf.get("HA_URL", ""))
    return f"{u.scheme}://{u.netloc}" if u.scheme and u.netloc else ""


class HomeAssistant:
    def __init__(self, base, token, entity):
        self.base, self.token, self.entity = base, token, entity

    def _req(self, method, path, body=None):
        req = urllib.request.Request(
            self.base + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read() or b"null")

    def state(self):
        return self._req("GET", f"/api/states/{self.entity}")

    def call(self, service):
        self._req("POST", f"/api/services/media_player/{service}", {"entity_id": self.entity})


def to_status(state):
    return {"playing": "Playing", "paused": "Paused"}.get(state, "Stopped")


def position_us(attrs, playing):
    pos = attrs.get("media_position")
    if pos is None:
        return 0
    pos = float(pos)
    if playing and attrs.get("media_position_updated_at"):
        try:
            t = datetime.datetime.fromisoformat(attrs["media_position_updated_at"])
            pos += (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
        except ValueError:
            pass
    return int(max(pos, 0) * 1_000_000)


class Player(dbus.service.Object):
    def __init__(self, bus, ha):
        super().__init__(bus, PLAYER_PATH)
        self.ha = ha
        self.props = {
            "PlaybackStatus": dbus.String("Stopped"),
            "LoopStatus": dbus.String("None"),
            "Rate": dbus.Double(1.0),
            "Shuffle": dbus.Boolean(False),
            "Metadata": dbus.Dictionary({}, signature="sv"),
            "Position": dbus.Int64(0),
            "MinimumRate": dbus.Double(1.0),
            "MaximumRate": dbus.Double(1.0),
            "CanGoNext": dbus.Boolean(True),
            "CanGoPrevious": dbus.Boolean(True),
            "CanPlay": dbus.Boolean(True),
            "CanPause": dbus.Boolean(True),
            "CanSeek": dbus.Boolean(False),
            "CanControl": dbus.Boolean(True),
        }
        self.track = None
        self.error = None

    def _error(self, msg):   # log each problem once, not every poll
        if msg != self.error:
            log(msg)
            self.error = msg

    # ── radio buttons (BlueZ calls these) ───────────────────────────────────
    def _do(self, service):
        log(f"radio button → {service}")
        try:
            self.ha.call(service)
        except (urllib.error.URLError, OSError, ValueError) as e:
            log(f"Home Assistant call {service} failed: {e}")
        GLib.timeout_add(500, self.refresh)

    @dbus.service.method(PLAYER_IFACE)
    def Play(self):
        self._do("media_play")

    @dbus.service.method(PLAYER_IFACE)
    def Pause(self):
        self._do("media_pause")

    @dbus.service.method(PLAYER_IFACE)
    def PlayPause(self):
        self._do("media_play_pause")

    @dbus.service.method(PLAYER_IFACE)
    def Stop(self):
        self._do("media_stop")

    @dbus.service.method(PLAYER_IFACE)
    def Next(self):
        self._do("media_next_track")

    @dbus.service.method(PLAYER_IFACE)
    def Previous(self):
        self._do("media_previous_track")

    @dbus.service.method(PLAYER_IFACE, in_signature="x")
    def Seek(self, offset):
        pass

    # ── properties ──────────────────────────────────────────────────────────
    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, iface, name):
        if iface == MPRIS:
            return {"Identity": "Music Assistant", "CanQuit": False, "CanRaise": False}.get(name, "")
        return self.props[name]

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        if iface == MPRIS:
            return {"Identity": "Music Assistant", "CanQuit": False, "CanRaise": False,
                    "HasTrackList": False, "SupportedUriSchemes": dbus.Array([], signature="s"),
                    "SupportedMimeTypes": dbus.Array([], signature="s")}
        return self.props

    @dbus.service.method(PROPS_IFACE, in_signature="ssv")
    def Set(self, iface, name, value):
        pass  # the radio can't change shuffle/loop on Music Assistant from here

    @dbus.service.signal(PROPS_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated):
        pass

    # ── Home Assistant → radio ──────────────────────────────────────────────
    def refresh(self):
        try:
            st = self.ha.state()
        except urllib.error.HTTPError as e:
            self._error(f"Home Assistant: HTTP {e.code} for {self.ha.entity}"
                        + (" (check the token)" if e.code == 401 else ""))
            return False
        except (urllib.error.URLError, OSError, ValueError) as e:
            self._error(f"Home Assistant unreachable: {e}")
            return False
        if self.error:
            log("Home Assistant OK again")
            self.error = None
        a = st.get("attributes", {}) if isinstance(st, dict) else {}
        status = to_status(st.get("state") if isinstance(st, dict) else None)
        meta = {}
        if a.get("media_title"):
            meta["xesam:title"] = dbus.String(a["media_title"])
        if a.get("media_artist"):
            meta["xesam:artist"] = dbus.Array([a["media_artist"]], signature="s")
        if a.get("media_album_name"):
            meta["xesam:album"] = dbus.String(a["media_album_name"])
        if a.get("media_duration"):
            meta["mpris:length"] = dbus.Int64(int(float(a["media_duration"]) * 1_000_000))
        meta["mpris:trackid"] = dbus.ObjectPath(f"{PLAYER_PATH}/track/{abs(hash(a.get('media_title', ''))) % 10**9}")
        new = {
            "PlaybackStatus": dbus.String(status),
            "Metadata": dbus.Dictionary(meta, signature="sv"),
            "Position": dbus.Int64(position_us(a, status == "Playing")),
        }
        changed = {k: v for k, v in new.items()
                   if k != "Position" and self.props.get(k) != v}
        if changed:   # BlueZ restarts its position clock from this
            changed["Position"] = new["Position"]
        self.props.update(new)
        if changed:
            self.PropertiesChanged(PLAYER_IFACE, changed, dbus.Array([], signature="s"))
            track = (a.get("media_artist"), a.get("media_title"))
            if "PlaybackStatus" in changed or track != self.track:
                log(f"{status}: {a.get('media_artist') or '-'} – {a.get('media_title') or '-'}")
                self.track = track
        return False


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    conf = read_conf()
    base = ha_base_url(conf)
    entity = conf.get("RADIO_HA_ENTITY") or (
        "media_player." + re.sub(r"[^a-z0-9]+", "_", conf.get("RADIO_AUDIO_NAME", "Car-Radio").lower()).strip("_"))
    try:
        token = open(TOKEN_FILE).read().strip()
    except OSError:
        token = ""
    if not base or not token:
        sys.exit(f"Need HA_API_URL (or HA_URL) and a token in {TOKEN_FILE}")
    log(f"Following {entity} on {base}")

    bus = dbus.SystemBus()
    player = Player(bus, HomeAssistant(base, token, entity))
    registered = {"ok": False}

    def register():
        try:
            media = dbus.Interface(bus.get_object("org.bluez", "/org/bluez/hci0"), "org.bluez.Media1")
            media.RegisterPlayer(dbus.ObjectPath(PLAYER_PATH), player.props)
            registered["ok"] = True
            log("Registered with BlueZ as the radio's media player")
        except dbus.DBusException as e:
            if "AlreadyExists" in e.get_dbus_name():
                registered["ok"] = True
            else:
                log(f"BlueZ RegisterPlayer failed ({e.get_dbus_name()}); retrying")
        return not registered["ok"]   # keep the retry timer going until it works

    def bluez_owner_changed(new_owner):
        # bluetoothd restarted: our registration is gone, do it again
        registered["ok"] = False
        if new_owner:
            GLib.timeout_add_seconds(2, register)

    bus.watch_name_owner("org.bluez", bluez_owner_changed)

    def tick():
        player.refresh()
        return True

    GLib.timeout_add_seconds(5, register)
    GLib.timeout_add_seconds(POLL_SECONDS, tick)
    tick()
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()

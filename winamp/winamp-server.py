#!/usr/bin/env python3
"""winamp-server.py: Webamp (Winamp 2 in the browser) as a remote for Music Assistant.

The kiosk's Chromium shows Webamp from this server. Webamp makes no sound
itself; every button, the playlist, the volume and the equalizer act on one
Music Assistant player (by default jvc2mqtt's radio player, Car-Radio), and
Music Assistant's state is mirrored back into the Winamp windows:

  browser (www/app.js) ⇄ /ws ⇄ this server ⇄ Music Assistant WebSocket API
                                   ↑
  Squeezelite -v (shared memory /dev/shm/squeezelite-<mac>) → visualizer samples

The Music Assistant token stays here (never sent to the browser), and the
browser can only run the handful of commands below, on that one player.

Settings: /etc/odroid-ha/odroid-ha.conf (WINAMP_*, MA_URL, HA_URL). Token: $CREDENTIALS_DIRECTORY/ma-token (systemd) or
/etc/odroid-ha/ma-token. Run by odroid-ha-winamp.service.
"""
import asyncio
import glob
import json
import mmap
import os
import re
import struct
import sys
import time
import urllib.parse
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web

CONF = "/etc/odroid-ha/odroid-ha.conf"
TOKEN_FILE = "/etc/odroid-ha/ma-token"
HERE = Path(__file__).resolve().parent
WWW = HERE / "www"
SKIN_DIRS = [HERE / "skins", Path("/etc/odroid-ha/winamp-skins")]
MAX_QUEUE_ITEMS = 1000

# Winamp's ten equalizer bands (Hz). The first and last are shelves, as in Winamp.
EQ_FREQS = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
EQ_DB = 12.0          # slider ends = ±12 dB
EQ_Q = 1.4


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


def ma_base_url(conf):
    """MA_URL, else port 8095 on HA_URL's host (MA as a Home Assistant add-on)."""
    if conf.get("MA_URL"):
        return conf["MA_URL"].rstrip("/")
    host = urllib.parse.urlsplit(conf.get("HA_URL", "")).hostname or ""
    return f"http://{host}:8095" if host else ""


def read_token():
    cred = os.environ.get("CREDENTIALS_DIRECTORY")
    for path in ([os.path.join(cred, "ma-token")] if cred else []) + [TOKEN_FILE]:
        try:
            tok = open(path).read().strip()
            if tok:
                return tok
        except OSError:
            pass
    return ""


# ─── Equalizer: Winamp sliders (0..100, 50 = flat) ⇄ Music Assistant DSP ─────
def slider_to_db(v):
    return round((float(v) - 50) * EQ_DB / 50, 1)


def db_to_slider(db):
    return max(0, min(100, round(50 + float(db) * 50 / EQ_DB)))


def eq_filter(on, preamp, bands):
    return {
        "type": "parametric_eq",
        "enabled": bool(on),
        "preamp": slider_to_db(preamp),
        "per_channel_preamp": {},
        "bands": [{
            "frequency": f,
            "q": EQ_Q if 0 < i < len(EQ_FREQS) - 1 else 0.7,
            "gain": slider_to_db(v),
            "type": "low_shelf" if i == 0 else "high_shelf" if i == len(EQ_FREQS) - 1 else "peak",
            "enabled": True,
            "channel": "ALL",
        } for i, (f, v) in enumerate(zip(EQ_FREQS, bands))],
    }


def find_eq(dsp):
    """Our filter is the parametric EQ whose bands sit on Winamp's frequencies."""
    for i, f in enumerate((dsp or {}).get("filters") or []):
        if f.get("type") == "parametric_eq" and \
                [round(b.get("frequency", 0)) for b in f.get("bands", [])] == EQ_FREQS:
            return i, f
    return None, None


def find_type(dsp, kind):
    """Balance and mono are MA's balance and stereo_width filters (the first of each)."""
    for i, f in enumerate((dsp or {}).get("filters") or []):
        if f.get("type") == kind:
            return i, f
    return None, None


def eq_from_dsp(dsp):
    """Winamp's sound settings as MA's DSP has them: EQ, balance, mono."""
    on = bool((dsp or {}).get("enabled"))
    _, bal = find_type(dsp, "balance")
    _, width = find_type(dsp, "stereo_width")
    out = {
        "balance": round(float(bal.get("balance") or 0)) if bal and bal.get("enabled") and on else 0,
        "mono": bool(width and width.get("enabled") and on and float(width.get("width", 1)) == 0),
    }
    _, f = find_eq(dsp)
    if not f:
        return {"on": False, "preamp": 50, "bands": [50] * len(EQ_FREQS), **out}
    return {
        "on": bool(f.get("enabled")) and on,
        "preamp": db_to_slider(f.get("preamp") or 0),
        "bands": [db_to_slider(b.get("gain", 0)) for b in f["bands"]],
        **out,
    }


# ─── Slim versions of Music Assistant objects for the browser ────────────────
TAGGED = re.compile(r'(?:^|\s)text="([^"]*)"')


def clean_title(title):
    """Radio streams (iHeart and others) put a raw tag line in the title, e.g.
    'Def Leppard - text="Photograph" song_spot="M" ...' → 'Def Leppard - Photograph'
    (same cleanup as radio/avrcp-player.py)."""
    m = TAGGED.search(title or "")
    if not m:
        return title
    prefix = title[:m.start()].strip().rstrip("-").strip()
    return f"{prefix} - {m.group(1).strip()}" if prefix else m.group(1).strip() or title


def slim_item(it):
    if not it:
        return None
    mi = it.get("media_item") or {}
    artists = [a.get("name") for a in mi.get("artists") or [] if a.get("name")]
    sd = it.get("streamdetails") or {}
    fmt = sd.get("audio_format") or {}
    live = sd.get("stream_metadata") or {}       # what a radio station is playing now
    title = clean_title(live.get("title")) if live.get("title") else mi.get("name")
    artist = live.get("artist") if live.get("title") else ", ".join(artists) or None
    return {
        "id": it.get("queue_item_id"),
        "name": clean_title(it.get("name") or mi.get("name") or ""),
        "title": title,
        "artist": artist,
        "album": (mi.get("album") or {}).get("name"),
        "duration": it.get("duration") or 0,
        "rate": fmt.get("sample_rate"),
        "bitrate": fmt.get("bit_rate"),
        "channels": fmt.get("channels"),
        "uri": mi.get("uri"),
    }


# ─── Visualizer: Squeezelite's shared-memory audio export (squeezelite -v) ───
class VisReader:
    """Reads struct vis_t from squeezelite's output_vis.c:
         pthread_rwlock_t rwlock; u32 buf_size; u32 buf_index; bool running;
         u32 rate; time_t updated; s16 buffer[16384]  (interleaved stereo)
    The lock's size depends on the platform, so find buf_size (16384) instead
    of assuming an offset. Reads without the lock: a torn read only means one
    slightly wrong visualizer frame."""
    BUF = 16384

    def __init__(self):
        self.mm = None
        self.path = None
        self.off = None
        self.last = None

    def _open(self):
        paths = sorted(glob.glob("/dev/shm/squeezelite-*"))
        if not paths:
            return False
        try:
            fd = os.open(paths[0], os.O_RDONLY)
            try:
                mm = mmap.mmap(fd, 0, access=mmap.ACCESS_READ)
            finally:
                os.close(fd)
        except (OSError, ValueError):
            return False
        for off in range(24, 72, 4):
            if struct.unpack_from("<I", mm, off)[0] == self.BUF:
                self.mm, self.path, self.off, self.last = mm, paths[0], off, None
                log(f"Visualizer: reading {self.path}")
                return True
        mm.close()
        return False

    def read(self):
        """New mono samples (bytes of little-endian int16) since the last call,
        and the sample rate. Empty when stopped or not available."""
        if self.mm is None and not self._open():
            return b"", 0
        o = self.off
        index, running = struct.unpack_from("<I?", self.mm, o + 4)
        rate = struct.unpack_from("<I", self.mm, o + 12)[0]
        # time_t sits on an 8-byte boundary after rate, then the buffer
        upd_off = (o + 16 + 7) & ~7
        buf_off = upd_off + 8
        if not running or index >= self.BUF:
            self.last = index
            return b"", rate
        last = self.last if self.last is not None else (index - 2048) % self.BUF
        self.last = index
        n = (index - last) % self.BUF
        if n == 0:
            return b"", rate
        n = min(n, self.BUF // 2)
        start = (index - n) % self.BUF
        raw = self.mm[buf_off + start * 2: buf_off + min(start + n, self.BUF) * 2]
        if start + n > self.BUF:
            raw += self.mm[buf_off: buf_off + (start + n - self.BUF) * 2]
        st = memoryview(raw).cast("h")
        mono = [(st[i] + st[i + 1]) >> 1 for i in range(0, len(st) - 1, 2)]
        return struct.pack(f"<{len(mono)}h", *mono), rate


# ─── Music Assistant connection ─────────────────────────────────────────────
class MusicAssistant:
    def __init__(self, base, token, player_want, broadcast):
        self.base, self.token, self.player_want = base, token, player_want
        self.broadcast = broadcast
        self.ws = None
        self.msg_id = 0
        self.pending = {}
        self.player = None
        self.queue = None
        self.items = []
        self.eq = None
        self.connected = False
        self.error = None
        self._items_task = None
        self._eq_task = None
        self._sound_wanted = None

    # ── low level ───────────────────────────────────────────────────────────
    async def call(self, command, **args):
        if not self.ws or self.ws.closed:
            raise ConnectionError("Music Assistant not connected")
        self.msg_id += 1
        mid = str(self.msg_id)
        fut = asyncio.get_running_loop().create_future()
        self.pending[mid] = fut
        try:
            await self.ws.send_json({"message_id": mid, "command": command, "args": args})
            msg = await asyncio.wait_for(fut, 15)
        finally:
            self.pending.pop(mid, None)
        if "error_code" in msg:
            raise RuntimeError(f"{command}: {msg.get('details') or msg.get('error_code')}")
        return msg.get("result")

    def _set_error(self, msg):
        if msg != self.error:
            log(msg)
            self.error = msg
            self.broadcast({"type": "status", "connected": False, "error": msg})

    async def run(self):
        url = self.base.replace("http", "ws", 1) + "/ws"
        async with ClientSession(timeout=ClientTimeout(total=None, sock_connect=10)) as s:
            while True:
                try:
                    async with s.ws_connect(url, heartbeat=30, max_msg_size=0) as ws:
                        await self._session(ws)
                except asyncio.CancelledError:
                    raise
                except Exception as e:  # noqa: BLE001 - keep reconnecting whatever happens
                    self._set_error(f"Music Assistant: {type(e).__name__}: {e}")
                self.ws = None
                self.connected = False
                for fut in self.pending.values():
                    if not fut.done():
                        fut.set_exception(ConnectionError("connection lost"))
                await asyncio.sleep(10)

    async def _session(self, ws):
        self.ws = ws
        await ws.receive_json(timeout=10)          # server info comes first
        reader = asyncio.create_task(self._reader(ws))
        try:
            res = await self.call("auth", token=self.token)
            if not (res or {}).get("authenticated"):
                raise RuntimeError("token not accepted (make a new one in Music Assistant)")
            while not await self._find_player():
                self._set_error(f"Music Assistant player '{self.player_want}' not found (yet)")
                await asyncio.sleep(15)
            self.connected = True
            if self.error:
                log("Music Assistant OK")
            self.error = None
            log(f"Following player {self.player['name']} ({self.player['player_id']})")
            await self._refresh_all()
            await reader
        finally:
            reader.cancel()

    async def _reader(self, ws):
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            data = json.loads(msg.data)
            mid = data.get("message_id")
            if mid is not None and mid in self.pending:
                if not self.pending[mid].done():
                    self.pending[mid].set_result(data)
            elif "event" in data:
                try:
                    await self._event(data)
                except Exception as e:  # noqa: BLE001
                    log(f"event {data.get('event')}: {e}")

    # ── player / queue state ────────────────────────────────────────────────
    async def _find_player(self):
        want = self.player_want.lower()
        for p in await self.call("players/all") or []:
            if p.get("player_id", "").lower() == want or p.get("name", "").lower() == want:
                self.player = p
                return True
        return False

    @property
    def pid(self):
        return self.player["player_id"]

    @property
    def qid(self):
        return (self.queue or {}).get("queue_id") or self.pid

    async def _refresh_all(self):
        try:
            q = await self.call("player_queues/get_active_queue", player_id=self.pid)
        except RuntimeError:
            q = None
        self.queue = q or await self.call("player_queues/get", queue_id=self.pid)
        await self._load_items()
        try:
            self.eq = eq_from_dsp(await self.call("config/players/dsp/get", player_id=self.pid))
        except RuntimeError as e:
            log(f"EQ: {e}")
            self.eq = None
        self.broadcast(self.snapshot())

    async def _load_items(self):
        items = []
        while len(items) < MAX_QUEUE_ITEMS:
            page = await self.call("player_queues/items", queue_id=self.qid, limit=200, offset=len(items))
            if not page:
                break
            items += [slim_item(i) for i in page]
            if len(page) < 200:
                break
        self.items = items

    def _schedule_items(self):
        async def later():
            await asyncio.sleep(0.4)
            await self._load_items()
            self.broadcast({"type": "items", "items": self.items, "queue": self.queue_state()})
        if self._items_task and not self._items_task.done():
            self._items_task.cancel()
        self._items_task = asyncio.create_task(later())

    def queue_state(self):
        q = self.queue or {}
        playing = q.get("state") == "playing"
        elapsed = float(q.get("elapsed_time") or 0)
        if playing and q.get("elapsed_time_last_updated"):
            elapsed += max(0.0, time.time() - float(q["elapsed_time_last_updated"]))
        return {
            "state": q.get("state") or "idle",
            "shuffle": bool(q.get("shuffle_enabled")),
            "repeat": q.get("repeat_mode") or "off",
            "current": slim_item(q.get("current_item")),
            "elapsed": elapsed,
        }

    def player_state(self):
        p = self.player or {}
        return {"name": p.get("name"), "available": p.get("available", False),
                "volume": p.get("volume_level"), "muted": p.get("volume_muted")}

    def snapshot(self):
        return {"type": "snapshot", "connected": self.connected, "error": self.error,
                "player": self.player_state(), "queue": self.queue_state(),
                "items": self.items, "eq": self.eq}

    async def _event(self, ev):
        name, obj, data = ev.get("event"), ev.get("object_id"), ev.get("data")
        if not self.player:
            return
        if name == "player_updated" and obj == self.pid and isinstance(data, dict):
            self.player = data
            self.broadcast({"type": "player", "player": self.player_state()})
        elif name == "queue_updated" and obj == self.qid and isinstance(data, dict):
            old = self.queue or {}
            self.queue = data
            self.broadcast({"type": "queue", "queue": self.queue_state()})
            if data.get("items") != old.get("items") or \
                    data.get("shuffle_enabled") != old.get("shuffle_enabled"):
                self._schedule_items()
        elif name == "queue_items_updated" and obj == self.qid:
            self._schedule_items()
        elif name == "queue_time_updated" and obj == self.qid and self.queue is not None:
            self.queue["elapsed_time"] = data
            self.queue["elapsed_time_last_updated"] = time.time()
            self.broadcast({"type": "time", "elapsed": float(data or 0)})
        elif name == "player_config_updated" and obj == self.pid:
            try:
                self.eq = eq_from_dsp(await self.call("config/players/dsp/get", player_id=self.pid))
                self.broadcast({"type": "eq", "eq": self.eq})
            except RuntimeError:
                pass

    # ── equalizer, balance, mono (MA's per-player DSP) ─────────────────────
    def set_sound(self, **changes):
        """Debounced: dragging a slider sends many values, MA gets the last.
        changes: eq=(on, preamp, bands), balance=-100..100, mono=bool."""
        self._sound_wanted = {**(self._sound_wanted or {}), **changes}
        if self._eq_task and not self._eq_task.done():
            return

        async def later():
            await asyncio.sleep(0.5)
            while self._sound_wanted:
                want, self._sound_wanted = self._sound_wanted, None
                dsp = await self.call("config/players/dsp/get", player_id=self.pid) or {}
                filters = list(dsp.get("filters") or [])
                ours = set()

                def put(i, new):
                    if i is None:
                        filters.append(new)
                        i = len(filters) - 1
                    else:
                        filters[i] = new
                    ours.add(i)
                if "eq" in want:
                    on, preamp, bands = want["eq"]
                    put(find_eq({"filters": filters})[0], eq_filter(on, preamp, bands))
                if "balance" in want:
                    bal = max(-100.0, min(100.0, float(want["balance"])))
                    i, f = find_type({"filters": filters}, "balance")
                    if f or bal:
                        put(i, {**(f or {}), "type": "balance", "enabled": bal != 0, "balance": bal})
                if "mono" in want:
                    mono = bool(want["mono"])
                    i, f = find_type({"filters": filters}, "stereo_width")
                    if f or mono:
                        put(i, {**(f or {}), "type": "stereo_width", "enabled": mono,
                                "width": 0.0 if mono else 1.0})
                # DSP as a whole: on for any of ours that is on, and for any other
                # enabled filter the user set up in MA (if they had DSP on)
                mine = any(filters[i].get("enabled") for i in ours)
                others = bool(dsp.get("enabled")) and any(
                    f.get("enabled") for j, f in enumerate(filters) if j not in ours)
                dsp.update(filters=filters, enabled=mine or others, preset_id=None)
                await self.call("config/players/dsp/save", player_id=self.pid, config=dsp)
                self.eq = eq_from_dsp(dsp)
        self._eq_task = asyncio.create_task(later())

    # ── commands the browser may send ───────────────────────────────────────
    async def command(self, cmd, a):
        q, p = self.qid, self.pid
        simple = {"play": "play", "pause": "pause", "play_pause": "play_pause",
                  "stop": "stop", "next": "next", "previous": "previous", "clear": "clear"}
        if cmd in simple:
            return await self.call(f"player_queues/{simple[cmd]}", queue_id=q)
        if cmd == "play_index":
            return await self.call("player_queues/play_index", queue_id=q, index=str(a["item"]))
        if cmd == "seek":
            return await self.call("player_queues/seek", queue_id=q, position=int(a["position"]))
        if cmd == "shuffle":
            return await self.call("player_queues/shuffle", queue_id=q, shuffle_enabled=bool(a["enabled"]))
        if cmd == "repeat":
            mode = a.get("mode")
            if mode not in ("off", "one", "all"):
                raise ValueError("bad repeat mode")
            return await self.call("player_queues/repeat", queue_id=q, repeat_mode=mode)
        if cmd == "volume":
            return await self.call("players/cmd/volume_set", player_id=p,
                                   volume_level=max(0, min(100, int(a["level"]))))
        if cmd == "delete":
            for item in a["items"]:
                await self.call("player_queues/delete_item", queue_id=q, item_id_or_index=str(item))
            return None
        if cmd == "move":
            shift = int(a["shift"])
            if shift:
                for item in a["items"]:
                    await self.call("player_queues/move_item", queue_id=q,
                                    queue_item_id=str(item), pos_shift=shift)
            return None
        if cmd == "eq":
            self.set_sound(eq=(bool(a["on"]), float(a["preamp"]),
                               [float(b) for b in a["bands"]][:len(EQ_FREQS)]))
            return None
        if cmd == "balance":
            self.set_sound(balance=float(a["balance"]))
            return None
        if cmd == "mono":
            self.set_sound(mono=bool(a["mono"]))
            return None
        if cmd == "playlists":    # ones that can take tracks, for "Add to"
            res = await self.call("music/playlists/library_items", limit=500, order_by="sort_name")
            return [{"id": i.get("item_id"), "name": i.get("name")}
                    for i in res or [] if i.get("is_editable", True)]
        if cmd == "add_to_playlist":
            uris = [str(u) for u in a.get("uris") or [] if u]
            if not uris:
                raise ValueError("nothing to add")
            pid = a.get("playlist")
            if not pid:
                name = str(a.get("name") or "").strip()[:100]
                if not name:
                    raise ValueError("no playlist name")
                pid = (await self.call("music/playlists/create_playlist", name=name) or {}).get("item_id")
            await self.call("music/playlists/add_playlist_tracks", db_playlist_id=str(pid), uris=uris)
            return None
        if cmd == "play_media":
            option = a.get("option", "play")
            if option not in ("play", "replace", "next", "add"):
                raise ValueError("bad option")
            return await self.call("player_queues/play_media", queue_id=q,
                                   media=str(a["uri"]), option=option)
        if cmd == "save_queue":
            await self.call("player_queues/save_as_playlist", queue_id=q, name=str(a["name"])[:100])
            return None
        if cmd == "library":
            kind = a.get("kind")
            if kind not in ("playlists", "radios", "albums"):
                raise ValueError("bad library kind")
            extra = {"search": str(a["search"])} if a.get("search") else {}
            res = await self.call(f"music/{kind}/library_items", limit=500,
                                  order_by="sort_name", **extra)
            return [{"uri": i.get("uri"), "name": i.get("name"),
                     "sub": ", ".join(x.get("name", "") for x in i.get("artists") or [])}
                    for i in res or []]
        raise ValueError(f"unknown command {cmd}")


# ─── Web server ─────────────────────────────────────────────────────────────
class App:
    def __init__(self, conf):
        self.conf = conf
        self.clients = set()
        self.vis = VisReader()
        player = conf.get("WINAMP_PLAYER") or "Car-Radio"
        self.ma = MusicAssistant(ma_base_url(conf), read_token(), player, self.broadcast)

    def broadcast(self, msg):
        text = json.dumps(msg)
        for ws in list(self.clients):
            if not ws.closed:
                asyncio.ensure_future(ws.send_str(text))

    async def ws_handler(self, request):
        ws = web.WebSocketResponse(heartbeat=30, max_msg_size=1 << 20)
        await ws.prepare(request)
        self.clients.add(ws)
        await ws.send_str(json.dumps(self.ma.snapshot()))
        try:
            async for msg in ws:
                if msg.type != WSMsgType.TEXT:
                    continue
                try:
                    m = json.loads(msg.data)
                    res = await self.ma.command(m.get("cmd"), m.get("args") or {})
                    reply = {"type": "result", "id": m.get("id"), "result": res}
                except Exception as e:  # noqa: BLE001 - report every failure to the page
                    reply = {"type": "result", "id": m.get("id") if isinstance(m, dict) else None,
                             "error": str(e)}
                if not ws.closed:
                    await ws.send_str(json.dumps(reply))
        finally:
            self.clients.discard(ws)
        return ws

    async def vis_loop(self):
        """~30 frames a second of new mono samples, as binary messages:
        u32 sample rate, then int16 samples."""
        while True:
            await asyncio.sleep(1 / 30)
            if not self.clients:
                continue
            try:
                pcm, rate = self.vis.read()
            except (ValueError, OSError, struct.error):
                self.vis = VisReader()
                continue
            if not pcm:
                continue
            frame = struct.pack("<I", rate) + pcm
            for ws in list(self.clients):
                if not ws.closed:
                    asyncio.ensure_future(ws.send_bytes(frame))

    async def config(self, _request):
        c = self.conf

        def num(key, default):
            try:
                return float(c.get(key) or default)
            except ValueError:
                return default
        return web.json_response({
            "skins": self.skins(),
            "skin": c.get("WINAMP_SKIN", ""),
            "homeUrl": c.get("HA_URL", ""),
            "scale": num("WINAMP_SCALE", 0),        # 0 / "auto" = fit the screen
            "visDelayMs": num("WINAMP_VIS_DELAY_MS", 300),
        })

    def skins(self):
        out, seen = [], set()
        for d in SKIN_DIRS:
            for f in sorted(d.glob("*.wsz")) + sorted(d.glob("*.zip")):
                if f.name not in seen:
                    seen.add(f.name)
                    out.append({"url": "skins/" + urllib.parse.quote(f.name), "name": f.stem})
        return out

    async def skin(self, request):
        name = request.match_info["name"]
        if "/" in name or "\\" in name or name.startswith("."):
            raise web.HTTPNotFound()
        for d in SKIN_DIRS:
            f = d / name
            if f.is_file():
                return web.FileResponse(f, headers={"Content-Type": "application/octet-stream"})
        raise web.HTTPNotFound()

    async def index(self, _request):
        return web.FileResponse(WWW / "index.html", headers={"Cache-Control": "no-cache"})

    async def start(self, app):
        app["tasks"] = [asyncio.create_task(self.ma.run()), asyncio.create_task(self.vis_loop())]

    async def stop(self, app):
        for t in app["tasks"]:
            t.cancel()


async def no_cache(_request, response):
    """Check every file again (a cheap 304 when unchanged): without this the
    kiosk can keep running an old app.js after an update."""
    if not isinstance(response, web.WebSocketResponse):
        response.headers["Cache-Control"] = "no-cache"


def main():
    conf = read_conf()
    a = App(conf)
    if not a.ma.base:
        sys.exit("Need MA_URL (or HA_URL) to find Music Assistant")
    if not a.ma.token:
        sys.exit(f"Need a Music Assistant token in {TOKEN_FILE} (odroid-ha-install --configure)")
    app = web.Application()
    app.router.add_get("/", a.index)
    app.router.add_get("/ws", a.ws_handler)
    app.router.add_get("/config.json", a.config)
    app.router.add_get("/skins/{name}", a.skin)
    app.router.add_static("/", WWW, append_version=False)
    app.on_startup.append(a.start)
    app.on_cleanup.append(a.stop)
    app.on_response_prepare.append(no_cache)
    host = conf.get("WINAMP_LISTEN") or "127.0.0.1"
    port = int(conf.get("WINAMP_PORT") or 8099)
    # "localhost" resolves to ::1 first on DietPi, and Chromium doesn't fall back
    # to 127.0.0.1 when ::1 refuses, so local-only means both loopbacks.
    hosts = ["127.0.0.1", "::1"] if host in ("127.0.0.1", "localhost", "::1") else [host]
    log(f"Webamp on port {port} ({', '.join(hosts)}) → Music Assistant {a.ma.base}, player {a.ma.player_want}")
    web.run_app(app, host=hosts, port=port, print=None, access_log=None)


if __name__ == "__main__":
    main()

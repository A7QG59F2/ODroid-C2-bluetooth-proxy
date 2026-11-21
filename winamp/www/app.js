// Webamp as a remote for one Music Assistant player.
//
// Webamp makes no sound here. Its "media" object is replaced by MAMedia, which
// sends every button press to winamp-server.py (and on to Music Assistant), and
// Music Assistant's state is written back into Webamp's store. The visualizer
// reads real samples from Squeezelite, streamed by the server.
import Webamp from "./webamp.mjs";

const $ = (s) => document.querySelector(s);
const cfg = await fetch("config.json").then((r) => r.json()).catch(() => ({}));
const EQ_BANDS = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000];

// ─── Link to winamp-server.py ───────────────────────────────────────────────
const link = {
  ws: null,
  seq: 0,
  pending: new Map(),
  connect() {
    const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
    ws.binaryType = "arraybuffer";
    ws.onmessage = (e) => {
      if (e.data instanceof ArrayBuffer) return vis.push(e.data);
      const m = JSON.parse(e.data);
      if (m.type === "result") {
        const p = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) { status(m.error, true); p?.reject(new Error(m.error)); } else p?.resolve(m.result);
      } else bridge.onMessage(m);
    };
    ws.onclose = () => {
      status("Lost the connection to the Odroid, retrying…", true);
      setTimeout(() => this.connect(), 3000);
    };
    this.ws = ws;
  },
  send(cmd, args = {}) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return Promise.reject(new Error("not connected"));
    const id = ++this.seq;
    this.ws.send(JSON.stringify({ id, cmd, args }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  },
};
const fire = (cmd, args) => link.send(cmd, args).catch(() => {});

function status(text, error = false) {
  const el = $("#status");
  el.textContent = text || "";
  el.className = error ? "err" : "";
}

// ─── Visualizer: an AnalyserNode stand-in fed by Squeezelite's samples ──────
// Webamp's spectrum and oscilloscope only read fftSize, frequencyBinCount and
// getByteTimeDomainData(), and run their own FFT. Samples arrive before they
// are heard (ALSA + Bluetooth latency), so reading lags by visDelayMs.
const vis = {
  fftSize: 2048,
  smoothingTimeConstant: 0,
  ring: new Int16Array(1 << 16),
  written: 0,
  rate: 48000,
  lastPush: 0,
  get frequencyBinCount() { return this.fftSize / 2; },
  push(buf) {
    const dv = new DataView(buf);
    this.rate = dv.getUint32(0, true) || this.rate;
    const s = new Int16Array(buf, 4);
    const mask = this.ring.length - 1;
    for (let i = 0; i < s.length; i++) this.ring[(this.written + i) & mask] = s[i];
    this.written += s.length;
    this.lastPush = performance.now();
  },
  getByteTimeDomainData(arr) {
    const now = performance.now();
    if (now - this.lastPush > 1000) return arr.fill(128);
    const delay = cfg.visDelayMs ?? 300;
    const behind = Math.max(0, ((this.lastPush + delay - now) * this.rate) / 1000);
    const end = Math.floor(this.written - behind);
    const mask = this.ring.length - 1;
    for (let i = 0; i < arr.length; i++) {
      const pos = end - arr.length + i;
      arr[i] = pos < 0 ? 128 : 128 + (this.ring[pos & mask] >> 8);
    }
    return arr;
  },
  getFloatTimeDomainData(arr) {
    const b = new Uint8Array(arr.length);
    this.getByteTimeDomainData(b);
    for (let i = 0; i < arr.length; i++) arr[i] = (b[i] - 128) / 128;
  },
  connect() {},
  disconnect() {},
};

// ─── Webamp's media object, pointed at Music Assistant ─────────────────────
class MAMedia {
  constructor() { this.listeners = {}; bridge.media = this; }
  on(ev, cb) { (this.listeners[ev] ||= []).push(cb); }
  emit(ev) { (this.listeners[ev] || []).forEach((cb) => cb()); }
  getAnalyser() { return vis; }
  timeElapsed() { return bridge.elapsedNow(); }
  duration() { return bridge.current?.duration || 0; }
  setVolume(v) { if (bridge.live()) bridge.sendVolume(v); }
  setBalance() {}           // Music Assistant players have no balance control
  setPreamp() { if (bridge.live()) bridge.eqChanged(); }
  setEqBand() { if (bridge.live()) bridge.eqChanged(); }
  enableEq() { if (bridge.live()) bridge.eqChanged(); }
  disableEq() { if (bridge.live()) bridge.eqChanged(); }
  async play() {
    if (!bridge.live()) return;
    const want = bridge.buffered;
    bridge.buffered = null;
    if (want && want !== bridge.current?.id) fire("play_index", { item: want });
    else fire(bridge.queueState === "paused" ? "play" : "play_pause");
  }
  pause() { if (bridge.live()) fire("pause"); }
  stop() { if (bridge.live()) fire("stop"); }
  seekToPercentComplete(pct) {
    if (!bridge.live() || !this.duration()) return;
    const pos = Math.round((pct / 100) * this.duration());
    bridge.setElapsed(pos);
    fire("seek", { position: pos });
  }
  async loadFromUrl(url, autoPlay) {
    if (!bridge.live() || !url.startsWith("ma:")) return;
    const item = url.slice(3);
    if (autoPlay) fire("play_index", { item });
    else bridge.buffered = item;
  }
  dispose() {}
}

// ─── Music Assistant ⇄ Webamp store ─────────────────────────────────────────
const bridge = {
  media: null,
  webamp: null,
  ready: false,       // Webamp has rendered and received the first snapshot
  syncing: 0,         // >0 while we write MA's state into Webamp (no echo back)
  items: [],
  idByItem: new Map(),
  itemById: new Map(),
  current: null,
  queueState: "idle",
  buffered: null,
  elapsed: 0,
  elapsedAt: 0,
  lastVolumeSent: 0,
  lastEqSent: 0,
  eqTimer: 0,
  volTimer: 0,

  live() { return this.ready && !this.syncing; },
  store() { return this.webamp.store; },
  sync(fn) { this.syncing++; try { fn(); } finally { this.syncing--; } },
  dispatch(a) { this.store().dispatch({ ...a, fromMA: true }); },

  elapsedNow() {
    const run = this.queueState === "playing" ? (performance.now() - this.elapsedAt) / 1000 : 0;
    const t = this.elapsed + run;
    return this.current?.duration ? Math.min(t, this.current.duration) : t;
  },
  setElapsed(t) { this.elapsed = t; this.elapsedAt = performance.now(); this.media?.emit("timeupdate"); },

  sendVolume(v) {
    this.lastVolumeSent = Date.now();
    clearTimeout(this.volTimer);
    this.volTimer = setTimeout(() => fire("volume", { level: Math.round(v) }), 120);
  },
  eqChanged() {
    this.lastEqSent = Date.now();
    clearTimeout(this.eqTimer);
    this.eqTimer = setTimeout(() => {
      const eq = this.store().getState().equalizer;
      fire("eq", { on: eq.on, preamp: eq.sliders.preamp, bands: EQ_BANDS.map((b) => eq.sliders[b]) });
    }, 250);
  },

  onMessage(m) {
    if (!this.webamp) return;
    switch (m.type) {
      case "snapshot":
        status(m.connected ? "" : m.error || "Waiting for Music Assistant…", !m.connected);
        this.applyItems(m.items || []);
        this.applyPlayer(m.player);
        this.applyQueue(m.queue);
        if (m.eq) this.applyEq(m.eq, true);
        this.ready = true;
        break;
      case "status": status(m.connected ? "" : m.error, !m.connected); break;
      case "items": this.applyItems(m.items); this.applyQueue(m.queue); break;
      case "queue": this.applyQueue(m.queue); break;
      case "player": this.applyPlayer(m.player); break;
      case "time": this.setElapsed(m.elapsed); break;
      case "eq": this.applyEq(m.eq); break;
    }
  },

  applyItems(items) {
    const same = items.length === this.items.length && items.every((it, i) => it.id === this.items[i].id);
    this.items = items;
    this.itemById = new Map(items.map((it) => [it.id, it]));
    if (same) return;
    const tracks = items.map((it) => ({
      url: "ma:" + it.id,
      duration: it.duration || 0,
      defaultName: it.name,
      metaData: { title: it.title || it.name, artist: it.artist || "", album: it.album || "" },
    }));
    this.sync(() => {
      this.dispatch({ type: "REMOVE_ALL_TRACKS" });
      if (tracks.length) this.webamp.appendTracks(tracks);
      const st = this.store().getState();
      this.idByItem = new Map();
      for (const id of st.playlist.trackOrder) {
        const url = st.tracks[id]?.url || "";
        if (url.startsWith("ma:")) this.idByItem.set(url.slice(3), id);
      }
    });
    this.current = null;    // re-select the current track below
  },

  applyQueue(q) {
    if (!q) return;
    const st = this.store().getState();
    this.sync(() => {
      // Current track
      const cur = q.current;
      const prev = this.current;
      const moved = cur && (cur.id !== prev?.id || st.playlist.currentTrack == null);
      // A radio station keeps its queue item while the song changes: retag it
      const retag = cur && !moved && (cur.title !== prev?.title || cur.artist !== prev?.artist);
      if (moved || retag) {
        const id = this.idByItem.get(cur.id);
        if (id != null) {
          if (moved) this.dispatch({ type: "BUFFER_TRACK", id });
          this.dispatch({ type: "SET_MEDIA", id, length: cur.duration || 0, channels: cur.channels || 2 });
          // The kbps / kHz boxes and mono/stereo come from the track's tags
          const bps = cur.bitrate > 10000 ? cur.bitrate : (cur.bitrate || 0) * 1000;
          this.dispatch({
            type: "SET_MEDIA_TAGS", id,
            title: cur.title || cur.name, artist: cur.artist || "", album: cur.album || "",
            sampleRate: cur.rate || 44100, bitrate: bps, numberOfChannels: cur.channels || 2,
          });
        }
      }
      this.current = cur;
      // Play state
      this.queueState = q.state;
      const s = this.store().getState().media.status;
      if (q.state === "playing" && s !== "PLAYING") this.dispatch({ type: "IS_PLAYING" });
      else if (q.state === "paused" && s !== "PAUSED") this.dispatch({ type: "PAUSE" });
      else if (q.state === "idle" && s !== "STOPPED") this.dispatch({ type: "STOP" });
      // Shuffle / repeat buttons
      const media = this.store().getState().media;
      if (media.shuffle !== q.shuffle) this.dispatch({ type: "TOGGLE_SHUFFLE" });
      if (media.repeat !== (q.repeat !== "off")) this.dispatch({ type: "TOGGLE_REPEAT" });
    });
    this.setElapsed(q.elapsed || 0);
  },

  applyPlayer(p) {
    if (!p) return;
    if (p.available === false) status(`${p.name || "The player"} is unavailable (radio off?)`, true);
    if (p.volume == null || Date.now() - this.lastVolumeSent < 2000) return;
    if (this.store().getState().media.volume !== p.volume) {
      this.sync(() => this.dispatch({ type: "SET_VOLUME", volume: p.volume }));
    }
  },

  applyEq(eq, force = false) {
    if (!eq || (!force && Date.now() - this.lastEqSent < 3000)) return;
    const st = this.store().getState().equalizer;
    this.sync(() => {
      if (st.sliders.preamp !== eq.preamp) this.dispatch({ type: "SET_BAND_VALUE", band: "preamp", value: eq.preamp });
      EQ_BANDS.forEach((b, i) => {
        if (st.sliders[b] !== eq.bands[i]) this.dispatch({ type: "SET_BAND_VALUE", band: b, value: eq.bands[i] });
      });
      if (st.on !== eq.on) this.dispatch({ type: eq.on ? "SET_EQ_ON" : "SET_EQ_OFF" });
    });
  },
};

// Webamp actions that Music Assistant has to carry out. The rest pass through.
// Actions from bridge.sync() carry fromMA and always pass.
const maMiddleware = (store) => (next) => (action) => {
  if (action.fromMA || bridge.syncing || !bridge.ready) return next(action);
  const st = store.getState();
  const itemsOf = (ids) => ids.map((id) => st.tracks[id]?.url).filter((u) => u?.startsWith("ma:")).map((u) => u.slice(3));
  switch (action.type) {
    case "TOGGLE_SHUFFLE":
      fire("shuffle", { enabled: !st.media.shuffle });
      return undefined;               // the button lights up when MA confirms
    case "TOGGLE_REPEAT":
      fire("repeat", { mode: st.media.repeat ? "off" : "all" });
      return undefined;
    case "RANDOMIZE_LIST":
      fire("shuffle", { enabled: true });
      return undefined;
    case "REMOVE_TRACKS":
      fire("delete", { items: itemsOf(action.ids) });
      return undefined;               // the playlist redraws from MA's queue
    case "REMOVE_ALL_TRACKS":
      fire("clear");
      return undefined;
    case "DRAG_SELECTED": {
      const sel = st.playlist.trackOrder.filter((id) => st.playlist.selectedTracks.includes(id));
      const items = itemsOf(action.offset > 0 ? sel.reverse() : sel);
      fire("move", { items, shift: action.offset });
      return next(action);            // move now, MA's queue confirms
    }
    case "ADD_TRACK_FROM_URL":
      if (!String(action.url).startsWith("ma:")) return undefined;   // local files can't reach MA
      break;
    case "REVERSE_LIST":
    case "SET_TRACK_ORDER":
      return undefined;               // Music Assistant can't reorder a queue this way
  }
  return next(action);
};

// ─── Library picker (eject button, "Load list", the Library button) ────────
const lib = {
  kind: "playlists",
  timer: 0,
  open(kind = this.kind) {
    this.kind = kind;
    document.querySelectorAll("#lib .tab").forEach((t) => t.classList.toggle("on", t.dataset.kind === kind));
    $("#lib").classList.add("open");
    this.load();
  },
  close() { $("#lib").classList.remove("open"); },
  async load() {
    const ul = $("#liblist");
    ul.innerHTML = '<li class="empty">Loading…</li>';
    let rows = [];
    try {
      rows = await link.send("library", { kind: this.kind, search: $("#libsearch").value.trim() });
    } catch (e) {
      ul.innerHTML = "";
      ul.append(Object.assign(document.createElement("li"), { className: "empty", textContent: e.message }));
      return;
    }
    ul.innerHTML = "";
    if (!rows.length) ul.innerHTML = '<li class="empty">Nothing here.</li>';
    for (const r of rows) {
      const li = document.createElement("li");
      const name = Object.assign(document.createElement("div"), { className: "name", textContent: r.name });
      if (r.sub) name.append(Object.assign(document.createElement("div"), { className: "sub", textContent: r.sub }));
      const add = Object.assign(document.createElement("button"), { type: "button", textContent: "+ Queue" });
      add.onclick = (e) => { e.stopPropagation(); fire("play_media", { uri: r.uri, option: "add" }); this.close(); };
      li.onclick = () => { fire("play_media", { uri: r.uri, option: "replace" }); this.close(); };
      li.append(name, add);
      ul.append(li);
    }
  },
};
document.querySelectorAll("#lib .tab").forEach((t) => (t.onclick = () => lib.open(t.dataset.kind)));
$("#libclose").onclick = () => lib.close();
$("#libbtn").onclick = () => lib.open();
// Opened full screen from a dashboard button: a way back. (In an iframe card
// the dashboard is already around it.)
// A tab the dashboard opened can close itself (back to the dashboard tab);
// otherwise go to the kiosk's dashboard URL.
if (window.top === window) {
  $("#homebtn").style.display = "inline-block";
  $("#homebtn").onclick = () => {
    window.close();
    setTimeout(() => { if (cfg.homeUrl) location.href = cfg.homeUrl; else history.back(); }, 300);
  };
}
$("#libsearch").oninput =() => { clearTimeout(lib.timer); lib.timer = setTimeout(() => lib.load(), 400); };

// A text prompt in the page (Onboard pops up for it, unlike a browser dialog).
function ask(question, value = "") {
  return new Promise((resolve) => {
    $("#askq").textContent = question;
    const input = $("#aska");
    input.value = value;
    $("#ask").classList.add("open");
    input.focus();
    const done = (v) => { $("#ask").classList.remove("open"); input.blur(); resolve(v); };
    $("#askok").onclick = () => done(input.value.trim() || null);
    $("#askno").onclick = () => done(null);
    input.onkeydown = (e) => { if (e.key === "Enter") done(input.value.trim() || null); if (e.key === "Escape") done(null); };
  });
}

// Next/previous go to Music Assistant (it knows the shuffle order and radio
// mode), eject opens the library. Caught before Webamp's own handlers.
window.addEventListener("click", (e) => {
  const t = e.target instanceof Element ? e.target : null;
  // Links out (Webamp's logo and "About" menu go to webamp.org): a kiosk has
  // no back button, so never leave the page.
  const a = t?.closest("a[href]");
  if (a && new URL(a.href, location.href).origin !== location.origin) {
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (!t || !bridge.ready) return;
  const hit = (sel) => t.closest(sel);
  let cmd = null;
  if (hit("#webamp #next, #webamp .playlist-next-button")) cmd = "next";
  else if (hit("#webamp #previous, #webamp .playlist-previous-button")) cmd = "previous";
  else if (hit("#webamp #eject, #webamp .playlist-eject-button") ||
           (hit("#webamp #play, #webamp .playlist-play-button") && !bridge.items.length)) cmd = "library";
  if (!cmd) return;
  e.stopPropagation();
  e.preventDefault();
  if (cmd === "library") lib.open();
  else fire(cmd);
}, true);

// ─── Skins ──────────────────────────────────────────────────────────────────
// Remember the skin picked from Options → Skins (Webamp fetches it by URL).
const SKIN_KEY = "odroid-winamp-skin";
window.open = () => null;   // same reason: no pop-up tabs on the kiosk
const realFetch = window.fetch.bind(window);
window.fetch = (input, init) => {
  const url = typeof input === "string" ? input : input?.url || "";
  if (bridge.ready && /\/skins\/[^/]+$/.test(url)) {
    try { localStorage.setItem(SKIN_KEY, url.slice(url.indexOf("skins/"))); } catch {}
  }
  return realFetch(input, init);
};
let savedSkin = null;
try { savedSkin = localStorage.getItem(SKIN_KEY); } catch {}
const skins = cfg.skins || [];
const byName = skins.find((s) => s.name.toLowerCase() === String(cfg.skin || "").toLowerCase());
const startSkin = skins.find((s) => s.url === savedSkin) || byName;

// ─── Layout: main + equalizer on the left, playlist filling the rest ────────
// (An iframe can start at 0×0 until the dashboard lays it out: wait for a size.)
for (let i = 0; i < 100 && !(window.innerWidth && window.innerHeight); i++) {
  await new Promise((r) => setTimeout(r, 50));
}
const W = window.innerWidth || 1920, H = window.innerHeight || 1200;
let resizeTimer = 0;   // the layout is computed once, so start over on a new size
window.addEventListener("resize", () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (Math.abs(window.innerWidth - W) > 40 || Math.abs(window.innerHeight - H) > 40) location.reload();
  }, 1000);
});
// Whole-number sizes keep every skin pixel the same size (crisp text)
const scale = Number(cfg.scale) > 0 ? Number(cfg.scale)
  : Math.max(1, Math.floor(Math.min(W / 550, H / 232)));
const extraHeight = Math.max(0, Math.floor((H / scale - 116) / 29));
const extraWidth = Math.max(0, Math.floor((W / scale - 550) / 25));
const stage = $("#stage");
stage.style.width = `${W / scale}px`;
stage.style.height = `${H / scale}px`;
stage.style.zoom = scale;

const webamp = new Webamp({
  __customMediaClass: MAMedia,
  __customMiddlewares: [maMiddleware],
  initialSkin: startSkin ? { url: startSkin.url } : undefined,
  availableSkins: skins,
  enableHotkeys: false,
  zIndex: 10,
  windowLayout: {
    main: { position: { top: 0, left: 0 } },
    equalizer: { position: { top: 116, left: 0 } },
    playlist: { position: { top: 0, left: 275 }, size: { extraHeight, extraWidth } },
  },
  handleAddUrlEvent: async () => {
    const url = await ask("Stream or file URL to add to the queue:");
    if (url) fire("play_media", { uri: url, option: "add" });
    return null;
  },
  handleLoadListEvent: async () => { lib.open("playlists"); return null; },
  handleSaveListEvent: async () => {
    const name = await ask("Save the queue as a Music Assistant playlist named:");
    if (name) fire("save_queue", { name });
    return null;
  },
});
bridge.webamp = webamp;
window.odroidWinamp = { bridge, vis, link };   // for poking at from DevTools
webamp.onWillClose((cancel) => cancel());   // nothing to close to on a kiosk
await webamp.renderInto(stage);

// Ticking clock for Webamp's time display while Music Assistant plays
setInterval(() => { if (bridge.queueState === "playing") bridge.media?.emit("timeupdate"); }, 250);

link.connect();

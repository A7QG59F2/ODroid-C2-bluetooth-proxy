/*
 * Webamp as a touch-screen remote for one Music Assistant player.
 *
 * Webamp (the Winamp 2 clone) normally plays audio itself. Here it gets a
 * custom media class instead, so every button, slider and playlist action
 * becomes a Music Assistant API call, and Music Assistant's queue state is
 * pushed back into Webamp's store:
 *
 *   Webamp main window  ->  play/pause/stop/next/prev/seek/volume on the MA queue
 *   Webamp playlist     <-  the MA queue (double-tap plays that item, remove/clear mirrored)
 *   Webamp equalizer    ->  a 10-band parametric EQ (+ preamp, balance) in the
 *                           player's MA DSP settings
 *
 * Audio never goes through the browser: the player itself (squeezelite on this
 * Odroid, or any other MA player) does the playing.
 *
 * Settings come from config.js (window.WINAMP_CONFIG), written by install.sh.
 */
(function () {
  "use strict";

  const CFG = Object.assign(
    { maUrl: "http://homeassistant.local:8095", token: "", player: "", skin: "" },
    window.WINAMP_CONFIG || {}
  );
  const ITEM_URL = "ma://queue-item/";
  // Winamp's 10 bands; Webamp slider values are 0..100, 50 = 0 dB, ends = +/-12 dB
  const EQ_BANDS = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000];
  const EQ_Q = 1.4;
  const EQ_RANGE_DB = 12;
  // Ignore echoes of our own volume/EQ changes for this long (ms)
  const LOCAL_HOLD_MS = 2000;

  const statusEl = document.getElementById("status");
  function status(text, isError) {
    statusEl.textContent = text || "";
    statusEl.className = isError ? "err" : "";
  }
  const log = (...a) => console.log("[ma-winamp]", ...a);

  // ── Music Assistant WebSocket API client ──────────────────────────────────
  class MusicAssistant {
    constructor(baseUrl, token) {
      this.wsUrl = baseUrl.replace(/^http/i, "ws").replace(/\/+$/, "") + "/ws";
      this.token = token;
      this.nextId = 1;
      this.pending = new Map();
      this.eventHandlers = [];
      this.onReady = () => {};
      this.retries = 0;
      this.ws = null;
    }

    connect() {
      status("Connecting to Music Assistant…");
      let ws;
      try {
        ws = new WebSocket(this.wsUrl);
      } catch (err) {
        this._retry(String(err));
        return;
      }
      this.ws = ws;
      let greeted = false;
      ws.onmessage = (ev) => {
        let msg;
        try { msg = JSON.parse(ev.data); } catch (_) { return; }
        if (!greeted && msg.server_version) {
          greeted = true;
          this._authenticate();
          return;
        }
        if (msg.event) {
          this.eventHandlers.forEach((h) => h(msg));
          return;
        }
        if (msg.message_id === "connection" && msg.error_code) {
          status("Music Assistant: " + (msg.details || "not ready"), true);
          return;
        }
        const p = this.pending.get(String(msg.message_id));
        if (!p) return;
        if (msg.error_code != null) {
          this.pending.delete(String(msg.message_id));
          p.reject(new Error(msg.details || "error " + msg.error_code));
        } else if (msg.partial) {
          // Long lists arrive in chunks
          p.parts.push(...(msg.result || []));
        } else {
          this.pending.delete(String(msg.message_id));
          p.resolve(p.parts.length ? p.parts.concat(msg.result || []) : msg.result);
        }
      };
      ws.onclose = () => {
        if (this.ws !== ws) return;
        this.ws = null;
        this.pending.forEach((p) => p.reject(new Error("disconnected")));
        this.pending.clear();
        this._retry("connection lost");
      };
      ws.onerror = () => {}; // onclose follows
    }

    _retry(why) {
      const delay = Math.min(30, 2 ** this.retries) * 1000;
      this.retries = Math.min(this.retries + 1, 5);
      status(`Music Assistant: ${why}, retrying in ${delay / 1000}s`, true);
      setTimeout(() => this.connect(), delay);
    }

    async _authenticate() {
      try {
        await this.send("auth", { token: this.token, device_name: "Odroid Winamp" });
      } catch (err) {
        status("Music Assistant refused the token: " + err.message, true);
        log("auth failed", err);
        // Leave the socket open but useless; reconnect later in case the token is fixed
        setTimeout(() => this.ws && this.ws.close(), 60000);
        return;
      }
      this.retries = 0;
      this.onReady();
    }

    send(command, args) {
      return new Promise((resolve, reject) => {
        if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
          reject(new Error("not connected"));
          return;
        }
        const id = String(this.nextId++);
        this.pending.set(id, { resolve, reject, parts: [] });
        this.ws.send(JSON.stringify({ message_id: id, command, args: args || {} }));
      });
    }
  }

  // ── Bridge state: what Music Assistant says, and how it maps into Webamp ──
  const bridge = {
    ma: null,
    webamp: null,
    store: null,
    media: null,
    ready: false,          // false until the first full sync; media calls are ignored until then
    quiet: 0,              // >0 while pushing MA state into Webamp, so it isn't echoed back
    layoutLocked: false,   // after first render, windows can't be moved/closed/resized
    player: null,
    queueId: null,
    queue: null,
    items: [],
    trackIdByItem: new Map(),
    itemByTrackId: new Map(),
    nextTrackId: 1000000,  // well away from Webamp's own ids
    elapsedBase: 0,
    elapsedAt: 0,
    dsp: null,
    dspWritable: true,
    lastLocalVolume: -Infinity,
    lastLocalDsp: -Infinity,
    volumeTimer: null,
    dspTimer: null,
    itemsTimer: null,
  };

  function silently(fn) {
    bridge.quiet++;
    try { fn(); } finally { bridge.quiet--; }
  }
  const canSend = () => bridge.ready && bridge.quiet === 0 && bridge.queueId != null;
  const state = () => bridge.store.getState();
  const dispatch = (a) => bridge.store.dispatch(a);
  const now = () => performance.now();

  function report(err) {
    log(err);
    status("Music Assistant: " + (err && err.message ? err.message : err), true);
    setTimeout(() => statusEl.classList.contains("err") && status(""), 5000);
  }
  function queueCmd(command, args) {
    return bridge.ma.send(command, Object.assign({ queue_id: bridge.queueId }, args || {})).catch(report);
  }

  function isPlaying() {
    return bridge.queue && bridge.queue.state === "playing";
  }
  function duration() {
    const item = bridge.queue && bridge.queue.current_item;
    return (item && item.duration) || 0;
  }
  function elapsed() {
    if (!bridge.queue) return 0;
    let t = bridge.elapsedBase;
    if (isPlaying()) t += (now() - bridge.elapsedAt) / 1000;
    const d = duration();
    return d > 0 ? Math.min(t, d) : t;
  }

  // ── Custom media class handed to Webamp ───────────────────────────────────
  class MaMedia {
    constructor() {
      this._handlers = {};
      this._analyser = null;
      bridge.media = this;
    }
    on(event, cb) { (this._handlers[event] = this._handlers[event] || []).push(cb); }
    emit(event) { (this._handlers[event] || []).forEach((cb) => cb()); }
    timeElapsed() { return elapsed(); }
    duration() { return duration(); }
    async play() { if (canSend()) queueCmd("player_queues/play"); }
    pause() { if (canSend()) queueCmd("player_queues/pause"); }
    stop() { if (canSend()) queueCmd("player_queues/stop"); }
    seekToPercentComplete(percent) {
      const d = duration();
      if (!canSend() || d <= 0) return;
      const position = Math.round((d * percent) / 100);
      bridge.elapsedBase = position;
      bridge.elapsedAt = now();
      queueCmd("player_queues/seek", { position });
    }
    async loadFromUrl(url, autoPlay) {
      // Webamp calls this on next/previous and when a playlist entry is double-tapped
      if (!canSend() || !autoPlay || !url.startsWith(ITEM_URL)) return;
      const itemId = decodeURIComponent(url.slice(ITEM_URL.length));
      queueCmd("player_queues/play_index", { index: itemId });
    }
    setVolume(volume) {
      if (!canSend() || !bridge.player) return;
      bridge.lastLocalVolume = now();
      clearTimeout(bridge.volumeTimer);
      bridge.volumeTimer = setTimeout(() => {
        bridge.ma
          .send("players/cmd/volume_set", { player_id: bridge.player.player_id, volume_level: Math.round(volume) })
          .catch(report);
      }, 150);
    }
    setBalance() { scheduleDspSave(); }
    setPreamp() { scheduleDspSave(); }
    setEqBand() { scheduleDspSave(); }
    disableEq() { scheduleDspSave(); }
    enableEq() { scheduleDspSave(); }
    getAnalyser() {
      // No audio passes through the page, so the visualizer stays flat
      if (!this._analyser) {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        this._analyser = new Ctx().createAnalyser();
      }
      return this._analyser;
    }
    dispose() {}
  }

  // ── Webamp actions that need translating (or blocking) ────────────────────
  const LAYOUT_ACTIONS = new Set([
    "UPDATE_WINDOW_POSITIONS", "CLOSE_WINDOW", "TOGGLE_WINDOW", "TOGGLE_WINDOW_SHADE_MODE",
    "TOGGLE_DOUBLESIZE_MODE", "WINDOW_SIZE_CHANGED", "RESET_WINDOW_SIZES",
    "CLOSE_WINAMP", "MINIMIZE_WINAMP",
  ]);
  const maMiddleware = () => (next) => (action) => {
    if (bridge.quiet) return next(action);
    if (bridge.layoutLocked && LAYOUT_ACTIONS.has(action.type)) return undefined;
    switch (action.type) {
      case "TOGGLE_SHUFFLE":
        if (canSend()) queueCmd("player_queues/shuffle", { shuffle_enabled: !state().media.shuffle });
        return undefined; // the button flips when MA confirms
      case "TOGGLE_REPEAT":
        if (canSend()) queueCmd("player_queues/repeat", { repeat_mode: state().media.repeat ? "off" : "all" });
        return undefined;
      case "REMOVE_TRACKS":
        if (canSend()) {
          action.ids.forEach((id) => {
            const itemId = bridge.itemByTrackId.get(Number(id));
            if (itemId) queueCmd("player_queues/delete_item", { item_id_or_index: itemId });
          });
        }
        return undefined; // the playlist refreshes from MA
      case "REMOVE_ALL_TRACKS":
        if (canSend()) queueCmd("player_queues/clear");
        return undefined;
      case "DRAG_SELECTED":
      case "REVERSE_LIST":
      case "RANDOMIZE_LIST":
      case "SORT_BY_TITLE":
        return undefined; // reordering isn't mirrored to MA; keep the list honest
      default:
        return next(action);
    }
  };

  // ── MA → Webamp ───────────────────────────────────────────────────────────
  // "Artist - Title" in the playlist and marquee, plus bitrate/sample rate once MA knows them
  function tagTrack(id, item) {
    const mi = item.media_item || {};
    const artist = (mi.artists || []).map((a) => a.name).filter(Boolean).join(", ");
    const fmt = (item.streamdetails && item.streamdetails.audio_format) || {};
    if (!(artist && mi.name) && !fmt.sample_rate) return; // keep MA's display name
    dispatch({
      type: "SET_MEDIA_TAGS", id,
      artist: artist || undefined,
      title: mi.name || item.name,
      album: mi.album ? mi.album.name : undefined,
      sampleRate: fmt.sample_rate || 44100,
      bitrate: fmt.bit_rate ? fmt.bit_rate * 1000 : null,
      numberOfChannels: fmt.channels || 2,
    });
  }

  function rebuildPlaylist() {
    silently(() => {
      dispatch({ type: "REMOVE_ALL_TRACKS" });
      bridge.trackIdByItem.clear();
      bridge.itemByTrackId.clear();
      bridge.items.forEach((item, i) => {
        const id = bridge.nextTrackId++;
        bridge.trackIdByItem.set(item.queue_item_id, id);
        bridge.itemByTrackId.set(id, item.queue_item_id);
        const len = item.duration || 0;
        dispatch({
          type: "ADD_TRACK_FROM_URL",
          url: ITEM_URL + encodeURIComponent(item.queue_item_id),
          duration: len,
          defaultName: item.name || mi.name || "Unknown",
          id,
          atIndex: i,
        });
        dispatch({ type: "SET_MEDIA_DURATION", id, duration: len });
        tagTrack(id, item);
      });
    });
    applyQueue(bridge.queue, true);
  }

  async function loadItems() {
    const qid = bridge.queueId;
    const items = await bridge.ma.send("player_queues/items", { queue_id: qid, limit: 1000, offset: 0 });
    if (qid !== bridge.queueId) return;
    bridge.items = items || [];
    rebuildPlaylist();
  }
  function scheduleItemsReload() {
    clearTimeout(bridge.itemsTimer);
    bridge.itemsTimer = setTimeout(() => loadItems().catch(report), 300);
  }

  function setElapsed(seconds, lastUpdated) {
    let t = seconds || 0;
    // Correct for time spent since MA measured it (clocks are NTP-synced; clamp anyway)
    if (lastUpdated && isPlaying()) t += Math.max(0, Math.min(10, Date.now() / 1000 - lastUpdated));
    bridge.elapsedBase = t;
    bridge.elapsedAt = now();
  }

  function applyQueue(q, force) {
    if (!q) return;
    const prev = bridge.queue;
    bridge.queue = q;
    setElapsed(q.elapsed_time, q.elapsed_time_last_updated);
    const st = state();
    const item = q.current_item;
    silently(() => {
      if (item) {
        const id = bridge.trackIdByItem.get(item.queue_item_id);
        if (id == null) {
          scheduleItemsReload(); // the queue changed under us
        } else if (force || st.playlist.currentTrack !== id ||
                   !prev || !prev.current_item || prev.current_item.queue_item_id !== item.queue_item_id) {
          dispatch({ type: "BUFFER_TRACK", id });
          dispatch({ type: "SET_MEDIA_DURATION", id, duration: item.duration || 0 });
          tagTrack(id, item);
        }
      }
      const want = q.state === "playing" ? "PLAYING" : q.state === "paused" ? "PAUSED" : "STOPPED";
      if (st.media.status !== want) {
        dispatch({ type: want === "PLAYING" ? "IS_PLAYING" : want === "PAUSED" ? "PAUSE" : "STOP" });
      }
      if (Boolean(q.shuffle_enabled) !== Boolean(st.media.shuffle)) dispatch({ type: "TOGGLE_SHUFFLE" });
      if ((q.repeat_mode && q.repeat_mode !== "off") !== Boolean(st.media.repeat)) dispatch({ type: "TOGGLE_REPEAT" });
    });
    bridge.media && bridge.media.emit("timeupdate");
  }

  function applyVolume(level) {
    if (level == null || now() - bridge.lastLocalVolume < LOCAL_HOLD_MS) return;
    if (Math.round(state().media.volume) === Math.round(level)) return;
    silently(() => dispatch({ type: "SET_VOLUME", volume: level }));
  }

  // ── Equalizer <-> MA DSP ──────────────────────────────────────────────────
  const toDb = (v) => Math.round(((v - 50) / 50) * EQ_RANGE_DB * 10) / 10;
  const toSlider = (db) => Math.max(0, Math.min(100, Math.round(50 + (db / EQ_RANGE_DB) * 50)));
  function isOurEq(f) {
    return f && f.type === "parametric_eq" && Array.isArray(f.bands) && f.bands.length === EQ_BANDS.length &&
      f.bands.every((b, i) => Math.round(b.frequency) === EQ_BANDS[i]);
  }

  function applyDsp(cfg) {
    bridge.dsp = cfg;
    if (!cfg || now() - bridge.lastLocalDsp < LOCAL_HOLD_MS) return;
    const eq = (cfg.filters || []).find(isOurEq);
    const bal = (cfg.filters || []).find((f) => f.type === "balance");
    silently(() => {
      if (eq) {
        dispatch({ type: "SET_BAND_VALUE", band: "preamp", value: toSlider(eq.preamp || 0) });
        eq.bands.forEach((b, i) => dispatch({ type: "SET_BAND_VALUE", band: EQ_BANDS[i], value: toSlider(b.gain) }));
      }
      const on = Boolean(eq && eq.enabled && cfg.enabled);
      if (on !== state().equalizer.on) dispatch({ type: on ? "SET_EQ_ON" : "SET_EQ_OFF" });
      const balance = bal && bal.enabled && cfg.enabled ? Math.round(bal.balance) : 0;
      if (balance !== state().media.balance) dispatch({ type: "SET_BALANCE", balance });
    });
  }

  async function loadDsp() {
    try {
      applyDsp(await bridge.ma.send("config/players/dsp/get", { player_id: bridge.player.player_id }));
      bridge.dspWritable = true;
    } catch (err) {
      bridge.dspWritable = false;
      log("DSP settings unavailable, the EQ stays local:", err.message);
    }
  }

  function scheduleDspSave() {
    if (!canSend() || !bridge.player) return;
    bridge.lastLocalDsp = now();
    clearTimeout(bridge.dspTimer);
    // MA re-applies DSP by restarting the stream, so wait until the sliders settle
    bridge.dspTimer = setTimeout(saveDsp, 800);
  }

  async function saveDsp() {
    if (!bridge.dspWritable) return;
    const st = state();
    const sliders = st.equalizer.sliders;
    const eqOn = st.equalizer.on;
    const balance = st.media.balance || 0;
    const cfg = JSON.parse(JSON.stringify(bridge.dsp || { enabled: false, filters: [], input_gain: 0, output_gain: 0 }));
    cfg.filters = cfg.filters || [];
    const eq = {
      type: "parametric_eq",
      enabled: eqOn,
      preamp: toDb(sliders.preamp),
      per_channel_preamp: {},
      bands: EQ_BANDS.map((f) => ({ frequency: f, q: EQ_Q, gain: toDb(sliders[f]), type: "peak", enabled: true, channel: "ALL" })),
    };
    const eqIdx = cfg.filters.findIndex(isOurEq);
    if (eqIdx >= 0) cfg.filters[eqIdx] = eq;
    else cfg.filters.push(eq);
    const balIdx = cfg.filters.findIndex((f) => f.type === "balance");
    if (balIdx >= 0) cfg.filters[balIdx] = Object.assign(cfg.filters[balIdx], { enabled: balance !== 0, balance });
    else if (balance !== 0) cfg.filters.push({ type: "balance", enabled: true, balance });
    if (eqOn || balance !== 0) cfg.enabled = true;
    delete cfg.preset_id;
    try {
      bridge.dsp = await bridge.ma.send("config/players/dsp/save", { player_id: bridge.player.player_id, config: cfg });
      bridge.lastLocalDsp = now();
    } catch (err) {
      report(err);
    }
  }

  // ── Finding the player and its queue ─────────────────────────────────────
  function matchPlayer(players) {
    const want = (CFG.player || "").trim().toLowerCase();
    if (!want) return players.find((p) => p.available) || null;
    return players.find((p) => p.player_id.toLowerCase() === want) ||
           players.find((p) => (p.name || p.display_name || "").toLowerCase() === want) || null;
  }

  async function queueIdFor(player) {
    // A player that is part of a group plays the group's queue
    const src = player.active_source;
    if (src && src !== player.player_id) {
      try {
        if (await bridge.ma.send("player_queues/get", { queue_id: src })) return src;
      } catch (_) { /* not a queue (e.g. a plugin source) */ }
    }
    return player.player_id;
  }

  async function switchQueue(qid) {
    bridge.queueId = qid;
    const q = await bridge.ma.send("player_queues/get", { queue_id: qid });
    bridge.queue = q;
    await loadItems();
    applyQueue(q, true);
  }

  async function fullSync() {
    bridge.ready = false;
    const players = await bridge.ma.send("players/all");
    const player = matchPlayer(players || []);
    if (!player) {
      status(`Player "${CFG.player}" not found in Music Assistant (is it on and enabled?)`, true);
      setTimeout(() => fullSync().catch(report), 15000);
      return;
    }
    bridge.player = player;
    await switchQueue(await queueIdFor(player));
    applyVolume(player.volume_level);
    await loadDsp();
    bridge.ready = true;
    status("");
    log("synced with", player.name, "queue", bridge.queueId);
  }

  function onEvent(msg) {
    const id = msg.object_id;
    switch (msg.event) {
      case "player_updated":
        if (bridge.player && id === bridge.player.player_id && msg.data) {
          bridge.player = msg.data;
          applyVolume(msg.data.volume_level);
          queueIdFor(msg.data).then((qid) => {
            if (qid !== bridge.queueId) switchQueue(qid).catch(report);
          });
        }
        break;
      case "player_added":
      case "player_removed":
        if (!bridge.player || id === bridge.player.player_id) fullSync().catch(report);
        break;
      case "queue_updated":
        if (id === bridge.queueId && msg.data) applyQueue(msg.data);
        break;
      case "queue_items_updated":
        if (id === bridge.queueId) scheduleItemsReload();
        break;
      case "queue_time_updated":
        if (id === bridge.queueId && typeof msg.data === "number") {
          setElapsed(msg.data);
          bridge.media && bridge.media.emit("timeupdate");
        }
        break;
      case "player_dsp_config_updated":
        if (bridge.player && id === bridge.player.player_id) applyDsp(msg.data);
        break;
      default:
        break;
    }
  }

  // ── Start ────────────────────────────────────────────────────────────────
  // There's no file system to browse on a kiosk: Webamp's "open file" buttons do nothing
  const origClick = HTMLInputElement.prototype.click;
  HTMLInputElement.prototype.click = function () {
    if (this.type === "file") return undefined;
    return origClick.apply(this, arguments);
  };

  if (!window.Webamp || !window.Webamp.browserIsSupported()) {
    status("Webamp didn't load (re-run odroid-ha-install)", true);
    return;
  }

  // Portrait stack: main (275x116), equalizer below it, playlist filling the
  // rest. The kiosk zooms the page so 275 CSS px is the screen's width.
  const playlistExtra = Math.max(0, Math.floor((window.innerHeight - 116 * 3) / 29));
  const webamp = new window.Webamp({
    __customMediaClass: MaMedia,
    __customMiddlewares: [maMiddleware],
    initialSkin: CFG.skin ? { url: CFG.skin } : undefined,
    enableHotkeys: false,
    windowLayout: {
      main: { position: { top: 0, left: 0 } },
      equalizer: { position: { top: 116, left: 0 } },
      playlist: { position: { top: 232, left: 0 }, size: { extraHeight: playlistExtra, extraWidth: 0 } },
    },
  });
  bridge.webamp = webamp;
  bridge.store = webamp.store;
  window.maWinamp = bridge; // for debugging from the console
  webamp.onClose(() => location.reload());

  webamp.renderWhenReady(document.getElementById("app")).then(() => {
    // Let Webamp centre the windows first, then pin them
    setTimeout(() => { bridge.layoutLocked = true; }, 1000);
  });

  setInterval(() => {
    if (bridge.media && isPlaying()) bridge.media.emit("timeupdate");
  }, 250);

  if (!CFG.token) {
    status("No Music Assistant token set: run  odroid-ha-install --configure", true);
    return;
  }
  const ma = new MusicAssistant(CFG.maUrl, CFG.token);
  bridge.ma = ma;
  ma.eventHandlers.push(onEvent);
  ma.onReady = () => fullSync().catch(report);
  ma.connect();
})();

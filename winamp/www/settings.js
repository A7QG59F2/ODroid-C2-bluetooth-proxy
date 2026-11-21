// The Settings screen: a full-screen page with everything Webamp keeps in its
// small menus (right-click, the O/I/V buttons, the playlist's ADD/REM/SEL/
// MISC/LIST buttons, EQ Presets), which can't be used by touch. Those buttons
// open this screen instead (app.js), at the matching section.
import { $, el, sheet, ask, toast } from "./ui.js";
import { prefs } from "./milkdrop.js";

// Winamp's built-in equalizer presets (as in Webamp): 60 Hz … 16 kHz, preamp;
// values 1–64, 33 = 0 dB.
const EQ_PRESETS = [
  ["Flat", 33, 33, 33, 33, 33, 33, 33, 33, 33, 33, 33],
  ["Classical", 33, 33, 33, 33, 33, 33, 20, 20, 20, 16, 33], ["Club", 33, 33, 38, 42, 42, 42, 38, 33, 33, 33, 33],
  ["Dance", 48, 44, 36, 32, 32, 22, 20, 20, 32, 32, 33],
  ["Laptop speakers/headphones", 40, 50, 41, 26, 28, 35, 40, 48, 53, 56, 33],
  ["Large hall", 49, 49, 42, 42, 33, 24, 24, 24, 33, 33, 33], ["Party", 44, 44, 33, 33, 33, 33, 33, 33, 44, 44, 33],
  ["Pop", 29, 40, 44, 45, 41, 30, 28, 28, 29, 29, 33], ["Reggae", 33, 33, 31, 22, 33, 43, 43, 33, 33, 33, 33],
  ["Rock", 45, 40, 23, 19, 26, 39, 47, 50, 50, 50, 33], ["Soft", 40, 35, 30, 28, 30, 39, 46, 48, 50, 52, 33],
  ["Ska", 28, 24, 25, 31, 39, 42, 47, 48, 50, 48, 33], ["Full Bass", 48, 48, 48, 42, 35, 25, 18, 15, 14, 14, 33],
  ["Soft Rock", 39, 39, 36, 31, 25, 23, 26, 31, 37, 47, 33], ["Full Treble", 16, 16, 16, 25, 37, 50, 58, 58, 58, 60, 33],
  ["Full Bass & Treble", 44, 42, 33, 20, 24, 35, 46, 50, 52, 52, 33], ["Live", 24, 33, 39, 41, 42, 42, 39, 37, 37, 36, 33],
  ["Techno", 45, 42, 33, 23, 24, 33, 45, 48, 48, 47, 33],
];
const EQ_BANDS = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000];
const toSlider = (v) => Math.round(((v - 1) / 63) * 100);
const VIS_STYLES = ["BAR", "OSCILLOSCOPE", "NONE"];

export const SECTIONS = [
  ["playback", "Playback"], ["playlist", "Playlist"], ["sound", "Sound & EQ"],
  ["look", "Skin & look"], ["visualizer", "Visualizer"],
];

export function initSettings({ webamp, bridge, fire, fullVis, skins, skinKey, openLibrary, addTo, itemsOf }) {
  const store = webamp.store;
  const state = () => store.getState();
  let section = "playback";

  // ── Building blocks ─────────────────────────────────────────────────────
  // Segmented choice: [label, value] pairs; current() → value
  const seg = (pairs, current, pick) => {
    const box = el("div", { className: "seg" });
    const draw = () => box.replaceChildren(...pairs.map(([label, v]) =>
      el("button", { type: "button", textContent: label, className: current() === v ? "on" : "",
        onclick: async () => { await pick(v); draw(); } })));
    draw();
    return box;
  };
  const btn = (label, onclick, cls = "") => el("button", { type: "button", textContent: label, onclick, className: cls });
  const row = (label, ...controls) => el("div", { className: "srow" },
    el("div", { className: "slabel", textContent: label }), el("div", { className: "sctl" }, ...controls));
  const grid = (...buttons) => el("div", { className: "sgrid" }, ...buttons);
  const hint = (text, cls = "") => el("p", { className: `hint ${cls}`, textContent: text });
  const selected = () => {
    const st = state();
    return st.playlist.trackOrder.filter((id) => st.playlist.selectedTracks.includes(id));
  };
  const redraw = () => show(section);

  // ── Sections ────────────────────────────────────────────────────────────
  const build = {
    playback: () => [
      row("", grid(
        btn("⏮ Previous", () => fire("previous"), "big"), btn("▶ Play", () => fire("play"), "big"),
        btn("⏸ Pause", () => fire("pause"), "big"), btn("⏹ Stop", () => fire("stop"), "big"),
        btn("⏭ Next", () => fire("next"), "big"))),
      row("Skip", grid(btn("−30 s", () => seekBy(-30)), btn("−10 s", () => seekBy(-10)),
        btn("+10 s", () => seekBy(10)), btn("+30 s", () => seekBy(30)))),
      row("Jump", grid(btn("Start of the list", () => {
        const first = bridge.items[0];
        if (first) fire("play_index", { item: first.id });
      }))),
      row("Repeat", seg([["Off", "off"], ["All", "all"], ["One track", "one"]], () => bridge.repeat,
        (v) => { bridge.repeat = v; return fire("repeat", { mode: v }); })),
      row("Shuffle", seg([["Off", false], ["On", true]], () => !!state().media.shuffle,
        (v) => fire("shuffle", { enabled: v }))),
      row("Time shows", seg([["Elapsed", "ELAPSED"], ["Remaining", "REMAINING"]], () => state().media.timeMode,
        (v) => { if (state().media.timeMode !== v) store.dispatch({ type: "TOGGLE_TIME_MODE" }); })),
    ],

    playlist: () => {
      const n = selected().length;
      return [
        hint("In the playlist: drag to scroll, tap to select, double-tap to play, hold a track for its menu, " +
          "drag ≡ to move it, + to add it to a Music Assistant playlist."),
        row("Add", grid(
          btn("Library…", () => { close(); openLibrary(); }),
          btn("Stream URL…", async () => {
            const url = await ask("Stream or file URL to add to the queue:");
            if (url) fire("play_media", { uri: url, option: "add" });
          }))),
        row(`Select (${n} selected)`, grid(
          btn("All", () => { store.dispatch({ type: "SELECT_ALL" }); redraw(); }),
          btn("None", () => { store.dispatch({ type: "SELECT_ZERO" }); redraw(); }),
          btn("Invert", () => { store.dispatch({ type: "INVERT_SELECTION" }); redraw(); }))),
        row("Selected tracks", grid(
          btn("Add to playlist…", () => {
            const items = itemsOf(selected()).filter((it) => it.uri);
            if (!items.length) return toast("Select some tracks first");
            addTo(items);
          }),
          btn("Remove from queue", () => {
            const ids = selected();
            if (!ids.length) return toast("Select some tracks first");
            store.dispatch({ type: "REMOVE_TRACKS", ids });   // → Music Assistant
            toast(`Removed ${ids.length}`);
          }, "danger"),
          btn("Keep only these", () => {
            const keep = new Set(selected());
            if (!keep.size) return toast("Select some tracks first");
            const ids = state().playlist.trackOrder.filter((id) => !keep.has(id));
            if (ids.length) store.dispatch({ type: "REMOVE_TRACKS", ids });
          }, "danger"))),
        row("Whole queue", grid(
          btn("Save as playlist…", async () => {
            const name = await ask("Save the queue as a Music Assistant playlist named:");
            if (name) fire("save_queue", { name }).then(() => toast(`Saved as “${name}”`));
          }),
          btn("Shuffle it", () => fire("shuffle", { enabled: true })),
          btn("Clear queue…", () => sheet("Clear the whole queue?", [
            { label: "Yes, clear it", danger: true, onClick: () => fire("clear") },
          ]), "danger"))),
      ];
    },

    sound: () => {
      const vol = el("input", { type: "range", min: 0, max: 100, step: 1, value: state().media.volume, className: "range" });
      const volText = el("span", { className: "val", textContent: `${vol.value}%` });
      vol.oninput = () => { volText.textContent = `${vol.value}%`; store.dispatch({ type: "SET_VOLUME", volume: Number(vol.value) }); };
      const bal = el("input", { type: "range", min: -100, max: 100, step: 5, value: bridge.sound.balance || 0, className: "range" });
      const balText = el("span", { className: "val" });
      const showBal = () => {
        const b = Number(bal.value);
        balText.textContent = b === 0 ? "Center" : b < 0 ? `${-b}% left` : `${b}% right`;
      };
      showBal();
      bal.oninput = showBal;
      bal.onchange = () => store.dispatch({ type: "SET_BALANCE", balance: Number(bal.value) });
      return [
        row("Volume", vol, volText),
        row("Balance", bal, balText, btn("Center", () => {
          bal.value = 0; showBal(); store.dispatch({ type: "SET_BALANCE", balance: 0 });
        })),
        row("Channels", seg([["Stereo", false], ["Mono", true]], () => !!bridge.sound.mono, (v) => bridge.setMono(v))),
        row("Equalizer", seg([["Off", false], ["On", true]], () => !!state().equalizer.on,
          (v) => store.dispatch({ type: v ? "SET_EQ_ON" : "SET_EQ_OFF" }))),
        row("EQ preset", grid(...EQ_PRESETS.map((p) => btn(p[0], () => applyPreset(p))))),
        hint("Balance, mono and the equalizer are filters in the player's DSP settings in Music Assistant."),
      ];
    },

    look: () => {
      let cur = "";
      try { cur = localStorage.getItem(skinKey) || ""; } catch { /* */ }
      const isBase = !cur || cur === "base" || !skins.some((s) => s.url === cur);
      return [
        row("Skin", grid(
          btn("Base skin", () => {
            store.dispatch({ type: "LOAD_DEFAULT_SKIN" });
            try { localStorage.setItem(skinKey, "base"); } catch { /* */ }
            redraw();
          }, isBase ? "on" : ""),
          ...skins.map((sk) => btn(sk.name, () => {
            webamp.setSkinFromUrl(sk.url);
            try { localStorage.setItem(skinKey, sk.url); } catch { /* */ }
            redraw();
          }, sk.url === cur ? "on" : "")))),
        hint(skins.length ? "" : "No extra skins installed yet. ") ,
        hint("More skins: copy .wsz files to /etc/odroid-ha/winamp-skins on the Odroid, or list their URLs " +
          "in WINAMP_SKIN_URLS (skins.webamp.org has thousands)."),
        row("Small visualizer", seg([["Bars", "BAR"], ["Scope", "OSCILLOSCOPE"], ["Off", "NONE"]],
          () => VIS_STYLES[state().display.visualizerStyle] || "BAR",
          (v) => {
            for (let i = 0; i < 3 && VIS_STYLES[state().display.visualizerStyle] !== v; i++) {
              store.dispatch({ type: "TOGGLE_VISUALIZER_STYLE" });
            }
          })),
      ];
    },

    visualizer: () => {
      const list = el("div", { className: "slist" }, el("div", { className: "hint", textContent: "Loading presets…" }));
      fullVis.presetNames().then((names) => {
        list.replaceChildren(...names.map((n) => el("button", {
          type: "button", className: fullVis.isSlow(n) ? "slow" : "",
          textContent: n + (fullVis.isSlow(n) ? "  (skipped: too slow)" : ""),
          onclick: () => { prefs.mode = "milkdrop"; prefs.save(); close(); fullVis.open(n); },
        })));
        if (!names.length) list.replaceChildren(hint(fullVis.error || "No presets.", "err"));
      });
      return [
        row("", grid(btn("Open full screen", () => { close(); fullVis.open(); }, "big"))),
        row("Style", seg([["Milkdrop", "milkdrop"], ["Bars", "bars"], ["Scope", "scope"]], () => prefs.mode,
          (v) => { prefs.mode = v; prefs.save(); })),
        row("Change preset", seg([["Never", 0], ["15 s", 15], ["30 s", 30], ["1 min", 60], ["2 min", 120]],
          () => prefs.cycle, (v) => { prefs.cycle = v; prefs.save(); })),
        row("Milkdrop size", seg([["Small (fastest)", "low"], ["Medium", "medium"], ["Large", "high"]],
          () => prefs.quality, (v) => { prefs.quality = v; prefs.save(); })),
        row("Skip presets under", seg([["Off", 0], ["3 fps", 3], ["5 fps", 5], ["8 fps", 8]],
          () => prefs.minFps, (v) => { prefs.minFps = v; prefs.save(); })),
        row("Show speed", seg([["Off", false], ["On", true]], () => prefs.showFps,
          (v) => { prefs.showFps = v; prefs.save(); })),
        row("Skipped presets", grid(btn(`Try all ${fullVis.slowCount()} again`, () => { fullVis.forgetSlow(); redraw(); }))),
        fullVis.error ? hint(fullVis.error, "err") : null,
        row("Milkdrop preset (tap to play it)", list),
      ];
    },
  };

  function show(name) {
    section = build[name] ? name : "playback";
    document.querySelectorAll("#setnav button").forEach((b) => b.classList.toggle("on", b.dataset.s === section));
    const body = $("#setbody");
    body.replaceChildren(el("h2", { textContent: SECTIONS.find((s) => s[0] === section)[1] }),
      ...build[section]().filter(Boolean));
    body.scrollTop = 0;
  }

  function applyPreset(p) {
    const vals = p.slice(1);
    EQ_BANDS.forEach((b, i) => store.dispatch({ type: "SET_BAND_VALUE", band: b, value: toSlider(vals[i]) }));
    store.dispatch({ type: "SET_BAND_VALUE", band: "preamp", value: toSlider(vals[10]) });
    if (!state().equalizer.on) store.dispatch({ type: "SET_EQ_ON" });
    toast(`Equalizer: ${p[0]}`);
    redraw();
  }
  function seekBy(sec) {
    const c = bridge.current;
    if (!c?.duration) return;
    const pos = Math.max(0, Math.min(c.duration - 1, Math.round(bridge.elapsedNow() + sec)));
    bridge.setElapsed(pos);
    fire("seek", { position: pos });
  }

  $("#setnav").replaceChildren(...SECTIONS.map(([key, label]) => {
    const b = el("button", { type: "button", textContent: label, onclick: () => show(key) });
    b.dataset.s = key;
    return b;
  }));

  const open = (name = section) => { show(name); $("#settings").classList.add("open"); };
  const close = () => $("#settings").classList.remove("open");
  $("#setclose").onclick = close;
  return { open, close };
}

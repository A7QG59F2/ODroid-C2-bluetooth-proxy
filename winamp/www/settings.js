// Settings: everything Webamp only offers through right-click menus (which
// don't work on a touch screen), plus Music Assistant extras.
import { $, el, sheet, ask, toast } from "./ui.js";
import { prefs } from "./milkdrop.js";

// Winamp's built-in equalizer presets (as in Webamp): 60 Hz … 16 kHz, preamp;
// values 1–64, 33 = 0 dB.
const EQ_PRESETS = [
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

export function initSettings({ webamp, bridge, fire, fullVis, skins, skinKey }) {
  const store = webamp.store;
  const state = () => store.getState();

  // Segmented buttons: [label, value] pairs, current() → value
  const seg = (pairs, current, pick) => {
    const box = el("div", { className: "seg" });
    const draw = () => box.replaceChildren(...pairs.map(([label, v]) =>
      el("button", { type: "button", textContent: label, className: current() === v ? "on" : "",
        onclick: async () => { await pick(v); draw(); } })));
    draw();
    return box;
  };
  const row = (label, ...controls) => el("div", { className: "srow" }, el("div", { className: "slabel", textContent: label }), ...controls);
  const btn = (label, onclick, cls = "") => el("button", { type: "button", textContent: label, onclick, className: cls });

  function build() {
    const body = $("#setbody");
    body.replaceChildren();
    const section = (title) => body.appendChild(el("section", {}, el("h2", { textContent: title })));

    // ── Look ──
    let s = section("Look");
    const curSkin = (() => { try { return localStorage.getItem(skinKey) || ""; } catch { return ""; } })();
    s.append(row("Skin", btn(skinName(curSkin), () => sheet("Skin", [
      { label: "Base skin (Winamp classic)", onClick: () => {
        store.dispatch({ type: "LOAD_DEFAULT_SKIN" });
        try { localStorage.setItem(skinKey, "base"); } catch { /* */ }
        build();
      } },
      ...skins.map((sk) => ({ label: sk.name, onClick: () => {
        webamp.setSkinFromUrl(sk.url);
        try { localStorage.setItem(skinKey, sk.url); } catch { /* */ }
        build();
      } })),
    ], { empty: "No skins installed." }))));
    s.append(el("p", { className: "hint", textContent:
      "More skins: put .wsz files in /etc/odroid-ha/winamp-skins on the Odroid, or list their URLs in WINAMP_SKIN_URLS." }));
    s.append(row("Small visualizer", seg([["Bars", "BAR"], ["Scope", "OSCILLOSCOPE"], ["Off", "NONE"]],
      () => ["BAR", "OSCILLOSCOPE", "NONE"][state().display.visualizerStyle] || "BAR",
      (v) => {
        for (let i = 0; i < 3 && (["BAR", "OSCILLOSCOPE", "NONE"][state().display.visualizerStyle]) !== v; i++) {
          store.dispatch({ type: "TOGGLE_VISUALIZER_STYLE" });
        }
      })));
    s.append(row("Time shows", seg([["Elapsed", "ELAPSED"], ["Remaining", "REMAINING"]],
      () => state().media.timeMode,
      (v) => { if (state().media.timeMode !== v) store.dispatch({ type: "TOGGLE_TIME_MODE" }); })));

    // ── Sound (Music Assistant's DSP for this player) ──
    s = section("Sound");
    s.append(row("Equalizer preset", btn("Choose…", () => sheet("Equalizer preset", [
      { label: "Flat (all 0 dB)", onClick: () => applyPreset(["Flat", ...Array(11).fill(33)]) },
      ...EQ_PRESETS.map((p) => ({ label: p[0], onClick: () => applyPreset(p) })),
    ]))));
    const bal = el("input", { type: "range", min: -100, max: 100, step: 5, value: bridge.sound.balance || 0, className: "range" });
    const balText = el("span", { className: "val" });
    const showBal = () => {
      const b = Number(bal.value);
      balText.textContent = b === 0 ? "Center" : b < 0 ? `${-b}% left` : `${b}% right`;
    };
    showBal();
    bal.oninput = showBal;
    bal.onchange = () => setBalance(Number(bal.value));
    s.append(row("Balance", bal, balText, btn("Center", () => { bal.value = 0; showBal(); setBalance(0); })));
    s.append(row("Channels", seg([["Stereo", false], ["Mono", true]], () => !!bridge.sound.mono,
      (v) => bridge.setMono(v))));
    s.append(el("p", { className: "hint", textContent:
      "The fader on the main window and tapping MONO / STEREO there do the same." }));

    // ── Playback ──
    s = section("Playback");
    s.append(row("Repeat", seg([["Off", "off"], ["All", "all"], ["One", "one"]], () => bridge.repeat,
      (v) => fire("repeat", { mode: v }))));
    s.append(row("Shuffle", seg([["Off", false], ["On", true]], () => !!state().media.shuffle,
      (v) => fire("shuffle", { enabled: v }))));
    s.append(row("Skip", btn("−10 s", () => seekBy(-10)), btn("+10 s", () => seekBy(10)), btn("+30 s", () => seekBy(30))));

    // ── Queue ──
    s = section("Queue (Music Assistant)");
    s.append(row("", btn("Save as playlist…", async () => {
      const name = await ask("Save the queue as a Music Assistant playlist named:");
      if (name) fire("save_queue", { name }).then(() => toast(`Saved as “${name}”`));
    }), btn("Add stream URL…", async () => {
      const url = await ask("Stream or file URL to add to the queue:");
      if (url) fire("play_media", { uri: url, option: "add" });
    }), btn("Clear queue", () => sheet("Clear the whole queue?", [
      { label: "Yes, clear it", danger: true, onClick: () => fire("clear") },
    ]), "danger")));
    s.append(el("p", { className: "hint", textContent:
      "In the playlist: drag to scroll, double-tap to play, hold for a track's menu, drag ≡ to move, + to add to a playlist." }));

    // ── Full-screen visualizer ──
    s = section("Full-screen visualizer");
    s.append(row("Style", seg([["Milkdrop", "milkdrop"], ["Bars", "bars"], ["Scope", "scope"]], () => prefs.mode,
      (v) => { prefs.mode = v; prefs.save(); })));
    s.append(row("Change preset", seg([["Never", 0], ["15 s", 15], ["30 s", 30], ["1 min", 60], ["2 min", 120]],
      () => prefs.cycle, (v) => { prefs.cycle = v; prefs.save(); })));
    s.append(row("Milkdrop size", seg([["Small (fastest)", "low"], ["Medium", "medium"], ["Large", "high"]],
      () => prefs.quality, (v) => { prefs.quality = v; prefs.save(); })));
    s.append(row("Skip presets under", seg([["Off", 0], ["3 fps", 3], ["5 fps", 5], ["8 fps", 8]],
      () => prefs.minFps, (v) => { prefs.minFps = v; prefs.save(); })));
    s.append(row("Show speed", seg([["Off", false], ["On", true]], () => prefs.showFps,
      (v) => { prefs.showFps = v; prefs.save(); })));
    s.append(row("Milkdrop preset", btn("Choose…", () => sheet("Milkdrop preset",
      fullVis.presetNames().then((names) => names.map((n) => ({
        label: n, sub: fullVis.isSlow(n) ? "skipped: too slow here" : "",
        onClick: () => { prefs.mode = "milkdrop"; prefs.save(); close(); fullVis.open(n); },
      }))))),
      btn(`Retry skipped (${fullVis.slowCount()})`, () => { fullVis.forgetSlow(); build(); })));
    if (fullVis.error) s.append(el("p", { className: "hint err", textContent: fullVis.error }));
  }

  function skinName(url) {
    if (!url || url === "base") return "Base skin";
    return skins.find((s) => s.url === url)?.name || "Base skin";
  }
  function applyPreset(p) {
    const vals = p.slice(1);
    EQ_BANDS.forEach((b, i) => store.dispatch({ type: "SET_BAND_VALUE", band: b, value: toSlider(vals[i]) }));
    store.dispatch({ type: "SET_BAND_VALUE", band: "preamp", value: toSlider(vals[10]) });
    if (!state().equalizer.on) store.dispatch({ type: "SET_EQ_ON" });
    toast(`Equalizer: ${p[0]}`);
  }
  function setBalance(b) {
    // Through Webamp, so its fader moves too (and MAMedia sends it on)
    store.dispatch({ type: "SET_BALANCE", balance: b });
  }
  function seekBy(sec) {
    const c = bridge.current;
    if (!c?.duration) return;
    const pos = Math.max(0, Math.min(c.duration - 1, Math.round(bridge.elapsedNow() + sec)));
    bridge.setElapsed(pos);
    fire("seek", { position: pos });
  }

  const open = () => { build(); $("#settings").classList.add("open"); };
  const close = () => $("#settings").classList.remove("open");
  $("#setclose").onclick = close;
  $("#settings").onclick = (e) => { if (e.target.id === "settings") close(); };
  return { open, close };
}

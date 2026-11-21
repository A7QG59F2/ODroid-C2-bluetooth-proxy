// Full-screen visualizer: Milkdrop (butterchurn, the engine Webamp uses),
// fed with Squeezelite's samples, with Winamp-style bars as the fallback.
//
// The C2 has no WebGL 2 on its GPU, so Milkdrop runs on the CPU (Chromium's
// SwiftShader, allowed by the kiosk's --enable-unsafe-swiftshader). That
// manages roughly 5–10 frames a second at a small size, scaled up to the
// screen. Presets that can't keep up are noted and skipped from then on.
import { $, el } from "./ui.js";

const PREFS_KEY = "odroid-milkdrop";
const SLOW_KEY = "odroid-milkdrop-slow";
const SIZES = { low: [192, 120], medium: [288, 180], high: [400, 250] };

function load(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
}
function save(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ }
}

export const prefs = {
  mode: "milkdrop",      // milkdrop | bars | scope
  quality: "low",        // low | medium | high (render size)
  cycle: 30,             // seconds per preset, 0 = stay
  minFps: 5,             // presets slower than this are skipped
  showFps: false,
  ...load(PREFS_KEY, {}),
  save() { const { save: _s, ...p } = this; save(PREFS_KEY, p); },
};

function loadScript(src) {
  return new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${src}"]`)) return resolve();
    document.head.append(el("script", { src, onload: resolve, onerror: () => reject(new Error(`${src} missing`)) }));
  });
}

export function initFullVis({ vis, bridge }) {
  const root = $("#fullvis");
  const canvas = $("#fvcanvas");          // Milkdrop (WebGL)
  const bars = $("#fvbars");              // bars / scope (2D)
  const bar = $("#fvbar");                // the controls strip
  const stage = $("#stage");
  const slow = new Set(load(SLOW_KEY, []));
  const st = {
    open: false, raf: 0, last: 0, viz: null, presets: null, names: [], idx: 0,
    loaded: 0, frames: 0, fps: 0, fpsT: 0, judgeFrom: 0, judgeFrames: 0,
    error: "", title: "", barsState: null, barTimer: 0,
  };
  const timeBytes = new Uint8Array(1024);

  // ── Milkdrop ────────────────────────────────────────────────────────────
  async function ensureMilkdrop() {
    if (st.viz) return true;
    if (st.error) return false;
    try {
      const probe = document.createElement("canvas").getContext("webgl2");
      if (!probe) throw new Error("Milkdrop needs WebGL 2, which this browser doesn't offer (the kiosk needs --enable-unsafe-swiftshader)");
      await loadScript("butterchurn.min.js");
      await loadScript("butterchurnPresets.min.js");
      const bc = window.butterchurn?.default || window.butterchurn;
      const packs = window.butterchurnPresets?.default || window.butterchurnPresets;
      st.presets = packs.getPresets();
      st.names = Object.keys(st.presets).sort(() => Math.random() - 0.5);
      const [w, h] = SIZES[prefs.quality] || SIZES.low;
      canvas.width = w;
      canvas.height = h;
      // The AudioContext only satisfies butterchurn's constructor: the samples
      // are handed to render() directly.
      const ac = new (window.AudioContext || window.webkitAudioContext)();
      st.viz = bc.createVisualizer(ac, canvas, {
        width: w, height: h, pixelRatio: 1, textureRatio: 1,
        meshWidth: 24, meshHeight: 18,
      });
      st.size = prefs.quality;
      st.idx = -1;
      next(0);
      return true;
    } catch (e) {
      st.error = e.message || String(e);
      return false;
    }
  }

  function playable() { return st.names.filter((n) => !slow.has(n)); }
  function next(blend = 2, step = 1) {
    if (!st.viz) return;
    const list = playable().length ? playable() : st.names;
    const cur = list.indexOf(st.names[st.idx]);
    const name = list[((cur < 0 ? -1 : cur) + step + list.length) % list.length];
    st.idx = st.names.indexOf(name);
    st.viz.loadPreset(st.presets[name], blend);
    st.loaded = performance.now();
    // Judge its speed once the blend is over and its shaders are compiled
    st.judgeFrom = st.loaded + blend * 1000 + 1500;
    st.judgeFrames = 0;
    showName();
  }
  function choose(name) {
    if (!st.viz || !st.presets[name]) return;
    slow.delete(name);
    save(SLOW_KEY, [...slow]);
    st.idx = st.names.indexOf(name);
    st.viz.loadPreset(st.presets[name], 0);
    st.loaded = performance.now();
    st.judgeFrom = Infinity;      // picked by hand: don't skip it
    showName();
  }
  function showName() { $("#fvname").textContent = st.names[st.idx] || ""; }

  function renderMilkdrop(t) {
    vis.getByteTimeDomainData(timeBytes);
    st.viz.render({ audioLevels: { timeByteArray: timeBytes, timeByteArrayL: timeBytes, timeByteArrayR: timeBytes } });
    // Too slow for this board? Note it and move on.
    if (t > st.judgeFrom) {
      st.judgeFrames++;
      const secs = (t - st.judgeFrom) / 1000;
      if (secs >= 3) {
        const fps = st.judgeFrames / secs;
        st.judgeFrom = Infinity;
        if (fps < prefs.minFps) {
          slow.add(st.names[st.idx]);
          save(SLOW_KEY, [...slow]);
          next(0);
          return;
        }
      }
    }
    if (prefs.cycle > 0 && t - st.loaded > prefs.cycle * 1000) next();
  }

  // ── Bars and oscilloscope (2D, in the skin's visualizer colors) ─────────
  const N = 2048;
  const raw = new Uint8Array(N), re = new Float32Array(N), im = new Float32Array(N);
  function fft() {
    for (let i = 1, j = 0; i < N; i++) {
      let bit = N >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
    }
    for (let len = 2; len <= N; len <<= 1) {
      const ang = (-2 * Math.PI) / len, wr = Math.cos(ang), wi = Math.sin(ang);
      for (let i = 0; i < N; i += len) {
        let cr = 1, ci = 0;
        for (let k = 0; k < len / 2; k++) {
          const a = i + k, b = a + len / 2;
          const tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr;
          re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti;
          const nr = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = nr;
        }
      }
    }
  }
  function renderBars() {
    const g = bars.getContext("2d"), W = bars.width, H = bars.height;
    const c = bridge.webamp?.store?.getState().display?.skinColors;
    const col = c && c.length >= 24 ? c : null;
    g.fillStyle = col ? col[0] : "#000";
    g.fillRect(0, 0, W, H);
    vis.getByteTimeDomainData(raw);
    if (prefs.mode === "scope") {
      g.fillStyle = col ? col[21] : "#fff";
      let prev = null;
      for (let x = 0; x < W; x++) {
        const y = Math.round(H / 2 + ((raw[Math.floor((x * N) / W)] - 128) / 128) * (H / 2 - 1));
        const a = prev ?? y;
        g.fillRect(x, Math.min(a, y), 1, Math.abs(a - y) + 1);
        prev = y;
      }
      return;
    }
    const nb = 48;
    const s = st.barsState ||= { levels: new Float32Array(nb), peaks: new Float32Array(nb), hold: new Float32Array(nb) };
    for (let i = 0; i < N; i++) { re[i] = ((raw[i] - 128) / 128) * (0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (N - 1))); im[i] = 0; }
    fft();
    const rate = vis.rate || 48000, binHz = rate / N, lo = 40, hi = Math.min(16000, rate / 2);
    const slot = Math.floor(W / nb), bw = Math.max(1, slot - 1), x0 = Math.floor((W - slot * nb) / 2);
    for (let b = 0; b < nb; b++) {
      const f1 = lo * (hi / lo) ** (b / nb), f2 = lo * (hi / lo) ** ((b + 1) / nb);
      const i1 = Math.max(1, Math.floor(f1 / binHz)), i2 = Math.max(i1 + 1, Math.ceil(f2 / binHz));
      let m = 0;
      for (let i = i1; i < i2 && i < N / 2; i++) m = Math.max(m, Math.hypot(re[i], im[i]));
      const db = 20 * Math.log10(m / (N / 4) + 1e-9) + 6 * Math.log2(f1 / 1000 + 1);
      const v = Math.min(1, Math.max(0, (db + 60) / 60));
      s.levels[b] = v > s.levels[b] ? v : Math.max(v, s.levels[b] - 0.04);
      if (s.levels[b] >= s.peaks[b]) { s.peaks[b] = s.levels[b]; s.hold[b] = 12; }
      else if (s.hold[b] > 0) s.hold[b]--;
      else s.peaks[b] = Math.max(0, s.peaks[b] - 0.015);
      const h = Math.round(s.levels[b] * (H - 2)), x = x0 + b * slot;
      for (let y = 0; y < h; y++) {
        g.fillStyle = col ? col[2 + Math.min(15, Math.floor((1 - y / H) * 16))] : `hsl(${120 - (y / H) * 120},100%,45%)`;
        g.fillRect(x, H - 1 - y, bw, 1);
      }
      if (s.peaks[b] > 0.01) {
        g.fillStyle = col ? col[23] : "#999";
        g.fillRect(x, H - 1 - Math.round(s.peaks[b] * (H - 2)), bw, 1);
      }
    }
  }

  // ── Frame loop ──────────────────────────────────────────────────────────
  function frame(t) {
    st.raf = requestAnimationFrame(frame);
    const milk = prefs.mode === "milkdrop" && st.viz;
    if (!milk && t - st.last < 33) return;          // bars: ~30 fps is plenty
    st.last = t;
    if (milk) renderMilkdrop(t); else renderBars();
    st.frames++;
    if (t - st.fpsT >= 1000) {
      st.fps = (st.frames * 1000) / (t - st.fpsT);
      st.frames = 0;
      st.fpsT = t;
      $("#fvfps").textContent = prefs.showFps ? `${st.fps.toFixed(1)} fps` : "";
    }
    const c = bridge.current;
    const title = c ? [c.artist, c.title || c.name].filter(Boolean).join(" – ") : "";
    if (title !== st.title) {
      st.title = title;
      $("#fvtitle").textContent = title;
      if (milk && title) try { st.viz.launchSongTitleAnim(title); } catch { /* optional */ }
    }
  }

  async function applyMode() {
    let milk = prefs.mode === "milkdrop";
    if (milk && st.viz && st.size !== prefs.quality) {     // new render size
      const [w, h] = SIZES[prefs.quality] || SIZES.low;
      canvas.width = w; canvas.height = h;
      st.viz.setRendererSize(w, h);
      st.size = prefs.quality;
    }
    if (milk && !(await ensureMilkdrop())) {
      milk = false;
      $("#fvnote").textContent = st.error;
    } else $("#fvnote").textContent = "";
    canvas.style.display = milk ? "block" : "none";
    bars.style.display = milk ? "none" : "block";
    $("#fvprev").style.visibility = $("#fvnext").style.visibility = milk ? "visible" : "hidden";
    $("#fvname").style.display = milk ? "" : "none";
    if (!milk) {
      bars.width = Math.floor(window.innerWidth / 8);
      bars.height = Math.floor(window.innerHeight / 8);
    }
    $("#fvmode").textContent = { milkdrop: "Milkdrop", bars: "Bars", scope: "Scope" }[prefs.mode];
  }

  function showBar() {
    bar.classList.add("show");
    clearTimeout(st.barTimer);
    st.barTimer = setTimeout(() => bar.classList.remove("show"), 5000);
  }

  async function open(presetName) {
    root.classList.add("open");
    stage.style.visibility = "hidden";     // nothing to paint behind it
    st.open = true;
    await applyMode();
    if (presetName) choose(presetName);
    showBar();
    st.fpsT = performance.now();
    st.frames = 0;
    cancelAnimationFrame(st.raf);
    st.raf = requestAnimationFrame(frame);
  }
  function close() {
    root.classList.remove("open");
    stage.style.visibility = "";
    st.open = false;
    cancelAnimationFrame(st.raf);
    st.raf = 0;
  }

  root.addEventListener("click", (e) => {
    if (e.target.closest("#fvbar")) return;
    if (bar.classList.contains("show")) bar.classList.remove("show"); else showBar();
  });
  $("#fvclose").onclick = close;
  $("#fvprev").onclick = () => { next(0, -1); showBar(); };
  $("#fvnext").onclick = () => { next(0, 1); showBar(); };
  $("#fvmode").onclick = async () => {
    const order = ["milkdrop", "bars", "scope"];
    prefs.mode = order[(order.indexOf(prefs.mode) + 1) % order.length];
    prefs.save();
    await applyMode();
    showBar();
  };
  document.addEventListener("visibilitychange", () => {
    if (!st.open) return;
    cancelAnimationFrame(st.raf);
    st.raf = document.hidden ? 0 : requestAnimationFrame(frame);
  });

  return {
    open, close,
    async presetNames() { await ensureMilkdrop(); return st.names.slice().sort((a, b) => a.localeCompare(b)); },
    isSlow: (n) => slow.has(n),
    forgetSlow() { slow.clear(); save(SLOW_KEY, []); },
    slowCount: () => slow.size,
    get error() { return st.error; },
    applyMode,
  };
}

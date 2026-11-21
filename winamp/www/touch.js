// Touch layer over Webamp's playlist.
//
// Webamp treats a drag on a track as "move these tracks", so a finger can't
// scroll the list. This layer sits on top of the track list and takes the
// touches itself:
//   drag anywhere        scroll
//   tap                  select   (double tap: play)
//   hold                 the track's menu (play, add to playlist, remove)
//   ≡ handle, drag       move the track (Music Assistant's queue order)
//   + button             add the track to a Music Assistant playlist
// The rows line up with Webamp's own (one per visible .track-cell) and are
// redrawn whenever Webamp's state or layout changes.
import { el } from "./ui.js";

export function initTouchPlaylist({ webamp, itemAt, onPlay, onAddTo, onMenu, onMove }) {
  const store = webamp.store;
  const layer = el("div", { id: "pltouch" });
  const marker = el("div", { className: "plmarker" });
  document.body.append(layer);
  let rows = [];          // overlay row elements, in visible order
  let geo = null;         // { top, rowH, offset, maxOff, count, visible }
  let sig = "";
  let g = null;           // the gesture in progress
  let lastTap = { index: -1, t: 0 };

  // ── Webamp's scroll position (0–100 %) ⇄ first visible row ──────────────
  const setOffset = (off) => {
    if (!geo) return;
    const o = Math.max(0, Math.min(geo.maxOff, Math.round(off)));
    if (o === geo.offset) return;
    store.dispatch({ type: "SET_PLAYLIST_SCROLL_POSITION", position: geo.maxOff ? (100 * o) / geo.maxOff : 0 });
  };

  function layout() {
    raf = 0;
    const tracks = document.querySelector("#webamp .playlist-tracks");
    const titles = tracks?.querySelector(".playlist-track-titles");
    const cells = titles ? [...titles.querySelectorAll(".track-cell")] : [];
    if (!tracks || document.querySelector("#webamp #playlist-window.shade, #webamp #playlist-window-shade")) {
      layer.style.display = "none";
      geo = null;
      return;
    }
    const R = tracks.getBoundingClientRect();
    const st = store.getState();
    const count = st.playlist.trackOrder.length;
    const rowH = cells[0]?.getBoundingClientRect().height || R.height / 10 || 1;
    const visible = Math.max(1, Math.floor(R.height / rowH + 0.01));
    const maxOff = Math.max(0, count - visible);
    const offset = Math.round(((st.display.playlistScrollPosition || 0) / 100) * maxOff);
    const dur = tracks.querySelector(".playlist-track-durations")?.getBoundingClientRect();
    const color = st.display.skinPlaylistStyle?.normal || "#00ff00";
    const s = [R.left, R.top, R.width, R.height, rowH, offset, count, cells.length, dur?.left, color].join();
    geo = { top: R.top, rowH, offset, maxOff, count, visible };
    if (s === sig) return;
    sig = s;
    Object.assign(layer.style, {
      display: "block", left: `${R.left}px`, top: `${R.top}px`, width: `${R.width}px`, height: `${R.height}px`,
      color, fontSize: `${Math.round(rowH * 0.62)}px`,
    });
    const addRight = dur ? Math.max(0, R.right - dur.left) : 0;
    // A handful of rows: simply rebuilt
    layer.replaceChildren(...cells.map((c, i) => {
      const r = c.getBoundingClientRect();
      const row = el("div", { className: "plrow" },
        el("span", { className: "plhandle", textContent: "≡" }),
        el("span", { className: "pladd", textContent: "+" }));
      row.dataset.index = offset + i;
      row.style.cssText = `top:${r.top - R.top}px;height:${r.height}px;line-height:${r.height}px`;
      row.firstChild.style.width = `${Math.round(rowH)}px`;
      Object.assign(row.lastChild.style, { right: `${addRight}px`, width: `${Math.round(rowH)}px` });
      return row;
    }), marker);
    rows = [...layer.querySelectorAll(".plrow")];
  }
  let raf = 0;
  const schedule = () => { if (!raf) raf = requestAnimationFrame(layout); };
  store.subscribe(schedule);
  window.addEventListener("resize", schedule);
  schedule();

  // ── Gestures ────────────────────────────────────────────────────────────
  const indexAtY = (y) => geo ? geo.offset + Math.floor((y - geo.top) / geo.rowH) : -1;
  const MOVE_PX = 10, HOLD_MS = 600, DOUBLE_MS = 450;

  layer.addEventListener("pointerdown", (e) => {
    if (g || !geo) return;
    const row = e.target.closest(".plrow");
    const index = row ? Number(row.dataset.index) : -1;
    const kind = !row ? "scroll" : e.target.closest(".plhandle") ? "drag" : e.target.closest(".pladd") ? "add" : "tap";
    g = { id: e.pointerId, y0: e.clientY, off0: geo.offset, index, kind, moved: false, row };
    try { layer.setPointerCapture(e.pointerId); } catch { /* synthetic events */ }
    e.preventDefault();
    if (kind === "tap") {
      g.hold = setTimeout(() => {
        if (g && !g.moved && g.kind === "tap") { g.kind = "done"; onMenu(index); }
      }, HOLD_MS);
    }
    if (kind === "drag") {
      row.classList.add("dragging");
      g.target = index;
      showMarker(index, index);
    }
  });

  layer.addEventListener("pointermove", (e) => {
    if (!g || e.pointerId !== g.id || !geo) return;
    const dy = e.clientY - g.y0;
    if (!g.moved && Math.abs(dy) < MOVE_PX) return;
    g.moved = true;
    clearTimeout(g.hold);
    if (g.kind === "drag") {
      g.y = e.clientY;
      dragTo();
      autoScroll();
    } else if (g.kind !== "done") {
      g.kind = "scroll";
      setOffset(g.off0 - dy / geo.rowH);
    }
  });

  const end = (e) => {
    if (!g || e.pointerId !== g.id) return;
    const done = g;
    g = null;
    clearTimeout(done.hold);
    clearInterval(scrollTimer);
    scrollTimer = 0;
    marker.style.display = "none";
    done.row?.classList.remove("dragging");
    if (e.type === "pointercancel") return;
    if (done.kind === "drag") {
      if (done.target !== done.index) onMove(done.index, done.target);
    } else if (done.kind === "add" && !done.moved) {
      onAddTo(done.index);
    } else if (done.kind === "tap" && !done.moved && done.index >= 0 && done.index < geo.count) {
      const now = performance.now();
      if (lastTap.index === done.index && now - lastTap.t < DOUBLE_MS) {
        lastTap = { index: -1, t: 0 };
        onPlay(done.index);
      } else {
        lastTap = { index: done.index, t: now };
        store.dispatch({ type: "CLICKED_TRACK", index: done.index });
      }
    }
  };
  layer.addEventListener("pointerup", end);
  layer.addEventListener("pointercancel", end);

  // Moving a track: the marker shows where it will land; near the top or
  // bottom edge the list scrolls along.
  function dragTo() {
    if (!g || !geo) return;
    const t = Math.max(0, Math.min(geo.count - 1, indexAtY(g.y)));
    g.target = t;
    showMarker(g.index, t);
  }
  let scrollTimer = 0;
  function autoScroll() {
    if (scrollTimer) return;
    scrollTimer = setInterval(() => {
      if (!g || g.kind !== "drag" || !geo) return;
      const rel = (g.y - geo.top) / (geo.rowH * geo.visible);
      if (rel < 0.08) setOffset(geo.offset - 1);
      else if (rel > 0.92) setOffset(geo.offset + 1);
      else return;
      requestAnimationFrame(() => requestAnimationFrame(dragTo));
    }, 120);
  }
  function showMarker(from, to) {
    if (!geo) return;
    const vis = to - geo.offset;
    if (vis < 0 || vis >= geo.visible) { marker.style.display = "none"; return; }
    // Moving down lands below the target row, moving up above it
    const y = (vis + (to > from ? 1 : 0)) * geo.rowH;
    Object.assign(marker.style, { display: "block", top: `${Math.round(y - 2)}px` });
  }

  layer.addEventListener("wheel", (e) => {
    e.preventDefault();
    if (geo) setOffset(geo.offset + Math.sign(e.deltaY) * Math.max(1, Math.round(Math.abs(e.deltaY) / geo.rowH)));
  }, { passive: false });

  return { layout: schedule, itemAt };
}

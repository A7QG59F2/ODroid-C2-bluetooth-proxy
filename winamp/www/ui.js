// Touch-sized dialogs: a list sheet, a text prompt and a short toast.
// (Webamp's own right-click menus are unusable on a touch screen.)

export const $ = (s) => document.querySelector(s);

export function el(tag, props = {}, ...children) {
  const e = Object.assign(document.createElement(tag), props);
  for (const c of children) if (c != null) e.append(c);
  return e;
}

// A modal list. items: [{label, sub, onClick, danger}] — tapping one closes
// the sheet and runs onClick. Returns a close function.
export function sheet(title, items, { empty = "Nothing here." } = {}) {
  const ul = el("ul");
  const modal = el("div", { className: "modal open sheet" },
    el("div", { className: "box" },
      el("header", {}, el("div", { className: "title", textContent: title })),
      ul,
      el("footer", {}, el("button", { type: "button", textContent: "Close", onclick: () => close() }))));
  const close = () => modal.remove();
  modal.onclick = (e) => { if (e.target === modal) close(); };
  const fill = (list) => {
    ul.replaceChildren();
    if (!list.length) ul.append(el("li", { className: "empty", textContent: empty }));
    for (const it of list) {
      const li = el("li", { className: it.danger ? "danger" : "" },
        el("div", { className: "name", textContent: it.label },
          it.sub ? el("div", { className: "sub", textContent: it.sub }) : null));
      li.onclick = () => { close(); it.onClick?.(); };
      ul.append(li);
    }
  };
  if (items instanceof Promise) {
    ul.append(el("li", { className: "empty", textContent: "Loading…" }));
    items.then(fill, (e) => { ul.replaceChildren(el("li", { className: "empty", textContent: e.message })); });
  } else fill(items);
  document.body.append(modal);
  return close;
}

// A text prompt in the page (Onboard pops up for it, unlike a browser dialog).
export function ask(question, value = "") {
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

let toastTimer = 0;
export function toast(text) {
  let t = $("#toast");
  if (!t) document.body.append(t = el("div", { id: "toast" }));
  t.textContent = text;
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 2500);
}

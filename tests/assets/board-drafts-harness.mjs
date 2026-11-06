// Run a built bearings board's inline script under a minimal DOM shim, with a
// browser store and a simulated Lavish chrome that both outlive the run, so a
// rebuild-then-reload (or a refresh) can be asserted through the real template.
//
// Usage: node board-drafts-harness.mjs <built-board.html> <storage.json> [actions]
// The browser store is <storage.json>; the chrome's per-tab store (queued
// prompts and restored review state) is <storage.json>.session.json. Delete
// the session file to simulate a new tab. NO_STORAGE=1 makes localStorage throw
// like Lavish's sandboxed frame. Comma-separated actions run in order:
//   type            select the first option and type a note into every card
//   submit:<key>    submit that card's form
//   pick:<id>       tick a charted row's dispatch pick
//   dispatch        press the dispatch button
//   load            frame load: restore review state, then report queued anchors
//   send            the chrome sends every queued prompt, then reports anchors
// Prints { cards, storage, calls, queue, badges, bar, picks }.
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const [, , boardPath, storagePath, actionList = ""] = process.argv;
const html = readFileSync(boardPath, "utf8");
const sessionPath = storagePath + ".session.json";

class Node {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this.attributes = {};
    this._text = ""; this.hidden = false; this.disabled = false; this.innerHTML = "";
    this.parentNode = null; this.type = ""; this.name = ""; this.value = ""; this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      toggle: () => {}, contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() { return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text; }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(t, fn) { (this.listeners[t] ||= []).push(fn); }
  fire(t) { for (const fn of this.listeners[t] || []) fn({ preventDefault() {} }); }
  dispatchEvent(ev) { for (let n = this; n; n = ev.bubbles ? n.parentNode : null) for (const fn of n.listeners[ev.type] || []) fn(ev); return true; }
  matches(sel) {
    const checked = sel.endsWith(":checked");
    const base = checked ? sel.slice(0, -8) : sel;
    if (checked && !this.checked) return false;
    if (base.startsWith(".")) return this.className.split(/\s+/).includes(base.slice(1));
    const m = base.match(/^(\w+)(?:\[(\w+)=([\w-]+)\])?$/);
    return !!m && this.tagName === m[1] && (!m[2] || this[m[2]] === m[3]);
  }
  querySelectorAll(sel) {
    const out = [];
    const walk = (n) => { for (const c of n.children) { if (c.matches(sel)) out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

globalThis.Event = class { constructor(type, init = {}) { this.type = type; this.bubbles = !!init.bubbles; } };

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html.split('<script id="bearings-data" type="application/json">')[1].split("</script>")[0];
byId.set("bearings-data", dataNode);

// Stand-in selectors the simulated chrome reports: "card:<key>" or "bar".
const anchorFor = (el) => {
  const form = el && el.attributes && el.attributes["data-lavish-question"];
  return form && el.tagName === "form" ? "card:" + form : el === byId.get("bb-dispatch") ? "bar" : "";
};
globalThis.document = {
  createElement: (tag) => new Node(tag),
  getElementById: (id) => {
    if (!byId.has(id)) { const n = new Node("div"); new Node("div").appendChild(n); byId.set(id, n); }
    return byId.get(id);
  },
  querySelector: (sel) => {
    if (sel === "bar") return byId.get("bb-dispatch") || null;
    if (sel.startsWith("card:")) {
      return (byId.get("bb-call")?.querySelectorAll("form") || []).find((f) => anchorFor(f) === sel) || null;
    }
    return new Node("div");
  },
};

const store = existsSync(storagePath) ? JSON.parse(readFileSync(storagePath, "utf8")) : {};
const session = existsSync(sessionPath) ? JSON.parse(readFileSync(sessionPath, "utf8")) : { queue: {}, review: [] };
const listeners = [];
const calls = [];
const timers = [];
const parent = {};
globalThis.setTimeout = (fn) => { timers.push(fn); return timers.length; };
const flush = () => { while (timers.length) timers.shift()(); };

globalThis.window = {
  parent,
  addEventListener: (t, fn) => { if (t === "message") listeners.push(fn); },
  localStorage: process.env.NO_STORAGE
    ? { getItem() { throw new Error("SecurityError"); }, setItem() { throw new Error("SecurityError"); } }
    : {
        getItem: (k) => (k in store ? store[k] : null),
        setItem: (k, v) => { store[k] = String(v); writeFileSync(storagePath, JSON.stringify(store)); },
      },
  lavish: {
    // Lavish keys a queued prompt by the explicit queueKey, else by the
    // anchoring element's question; the same key replaces the unsent entry.
    queuePrompt: (prompt, opts) => {
      const anchor = anchorFor(opts.element);
      const key = opts.queueKey !== undefined ? opts.queueKey : "question:" + opts.element.attributes["data-lavish-question"];
      calls.push({ key, anchor, prompt, data: opts.data });
      session.queue[key] = { anchor, prompt };
    },
  },
};
globalThis.FormData = class {
  constructor(form) { this.form = form; }
  get(name) {
    const els = this.form.querySelectorAll("input");
    const hit = name === "answer" ? els.find((e) => e.name === name && e.checked) : els.find((e) => e.name === name);
    return hit ? hit.value : null;
  }
};
globalThis.TextEncoder = TextEncoder;

new Function(html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>")))();

const post = (data) => { for (const fn of listeners) fn({ data, source: parent }); flush(); };
const anchors = () => post({ type: "lavish:queuedAnchors", selectors: Object.values(session.queue).map((q) => q.anchor) });
// Lavish collects every control under a data-lavish-question scope.
const scopes = () => {
  const out = [];
  const walk = (n) => { for (const c of n.children) { if (c.attributes["data-lavish-question"]) out.push(c); walk(c); } };
  for (const id of ["bb-call", "bb-charted", "bb-dispatch"]) walk({ children: [byId.get(id)] });
  return out;
};
const controls = () => scopes().flatMap((scope) =>
  scope.querySelectorAll("input").map((el, index) => ({
    el, index, question: scope.attributes["data-lavish-question"],
    key: [scope.attributes["data-lavish-question"], el.name, el.type, el.type === "hidden" ? "" : el.value].join("|"),
  })));

const forms = () => byId.get("bb-call").querySelectorAll("form");
for (const act of actionList.split(",").filter(Boolean)) {
  const [name, arg] = act.split(":");
  if (name === "type") {
    for (const f of forms()) {
      f.querySelector("input[type=radio]").checked = true;
      f.querySelector("input[name=note]").value = "typed " + f.attributes["data-lavish-question"];
      f.fire("input");
    }
  } else if (name === "submit") {
    forms().find((f) => f.attributes["data-lavish-question"] === arg).fire("submit");
  } else if (name === "pick") {
    const box = byId.get("bb-charted").querySelectorAll(".bb-pick").find((c) => c.value === arg);
    box.checked = true; box.fire("change");
  } else if (name === "dispatch") {
    byId.get("bb-dispatch-btn").fire("click");
  } else if (name === "load") {
    for (const f of session.review) {
      const hit = controls().find((c) => c.key === f.key) || controls().find((c) => c.question === f.question && c.index === f.index);
      if (!hit) continue;
      if (f.checked === null) hit.el.value = f.value; else hit.el.checked = f.checked;
    }
    post({ type: "lavish:restoreReviewState" });
    anchors();
  } else if (name === "send") {
    session.queue = {};
    anchors();
  }
}
// The chrome saves review state as the page changes; mirror its final shape.
session.review = controls().map((c) => ({
  key: c.key, index: c.index, question: c.question, value: c.el.value,
  checked: c.el.type === "checkbox" || c.el.type === "radio" ? c.el.checked : null,
}));
writeFileSync(sessionPath, JSON.stringify(session));

const bar = byId.get("bb-dispatch");
const cards = forms().map((f) => ({
  key: f.attributes["data-lavish-question"],
  selection: f.querySelectorAll("input").find((r) => r.type === "radio" && r.checked)?.value ?? "",
  note: f.querySelector("input[name=note]").value,
  queued: f.parentNode.parentNode.classList.contains("is-queued"),
  state: f.querySelectorAll("input").find((i) => i.name === "lavish-state")?.value ?? "",
}));
process.stdout.write(JSON.stringify({
  cards, storage: store, calls, queue: Object.keys(session.queue),
  bar: { queued: bar.classList.contains("is-queued"), count: byId.get("bb-dispatch-count").textContent, disabled: byId.get("bb-dispatch-btn").disabled },
  picks: byId.get("bb-charted").querySelectorAll(".bb-pick").filter((c) => c.checked).map((c) => c.value),
}) + "\n");

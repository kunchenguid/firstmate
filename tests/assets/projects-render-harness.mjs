// Render a built Projects view page's shipped inline script under a minimal DOM
// shim, drive it like the captain would, and print what it rendered and what it
// sent, so page behavior is asserted through the real template rather than by
// reading its source.
//
// Usage: node projects-render-harness.mjs <built-page.html> <project-id>
// Prints one JSON document:
//   { error, totals:[text], cards:[{name,counter,now}], tray,
//     detail:{name,counter,groups:[title],calls:[title],fixable:[title]},
//     reloaded:{name,cards}, reloadedAfterBack:{cards},
//     sent:[{question,selection,note}] }
// `reloaded` is what the page shows after it is loaded again at a URL without
// the hash, as Lavish's live reload of its sandboxed artifact frame does (no
// web storage there, only window.name), while a project was open;
// `reloadedAfterBack` the same after the captain went back to the overview.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const projectId = process.argv[3];

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.parentNode = null;
    this.attributes = {};
    this.listeners = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.value = "";
    this.style = { setProperty() {} };
  }
  get textContent() {
    return this._text + this.children.map((c) => c.textContent).join("");
  }
  set textContent(v) {
    this.children.forEach((c) => { c.parentNode = null; });
    this.children = [];
    this._text = String(v);
  }
  appendChild(c) {
    if (c.parentNode) c.parentNode.removeChild(c);
    c.parentNode = this;
    this.children.push(c);
    return c;
  }
  insertBefore(c, ref) {
    if (c.parentNode) c.parentNode.removeChild(c);
    const i = this.children.indexOf(ref);
    c.parentNode = this;
    if (i < 0) this.children.push(c); else this.children.splice(i, 0, c);
    return c;
  }
  removeChild(c) {
    this.children = this.children.filter((x) => x !== c);
    c.parentNode = null;
    return c;
  }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.children;
    return s[s.indexOf(this) + 1] || null;
  }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type) {
    (this.listeners[type] || []).forEach((fn) => fn({ preventDefault() {}, stopPropagation() {} }));
  }
  focus() {}
}

const byId = {};
for (const id of ["pv-main", "pv-updated", "pv-scrim", "pv-sheet"]) {
  byId[id] = new Node("div");
}
const dataMatch = html.match(/<script id="projects-data" type="application\/json">\n([\s\S]*?)\n<\/script>/);
const dataNode = new Node("script");
dataNode.textContent = dataMatch ? dataMatch[1] : "";
byId["projects-data"] = dataNode;

const scripts = [...html.matchAll(/<script>\n([\s\S]*?)<\/script>/g)];
const code = scripts.length ? scripts[scripts.length - 1][1] : "";

const sent = [];
let windowListeners = {};
const location = { hash: "" };
// Lavish serves the page in a sandboxed iframe without allow-same-origin
// (both the iframe attribute and a `content-security-policy: sandbox` header),
// so its origin is opaque and every web-storage access throws a SecurityError,
// exactly as Chrome does. Only window.name survives a navigation of that frame.
function denied() {
  const e = new Error("Failed to read the 'sessionStorage' property from 'Window': The document is sandboxed and lacks the 'allow-same-origin' flag.");
  e.name = "SecurityError";
  throw e;
}
const storageDenied = { get: denied, set: denied };
globalThis.document = {
  getElementById: (id) => byId[id] || null,
  createElement: (tag) => new Node(tag),
  createTextNode: (t) => { const n = new Node("#text"); n.textContent = t; return n; },
};
globalThis.window = {
  location,
  name: "",
  lavish: { queuePrompt: (_prompt, ctx) => sent.push(ctx.data) },
  addEventListener: (type, fn) => { (windowListeners[type] ||= []).push(fn); },
  scrollTo() {},
};
globalThis.setInterval = () => 0;
globalThis.setTimeout = () => 0;

function all(node, pred, out = []) {
  if (pred(node)) out.push(node);
  node.children.forEach((c) => all(c, pred, out));
  return out;
}
const hasClass = (cls) => (n) => n.className.split(/\s+/).includes(cls);
const one = (root, cls) => all(root, hasClass(cls))[0];
function goTo(hash) {
  location.hash = hash;
  (windowListeners.hashchange || []).forEach((fn) => fn());
}
function typeAndSend(container, words) {
  const box = all(container, (n) => n.tagName === "textarea")[0];
  box.value = words;
  box.fire("input");
  one(container, "send").fire("click");
}

const out = { error: "", totals: [], cards: [], tray: null, detail: null, reloaded: null, reloadedAfterBack: null, sent };
Object.defineProperty(globalThis.window, "sessionStorage", storageDenied);
Object.defineProperty(globalThis.window, "localStorage", storageDenied);
// Load the page again as a fresh document at a URL without the hash, as the
// sandboxed frame does on a live reload; only window.name survives.
function reload() {
  for (const id of Object.keys(byId)) if (id !== "projects-data") byId[id] = new Node("div");
  windowListeners = {};
  location.hash = "";
  new Function(code)();
}
try {
  new Function(code)();
  const main = byId["pv-main"];
  const err = one(main, "err");
  if (err) throw new Error(err.textContent);
  out.totals = all(main, hasClass("total")).map((t) => t.textContent);
  out.cards = all(main, hasClass("card")).map((c) => ({
    name: one(c, "card__name").textContent,
    counter: one(c, "count").textContent,
    now: one(c, "card__now").textContent,
  }));
  const tray = one(main, "tray");
  out.tray = tray ? tray.textContent : null;

  // Add a task from the overview card's plus.
  const card = all(main, hasClass("card")).find((c) => one(c, "card__name").textContent
    === JSON.parse(dataNode.textContent).projects.find((p) => p.id === projectId).name);
  one(card, "plus").fire("click");
  typeAndSend(byId["pv-sheet"], "Add the dark icon");

  // Open the project, then correct inside it; needs-you cards offer no composer.
  goTo("#p=" + projectId);
  const detail = byId["pv-main"];
  out.detail = {
    name: all(detail, (n) => n.tagName === "h2")[0].textContent,
    counter: one(detail, "count").textContent,
    groups: all(detail, hasClass("group__title")).map((g) => g._text.trim()),
    calls: all(detail, hasClass("call__q")).map((q) => q.textContent),
    callComposers: all(detail, hasClass("call")).filter((c) => all(c, (n) => n.tagName === "textarea").length).length,
    callNotes: all(detail, hasClass("call")).map((c) => (one(c, "item__s") || { textContent: "" }).textContent),
    fixable: all(detail, hasClass("item--moving"))
      .filter((r) => one(r, "fix")).map((r) => one(r, "item__t").textContent),
  };
  const fixRow = all(detail, hasClass("item--moving")).find((r) => one(r, "fix"));
  if (fixRow) {
    one(fixRow, "fix").fire("click");
    typeAndSend(one(detail, "fixbox"), "Use the brand color");
  }

  // The open project survives an automatic redraw (reload without the hash),
  // and going back to the overview is remembered the same way.
  reload();
  const after = byId["pv-main"];
  const h2 = all(after, (n) => n.tagName === "h2")[0];
  out.reloaded = { name: h2 ? h2.textContent : null, cards: all(after, hasClass("card")).length };
  const back = one(after, "back");
  if (back) back.fire("click");
  reload();
  out.reloadedAfterBack = { cards: all(byId["pv-main"], hasClass("card")).length };
} catch (e) {
  out.error = String(e && e.message || e);
}
process.stdout.write(JSON.stringify(out) + "\n");

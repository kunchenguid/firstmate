// Run a built bearings board's inline script under a minimal DOM shim with a
// storage file that outlives the run, so a rebuild-then-reload can be asserted
// through the real template.
//
// Usage: node board-drafts-harness.mjs <built-board.html> <storage.json> [action]
// action: "type" selects the first option and types a note into every card, then fires input events.
// Prints { cards:[{key,selection,note}], storage }.
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const [, , boardPath, storagePath, action = ""] = process.argv;
const html = readFileSync(boardPath, "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag; this.className = ""; this.children = []; this.attributes = {};
    this._text = ""; this.hidden = false; this.disabled = false; this.innerHTML = "";
    this.parentNode = null; this.type = ""; this.name = ""; this.value = ""; this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      toggle: () => {}, contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() { return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text; }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(t, fn) { (this.listeners[t] ||= []).push(fn); }
  fire(t) { for (const fn of this.listeners[t] || []) fn({ preventDefault() {} }); }
  matches(sel) {
    if (sel.startsWith(".")) return this.className.split(/\s+/).includes(sel.slice(1));
    const m = sel.match(/^(\w+)(?:\[(\w+)=(\w+)\])?$/);
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

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html.split('<script id="bearings-data" type="application/json">')[1].split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  getElementById: (id) => {
    if (!byId.has(id)) { const n = new Node("div"); new Node("div").appendChild(n); byId.set(id, n); }
    return byId.get(id);
  },
  querySelector: () => new Node("div"),
};
const store = existsSync(storagePath) ? JSON.parse(readFileSync(storagePath, "utf8")) : {};
globalThis.window = {
  localStorage: {
    getItem: (k) => (k in store ? store[k] : null),
    setItem: (k, v) => { store[k] = String(v); writeFileSync(storagePath, JSON.stringify(store)); },
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

const forms = byId.get("bb-call").querySelectorAll("form");
if (action === "type") {
  for (const f of forms) {
    f.querySelector("input[type=radio]").checked = true;
    f.querySelector("input[name=note]").value = "typed " + f.attributes["data-lavish-question"];
    f.fire("input");
  }
}
const cards = forms.map((f) => ({
  key: f.attributes["data-lavish-question"],
  selection: f.querySelectorAll("input[type=radio]").find((r) => r.checked)?.value ?? "",
  note: f.querySelector("input[name=note]").value,
}));
process.stdout.write(JSON.stringify({ cards, storage: store }) + "\n");

// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [<submissions-json>]
// An optional submissions array [{index, selection, note}] fills in and submits
// the index-th decision form after the render; the result then carries
//   submits:[{queued:[{prompt,text,data}], alert, alert_visible}]
// Prints one JSON document:
//   { stats:[{n,label}], captains_call:[text], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, force) => {
        const classes = new Set(this.className.split(/\s+/).filter(Boolean));
        const enabled = force ?? !classes.has(c);
        if (enabled) classes.add(c); else classes.delete(c);
        this.className = [...classes].join(" ");
        return enabled;
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { (this.listeners ??= {})[type] = fn; }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const queuedPrompts = [];
globalThis.window = {
  lavish: { queuePrompt: (prompt, opts) => queuedPrompts.push({ prompt, text: opts.text, data: opts.data }) },
};
globalThis.FormData = class {
  constructor(form) {
    this.values = new Map();
    const walk = (n) => {
      for (const c of n.children) {
        if (c.tagName === "input" && c.type === "radio" && c.checked) this.values.set(c.name, c.value);
        if (c.tagName === "input" && c.type === "text") this.values.set(c.name, c.value);
        walk(c);
      }
    };
    walk(form);
  }
  get(name) { return this.values.has(name) ? this.values.get(name) : null; }
};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);
const captains_call = (byId.get("bb-call") || new Node("div")).children
  .filter((n) => n.className.split(/\s+/).includes("bb-decision"))
  .map((n) => n.textContent);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const submits = [];
if (process.argv[3]) {
  const forms = [];
  const find = (n) => { for (const c of n.children) { if (c.tagName === "form") forms.push(c); find(c); } };
  find(byId.get("bb-call") || new Node("div"));
  for (const sub of JSON.parse(process.argv[3])) {
    const form = forms[sub.index];
    const inputs = [];
    const gather = (n) => { for (const c of n.children) { if (c.tagName === "input") inputs.push(c); gather(c); } };
    gather(form);
    for (const i of inputs) {
      if (i.type === "radio") i.checked = i.value === sub.selection;
      if (i.type === "text") i.value = sub.note ?? "";
    }
    const before = queuedPrompts.length;
    form.listeners.submit({ preventDefault() {} });
    const limit = [];
    const seek = (n) => { for (const c of n.children) { if (c.className.split(/\s+/).includes("bb-limit")) limit.push(c); seek(c); } };
    seek(form);
    submits.push({
      queued: queuedPrompts.slice(before),
      alert: limit[0]?.textContent ?? "",
      alert_visible: limit[0]?.classList.contains("is-visible") ?? false,
    });
  }
}

process.stdout.write(
  JSON.stringify({ stats, captains_call, underway, charted, empty, more, error: errorText, submits }) + "\n");

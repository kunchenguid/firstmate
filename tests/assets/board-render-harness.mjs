// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], charted:[{title,sub,badges,pickable}],
//     calls:[{title,badges,ctx:[{k,v}]}] }
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
    const tokens = () => this.className.split(/\s+/).filter(Boolean);
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => tokens().includes(c),
      remove: (c) => { this.className = tokens().filter((t) => t !== c).join(" "); },
      // Card-deck navigation drives the class it wants with an explicit second
      // argument, so honour force before falling back to flipping.
      toggle: (c, force) => {
        const on = force === undefined ? !tokens().includes(c) : Boolean(force);
        if (on) this.classList.add(c); else this.classList.remove(c);
        return on;
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
  addEventListener() {}
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
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    // A badge may carry further classes after its tone, so read the tone token
    // itself rather than everything that follows the prefix.
    .map((c) => ({
      tone: (c.className.match(/fm-badge--([\w-]+)/) || [, ""])[1],
      text: c.textContent,
    }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const ch = byId.get("bb-charted") || new Node("div");
const charted = ch.children
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
// Captain's Call cards: the badges each card wears and the context rows in its
// body, so what the risk value renders as is asserted through the template.
const deck = byId.get("bb-call") || new Node("div");
const calls = deck.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => {
    const pad = card.children.find((c) => c.className.includes("bb-decision__pad"));
    const top = pad?.children.find((c) => c.className.includes("bb-decision__top"));
    const ctx = pad?.children.find((c) => c.className.includes("bb-ctx"));
    return {
      title: pad?.children.find((c) => c.className.includes("bb-decision__title"))?.textContent ?? "",
      badges: top ? badgesOf(top) : [],
      ctx: (ctx?.children ?? []).map((row) => ({
        k: row.children.find((c) => c.className.includes("bb-ctx__k"))?.textContent ?? "",
        v: row.children.find((c) => c.className.includes("bb-ctx__v"))?.textContent ?? "",
      })),
    };
  });

// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(JSON.stringify({ stats, charted, calls, empty, more, error: errorText }) + "\n");

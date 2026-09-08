// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label,owners}], charted:[...], underway:[...], awaiting:[...],
//     landed:[...], call:[{title,badges,link}], awaitingEmpty, empty, more, error }
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
    const has = (c) => this.className.split(/\s+/).includes(c);
    const add = (c) => { if (!has(c)) this.className = (this.className + " " + c).trim(); };
    const remove = (c) => {
      this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
    };
    this.classList = {
      add,
      remove,
      contains: has,
      // the shipped deck toggles the pile classes as cards are dealt
      toggle: (c, on) => { if (on === undefined ? has(c) : !on) remove(c); else add(c); },
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
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
  // "" when the tile carries no ownership sub-line at all
  owners: t.children.find((c) => c.className.includes("bb-stat__owners"))?.textContent ?? "",
}));

const rowsOf = (id) => {
  const host = byId.get(id) || new Node("div");
  return host.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      const pr = row.children.find((c) => c.className.includes("bb-row__pr"));
      const age = row.children.find((c) => c.className.includes("bb-row__age"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pr: pr ? { text: pr.textContent, href: pr.href } : null,
        age: age ? age.textContent : null,
      };
    });
};
const emptyOf = (id) =>
  (byId.get(id) || new Node("div")).children
    .filter((c) => c.className.includes("bb-empty"))
    .map((c) => c.textContent);

const call = (byId.get("bb-call") || new Node("div")).children
  .filter((c) => c.className.includes("bb-decision"))
  .map((card) => {
    const pad = card.children[0] || new Node("div");
    const top = pad.children.find((c) => c.className.includes("bb-decision__top"));
    return {
      title: pad.children.find((c) => c.className.includes("bb-decision__title"))?.textContent ?? "",
      badges: top ? badgesOf(top) : [],
      link: pad.children.find((c) => c.className.includes("bb-decision__link"))?.textContent ?? "",
    };
  });

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
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({
    stats,
    charted,
    underway: rowsOf("bb-underway"),
    awaiting: rowsOf("bb-awaiting"),
    landed: rowsOf("bb-landed"),
    call,
    awaitingEmpty: emptyOf("bb-awaiting"),
    empty,
    more,
    error: errorText,
  }) + "\n",
);

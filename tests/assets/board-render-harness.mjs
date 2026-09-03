// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [clicks-json]
// clicks-json (optional): an array of {"id":"<element id>"} or
// {"selector":".bb-chip","match":{"group":"repo","key":"alpha"}} objects,
// clicked in order after the initial render, so filter-bar interactions can
// be exercised the same way a captain's click would.
// Prints one JSON document: { stats:[{n,label}], charted:[{title,sub,badges,pickable}],
// filterbar:{chips,clearHidden}, deck:{...}, sections:{...} }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const clicks = process.argv[3] ? JSON.parse(process.argv[3]) : [];

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this.dataset = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this._listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
      },
      toggle: (c, on) => {
        const has = this.classList.contains(c);
        const want = on === undefined ? !has : on;
        if (want && !has) this.classList.add(c);
        if (!want && has) this.classList.remove(c);
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  remove() {
    if (!this.parentNode) return;
    const i = this.parentNode.children.indexOf(this);
    if (i !== -1) this.parentNode.children.splice(i, 1);
    this.parentNode = null;
  }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) {
    (this._listeners[type] = this._listeners[type] || []).push(fn);
  }
  click() {
    for (const fn of this._listeners.click || []) fn({ preventDefault() {} });
  }
  // Supports the plain compound-class selectors the template and tests
  // actually use, e.g. ".bb-chip", ".bb-chip.is-active", ".bb-pick:checked".
  querySelectorAll(sel) {
    const checkedOnly = sel.endsWith(":checked");
    const base = checkedOnly ? sel.slice(0, -":checked".length) : sel;
    const wantClasses = base.split(".").filter(Boolean);
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        const classes = c.className.split(/\s+/);
        if (wantClasses.every((w) => classes.includes(w)) && (!checkedOnly || c.checked)) out.push(c);
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

// Replay any requested clicks (filter chips, the clear-filters button) now
// that the page has finished its initial render, so filter-bar interaction
// can be asserted the same way the fix report requires: through the real
// template, not by reading its source.
for (const c of clicks) {
  const target = c.id
    ? byId.get(c.id)
    : (byId.get("bb-filterbar") || new Node("div"))
        .querySelectorAll(c.selector)
        .find((n) => !c.match || Object.entries(c.match).every(([k, v]) => n.dataset[k] === v));
  if (!target) throw new Error("harness click target not found: " + JSON.stringify(c));
  target.click();
}

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

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
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

// Filter bar: every chip's group/key/label/count/active state, plus whether
// the "show everything" clear control is currently visible.
const filterBarNode = byId.get("bb-filterbar") || new Node("div");
const filterChips = filterBarNode.querySelectorAll(".bb-chip").map((chip) => ({
  group: chip.dataset.group,
  key: chip.dataset.key,
  label: chip.children[0]?.textContent ?? "",
  count: Number((chip.children[1]?.textContent ?? "").replace(/[()]/g, "")),
  active: chip.classList.contains("is-active"),
}));
const clearNode = filterBarNode.querySelectorAll(".bb-filter__clear")[0];
const filterbar = { chips: filterChips, clearHidden: clearNode ? !!clearNode.hidden : true };

// Captain's Call deck: every dealt card (tagged with repo/type) plus whether
// it is the one currently shown, and the stack counter text the captain
// actually reads.
const deckNode = byId.get("bb-call") || new Node("div");
const deckCards = deckNode.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((c) => ({ repo: c.dataset.repo, type: c.dataset.type, hidden: !!c.hidden }));
const deckEmpty = deckNode.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const deck = {
  cards: deckCards,
  visibleCount: deckCards.filter((c) => !c.hidden).length,
  stackText: (byId.get("bb-stack-count") || new Node("span")).textContent,
  empty: deckEmpty,
};

// The three project-scoped rows sections: repo tag + hidden flag per row,
// plus whatever empty-state message is currently showing (if any).
function sectionState(id) {
  const node = byId.get(id) || new Node("div");
  return {
    rows: node.children
      .filter((c) => c.className.split(/\s+/).includes("bb-row"))
      .map((c) => ({ repo: c.dataset.repo, hidden: !!c.hidden })),
    empty: node.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent),
  };
}
const sections = {
  underway: sectionState("bb-underway"),
  landed: sectionState("bb-landed"),
  charted: sectionState("bb-charted"),
};

process.stdout.write(JSON.stringify({ stats, charted, empty, more, error: errorText, filterbar, deck, sections }) + "\n");

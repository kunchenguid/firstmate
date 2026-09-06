// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [clicks-json]
// clicks-json (optional): an array of actions replayed in order after the
// initial render, so filter-bar and dispatch-picker interactions can be
// exercised the same way a captain's click would:
//   {"id":"<element id>"} or
//   {"selector":".bb-chip","container":"<id, default bb-filterbar>","match":{...}}
//     both click the found element (matched against its dataset or, when a
//     match value isn't found there, the same-named property, e.g. "value"
//     for a checkbox);
//   the same shape with a "set" object instead of a click assigns those
//   properties directly (e.g. {"set":{"checked":true}} to tick a checkbox
//   without going through its own click handler), optionally followed by
//   {"fire":"input"} to dispatch that event the way typing would.
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
  // Events reach ancestor listeners, as they do in a browser: the decision
  // form listens for changes made on the radios inside it.
  dispatch(type) {
    const ev = { type, target: this, preventDefault() {} };
    for (let n = this; n; n = n.parentNode) {
      for (const fn of n._listeners[type] || []) fn(ev);
    }
  }
  click() {
    // A radio takes its group exclusively, so picking one clears the rest.
    if (this.type === "radio") {
      let top = this;
      while (top.parentNode) top = top.parentNode;
      for (const r of top.querySelectorAll("input")) {
        if (r.type === "radio" && r.name === this.name) r.checked = false;
      }
      this.checked = true;
      this.dispatch("change");
    }
    this.dispatch("click");
  }
  submit() {
    for (const fn of this._listeners.submit || []) fn({ preventDefault() {} });
  }
  focus() { focused = this; }
  // Supports the plain compound-class selectors the template and tests
  // actually use, e.g. ".bb-chip", ".bb-chip.is-active", ".bb-pick:checked",
  // plus a bare tag name ("input") for the controls that carry no class.
  querySelectorAll(sel) {
    const checkedOnly = sel.endsWith(":checked");
    const base = checkedOnly ? sel.slice(0, -":checked".length) : sel;
    const wantTag = base.startsWith(".") ? "" : base.split(".")[0].toLowerCase();
    const wantClasses = base.split(".").filter(Boolean).slice(wantTag ? 1 : 0);
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        const classes = c.className.split(/\s+/);
        const tagOk = !wantTag || String(c.tagName).toLowerCase() === wantTag;
        if (tagOk && wantClasses.every((w) => classes.includes(w)) && (!checkedOnly || c.checked)) out.push(c);
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
// Every prompt the board hands the review tool, in order, so the answer a
// captain would actually queue is asserted rather than inferred.
const queued = [];
let focused = null;
globalThis.window = {
  lavish: {
    // The origin element is a live DOM node; keep only what a caller asserts on.
    queuePrompt: (prompt, options = {}) =>
      queued.push({ prompt, options: { tag: options.tag, text: options.text,
        queueKey: options.queueKey, data: options.data } }),
  },
};
globalThis.TextEncoder = TextEncoder;
// The template reads its answer through FormData, so the shim has to agree
// with a browser on the one case that matters here: an unchecked radio group
// contributes nothing, which is what makes a bare note the whole answer.
globalThis.FormData = class {
  constructor(form) {
    this.pairs = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.name && !(c.type === "radio" && !c.checked)) this.pairs.push([c.name, c.value]);
        walk(c);
      }
    };
    walk(form);
  }
  get(name) {
    const hit = this.pairs.find(([k]) => k === name);
    return hit ? hit[1] : null;
  }
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

// Replay any requested clicks (filter chips, the clear-filters button) now
// that the page has finished its initial render, so filter-bar interaction
// can be asserted the same way the fix report requires: through the real
// template, not by reading its source.
const callDeck = byId.get("bb-call") || new Node("div");
const cardForms = new Map();
(function collectForms(node) {
  for (const child of node.children) {
    const key = child.attributes["data-lavish-question"];
    if (key) cardForms.set(key, child);
    collectForms(child);
  }
})(callDeck);
function findInCard(key, selector, match) {
  const form = cardForms.get(key);
  if (!form) throw new Error("harness: no decision card with key " + key);
  if (!selector) return form;
  return form
    .querySelectorAll(selector)
    .find((n) => !match || Object.entries(match).every(([k, v]) => (k in n.dataset ? n.dataset[k] : n[k]) === v));
}

for (const c of clicks) {
  const target = c.card
    ? findInCard(c.card, c.selector, c.match)
    : c.id
    ? byId.get(c.id)
    : (byId.get(c.container || "bb-filterbar") || new Node("div"))
        .querySelectorAll(c.selector)
        .find((n) => !c.match || Object.entries(c.match).every(([k, v]) => (k in n.dataset ? n.dataset[k] : n[k]) === v));
  if (!target) throw new Error("harness click target not found: " + JSON.stringify(c));
  if (c.set) Object.assign(target, c.set);
  if (c.fire) target.dispatch(c.fire);
  else if (!c.set) { if (c.submit) target.submit(); else target.click(); }
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
    const pick = row.children.find((c) => c.className.includes("bb-pick") && !c.className.includes("spacer"));
    return {
      title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
      sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
      badges: badgesOf(row),
      pickable: !!pick,
      checked: !!pick && !!pick.checked,
      hidden: !!row.hidden,
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
  .map((c) => ({
    repo: c.dataset.repo,
    type: c.dataset.type,
    hidden: !!c.hidden,
    title: c.querySelectorAll(".bb-decision__title")[0]?.textContent ?? "",
    // Flags are the board's whole answer to a badly composed card: it says
    // what is wrong on the card's face and deals it anyway.
    flags: c.querySelectorAll(".bb-flag").map((f) => ({
      kind: f.children[0]?.textContent ?? "",
      text: f.children[1]?.textContent ?? "",
    })),
    queued: c.classList.contains("is-queued"),
    limit: c.querySelectorAll(".bb-limit")[0]?.textContent ?? "",
  }));
const deckEmpty = deckNode.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const deck = {
  cards: deckCards,
  visibleCount: deckCards.filter((c) => !c.hidden).length,
  stackText: (byId.get("bb-stack-count") || new Node("span")).textContent,
  empty: deckEmpty,
  focused: focused ? focused.className : null,
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

// The Charted Next dispatch bar: what it currently tells the captain and
// whether the "queue dispatch order" button would fire.
const dispatch = {
  count: (byId.get("bb-dispatch-count") || new Node("span")).textContent,
  disabled: !!(byId.get("bb-dispatch-btn") || new Node("button")).disabled,
};

process.stdout.write(JSON.stringify({ stats, charted, empty, more, error: errorText, filterbar, deck, sections, dispatch, queued }) + "\n");

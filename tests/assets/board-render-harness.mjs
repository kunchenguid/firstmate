// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label,tag,type,scrolls_to,target_declared,prompts}],
//     captains_call:[text], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error,
//     call:{wide:[page], narrow:[page], empty, details:[view]} }
// where each Captain's Call page is {title, height, natural}: the card the back
// and next buttons show, the height it lays out at, and the height its own
// content needs. Layout is a toy model - text wraps at a fixed character width
// within the viewport width, and a hidden element takes no space - so height
// assertions test how the page sizes its cards, not real font metrics. "wide"
// pages after the initial render and web fonts load; "narrow" pages again after
// the window narrows and fires resize. Each details view is what one card's
// Details button opened: {button, was_closed, open, title, ctx_rows, context,
// none, options:[{label, rec, hint, details}], links, closed_after, prompts}.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

const CHAR_PX = 8;
const LINE_PX = 20;
const BOX_PX = 4;
const layout = { width: 640 };

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
    this.listeners = {};
    this.id = "";
    this.style = {};
    const has = (c) => this.className.split(/\s+/).includes(c);
    const remove = (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); };
    this.classList = {
      add: (c) => { if (!has(c)) this.className = (this.className + " " + c).trim(); },
      remove,
      toggle: (c, force) => {
        const enabled = force ?? !has(c);
        if (enabled) this.classList.add(c); else remove(c);
        return enabled;
      },
      contains: has,
    };
  }
  // Toy layout: own text wraps at CHAR_PX per character inside the viewport,
  // children stack, and a hidden element takes no space. An explicit
  // min-height raises the laid-out box; the natural height ignores it.
  naturalHeight() {
    if (this.hidden) return 0;
    const own = this.children.length || !this._text
      ? 0
      : Math.ceil((this._text.length * CHAR_PX) / layout.width) * LINE_PX;
    return BOX_PX + own + this.children.reduce((h, c) => h + c.naturalHeight(), 0);
  }
  getBoundingClientRect() {
    if (this.hidden) return { height: 0, width: 0 };
    const min = parseFloat(this.style.minHeight) || 0;
    return { height: Math.max(min, this.naturalHeight()), width: layout.width };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatch(type) { for (const fn of this.listeners[type] || []) fn({ type, preventDefault() {} }); }
  scrollIntoView(opts) { scrolls.push({ id: this.id, opts }); }
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

// Ids the built page declares in its static markup. getElementById below mints
// any id the script asks for, so a tile aimed at an id the page never declares
// is visible as a scroll to an undeclared target.
const declaredIds = new Set(
  [...html.split("<script")[0].matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
const scrolls = [];
const prompts = [];

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
      n.id = id;
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
const frames = [];
const flushFrames = () => { while (frames.length) frames.shift()(); };
const windowListeners = {};
let fontsReady;
const fontsLoaded = new Promise((resolve) => { fontsReady = resolve; });
globalThis.document.fonts = { ready: fontsLoaded };
globalThis.window = {
  lavish: { queuePrompt: (...args) => prompts.push(args) },
  addEventListener: (type, fn) => { (windowListeners[type] ||= []).push(fn); },
  requestAnimationFrame: (fn) => { frames.push(fn); },
};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

// Web fonts finish loading after the first render.
fontsReady();
await fontsLoaded;
await Promise.resolve();
flushFrames();

// Page through Captain's Call from the first card with the back and next
// buttons, recording the card each step shows.
const deck = byId.get("bb-call");
const decisionCards = () => deck.children.filter((c) => c.className.split(/\s+/).includes("bb-decision"));
const pageCall = () => {
  const prev = byId.get("bb-stack-prev");
  const next = byId.get("bb-stack-next");
  const pages = [];
  if (!decisionCards().length) return pages;
  for (let i = 0; i < 100 && !prev.disabled; i++) prev.dispatch("click");
  for (let i = 0; i < 100; i++) {
    const shown = decisionCards().filter((c) => !c.hidden);
    pages.push(...shown.map((c) => {
      const title = c.querySelectorAll(".bb-decision__title")[0]?.textContent ?? "";
      return { title, height: c.getBoundingClientRect().height, natural: c.naturalHeight() };
    }));
    if (next.disabled) break;
    next.dispatch("click");
  }
  return pages;
};
// Open each card's Details view with its button, record what the full-screen
// view shows, then close it again with its Close button.
const linksIn = (n, out = []) => {
  for (const c of n.children) {
    if (c.tagName === "a" && c.href) out.push(c.href);
    linksIn(c, out);
  }
  return out;
};
const details = decisionCards().map((card) => {
  const btn = card.querySelectorAll(".bb-detailsbtn")[0];
  if (!btn) return { button: null };
  const modal = byId.get("bb-modal");
  const body = byId.get("bb-modal-body");
  const text = (n) => n.textContent;
  const wasClosed = modal.hidden;
  const before = prompts.length;
  btn.dispatch("click");
  const view = {
    button: { tag: btn.tagName, type: btn.type, label: btn.textContent, controls: btn.attributes["aria-controls"] ?? null },
    was_closed: wasClosed,
    open: !modal.hidden,
    title: byId.get("bb-modal-title").textContent,
    ctx_rows: body.querySelectorAll(".bb-ctx__row").map((r) => r.children.map(text)),
    context: body.querySelectorAll(".bb-modal__ctxp").map(text),
    none: body.querySelectorAll(".bb-modal__none").map(text),
    options: body.querySelectorAll(".bb-modal__opt").map((o) => ({
      label: o.querySelectorAll(".bb-modal__optname")[0]?.textContent ?? "",
      rec: o.querySelectorAll(".bb-opt__rec").length > 0,
      hint: o.querySelectorAll(".bb-modal__opthint")[0]?.textContent ?? null,
      details: o.querySelectorAll(".bb-modal__optp").map(text),
    })),
    links: linksIn(body),
  };
  byId.get("bb-modal-close").dispatch("click");
  view.closed_after = modal.hidden;
  view.prompts = prompts.length - before;
  return view;
});

const callWide = pageCall();
layout.width = 320;
for (const fn of windowListeners.resize || []) fn({ type: "resize" });
flushFrames();
const callNarrow = pageCall();
const callEmpty = deck.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);

const strip = byId.get("bb-stats") || new Node("div");
// Click each tile and record where the page scrolled and whether the click
// queued anything for the agent.
const stats = strip.children.map((t) => {
  const before = { scrolls: scrolls.length, prompts: prompts.length };
  t.dispatch("click");
  const hit = scrolls.slice(before.scrolls);
  return {
    n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
    label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
    tag: t.tagName,
    type: t.type,
    scrolls_to: hit.map((h) => h.id),
    target_declared: hit.length > 0 && hit.every((h) => declaredIds.has(h.id)),
    prompts: prompts.length - before.prompts,
  };
});

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

process.stdout.write(
  JSON.stringify({ stats, captains_call, underway, charted, empty, more, error: errorText,
    call: { wide: callWide, narrow: callNarrow, empty: callEmpty, details } }) + "\n");

// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label,tag,type,scrolls_to,prompts}],
//     captains_call:[text], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error,
//     call:{wide:[page], narrow:[page], empty, details:[view]} }
// where a tile's scrolls_to lists the visible eyebrow heading of each section a
// click scrolled to, read from the built page's markup (null for a target that
// is not such a section), and each Captain's Call page is
// {title, height, natural}: the card the back
// and next buttons show, the height it lays out at, and the height its own
// content needs. Layout is a toy model - text wraps at a fixed character width
// within the viewport width, and a hidden element takes no space - so height
// assertions test how the page sizes its cards, not real font metrics. "wide"
// pages after the initial render and web fonts load; "narrow" pages again after
// the window narrows and fires resize. Each details view is what the Details
// button of one shown card opened, paging from the first card: {button,
// button_row, was_closed, open, title, ctx_rows, context, none, options:[{label,
// rec, hint, details}], links, closed_after, focus, prompts}, where
// button.controls is the declared role of the element the button's
// aria-controls names, open and closed state are read from that element,
// button_row is the row holding the button - its buttons' labels and its
// display and flex-wrap resolved from the built page's stylesheet - and focus
// is where keyboard focus landed once the view closed: {label, card, visible},
// card being the title of the card that holds the focused element. call.advance
// answers the first card, opens its Details before the deal's timer fires,
// fires it, then closes the view: {answered, shown, focus} (null for fewer than
// two cards). Focus moves only to an element with no hidden ancestor, as in a
// browser, and timers fire only when the harness fires them.
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
  rendered() {
    for (let n = this; n; n = n.parentNode) if (n.hidden) return false;
    return true;
  }
  focus() { if (this.rendered()) globalThis.document.activeElement = this; }
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

// The built page's static markup: the opening tag of every element it declares
// by id, and the visible eyebrow heading of every section that carries an id.
const markup = html.split("<script")[0];
const declared = new Map(
  [...markup.matchAll(/<[a-z][^>]*\sid="([^"]+)"[^>]*>/g)].map((m) => [m[1], m[0]]));
const roleOf = (id) => declared.get(id)?.match(/\srole="([^"]*)"/)?.[1] ?? null;
const sectionHeading = new Map(
  [...markup.matchAll(/<section\b[^>]*\sid="([^"]+)"[^>]*>([\s\S]*?)<\/section>/g)].map(([, id, body]) => [
    id,
    (body.match(/class="[^"]*\bfm-sign--eyebrow\b[^"]*"[^>]*>([\s\S]*?)<\/span>/)?.[1] ?? "")
      .replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim(),
  ]));
// The built page's own stylesheet outside any @media block, as rules in source
// order: each one's selector list and declarations.
const css = (html.match(/<style>([\s\S]*?)<\/style>/)?.[1] ?? "")
  .replace(/\/\*[\s\S]*?\*\//g, "")
  .replace(/@import\s+url\([^)]*\)[^;]*;/g, "")
  .replace(/@media[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, "");
const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, sel, body]) => ({
  selectors: sel.split(",").map((x) => x.trim()),
  decls: new Map(body.split(";").map((d) => d.split(":")).filter((d) => d.length > 1)
    .map(([k, ...v]) => [k.trim(), v.join(":").trim()])),
}));
// One property of a rendered element, from the rules whose selector is a plain
// [tag].class compound the element matches; more classes, then later source
// order, win. Pseudo-classes, combinators and attribute selectors are outside
// this model, so a property set only through them resolves to null.
const styleOf = (node, prop) => {
  const classes = node.className.split(/\s+/);
  let best = null;
  for (const r of rules) {
    if (!r.decls.has(prop)) continue;
    for (const sel of r.selectors) {
      const m = sel.match(/^([a-z][a-z0-9]*)?((?:\.[\w-]+)+)$/);
      if (!m || (m[1] && m[1] !== node.tagName)) continue;
      const need = m[2].slice(1).split(".");
      if (!need.every((c) => classes.includes(c))) continue;
      const rank = need.length + (m[1] ? 0.5 : 0);
      if (!best || rank >= best.rank) best = { rank, value: r.decls.get(prop) };
    }
  }
  return best?.value ?? null;
};
const scrolls = [];
const prompts = [];
const timers = [];

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  activeElement: null,
  createElement: (tag) => new Node(tag),
  // Lazily mint an element the first time the page asks for it, but, as in a
  // browser, only for an id its static markup declares; any other id is null.
  getElementById: (id) => {
    if (!byId.has(id) && declared.has(id)) {
      const n = new Node("div");
      n.id = id;
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id) ?? null;
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
// A submitted form's entries: each named input's value, a radio only when checked.
globalThis.FormData = class {
  constructor(form) {
    this.entries = new Map();
    const walk = (n) => n.children.forEach((c) => {
      if (c.tagName === "input" && c.name && (c.type !== "radio" || c.checked)) this.entries.set(c.name, c.value);
      walk(c);
    });
    walk(form);
  }
  get(name) { return this.entries.has(name) ? this.entries.get(name) : null; }
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function("setTimeout", script)((fn) => { timers.push(fn); });

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
// buttons, calling <visit> on the card each step shows.
const deck = byId.get("bb-call");
const decisionCards = () => deck.children.filter((c) => c.className.split(/\s+/).includes("bb-decision"));
const titleOf = (card) => card.querySelectorAll(".bb-decision__title")[0]?.textContent ?? "";
const showFirst = () => {
  const prev = byId.get("bb-stack-prev");
  for (let i = 0; i < 100 && !prev.disabled; i++) prev.dispatch("click");
};
const eachPage = (visit) => {
  const next = byId.get("bb-stack-next");
  const pages = [];
  if (!decisionCards().length) return pages;
  showFirst();
  for (let i = 0; i < 100; i++) {
    pages.push(...decisionCards().filter((c) => !c.hidden).map(visit));
    if (next.disabled) break;
    next.dispatch("click");
  }
  return pages;
};
const pageCall = () => eachPage((c) => ({ title: titleOf(c), height: c.getBoundingClientRect().height, natural: c.naturalHeight() }));
const firstWhere = (n, pred) => {
  for (const c of n.children) {
    if (pred(c)) return c;
    const hit = firstWhere(c, pred);
    if (hit) return hit;
  }
  return null;
};
// Where keyboard focus is: the focused element's label, the title of the card
// that holds it, and whether it is rendered.
const focusNow = () => {
  const f = document.activeElement;
  if (!f) return null;
  let card = f;
  while (card && !card.className.split(/\s+/).includes("bb-decision")) card = card.parentNode;
  return { label: f.textContent, card: card ? titleOf(card) : null, visible: f.rendered() };
};
// Open each shown card's Details view with its button, record what the
// full-screen view shows, then close it again with its Close button.
const linksIn = (n, out = []) => {
  for (const c of n.children) {
    if (c.tagName === "a" && c.href) out.push(c.href);
    linksIn(c, out);
  }
  return out;
};
const details = eachPage((card) => {
  const btn = card.querySelectorAll(".bb-detailsbtn")[0];
  if (!btn) return { button: null };
  const controls = btn.attributes["aria-controls"] ?? null;
  const modal = document.getElementById(controls);
  const body = byId.get("bb-modal-body");
  const text = (n) => n.textContent;
  const wasClosed = modal?.hidden === true;
  const before = prompts.length;
  const row = btn.parentNode;
  btn.dispatch("click");
  const view = {
    button: { tag: btn.tagName, type: btn.type, label: btn.textContent, controls: roleOf(controls) },
    button_row: {
      buttons: row.children.filter((c) => c.tagName === "button").map(text),
      display: styleOf(row, "display"),
      flex_wrap: styleOf(row, "flex-wrap"),
    },
    was_closed: wasClosed,
    open: modal?.hidden === false,
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
  view.closed_after = modal?.hidden === true;
  view.focus = focusNow();
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
    scrolls_to: hit.map((h) => sectionHeading.get(h.id) ?? null),
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

// Answer the first card, open its Details before the deal's timer fires, let a
// frame pass and the timer fire, then close the view.
const advance = (() => {
  if (decisionCards().length < 2) return null;
  showFirst();
  const card = decisionCards().find((c) => !c.hidden);
  firstWhere(card, (c) => c.tagName === "input" && c.type === "radio").checked = true;
  firstWhere(card, (c) => c.tagName === "form").dispatch("submit");
  card.querySelectorAll(".bb-detailsbtn")[0].dispatch("click");
  flushFrames();
  while (timers.length) timers.shift()();
  byId.get("bb-modal-close").dispatch("click");
  const shown = decisionCards().find((c) => !c.hidden);
  return { answered: titleOf(card), shown: shown ? titleOf(shown) : null, focus: focusNow() };
})();

process.stdout.write(
  JSON.stringify({ stats, captains_call, underway, charted, empty, more, error: errorText,
    call: { wide: callWide, narrow: callNarrow, empty: callEmpty, details, advance } }) + "\n");

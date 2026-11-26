// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [<card-index> <question>]
// With a card index and question, it clicks that card's Ask for more button,
// types the question, and sends it, recording every Lavish prompt queued.
// Prints one JSON document:
//   { stats:[{n,label}], captains_call:[text], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error,
//     cards:[{detail, more:[{asked,answer,view,open}], refs:[{text,href,target,rel}],
//       ask_button, ask_open, asked_shown, queued}], prompts:[{prompt,tag,queueKey,data}] }
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
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
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
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  dispatch(type) { for (const fn of this.listeners[type] || []) fn({ preventDefault() {} }); }
  focus() {}
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

const has = (n, c) => n.className.split(/\s+/).includes(c);
const findAll = (n, c) => {
  const out = [];
  const walk = (m) => { for (const k of m.children) { if (has(k, c)) out.push(k); walk(k); } };
  walk(n);
  return out;
};
const find = (n, c) => findAll(n, c)[0];
const cardNodes = (byId.get("bb-call") || new Node("div")).children.filter((n) => has(n, "bb-decision"));

const prompts = [];
if (process.argv.length > 3) {
  globalThis.window.lavish = {
    queuePrompt: (prompt, o) => prompts.push({ prompt, tag: o.tag, queueKey: o.queueKey, data: o.data }),
  };
  const card = cardNodes[Number(process.argv[3])];
  find(card, "bb-ask-btn").dispatch("click");
  find(card, "bb-ask__field").value = process.argv[4];
  find(card, "bb-ask__send").dispatch("click");
}

const cards = cardNodes.map((card) => {
  const moreItems = findAll(card, "bb-more__item").map((it) => {
    const view = find(it, "bb-more__frame") || find(it, "bb-more__img");
    const open = find(it, "bb-more__open");
    return {
      asked: find(it, "bb-more__asked")?.textContent ?? "",
      answer: find(it, "bb-more__answer")?.textContent ?? "",
      view: view ? { tag: view.tagName, src: view.attributes.src, sandbox: view.attributes.sandbox ?? null } : null,
      open: open ? open.href : null,
    };
  });
  const askBox = find(card, "bb-ask");
  return {
    detail: findAll(card, "bb-decision__detail").map((d) => d.textContent),
    more: moreItems,
    refs: findAll(card, "bb-ref").map((a) => ({ text: a.textContent, href: a.href, target: a.target, rel: a.rel })),
    ask_button: Boolean(find(card, "bb-ask-btn")),
    ask_open: askBox ? !askBox.hidden : false,
    asked_shown: Boolean(find(card, "bb-asked")?.classList.contains("is-visible")),
    queued: has(card, "is-queued"),
  };
});

process.stdout.write(
  JSON.stringify({ stats, captains_call, underway, charted, empty, more, error: errorText, cards, prompts }) + "\n");

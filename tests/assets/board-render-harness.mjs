// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable,links}], options:[{text,links}],
//     cards:[{key,dossier,rows,freeform,context}], empty, more, error }
// where links is [{text,href,target,rel}] for every anchor in a row's text, and
// each Captain's Call card reports its context-row keys beside the question,
// its free-text fields as [{name,placeholder}], and its Context box as
// {age, sections:[{name,text}], links:[{kind,label,href,state}]} or null.
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
    this.href = "";
    this.target = "";
    this.rel = "";
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x !== c).join(" "); },
      toggle: (c, on) => {
        const want = on === undefined ? !this.classList.contains(c) : Boolean(on);
        if (want) { if (!this.classList.contains(c)) this.classList.add(c); } else this.classList.remove(c);
        return want;
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
  createTextNode: (text) => { const n = new Node("#text"); n.textContent = text; return n; },
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

const linksOf = (node) =>
  node.children.flatMap((c) => (c.tagName === "a"
    ? [{ text: c.textContent, href: c.href, target: c.target, rel: c.rel }]
    : linksOf(c)));

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
        links: main ? linksOf(main) : [],
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const deck = byId.get("bb-call") || new Node("div");
const optionLabels = deck.querySelectorAll(".bb-opt__label").map((l) => ({ text: l.textContent, links: linksOf(l) }));

const cards = deck.children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => {
    const box = card.querySelectorAll(".bb-dossier")[0];
    return {
      key: card.querySelectorAll(".bb-decision__pad")[0]?.children
        .find((c) => c.tagName === "form")?.attributes["data-lavish-question"],
      dossier: card.className.split(/\s+/).includes("bb-decision--dossier"),
      rows: card.querySelectorAll(".bb-decision__pad")[0]
        ?.querySelectorAll(".bb-ctx__k").map((k) => k.textContent) ?? [],
      freeform: card.querySelectorAll(".bb-freeform").map((f) => ({ name: f.name, placeholder: f.placeholder })),
      context: box ? {
        age: box.querySelectorAll(".bb-dossier__age")[0]?.textContent ?? null,
        sections: box.children
          .filter((c) => c.className.includes("bb-dossier__sec"))
          .map((sec) => ({ name: sec.className.replace(/.*bb-dossier__sec--(\S+).*/, "$1"), text: sec.textContent })),
        links: box.querySelectorAll(".bb-links__item").map((li) => ({
          kind: li.children[0].textContent,
          label: li.children[1].textContent,
          href: li.children[1].tagName === "a" ? li.children[1].href : null,
          state: li.children[2]?.textContent ?? null,
        })),
      } : null,
    };
  });

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
  JSON.stringify({ stats, underway, charted, options: optionLabels, cards, empty, more, error: errorText }) + "\n");

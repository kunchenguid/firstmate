// Render a built workstream board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node workstream-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label,href}], streams:[{id,name,badges,rows,graph}],
//     waiting:[{key,title,options}], agents:[{id,doing}],
//     divergence:[{id,note}], error }
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
    this.id = "";
    this.style = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x !== c).join(" ");
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
  setAttribute(k, v) { this.attributes[k] = String(v); if (k === "id") this.id = String(v); }
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

class TextNode {
  constructor(text) { this._text = String(text); this.children = []; this.className = ""; this.tagName = "#text"; }
  get textContent() { return this._text; }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="workstream-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("workstream-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  createElementNS: (_ns, tag) => new Node(tag),
  createTextNode: (text) => new TextNode(text),
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

const byClass = (n, cls) => n.children.filter((c) => c.className.split(/\s+/).includes(cls));
const firstClass = (n, cls) => byClass(n, cls)[0];
const deep = (n, cls) => n.querySelectorAll("." + cls);

const strip = byId.get("wb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(firstClass(t, "wb-stat__num")?.textContent),
  label: firstClass(t, "wb-stat__label")?.textContent,
  href: t.attributes.href ?? "",
  attn: t.className.includes("wb-stat--attn"),
  warn: t.className.includes("wb-stat--warn"),
}));

const streamsCol = byId.get("wb-streams") || new Node("div");
const streams = streamsCol.children.map((card) => {
  const head = firstClass(card, "ws-head");
  const rows = deep(card, "wb-trow").map((row) => {
    const sum = firstClass(row, "wb-trow__sum");
    return {
      id: sum ? firstClass(sum, "wb-trow__id")?.textContent : "",
      title: sum ? firstClass(sum, "wb-trow__t")?.textContent : "",
      held: row.className.includes("wb-trow--held"),
      decision: row.className.includes("wb-trow--decision"),
      expandable: row.tagName === "details",
      agent: sum ? (firstClass(sum, "wb-agent")?.textContent ?? "") : "",
    };
  });
  const svg = deep(card, "ws-fig").flatMap((f) => f.children.filter((c) => c.tagName === "svg"));
  const graph = svg.length
    ? {
        nodes: svg[0].children.filter((c) => c.tagName === "rect").length,
        edges: svg[0].children.filter((c) => c.tagName === "line").length,
      }
    : null;
  return {
    id: card.id,
    title: head ? firstClass(head, "ws-head-top")?.children.find((c) => c.tagName === "h2")?.textContent : "",
    badges: head ? deep(head, "fm-badge").map((b) => b.textContent) : [],
    outcome: head ? (firstClass(head, "ws-outcome")?.textContent ?? "") : "",
    segments: head ? deep(head, "ws-progress").flatMap((p) => p.children.map((s) => s.className)) : [],
    rows,
    more: deep(card, "wb-morechip").map((c) => c.textContent),
    graph,
  };
});

const waitingItems = byId.get("wb-waiting-items") || new Node("div");
const waiting = waitingItems.children
  .filter((item) => deep(item, "wb-qform").length)
  .map((item) => {
    const form = deep(item, "wb-qform")[0];
    return {
      key: firstClass(item, "wb-k")?.textContent ?? "",
      question: form.attributes["data-lavish-question"] ?? "",
      options: form.children
        .filter((c) => c.tagName === "label")
        .map((lab) => lab.children.find((c) => c.type === "radio")?.value ?? ""),
      freeform: form.children.some((c) => c.className.includes("wb-freeform")),
    };
  });

const agentsItems = byId.get("wb-agents-items") || new Node("div");
const agents = agentsItems.children
  .map((row) => ({ chip: firstClass(row, "wb-agent")?.textContent ?? "" }))
  .filter((a) => a.chip);

const dv = byId.get("wb-divergence") || new Node("div");
const divergence = {
  hidden: dv.hidden,
  rows: deep(dv, "wb-callout__row").map((r) => ({
    id: firstClass(r, "wb-callout__id")?.textContent ?? "",
    note: r.children[1]?.textContent ?? "",
  })),
};

// A fail-closed render replaces the page body instead of the board sections,
// so surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");

process.stdout.write(JSON.stringify({ stats, streams, waiting, agents, divergence, error: errorText }) + "\n");

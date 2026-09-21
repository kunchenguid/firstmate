// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
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
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
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
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) {
    (this.listeners[type] ||= []).push(fn);
  }
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
// Build the initial DOM the way an HTML parser would: elements the markup
// carries (their tag plus hidden/disabled/checked state) exist before the
// page script runs, so what the script leaves untouched stays as authored.
function mint(tag) {
  const n = new Node(tag);
  new Node("div").appendChild(n);
  return n;
}
for (const m of html.matchAll(/<([a-zA-Z][a-zA-Z0-9]*)[^>]*\sid="([^"]+)"[^>]*>/g)) {
  const tagAttrs = m[0];
  const n = mint(m[1].toLowerCase());
  n.elementId = m[2];
  if (/\shidden(?=[\s>])/.test(tagAttrs)) n.hidden = true;
  if (/\sdisabled(?=[\s>])/.test(tagAttrs)) n.disabled = true;
  if (/\schecked(?=[\s>])/.test(tagAttrs)) n.checked = true;
  const type = tagAttrs.match(/\stype="([^"]*)"/);
  if (type) n.type = type[1];
  const value = tagAttrs.match(/\svalue="([^"]*)"/);
  if (value) n.value = value[1];
  const cls = tagAttrs.match(/\sclass="([^"]*)"/);
  if (cls) n.className = cls[1];
  byId.set(m[2], n);
}
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
      byId.set(id, mint("div"));
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

// Whether the dispatch bar reaches the reader, decided the way a browser
// decides it: the user-agent sheet hides [hidden], and an author rule keeps
// the bar visible only when its display declaration wins the cascade. The
// matcher covers the simple selectors the shipped stylesheet uses (type,
// class, id, [hidden]) and ignores ancestor qualifiers and pseudo selectors,
// which no display rule there depends on.
function computedDisplay(el) {
  const css = html.split("<style>")[1].split("</style>")[0].replace(/\/\*[\s\S]*?\*\//g, "");
  const classes = el.className.split(/\s+/).filter(Boolean);
  const compoundMatches = (compound) => {
    if (compound.includes(":")) return false;
    const parts = compound.match(/([a-zA-Z][a-zA-Z0-9]*)|(\.[a-zA-Z0-9_-]+)|(#[a-zA-Z0-9_-]+)|(\[[a-zA-Z0-9_-]+(?:=[^\]]+)?\])/g) || [];
    if (!parts.length) return false;
    return parts.every((p) => {
      if (p.startsWith(".")) return classes.includes(p.slice(1));
      if (p.startsWith("#")) return el.elementId === p.slice(1);
      if (p.startsWith("[")) return p === "[hidden]" && el.hidden;
      return el.tagName === p.toLowerCase();
    });
  };
  const specificity = (sel) => [
    (sel.match(/#/g) || []).length,
    (sel.match(/\./g) || []).length + (sel.match(/\[/g) || []).length,
    (sel.match(/(^|[\s>])([a-zA-Z][a-zA-Z0-9]*)/g) || []).length,
  ];
  let winner = null;
  let order = 0;
  for (const chunk of css.split("}")) {
    const brace = chunk.indexOf("{");
    if (brace < 0 || chunk.trim().startsWith("@")) continue;
    const decls = chunk.slice(brace + 1);
    const display = (decls.match(/(?:^|;)\s*display\s*:\s*([^;]+)/) || [])[1];
    if (!display) continue;
    for (const sel of chunk.slice(0, brace).split(",")) {
      const rightmost = sel.trim().split(/[\s>]+/).pop();
      if (!compoundMatches(rightmost)) continue;
      const spec = specificity(sel);
      if (!winner || spec.join() > winner.spec.join()
        || (spec.join() === winner.spec.join() && order > winner.order)) {
        winner = { spec, order, display: display.trim() };
      }
    }
    order += 1;
  }
  if (winner) return winner.display;
  return el.hidden ? "none" : "block";
}

const bar = byId.get("bb-dispatch") || mint("div");
const barBtn = byId.get("bb-dispatch-btn") || mint("button");
const dispatch = {
  presented: computedDisplay(bar) !== "none",
  buttonDisabled: barBtn.disabled,
  buttonWired: (barBtn.listeners.click || []).length > 0,
};

process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, error: errorText, dispatch }) + "\n");

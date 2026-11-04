// Render a built bearings report preview page's shipped inline script under a
// minimal DOM shim and print the document it produced, so preview behavior is
// asserted through the real page rather than by reading its source.
//
// Usage: node report-preview-harness.mjs <preview.html>
// Prints one JSON document:
//   { title, path, meta, blocks:[{tag,text,children}] }
// where each block child is {tag,text,href?,children}.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this._text = "";
    this.href = "";
  }
  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join("") : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  get lastChild() { return this.children[this.children.length - 1] || null; }
  appendChild(n) { this.children.push(n); return n; }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="report-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("report-data", dataNode);

globalThis.document = {
  title: "",
  createElement: (tag) => new Node(tag),
  createTextNode: (text) => { const n = new Node("#text"); n.textContent = text; return n; },
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};

const script = html.slice(html.lastIndexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const tree = (n) => {
  const out = { tag: n.tagName, text: n.textContent };
  if (n.href) out.href = n.href;
  const kids = n.children.filter((c) => c.tagName !== "#text").map(tree);
  if (kids.length) out.children = kids;
  return out;
};

process.stdout.write(JSON.stringify({
  title: document.title,
  path: byId.get("rp-path")?.textContent ?? "",
  meta: byId.get("rp-meta")?.textContent ?? "",
  blocks: (byId.get("rp-doc") || new Node("main")).children.map(tree),
}) + "\n");

// Render a built graph board's shipped inline script under a minimal DOM shim.
// The output describes rendered nodes and is the test contract, not template text.
//
// Usage: node graph-board-render-harness.mjs <built-board.html>
// Prints {tasks:[...],stale:{state,text}}.
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
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (...classes) => {
        this.className = [...new Set((this.className + " " + classes.join(" ")).trim().split(/\s+/).filter(Boolean))].join(" ");
      },
      remove: (...classes) => {
        const excluded = new Set(classes);
        this.className = this.className.split(/\s+/).filter((item) => item && !excluded.has(item)).join(" ");
      },
      contains: (value) => this.className.split(/\s+/).includes(value),
    };
  }
  get textContent() {
    return this.children.length ? this.children.map((child) => child.textContent).join("") : this._text;
  }
  set textContent(value) { this._text = String(value); this.children = []; }
  appendChild(node) { node.parentNode = this; this.children.push(node); return node; }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name === "class") this.className = String(value);
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  addEventListener(name, listener) {
    (this.listeners[name] ||= []).push(listener);
  }
  click() { (this.listeners.click || []).forEach((listener) => listener({ preventDefault() {} })); }
  querySelectorAll(selector) {
    const className = selector.match(/\.([A-Za-z0-9_-]+)/)?.[1];
    const tagName = selector.match(/^([A-Za-z0-9]+)/)?.[1];
    const checkedOnly = selector.endsWith(":checked");
    const found = [];
    const visit = (node) => {
      for (const child of node.children) {
        const tagMatches = !tagName || child.tagName === tagName;
        const classMatches = !className || child.classList.contains(className);
        if (tagMatches && classMatches && (!checkedOnly || child.checked)) found.push(child);
        visit(child);
      }
    };
    visit(this);
    return found;
  }
}

const byId = new Map();
const fixedNow = Number(process.env.FM_GRAPH_BOARD_NOW);
if (Number.isFinite(fixedNow)) {
  const RealDate = Date;
  globalThis.Date = class extends RealDate {
    static now() { return fixedNow * 1000; }
  };
}
const documentElement = new Node("html");
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="graph-board-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("graph-board-data", dataNode);

globalThis.document = {
  documentElement,
  createElement: (tag) => new Node(tag),
  createElementNS: (_namespace, tag) => new Node(tag),
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
  querySelector: () => new Node("div"),
};
globalThis.window = {
  getComputedStyle: () => ({
    getPropertyValue: (name) => ({
      "--graph-step-width": "120px",
      "--graph-step-gap": "20px",
    })[name] || "",
  }),
};
globalThis.TextEncoder = TextEncoder;

const scriptStart = html.indexOf("<script>", html.indexOf("</script>"));
const script = html.slice(scriptStart + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const attr = (node, name) => node.getAttribute(name) || "";
const classNodes = (node, className) => node.querySelectorAll("." + className);
const freshness = byId.get("graph-freshness");
const tasksRoot = byId.get("graph-tasks");
const tasks = classNodes(tasksRoot, "graph-task").map((task) => {
  const boxes = classNodes(task, "graph-step").map((box) => ({
    step: attr(box, "data-step"),
    state: attr(box, "data-state"),
    current: box.attributes["data-current"] === "true",
    evidence: attr(box, "data-evidence"),
    duration: attr(box, "data-duration"),
  }));
  const edges = classNodes(task, "graph-edge").map((edge) => {
    const d = attr(edge, "d");
    const endpoints = d.match(/^M (-?[0-9.]+) 36 C -?[0-9.]+ 36, -?[0-9.]+ 36, (-?[0-9.]+) 36$/);
    return {
      from: attr(edge, "data-from"),
      to: attr(edge, "data-to"),
      x1: endpoints ? Number(endpoints[1]) : null,
      x2: endpoints ? Number(endpoints[2]) : null,
    };
  });
  const detailButton = classNodes(task, "graph-detail")[0];
  if (detailButton) detailButton.click();
  const detail = classNodes(task, "graph-detail-panel")[0];
  return {
    id: attr(task, "data-task-id"),
    kind: attr(task, "data-kind"),
    recordState: attr(task, "data-record-state"),
    banner: classNodes(task, "graph-banner")[0]?.textContent || "",
    boxes,
    edges,
    probe: attr(task, "data-probe"),
    evidence: attr(task, "data-evidence"),
    detail: detail?.textContent || "",
    detailVisible: detail ? !detail.hidden : false,
  };
});

process.stdout.write(JSON.stringify({
  tasks,
  stale: { state: attr(freshness, "data-state"), text: freshness?.textContent || "" },
}) + "\n");

// Execute the shipped self-contained /logbook page renderer under a minimal DOM
// whose opaque-origin fetch always fails, matching Luxe's sandbox boundary.
//
// Usage: node logbook-render-harness.mjs <index.html> [--refresh]
import fs from "node:fs";
import path from "node:path";

const page = path.resolve(process.argv[2]);
const clickRefresh = process.argv[3] === "--refresh";
const html = fs.readFileSync(page, "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this._text = "";
    this.hidden = false;
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.href = "";
    this.rel = "";
    this.target = "";
  }
  get textContent() {
    return this.children.length ? this.children.map((child) => child.textContent).join("") : this._text;
  }
  set textContent(value) {
    this._text = String(value);
    this.children = [];
  }
  appendChild(node) {
    this.children.push(node);
    return node;
  }
  replaceChildren(...nodes) {
    this.children = [];
    nodes.forEach((node) => this.appendChild(node));
  }
  setAttribute(key, value) { this.attributes[key] = value; }
  addEventListener(kind, callback) { this.listeners[kind] = callback; }
}

const ids = new Map();
const element = (id) => {
  if (!ids.has(id)) ids.set(id, new Node("div"));
  return ids.get(id);
};
const payloadMatch = html.match(/<script id="firstmate-logbook-data" type="application\/json">\n([\s\S]*?)\n<\/script>/);
if (payloadMatch) element("firstmate-logbook-data").textContent = payloadMatch[1];

let reloads = 0;
let fetches = 0;
globalThis.document = {
  title: "Firstmate Logbook",
  createElement: (tag) => new Node(tag),
  getElementById: (id) => ids.has(id) || id !== "firstmate-logbook-data" ? element(id) : null,
};
globalThis.window = {};
globalThis.location = {
  href: "http://127.0.0.1/artifact/session/index.html",
  origin: "null",
  replace: (url) => {
    reloads += 1;
    globalThis.location.href = String(url);
  },
};
globalThis.setInterval = () => 1;
globalThis.fetch = async () => {
  fetches += 1;
  throw new TypeError("Failed to fetch from opaque Luxe sandbox origin");
};

const rendererScripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
if (rendererScripts.length !== 1) throw new Error(`expected one renderer script, found ${rendererScripts.length}`);
new Function(rendererScripts[0][1])();
await window.firstmateLogbookReady;
if (clickRefresh) window.firstmateLogbookRefresh();

const snapshot = {
  title: element("mission-title").textContent,
  status: element("mission-status").textContent,
  updated: element("updated-at").textContent,
  age: element("updated-age").textContent,
  notice: element("load-notice").hidden ? "" : element("load-notice").textContent,
  snapshot: element("snapshot").children.map((card) => ({
    step: card.dataset.step,
    text: card.children.at(-1)?.textContent ?? "",
  })),
  gatesMeta: element("gates-meta").textContent,
  gateTitles: element("gates").children.map((row) => row.textContent),
  milestoneTitles: element("milestones").children.map((row) => row.children[0]?.children[0]?.children[0]?.textContent ?? ""),
  blockers: element("blockers").textContent,
  final: element("final").hidden ? "" : `${element("final-label").textContent} ${element("final-outcome").textContent}`,
  fetches,
  reloads,
  refreshHref: globalThis.location.href,
};
process.stdout.write(`${JSON.stringify(snapshot)}\n`);

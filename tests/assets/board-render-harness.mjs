// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document containing stat cards, merged task rows,
// unanswered-question rows, and renderer errors.
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
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, force) => {
        const has = this.className.split(/\s+/).includes(c);
        const want = force === undefined ? !has : Boolean(force);
        if (want && !has) this.className = (this.className + " " + c).trim();
        else if (!want && has) this.className = this.className.split(/\s+/).filter((x) => x !== c).join(" ");
        return want;
      },
    };
    this.style = {};
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

const stats = (byId.get("bb-stats") || new Node("div")).children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

// A telemetry stat strip (bt-stats-*): one {label, value, noData} per card.
const btStatsOf = (container) =>
  container.children.map((t) => ({
    label: t.children.find((c) => c.className.includes("bt-stat__label"))?.textContent ?? "",
    value: t.children.find((c) => c.className.includes("bt-stat__val"))?.textContent ?? "",
    noData: t.className.includes("bt-stat--nodata"),
  }));

const taskContainer = byId.get("bb-tasks") || new Node("tbody");
const tasks = taskContainer.children
  .filter((row) => row.className.split(/\s+/).includes("bb-task-row"))
  .map((row) => {
    const stateCell = row.children[1];
    const repairBadge = stateCell?.children.find((c) => c.className.includes("fm-badge--danger"));
    const stateText = stateCell?.children.find((c) => c !== repairBadge)?.textContent ?? stateCell?.textContent ?? "";
    return {
      id: row.children[0]?.textContent.trim() ?? "",
      state: stateText,
      title: row.children[2]?.textContent ?? "",
      blocker: row.children[3]?.textContent ?? "",
      kind: row.attributes["data-kind"] ?? "underway",
      alarm: Boolean(repairBadge),
      alarmText: repairBadge?.textContent ?? "",
      pickable: row.children[0]?.querySelectorAll(".bb-pick").length > 0,
    };
  });
const legacyCopies = ["bb-charted", "bb-underway"].filter((id) => byId.has(id));
const empty = taskContainer.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const omittedIndicator = byId.get("bb-task-omitted");
const omitted = omittedIndicator?.textContent ?? "";
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const statsCost = btStatsOf(byId.get("bt-stats-cost") || new Node("div"));
const statsFleet = btStatsOf(byId.get("bt-stats-fleet") || new Node("div"));
const qContainer = byId.get("bb-questions") || new Node("div");
const questionRows = qContainer.children
  .filter((r) => r.className.split(/\s+/).includes("bb-question-row"))
  .map((row) => ({
    id: row.children[0]?.textContent ?? "",
    urgency: row.children[1]?.textContent ?? "",
    question: row.children[2]?.textContent ?? "",
    action: row.children[3]?.textContent ?? "",
  }));
const questionsEmpty = qContainer.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const calls = (byId.get("bb-call") || new Node("div")).children.map((card) => ({
  title: card.children[0]?.children.find((c) => c.className.includes("bb-decision__title"))?.textContent ?? "",
  badges: card.children[0]?.children.find((c) => c.className.includes("bb-decision__top"))?.children.map((c) => c.textContent) ?? [],
}));

process.stdout.write(
  JSON.stringify({
    stats, tasks, legacyCopies, empty, omitted, omittedHidden: omittedIndicator?.hidden ?? true, error: errorText,
    statsCost, statsFleet, questions: questionRows, questionsEmpty, calls,
  }) + "\n");

// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [interaction mode]
// Interaction modes submit freeform only, choices only, or both controls in
// either order on every Captain's Call card through the public Lavish queue
// interface. The result includes rendered state, captured calls, and
// protocol-shaped Lavish output.
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
    this.name = "";
    this.placeholder = "";
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((name) => name && name !== c).join(" ");
      },
      toggle: (c, force) => {
        const present = this.className.split(/\s+/).includes(c);
        const wanted = force === undefined ? !present : force;
        if (wanted && !present) this.className = (this.className + " " + c).trim();
        if (!wanted && present) {
          this.className = this.className.split(/\s+/).filter((name) => name && name !== c).join(" ");
        }
        return wanted;
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
  addEventListener(type, listener) {
    if (!this.listeners[type]) this.listeners[type] = [];
    this.listeners[type].push(listener);
  }
  dispatch(type) {
    const event = { preventDefault() {} };
    for (const listener of this.listeners[type] || []) listener(event);
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
const queuedPrompts = [];
globalThis.window = {
  lavish: {
    queuePrompt(prompt, options) {
      const question = options.element?.attributes["data-lavish-question"] || "";
      const queueKey = options.queueKey || (question ? "question:" + question : "");
      const queued = {
        prompt,
        tag: options.tag,
        text: options.text,
        queueKey,
        data: options.data || {},
      };
      const existing = queueKey
        ? queuedPrompts.findIndex((candidate) => candidate.queueKey === queueKey)
        : -1;
      if (existing === -1) queuedPrompts.push(queued);
      else queuedPrompts[existing] = queued;
    },
  },
};
globalThis.TextEncoder = TextEncoder;
globalThis.FormData = class {
  constructor(form) {
    this.values = new Map();
    const visit = (node) => {
      if (node.name && (node.type !== "radio" || node.checked)) this.values.set(node.name, node.value);
      node.children.forEach(visit);
    };
    visit(form);
  }
  get(name) { return this.values.has(name) ? this.values.get(name) : null; }
};

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

const descendants = (node) => {
  const out = [];
  const walk = (current) => {
    current.children.forEach((child) => { out.push(child); walk(child); });
  };
  walk(node);
  return out;
};

const lavishResult = (calls) => {
  const escaped = (value) => '"' + String(value)
    .replaceAll("\\", "\\\\")
    .replaceAll('"', '\\"')
    .replaceAll("\n", "\\n") + '"';
  const rows = calls.map((call, index) => {
    const prompt = call.prompt + "\n\nContext data:\n" + JSON.stringify(call.data);
    return "  " + [String(index + 1), prompt, "form", call.tag, call.text].map(escaped).join(",");
  });
  return [
    "session:",
    "  file: /bearings-board.html",
    "  status: feedback",
    "  session_ended: false",
    `prompts[${calls.length}]{uid,prompt,selector,tag,text}:`,
    ...rows,
  ].join("\n") + "\n";
};

const interactions = [];
const interactionMode = process.argv[3] || "";
const interactionModes = [
  "--freeform-interactions",
  "--choice-interactions",
  "--mixed-choice-first",
  "--mixed-freeform-first",
];
if (interactionModes.includes(interactionMode)) {
  const callDeck = byId.get("bb-call") || new Node("div");
  const stackCount = byId.get("bb-stack-count") || new Node("div");
  const stackPrev = byId.get("bb-stack-prev") || new Node("button");
  const stackNext = byId.get("bb-stack-next") || new Node("button");
  const refreshStack = () => {
    stackNext.dispatch("click");
    stackPrev.dispatch("click");
  };
  callDeck.children.forEach((card) => {
    const nodes = descendants(card);
    const freeform = nodes.find((node) => node.className.split(/\s+/).includes("bb-freeform"));
    const freeformForm = nodes.find((node) => node.className.split(/\s+/).includes("bb-freeform-form"));
    const choiceForm = nodes.find((node) => node.attributes["data-lavish-question"] && node !== freeformForm);
    const label = nodes.find((node) => node.className.split(/\s+/).includes("bb-freeform-label"));
    const question = choiceForm?.attributes["data-lavish-question"] || freeformForm?.attributes["data-lavish-question"] || "";
    const submitFreeform = () => {
      if (!freeform || !freeformForm) return;
      freeform.value = "Need more context for " + question;
      freeformForm.dispatch("submit");
    };
    const submitChoice = () => {
      const radio = nodes.find((node) => node.type === "radio" && node.value !== "reconcile");
      if (!radio || !choiceForm) return;
      radio.checked = true;
      choiceForm.dispatch("submit");
    };
    if (interactionMode === "--freeform-interactions") submitFreeform();
    if (interactionMode === "--choice-interactions") submitChoice();
    if (interactionMode === "--mixed-choice-first") {
      submitChoice();
      submitFreeform();
    }
    if (interactionMode === "--mixed-freeform-first") {
      submitFreeform();
      submitChoice();
    }
    refreshStack();
    interactions.push({
      question,
      hasFreeform: Boolean(freeform && freeformForm),
      freeformLabel: label?.textContent || "",
      freeformPlaceholder: freeform?.placeholder || "",
      messageQueued: Boolean(freeformForm?.classList.contains("is-queued")),
      choiceQueued: Boolean(choiceForm?.classList.contains("is-queued")),
      cardQueued: card.classList.contains("is-queued"),
      cardAnswered: card.classList.contains("is-answered"),
      stackStatus: stackCount.textContent,
    });
  });
}
const freeformCalls = queuedPrompts.filter((call) => call.tag === "prompt");
const choiceCalls = queuedPrompts.filter((call) => call.tag === "choice");

process.stdout.write(JSON.stringify({
  stats,
  underway,
  charted,
  empty,
  more,
  error: errorText,
  interactions,
  queuedPrompts,
  freeformLavishResult: lavishResult(freeformCalls),
  choiceLavishResult: lavishResult(choiceCalls),
}) + "\n");

// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}],
//     calls:[{fields:[{cls,text,links:[{text,href,target,rel}]}]}],
//     empty, more, error }
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const html = readFileSync(process.argv[2], "utf8");

if (process.argv[3] === "--layout") {
  const dir = mkdtempSync(join(tmpdir(), "board-layout-"));
  try {
    const probe = `<script>
      document.querySelectorAll('.bb-decision').forEach(card => {
        card.hidden = false;
        card.style.width = '280px';
      });
      const fields = [...document.querySelectorAll('.bb-decision__title, .bb-opt__label')].map(n => ({
        cls: n.className, text: n.textContent, links: n.querySelectorAll('a').length,
        wrap: getComputedStyle(n).overflowWrap, width: n.clientWidth, scroll: n.scrollWidth
      }));
      const result = document.createElement('pre');
      result.id = 'layout-result';
      result.textContent = encodeURIComponent(JSON.stringify(fields));
      document.body.appendChild(result);
    </script>`;
    const file = join(dir, "board.html");
    writeFileSync(file, html.replace("</body>", probe + "</body>"));
    const browser = spawnSync(process.argv[4], ["--headless", "--no-sandbox", "--disable-gpu",
      "--no-first-run", "--user-data-dir=" + join(dir, "profile"), "--dump-dom", "file://" + file],
      { encoding: "utf8", timeout: 30000, maxBuffer: 5 * 1024 * 1024 });
    const result = browser.stdout?.match(/<pre id="layout-result">([^<]+)<\/pre>/);
    if (browser.status !== 0 || !result) throw new Error(browser.error?.message || browser.stderr || "No browser layout result");
    process.stdout.write(decodeURIComponent(result[1]) + "\n");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
  process.exit(0);
}

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
      remove: (c) => { this.className = this.className.split(/\s+/).filter((k) => k && k !== c).join(" "); },
      toggle: (c, on) => {
        const has = this.className.split(/\s+/).includes(c);
        if (on === undefined ? !has : on) { if (!has) this.classList.add(c); } else this.classList.remove(c);
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
// Captain's Call free-text fields, with the links each one carries.
const FREE_TEXT = ["bb-decision__title", "bb-decision__detail", "bb-ctx__v", "bb-opt__label", "bb-opt__hint"];
const calls = (byId.get("bb-call") || new Node("div")).children
  .filter((c) => c.className.split(/\s+/).includes("bb-decision"))
  .map((card) => {
    const fields = [];
    const walk = (n) => {
      for (const c of n.children) {
        const cls = c.className.split(/\s+/).find((k) => FREE_TEXT.includes(k));
        if (cls) {
          fields.push({
            cls, text: c.textContent, tags: c.children.map((k) => k.tagName),
            links: c.children.filter((k) => k.tagName === "a")
              .map((a) => ({ text: a.textContent, href: a.href, target: a.target, rel: a.rel })),
          });
        } else walk(c);
      }
    };
    walk(card);
    return { fields };
  });
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, underway, charted, calls, empty, more, error: errorText }) + "\n");

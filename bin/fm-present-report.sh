#!/usr/bin/env bash
# fm-present-report.sh - render one canonical Markdown report or Bearings snapshot as static local HTML.
#
# Usage:
#   fm-present-report.sh markdown --source <report.md> [--open]
#   fm-present-report.sh bearings --source <report.md> --snapshot <snapshot.json> [--open]
#
# The output is a timestamped file under the effective home's gitignored .lavish/
# directory. Rendering and browser-open failures return the canonical Markdown
# fallback on stdout and exit successfully so presentation never blocks completion.
# The script performs no network operations and serves no content.
set -u

usage() {
  sed -n '2,10s/^# \{0,1\}//p' "$0" >&2
}

MODE=${1:-}
case "$MODE" in markdown|bearings) shift ;; *) usage; exit 2 ;; esac
SOURCE=
SNAPSHOT=
OPEN_PAGE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) shift; SOURCE=${1:-} ;;
    --snapshot) shift; SNAPSHOT=${1:-} ;;
    --open) OPEN_PAGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift
done

[ -n "$SOURCE" ] || { usage; exit 2; }
[ -f "$SOURCE" ] || { printf 'fm-present-report: canonical Markdown not found: %s\n' "$SOURCE" >&2; exit 2; }
if [ "$MODE" = bearings ] && [ -z "$SNAPSHOT" ]; then
  usage
  exit 2
fi
command -v node >/dev/null 2>&1 || {
  printf 'fm-present-report: could not render static HTML because node is unavailable; using canonical Markdown: %s\n' "$SOURCE" >&2
  printf 'markdown:%s\n' "$SOURCE"
  exit 0
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}
OUTPUT_DIR="$FM_HOME/.lavish"
NOW=${FM_PRESENT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
STAMP=$(printf '%s' "$NOW" | tr -d ':-' | sed 's/\.000Z$/Z/; s/\.[0-9][0-9]*Z$/Z/')
case "$STAMP" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) STAMP=$(date -u +%Y%m%dT%H%M%SZ) ;;
esac
if [ "$MODE" = bearings ]; then
  NAME="bearings-$STAMP.html"
else
  BASE=$(basename "$SOURCE")
  BASE=${BASE%.*}
  BASE=$(printf '%s' "$BASE" | tr -cs 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')
  [ -n "$BASE" ] || BASE=report
  NAME="$BASE-$STAMP.html"
fi
OUTPUT="$OUTPUT_DIR/$NAME"
TEMP="$OUTPUT.tmp.$$"
mkdir -p "$OUTPUT_DIR" || {
  printf 'fm-present-report: could not render static HTML under %s; using canonical Markdown: %s\n' "$OUTPUT_DIR" "$SOURCE" >&2
  printf 'markdown:%s\n' "$SOURCE"
  exit 0
}

if ! FM_PRESENT_MODE="$MODE" \
  FM_PRESENT_SOURCE="$SOURCE" \
  FM_PRESENT_SNAPSHOT="$SNAPSHOT" \
  FM_PRESENT_NOW_VALUE="$NOW" \
  node --input-type=module >"$TEMP" <<'JS'
import { readFileSync, realpathSync } from "node:fs";
import { dirname, extname, isAbsolute, relative, resolve, sep } from "node:path";

const mode = process.env.FM_PRESENT_MODE;
const sourcePath = process.env.FM_PRESENT_SOURCE;
const snapshotPath = process.env.FM_PRESENT_SNAPSHOT;
const observedAt = process.env.FM_PRESENT_NOW_VALUE;

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

const sourceDirectory = dirname(realpathSync(sourcePath));
const safeSvgElements = new Set([
  "svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
  "text", "tspan", "title", "desc", "clipPath", "mask", "linearGradient", "radialGradient",
  "stop", "pattern", "marker",
]);

function inlineText(value) {
  return escapeHtml(value)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>");
}

function safeHttps(destination) {
  if (!/^https:\/\//i.test(destination) || /[\s\u0000-\u001f\u007f]/u.test(destination)) return false;
  try {
    const parsed = new URL(destination);
    return parsed.protocol === "https:" && Boolean(parsed.hostname);
  } catch {
    return false;
  }
}

function safeSvgAttributes(source, root) {
  let remaining = source;
  let svgNamespace = false;
  while (remaining) {
    const attribute = remaining.match(/^\s+([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*(["'])(.*?)\2/s);
    if (!attribute) return null;
    const name = attribute[1];
    const lowerName = name.toLowerCase();
    const value = attribute[3];
    remaining = remaining.slice(attribute[0].length);
    if (/^on/.test(lowerName) || ["href", "xlink:href", "src", "style"].includes(lowerName)) return null;
    if (name.includes(":") && name !== "xml:space") return null;
    if (lowerName === "xmlns") {
      if (!root || value !== "http://www.w3.org/2000/svg") return null;
      svgNamespace = true;
      continue;
    }
    if (/xmlns|(?:javascript|data|file|https?):|\/\/|@import|expression\s*\(|-moz-binding/i.test(`${name}=${value}`)) return null;
    const withoutLocalReferences = value.replace(/url\(\s*#[-A-Za-z0-9_.:]+\s*\)/gi, "");
    if (/url\s*\(/i.test(withoutLocalReferences) || /[\u0000-\u001f\u007f]/u.test(value)) return null;
  }
  return { svgNamespace };
}

function safeSvg(bytes) {
  let svg;
  try {
    svg = new TextDecoder("utf-8", { fatal: true }).decode(bytes).trim();
  } catch {
    return false;
  }
  if (!svg.startsWith("<svg") || /<!|<\?|<!--/.test(svg)) return false;
  if (/&(?!(?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9A-Fa-f]+);)/.test(svg)) return false;

  const stack = [];
  const tags = svg.matchAll(/<([^<>]+)>/g);
  let cursor = 0;
  let rootSeen = false;
  for (const tag of tags) {
    if (/[<>]/.test(svg.slice(cursor, tag.index))) return false;
    cursor = tag.index + tag[0].length;
    const content = tag[1];
    if (content.startsWith("/")) {
      const closing = content.match(/^\/([A-Za-z][A-Za-z0-9-]*)\s*$/);
      if (!closing || stack.pop() !== closing[1]) return false;
      continue;
    }

    const selfClosing = /\/\s*$/.test(content);
    const opening = content.replace(/\/\s*$/, "").match(/^([A-Za-z][A-Za-z0-9-]*)([\s\S]*)$/);
    if (!opening || !safeSvgElements.has(opening[1])) return false;
    const isRoot = !rootSeen;
    if ((isRoot && opening[1] !== "svg") || (!isRoot && stack.length === 0)) return false;
    const attributes = safeSvgAttributes(opening[2], isRoot);
    if (!attributes || (isRoot && !attributes.svgNamespace)) return false;
    rootSeen = true;
    if (!selfClosing) stack.push(opening[1]);
  }
  return rootSeen && stack.length === 0 && !/[<>]/.test(svg.slice(cursor)) && cursor === svg.length;
}

function reportImage(destination) {
  if (!destination || destination !== destination.trim() || isAbsolute(destination) || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(destination) || destination.startsWith("//") || destination.includes("\0")) return null;
  const extension = extname(destination).toLowerCase();
  if (extension !== ".png" && extension !== ".svg") return null;
  try {
    const assetPath = realpathSync(resolve(sourceDirectory, destination));
    const localPath = relative(sourceDirectory, assetPath);
    if (localPath === ".." || localPath.startsWith(`..${sep}`) || isAbsolute(localPath)) return null;
    const bytes = readFileSync(assetPath);
    if (extension === ".svg" && !safeSvg(bytes)) return null;
    const mediaType = extension === ".png" ? "image/png" : "image/svg+xml";
    return `data:${mediaType};base64,${bytes.toString("base64")}`;
  } catch {
    return null;
  }
}

function inlineMarkdown(value) {
  const output = [];
  const syntax = /!\[([^\]]*)\]\(([^)]+)\)|\[([^\]]+)\]\(([^)]+)\)/g;
  let cursor = 0;
  for (const match of value.matchAll(syntax)) {
    output.push(inlineText(value.slice(cursor, match.index)));
    if (match[1] !== undefined) {
      const alt = match[1];
      const destination = match[2];
      const dataUri = reportImage(destination);
      output.push(dataUri
        ? `<img class="report-image" src="${dataUri}" alt="${escapeHtml(alt)}">`
        : `<span class="reference image-reference">Image: ${inlineText(alt)} <code>${escapeHtml(destination)}</code></span>`);
    } else {
      const label = match[3];
      const destination = match[4];
      output.push(safeHttps(destination)
        ? `<a href="${escapeHtml(destination)}" target="_blank" rel="noopener noreferrer">${inlineText(label)}<span class="visually-hidden"> (opens in new tab)</span></a>`
        : `<span class="reference">${inlineText(label)} <code>${escapeHtml(destination)}</code></span>`);
    }
    cursor = match.index + match[0].length;
  }
  output.push(inlineText(value.slice(cursor)));
  return output.join("");
}

function renderMarkdown(markdown) {
  const output = [];
  let paragraph = [];
  let list = null;
  let fence = null;
  let code = [];
  const flushParagraph = () => {
    if (paragraph.length > 0) output.push(`<p>${inlineMarkdown(paragraph.join(" "))}</p>`);
    paragraph = [];
  };
  const flushList = () => {
    if (!list) return;
    output.push(`<${list.type}>${list.items.map((item) => `<li>${inlineMarkdown(item)}</li>`).join("")}</${list.type}>`);
    list = null;
  };
  const flushCode = () => {
    output.push(`<pre><code${fence ? ` class="language-${escapeHtml(fence)}"` : ""}>${escapeHtml(code.join("\n"))}</code></pre>`);
    code = [];
    fence = null;
  };

  for (const line of markdown.replaceAll("\r\n", "\n").split("\n")) {
    const fenceMatch = line.match(/^```\s*([^ ]*)/);
    if (fenceMatch) {
      if (fence !== null) flushCode();
      else {
        flushParagraph();
        flushList();
        fence = fenceMatch[1] || "text";
      }
      continue;
    }
    if (fence !== null) {
      code.push(line);
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      flushParagraph();
      flushList();
      const level = heading[1].length;
      output.push(`<h${level}>${inlineMarkdown(heading[2])}</h${level}>`);
      continue;
    }
    const unordered = line.match(/^\s*[-*]\s+(.+)$/);
    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
    if (unordered || ordered) {
      flushParagraph();
      const type = ordered ? "ol" : "ul";
      if (list?.type !== type) {
        flushList();
        list = { type, items: [] };
      }
      list.items.push((ordered ?? unordered)[1]);
      continue;
    }
    if (!line.trim()) {
      flushParagraph();
      flushList();
      continue;
    }
    paragraph.push(line.trim());
  }
  if (fence !== null) flushCode();
  flushParagraph();
  flushList();
  return output.join("\n");
}

const style = `
:root{color-scheme:light;--canvas:#f7f6f3;--surface:#fff;--ink:#20211f;--muted:#666862;--line:#deded9;--accent:#315f4b;--call:#fdf0ef;--call-ink:#7f322d;--code:#efeee9}
*{box-sizing:border-box}
html{background:var(--canvas);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;line-height:1.6}
body{margin:0}
.skip-link{position:absolute;left:1rem;top:-5rem;background:var(--ink);color:#fff;padding:.6rem .9rem;z-index:2}
.skip-link:focus{top:1rem}
.visually-hidden{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
:focus-visible{outline:3px solid #245f9a;outline-offset:3px}
.site-header,main,footer{width:min(76ch,calc(100% - 2rem));margin-inline:auto}
.site-header{padding:clamp(3rem,8vw,7rem) 0 2rem;border-bottom:1px solid var(--line)}
.eyebrow{font-size:.78rem;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);font-weight:700}
h1{font-family:Georgia,"Times New Roman",serif;font-size:clamp(2.2rem,7vw,4.6rem);line-height:1.04;letter-spacing:-.035em;margin:.5rem 0 1rem;text-wrap:balance}
h2{font-size:1.2rem;line-height:1.25;margin:3rem 0 1rem}
h3{font-size:1rem;margin:2rem 0 .5rem}
p,ul,ol,pre{margin:0 0 1.2rem}a{color:var(--accent)}code{font-family:"SFMono-Regular",Consolas,monospace;background:var(--code);padding:.1em .3em;border-radius:4px;font-size:.9em}
pre{overflow:auto;background:var(--code);padding:1rem;border:1px solid var(--line);border-radius:8px}pre code{padding:0}
.report-image{display:block;max-width:100%;height:auto;margin:1.5rem auto;border-radius:8px}
.report{background:var(--surface);border:1px solid var(--line);padding:clamp(1.25rem,4vw,3rem);margin:2rem auto}
section{border-top:1px solid var(--line);padding-top:.1rem}.records{list-style:none;padding:0;margin:0}.record{padding:1rem 0;border-bottom:1px solid var(--line);display:grid;grid-template-columns:minmax(9rem,14rem) 1fr;gap:.35rem 1.25rem}.record strong{overflow-wrap:anywhere}.record p{margin:0;color:var(--muted)}
.captains-call .record{background:var(--call);color:var(--call-ink);margin-inline:-.75rem;padding-inline:.75rem}.empty{color:var(--muted)}
details{border-top:1px solid var(--line);padding:1rem 0}summary{cursor:pointer;font-weight:700}footer{padding:1rem 0 4rem;color:var(--muted);font-size:.9rem;overflow-wrap:anywhere}
@media(max-width:42rem){.record{grid-template-columns:1fr}.site-header{padding-top:3rem}}
@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto!important;transition:none!important}}
@media print{html{background:#fff}.skip-link{display:none}.report{border:0;padding:0}.site-header,main,footer{width:100%}}
`;

function shell({ title, eyebrow, intro, body, schema = "canonical Markdown", observed = observedAt }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
<title>${escapeHtml(title)}</title>
<style>${style}</style>
</head>
<body>
<a class="skip-link" href="#content">Skip to report</a>
<header class="site-header">
<div class="eyebrow">${escapeHtml(eyebrow)}</div>
<h1>${escapeHtml(title)}</h1>
<p>${intro}</p>
<p>Observed <time datetime="${escapeHtml(observed)}">${escapeHtml(observed)}</time></p>
</header>
<main id="content" class="report" aria-label="${escapeHtml(title)}">${body}</main>
<footer>Canonical source: <code>${escapeHtml(sourcePath)}</code><br>Projection source: <code>${escapeHtml(schema)}</code></footer>
</body>
</html>`;
}

const markdown = readFileSync(sourcePath, "utf8");
if (mode === "markdown") {
  const firstHeading = markdown.match(/^#\s+(.+)$/m)?.[1] ?? "Firstmate report";
  process.stdout.write(shell({
    title: firstHeading,
    eyebrow: "Firstmate report",
    intro: "A static reading copy. The Markdown file remains authoritative.",
    body: `<article aria-label="Canonical report">${renderMarkdown(markdown.replace(/^#\s+.+\n?/, ""))}</article>`,
  }));
} else if (mode === "bearings") {
  const snapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));
  if (snapshot?.schema !== "fm-bearings.v1") throw new Error("unsupported Bearings schema");
  if (snapshot.unhealthy_endpoints === undefined) snapshot.unhealthy_endpoints = [];
  for (const key of ["in_flight", "secondmates", "decisions_open", "landed", "gates", "unhealthy_endpoints", "omitted"]) {
    if (!Array.isArray(snapshot[key])) throw new Error(`Bearings snapshot is missing ${key}`);
  }
  if (typeof snapshot.generated !== "string" || !snapshot.generated) throw new Error("Bearings snapshot is missing generated");
  const secondmateMirrors = new Set();
  const decisions = [];
  const underway = [];
  const charted = [];
  const landed = [];
  const add = (target, kind, row, primary, detail) => {
    const id = String(row.id ?? "unknown");
    target.push({ id, kind, primary, detail });
  };
  for (const row of snapshot.decisions_open) add(decisions, "decision", row, row.summary ?? row.id, `${row.owner ?? "-"} · ${row.verb ?? "decision"}`);
  for (const row of snapshot.unhealthy_endpoints) add(decisions, "endpoint", row, row.id, `${row.state ?? "unhealthy"} · ${row.reason ?? "Endpoint unavailable"}`);
  for (const row of snapshot.secondmates) {
    const target = row.state === "active_child_work" ? underway : charted;
    const freshness = `${row.freshness ?? "freshness unknown"}${Number.isFinite(row.age_seconds) ? ` · observed ${row.age_seconds}s before snapshot` : ""}`;
    const contradiction = row.contradiction ? ` · contradiction: ${row.reason ?? "reported"}` : "";
    add(target, "secondmate", row, row.id, `${row.state ?? "unknown"} · ${row.doing ?? row.reason ?? "Current detail unavailable"} · ${freshness}${contradiction}`);
    secondmateMirrors.add(String(row.id ?? "unknown"));
  }
  for (const row of snapshot.in_flight) {
    if (row.kind === "secondmate" && secondmateMirrors.has(String(row.id ?? "unknown"))) continue;
    add(underway, "worker", row, row.id, `${row.state ?? "unknown"} · ${row.doing ?? "Current detail unavailable"}`);
  }
  for (const row of snapshot.gates) add(charted, "gate", row, row.title ?? row.id, `Blocked by ${row.blocked_by ?? "-"} · ${row.reason ?? "queued"}`);
  for (const row of snapshot.landed) add(landed, "landed", row, row.what ?? row.id, `${row.owner ?? "-"} · ${row.artifact ?? "-"}`);

  const records = (items, empty) => items.length === 0
    ? `<p class="empty">${escapeHtml(empty)}</p>`
    : `<ul class="records">${items.map((item) => `<li class="record" data-record-kind="${escapeHtml(item.kind)}" data-record-id="${escapeHtml(item.id)}"><strong>${escapeHtml(item.primary)}</strong><p>${escapeHtml(item.detail)}</p></li>`).join("")}</ul>`;
  const omissions = snapshot.omitted.length === 0
    ? "<p>No omitted surfaces were reported.</p>"
    : `<ul>${snapshot.omitted.map((item) => `<li><strong>${escapeHtml(item.surface)}</strong> - reveal with <code>${escapeHtml(item.reveal)}</code></li>`).join("")}</ul>`;
  const body = `
<section class="captains-call" aria-labelledby="captains-call"><h2 id="captains-call">Captain's Call</h2>${records(decisions, "Nothing needs your action right now.")}</section>
<section aria-labelledby="recently-landed"><h2 id="recently-landed">Recently Landed</h2>${records(landed, "No recent completions are in the current baseline.")}</section>
<section aria-labelledby="underway"><h2 id="underway">Underway</h2>${records(underway, "Nothing is underway.")}</section>
<section aria-labelledby="charted-next"><h2 id="charted-next">Charted Next</h2>${records(charted, "Nothing is queued.")}</section>
<details><summary>Omissions and data health</summary>${omissions}<p>PR enrichment: ${escapeHtml(snapshot.prs ?? "not reported")}</p></details>`;
  process.stdout.write(shell({
    title: "Fleet bearings",
    eyebrow: `${underway.length} current · ${decisions.length} Captain's Call`,
    intro: "An on-demand Firstmate snapshot. Run <code>/bearings</code> again to refresh.",
    body,
    schema: snapshot.schema,
    observed: snapshot.generated,
  }));
} else {
  throw new Error("unsupported presentation mode");
}
JS
then
  rm -f "$TEMP"
  printf 'fm-present-report: could not render static HTML; using canonical Markdown: %s\n' "$SOURCE" >&2
  printf 'markdown:%s\n' "$SOURCE"
  exit 0
fi

if ! mv "$TEMP" "$OUTPUT"; then
  rm -f "$TEMP"
  printf 'fm-present-report: could not publish static HTML; using canonical Markdown: %s\n' "$SOURCE" >&2
  printf 'markdown:%s\n' "$SOURCE"
  exit 0
fi

if [ "$OPEN_PAGE" = 1 ]; then
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ] && command -v open >/dev/null 2>&1; then
    OPEN_COMMAND=open
  elif command -v xdg-open >/dev/null 2>&1; then
    OPEN_COMMAND=xdg-open
  else
    OPEN_COMMAND=
  fi
  if [ -z "$OPEN_COMMAND" ] || ! "$OPEN_COMMAND" "$OUTPUT" >/dev/null 2>&1; then
    printf 'fm-present-report: could not open %s; using canonical Markdown: %s\n' "$OUTPUT" "$SOURCE" >&2
    printf 'markdown:%s\n' "$SOURCE"
    exit 0
  fi
fi
printf 'html:%s\n' "$OUTPUT"

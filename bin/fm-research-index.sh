#!/usr/bin/env bash
# Generate (or regenerate) data/research-index.html from all scout reports
# and HTML research artifacts under data/.
#
# Usage: bin/fm-research-index.sh
# Called by hand after a report is written, or from a teardown hook.
set -euo pipefail
HOME="${FM_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DATA="$HOME/data"
INDEX="$DATA/research-index.html"

python3 - "$DATA" "$INDEX" <<'PY'
import sys, os, re, datetime, glob
from collections import OrderedDict

data_dir = sys.argv[1]
index_path = sys.argv[2]

EXCLUDE = {'research-index.html', '.lavish'}

entries = []

def file_dt(path):
    st = os.stat(path)
    return datetime.datetime.fromtimestamp(st.st_mtime)

def strip_html_tags(text):
    text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL)
    text = re.sub(r'<script[^>]*>.*?</script>', '', text, flags=re.DOTALL)
    text = re.sub(r'<[^>]+>', ' ', text)
    return re.sub(r'\s+', ' ', text).strip()

def escape(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')

def extract_md_summary(path):
    text = open(path, errors='replace').read()
    def prose_lines(block):
        out = []
        for l in block.splitlines():
            s = l.strip()
            if not s: continue
            if s.startswith('#') or s.startswith('---'): continue
            if s.startswith('|') or s.startswith('- ') or s.startswith('**Task:') or s.startswith('**Scout task'): continue
            if s.startswith('**') and ':' in s[:30] and len(s) < 80: continue
            out.append(s)
            if len(out) >= 4: break
        return out
    m = re.search(r'^##\s+[\d.]*\s*Executive\s+Summary\s*$', text, re.MULTILINE | re.IGNORECASE)
    if m:
        chunk = text[m.end():]
        m2 = re.search(r'^##\s+', chunk, re.MULTILINE)
        if m2: chunk = chunk[:m2.start()]
        lines = prose_lines(chunk)
        if lines: return ' '.join(lines)[:300]
    lines = prose_lines(text)
    if lines: return ' '.join(lines)[:300]
    return None

def extract_html_summary(path, title):
    text = open(path, errors='replace').read()
    clean = strip_html_tags(text)
    clean = clean[len(title):].strip()
    if len(clean) > 300:
        return clean[:300].rsplit(' ', 1)[0]
    return clean[:300] if clean else None

def rel_path(path):
    return os.path.relpath(path, data_dir)

def add_report(name, report):
    text = open(report, errors='replace').read()
    m = re.search(r'^# (.+)$', text, re.MULTILINE)
    title = m.group(1).strip() if m else name
    dt = file_dt(report)
    summary = extract_md_summary(report) or 'Scout report.'
    entries.append({
        'dt': dt, 'date': dt.strftime('%Y-%m-%d'), 'time': dt.strftime('%H:%M'),
        'title': title, 'summary': summary,
        'path': rel_path(report), 'type': 'report',
        'md': text,
    })

def add_html(name, path, default_title=None):
    text = open(path, errors='replace').read()
    tm = re.search(r'<title>([^<]+)</title>', text, re.IGNORECASE)
    title = (tm.group(1).strip() if tm else default_title or os.path.basename(path))
    dt = file_dt(path)
    summary = extract_html_summary(path, title) or 'HTML research artifact.'
    entries.append({
        'dt': dt, 'date': dt.strftime('%Y-%m-%d'), 'time': dt.strftime('%H:%M'),
        'title': title, 'summary': summary,
        'path': rel_path(path), 'type': 'html',
    })

# --- Scout reports ---
for name in sorted(os.listdir(data_dir)):
    if name in EXCLUDE: continue
    report = os.path.join(data_dir, name, 'report.md')
    if os.path.isfile(report):
        add_report(name, report)

# --- HTML in subdirs ---
for name in sorted(os.listdir(data_dir)):
    if name in EXCLUDE: continue
    index_html = os.path.join(data_dir, name, 'index.html')
    if os.path.isfile(index_html):
        add_html(name, index_html)

# --- Top-level HTML ---
for path in sorted(glob.glob(os.path.join(data_dir, '*.html'))):
    basename = os.path.basename(path)
    if basename in EXCLUDE: continue
    add_html(basename, path)

# Sort newest first
entries.sort(key=lambda e: e['dt'], reverse=True)

by_date = OrderedDict()
for e in entries:
    by_date.setdefault(e['date'], []).append(e)

report_count = sum(1 for e in entries if e['type'] == 'report')
html_count = sum(1 for e in entries if e['type'] == 'html')
now_str = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')

# Build HTML
L = []
L.append('<!doctype html>')
L.append('<html lang="en">')
L.append('<head>')
L.append('  <meta charset="utf-8" />')
L.append('  <meta name="viewport" content="width=device-width, initial-scale=1" />')
L.append('  <title>Research Index — Firstmate Fleet</title>')
L.append('  <style>')
L.append('    :root {')
L.append("      --paper: #fbfaf7; --ink: #1b1a17; --soft: #423e38; --muted: #6e6a62;")
L.append("      --hair: #e4dfd5; --fill: #f3efe6; --accent: #cb4322; --accent-ink: #a5341a;")
L.append("      --green: #286446; --amber: #956b12;")
L.append("      --serif: 'Times New Roman', Georgia, 'DejaVu Serif', serif;")
L.append('    }')
L.append('    * { box-sizing: border-box; }')
L.append('    html { background: var(--paper); color: var(--ink); }')
L.append('    body { max-width: 80rem; margin: 0 auto; padding: 2.5rem clamp(1.1rem,4vw,3.25rem) 4rem; font-family: var(--serif); font-size: 1.04rem; line-height: 1.58; }')
L.append('    h1 { max-width: 18ch; margin-bottom: .4rem; font-size: clamp(2rem,5vw,3.2rem); line-height: 1.08; letter-spacing: -.03em; }')
L.append('    .standfirst { max-width: 70ch; margin-bottom: 2rem; font-size: 1.1rem; color: var(--soft); }')
L.append('    .meta-row { display: flex; flex-wrap: wrap; gap: .5rem 1.5rem; padding: .75rem 0; border-top: 1px solid var(--hair); border-bottom: 1px solid var(--hair); color: var(--muted); font-size: .88rem; margin-bottom: 2rem; }')
L.append('    h2 { margin: 2.5rem 0 .75rem; padding-top: .6rem; border-top: 1px solid var(--ink); font-size: 1.3rem; line-height: 1.2; color: var(--muted); text-transform: uppercase; letter-spacing: .08em; }')
L.append('    h2:first-of-type { border-top: none; padding-top: 0; margin-top: 0; }')
L.append('    .entry { padding: 1rem 0; border-bottom: 1px solid var(--hair); }')
L.append('    .entry:last-child { border-bottom: none; }')
L.append('    .entry-header { display: flex; align-items: baseline; gap: .75rem; flex-wrap: wrap; margin-bottom: .3rem; }')
L.append('    .entry-time { font-size: .8rem; color: var(--muted); font-variant-numeric: tabular-nums; min-width: 4.5rem; }')
L.append('    .entry-type { display: inline-block; font-size: .68rem; letter-spacing: .12em; text-transform: uppercase; padding: .1rem .4rem; border: 1px solid var(--hair); border-radius: 99px; color: var(--muted); }')
L.append('    .entry-type.report { color: var(--accent-ink); border-color: var(--accent); }')
L.append('    .entry-type.html { color: var(--green); }')
L.append('    .entry-title { font-size: 1.1rem; font-weight: bold; }')
L.append('    .entry-title a { color: var(--ink); text-decoration: none; }')
L.append('    .entry-title a:hover { color: var(--accent-ink); text-decoration: underline; text-underline-offset: .15em; }')
L.append('    .entry-summary { color: var(--soft); font-size: .98rem; line-height: 1.5; margin-top: .35rem; }')
L.append('    .legend { display: flex; gap: 1.5rem; font-size: .85rem; color: var(--muted); margin-bottom: 1.5rem; }')
L.append('    .legend span { display: flex; align-items: center; gap: .35rem; }')
L.append('    .regen-note { font-size: .82rem; color: var(--muted); margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--hair); }')
L.append('    .expand-hint { font-size: .78rem; color: var(--muted); opacity: 0.5; margin-left: .5rem; }')
L.append('    .entry.expanded { border-bottom: none; }')
L.append('    .entry-body { display: none; padding: 1rem 0 .5rem; border-top: 1px dashed var(--hair); margin-top: .5rem; }')
L.append('    .entry.expanded .entry-body { display: block; }')
L.append('    .entry-body .md-content { max-height: 60vh; overflow-y: auto; padding: 1rem; background: var(--fill); border: 1px solid var(--hair); font-size: .92rem; line-height: 1.6; }')
L.append('    .entry-body .md-content h1, .entry-body .md-content h2 { border-top: 1px solid var(--hair); padding-top: .5rem; margin-top: 1.5rem; }')
L.append('    .entry-body .md-content h1 { font-size: 1.4rem; }')
L.append('    .entry-body .md-content h2 { font-size: 1.15rem; color: var(--soft); }')
L.append('    .entry-body .md-content p { margin: .5rem 0; }')
L.append('    .entry-body .md-content code { background: var(--paper); padding: .05rem .25rem; border-radius: 3px; font-size: .88em; }')
L.append('    .entry-body .md-content pre { background: var(--paper); padding: .75rem; border-radius: 4px; overflow-x: auto; }')
L.append('    .entry-body .md-content pre code { background: none; padding: 0; }')
L.append('    .entry-body .md-content blockquote { border-left: 3px solid var(--accent); padding-left: 1rem; color: var(--muted); margin: .75rem 0; }')
L.append('    .entry-body .md-content table { border-collapse: collapse; width: 100%; margin: .75rem 0; font-size: .88rem; }')
L.append('    .entry-body .md-content th, .entry-body .md-content td { border: 1px solid var(--hair); padding: .4rem .6rem; text-align: left; }')
L.append('    .entry-body .md-content th { background: var(--fill); font-weight: bold; }')
L.append('    .entry-body .md-content strong { color: var(--ink); }')
L.append('    .entry-body .md-content em { color: var(--soft); }')
L.append('    .entry-body .md-content ul, .entry-body .md-content ol { padding-left: 1.5rem; }')
L.append('    .entry-body .md-content li { margin: .25rem 0; }')
L.append('    .loading { color: var(--muted); font-style: italic; font-size: .88rem; }')
L.append('    .load-err { color: var(--accent-ink); }')
L.append('  </style>')
L.append('</head>')

# Embed markdown content as JSON for file:// protocol compatibility
report_entries = [e for e in entries if e['type'] == 'report']
if report_entries:
    import json
    md_data = {e['path']: e['md'] for e in report_entries}
    md_json = json.dumps(md_data, ensure_ascii=False)
    L.append(f'  <script type="application/json" id="md-data">{md_json}</script>')

L.append('<body>')
L.append('  <h1>Research Index</h1>')
L.append('  <p class="standfirst">Scout reports and HTML research artifacts from the fleet, sorted by recency.</p>')
L.append(f'  <div class="meta-row">')
L.append(f'    <span><strong>{len(entries)}</strong> total artifacts</span>')
L.append(f'    <span><strong>{report_count}</strong> scout reports</span>')
L.append(f'    <span><strong>{html_count}</strong> HTML artifacts</span>')
L.append(f'    <span>Regenerated {now_str}</span>')
L.append('  </div>')
L.append('  <div class="legend">')
L.append('    <span><span class="entry-type report">report</span> Markdown scout report</span>')
L.append('    <span><span class="entry-type html">html</span> Lavish / HTML artifact</span>')
L.append('  </div>')

for date, group in by_date.items():
    L.append(f'  <h2>{date}</h2>')
    for idx, e in enumerate(group):
        type_cls = 'report' if e['type'] == 'report' else 'html'
        type_esc = escape(e['type'].upper())
        title_esc = escape(e['title'])
        summary_esc = escape(e['summary'])
        path_esc = escape(e['path'])
        entry_id = f'e{len(entries) - len(group) + idx}'
        L.append(f'  <div class="entry" id="{entry_id}" data-path="{path_esc}">')
        L.append(f'    <div class="entry-header">')
        L.append(f'      <span class="entry-time">{e["time"]}</span>')
        L.append(f'      <span class="entry-type {type_cls}">{type_esc}</span>')
        if e['type'] == 'report':
            L.append(f'      <span class="entry-title"><a href="{path_esc}" onclick="event.preventDefault(); togglePreview(\'{entry_id}\'); return false;">{title_esc}</a> <span class="expand-hint">click to preview</span></span>')
        else:
            L.append(f'      <span class="entry-title"><a href="{path_esc}">{title_esc}</a></span>')
        L.append(f'    </div>')
        L.append(f'    <p class="entry-summary">{summary_esc}</p>')
        L.append(f'    <div class="entry-body" id="body-{entry_id}"><div class="md-content"><span class="loading">Loading…</span></div></div>')
        L.append(f'  </div>')

# JS section
L.append('  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>')
L.append('  <script>')
L.append('    var __mdData = {};')
L.append('    (function() {')
L.append('      var el = document.getElementById("md-data");')
L.append('      if (el) { try { __mdData = JSON.parse(el.textContent); } catch(e) {} }')
L.append('    })();')
L.append('    function togglePreview(entryId) {')
L.append('      var card = document.getElementById(entryId);')
L.append('      var body = document.getElementById("body-" + entryId);')
L.append('      var content = body.querySelector(".md-content");')
L.append('      var path = card.getAttribute("data-path");')
L.append('      var wasExpanded = card.classList.contains("expanded");')
L.append('      document.querySelectorAll(".entry.expanded").forEach(function(el) {')
L.append('        el.classList.remove("expanded");')
L.append('      });')
L.append('      if (!wasExpanded) {')
L.append('        card.classList.add("expanded");')
L.append('        if (!body.dataset.loaded) {')
L.append('          var md = __mdData[path];')
L.append('          if (md !== undefined) {')
L.append('            if (typeof marked !== "undefined") content.innerHTML = marked.parse(md);')
L.append('            else content.textContent = md;')
L.append('            body.dataset.loaded = "1";')
L.append('          } else {')
L.append("            content.innerHTML = '<p class=\"load-err\">Markdown data not found for: ' + path + '</p>';")
L.append('          }')
L.append('        }')
L.append('      }')
L.append('    }')
L.append('  </script>')
L.append(f'  <p class="regen-note">Regenerate: <code>bin/fm-research-index.sh</code></p>')
L.append('</body>')
L.append('</html>')

with open(index_path, 'w') as f:
    f.write('\n'.join(L) + '\n')

print(f"Wrote {len(entries)} entries to {index_path}")
PY

#!/usr/bin/env bash
# fm-dashboard.sh - always-on, READ-ONLY local fleet dashboard.
#
# Serves a single self-contained dark-theme web page on localhost that
# auto-refreshes and shows each in-flight worker's task id, kind, harness/model,
# project, current state, latest activity, live pane tail, no-mistakes
# validation step, and PR link plus checks status.
#
# Data sources are structured readers, never hand-parsed state files:
#   - bin/fm-fleet-snapshot.sh --json    (task identity, current state, PR url)
#   - bin/fm-crew-state.sh <id>          (run-step / validation step, embedded in
#                                         the snapshot's current_state)
#   - bin/fm-backend.sh fm_backend_capture (pane tail, last N lines, read-only;
#                                           tmux uses `capture-pane -p`)
#   - gh pr view <url> --json            (PR checks, read-only, cached 60s)
#
# READ-ONLY CONTRACT: this script never writes to state/, data/, config/, or any
# worktree, and shells out only to read-only commands. The only filesystem
# activity is the loopback socket the Python stdlib http.server opens in serve
# mode; every fleet read is a read-only command (snapshot, pane capture, gh).
#
# Usage:
#   fm-dashboard.sh                       serve the dashboard (default)
#   fm-dashboard.sh --port 8790           serve on a specific loopback port
#   fm-dashboard.sh --refresh 15          page auto-refresh interval (seconds)
#   fm-dashboard.sh --gh-cache 120        PR checks cache TTL (seconds)
#   fm-dashboard.sh --pane-lines 25       pane tail line count
#   fm-dashboard.sh --snapshot            print the dashboard JSON and exit
#   fm-dashboard.sh --pr-check <url>      print one PR's checks JSON and exit
#   fm-dashboard.sh --html                print the HTML page and exit
#
# Flags:
#   --port N       loopback port (default 8790)
#   --host HOST    loopback bind address: 127.0.0.1, ::1, or localhost
#                  (default 127.0.0.1; non-loopback is refused)
#   --refresh N    page auto-refresh interval in seconds (default 10)
#   --gh-cache N   PR checks cache TTL in seconds (default 60)
#   --pane-lines N pane tail line count (default 15)
#
# Output contract: `--snapshot` prints one JSON object with schema
# `fm-dashboard.v1`; `--pr-check` prints one JSON object per URL. Both always
# exit 0 and carry failures in an `error` field so a data-source error is shown
# loudly instead of rendering as an empty row.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-dashboard.sh"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  cat <<'EOF'
usage: fm-dashboard.sh [--port N] [--host HOST] [--refresh N] [--gh-cache N]
                      [--pane-lines N]
       fm-dashboard.sh --snapshot
       fm-dashboard.sh --pr-check <url>
       fm-dashboard.sh --html

Serve an always-on, read-only local fleet dashboard on localhost.
With no mode flag the dashboard serves. --snapshot prints the dashboard JSON,
--pr-check prints one PR's checks JSON, and --html prints the page HTML.
EOF
}

MODE=serve
PORT=8790
HOST=127.0.0.1
REFRESH=10
GH_CACHE_TTL=60
PANE_LINES=15
PR_URL=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --snapshot) MODE=snapshot ;;
    --html) MODE=html ;;
    --pr-check)
      MODE=pr-check
      [ "$#" -ge 2 ] || { echo "fm-dashboard: --pr-check requires a URL" >&2; exit 2; }
      PR_URL=$2
      shift
      ;;
    --port) [ "$#" -ge 2 ] || { echo "fm-dashboard: --port requires a value" >&2; exit 2; }; PORT=$2; shift ;;
    --port=*) PORT=${1#*=} ;;
    --host) [ "$#" -ge 2 ] || { echo "fm-dashboard: --host requires a value" >&2; exit 2; }; HOST=$2; shift ;;
    --host=*) HOST=${1#*=} ;;
    --refresh) [ "$#" -ge 2 ] || { echo "fm-dashboard: --refresh requires a value" >&2; exit 2; }; REFRESH=$2; shift ;;
    --refresh=*) REFRESH=${1#*=} ;;
    --gh-cache) [ "$#" -ge 2 ] || { echo "fm-dashboard: --gh-cache requires a value" >&2; exit 2; }; GH_CACHE_TTL=$2; shift ;;
    --gh-cache=*) GH_CACHE_TTL=${1#*=} ;;
    --pane-lines) [ "$#" -ge 2 ] || { echo "fm-dashboard: --pane-lines requires a value" >&2; exit 2; }; PANE_LINES=$2; shift ;;
    --pane-lines=*) PANE_LINES=${1#*=} ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

fail_usage() {  # <message>
  echo "fm-dashboard: $1" >&2
  exit 2
}

case "$PORT" in ''|*[!0-9]*) fail_usage "--port must be a positive integer" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail_usage "--port must be 1-65535"
case "$HOST" in
  127.0.0.1|::1|localhost) ;;
  *) fail_usage "--host must be a loopback address (127.0.0.1, ::1, or localhost)" ;;
esac
case "$REFRESH" in ''|*[!0-9]*|0) fail_usage "--refresh must be a positive integer" ;; esac
case "$GH_CACHE_TTL" in ''|*[!0-9]*|0) fail_usage "--gh-cache must be a positive integer" ;; esac
case "$PANE_LINES" in ''|*[!0-9]*|0) fail_usage "--pane-lines must be a positive integer" ;; esac

# pane_tail_json <backend> <target> <lines> <id> - read the last <lines> lines
# of a recorded endpoint through the backend-aware read-only capture primitive,
# and emit a JSON object `{lines:[...], error:null|string}`. The id supplies the
# expected `fm-<id>` label bin/fm-peek.sh passes, which the zellij/cmux adapters
# use to verify they capture the intended task's pane and not a stranger's.
#
# The capture runs in-process rather than under fm_run_timed: the timed runner
# can only exec an external command, so bounding the shell function would force
# a child bash to re-source the backend adapter chain on every capture (~2s each
# for the tmux adapter's session-lock and cursor libs). Calling it directly
# sources each adapter once per snapshot process and matches bin/fm-crew-state.sh's
# own unbounded cheap pane reads (tmux capture-pane -p is a fast read-only call).
pane_tail_json() {  # <backend> <target> <lines> <id>
  local backend=$1 target=$2 lines=$3 id=$4 capture rc text lines_json
  if [ -z "$target" ]; then
    jq -n '{lines:[], error:"no recorded endpoint"}'
    return 0
  fi
  capture=$(fm_backend_capture "$backend" "$target" "$lines" "fm-$id" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    jq -n --arg e "pane capture failed (exit $rc)" '{lines:[], error:$e}'
    return 0
  fi
  text=$(printf '%s\n' "$capture" | sed '/^[[:space:]]*$/d' | tail -n "$lines")
  lines_json=$(printf '%s\n' "$text" | jq -Rn '[inputs]')
  jq -n --argjson lines "$lines_json" '{lines:$lines, error:null}'
}

# pr_check_json <url> - read-only PR checks for one github.com PR via gh.
# Non-github URLs are answered with an explicit error rather than a fake pass.
pr_check_json() {  # <url>
  local url=$1 gh_json
  case "$url" in
    https://github.com/*) ;;
    *)
      jq -n --arg url "$url" --arg e "PR checks support github.com only" \
        '{url:$url, pr_state:null, verdict:"unknown", items:[], error:$e}'
      return 0
      ;;
  esac
  if ! command -v gh >/dev/null 2>&1; then
    jq -n --arg url "$url" --arg e "gh not found" \
      '{url:$url, pr_state:null, verdict:"unknown", items:[], error:$e}'
    return 0
  fi
  if ! gh_json=$(gh pr view "$url" --json state,statusCheckRollup 2>/dev/null); then
    jq -n --arg url "$url" --arg e "gh pr view failed" \
      '{url:$url, pr_state:null, verdict:"unknown", items:[], error:$e}'
    return 0
  fi
  printf '%s' "$gh_json" | jq -c --arg url "$url" '
    def bad: . == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT"
      or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE";
    def in_progress: . == "EXPECTED" or . == "PENDING" or . == "STARTED"
      or . == "IN_PROGRESS" or . == "QUEUED";
    def ok: . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED";
    def verdict($rs):
      if ($rs | length) == 0 then "no_checks"
      elif any($rs[]; (.conclusion // "") | bad) then "failure"
      elif any($rs[]; (.status // "") | in_progress) then "pending"
      elif all($rs[]; ((.conclusion // "") | ok)) then "success"
      else "unknown" end;
    {url:$url,
     pr_state:(.state // null),
     verdict:verdict(.statusCheckRollup // []),
     items:[ (.statusCheckRollup // [])[]
             | {name:(.name // ""), status:(.status // ""), conclusion:(.conclusion // "")} ][0:20],
     error:null}'
}

# dashboard_snapshot - emit the fm-dashboard.v1 JSON. Always exits 0 and carries
# failures in `error`/`errors` fields so the UI renders them loudly.
dashboard_snapshot() {
  local snapshot now fm_home task id backend target model pane
  local enriched tasks
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' '{"schema":"fm-dashboard.v1","generated":"","fm_home":null,"refresh_seconds":0,"error":"jq not found","tasks":[],"errors":["jq not found"]}'
    return 0
  fi
  if ! snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json --no-remote-probe 2>&1); then
    snapshot=""
  fi
  if ! printf '%s' "$snapshot" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1; then
    jq -n --arg now "$now" --arg e "fleet snapshot unavailable: $(printf '%s' "$snapshot" | head -c 300)" \
      '{schema:"fm-dashboard.v1", generated:$now, fm_home:null, refresh_seconds:0, error:$e, tasks:[], errors:[$e]}'
    return 0
  fi

  fm_home=$(printf '%s' "$snapshot" | jq -r '.fm_home // ""')
  enriched=""
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    id=$(printf '%s' "$task" | jq -r '.id // ""')
    backend=$(printf '%s' "$task" | jq -r '.backend // "tmux"')
    target=$(printf '%s' "$task" | jq -r '.endpoint.target // ""')
    model=$(printf '%s' "$task" | jq -r '.model // ""')
    if [ "$(printf '%s' "$task" | jq -r '.remote.host // ""')" != "" ]; then
      pane=$(jq -n '{lines:[], error:"remote worker - live view not available from the dashboard; open its remote session"}')
    else
      pane=$(pane_tail_json "$backend" "$target" "$PANE_LINES" "$id")
    fi
    enriched="$enriched$(printf '%s' "$task" | jq -c \
      --arg model "$model" \
      --argjson pane "$pane" \
      '{
        id: .id,
        kind: .kind,
        harness: (.harness // ""),
        model: $model,
        project: (.project // ""),
        backend: (.backend // "tmux"),
        mode: (.mode // ""),
        state: .current_state.state,
        state_source: .current_state.source,
        state_detail: (.current_state.detail // ""),
        latest_activity: (.hints.last_event_text // ""),
        pending_decision: .hints.pending_decision,
        blocked: .hints.blocked_event,
        remote_host: (.remote.host // ""),
        endpoint_present: .endpoint.exists,
        endpoint_target: (.endpoint.target // null),
        pane_tail: $pane,
        validation: {active: (.current_state.source == "run-step"), detail: (.current_state.detail // "")},
        pr: {url: (.pr.url // null)}
      }')"$'\n'
  done < <(printf '%s' "$snapshot" | jq -c '.tasks[]')

  tasks=$(printf '%s' "$enriched" | jq -s '.')
  jq -n --arg now "$now" --arg home "$fm_home" --arg refresh "$REFRESH" --argjson tasks "$tasks" \
    '{schema:"fm-dashboard.v1",
      generated:$now,
      fm_home:$home,
      refresh_seconds:($refresh | tonumber),
      error:null,
      tasks:$tasks,
      errors:[]}'
}

# dashboard_html - print the self-contained dark-theme HTML page with the
# refresh interval baked into the JS auto-refresh.
#
# The page is streamed straight through sed rather than captured in a command
# substitution: bash mis-parses a quoted heredoc nested inside $(...) when the
# body carries an unbalanced quote (the JS HTML-escape regex below), so the
# substitution happens on sed's output instead of on a shell variable.
dashboard_html() {
  sed "s/__REFRESH__/$REFRESH/g" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>firstmate fleet</title>
<style>
:root { --bg:#0d1117; --panel:#161b22; --border:#30363d; --fg:#c9d1d9;
  --muted:#8b949e; --accent:#58a6ff; --green:#3fb950; --yellow:#d29922;
  --red:#f85149; --purple:#bc8cff; }
* { box-sizing:border-box; }
html, body { margin:0; background:var(--bg); color:var(--fg);
  font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
header { padding:12px 16px; border-bottom:1px solid var(--border);
  display:flex; align-items:baseline; gap:14px; flex-wrap:wrap; }
h1 { font-size:15px; margin:0; color:var(--accent); font-weight:600; }
#meta { color:var(--muted); font-size:12px; }
.banner { background:var(--red); color:#fff; padding:8px 16px; font-weight:700; }
.hidden { display:none; }
main { padding:12px 16px; }
table { width:100%; border-collapse:collapse; }
th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--border);
  vertical-align:top; }
th { color:var(--muted); font-weight:400; white-space:nowrap; }
tr:hover td { background:var(--panel); }
.mono { white-space:nowrap; }
.state { font-weight:700; }
.state.working { color:var(--green); }
.state.done { color:var(--green); }
.state.parked { color:var(--yellow); }
.state.paused { color:var(--yellow); }
.state.blocked { color:var(--red); }
.state.failed { color:var(--red); }
.state.unknown { color:var(--muted); }
.badge { border:1px solid var(--border); border-radius:3px; padding:0 4px;
  margin-left:4px; color:var(--muted); font-size:11px; }
.badge.warn { color:var(--yellow); border-color:var(--yellow); }
.badge.err { color:var(--red); border-color:var(--red); }
.badge.val { color:var(--purple); border-color:var(--purple); }
.checks.success { color:var(--green); }
.checks.failure { color:var(--red); }
.checks.pending { color:var(--yellow); }
.checks.no_checks, .checks.unknown { color:var(--muted); }
a { color:var(--accent); text-decoration:none; }
a:hover { text-decoration:underline; }
details.pane { margin:0; }
summary { cursor:pointer; color:var(--accent); user-select:none; }
pre.tail { background:var(--panel); border:1px solid var(--border); padding:6px 8px;
  margin:4px 0 0; white-space:pre-wrap; word-break:break-word; max-height:220px;
  overflow:auto; color:var(--fg); font-size:12px; }
.errline { color:var(--red); }
#empty { color:var(--muted); padding:28px; text-align:center;
  border:1px dashed var(--border); }
footer { color:var(--muted); padding:8px 16px; font-size:11px; }
</style>
</head>
<body>
<header>
  <h1>firstmate fleet</h1>
  <span id="meta"></span>
</header>
<div id="banner" class="banner hidden"></div>
<main>
  <div id="empty" class="hidden">No live workers. The fleet is empty.</div>
  <table id="fleet">
    <thead><tr>
      <th>Task</th><th>Kind</th><th>Harness / Model</th><th>Project</th>
      <th>State</th><th>Validation / Activity</th><th>PR / Checks</th><th>Tail</th>
    </tr></thead>
    <tbody id="rows"></tbody>
  </table>
</main>
<footer id="footer"></footer>
<script>
var REFRESH = __REFRESH__;
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
}
function stateClass(s) {
  var cls = { working: 'working', done: 'done', parked: 'parked', paused: 'paused',
    blocked: 'blocked', failed: 'failed', unknown: 'unknown' }[s] || 'unknown';
  return cls;
}
function checksHtml(pr) {
  if (!pr || !pr.url) return '<span class="errline">no PR</span>';
  var out = '<a href="' + esc(pr.url) + '" target="_blank" rel="noopener">PR</a>';
  var c = pr.checks;
  if (!c) return out;
  if (c.error) return out + ' <span class="badge err">' + esc(c.error) + '</span>';
  out += ' <span class="checks ' + esc(c.verdict) + '">' + esc(c.verdict) + '</span>';
  if (c.pr_state) out += ' <span class="badge">' + esc(c.pr_state) + '</span>';
  var items = c.items || [];
  if (items.length) {
    out += '<details class="pane"><summary>checks</summary><pre class="tail">';
    out += items.map(function (i) {
      return esc(i.name || '?') + ' ' + esc(i.status || '') +
        (i.conclusion ? ' / ' + esc(i.conclusion) : '');
    }).join('\n');
    out += '</pre></details>';
  }
  return out;
}
function tailHtml(t) {
  var p = t.pane_tail || {};
  var out = t.remote_host ? '<span class="badge">remote: ' + esc(t.remote_host) + '</span> ' : '';
  if (p.error) return out + '<span class="errline">' + esc(p.error) + '</span>';
  var lines = p.lines || [];
  if (!lines.length) return out + '<span class="badge">no output</span>';
  return out + '<details class="pane"><summary>tail (' + lines.length + ')</summary>' +
    '<pre class="tail">' + esc(lines.join('\n')) + '</pre></details>';
}
function activityHtml(t) {
  if (t.validation && t.validation.active) {
    return '<span class="badge val">validation</span> ' + esc(t.validation.detail || t.state_detail || '');
  }
  // Prefer the last wake-event note (the meaningful activity) over a pane
  // busy-state detail, which the State column already conveys.
  var d = t.latest_activity || t.state_detail || '';
  return d ? esc(d) : '<span class="badge">-</span>';
}
function flagsHtml(t) {
  var out = '';
  if (t.pending_decision) out += '<span class="badge warn">decision</span>';
  if (t.blocked) out += '<span class="badge err">blocked</span>';
  return out;
}
function rowHtml(t) {
  var harness = t.harness || '';
  if (t.model) harness += ' / ' + t.model;
  return '<tr>' +
    '<td class="mono">' + esc(t.id) + '</td>' +
    '<td class="mono">' + esc(t.kind) + '</td>' +
    '<td class="mono">' + esc(harness) + '</td>' +
    '<td>' + esc(t.project) + '</td>' +
    '<td><span class="state ' + stateClass(t.state) + '">' + esc(t.state) + '</span>' +
      ' <span class="badge">' + esc(t.state_source) + '</span>' + flagsHtml(t) + '</td>' +
    '<td>' + activityHtml(t) + '</td>' +
    '<td>' + checksHtml(t.pr) + '</td>' +
    '<td>' + tailHtml(t) + '</td>' +
    '</tr>';
}
function render(data) {
  var meta = document.getElementById('meta');
  var banner = document.getElementById('banner');
  var empty = document.getElementById('empty');
  var tbody = document.getElementById('rows');
  var footer = document.getElementById('footer');
  banner.classList.add('hidden');
  banner.textContent = '';
  if (data.error) { banner.textContent = 'error: ' + data.error; banner.classList.remove('hidden'); }
  var tasks = data.tasks || [];
  meta.textContent = 'home: ' + (data.fm_home || '?') + ' · generated: ' +
    (data.generated || '?') + ' · refresh: ' + (data.refresh_seconds || REFRESH) + 's';
  if (!tasks.length) {
    empty.classList.remove('hidden');
    tbody.innerHTML = '';
  } else {
    empty.classList.add('hidden');
    tbody.innerHTML = tasks.map(rowHtml).join('');
  }
  footer.textContent = tasks.length + ' worker(s) · auto-refresh ' +
    (data.refresh_seconds || REFRESH) + 's · rendered ' + new Date().toISOString();
}
function tick() {
  fetch('/snapshot').then(function (r) {
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return r.json();
  }).then(render).catch(function (e) {
    var banner = document.getElementById('banner');
    banner.textContent = 'snapshot failed: ' + e.message;
    banner.classList.remove('hidden');
  });
}
setInterval(tick, REFRESH * 1000);
tick();
</script>
</body>
</html>
HTML
}

# dashboard_serve - run the stdlib http.server loop. The bash script stays the
# single data owner: the server shells back into `--snapshot` for fleet data and
# `--pr-check` for PR checks, holding the 60s PR-check cache in memory.
dashboard_serve() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "fm-dashboard: python3 is required to serve the dashboard" >&2
    exit 1
  fi
  python3 - "$SELF" "$PORT" "$HOST" "$REFRESH" "$GH_CACHE_TTL" <<'PY'
import http.server
import json
import socket
import subprocess
import sys
import time

SCRIPT = sys.argv[1]
PORT = int(sys.argv[2])
HOST = sys.argv[3]
REFRESH = int(sys.argv[4])
GH_TTL = int(sys.argv[5])

try:
    ADDRESS_FAMILY = socket.getaddrinfo(
        HOST, PORT, proto=socket.IPPROTO_TCP, flags=socket.AI_NUMERICHOST
    )[0][0]
except socket.gaierror:
    try:
        ADDRESS_FAMILY = socket.getaddrinfo(HOST, PORT, proto=socket.IPPROTO_TCP)[0][0]
    except socket.gaierror as e:
        print("fm-dashboard: cannot resolve --host %r: %s" % (HOST, e), file=sys.stderr)
        sys.exit(1)


def snapshot_json():
    p = subprocess.run([SCRIPT, "--snapshot"], capture_output=True, text=True, timeout=180)
    try:
        data = json.loads(p.stdout or "{}")
    except json.JSONDecodeError:
        return {"schema": "fm-dashboard.v1", "error": "snapshot returned invalid JSON",
                "tasks": [], "errors": ["snapshot returned invalid JSON"]}
    if p.returncode != 0:
        data["error"] = data.get("error") or ("snapshot failed: " + (p.stderr or "")[:200])
    for task in data.get("tasks", []):
        pr = task.get("pr") or {}
        url = pr.get("url")
        if url:
            pr["checks"] = pr_checks(url)
        else:
            pr["checks"] = None
        task["pr"] = pr
    return data


def pr_checks(url):
    now = time.monotonic()
    cached = SERVER.gh_cache.get(url)
    if cached and (now - cached[0]) < GH_TTL:
        return cached[1]
    p = subprocess.run([SCRIPT, "--pr-check", url], capture_output=True, text=True, timeout=30)
    try:
        checks = json.loads(p.stdout or "{}")
    except json.JSONDecodeError:
        checks = {"url": url, "error": "pr-check returned invalid JSON"}
    SERVER.gh_cache[url] = (now, checks)
    return checks


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    address_family = ADDRESS_FAMILY

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.gh_cache = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _text(self, code, body, ctype):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            p = subprocess.run([SCRIPT, "--html", "--refresh", str(REFRESH)],
                               capture_output=True, text=True, timeout=15)
            self._text(200, p.stdout or "", "text/html; charset=utf-8")
        elif self.path == "/snapshot":
            self._text(200, json.dumps(snapshot_json()), "application/json; charset=utf-8")
        elif self.path == "/health":
            self._text(200, "ok", "text/plain; charset=utf-8")
        else:
            self._text(404, "not found", "text/plain; charset=utf-8")


SERVER = Server((HOST, PORT), Handler)
print("fm-dashboard: serving on http://%s:%s" % (HOST, SERVER.server_address[1]),
      file=sys.stderr, flush=True)
try:
    SERVER.serve_forever()
except KeyboardInterrupt:
    pass
PY
}

case "$MODE" in
  snapshot) dashboard_snapshot ;;
  pr-check) pr_check_json "$PR_URL" ;;
  html) dashboard_html ;;
  serve) dashboard_serve ;;
  *) usage >&2; exit 2 ;;
esac

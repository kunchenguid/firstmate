#!/usr/bin/env bash
# fm-dashboard.sh - generate a read-only fleet dashboard for a firstmate home.
#
# Usage:
#   bin/fm-dashboard.sh                  # write state/dashboard.html, print its path
#   bin/fm-dashboard.sh -o <out.html>    # write elsewhere (e.g. a temp dir)
#   bin/fm-dashboard.sh --open           # also open it in the default browser
#   bin/fm-dashboard.sh --serve [port]   # HTTP-serve it, regenerating per request
#                                        # (default port 8737, binds 127.0.0.1)
#
# Renders one self-contained HTML page (inline CSS, no CDN, renders offline;
# dark theme). At the top, a "Decisions needed" section lists everything
# waiting on the captain, oldest first (by status-file mtime), with
# warning-accent styling: tasks whose current state is parked (needs-decision)
# or blocked, showing the latest needs-decision:/blocked: status line as the
# ask; and tasks with pr= in meta whose checks are green, where the pending
# decision is the merge (full PR URL linked). When nothing is waiting it shows
# a quiet "Nothing needs you." Below that, per direct report (every
# state/<id>.meta): task id,
# project, kind, current state from bin/fm-crew-state.sh, last-reported time
# (status-file mtime), last-activity time (turn-ended mtime), the latest
# status line, a PR link when meta records pr=, and a stage-based progress
# bar. A fleet header shows running / needs-attention / total counts, watcher
# liveness (state/.last-watcher-beat age; red when missing or older than
# FM_GUARD_GRACE, default 300s), the queued-wake count, and the generation
# time. A backlog section lists Queued and recent Done items parsed
# best-effort from data/backlog.md. The page embeds a 30s meta refresh.
#
# Progress mapping (COARSE AND STAGE-BASED, never measured precision), derived
# from fm-crew-state.sh's "state · source · detail" line plus meta kind=/pr=:
#   spawned / unknown (no state source yet)      10%
#   working, kind=ship, pre-validation           30%
#   working, kind=scout                          40%
#   validating/fixing/ci (run-step detail)       60%
#   PR open (meta pr= recorded, not yet green)   80%  (blue, PR-ready)
#   done with "checks green"/"checks-passed"     90%  (blue, awaiting merge)
#   done / merged (incl. scout report done)     100%
#   parked / blocked (needs-decision, blocked)   holds the stage percent it
#     would otherwise have (pr= -> 80, run-step gate -> 60, else the kind's
#     working percent) and is styled as a warning, never advancing.
#   paused (declared external wait)              holds the stage percent the
#     same way parked/blocked do, but styled distinctly and NOT counted as
#     needs-attention: it is a deliberate wait, not a captain decision.
#   failed                                       no percent; a failed badge.
#   kind=secondmate                              no percent; persistent
#     supervisors have no completion stage.
#
# --serve implementation choice: python3 stdlib http.server with a tiny
# handler that shells back into this script per request. A pure-bash HTTP
# server needs nc/socat (new dependencies with portability hazards), and a
# bash regenerate-loop over a static file cannot refresh on demand; python3
# stdlib is within the allowed dependency set and gives regenerate-on-request
# in ~25 lines. Without python3, --serve fails with a clear error while plain
# generation still works.
#
# Read-only guarantee: the only writes are the output file itself plus its
# transient sibling "$OUT.tmp.$$", used for an atomic rename so --serve never
# reads a half-written page. Nothing under state/, data/, or projects/ is
# otherwise touched; missing status files, a missing watcher beat, a missing
# backlog, or an empty fleet all render gracefully (exit 0).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CREW_STATE_BIN=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}

OUT="$STATE/dashboard.html"
OPEN=0
SERVE=0
PORT=8737
GRACE=${FM_GUARD_GRACE:-300}
case "$GRACE" in ''|*[!0-9]*) GRACE=300 ;; esac

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      [ $# -ge 2 ] || { echo "error: -o needs a path" >&2; exit 2; }
      OUT=$2; shift ;;
    --open) OPEN=1 ;;
    --serve)
      SERVE=1
      if [ $# -ge 2 ]; then
        case "$2" in
          [0-9]*) case "$2" in *[!0-9]*) ;; *) PORT=$2; shift ;; esac ;;
        esac
      fi ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

NOW=$(date +%s)

# --- portable stat/date helpers ---------------------------------------------

STAT_STYLE=gnu
if stat -f %m . >/dev/null 2>&1; then STAT_STYLE=bsd; fi
DATE_STYLE=bsd
if date -d @0 +%s >/dev/null 2>&1; then DATE_STYLE=gnu; fi

mtime_of() {  # <path> -> epoch, or nothing (rc 1) when missing
  [ -e "$1" ] || return 1
  if [ "$STAT_STYLE" = bsd ]; then stat -f %m "$1" 2>/dev/null
  else stat -c %Y "$1" 2>/dev/null; fi
}

abs_time() {  # <epoch> -> "YYYY-MM-DD HH:MM:SS"
  if [ "$DATE_STYLE" = gnu ]; then date -d "@$1" '+%Y-%m-%d %H:%M:%S'
  else date -r "$1" '+%Y-%m-%d %H:%M:%S'; fi
}

rel_age() {  # <epoch> -> "3m ago" etc.
  local s=$(( NOW - $1 ))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf '%ss ago' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm ago' "$(( s / 60 ))"
  elif [ "$s" -lt 86400 ]; then printf '%sh %sm ago' "$(( s / 3600 ))" "$(( s % 3600 / 60 ))"
  else printf '%sd ago' "$(( s / 86400 ))"
  fi
}

html_escape() {  # <string>
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

truncate_str() {  # <string> <maxlen>
  if [ "${#1}" -gt "$2" ]; then printf '%s…' "${1:0:$2}"; else printf '%s' "$1"; fi
}

meta_value() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Classify a done task's stage. The crew-state detail is authoritative (a
# merged PR reads "run passed: PR merged/closed" while the status log's last
# line still says "checks green"), so match it first and fall back to the
# status line only when the detail says nothing.
done_stage() {  # <cs-detail> <last-status-line> -> merged|checks-green|done
  case "$1" in
    *merged*) printf 'merged'; return ;;
    *'checks green'*|*checks-passed*) printf 'checks-green'; return ;;
  esac
  case "$2" in
    *merged*) printf 'merged' ;;
    *'checks green'*|*checks-passed*) printf 'checks-green' ;;
    *) printf 'done' ;;
  esac
}

# Emit a "<abs><br><span class=rel>(rel)</span>" cell body for an epoch, or a dash.
time_cell() {  # <epoch-or-empty>
  if [ -n "$1" ]; then
    printf '%s<br><span class="rel">%s</span>' "$(abs_time "$1")" "$(rel_age "$1")"
  else
    printf '<span class="rel">—</span>'
  fi
}

# --- per-task rows + fleet counts --------------------------------------------

TOTAL=0
RUNNING=0
ATTENTION=0
ROWS=""
# DECS accumulates "sort-epoch<TAB><li>...</li>" records for the decisions
# section; sorted numerically (oldest first) before rendering. Entries with no
# readable mtime sort last via the 9999999999 sentinel.
DECS=""

collect_tasks() {
  local meta id project pname kind pr statusf turnf last_line smt tmt
  local csline cs_state cs_source cs_detail rest
  local pct cls label pr_cell status_cell bar stage
  local dec_ask dec_mt dec_when dec_pr
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    TOTAL=$(( TOTAL + 1 ))
    id=$(basename "$meta" .meta)
    project=$(meta_value "$meta" project)
    pname=${project##*/}
    [ -n "$pname" ] || pname='?'
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    pr=$(meta_value "$meta" pr)

    statusf="$STATE/$id.status"
    turnf="$STATE/$id.turn-ended"
    last_line=$(grep -v '^[[:space:]]*$' "$statusf" 2>/dev/null | tail -1 || true)
    smt=$(mtime_of "$statusf" || true)
    tmt=$(mtime_of "$turnf" || true)

    csline=$("$CREW_STATE_BIN" "$id" 2>/dev/null || true)
    [ -n "$csline" ] || csline='state: unknown · source: none · state read failed'
    cs_state=${csline#state: }
    cs_state=${cs_state%% *}
    cs_source=none
    cs_detail=""
    case "$csline" in
      *'· source: '*)
        rest=${csline#*'· source: '}
        cs_source=${rest%% *}
        case "$rest" in *' · '*) cs_detail=${rest#*' · '} ;; esac
        ;;
    esac

    stage=""
    [ "$cs_state" = 'done' ] && stage=$(done_stage "$cs_detail" "$last_line")

    # Stage-based progress (see header mapping). Never invents precision.
    pct=""; cls=muted; label=""
    if [ "$kind" = secondmate ]; then
      case "$cs_state" in
        failed) cls=fail; label=failed ;;
        paused) cls=paused; label=paused ;;
        blocked|parked) cls=warn; label="$cs_state" ;;
        *) cls=ok; label='persistent' ;;
      esac
    else
      case "$cs_state" in
        failed)
          cls=fail; label=failed ;;
        done)
          case "$stage" in
            checks-green) pct=90; cls='pr'; label='checks green' ;;
            merged)       pct=100; cls='done'; label='merged' ;;
            *)            pct=100; cls='done'; label='done' ;;
          esac ;;
        parked|blocked)
          if [ -n "$pr" ]; then pct=80
          elif [ "$cs_source" = run-step ]; then pct=60
          elif [ "$kind" = scout ]; then pct=40
          else pct=30
          fi
          cls=warn
          if [ "$cs_state" = parked ]; then label='held: needs decision'
          else label='held: blocked'; fi ;;
        paused)
          if [ -n "$pr" ]; then pct=80
          elif [ "$cs_source" = run-step ]; then pct=60
          elif [ "$kind" = scout ]; then pct=40
          else pct=30
          fi
          cls=paused; label='paused: external wait' ;;
        working)
          case "$cs_detail" in
            *validating*|*fixing*|*'ci running'*) pct=60; label=validating ;;
            *) if [ "$kind" = scout ]; then pct=40; label=scouting
               else pct=30; label=working; fi ;;
          esac
          cls=ok
          if [ -n "$pr" ] && [ "$pct" -lt 80 ]; then pct=80; cls='pr'; label='PR open'; fi ;;
        *)
          pct=10; cls=muted
          if [ -f "$statusf" ]; then label=unknown; else label=spawned; fi ;;
      esac
    fi

    if [ "$cs_state" = working ]; then RUNNING=$(( RUNNING + 1 )); fi
    case "$cs_state" in
      parked|blocked|failed) ATTENTION=$(( ATTENTION + 1 )) ;;
      unknown) [ "$kind" = secondmate ] || ATTENTION=$(( ATTENTION + 1 )) ;;
      done) [ -n "$pr" ] && [ "$stage" = checks-green ] && ATTENTION=$(( ATTENTION + 1 )) ;;
    esac

    # Decisions needed (best-effort, see header): a parked/blocked task's ask
    # is its latest needs-decision:/blocked: status line (falling back to the
    # state detail); a checks-green task with a recorded PR waits on the merge.
    dec_ask=""
    case "$cs_state" in
      parked|blocked)
        dec_ask=$(grep -E '^[[:space:]]*(needs-decision|blocked):' "$statusf" 2>/dev/null | tail -1 || true)
        [ -n "$dec_ask" ] || dec_ask="$cs_state: ${cs_detail:-waiting on a decision}"
        ;;
      done)
        if [ -n "$pr" ] && [ "$stage" = checks-green ]; then
          dec_ask='merge? checks are green'
        fi
        ;;
    esac
    if [ -n "$dec_ask" ]; then
      dec_ask=$(printf '%s' "$dec_ask" | tr '\t' ' ')
      dec_mt=${smt:-${tmt:-}}
      if [ -n "$dec_mt" ]; then
        dec_when="waiting $(rel_age "$dec_mt")"; dec_when=${dec_when% ago}
      else
        dec_when='waiting time unknown'
      fi
      dec_pr=""
      [ -n "$pr" ] && dec_pr=" · <a href=\"$(html_escape "$pr")\">$(html_escape "$pr")</a>"
      DECS="$DECS${dec_mt:-9999999999}	<li><span class=\"decask\">$(html_escape "$(truncate_str "$dec_ask" 160)")</span><span class=\"decmeta\"> — $(html_escape "$pname") · $dec_when$dec_pr</span></li>
"
    fi

    if [ -n "$pct" ]; then
      bar="<div class=\"bar\"><div class=\"fill f-$cls\" style=\"width:${pct}%\"></div></div><div class=\"plabel\">${pct}% · $(html_escape "$label") <span class=\"stagenote\">(stage)</span></div>"
    else
      bar="<div class=\"plabel\">$(html_escape "$label")</div>"
    fi

    if [ -n "$pr" ]; then
      pr_cell="<a href=\"$(html_escape "$pr")\">PR</a>"
    else
      pr_cell='<span class="rel">—</span>'
    fi

    if [ -n "$last_line" ]; then
      status_cell=$(html_escape "$(truncate_str "$last_line" 140)")
    else
      status_cell='<span class="rel">no status yet</span>'
    fi

    ROWS="$ROWS<tr>
<td class=\"id\">$(html_escape "$id")</td>
<td>$(html_escape "$pname")</td>
<td>$(html_escape "$kind")</td>
<td><span class=\"badge b-$cls\">$(html_escape "$cs_state")</span><div class=\"detail\">$(html_escape "$(truncate_str "$cs_detail" 90)")</div></td>
<td class=\"prog\">$bar</td>
<td class=\"time\">$(time_cell "$smt")</td>
<td class=\"time\">$(time_cell "$tmt")</td>
<td class=\"statusline\">$status_cell</td>
<td>$pr_cell</td>
</tr>
"
  done
}

# --- backlog (best-effort parse; tolerate free-form lines / missing file) ----

backlog_items() {  # <section-header-regex> [limit]
  local f="$DATA/backlog.md" limit=${2:-0} n=0 line
  [ -f "$f" ] || return 0
  awk "/^## $1[[:space:]]*\$/{s=1;next} /^## /{s=0} s && /^[-*] /" "$f" 2>/dev/null \
    | while IFS= read -r line; do
        if [ "$limit" -gt 0 ]; then
          n=$(( n + 1 ))
          [ "$n" -le "$limit" ] || break
        fi
        line=$(printf '%s' "$line" | sed -e 's/^[-*] \[.\] //' -e 's/^[-*] //')
        printf '<li>%s</li>\n' "$(html_escape "$line")"
      done
}

# --- page ---------------------------------------------------------------------

generate_page() {
  local beat_mt beat_cell wakes queued_html done_html dec_items dec_count
  collect_tasks

  beat_mt=$(mtime_of "$STATE/.last-watcher-beat" || true)
  if [ -z "$beat_mt" ]; then
    beat_cell='<div class="num bad">missing</div>'
  elif [ $(( NOW - beat_mt )) -gt "$GRACE" ]; then
    beat_cell="<div class=\"num bad\">$(rel_age "$beat_mt")</div>"
  else
    beat_cell="<div class=\"num good\">$(rel_age "$beat_mt")</div>"
  fi

  wakes=0
  if [ -f "$STATE/.wake-queue" ]; then
    wakes=$(grep -c . "$STATE/.wake-queue" 2>/dev/null || true)
    case "$wakes" in ''|*[!0-9]*) wakes=0 ;; esac
  fi

  queued_html=$(backlog_items 'Queued')
  done_html=$(backlog_items 'Done' 10)
  [ -n "$queued_html" ] || queued_html='<li class="rel">nothing queued</li>'
  [ -n "$done_html" ] || done_html='<li class="rel">nothing recorded</li>'

  cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="30">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>firstmate fleet</title>
<style>
:root{color-scheme:dark}
body{margin:0;padding:24px;background:#0d1117;color:#d6dee6;
  font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
h1{font-size:20px;margin:0 0 4px}
h2{font-size:15px;margin:28px 0 8px;color:#b6c2cd}
.sub{color:#8b949e;font-size:12px}
.cards{display:flex;gap:12px;flex-wrap:wrap;margin:18px 0}
.card{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:10px 18px;min-width:110px}
.card .num{font-size:22px;font-weight:700}
.card .lbl{color:#8b949e;font-size:11px;text-transform:uppercase;letter-spacing:.05em}
.good{color:#3fb950}.warn{color:#d29922}.bad{color:#f85149}.info{color:#58a6ff}
table{width:100%;border-collapse:collapse;background:#161b22;border:1px solid #21262d;border-radius:8px}
th,td{padding:8px 10px;text-align:left;vertical-align:top;border-top:1px solid #21262d}
th{background:#1c2128;color:#8b949e;font-size:11px;text-transform:uppercase;letter-spacing:.05em;border-top:none}
.id{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;white-space:nowrap}
.badge{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;font-weight:600;white-space:nowrap}
.b-ok{background:#12261e;color:#3fb950;border:1px solid #238636}
.b-warn{background:#2a2410;color:#d29922;border:1px solid #9e6a03}
.b-fail{background:#2d1517;color:#f85149;border:1px solid #da3633}
.b-pr{background:#0d2137;color:#58a6ff;border:1px solid #1f6feb}
.b-done{background:#12261e;color:#3fb950;border:1px solid #238636}
.b-muted{background:#21262d;color:#8b949e;border:1px solid #30363d}
.b-paused{background:#1d1b2e;color:#a371f7;border:1px solid #8957e5}
.bar{width:120px;height:8px;background:#21262d;border-radius:4px;overflow:hidden}
.fill{height:100%;border-radius:4px}
.f-ok{background:#238636}.f-warn{background:#9e6a03}.f-pr{background:#1f6feb}
.f-done{background:#3fb950}.f-fail{background:#da3633}.f-muted{background:#30363d}
.f-paused{background:#8957e5}
.plabel{font-size:11px;color:#8b949e;margin-top:3px;white-space:nowrap}
.stagenote{color:#57606a}
.detail{font-size:12px;color:#8b949e;max-width:260px;word-break:break-word}
.statusline{font-size:12px;color:#8b949e;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;
  max-width:340px;word-break:break-word}
.time{white-space:nowrap;font-size:13px}
.rel{color:#8b949e;font-size:12px}
a{color:#58a6ff;text-decoration:none}
a:hover{text-decoration:underline}
.empty{background:#12261e;border:1px solid #238636;border-radius:8px;padding:28px;
  text-align:center;color:#3fb950;font-size:16px;margin:18px 0}
.decisions{background:#1c1607;border:1px solid #9e6a03;border-radius:8px;margin:18px 0}
.decisions h2{margin:0;padding:10px 14px;color:#e3b341;font-size:15px;border-bottom:1px solid #3a2d0e}
ul.dec{list-style:none;margin:0;padding:0}
ul.dec li{padding:9px 14px;border-bottom:1px solid #3a2d0e;font-size:13px;word-break:break-word}
ul.dec li:last-child{border-bottom:none}
.decask{color:#e3b341;font-weight:600}
.decmeta{color:#8b949e;font-size:12px}
.decnone{background:#161b22;border:1px solid #21262d;border-radius:8px;margin:18px 0;
  padding:12px 14px;color:#8b949e;font-size:13px}
.cols{display:flex;gap:24px;flex-wrap:wrap}
.col{flex:1;min-width:300px}
ul.bl{list-style:none;padding:0;margin:8px 0;background:#161b22;border:1px solid #21262d;border-radius:8px}
ul.bl li{padding:6px 12px;border-bottom:1px solid #21262d;font-size:13px;color:#b6c2cd}
ul.bl li:last-child{border-bottom:none}
footer{margin-top:24px;color:#57606a;font-size:11px}
</style>
</head>
<body>
<h1>firstmate fleet</h1>
<div class="sub">home: $(html_escape "$FM_HOME") · generated $(abs_time "$NOW") · auto-refreshes every 30s</div>
<div class="cards">
<div class="card"><div class="num good">$RUNNING</div><div class="lbl">running</div></div>
<div class="card"><div class="num $([ "$ATTENTION" -gt 0 ] && echo warn || echo good)">$ATTENTION</div><div class="lbl">needs attention</div></div>
<div class="card"><div class="num">$TOTAL</div><div class="lbl">total</div></div>
<div class="card">$beat_cell<div class="lbl">watcher beat</div></div>
<div class="card"><div class="num $([ "$wakes" -gt 0 ] && echo warn || echo good)">$wakes</div><div class="lbl">queued wakes</div></div>
</div>
HTMLHEAD

  if [ -n "$DECS" ]; then
    dec_items=$(printf '%s' "$DECS" | sort -n | cut -f2-)
    dec_count=$(printf '%s\n' "$dec_items" | grep -c '<li' || true)
    printf '<div class="decisions">\n<h2>⚠ Decisions needed (%s)</h2>\n<ul class="dec">\n%s\n</ul>\n</div>\n' "$dec_count" "$dec_items"
  else
    printf '<div class="decnone">Nothing needs you.</div>\n'
  fi

  if [ "$TOTAL" -eq 0 ]; then
    printf '<div class="empty">✓ No work in flight — the fleet is idle and healthy.</div>\n'
  else
    cat <<'TBLHEAD'
<h2>Direct reports</h2>
<table>
<tr><th>Task</th><th>Project</th><th>Kind</th><th>State</th><th>Progress</th>
<th>Last report</th><th>Last activity</th><th>Latest status</th><th>PR</th></tr>
TBLHEAD
    printf '%s' "$ROWS"
    printf '</table>\n<div class="sub" style="margin-top:6px">Progress is coarse and stage-based (lifecycle stage → percent), not a measured completion figure.</div>\n'
  fi

  cat <<BACKLOG
<h2>Backlog</h2>
<div class="cols">
<div class="col"><div class="lbl sub">QUEUED</div><ul class="bl">
$queued_html
</ul></div>
<div class="col"><div class="lbl sub">RECENTLY DONE</div><ul class="bl">
$done_html
</ul></div>
</div>
<footer>fm-dashboard.sh · read-only view of $(html_escape "$STATE")</footer>
</body>
</html>
BACKLOG
}

TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP"' EXIT
generate_page > "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
printf '%s\n' "$OUT"

if [ "$OPEN" = 1 ]; then
  if [ "$(uname)" = Darwin ]; then open "$OUT" || true
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$OUT" || true
  else echo "warn: no opener found (open/xdg-open); open $OUT manually" >&2
  fi
fi

if [ "$SERVE" = 1 ]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "error: --serve needs python3 (stdlib http.server); plain generation still works" >&2
    exit 1
  }
  echo "serving http://127.0.0.1:$PORT/ (regenerates on each request; Ctrl-C to stop)" >&2
  exec python3 - "$PORT" "$SCRIPT_DIR/fm-dashboard.sh" "$OUT" <<'PY'
import http.server
import subprocess
import sys

port, script, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] != "/":
            self.send_error(404)
            return
        try:
            subprocess.run(
                [script, "-o", out],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=120,
            )
        except Exception:
            pass  # serve the last good page rather than erroring
        try:
            with open(out, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(500, "dashboard not generated")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
fi

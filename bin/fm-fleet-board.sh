#!/usr/bin/env bash
# fm-fleet-board.sh - render the whole fleet as a dark, dense, clickable HTML board.
#
# READ-ONLY. Gathers live fleet state and writes one self-contained HTML file
# (default $FM_HOME/.lavish/fleet-board.html), then prints the output path. It
# never mutates fleet state: it only reads data/backlog.md, each
# state/<id>.meta, and each in-flight task's current state via
# bin/fm-crew-state.sh, and writes the single output HTML file.
#
# Usage:
#   fm-fleet-board.sh [--out <path>]
#
# Flags:
#   --out <path>   write the HTML here instead of the default
#                  ($FM_HOME/.lavish/fleet-board.html).
#   -h, --help     print this help and exit.
#
# Data sources, in order of preference. The internal per-task record shape is
# identical either way, so the snapshot path slots in without a render rewrite:
#   1. bin/fm-fleet-snapshot.sh --json, when that script exists (upstream). Its
#      JSON is normalized into the same tab-separated task records used below;
#      on any parse trouble it falls back to (2).
#   2. Direct gather: data/backlog.md sections (In flight / Queued / Done), each
#      state/<id>.meta (window=, harness=, model=, effort=, kind=, mode=, pr=),
#      and bin/fm-crew-state.sh <id> for the current state of in-flight tasks.
#
# The HTML is self-contained (inline CSS, no external assets, dark monospace)
# and renders standalone in any browser; firstmate may open it via lavish-axi,
# but the file never depends on it. Missing meta, empty backlog sections, and
# unreadable state files degrade gracefully - the board shows what is known.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# Overridable so tests can inject a hermetic crew-state stub without a real
# no-mistakes run or live pane.
CREW_STATE_CMD="${FM_CREW_STATE_CMD:-$SCRIPT_DIR/fm-crew-state.sh}"
SNAPSHOT_BIN="${FM_FLEET_SNAPSHOT_CMD:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"

# Non-whitespace field separator (ASCII unit separator). A whitespace separator
# such as tab would make `read` collapse consecutive empty fields and misalign
# the record, so the internal record delimiter must be non-whitespace.
SEP=$'\037'

print_help() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      OUT=${2:-}
      [ -n "$OUT" ] || { echo "fm-fleet-board.sh: --out needs a path" >&2; exit 2; }
      shift 2
      ;;
    --out=*) OUT=${1#--out=}; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "fm-fleet-board.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || OUT="$FM_HOME/.lavish/fleet-board.html"

# --- small helpers ----------------------------------------------------------

html_escape() {
  local s=${1:-}
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  printf '%s' "$s"
}

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

meta_val() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- normalized task record -------------------------------------------------
#
# Every task, from either data source, is emitted as one tab-separated record
# with these positional fields. Keeping this the single contract is what lets a
# future fm-fleet-snapshot.sh feed the same renderer untouched:
#
#   1 section     inflight|queued|done
#   2 id
#   3 desc        one-line description (backlog metadata stripped)
#   4 repo
#   5 kind        ship|scout (default ship)
#   6 blocked_by  upstream task id, when queued and blocked
#   7 done_ref    PR url / report path / "local main", for Done rows
#   8 state       crew-state verb for in-flight (working|parked|done|failed|blocked|unknown)
#   9 detail      crew-state current-activity detail
#  10 window      backend window label
#  11 harness
#  12 model
#  13 effort
#  14 mode
#  15 pr          full https PR url when recorded
#  16 branch      worktree branch, when readable
emit_record() {
  local f out=""
  for f in "$@"; do
    f=${f//$SEP/ }
    f=${f//$'\n'/ }
    out="$out$f$SEP"
  done
  printf '%s\n' "$out"
}

# --- direct gather ----------------------------------------------------------

# Pull a "(key: value)" group out of a backlog line's tail.
extract_paren() {  # <text> <key>
  printf '%s\n' "$1" | grep -oE "\($2: [^)]+\)" | head -1 | sed -E "s/^\($2: //; s/\)\$//"
}

parse_backlog_line() {  # <section> <raw-line>
  local section=$1 raw=$2 body id rest repo kind blocked_by pr report done_ref desc
  raw="${raw#"${raw%%[![:space:]]*}"}"
  case "$raw" in
    '- [ ] '*) body=${raw#- \[ \] } ;;
    '- [x] '*) body=${raw#- \[x\] } ;;
    '- [X] '*) body=${raw#- \[X\] } ;;
    '- '*)     body=${raw#- } ;;
    *) return 0 ;;
  esac
  # Bold in-flight form (- **<id>** - ...) collapses to the plain form.
  body=${body//\*\*/}
  case "$body" in
    *' - '*) id=${body%% - *}; rest=${body#* - } ;;
    *)       id=$(trim "$body"); rest="" ;;
  esac
  id=$(trim "$id")
  # Real task ids are single kebab tokens; anything with a space is prose.
  case "$id" in ''|*' '*) return 0 ;; esac

  repo=$(trim "$(extract_paren "$rest" repo)")
  kind=$(trim "$(extract_paren "$rest" kind)")
  [ -n "$kind" ] || kind=ship
  blocked_by=$(printf '%s\n' "$rest" | grep -oE 'blocked-by: [A-Za-z0-9_-]+' | head -1 | sed 's/blocked-by: //')
  pr=$(printf '%s\n' "$rest" | grep -oE 'https://[^ )]+' | head -1)
  report=$(printf '%s\n' "$rest" | grep -oE 'data/[^ )]+report\.md' | head -1)

  done_ref=""
  if [ "$section" = "done" ]; then
    if [ -n "$pr" ]; then done_ref=$pr
    elif [ -n "$report" ]; then done_ref=$report
    elif printf '%s' "$rest" | grep -q 'local main'; then done_ref="local main"
    fi
  fi

  # Strip trailing backlog metadata so the description reads cleanly.
  desc=$(printf '%s\n' "$rest" | sed -E \
    's/\(repo:[^)]*\)//g; s/\(kind:[^)]*\)//g; s/\(since[^)]*\)//g; s/\(added[^)]*\)//g; s/\(merged[^)]*\)//g; s/\(reported[^)]*\)//g; s/blocked-by: [A-Za-z0-9_-]+//g')
  [ -n "$pr" ] && desc=${desc//"$pr"/}
  [ -n "$report" ] && desc=${desc//"$report"/}
  desc=$(printf '%s\n' "$desc" | sed -E 's/[[:space:]]+/ /g')
  desc=$(trim "$desc")
  desc=${desc%%-}
  desc=$(trim "$desc")

  local state="" detail="" window="" harness="" model="" effort="" mode="" branch="" meta wt cs after
  if [ "$section" = inflight ]; then
    meta="$STATE/$id.meta"
    window=$(meta_val "$meta" window)
    harness=$(meta_val "$meta" harness)
    model=$(meta_val "$meta" model)
    effort=$(meta_val "$meta" effort)
    mode=$(meta_val "$meta" mode)
    local meta_pr
    meta_pr=$(meta_val "$meta" pr)
    [ -n "$meta_pr" ] && pr=$meta_pr
    wt=$(meta_val "$meta" worktree)
    if [ -n "$wt" ] && [ -d "$wt" ]; then
      branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    fi
    # Current state, read-only, degrading to unknown on any trouble.
    cs=$("$CREW_STATE_CMD" "$id" 2>/dev/null || true)
    if [ -n "$cs" ]; then
      state=${cs#state: }
      state=${state%% · *}
      case "$cs" in
        *' · source: '*)
          after=${cs#* · source: }
          case "$after" in *' · '*) detail=${after#* · } ;; esac
          ;;
      esac
    fi
    [ -n "$state" ] || state=unknown
  fi

  emit_record "$section" "$id" "$desc" "$repo" "$kind" "$blocked_by" \
    "$done_ref" "$state" "$detail" "$window" "$harness" "$model" \
    "$effort" "$mode" "$pr" "$branch"
}

gather_direct() {
  local backlog="$DATA/backlog.md" section="" line
  [ -f "$backlog" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '## In flight'*|'## In Flight'*) section=inflight; continue ;;
      '## Queued'*) section=queued; continue ;;
      '## Done'*) section="done"; continue ;;
      '#'*) section=""; continue ;;
    esac
    [ -n "$section" ] || continue
    parse_backlog_line "$section" "$line"
  done < "$backlog"
}

# --- snapshot gather (upstream seam) ----------------------------------------
#
# When bin/fm-fleet-snapshot.sh (upstream PR #343) is present, prefer its
# --json output. The exact field names are confirmed against that snapshot's
# schema at integration time; this maps the expected shape and returns non-zero
# on any mismatch so gather_direct stays authoritative until then. It emits the
# same normalized records as gather_direct, so the renderer needs no change.
gather_from_snapshot() {
  command -v jq >/dev/null 2>&1 || return 1
  local json
  json=$("$SNAPSHOT_BIN" --json 2>/dev/null) || return 1
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -e 'has("tasks")' >/dev/null 2>&1 || return 1
  printf '%s' "$json" | jq -r '
    .tasks[]? |
    [ (.section // "queued"),
      (.id // ""),
      (.desc // .description // ""),
      (.repo // ""),
      (.kind // "ship"),
      (.blocked_by // ""),
      (.done_ref // .pr // ""),
      (.state // ""),
      (.detail // ""),
      (.window // ""),
      (.harness // ""),
      (.model // ""),
      (.effort // ""),
      (.mode // ""),
      (.pr // ""),
      (.branch // "")
    ] | map(gsub("[\\u001f\\n]"; " ")) | join("\u001f")
  ' 2>/dev/null || return 1
}

gather_tasks() {
  if [ -x "$SNAPSHOT_BIN" ] && [ "${FM_FLEET_BOARD_USE_SNAPSHOT:-1}" != 0 ]; then
    local snap
    if snap=$(gather_from_snapshot) && [ -n "$snap" ]; then
      printf '%s\n' "$snap"
      return 0
    fi
  fi
  gather_direct
}

# --- rendering --------------------------------------------------------------

html_head() {
  cat <<'CSS'
<!doctype html>
<html><head><meta charset="utf-8"><title>Fleet Board</title>
<style>
  :root { --bg:#16151d; --row:#1c1b24; --row2:#211f2b; --ink:#e8e6f0; --faint:#8b87a0; --line:#2e2b3d; --accent:#a78bfa; --ok:#34d399; --work:#fbbf24; --queue:#60a5fa; --done:#6b7280; --danger:#f87171; }
  * { box-sizing:border-box; margin:0; }
  body { background:var(--bg); color:var(--ink); font:14px/1.5 ui-monospace, 'SF Mono', Menlo, monospace; padding:28px; }
  h1 { font-size:16px; letter-spacing:.06em; margin-bottom:2px; }
  .sub { color:var(--faint); font-size:12px; margin-bottom:18px; }
  .group { color:var(--faint); font-size:11px; letter-spacing:.14em; text-transform:uppercase; margin:18px 0 6px; }
  .empty { color:var(--faint); font-size:12.5px; padding:8px 4px; }
  details { background:var(--row); border-bottom:1px solid var(--line); }
  details:nth-of-type(even) { background:var(--row2); }
  summary { display:flex; align-items:center; gap:10px; padding:11px 14px; cursor:pointer; list-style:none; }
  summary::-webkit-details-marker { display:none; }
  summary .id { font-weight:700; font-size:14.5px; }
  summary .repo { color:var(--faint); font-size:12.5px; }
  .chip { font-size:11px; border:1px solid; border-radius:99px; padding:1px 10px; margin-left:auto; }
  .chip + .chip { margin-left:8px; }
  .st-work { color:var(--work); border-color:var(--work); }
  .st-queue { color:var(--queue); border-color:var(--queue); }
  .st-done { color:var(--done); border-color:var(--done); }
  .st-ok { color:var(--ok); border-color:var(--ok); }
  .st-danger { color:var(--danger); border-color:var(--danger); }
  .st-idle { color:var(--faint); border-color:var(--faint); }
  .kind { color:var(--accent); border-color:var(--accent); margin-left:0; }
  .detail { padding:4px 16px 14px 36px; color:var(--faint); font-size:12.5px; border-top:1px dashed var(--line); }
  .detail b { color:var(--ink); }
  .detail div { padding:2px 0; }
  .foot { color:var(--faint); font-size:11.5px; margin-top:18px; }
  a { color:var(--accent); }
</style></head><body>
CSS
}

# Echo "<class> <label>" for an in-flight crew state.
inflight_chip() {  # <state>
  case "$1" in
    working)      printf 'st-work working' ;;
    parked)       printf 'st-danger needs-decision' ;;
    done)         printf 'st-ok ready' ;;
    failed)       printf 'st-danger failed' ;;
    blocked)      printf 'st-danger blocked' ;;
    unknown|'')   printf 'st-idle unknown' ;;
    *)            printf 'st-idle %s' "$1" ;;
  esac
}

detail_line() {  # <label> <value>
  [ -n "$2" ] || return 0
  printf '    <div><b>%s:</b> %s</div>\n' "$(html_escape "$1")" "$(html_escape "$2")"
}

render_row() {  # <record-line>
  local line=$1
  local section id desc repo kind blocked_by done_ref state detail window harness model effort mode pr branch
  IFS=$SEP read -r section id desc repo kind blocked_by done_ref state detail window harness model effort mode pr branch <<EOF
$line
EOF
  [ -n "$id" ] || return 0

  local open="" chip_cls chip_lbl agent ci
  case "$section" in
    inflight)
      open=" open"
      ci=$(inflight_chip "$state")
      chip_cls=${ci%% *}; chip_lbl=${ci#* }
      ;;
    queued)
      chip_cls=st-queue
      if [ -n "$blocked_by" ]; then chip_lbl="blocked-by: $blocked_by"; else chip_lbl=queued; fi
      ;;
    "done")
      chip_cls=st-done
      if [ "$kind" = scout ]; then chip_lbl="done"; else chip_lbl=merged; fi
      ;;
    *)
      chip_cls=st-idle; chip_lbl=$section
      ;;
  esac

  printf '<details%s>\n' "$open"
  printf '  <summary><span class="id">%s</span>' "$(html_escape "$id")"
  [ -n "$repo" ] && printf '<span class="repo">%s</span>' "$(html_escape "$repo")"
  printf '<span class="chip kind">%s</span>' "$(html_escape "$kind")"
  printf '<span class="chip %s">%s</span></summary>\n' "$chip_cls" "$(html_escape "$chip_lbl")"
  printf '  <div class="detail">\n'
  detail_line "What" "$desc"
  if [ "$section" = inflight ]; then
    agent=$harness
    [ -n "$model" ] && [ "$model" != default ] && agent="$agent · $model"
    [ -n "$effort" ] && [ "$effort" != default ] && agent="$agent · $effort effort"
    [ -n "$window" ] && agent="$agent · $window"
    agent=${agent# · }
    detail_line "Agent" "$agent"
    detail_line "Branch" "$branch"
    detail_line "Now" "$detail"
  fi
  [ "$section" = queued ] && detail_line "Blocked by" "$blocked_by"
  if [ -n "$pr" ]; then
    printf '    <div><b>PR:</b> <a href="%s">%s</a></div>\n' "$(html_escape "$pr")" "$(html_escape "$pr")"
  fi
  [ "$section" = "done" ] && [ "$done_ref" != "$pr" ] && detail_line "Result" "$done_ref"
  printf '  </div>\n</details>\n'
}

render_group() {  # <section> <label> <records>
  local sec=$1 label=$2 records=$3 line matched="" count=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$sec$SEP"*) matched="$matched$line"$'\n'; count=$((count + 1)) ;;
    esac
  done <<< "$records"

  printf '<div class="group">%s · %s task(s)</div>\n' "$(html_escape "$label")" "$count"
  if [ "$count" -eq 0 ]; then
    printf '<div class="empty">nothing here</div>\n'
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    render_row "$line"
  done <<< "$matched"
}

render_html() {  # <records>
  local records=$1 ts
  ts=$(date '+%Y-%m-%d %H:%M')
  html_head
  printf '<h1>FLEET BOARD</h1>\n'
  printf '<div class="sub">Snapshot %s · generated by fm-fleet-board.sh · read-only, click any row for detail</div>\n' "$(html_escape "$ts")"
  render_group inflight "In flight" "$records"
  render_group queued "Queued" "$records"
  render_group "done" "Done" "$records"
  printf '<div class="foot">Regenerate any time with fm-fleet-board.sh · this file is self-contained and opens standalone in any browser.</div>\n'
  printf '</body></html>\n'
}

# --- main -------------------------------------------------------------------

RECORDS=$(gather_tasks)
mkdir -p "$(dirname "$OUT")"
render_html "$RECORDS" > "$OUT"
printf '%s\n' "$OUT"

#!/usr/bin/env bash
# fm-dashboard.sh - read-only nautical kanban dashboard for the terminal.
#
# Renders fm-fleet-snapshot.sh --json as four columns: Queued, In flight,
# Waiting on captain (live captain holds, open worker decisions, and ready PRs,
# including finished tasks whose run state is stale),
# and Done (most recent first).
# Like fm-fleet-view.sh it never parses fleet state itself, and it never
# mutates fleet state, steers workers, or merges anything.
# Colour uses ANSI escapes only when stdout is a TTY and NO_COLOR is unset.
# Width comes from COLUMNS, else tput; below four usable columns the board
# degrades to stacked columns.
# The live loop draws on the terminal's alternate screen and never emits more
# lines than the terminal is tall: each column is a viewport over its full
# cards, scrolled with up/down (j/k), focus moved with left/right (h/l), and
# its header shows the position ("cards 1-4 of 14").  Below four columns of
# width only the focused column is shown.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-dashboard.sh [--once] [--interval SECONDS] [--done N] [--snapshot FILE]
                       [--rows N] [--focus 0-3] [--scroll N]

Show firstmate's work as a kanban board in the terminal, refreshing until q.
  --once           print one frame and exit
  --interval S     seconds between refreshes (default 5)
  --done N         recent Done cards to show (default 6)
  --snapshot FILE  render this fm-fleet-snapshot.sh --json file instead of a live snapshot
  --rows N         clip the frame to N lines, each column a scrollable viewport
                   (the live loop on a terminal always does this)
  --focus C        with --rows, the focused column, 0 (Queued) to 3 (Done)
  --scroll N       with --rows, the first card shown in the focused column
Keys: up/down or k/j scroll the focused column, left/right or h/l change it, q quits.
EOF
}

ONCE=0 INTERVAL=5 DONE_MAX=6 SNAPSHOT_FILE='' ROWS=0 FOCUS=0 SCROLL=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --once) ONCE=1 ;;
    --interval) INTERVAL=${2:-}; shift ;;
    --done) DONE_MAX=${2:-}; shift ;;
    --snapshot) SNAPSHOT_FILE=${2:-}; shift ;;
    --rows) ROWS=${2:-}; shift ;;
    --focus) FOCUS=${2:-}; shift ;;
    --scroll) SCROLL=${2:-}; shift ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case "$INTERVAL" in ''|*[!0-9]*|0) echo "fm-dashboard: --interval must be a positive integer" >&2; exit 2 ;; esac
case "$DONE_MAX" in ''|*[!0-9]*) echo "fm-dashboard: --done must be a non-negative integer" >&2; exit 2 ;; esac

case "$ROWS" in ''|*[!0-9]*) echo "fm-dashboard: --rows must be a non-negative integer" >&2; exit 2 ;; esac
case "$FOCUS" in [0-3]) ;; *) echo "fm-dashboard: --focus must be 0-3" >&2; exit 2 ;; esac
case "$SCROLL" in ''|*[!0-9]*) echo "fm-dashboard: --scroll must be a non-negative integer" >&2; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { echo "fm-dashboard: jq not found" >&2; exit 1; }

COLOR=false
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && COLOR=true

# shellcheck disable=SC2016  # jq program, not shell expansion
RENDER='
  def paint($s): if $color and $s != "" then "\u001b[\($s)m" + . + "\u001b[0m" else . end;
  def rep($n): if $n > 0 then . * $n else "" end;
  def trunc($n): if length <= $n then . elif $n < 2 then .[:$n] else .[:$n-1] + "…" end;
  def fit($w): reduce .[] as [$t, $s] ({r: [], left: $w}; .r += [[$t[:.left], $s]] | .left = ([.left - ($t | length), 0] | max)) | .r;
  def chunks($n): if length <= $n then [.] else [.[:$n]] + (.[$n:] | chunks($n)) end;
  def dash: if . == null or . == "" then "-" else tostring end;
  def seg($t; $s): [[$t, $s]];
  # A rendered line is a list of [text, style] segments padded to width $w.
  def out($w): (map(.[0] | length) | add // 0) as $v
    | (map(. as [$t, $s] | $t | paint($s)) | join("")) + (" " | rep($w - $v));

  def state_style:
    if . == "working" then "1;32" elif . == "done" then "1;36"
    elif . == "blocked" or . == "failed" then "1;31"
    elif . == "paused" or . == "parked" then "1;33" else "2" end;

  def card($c; $w; $bs):
    ($w - 2) as $iw
    | [seg("╭─ "; $bs) + seg($c.id | dash | trunc($w - 5); "1;37") + seg(" " + ("─" | rep($w - 4 - ($c.id | dash | trunc($w - 5) | length))); $bs)]
      + [$c.title | dash | chunks($iw)[:2][] | seg("│ "; $bs) + seg(.; "")]
      + [seg("│ "; $bs) + seg("\($c.project | dash) · \($c.kind | dash) · \($c.mode | dash)" | trunc($iw); "2")]
      + (if $c.state then [seg("│ "; $bs) + seg("⚑ " + $c.state + (if ($c.detail // "") != "" then " - " + $c.detail else "" end) | trunc($iw); $c.state | state_style)] else [] end)
      + (if $c.note then [seg("│ "; $bs) + seg($c.note | trunc($iw); "1;35")] else [] end)
      + (if $c.pr then [$c.pr | chunks($iw)[] | seg("│ "; $bs) + seg(.; "4;34")] else [] end)
      + [seg("╰" + ("─" | rep($w - 1)); $bs)];

  # Whole cards from $off that fit in $body lines; the first is clipped if taller.
  def viewport($cards; $w; $bs; $off; $body):
    ($cards | map(card(.; $w; $bs))) as $cs
    | reduce range($off; $cs | length) as $i ({lines: [], n: 0, stop: false};
        if .stop then .
        else ($cs[$i] | length) as $h
          | if (.lines | length) + $h <= $body or .n == 0
            then .lines += $cs[$i] | .n += 1 else .stop = true end
        end)
    | .lines |= .[:$body];

  # $body 0 renders every card; otherwise the column is a viewport over them.
  def column($col; $w; $body; $off; $focused):
    ($col.cards | length) as $t
    | [seg((if $focused then "▶ " else "" end) + $col.name | trunc($w); $col.style + ";1")]
    + [seg(($col.motto + " (\($t))") | trunc($w); "2;3")]
    + [seg("═" | rep($w); $col.style)]
    + (if $body == 0 then
         (if $t == 0 then [seg("  calm waters" | trunc($w); "2")]
          else [$col.cards[] | card(.; $w; $col.style)[]] end)
       else
         viewport($col.cards; $w; $col.style; $off; $body) as $v
         | [seg((if $t == 0 then "cards 0 of 0"
                 else "cards \($off + 1)-\($off + $v.n) of \($t)"
                   + (if $off > 0 then " ↑" else "" end)
                   + (if $off + $v.n < $t then " ↓" else "" end) end) | trunc($w); "2")]
         + (if $t == 0 then [seg("  calm waters" | trunc($w); "2")] else $v.lines end)
       end);

  def task_card($t; $note): {
    id: $t.id,
    title: ($t.backlog.title // $t.id),
    project: ($t.backlog.repo // $t.project),
    kind: $t.kind, mode: $t.mode,
    state: ($t.current_state.state // "unknown"),
    detail: ($t.current_state.detail // ""),
    note: $note,
    pr: $t.pr.url
  };
  def record_card($r; $note): {
    id: ($r.id // "note"),
    title: ($r.title // $r.raw),
    project: $r.repo, kind: $r.kind, mode: null, state: null,
    note: $note,
    pr: ($r.pr_url // $r.report_path)
  };

  # A finished task with an open PR waits on the captain, also when its run
  # state is stale or unrecognized: its latest status line says done and no
  # worker is alive.
  def pr_ready: .pr.url != null
    and (.current_state.state == "done"
      or (.paths.status_log.last_event.state == "done" and .endpoint.status != "alive"));

  (.tasks // []) as $tasks
  | (.backlog.records // []) as $records
  | ($records | map(select(.state != "done" and .captain_actionable == true and (.id // "") != ""))) as $held
  | ($held | map(.id)) as $held_ids
  | ($tasks | map(select(.hints.pending_decision == true
      or pr_ready
      or (.id as $id | $held_ids | index($id))))) as $task_waits
  | ($task_waits | map(.id)) as $wait_ids
  | ($records | map(select(.state != "done" and .captain_actionable == true and ((.id // "") as $id | $wait_ids | index($id) | not)))) as $holds
  | [
      {name: "QUEUED", motto: "in the hold", style: "36",
       cards: [$records[] | select(.state == "queued" and .captain_actionable != true)
         | record_card(.; if (.blocked_by // "") != "" then "awaits " + .blocked_by else null end)]},
      {name: "IN FLIGHT", motto: "under sail", style: "32",
       cards: [$tasks[] | select(.id as $id | $wait_ids | index($id) | not) | task_card(.; null)]},
      {name: "WAITING ON CAPTAIN", motto: "the captain'"'"'s call", style: "35",
       cards: ([$task_waits[] | task_card(.; if .hints.pending_decision == true then "decision needed"
           elif pr_ready then "PR ready for review"
           else "held: " + (.id as $id | $held[] | select(.id == $id) | .hold_reason // "decision") end)]
         + [$holds[] | record_card(.; "held: " + (.hold_reason // "decision"))])},
      {name: "DONE", motto: "made port", style: "33",
       cards: ([$records[] | select(.state == "done")] | .[:$done_max] | map(record_card(.; null)))}
    ] as $cols
  | (.fm_home // "firstmate" | split("/") | map(select(. != "")) | last // "firstmate") as $fleet
  | ($cols | to_entries | map(
      [([($offsets[.key] // 0), 0] | max), ([(.value.cards | length) - 1, 0] | max)] | min)) as $offs
  | ($width >= 4 * 24 + 3) as $wide
  | ($rows > 0) as $clip
  | ([$rows - 4 - 4 - (if $wide then 0 else 1 end), 1] | max) as $body
  | ([
      [
      (seg("⚓ FIRSTMATE"; "1;33") + seg("  ·  ship'"'"'s log of the "; "2") + seg($fleet; "1;37") + seg(" fleet"; "2") | fit(if $clip then $width else 100000 end) | out(0)),
      (seg("\($cols[1].cards | length) under sail · \($cols[0].cards | length) in the hold · \($cols[2].cards | length) awaiting the captain · \($cols[3].cards | length) made port"; "1") | fit(if $clip then $width else 100000 end) | out(0)),
      (seg("logged \(.generated // "-")" + (if $once then "" else " · refresh \($interval)s · q to quit" end); "2") | fit(if $clip then $width else 100000 end) | out(0)),
      ""
    ][],
    (if $wide then
       (($width - 3) / 4 | floor) as $cw
       | ($cols | to_entries | map(column(.value; $cw; (if $clip then $body else 0 end); $offs[.key]; $clip and .key == $focus))) as $blocks
       | ($blocks | map(length) | max) as $h
       | range(0; $h) as $i
       | [$blocks[] | (.[$i] // []) | out($cw)] | join(" ") | sub(" +$"; "")
     elif $clip then
       (seg($cols | to_entries | map(if .key == $focus then "[" + .value.name + "]" else .value.name end) | join(" · ") | trunc($width); "2") | out(0)),
       ($cols[$focus] | column(.; [$width, 20] | max; $body; $offs[$focus]; true)[] | out(0))
     else
       $cols[] | (column(.; [$width, 20] | max; 0; 0; false)[] | out(0)), ""
     end)
    ]) as $lines
  | (if $clip then $lines[:$rows] else $lines end) as $shown
  | if $live then ($offs | map(tostring) | join(" ")), $shown[] else $shown[] end
'

snapshot() {
  if [ -n "$SNAPSHOT_FILE" ]; then cat -- "$SNAPSHOT_FILE"; else "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; fi
}

term_height() {
  local size=
  [ -n "${LINES:-}" ] || size=$({ stty size </dev/tty; } 2>/dev/null) || size=
  printf '%s\n' "${LINES:-${size% *}}"
}

term_width() {
  local size=
  [ -n "${COLUMNS:-}" ] || size=$({ stty size </dev/tty; } 2>/dev/null) || size=
  printf '%s\n' "${COLUMNS:-${size#* }}"
}

# render <width> <rows> <focus> <offsets-json> <live>: draw a snapshot; with
# <live> true the first line printed is the clamped scroll offsets.
render() {
  local width=$2
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  printf '%s\n' "$1" | jq -r --argjson color "$COLOR" --argjson width "$width" \
    --argjson once "$([ "$ONCE" = 1 ] && echo true || echo false)" \
    --argjson interval "$INTERVAL" --argjson done_max "$DONE_MAX" \
    --argjson rows "$3" --argjson focus "$4" --argjson offsets "$5" --argjson live "$6" "$RENDER"
}

frame() {  # <width>
  local json offs="[0,0,0,0]"
  json=$(snapshot) || return $?
  [ "$ROWS" -gt 0 ] && offs=$(printf '[%s,%s,%s,%s]' "$([ "$FOCUS" = 0 ] && echo "$SCROLL" || echo 0)" \
    "$([ "$FOCUS" = 1 ] && echo "$SCROLL" || echo 0)" "$([ "$FOCUS" = 2 ] && echo "$SCROLL" || echo 0)" \
    "$([ "$FOCUS" = 3 ] && echo "$SCROLL" || echo 0)")
  render "$json" "$1" "$ROWS" "$FOCUS" "$offs" false
}

if [ "$ONCE" = 1 ]; then
  frame "$(term_width)"
  exit $?
fi

draw() {  # <text>: repaint in place, one terminal row per line, no scroll
  local -a lines
  local i last buf=$'\033[H'
  mapfile -t lines <<<"$1"
  last=$((${#lines[@]} - 1))
  for i in "${!lines[@]}"; do
    buf+="${lines[$i]}"$'\033[K'
    [ "$i" -lt "$last" ] && buf+=$'\n'
  done
  printf '%s\033[J' "$buf"
}

if [ ! -t 1 ]; then
  trap 'exit 0' INT TERM
  while :; do
    out=$(frame "$(term_width)" 2>&1)
    printf '%s\n' "$out"
    if [ -t 0 ]; then
      key=
      read -rsn1 -t "$INTERVAL" key || true
      case "$key" in q|Q) exit 0 ;; esac
    else
      sleep "$INTERVAL"
    fi
  done
fi

# Live terminal: alternate screen, viewport per column, keyboard scrolling.
# The tty stays unechoed for the whole session so keys typed while the board is
# busy never print as ^[[C, and the snapshot is fetched in the background so
# keys keep registering and the board keeps redrawing while it runs.
saved_tty=$(stty -g 2>/dev/null) || saved_tty=
[ -n "$saved_tty" ] && stty -echo -icanon 2>/dev/null
snap_file=$(mktemp "${TMPDIR:-/tmp}/fm-dashboard.XXXXXX") || exit 1
fetch_pid=''
cleanup() {
  [ -n "$fetch_pid" ] && kill "$fetch_pid" 2>/dev/null
  rm -f "$snap_file"
  [ -n "$saved_tty" ] && stty "$saved_tty" 2>/dev/null
  printf '\033[?1049l'
  tput cnorm 2>/dev/null || true
}
tput civis 2>/dev/null || true
printf '\033[?1049h'
trap cleanup EXIT
trap 'exit 0' INT TERM
dirty=1
trap 'dirty=1' WINCH

# read_key <timeout>: set key from the tty, mapping arrow escapes to k/j/l/h.
read_key() {
  local rest
  key=
  if [ -t 0 ]; then read -rsn1 -t "$1" key && [ -n "$key" ] || return 1; else sleep "$1"; return 1; fi
  if [ "$key" = $'\033' ]; then
    read -rsn2 -t 0.05 rest || rest=
    case "$rest" in '[A') key=k ;; '[B') key=j ;; '[C') key=l ;; '[D') key=h ;; *) key= ;; esac
  fi
}

focus=0 offs="0 0 0 0" json='' deadline=0 key=
while :; do
  if [ -n "$fetch_pid" ] && ! kill -0 "$fetch_pid" 2>/dev/null; then
    wait "$fetch_pid" 2>/dev/null
    fetch_pid=''
    json=$(<"$snap_file")
    deadline=$((SECONDS + INTERVAL))
    dirty=1
  fi
  if [ -z "$fetch_pid" ] && [ "$SECONDS" -ge "$deadline" ]; then
    snapshot >"$snap_file" 2>&1 &
    fetch_pid=$!
  fi
  if [ "$dirty" = 1 ]; then
    dirty=0
    rows=$(term_height)
    case "$rows" in ''|*[!0-9]*|0) rows=24 ;; esac
    if [ -z "$json" ]; then
      out=$'\u2693 FIRSTMATE  \u00b7  hoisting the ship'"'"'s log...'
    else
      # shellcheck disable=SC2086  # $offs is four space-separated integers
      set -- $offs
      out=$(render "$json" "$(term_width)" "$rows" "$focus" "[$1,$2,$3,$4]" true 2>&1)
      case "${out%%$'\n'*}" in
        *[!0-9\ ]*|'') ;;
        *) offs=${out%%$'\n'*}; out=${out#*$'\n'} ;;
      esac
    fi
    draw "$out"
  fi
  # Wait for a key, then drain every pending key before the next redraw so a
  # held key costs one repaint, not one per repeat.
  read_key 0.25 || continue
  while :; do
    # shellcheck disable=SC2086
    set -- $offs
    case "$key" in
      q|Q) exit 0 ;;
      j) arr=("$@"); arr[focus]=$((arr[focus] + 1)); offs="${arr[*]}"; dirty=1 ;;
      k) arr=("$@"); [ "${arr[focus]}" -gt 0 ] && arr[focus]=$((arr[focus] - 1)); offs="${arr[*]}"; dirty=1 ;;
      l) [ "$focus" -lt 3 ] && focus=$((focus + 1)); dirty=1 ;;
      h) [ "$focus" -gt 0 ] && focus=$((focus - 1)); dirty=1 ;;
    esac
    read_key 0.01 || break
  done
done

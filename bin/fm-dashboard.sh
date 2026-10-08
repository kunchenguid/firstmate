#!/usr/bin/env bash
# fm-dashboard.sh - read-only nautical kanban dashboard for the terminal.
#
# Renders fm-fleet-snapshot.sh --json as four columns: Queued, In flight,
# Waiting on captain (live captain holds, open worker decisions, and ready PRs),
# and Done (most recent first).
# Like fm-fleet-view.sh it never parses fleet state itself, and it never
# mutates fleet state, steers workers, or merges anything.
# Colour uses ANSI escapes only when stdout is a TTY and NO_COLOR is unset.
# Width comes from COLUMNS, else tput; below four usable columns the board
# degrades to stacked columns.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-dashboard.sh [--once] [--interval SECONDS] [--done N] [--snapshot FILE]

Show firstmate's work as a kanban board in the terminal, refreshing until q.
  --once           print one frame and exit
  --interval S     seconds between refreshes (default 5)
  --done N         recent Done cards to show (default 6)
  --snapshot FILE  render this fm-fleet-snapshot.sh --json file instead of a live snapshot
EOF
}

ONCE=0 INTERVAL=5 DONE_MAX=6 SNAPSHOT_FILE=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --once) ONCE=1 ;;
    --interval) INTERVAL=${2:-}; shift ;;
    --done) DONE_MAX=${2:-}; shift ;;
    --snapshot) SNAPSHOT_FILE=${2:-}; shift ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case "$INTERVAL" in ''|*[!0-9]*|0) echo "fm-dashboard: --interval must be a positive integer" >&2; exit 2 ;; esac
case "$DONE_MAX" in ''|*[!0-9]*) echo "fm-dashboard: --done must be a non-negative integer" >&2; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { echo "fm-dashboard: jq not found" >&2; exit 1; }

COLOR=false
[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && COLOR=true

# shellcheck disable=SC2016  # jq program, not shell expansion
RENDER='
  def paint($s): if $color and $s != "" then "\u001b[\($s)m" + . + "\u001b[0m" else . end;
  def rep($n): if $n > 0 then . * $n else "" end;
  def trunc($n): if length <= $n then . elif $n < 2 then .[:$n] else .[:$n-1] + "…" end;
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

  def column($col; $w):
    [seg($col.name | trunc($w); $col.style + ";1")]
    + [seg(($col.motto + " (\($col.cards | length))") | trunc($w); "2;3")]
    + [seg("═" | rep($w); $col.style)]
    + (if ($col.cards | length) == 0 then [seg("  calm waters" | trunc($w); "2")]
       else [$col.cards[] | card(.; $w; $col.style)[]] end);

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

  (.tasks // []) as $tasks
  | (.backlog.records // []) as $records
  | ($records | map(select(.state != "done" and .captain_actionable == true and (.id // "") != ""))) as $held
  | ($held | map(.id)) as $held_ids
  | ($tasks | map(select(.hints.pending_decision == true
      or (.current_state.state == "done" and .pr.url != null)
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
           elif .current_state.state == "done" and .pr.url != null then "PR ready for review"
           else "held: " + (.id as $id | $held[] | select(.id == $id) | .hold_reason // "decision") end)]
         + [$holds[] | record_card(.; "held: " + (.hold_reason // "decision"))])},
      {name: "DONE", motto: "made port", style: "33",
       cards: ([$records[] | select(.state == "done")] | .[:$done_max] | map(record_card(.; null)))}
    ] as $cols
  | (.fm_home // "firstmate" | split("/") | map(select(. != "")) | last // "firstmate") as $fleet
  | [
      (seg("⚓ FIRSTMATE"; "1;33") + seg("  ·  ship'"'"'s log of the "; "2") + seg($fleet; "1;37") + seg(" fleet"; "2") | out(0)),
      (seg("\($cols[1].cards | length) under sail · \($cols[0].cards | length) in the hold · \($cols[2].cards | length) awaiting the captain · \($cols[3].cards | length) made port"; "1") | out(0)),
      (seg("logged \(.generated // "-")" + (if $once then "" else " · refresh \($interval)s · q to quit" end); "2") | out(0)),
      ""
    ][],
    (if $width >= 4 * 24 + 3 then
       (($width - 3) / 4 | floor) as $cw
       | ($cols | map(column(.; $cw))) as $blocks
       | ($blocks | map(length) | max) as $h
       | range(0; $h) as $i
       | [$blocks[] | (.[$i] // []) | out($cw)] | join(" ") | sub(" +$"; "")
     else
       $cols[] | (column(.; [$width, 20] | max)[] | out(0)), ""
     end)
'

snapshot() {
  if [ -n "$SNAPSHOT_FILE" ]; then cat -- "$SNAPSHOT_FILE"; else "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; fi
}

term_width() {
  local size=
  [ -n "${COLUMNS:-}" ] || size=$({ stty size </dev/tty; } 2>/dev/null) || size=
  printf '%s\n' "${COLUMNS:-${size#* }}"
}

frame() {  # <width>
  local json width=$1
  json=$(snapshot) || return $?
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  printf '%s\n' "$json" | jq -r --argjson color "$COLOR" --argjson width "$width" \
    --argjson once "$([ "$ONCE" = 1 ] && echo true || echo false)" \
    --argjson interval "$INTERVAL" --argjson done_max "$DONE_MAX" "$RENDER"
}

if [ "$ONCE" = 1 ]; then
  frame "$(term_width)"
  exit $?
fi

if [ -t 1 ]; then
  tput civis 2>/dev/null || true
  trap 'tput cnorm 2>/dev/null || true; printf "\n"' EXIT
fi
trap 'exit 0' INT TERM
while :; do
  # Re-read the terminal size each frame so a resize is picked up.
  out=$(frame "$(term_width)" 2>&1)
  [ -t 1 ] && printf '\033[H\033[2J'
  printf '%s\n' "$out"
  if [ -t 0 ]; then
    key=
    read -rsn1 -t "$INTERVAL" key || true
    case "$key" in q|Q) exit 0 ;; esac
  else
    sleep "$INTERVAL"
  fi
done

#!/usr/bin/env bash
# fm-fleet-view.sh - narrow human side-panel over fm-fleet-snapshot.sh.
#
# The view is read-only and does not parse fleet files itself. Normal and watch
# renders ask the canonical snapshot to skip live usage queries because usage is
# not shown here; this keeps a few-second redraw cadence cheap. --json preserves
# the canonical snapshot's complete default behavior.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_CMD="$SCRIPT_DIR/fm-fleet-snapshot.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-view.sh [--json] [--watch [interval]]

Render a narrow, prioritized fleet side panel from fm-fleet-snapshot.sh.
Use --json to print the complete underlying snapshot.
Use --watch to redraw every 5 seconds, or provide a positive interval in seconds.
EOF
}

FORMAT=panel
WATCH=0
INTERVAL=5
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --watch)
      WATCH=1
      if [ $# -gt 1 ] && [[ $2 != -* ]]; then
        shift
        INTERVAL=$1
      fi
      ;;
    --watch=*) WATCH=1; INTERVAL=${1#--watch=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$FORMAT" = json ] && [ "$WATCH" = 1 ]; then
  echo "fm-fleet-view: --json and --watch cannot be combined" >&2
  exit 2
fi
if [ "$WATCH" = 1 ]; then
  if ! [[ $INTERVAL =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ $INTERVAL =~ ^0+([.]0+)?$ ]]; then
    echo "fm-fleet-view: watch interval must be a positive number" >&2
    exit 2
  fi
fi

if [ "$FORMAT" = json ]; then
  "$SNAPSHOT_CMD" --json
  exit $?
fi

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-view: jq not found" >&2; exit 1; }

terminal_width() {
  local width=${COLUMNS:-}
  case "$width" in
    ''|*[!0-9]*)
      width=
      if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
        width=$(tput cols 2>/dev/null || true)
      fi
      ;;
  esac
  case "$width" in ''|*[!0-9]*) width=60 ;; esac
  [ "$width" -ge 20 ] || width=20
  printf '%s\n' "$width"
}

render_once() {
  local width snapshot
  width=$(terminal_width)
  if ! snapshot=$("$SNAPSHOT_CMD" --json); then
    printf '%s\n' "FLEET VIEW DEGRADED" "Snapshot unavailable; retrying on the next redraw."
    return 1
  fi

  printf '%s\n' "$snapshot" | jq -r --argjson width "$width" '
    def clean: tostring | gsub("[[:space:]]+"; " ");
    def clip($n):
      clean
      | if length <= $n then .
        elif $n <= 1 then .[:$n]
        else .[:($n - 1)] + "…" end;
    def line($prefix; $value): $prefix + ($value | clip(($width - ($prefix | length)) | if . < 1 then 1 else . end));
    def task_title($t): ($t.backlog.title // $t.project // $t.id // "unknown");
    def task_step($t):
      (($t.current_state.detail // "") as $detail
       | if $detail != "" then $detail else ($t.hints.last_event_text // "unknown") end)
      | sub("^[a-z-]+( \\[[^]]+\\])?:[[:space:]]*"; "")
      | if . == "" then "unknown" else . end;
    def artifact($r): ($r.pr_url // "-");

    . as $snapshot
    | ([.tasks[]?] | sort_by(.id)) as $working
    | ([.backlog.records[]?
        | select(.state == "queued" and .structured == true
                 and ((.kind // "") == "captain" or (.hold_kind // "") == "captain"))]) as $captain_held
    | (([.tasks[]? as $task
        | ($task.hints.open_decisions // [])[]?
        | {id:($task.id // "unknown"),verb:(.verb // "needs-decision"),summary:(.summary // "reason unavailable")}]
       + [$captain_held[]
          | {id:(.id // "unknown"),verb:"needs-decision",
             summary:(.hold // .blocked_reason // .body_excerpt // .title // "reason unavailable")}])
       | sort_by([if .verb == "needs-decision" then 0 else 1 end, .id])) as $waiting
    | ([.backlog.records[]?
        | select(.state == "done" and .structured == true and .pr_url != null)
        | {id,title,pr_url,completion}]
       + [(.secondmate_landed.records // [])[]?
          | select(.pr_url != null)
          | {id,title,pr_url,completion}]
       | sort_by([(.completion.date // ""),(.id // "")]) | reverse) as $landed
    | ([.backlog.records[]? | select(.state == "done" and .structured == true) | .id]) as $done_ids
    | ([.backlog.records[]?
        | select(.state == "queued" and .structured == true
                 and (((.kind // "") == "captain" or (.hold_kind // "") == "captain") | not))]) as $queued
    | ([$queued[]
        | .blocked_by as $blocker
        | select(($blocker // "") == "" or (($done_ids | index($blocker)) != null))]) as $ready
    | ([$queued[]
        | .blocked_by as $blocker
        | select(($blocker // "") != "" and (($done_ids | index($blocker)) == null))]) as $blocked
    | ("=" * $width),
      ("FIRSTMATE FLEET" | clip($width)),
      ("=" * $width),
      "",
      ("WORKING NOW (\($working | length))" | clip($width)),
      (if ($working | length) == 0 then
         "  No live workers."
       else
         $working[]
         | line("• "; ((.id // "unknown") + " · " + task_title(.))),
           line("  "; ((.current_state.state // "unknown") + ": " + task_step(.)))
       end),
      "",
      (if ($waiting | length) > 0 then "!" * $width else empty end),
      ("WAITING ON THE CAPTAIN (\($waiting | length))" | clip($width)),
      (if ($waiting | length) == 0 then
         "  Nothing needs a captain decision."
       else
         $waiting[]
         | line("! "; .id),
           line("  "; .summary)
       end),
      (if ($waiting | length) > 0 then "!" * $width else empty end),
      "",
      ("LANDED (showing \([($landed[:5])[]] | length) of \($landed | length))" | clip($width)),
      (if ($landed | length) == 0 then
         "  No recently merged work with a PR link."
       else
         $landed[:5][]
         | line("• "; ((.id // "unknown") + " · " + (.title // "unknown"))),
           line("  "; artifact(.))
       end),
      "",
      ("QUEUED \($queued | length) · READY \($ready | length) · BLOCKED \($blocked | length)" | clip($width)),
      "Ready now:",
      (if ($ready | length) == 0 then "  None." else $ready[] | line("• "; ((.id // "unknown") + " · " + (.title // "unknown"))) end),
      "Still blocked:",
      (if ($blocked | length) == 0 then
         "  None."
       else
         $blocked[]
         | line("• "; ((.id // "unknown") + " ← " + (.blocked_by // "unknown")
                       + (if (.blocked_reason // "") == "" then "" else " · " + .blocked_reason end)))
       end)
  ' || {
    echo "FLEET VIEW DEGRADED"
    echo "Snapshot data could not be rendered; retrying on the next redraw."
    return 1
  }
}

if [ "$WATCH" = 1 ]; then
  trap 'printf "\033[0m\n"; exit 0' INT TERM HUP
  while :; do
    printf '\033[H\033[2J'
    render_once || true
    sleep "$INTERVAL"
  done
fi

render_once

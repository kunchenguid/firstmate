#!/usr/bin/env bash
# fm-fleet-view.sh - narrow human side-panel over fm-fleet-snapshot.sh.
#
# The view is read-only and does not parse fleet files itself.
# Every task is classified exclusively from reconciled current state: working,
# waiting for a decision or merge, finished, failed, paused, or unknown.
# Queued backlog records are shown separately as ready, dependency-blocked, or
# decision-held; decision-held records appear under waiting rather than queued.
# Watch mode uses only bash, jq, terminal control sequences, and sleep; a failed
# snapshot or render prints an explicit degraded panel and retries next redraw.
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
    def task_artifact($t):
      ($t.pr.url // $t.backlog.pr_url // (if $t.paths.report.present then $t.paths.report.path else null end));
    def waiting_on_merge($t):
      ($t.current_state.state // "") == "done"
      and ($t.backlog.state // "") == "in_flight"
      and (($t.pr.url // $t.backlog.pr_url // null) != null);

    . as $snapshot
    | ([.tasks[]?] | sort_by(.id)) as $tasks
    | ([$tasks[] | select((.current_state.state // "unknown") == "working")]) as $working
    | ([$tasks[].id] | unique) as $current_task_ids
    | ([.backlog.records[]?
        | select(.state == "queued" and .structured == true
                 and ((.kind // "") == "captain" or (.hold_kind // "") == "captain"))]) as $captain_held
    | ([.tasks[]? as $task
        | ($task.hints.open_decisions // [])[]?
        | {id:($task.id // "unknown"),verb:(.verb // "needs-decision"),
           summary:(.summary // "reason unavailable"),artifact:task_artifact($task)}]) as $decision_waiting
    | ([$decision_waiting[].id] | unique) as $decision_ids
    | (($decision_waiting
       + [$captain_held[]
          | {id:(.id // "unknown"),verb:"needs-decision",
             summary:(.hold // .blocked_reason // .body_excerpt // .title // "reason unavailable"),artifact:null}]
       + [$tasks[]
          | select((.current_state.state // "unknown") == "parked"
                   or (.current_state.state // "unknown") == "blocked"
                   or waiting_on_merge(.))
          | . as $task
          | select(waiting_on_merge($task) or (($decision_ids | index($task.id)) == null))
          | {id:(.id // "unknown"),verb:(if waiting_on_merge(.) then "merge" else (.current_state.state // "parked") end),
             summary:((.current_state.detail // "") | if . == "" then "reason unavailable" else . end),
             artifact:task_artifact(.)}])
       | sort_by([if .verb == "needs-decision" then 0 else 1 end, .id])) as $waiting
    | ([$tasks[]
        | select((.current_state.state // "unknown") == "done" and (waiting_on_merge(.) | not))
        | {id:(.id // "unknown"),title:task_title(.),summary:task_step(.),artifact:task_artifact(.)}]) as $live_finished
    | ([.backlog.records[]?
        | select(.state == "done" and .structured == true
                 and ((.id as $id | $current_task_ids | index($id)) == null))
        | {id,title,summary:((.completion.verb // "done") + (if (.completion.date // "") == "" then "" else " " + .completion.date end)),
           artifact:(.pr_url // .report_path // .local_note // null),completion}]
       + [(.secondmate_landed.records // [])[]?
          | select((.id as $id | $current_task_ids | index($id)) == null)
          | {id,title,summary:((.completion.verb // "done") + (if (.completion.date // "") == "" then "" else " " + .completion.date end)),
             artifact:(.pr_url // .report_path // .local_note // null),completion}]
       | sort_by([(.completion.date // ""),(.id // "")]) | reverse) as $history_finished
    | (reduce ($live_finished + $history_finished)[] as $row
         ([]; if ([.[].id] | index($row.id)) == null then . + [$row] else . end)) as $finished
    | ([$tasks[] | select((.current_state.state // "unknown") == "failed")]) as $failed
    | ([$tasks[] | select((.current_state.state // "unknown") == "paused")]) as $paused
    | ([$tasks[]
        | (.current_state.state // "unknown") as $state
        | select((["working","parked","blocked","done","failed","paused"]
                  | index($state)) == null)]) as $unknown
    | ([.backlog.records[]?
        | select(.state == "queued" and .structured == true
                 and (((.kind // "") == "captain" or (.hold_kind // "") == "captain") | not))]) as $queued
    | ([$queued[]
        | select(((.unresolved_blocker_ids // []) | length) == 0)]) as $ready
    | ([$queued[]
        | select(((.unresolved_blocker_ids // []) | length) > 0)]) as $blocked
    | ("=" * $width),
      ("FLEET STATUS" | clip($width)),
      ("=" * $width),
      "",
      ("WORKING NOW (\($working | length))" | clip($width)),
      (if ($working | length) == 0 then
         "  No active tasks."
       else
         $working[]
         | line("• "; ((.id // "unknown") + " · " + task_title(.))),
           line("  "; ((.current_state.state // "unknown") + ": " + task_step(.)))
       end),
      "",
      (if ($waiting | length) > 0 then "!" * $width else empty end),
      ("WAITING ON DECISION (\($waiting | length))" | clip($width)),
      (if ($waiting | length) == 0 then
         "  No decisions or merges pending."
       else
         $waiting[]
         | line("! "; .id),
           line("  "; .summary),
           (if .artifact == null then empty else line("  "; .artifact) end)
       end),
      (if ($waiting | length) > 0 then "!" * $width else empty end),
      "",
      ("FINISHED (showing \([($finished[:5])[]] | length) of \($finished | length))" | clip($width)),
      (if ($finished | length) == 0 then
         "  Nothing has finished successfully."
       else
         $finished[:5][]
         | line("• "; ((.id // "unknown") + " · " + (.title // "unknown"))),
           line("  "; (.summary // "done")),
           (if .artifact == null then empty else line("  "; .artifact) end)
       end),
      "",
      ("FAILED (\($failed | length))" | clip($width)),
      (if ($failed | length) == 0 then
         "  No failed tasks."
       else
         $failed[]
         | line("• "; ((.id // "unknown") + " · " + task_title(.))),
           line("  "; task_step(.))
       end),
      "",
      (if ($paused | length) == 0 then empty else
         ("PAUSED (\($paused | length))" | clip($width)),
         ($paused[]
          | line("• "; ((.id // "unknown") + " · " + task_title(.))),
            line("  "; task_step(.))),
         ""
       end),
      ("UNKNOWN (\($unknown | length))" | clip($width)),
      (if ($unknown | length) == 0 then
         "  No tasks with unknown state."
       else
         $unknown[]
         | line("• "; ((.id // "unknown") + " · " + task_title(.))),
           line("  "; task_step(.))
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
         | line("• "; ((.id // "unknown") + " ← " + ((.unresolved_blocker_ids // []) | join(","))
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

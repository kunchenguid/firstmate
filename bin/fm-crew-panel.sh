#!/usr/bin/env bash
# fm-crew-panel.sh - the read-only crew status panels beside firstmate and each worker.
#
# Usage: fm-crew-panel.sh [--task <task-id>] [--watch [--interval <s>] [--rounds <n>]]
#                         [--snapshot <file>] [--width <n>] [--name <crew>]
#                         [--color|--no-color] [--now <epoch>]
#        fm-crew-panel.sh open-fleet
#        fm-crew-panel.sh open-task <task-id>
#
# Without --task it prints the fleet panel: one card for each worker of this
# home, in the order needs you, no reply or failed, PR or report ready,
# verifying or checking, working, starting; inside one group the oldest worker
# is first. A ship's pstack verifier (<ship>-verify) shows inside its ship's
# card. With --task it prints that worker's own panel: the question for the
# captain, every plan step name, the messages from firstmate, the events, the
# automatic review steps, the verifier steps and scenario results, and the PR.
# A section with no data is left out. No line is wider than the panel.
#
# The panel reads fm-fleet-snapshot.sh --json, the worker's status log, its
# inbox messages, and its no-mistakes run (only from the worker's own branch).
# bin/fm-crew-panel.jq owns the layout. The panel never changes any state.
#
# open-fleet and open-task split a Herdr pane to the right of the caller's pane
# (open-fleet) or of the task's recorded pane (open-task), label the new pane
# fm-crew-panel, and run the panel there with --watch. bin/fm-session-start.sh
# runs open-fleet and bin/fm-spawn.sh runs open-task. Both are idempotent: a tab
# that already has a fm-crew-panel pane gets no second panel. They do nothing,
# with exit 0, when config/crew-panel is off, in a secondmate home, or on any
# backend other than Herdr. They exit 1 with a message when a Herdr call fails;
# their callers treat that as a warning and continue.
# The worker panel stops when the task's record is removed or the task moves to
# a new pane; the panel pane then closes. The backend's task close also closes
# the panel when that close empties the task workspace.
#
# config/crew-panel: absent or `on` opens the panels automatically; `off` stops
# the automatic panels. Anything else warns and counts as off. The manual
# command works in both cases.
#
# Environment: FM_CREW_PANEL_RATIO is the Herdr split ratio (default 0.7, the
# share the existing pane keeps). FM_CREW_PANEL_NAME is the crew name in the
# fleet header (default: the home folder name).
#
# Exit codes: 0 printed or nothing to do; 1 a snapshot or Herdr call failed;
# 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RENDERER="$SCRIPT_DIR/fm-crew-panel.jq"
PANEL_LABEL=fm-crew-panel

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"  # FM_GATE_HUMAN_DECISION: the human-decision component
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"  # fm_root_is_secondmate_home
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"  # fm_nm_run: one bounded no-mistakes read

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die_usage() {
  printf 'fm-crew-panel: %s\n' "$1" >&2
  printf 'usage: fm-crew-panel.sh [--task <id>] [--watch] | open-fleet | open-task <id>\n' >&2
  exit 2
}

need_value() {  # <option> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 needs a value"
}

# crew_panel_mode <config-dir>: prints on or off. The parse matches
# config/step-display: absent is on; a file that cannot be read warns and is
# off; whitespace is ignored; empty or `on` is on, `off` is off; anything else
# warns and is off.
crew_panel_mode() {
  local file="$1/crew-panel" raw
  [ -e "$file" ] || { printf 'on\n'; return 0; }
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'fm-crew-panel: warning: %s is not a readable file; the automatic panels are off\n' "$file" >&2
    printf 'off\n'
    return 0
  fi
  raw=$(tr -d '[:space:]' < "$file")
  case "$raw" in
    ''|on) printf 'on\n' ;;
    off) printf 'off\n' ;;
    *)
      printf 'fm-crew-panel: warning: %s holds "%s", not on or off; the automatic panels are off\n' "$file" "$raw" >&2
      printf 'off\n'
      ;;
  esac
}

# --- automatic panels on Herdr -------------------------------------------------

# open_preflight: 0 when an automatic panel may open here, 1 (silently) when
# not. FM_BACKEND_HERDR_* helpers come from the Herdr backend.
open_preflight() {
  [ "$(crew_panel_mode "$CONFIG")" = on ] || return 1
  ! fm_root_is_secondmate_home "$FM_HOME" || return 1
  return 0
}

load_herdr() {
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  fm_backend_source herdr
}

# open_split <session> <pane> <panel-args...>: split <pane> to the right and run
# the panel there, unless the pane's tab already has a panel.
open_split() {
  local session=$1 pane=$2 info tab ws panes out new cmd arg
  shift 2
  info=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || {
    echo "fm-crew-panel: could not read herdr pane $pane" >&2
    return 1
  }
  tab=$(printf '%s' "$info" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  ws=$(printf '%s' "$info" | jq -r '.result.pane.workspace_id // empty' 2>/dev/null)
  [ -n "$tab" ] && [ -n "$ws" ] || {
    echo "fm-crew-panel: herdr pane $pane has no tab" >&2
    return 1
  }
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$ws" 2>/dev/null) || {
    echo "fm-crew-panel: could not list the panes of herdr tab $tab" >&2
    return 1
  }
  if printf '%s' "$panes" | jq -e --arg tab "$tab" --arg label "$PANEL_LABEL" \
    'any(.result.panes[]?; .tab_id == $tab and (.label // "") == $label)' >/dev/null 2>&1; then
    return 0
  fi
  out=$(fm_backend_herdr_cli "$session" pane split "$pane" --direction right \
    --ratio "${FM_CREW_PANEL_RATIO:-0.7}" --cwd "$FM_HOME" --no-focus 2>/dev/null) || {
    echo "fm-crew-panel: herdr could not split pane $pane" >&2
    return 1
  }
  new=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ -n "$new" ] || {
    echo "fm-crew-panel: herdr returned no pane id for the split" >&2
    return 1
  }
  fm_backend_herdr_cli "$session" pane rename "$new" "$PANEL_LABEL" >/dev/null 2>&1 || {
    fm_backend_herdr_cli "$session" pane close "$new" >/dev/null 2>&1 || true
    echo "fm-crew-panel: herdr could not label the panel pane" >&2
    return 1
  }
  cmd="exec env FM_HOME=$(printf '%q' "$FM_HOME") $(printf '%q' "$SCRIPT_DIR/fm-crew-panel.sh") --watch"
  for arg in "$@"; do cmd="$cmd $(printf '%q' "$arg")"; done
  fm_backend_herdr_cli "$session" pane run "$new" "$cmd" >/dev/null 2>&1 || {
    fm_backend_herdr_cli "$session" pane close "$new" >/dev/null 2>&1 || true
    echo "fm-crew-panel: herdr could not start the panel" >&2
    return 1
  }
  return 0
}

open_fleet() {
  open_preflight || return 0
  [ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  load_herdr
  # The innermost multiplexer wins, as for every other backend choice.
  [ "$(fm_backend_detect 2>/dev/null)" = herdr ] || return 0
  open_split "$HERDR_SESSION" "$HERDR_PANE_ID" --name "$(crew_name)"
}

meta_field() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

open_task() {  # <task-id>
  local id=$1 meta backend session pane
  open_preflight || return 0
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "fm-crew-panel: no record for task $id" >&2; return 1; }
  backend=$(meta_field "$meta" backend)
  [ "$backend" = herdr ] || return 0
  [ "$(meta_field "$meta" kind)" != secondmate ] || return 0
  session=$(meta_field "$meta" herdr_session)
  pane=$(meta_field "$meta" herdr_pane_id)
  [ -n "$session" ] && [ -n "$pane" ] || { echo "fm-crew-panel: task $id has no herdr pane" >&2; return 1; }
  load_herdr
  open_split "$session" "$pane" --task "$id" --name "$(crew_name)"
}

crew_name() {
  if [ -n "${FM_CREW_PANEL_NAME:-}" ]; then printf '%s\n' "$FM_CREW_PANEL_NAME"
  else basename -- "$FM_HOME"; fi
}

case "${1:-}" in
  open-fleet) [ $# -eq 1 ] || die_usage "open-fleet takes no arguments"; open_fleet; exit $? ;;
  open-task) [ $# -eq 2 ] || die_usage "open-task needs one task id"; open_task "$2"; exit $? ;;
esac

# --- render --------------------------------------------------------------------

TASK=
WATCH=0
INTERVAL=5
ROUNDS=0
SNAPSHOT_FILE=
WIDTH=
NAME=
COLOR=
NOW=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task) need_value "$1" $#; TASK=$2; shift 2 ;;
    --watch) WATCH=1; shift ;;
    --interval) need_value "$1" $#; INTERVAL=$2; shift 2 ;;
    --rounds) need_value "$1" $#; ROUNDS=$2; shift 2 ;;
    --snapshot) need_value "$1" $#; SNAPSHOT_FILE=$2; shift 2 ;;
    --width) need_value "$1" $#; WIDTH=$2; shift 2 ;;
    --name) need_value "$1" $#; NAME=$2; shift 2 ;;
    --now) need_value "$1" $#; NOW=$2; shift 2 ;;
    --color) COLOR=1; shift ;;
    --no-color) COLOR=0; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done
case "$INTERVAL" in ''|*[!0-9]*|0) die_usage "--interval must be a positive whole number of seconds" ;; esac
case "$ROUNDS" in ''|*[!0-9]*) die_usage "--rounds must be a whole number" ;; esac
case "$WIDTH" in ''|*[!0-9]*) [ -z "$WIDTH" ] || die_usage "--width must be a whole number" ;; esac
case "$NOW" in ''|*[!0-9]*) [ -z "$NOW" ] || die_usage "--now must be an epoch in seconds" ;; esac
[ -z "$SNAPSHOT_FILE" ] || [ -r "$SNAPSHOT_FILE" ] || die_usage "cannot read snapshot file: $SNAPSHOT_FILE"
[ -n "$NAME" ] || NAME=$(crew_name)
[ -n "$COLOR" ] || { if [ -t 1 ]; then COLOR=1; else COLOR=0; fi; }

panel_width() {
  local w=$WIDTH
  [ -n "$w" ] || w=${COLUMNS:-}
  case "$w" in ''|*[!0-9]*) w= ;; esac
  if [ -z "$w" ] && [ -t 1 ]; then w=$(tput cols 2>/dev/null || true); fi
  case "$w" in ''|*[!0-9]*) w=44 ;; esac
  [ "$w" -ge 20 ] || w=20
  printf '%s\n' "$w"
}

take_snapshot() {
  if [ -n "$SNAPSHOT_FILE" ]; then cat -- "$SNAPSHOT_FILE"
  else "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; fi
}

# status_events <status-file>: the status log as JSON events, newest last.
status_events() {
  local file=$1
  [ -r "$file" ] || { printf '[]\n'; return 0; }
  tail -n 200 -- "$file" | jq -R -s '
    [ split("\n")[] | select(length > 0)
      | capture("^(?<state>[a-z][a-z-]*)(?<tags>( +[^ :]+)*): (?<text>.*)$")?
      | . as $e
      | { state: $e.state,
          at: ([$e.tags | scan("\\[at=([0-9]+)\\]")[0]] | first | if . then tonumber else null end),
          key: ([$e.tags | scan("\\[key=([^]]+)\\]")[0]] | first),
          text: ($e.text | sub("^\\[key=[^]]*\\] "; "")) } ]
  ' 2>/dev/null || printf '[]\n'
}

# inbox_steers <inbox-dir>: firstmate messages to the worker, oldest first.
inbox_steers() {
  local dir=$1 f at body
  [ -d "$dir" ] || { printf '[]\n'; return 0; }
  for f in "$dir"/*.msg "$dir"/handled/*.msg; do
    [ -f "$f" ] || continue
    at=$(sed -n 's/^at=//p' "$f" | head -n 1)
    body=$(awk 'seen { print } /^--$/ { seen = 1 }' "$f")
    jq -n --arg at "$at" --arg text "$body" \
      '{at: (try ($at | fromdateiso8601) catch null), text: ($text | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; ""))}'
  done | jq -s 'sort_by(.at // 0)'
}

# task_extra <task-json>: the facts the snapshot does not carry, as one JSON object.
task_extra() {
  local task=$1 id kind status_path meta_path worktree source state report events steers review model vreport
  id=$(printf '%s' "$task" | jq -r '.id')
  kind=$(printf '%s' "$task" | jq -r '.kind // ""')
  status_path=$(printf '%s' "$task" | jq -r '.paths.status_log.path // empty')
  meta_path=$(printf '%s' "$task" | jq -r '.paths.meta.path // empty')
  worktree=$(printf '%s' "$task" | jq -r 'if .paths.worktree.present then .paths.worktree.path else empty end')
  source=$(printf '%s' "$task" | jq -r '.current_state.source // ""')
  state=$(printf '%s' "$task" | jq -r '.current_state.state // ""')
  report=$(printf '%s' "$task" | jq -r '.paths.report.path // empty')
  events=$(status_events "$status_path")
  steers='[]'
  [ -z "$status_path" ] || steers=$(inbox_steers "${status_path%.status}.inbox")
  review=
  if [ "$kind" = ship ] && [ "$source" = run-step ] && [ -n "$worktree" ] \
     && { [ -n "$TASK" ] || [ "$state" != "done" ]; }; then
    review=$(fm_nm_run "$worktree" 5 axi status 2>/dev/null) || review=
  fi
  model=
  [ -z "$meta_path" ] || model=$(sed -n 's/^model=//p' "$meta_path" 2>/dev/null | tail -n 1)
  vreport=false
  if [ -n "$report" ]; then
    [ ! -f "$(dirname -- "$(dirname -- "$report")")/$id-verify/report.md" ] || vreport=true
  fi
  jq -n --arg id "$id" --argjson events "$events" --argjson steers "$steers" \
    --arg review "$review" --arg model "$model" --argjson vreport "$vreport" \
    '{key: $id, value: {events: $events, steers: $steers,
      review: (if $review == "" then null else $review end),
      model: (if $model == "" then null else $model end), verify_report: $vreport}}'
}

render_once() {
  local snapshot extra now width task
  snapshot=$(take_snapshot) || return 1
  printf '%s' "$snapshot" | jq -e 'type == "object"' >/dev/null 2>&1 || {
    echo "fm-crew-panel: the fleet snapshot is not readable JSON" >&2
    return 1
  }
  extra=$(printf '%s' "$snapshot" | jq -c '.tasks[]? | select(.kind != "secondmate")' | while IFS= read -r task; do
    [ -z "$TASK" ] || printf '%s' "$task" | jq -e --arg id "$TASK" '.id == $id or .id == $id + "-verify"' >/dev/null || continue
    task_extra "$task"
  done | jq -s 'from_entries')
  now=${NOW:-$(date +%s)}
  width=$(panel_width)
  { printf '%s\n' "$snapshot"; printf '%s\n' "$extra"; } | jq -s '{snap: .[0], extra: .[1]}' |
    jq -r --argjson W "$width" --argjson now "$now" --arg name "$NAME" --arg color "$COLOR" \
      --arg task "$TASK" --arg human "$FM_GATE_HUMAN_DECISION" -f "$RENDERER"
}

[ "$WATCH" -eq 1 ] || { render_once; exit $?; }

# A worker panel stops when its task's record is removed or when the task moves
# to a new pane (a restart), so the panel pane closes and leaves no empty tab.
start_pane=
[ -z "$TASK" ] || [ -n "$SNAPSHOT_FILE" ] || start_pane=$(meta_field "$STATE/$TASK.meta" herdr_pane_id)
round=0
while :; do
  round=$((round + 1))
  frame=$(render_once 2>&1)
  if [ -t 1 ]; then printf '\033[H\033[2J'; fi
  printf '%s\n' "$frame"
  [ "$ROUNDS" -eq 0 ] || [ "$round" -lt "$ROUNDS" ] || exit 0
  if [ -n "$TASK" ] && [ -z "$SNAPSHOT_FILE" ]; then
    [ -e "$STATE/$TASK.meta" ] || exit 0
    [ -z "$start_pane" ] || [ "$(meta_field "$STATE/$TASK.meta" herdr_pane_id)" = "$start_pane" ] || exit 0
  fi
  sleep "$INTERVAL"
done

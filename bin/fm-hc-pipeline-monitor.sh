#!/usr/bin/env bash
# bin/fm-hc-pipeline-monitor.sh - the read-only no-mistakes pipeline monitor
# terminal for an hc-backed task, shown beside the worker's tab in Herdr desktop.
#
# Usage:
#   fm-hc-pipeline-monitor.sh observe <task-id>  # idempotent; the watcher calls it each poll
#   fm-hc-pipeline-monitor.sh close <task-id>    # fm-teardown.sh calls it before the worker close
#
# observe is opt-in: it opens nothing unless config/hc-pipeline-monitor exists.
# observe reads the task's active no-mistakes run in its worktree. For the first
# active run it opens exactly one monitor terminal running
# `no-mistakes attach --run <run-id>`. When a newer run id appears it replaces the
# earlier monitor rather than adding a second one. Re-observing the same run changes
# nothing. Only backend=hc tasks are handled; other backends exit 0 untouched.
#
# Safety contract (AGENTS.md section 1; the brief's Herdr isolation rules):
#   - The monitor carries firstmate.monitor=fm-<task> and firstmate.home=<hometag>
#     and never firstmate.task, so it can never look like a worker endpoint.
#   - Input is never sent to the monitor: it is a view, and the worker answers the pipeline.
#   - close and replace kill only terminals whose labels name this task and this home.
#     Any other terminal is left alone, including the captain's.
#   - Ambiguous or unreadable state is refused with a message, never guessed past.
#
# Run attribution comes from bin/fm-nm-run-lib.sh (fm_nm_run_checked, fm_nm_field,
# fm_nm_run_is_active) over `no-mistakes axi status` in the task worktree.
# The hc primitives come from bin/backends/hc.sh. Environment: FM_HOME, and
# FM_STATE_OVERRIDE (defaults to $FM_HOME/state), as in the other bin scripts.

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
FM_BACKEND_LIB_DIR=$SCRIPT_DIR
export FM_ROOT FM_HOME FM_BACKEND_LIB_DIR

# shellcheck source=bin/backends/hc.sh
. "$SCRIPT_DIR/backends/hc.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  echo "usage: fm-hc-pipeline-monitor.sh observe|close <task-id>" >&2
  exit 2
}

# meta_value <meta-file> <key>: the last value of key=value in a task meta record.
meta_value() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

monitor_label() { printf 'fm-%s' "$1"; }

# monitor_tab <task>: the monitor's own tab, grouped beside the worker's tab.
monitor_tab() { printf '%s pipeline monitor' "$(fm_backend_hc_scoped_label "$1")"; }

# monitor_terminal_owned <session> <address> <task> <home>: 0 when the terminal's
# labels name exactly this task's monitor in this home and it carries no worker label.
monitor_terminal_owned() {
  local session=$1 address=$2 task=$3 home=$4 fields
  fields=$(fm_backend_hc_cli "$session" get --json "$address" 2>/dev/null \
    | jq -r '[.labels["firstmate.monitor"] // "", .labels["firstmate.home"] // "", (.labels["firstmate.task"] // "")] | @tsv' 2>/dev/null) || return 1
  [ "$fields" = "$(printf '%s\t%s\t' "$(monitor_label "$task")" "$home")" ]
}

# monitor_list <session> <task> <home>: addresses of this task's monitor terminals.
monitor_list() {
  fm_backend_hc_cli "$1" ls --json --label "firstmate.monitor=$(monitor_label "$2")" --label "firstmate.home=$3" 2>/dev/null \
    | jq -r '.terminals[]?.address // empty' 2>/dev/null
}

# monitor_close_all <session> <task> <home>: close every owned monitor terminal.
# Returns non-zero when a listed terminal is not provably owned or cannot be closed.
monitor_close_all() {
  local session=$1 task=$2 home=$3 address failed=0
  while IFS= read -r address; do
    [ -n "$address" ] || continue
    fm_backend_hc_address_valid "$address" || { failed=1; continue; }
    if ! monitor_terminal_owned "$session" "$address" "$task" "$home"; then
      echo "error: pipeline monitor $address does not carry this task's monitor labels; leaving it open" >&2
      failed=1
      continue
    fi
    fm_backend_hc_cli "$session" kill --json "$address" >/dev/null 2>&1 || true
    fm_backend_hc_cli "$session" rm --json "$address" >/dev/null 2>&1 || true
  done <<EOF
$(monitor_list "$session" "$task" "$home")
EOF
  [ "$failed" -eq 0 ]
}

# active_run_id <worktree>: prints the active run id, or nothing when no run is
# active. A failed or unreadable status read prints nothing.
active_run_id() {
  local wt=$1 out run_id
  out=$(fm_nm_run_checked "$wt" 5 axi status) || return 0
  fm_nm_run_is_active "$out" || return 0
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  case "$run_id" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  printf '%s' "$run_id"
}

cmd_observe() {
  local task=$1 meta session wt run_id home record recorded addr live out
  # Opt-in: with config/hc-pipeline-monitor absent, observe opens nothing. close still runs.
  [ -e "$CONFIG/hc-pipeline-monitor" ] || return 0
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || return 0
  [ "$(meta_value "$meta" backend)" = hc ] || return 0
  session=$(meta_value "$meta" hc_session)
  wt=$(meta_value "$meta" worktree)
  fm_backend_hc_atom_valid "$session" || { echo "error: $task has no valid hc session; pipeline monitor not opened" >&2; return 1; }
  [ -d "$wt" ] || return 0
  run_id=$(active_run_id "$wt")
  [ -n "$run_id" ] || return 0

  home=$(fm_backend_hometag)
  record="$STATE/.hc-monitor-$task"
  recorded=$(cat "$record" 2>/dev/null || true)
  if [ "${recorded%%$'\t'*}" = "$run_id" ]; then
    addr=${recorded#*$'\t'}
    if fm_backend_hc_address_valid "$addr" && monitor_terminal_owned "$session" "$addr" "$task" "$home"; then
      return 0
    fi
  fi

  # A new run, or a monitor that vanished: close any owned monitor first so exactly one remains.
  monitor_close_all "$session" "$task" "$home" || { echo "error: could not clear the old pipeline monitor for $task; not opening a second one" >&2; return 1; }
  out=$(fm_backend_hc_cli "$session" run --bg --json --no-parent --outlive-parent --no-notify \
    --cwd "$wt" \
    --label "herdr.space=${FM_HC_SPACE:-fm-$home}" --label "herdr.tab=$(monitor_tab "$task")" \
    --label "firstmate.monitor=$(monitor_label "$task")" --label "firstmate.home=$home" \
    -- no-mistakes attach --run "$run_id" 2>&1) \
    || { echo "error: could not open the pipeline monitor for $task: $out" >&2; return 1; }
  live=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)
  fm_backend_hc_address_valid "$live" || { echo "error: hc run did not return a monitor address for $task (got: $out)" >&2; return 1; }
  printf '%s\t%s\n' "$run_id" "$live" > "$record.tmp" && mv -f "$record.tmp" "$record"
}

cmd_close() {
  local task=$1 meta session home record
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || return 0
  [ "$(meta_value "$meta" backend)" = hc ] || return 0
  session=$(meta_value "$meta" hc_session)
  fm_backend_hc_atom_valid "$session" || { echo "error: $task has no valid hc session; pipeline monitor not closed" >&2; return 1; }
  home=$(fm_backend_hometag)
  monitor_close_all "$session" "$task" "$home" || return 1
  record="$STATE/.hc-monitor-$task"
  rm -f "$record"
}

[ "$#" -eq 2 ] || usage
case "$2" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
case "$1" in
  observe) cmd_observe "$2" ;;
  close) cmd_close "$2" ;;
  *) usage ;;
esac

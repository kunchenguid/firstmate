# shellcheck shell=bash
# Source-only helper for fm-browser.sh integration points.
# The public lifecycle, state fields, receipt schema, command surface, and
# refusal semantics are owned by bin/fm-browser.sh and its --help output.
# Source this file from scripts that only need to inspect whether a task has an
# unclean browser binding before performing task cleanup or fleet summaries.

fm_browser_state_dir() {
  local home=${1:-${FM_HOME:-}}
  [ -n "$home" ] || return 1
  printf '%s\n' "${FM_STATE_OVERRIDE:-$home/state}/browser/v1"
}

fm_browser_binding_file() {
  local home=$1 task=$2 state
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  state=$(fm_browser_state_dir "$home") || return 1
  printf '%s\n' "$state/task-bindings/$task.json"
}

fm_browser_task_cleaned() {
  local home=$1 task=$2 binding
  binding=$(fm_browser_binding_file "$home" "$task") || return 1
  [ -f "$binding" ] || return 0
  python3 - "$binding" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    obj = json.load(fh)
raise SystemExit(0 if obj.get('cleaned') is True or obj.get('state') == 'cleaned' else 1)
PY
}

fm_browser_refuse_unclean_task() {
  local home=$1 task=$2 binding message
  binding=$(fm_browser_binding_file "$home" "$task") || return 0
  [ -f "$binding" ] || return 0
  message=$(python3 - "$binding" "$task" <<'PY'
import json, sys
binding, task = sys.argv[1], sys.argv[2]
try:
    with open(binding, encoding='utf-8') as fh:
        obj = json.load(fh)
except Exception:
    state, handle = 'unreadable', 'unknown'
else:
    if obj.get('cleaned') is True or obj.get('state') == 'cleaned':
        raise SystemExit(0)
    state = obj.get('state', 'unknown')
    handle = obj.get('handle', 'unknown')
print(
    f'error: task {task} has an unclean browser binding {binding} (state: {state}); '
    f'run bin/fm-browser.sh close --handle {handle} or inspect the browser record before cleanup'
)
raise SystemExit(1)
PY
  ) && return 0
  [ -n "$message" ] || message="error: task $task has an unclean browser binding $binding (state: unknown); run bin/fm-browser.sh close --handle unknown or inspect the browser record before cleanup"
  printf '%s\n' "$message" >&2
  return 1
}

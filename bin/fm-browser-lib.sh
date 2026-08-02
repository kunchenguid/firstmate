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
  local home=$1 task=$2 binding state handle
  binding=$(fm_browser_binding_file "$home" "$task") || return 0
  [ -f "$binding" ] || return 0
  if fm_browser_task_cleaned "$home" "$task"; then
    return 0
  fi
  state=$(python3 - "$binding" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    obj = json.load(fh)
print(obj.get('state', 'unknown'))
PY
)
  handle=$(python3 - "$binding" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    obj = json.load(fh)
print(obj.get('handle', 'unknown'))
PY
)
  printf 'error: task %s has an unclean browser binding %s (state: %s); run bin/fm-browser.sh close --handle %s or inspect the browser record before cleanup\n' "$task" "$binding" "$state" "$handle" >&2
  return 1
}

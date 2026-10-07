# shellcheck shell=bash
fm_ready_queue_needs_review() (
  local script_dir data backend ready count
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$script_dir/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$script_dir/fm-timeout-lib.sh"
  data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  backend=$(fm_tasks_axi_backend "${data%/*}" 2>/dev/null) || return 0
  if [ "$backend" = markdown ] && [ ! -e "$data/backlog.md" ] && [ ! -L "$data/backlog.md" ]; then
    return 1
  fi
  ready=$(fm_run_timed 10 env FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$data" \
    "$script_dir/fm-tasks-axi.sh" ready 2>/dev/null) || return 0
  count=$(printf '%s\n' "$ready" | awk '/^count: [0-9]+$/ { print $2; exit }')
  [ "$count" != 0 ]
)


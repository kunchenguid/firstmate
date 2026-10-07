# shellcheck shell=bash
fm_ready_queue_needs_review() (
  local script_dir data root backend ready count
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$script_dir/fm-tasks-axi-lib.sh"
  # shellcheck source=/dev/null # Linted separately; its globals stay in this subshell.
  . "$script_dir/fm-backlog-transition-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$script_dir/fm-timeout-lib.sh"
  data=$(fm_backlog_data_absolute "${FM_DATA_OVERRIDE:-$FM_HOME/data}" 2>/dev/null) || return 0
  root=$(fm_backlog_root "$data" 2>/dev/null) || return 0
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 0
  if [ "$backend" = markdown ] && [ ! -e "$data/backlog.md" ] && [ ! -L "$data/backlog.md" ]; then
    return 1
  fi
  ready=$(fm_run_timed 10 env FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$data" \
    "$script_dir/fm-tasks-axi.sh" ready 2>/dev/null) || return 0
  count=$(printf '%s\n' "$ready" | awk '/^count: [0-9]+$/ { print $2; exit }')
  [ "$count" != 0 ]
)

# shellcheck shell=bash
# fm-ready-queue-lib.sh - the single owner of firstmate's backlog readiness
# verdict, shared by the watcher's heartbeat triage and the away-mode daemon's
# classification so the two cannot disagree about whether queued work is ready.
#
#   fm_ready_queue_needs_review
#       Returns 0 when the queue holds ready units OR readiness could not be
#       determined, and 1 only for a readable backlog that is empty: a markdown
#       home with no backlog file, or a ready count of zero. Every probe
#       failure returns 0 deliberately: unreadable readiness must escalate as a
#       review, never be absorbed as an empty queue. Runs in a subshell so its
#       sourced globals never reach the caller.
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

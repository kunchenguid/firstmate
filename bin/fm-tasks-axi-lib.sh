# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
#
# Hidden backlog category (captain triage: do / defer / backlog / kill):
# A structured hold whose reason starts with "backlog:" is render-hidden from
# every routine status surface until revived (unhold) or listed explicitly.
# This lib owns the predicate and the human hint text; listing surfaces call it
# rather than re-stating the prefix. Explicit listing is bin/fm-backlog-list.sh
# --backlog (see that script's header). Deferred (hold-until / future) and
# parked (hold-kind parked without the backlog: reason prefix) stay visible.

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

# True when a hold reason is the hidden backlog triage category.
# Match is prefix-only and case-sensitive: "backlog: cold storage" matches;
# "Backlog: ..." or "deferred backlog later" do not.
fm_hold_reason_is_backlogged() {
  case "${1:-}" in
    backlog:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when a markdown task title line carries (hold: backlog: ...).
fm_backlog_title_line_is_backlogged() {
  printf '%s\n' "${1:-}" | grep -E '\(hold:[[:space:]]*backlog:' >/dev/null
}

# Print the one-line routine-surface hint, or nothing when count is zero.
# Callers pass the explicit list invocation operators should run (default is
# the firstmate backlog status view).
fm_backlog_hidden_hint() {
  local count=${1:-0}
  local how=${2:-'bin/fm-backlog-list.sh --backlog'}
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac
  printf '%d backlogged hidden - use %s to list\n' "$count" "$how"
}

# List structured task ids in a backlog markdown file whose hold reason starts
# with "backlog:". One id per line, in file order. Free-form lines are ignored.
fm_backlogged_ids_from_file() {
  local path=$1
  [ -f "$path" ] || return 0
  awk '
    function is_task_title(line) {
      return line ~ /^[-*][[:space:]]+(\[[ xX]\][[:space:]]+)?[^[:space:]]+[[:space:]]+-[[:space:]]+/ \
        || line ~ /^[-*][[:space:]]+\*\*[^*]+\*\*[[:space:]]+-[[:space:]]+/
    }
    function task_id(line,   rest, id) {
      rest = line
      sub(/^[-*][[:space:]]+/, "", rest)
      if (rest ~ /^\[[ xX]\][[:space:]]+/) sub(/^\[[ xX]\][[:space:]]+/, "", rest)
      if (rest ~ /^\*\*[^*]+\*\*/) {
        sub(/^\*\*/, "", rest)
        sub(/\*\*.*/, "", rest)
        id = rest
      } else {
        id = rest
        sub(/[[:space:]].*/, "", id)
      }
      return id
    }
    is_task_title($0) && /\(hold:[[:space:]]*backlog:/ {
      id = task_id($0)
      if (id != "") print id
    }
  ' "$path"
}

# Count structured backlogged title lines in a backlog markdown file.
fm_backlogged_count_from_file() {
  local path=$1
  local n
  n=$(fm_backlogged_ids_from_file "$path" | awk 'END { print NR+0 }')
  printf '%s\n' "${n:-0}"
}

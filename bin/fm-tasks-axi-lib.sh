# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap and
# teardown.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer and
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites.
# `config/backlog-backend=manual` opts out of tasks-axi backlog mutations;
# absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.

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
    fm_tasks_axi_update_has_archive_body
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

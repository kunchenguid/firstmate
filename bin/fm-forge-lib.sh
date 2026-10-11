#!/usr/bin/env bash
# Task-scoped paths for PR/issue body text and refusal of fixed shared /tmp names.
# bin/fm-spawn.sh creates /tmp/fm-<task-id>/ at launch (tasktmp= metadata); this
# file owns the path formula and collision rules for gh --body-file consumers.

# Print the per-task temp root (same path bin/fm-spawn.sh uses).
fm_task_tmp_root() {  # <task-id>
  printf '/tmp/fm-%s' "$1"
}

# Print the task-unique body file path workers should use with gh --body-file.
fm_forge_body_file() {  # <task-id>
  printf '%s/pr-description.md' "$(fm_task_tmp_root "$1")"
}

# 0 when <path> is a fixed shared filename that must not carry forge body text.
fm_forge_body_file_is_shared_collision() {  # <path>
  local path=$1 dir base
  [ -n "$path" ] || return 1
  dir=$(dirname -- "$path")
  base=$(basename -- "$path")
  [ "$dir" = /tmp ] || return 1
  case "$base" in
    pr-body|pr-body.md|issue-body|issue-body.md) return 0 ;;
  esac
  return 1
}

# Refuse unsafe --body-file paths; print a reason to stderr and return 1.
fm_forge_body_file_refuse() {  # <path>
  local path=$1
  if fm_forge_body_file_is_shared_collision "$path"; then
    echo "error: forge body file '$path' is a fixed shared /tmp name; use --body inline, $(fm_forge_body_file '<task-id>'), or another path under /tmp/fm-<task-id>/" >&2
    return 1
  fi
  return 0
}

#!/usr/bin/env bash
# Read and account for the local startup-memory budget.
# Usage:
#   fm-startup-memory-budget.sh read
#   fm-startup-memory-budget.sh report
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` labels that three-file budget scope
# and also prints sizes for the other bounded session-start digest components.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,11{s/^# \{0,1\}//;p;}' "$0"
}

print_error() {
  printf 'startup-memory-budget: %s\n' "$1" >&2
}

read_budget() {
  if ! fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
    print_error "invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  printf '%s\n' "$FM_STARTUP_MEMORY_BUDGET_VALUE"
}

report() {
  local budget bytes tokens presence total=0 shared_tokens=0 role=primary file
  local backlog_limit status_tail backlog_rows=0 meta_files=0 meta_bytes=0
  local status_files=0 status_bytes=0 component_tokens
  if ! budget=$(read_budget); then
    return 2
  fi

  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    role=secondmate
  fi

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'effective_budget_tokens=%s\n' "$budget"
  printf 'budget_scope=memory-files-only\n'
  for file in captain.md captain-shared.md learnings.md; do
    if ! fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    bytes=$FM_STARTUP_MEMORY_MEASURE_BYTES
    tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    presence=$FM_STARTUP_MEMORY_MEASURE_PRESENCE
    total=$((total + tokens))
    [ "$file" != captain-shared.md ] || shared_tokens=$tokens
    printf 'file=data/%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$bytes" "$tokens" "$presence"
  done
  printf 'total_estimated_tokens=%s\n' "$total"
  if fm_startup_memory_decimal_le "$total" "$budget"; then
    printf 'budget_status=within-budget\n'
  else
    printf 'budget_status=over-budget\n'
  fi
  if [ "$role" = secondmate ] \
    && ! fm_startup_memory_decimal_le "$shared_tokens" "$budget"; then
    printf 'exception=primary-owned-shared-file-alone-exceeds-budget\n'
  fi

  for file in projects.md secondmates.md; do
    if ! fm_startup_memory_measure_file "$DATA/$file" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    printf 'digest_file=data/%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$file" "$FM_STARTUP_MEMORY_MEASURE_BYTES" \
      "$FM_STARTUP_MEMORY_MEASURE_TOKENS" "$FM_STARTUP_MEMORY_MEASURE_PRESENCE"
  done

  backlog_limit=${FM_SESSION_START_BACKLOG_LIMIT:-80}
  case "$backlog_limit" in ''|*[!0-9]*|0) backlog_limit=80 ;; esac
  if [ -f "$DATA/backlog.md" ]; then
    backlog_rows=$(awk -v max="$backlog_limit" '
      /^[-*][[:space:]]+/ && rows < max { rows++ }
      END { print rows + 0 }
    ' "$DATA/backlog.md")
  fi
  printf 'digest_backlog_rows=%s limit=%s\n' "$backlog_rows" "$backlog_limit"

  for file in "$STATE"/*.meta; do
    [ -f "$file" ] || continue
    meta_files=$((meta_files + 1))
    bytes=$(wc -c < "$file" | tr -d '[:space:]')
    meta_bytes=$((meta_bytes + bytes))
  done
  component_tokens=$(((meta_bytes + 2) / 3))
  printf 'digest_meta_files=%s bytes=%s estimated_tokens=%s\n' \
    "$meta_files" "$meta_bytes" "$component_tokens"

  # Mirrors fm-session-start.sh's STATUS_TAIL default so this line measures
  # what the digest actually projects: 0 tail lines unless the knob is set.
  status_tail=${FM_SESSION_START_STATUS_TAIL:-0}
  case "$status_tail" in ''|*[!0-9]*) status_tail=0 ;; esac
  for file in "$STATE"/*.status; do
    [ -f "$file" ] || continue
    status_files=$((status_files + 1))
    bytes=$(tail -n "$status_tail" "$file" | wc -c | tr -d '[:space:]')
    status_bytes=$((status_bytes + bytes))
  done
  component_tokens=$(((status_bytes + 2) / 3))
  printf 'digest_status_tail_files=%s lines_per_file=%s bytes=%s estimated_tokens=%s\n' \
    "$status_files" "$status_tail" "$status_bytes" "$component_tokens"
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

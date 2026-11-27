#!/usr/bin/env bash
# Read and account for the local startup-memory budget.
# Usage:
#   fm-startup-memory-budget.sh read
#   fm-startup-memory-budget.sh report [--claude-index <absolute-memory-index>]
#
# `read` prints the one validated effective budget from
# config/startup-memory-budget.  `report` prints the stable local estimate for
# data/captain.md, data/captain-shared.md, and data/learnings.md together.
# A stow pass may include its active Claude account's project memory/MEMORY.md
# as a fourth file; the caller supplies that exact path, never a directory to
# scan. An absent index counts as zero; no report writes any memory file.
# Bootstrap owns default materialization; this command never creates or repairs
# configuration, so an absent, malformed, symlinked, hardlinked, or otherwise
# unsafe value is a concrete error rather than an inferred default.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "$0"
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
  local claude_index=${1:-} budget file label path tokens total=0 shared_tokens=0 role=primary
  local -a files=(captain.md captain-shared.md learnings.md)
  if [ -n "$claude_index" ]; then
    files+=(claude-index)
  fi
  if ! budget=$(read_budget); then
    return 2
  fi

  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    role=secondmate
  fi

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'effective_budget_tokens=%s\n' "$budget"
  for file in "${files[@]}"; do
    if [ "$file" = claude-index ]; then
      label=claude-auto-memory/MEMORY.md
      path=$claude_index
    else
      label=data/$file
      path=$DATA/$file
    fi
    if ! fm_startup_memory_measure_file "$path" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    total=$((total + tokens))
    [ "$file" != captain-shared.md ] || shared_tokens=$tokens
    printf 'file=%s bytes=%s estimated_tokens=%s status=%s\n' \
      "$label" "$FM_STARTUP_MEMORY_MEASURE_BYTES" "$tokens" "$FM_STARTUP_MEMORY_MEASURE_PRESENCE"
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
}

case "${1:-}" in
  read)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    read_budget
    ;;
  report)
    if [ "$#" -eq 1 ]; then
      report
    elif [ "$#" -eq 3 ] && [ "$2" = --claude-index ] && [[ "$3" = /*/memory/MEMORY.md ]]; then
      report "$3"
    else
      usage >&2
      exit 2
    fi
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

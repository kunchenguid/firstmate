#!/usr/bin/env bash
# Read and account for the local startup-memory budgets.
# Usage:
#   fm-startup-memory-budget.sh read
#   fm-startup-memory-budget.sh report
#   fm-startup-memory-budget.sh check
#
# Two independent classes are accounted for, so one cannot silently eat the
# other's room:
#   startup-always-loaded  data/captain.md, data/captain-shared.md, and the
#                          learnings INDEX - what every turn of every session
#                          pays for. Bounded by config/startup-memory-budget.
#   learning-topic         each data/learnings/<topic>.md, read only when its
#                          trigger matches. Each is bounded on its own by
#                          config/learning-topic-budget.
#
# `read` prints the validated startup budget. `report` prints the estimate for
# both classes and always exits 0. `check` prints the same report and exits 1
# when any class is over budget, so tooling detects real growth instead of only
# validating that a config value parses.
# Bootstrap owns startup-budget materialization; this command never creates or
# repairs configuration, so an absent, malformed, symlinked, hardlinked, or
# otherwise unsafe startup value is a concrete error rather than an inferred
# default. The optional per-topic override defaults to the tracked constant.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  sed -n '2,23{s/^# \{0,1\}//;p;}' "$0"
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

# The always-loaded startup set. The learnings INDEX is startup input; topic
# files under data/learnings/ are not, and are bounded separately. A home that
# has not been topic-split yet still measures its flat learnings.md here, so it
# is never silently unaccounted for.
startup_learnings_relpath() {
  if [ -f "$DATA/learnings/index.md" ]; then
    printf 'learnings/index.md\n'
  elif [ -f "$DATA/learnings.md" ]; then
    printf 'learnings.md\n'
  else
    printf 'learnings/index.md\n'
  fi
}

OVER_BUDGET=0

report() {
  local budget topic_budget bytes tokens presence total=0 shared_tokens=0 role=primary
  local learnings topic name count=0
  if ! budget=$(read_budget); then
    return 2
  fi
  if ! topic_budget=$(fm_learning_topic_budget_read "$CONFIG"); then
    print_error "invalid config/$FM_LEARNING_TOPIC_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 2
  fi

  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    role=secondmate
  fi
  learnings=$(startup_learnings_relpath)

  printf 'estimator=ceil(UTF-8 bytes / 3) conservative-local-estimate\n'
  printf 'role=%s\n' "$role"
  printf 'class=startup-always-loaded\n'
  printf 'effective_budget_tokens=%s\n' "$budget"
  for file in captain.md captain-shared.md "$learnings"; do
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
    OVER_BUDGET=1
  fi
  if [ "$role" = secondmate ] \
    && ! fm_startup_memory_decimal_le "$shared_tokens" "$budget"; then
    printf 'exception=primary-owned-shared-file-alone-exceeds-budget\n'
  fi

  printf 'class=learning-topic\n'
  printf 'topic_budget_tokens=%s\n' "$topic_budget"
  for topic in "$DATA"/learnings/*.md; do
    [ -f "$topic" ] || continue
    name=$(basename "$topic")
    [ "$name" != index.md ] || continue
    count=$((count + 1))
    if ! fm_startup_memory_measure_file "$topic" >/dev/null; then
      print_error "$FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 2
    fi
    bytes=$FM_STARTUP_MEMORY_MEASURE_BYTES
    tokens=$FM_STARTUP_MEMORY_MEASURE_TOKENS
    if fm_startup_memory_decimal_le "$tokens" "$topic_budget"; then
      printf 'topic=data/learnings/%s bytes=%s estimated_tokens=%s status=within-budget\n' \
        "$name" "$bytes" "$tokens"
    else
      printf 'topic=data/learnings/%s bytes=%s estimated_tokens=%s status=over-budget\n' \
        "$name" "$bytes" "$tokens"
      OVER_BUDGET=1
    fi
  done
  printf 'topic_files=%s\n' "$count"
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
  check)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    report || exit $?
    if [ "$OVER_BUDGET" -ne 0 ]; then
      printf '\n' >&2
      printf 'startup-memory-budget: FAIL - always-loaded startup memory or a topic\n' >&2
      printf 'learning file is over budget. Every session of this home pays the startup\n' >&2
      printf 'class on every turn. Prune or topic-split the offending file (the stow\n' >&2
      printf 'skill owns curation), or raise the budget deliberately in\n' >&2
      printf 'config/%s or config/%s.\n' \
        "$FM_STARTUP_MEMORY_BUDGET_FILE" "$FM_LEARNING_TOPIC_BUDGET_FILE" >&2
      exit 1
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

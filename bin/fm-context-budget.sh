#!/usr/bin/env bash
# Enforce the size budget for firstmate's ALWAYS-LOADED agent instructions.
# Usage:
#   fm-context-budget.sh            report the measurement, exit non-zero when over
#   fm-context-budget.sh report     print the measurement only, always exit 0
#   fm-context-budget.sh check      same as the default
#   fm-context-budget.sh budget     print the effective budget in estimated tokens
#
# The measured surface is exactly what every session of every fleet member pays
# for on every turn: CLAUDE.md (the @AGENTS.md pointer harnesses read) plus
# AGENTS.md itself.  Skills under .agents/skills/ are deliberately NOT counted -
# their cost is paid only by the sessions that load them, which is the whole
# point of routing situational procedure there.
#
# The token estimate reuses bin/fm-startup-memory-budget-lib.sh's ceil(bytes/3)
# so this repo keeps ONE token-estimation formula.  That estimate is
# deliberately conservative for ordinary prose and claims no provider exactness.
#
# Raising FM_CONTEXT_BUDGET_TOKENS is a deliberate act: AGENTS.md's "Maintaining
# this file" section and .agents/skills/firstmate-coding-guidelines/SKILL.md own
# the placement decision tree that should be applied BEFORE the budget is raised.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

# Budget in estimated tokens, in the ceil(bytes/3) units above.
# Set with headroom over the measured surface so ordinary safety-rule edits fit,
# but not so much that a whole procedure can be pasted back inline unnoticed.
FM_CONTEXT_BUDGET_TOKENS="${FM_CONTEXT_BUDGET_TOKENS:-5000}"

# Files loaded into every turn's context, relative to the tracked code root.
FM_CONTEXT_FILES="CLAUDE.md AGENTS.md"

usage() {
  sed -n '2,9{s/^# \{0,1\}//;p;}' "$0"
}

fail() {
  printf 'context-budget: %s\n' "$1" >&2
  exit 2
}

measure() {
  local total_bytes=0 total_tokens=0 rel path bytes tokens
  MEASURE_ROWS=""
  for rel in $FM_CONTEXT_FILES; do
    path="$FM_ROOT/$rel"
    [ -f "$path" ] || fail "always-loaded file is missing: $rel"
    bytes=$(wc -c <"$path" | tr -d ' ')
    tokens=$(fm_startup_memory_estimated_tokens_for_bytes "$bytes") ||
      fail "could not estimate tokens for: $rel"
    MEASURE_ROWS="${MEASURE_ROWS}${rel} ${bytes} ${tokens}"$'\n'
    total_bytes=$((total_bytes + bytes))
    total_tokens=$((total_tokens + tokens))
  done
  MEASURE_BYTES=$total_bytes
  MEASURE_TOKENS=$total_tokens
}

print_report() {
  local rel bytes tokens
  printf 'Always-loaded agent instructions (paid by every turn of every session)\n'
  while read -r rel bytes tokens; do
    [ -n "$rel" ] || continue
    printf '  %-12s %7s bytes  ~%6s est. tokens\n' "$rel" "$bytes" "$tokens"
  done <<EOF
$MEASURE_ROWS
EOF
  printf '  %-12s %7s bytes  ~%6s est. tokens\n' "TOTAL" "$MEASURE_BYTES" "$MEASURE_TOKENS"
  printf '  budget       %22s est. tokens\n' "$FM_CONTEXT_BUDGET_TOKENS"
}

case "${1:-check}" in
  -h|--help|help)
    usage
    ;;
  budget)
    printf '%s\n' "$FM_CONTEXT_BUDGET_TOKENS"
    ;;
  report)
    measure
    print_report
    ;;
  check)
    case "$FM_CONTEXT_BUDGET_TOKENS" in
      ''|*[!0-9]*) fail "FM_CONTEXT_BUDGET_TOKENS must be a positive integer: $FM_CONTEXT_BUDGET_TOKENS" ;;
    esac
    measure
    print_report
    if [ "$MEASURE_TOKENS" -gt "$FM_CONTEXT_BUDGET_TOKENS" ]; then
      printf '\n'
      printf 'context-budget: FAIL - always-loaded instructions are %s est. tokens over budget.\n' \
        "$((MEASURE_TOKENS - FM_CONTEXT_BUDGET_TOKENS))" >&2
      printf 'AGENTS.md is loaded in full on every turn of every session of every fleet\n' >&2
      printf 'member. Move situational procedure into a skill under .agents/skills/ and\n' >&2
      printf 'leave only its load trigger inline; see the knowledge-placement decision\n' >&2
      printf 'tree in .agents/skills/firstmate-coding-guidelines/SKILL.md. Raise the\n' >&2
      printf 'budget in bin/fm-context-budget.sh only with a stated reason.\n' >&2
      exit 1
    fi
    printf '\ncontext-budget: OK - %s est. tokens within the %s budget.\n' \
      "$MEASURE_TOKENS" "$FM_CONTEXT_BUDGET_TOKENS"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

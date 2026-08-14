#!/usr/bin/env bash
# Shared CI-ready scoring for a set of check conclusions.
#
# ONE owner of the rule that a green verdict is valid only when at least one
# check completed with success AND none are pending, failed, cancelled,
# skipped, or never-run. Zero checks is a distinct non-success state, never
# passed. Used by current-state reporting so a cancelled-only or empty check
# set cannot be read as checks-passed.
#
# Public interface: fm_ci_ready_verdict [conclusion...]
#   Reads conclusions from the arguments, or from stdin (one per line) when
#   none are given. Blank lines are ignored.
#   Prints exactly one of: passed | empty | not-passed
# Sourced by callers; also runnable as a command so tests drive the same
# public function through an executable interface.

fm_ci_verdict_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# 0 if $1 is a completed success conclusion.
fm_ci_verdict_is_success() {
  case "$1" in
    SUCCESS|success) return 0 ;;
    *) return 1 ;;
  esac
}

fm_ci_ready_verdict() {
  local raw conclusion saw_success=0
  if [ "$#" -gt 0 ]; then
    for raw in "$@"; do
      conclusion=$(fm_ci_verdict_trim "$raw")
      [ -n "$conclusion" ] || continue
      if fm_ci_verdict_is_success "$conclusion"; then
        saw_success=1
        continue
      fi
      printf 'not-passed'
      return 0
    done
  else
    while IFS= read -r raw || [ -n "$raw" ]; do
      conclusion=$(fm_ci_verdict_trim "$raw")
      [ -n "$conclusion" ] || continue
      if fm_ci_verdict_is_success "$conclusion"; then
        saw_success=1
        continue
      fi
      printf 'not-passed'
      return 0
    done
  fi
  if [ "$saw_success" = 1 ]; then
    printf 'passed'
  else
    printf 'empty'
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fm_ci_ready_verdict "$@"
  printf '\n'
fi

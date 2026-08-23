#!/usr/bin/env bash
# fm-decision-tier.sh - CLI over bin/fm-decision-tier-lib.sh: the
# decision-tiering classifier and default-with-veto timeout mechanism from
# workstream 1 of the fleet engineering plan (data/fleet-engineering-plan.html,
# "widen the judgment channel" - "the actual 10x lever").
#
# NOT WIRED IN. This script and its library are a standalone building block.
# Nothing in firstmate's live escalation path calls them yet; turning that on
# is the captain's call, not something firstmate can self-grant (the plan's
# workstream 1 says so explicitly).
#
# Usage:
#   fm-decision-tier.sh classify <category>
#   fm-decision-tier.sh categories [auto|default-veto|hard-stop]
#   fm-decision-tier.sh auto [--now <epoch>] <log-file> <id> <category> <note>
#   fm-decision-tier.sh hard-stop [--now <epoch>] <log-file> <id> <category> <note>
#   fm-decision-tier.sh open [--now <epoch>] <log-file> <id> <category> <window-seconds> <recommendation> <default-action>
#   fm-decision-tier.sh veto [--now <epoch>] <log-file> <id> <note>
#   fm-decision-tier.sh status [--now <epoch>] <log-file> <id>
#   fm-decision-tier.sh report [--now <epoch>] <log-file>
#
# `classify` is the single-owner category->tier lookup
# (bin/fm-decision-tier-lib.sh fm_decision_tier_classify); an unrecognized
# category always classifies hard-stop rather than silently defaulting to a
# weaker tier. `categories` lists the known category vocabulary, optionally
# filtered to one tier; with no argument it prints `<category>\t<tier>` pairs,
# derived from `classify` rather than a second table.
#
# `auto` and `hard-stop` log a decision whose category already classifies to
# that tier; each refuses (exit 1) when the category classifies differently,
# so a caller cannot log a merge as auto by mistake.
#
# `open` records a default-with-veto decision: a stated recommendation and
# default action with a window in seconds, and refuses when the category does
# not classify default-veto. `status` reports one of:
#   pending  - still inside the window, no veto yet.
#   vetoed   - the captain objected before the window elapsed.
#   expired  - the window elapsed with no veto: the default action is cleared
#              to run. This is the "expires into action" contract - nothing
#              polls or reminds anyone; the status is recomputed from the log.
#   unknown  - no such id was ever opened.
# `veto` records a captain objection and refuses once the id is not currently
# pending (already vetoed, or the window already expired - too late).
#
# `report` prints one `key=value` line per counter - total, one line per tier
# outcome, and `escalation_count` (hard-stop decisions, the only tier that
# unconditionally reaches the captain) - so a session's escalation count is a
# reported, measurable quantity rather than a felt impression.
#
# `--now <epoch>` overrides the current time (default: the real clock) for
# deterministic testing and demonstration. It must come immediately after the
# subcommand name when given. The library itself never reads the clock; every
# time-sensitive library function takes epoch seconds as an explicit argument.
#
# Exit status: 0 on success; 1 on a refused or invalid operation (wrong tier
# for the category, veto after expiry, malformed window/epoch); 2 on a usage
# error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-decision-tier-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-decision-tier-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-tier: %s\n' "$*" >&2
  exit 1
}

now_default() {
  date +%s
}

# Pops a leading "--now <epoch>" pair off the positional args, if present, and
# echoes the resolved epoch. Callers re-derive their remaining positionals
# with `shift` guarded the same way, since bash functions cannot hand back a
# mutated caller argv.
resolve_now() {
  if [ "${1:-}" = --now ]; then
    case "${2:-}" in
      ''|*[!0-9]*) fail "--now requires an integer epoch" ;;
    esac
    printf '%s' "$2"
  else
    now_default
  fi
}

command_classify() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_decision_tier_classify "$1"
  printf '\n'
}

command_categories() {
  if [ "$#" -eq 0 ]; then
    local c
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      printf '%s\t%s\n' "$c" "$(fm_decision_tier_classify "$c")"
    done < <(fm_decision_tier_known_categories)
  elif [ "$#" -eq 1 ]; then
    case "$1" in
      auto|default-veto|hard-stop) fm_decision_tier_categories_for "$1" ;;
      *) fail "unknown tier '$1' (expected auto, default-veto, or hard-stop)" ;;
    esac
  else
    usage >&2
    exit 2
  fi
}

command_auto() {
  local now
  now=$(resolve_now "$@")
  [ "${1:-}" = --now ] && shift 2
  [ "$#" -eq 4 ] || { usage >&2; exit 2; }
  fm_decision_tier_log_auto "$1" "$now" "$2" "$3" "$4"
}

command_hard_stop() {
  local now
  now=$(resolve_now "$@")
  [ "${1:-}" = --now ] && shift 2
  [ "$#" -eq 4 ] || { usage >&2; exit 2; }
  fm_decision_tier_log_hard_stop "$1" "$now" "$2" "$3" "$4"
}

command_open() {
  local now
  now=$(resolve_now "$@")
  [ "${1:-}" = --now ] && shift 2
  [ "$#" -eq 6 ] || { usage >&2; exit 2; }
  fm_decision_tier_open_default "$1" "$now" "$2" "$3" "$5" "$6" "$4"
}

command_veto() {
  local now
  now=$(resolve_now "$@")
  [ "${1:-}" = --now ] && shift 2
  [ "$#" -eq 3 ] || { usage >&2; exit 2; }
  fm_decision_tier_veto "$1" "$now" "$2" "$3"
}

command_status() {
  local now
  now=$(resolve_now "$@")
  [ "${1:-}" = --now ] && shift 2
  [ "$#" -eq 2 ] || { usage >&2; exit 2; }
  fm_decision_tier_status "$1" "$2" "$now"
  printf '\n'
}

command_report() {
  local now
  now=$(resolve_now "$@")
  [ "${1:-}" = --now ] && shift 2
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_decision_tier_report "$1" "$now"
}

case "${1:-}" in
  classify) shift; command_classify "$@" ;;
  categories) shift; command_categories "$@" ;;
  auto) shift; command_auto "$@" ;;
  hard-stop) shift; command_hard_stop "$@" ;;
  open) shift; command_open "$@" ;;
  veto) shift; command_veto "$@" ;;
  status) shift; command_status "$@" ;;
  report) shift; command_report "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

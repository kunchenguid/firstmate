#!/usr/bin/env bash
# fm-routine-complete.sh - verify and execute routine completion after the verification gate.
#
# Semantic policy is owned by .agents/skills/decision-reconciliation/SKILL.md.
# AGENTS.md section 7 owns delivery and merge authority; this script enforces the
# mechanical checks before bin/fm-pr-merge.sh may run for routine ship work.
#
# Usage:
#   fm-routine-complete.sh verify <task-id>
#   fm-routine-complete.sh merge <task-id> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-routine-complete: %s\n' "$*" >&2
  exit 1
}

meta_value() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

routine_verify() {  # <task-id>
  local id=$1 meta="$STATE/$id.meta" status="$STATE/$id.status" last pr_url kind
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "$id has no task metadata"
  kind=$(meta_value "$meta" kind)
  [ "$kind" = ship ] || fail "$id is not kind ship (kind=${kind:-unknown})"
  last=$(last_status_line "$status")
  [ -n "$last" ] || fail "$id has no status history"
  case "$last" in
    *checks\ green*|*PR\ ready*) : ;;
    *)
      fail "$id is not verification-complete (last status: $last)"
      ;;
  esac
  pr_url=$(meta_value "$meta" pr)
  [ -n "$pr_url" ] || fail "$id has no recorded pr= metadata"
  fm_pr_url_parse "$pr_url" || fail "$id has invalid pr metadata: $pr_url"
  if status_open_decisions "$status" | grep -q .; then
    fail "$id still has open keyed status decisions"
  fi
  printf 'eligible: %s routine completion after verification gate\n' "$id"
}

command_verify() {
  local id=${1:-}
  [ -n "$id" ] || { usage >&2; exit 2; }
  fm_pr_task_id_valid "$id" || fail "invalid task id: $id"
  routine_verify "$id"
}

command_merge() {
  local id=${1:-}
  [ -n "$id" ] || { usage >&2; exit 2; }
  shift
  [ "${1:-}" = "--" ] && shift
  fm_pr_task_id_valid "$id" || fail "invalid task id: $id"
  routine_verify "$id" >/dev/null
  "$SCRIPT_DIR/fm-pr-merge.sh" "$id" "$(meta_value "$STATE/$id.meta" pr)" -- "$@"
  printf 'routine-merged: %s\n' "$id"
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || { usage >&2; exit 2; }
  shift
  case "$cmd" in
    verify) command_verify "$@" ;;
    merge) command_merge "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"

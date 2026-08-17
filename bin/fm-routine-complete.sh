#!/usr/bin/env bash
# fm-routine-complete.sh - verify and execute routine completion after the verification gate.
#
# Semantic policy is owned by .agents/skills/decision-reconciliation/SKILL.md.
# AGENTS.md section 7 owns delivery and merge authority; this script enforces the
# mechanical checks before bin/fm-pr-merge.sh may run for routine ship work.
#
# Usage:
#   fm-routine-complete.sh verify <task-id>
#   fm-routine-complete.sh merge <task-id> [-- <extra gh pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

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

routine_run_head_parse() {  # <crew-state-line>
  local state=$1 marker=" · run-head: " run_head
  case "$state" in
    *"$marker"*) ;;
    *) return 1 ;;
  esac
  run_head=${state##*"$marker"}
  fm_pr_head_valid "$run_head" || return 1
  ROUTINE_VERIFIED_RUN_HEAD=$run_head
}

routine_validate() {  # <task-id>
  local id=$1
  local meta="$STATE/$id.meta" status="$STATE/$id.status" current_state kind
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "$id has no task metadata"
  kind=$(meta_value "$meta" kind)
  [ "$kind" = ship ] || fail "$id is not kind ship (kind=${kind:-unknown})"
  if ! current_state=$("$CREW_STATE_BIN" "$id"); then
    fail "could not read current verification state for $id"
  fi
  case "$current_state" in
    "state: done · source: run-step"*) : ;;
    *) fail "$id is not verification-complete (current state: $current_state)" ;;
  esac
  routine_run_head_parse "$current_state" \
    || fail "$id verification state has no resolved run head"
  fm_pr_metadata_identity_parse "$meta" \
    || fail "$id has invalid PR metadata"
  [ "$FM_PR_META_PROVIDER" = github ] \
    || fail "$id has no mergeable GitHub PR metadata"
  fm_pr_head_valid "$FM_PR_META_HEAD" \
    || fail "$id has no verified pr_head= metadata"
  [ "$FM_PR_META_HEAD" = "$ROUTINE_VERIFIED_RUN_HEAD" ] \
    || fail "$id PR head is not the verified run head"
  if status_open_decisions "$status" | grep -q .; then
    fail "$id still has open keyed status decisions"
  fi
  ROUTINE_VERIFIED_PR_URL=$FM_PR_META_URL
  ROUTINE_VERIFIED_PR_HEAD=$FM_PR_META_HEAD
  printf 'eligible: %s routine completion after verification gate\n' "$id"
}

record_routine_completion() {  # <task-id>
  local id=$1
  local meta="$STATE/$id.meta" lock tmp line
  lock=$(fm_meta_lock_path "$meta") || fail "could not lock $id metadata"
  fm_lock_acquire_wait "$lock" || fail "could not lock $id metadata"
  if ! fm_pr_metadata_identity_parse "$meta" \
    || [ "$FM_PR_META_URL" != "$ROUTINE_VERIFIED_PR_URL" ] \
    || [ "$FM_PR_META_HEAD" != "$ROUTINE_VERIFIED_PR_HEAD" ]; then
    fm_lock_release "$lock" || true
    fail "$id PR metadata changed before completion was recorded"
  fi
  tmp=$(mktemp "$STATE/.fm-routine-complete.XXXXXX") || {
    fm_lock_release "$lock" || true
    fail "could not prepare $id completion evidence"
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      routine_complete_pr=*|routine_complete_pr_head=*|routine_complete_run_head=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" || {
        rm -f "$tmp"
        fm_lock_release "$lock" || true
        fail "could not record $id completion evidence"
      } ;;
    esac
  done < "$meta"
  {
    printf 'routine_complete_pr=%s\n' "$ROUTINE_VERIFIED_PR_URL"
    printf 'routine_complete_pr_head=%s\n' "$ROUTINE_VERIFIED_PR_HEAD"
    printf 'routine_complete_run_head=%s\n' "$ROUTINE_VERIFIED_RUN_HEAD"
  } >> "$tmp" || {
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    fail "could not record $id completion evidence"
  }
  chmod 0600 "$tmp" || {
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    fail "could not secure $id completion evidence"
  }
  mv -f "$tmp" "$meta" || {
    rm -f "$tmp"
    fm_lock_release "$lock" || true
    fail "could not record $id completion evidence"
  }
  fm_lock_release "$lock" || fail "could not unlock $id metadata"
}

require_routine_completion() {  # <task-id>
  local id=$1
  local meta="$STATE/$id.meta" recorded_pr recorded_head recorded_run_head
  recorded_pr=$(meta_value "$meta" routine_complete_pr)
  recorded_head=$(meta_value "$meta" routine_complete_pr_head)
  recorded_run_head=$(meta_value "$meta" routine_complete_run_head)
  [ -n "$recorded_pr" ] && [ -n "$recorded_head" ] && [ -n "$recorded_run_head" ] \
    || fail "$id has no prior routine completion evidence"
  fm_pr_url_parse "$recorded_pr" \
    || fail "$id has invalid routine completion PR evidence"
  [ "$FM_PR_URL" = "$recorded_pr" ] \
    || fail "$id has non-canonical routine completion PR evidence"
  fm_pr_head_valid "$recorded_head" \
    || fail "$id has invalid routine completion head evidence"
  fm_pr_head_valid "$recorded_run_head" \
    || fail "$id has invalid routine completion run-head evidence"
  [ "$recorded_head" = "$recorded_run_head" ] \
    || fail "$id routine completion evidence is not bound to its verified run"
  [ "$recorded_pr" = "$ROUTINE_VERIFIED_PR_URL" ] \
    && [ "$recorded_head" = "$ROUTINE_VERIFIED_PR_HEAD" ] \
    && [ "$recorded_run_head" = "$ROUTINE_VERIFIED_RUN_HEAD" ] \
    || fail "$id PR metadata changed after routine completion"
}

command_verify() {
  local id=${1:-}
  [ -n "$id" ] || { usage >&2; exit 2; }
  fm_pr_task_id_valid "$id" || fail "invalid task id: $id"
  routine_validate "$id"
  record_routine_completion "$id"
}

command_merge() {
  local id=${1:-}
  [ -n "$id" ] || { usage >&2; exit 2; }
  shift
  [ "${1:-}" = "--" ] && shift
  fm_pr_task_id_valid "$id" || fail "invalid task id: $id"
  routine_validate "$id" >/dev/null
  require_routine_completion "$id"
  fm_pr_metadata_identity_parse "$STATE/$id.meta" \
    || fail "$id has invalid PR metadata after verification"
  [ "$FM_PR_META_URL" = "$ROUTINE_VERIFIED_PR_URL" ] \
    && [ "$FM_PR_META_HEAD" = "$ROUTINE_VERIFIED_PR_HEAD" ] \
    || fail "$id PR metadata changed after verification"
  FM_PR_EXPECTED_URL=$ROUTINE_VERIFIED_PR_URL FM_PR_EXPECTED_HEAD=$ROUTINE_VERIFIED_PR_HEAD \
    "$SCRIPT_DIR/fm-pr-merge.sh" "$id" "$ROUTINE_VERIFIED_PR_URL" -- "$@"
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

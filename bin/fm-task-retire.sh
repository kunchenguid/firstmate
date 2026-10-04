#!/usr/bin/env bash
# Backend-neutral Firstmate task retirement.
#
# Usage:
#   fm-task-retire.sh <task-id> [fm-teardown arguments...]
#   fm-task-retire.sh <task-id> --complete-only
#   fm-task-retire.sh <task-id> --historical-state <dry-run|apply> --generation <generation>
#
# --complete-only closes an already accepted/delivered or explicitly archived
# business row while retaining every resource. MAIN only; no provider/backend
# calls. The existing cleanup receipt and backlog-close marker preserve the
# outstanding resource obligation and replay bookkeeping after interruption.
# Accepted scouts need their assessed report; accepted ships need the guarded
# merge owner's generation-bound receipt. Open/unknown goals refuse.
#
# Legacy/local tasks delegate unchanged to fm-teardown.sh.
# Remote tasks use provider-specific terminal/report/decision/source preflight,
# pair backlog closure or retention before volatile-record removal, and preserve
# the complete execution record when that transition cannot be confirmed.
# They never invoke local endpoint or worktree teardown. Legacy AIME
# executor=cloud-worker records remain supported without migration.
# Historical state cleanup is deliberately task-specific. It performs no
# endpoint, copy, provider, backlog, or business-state effect; it requires an
# already-absent execution record plus exact terminal disposition and immutable
# cleanup completion evidence, then retires only the existing owners' volatile
# status/runtime/poll projections and archives active cleanup/merge receipts.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

id=${1-}
case "$id" in
  -h|--help)
    printf '%s\n' 'usage: fm-task-retire.sh <task-id> [fm-teardown arguments...]' \
      '       fm-task-retire.sh <task-id> --complete-only' \
      '       fm-task-retire.sh <task-id> --historical-state <dry-run|apply> --generation <generation>' \
      '--complete-only: MAIN records accepted/delivered or archived business completion; retains every resource.' \
      '--historical-state: MAIN retires one already-ended task state after exact terminal and completed-cleanup proof; performs no provider, endpoint, copy, backlog, or business-state action.'
    exit 0
    ;;
esac
[ -n "$id" ] || { printf 'usage: fm-task-retire.sh <task-id> [fm-teardown arguments...]\n' >&2; exit 2; }
# shellcheck source=bin/fm-cleanup-receipt-lib.sh
. "$SCRIPT_DIR/fm-cleanup-receipt-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
meta="$STATE/$id.meta"

historical_state_cleanup() ( # <dry-run|apply> <generation>
  local action=$1 generation=$2 data meta_lock='' control_lock='' receipt disposition facts busy_gen path count=0
  local -a paths=()
  case "$generation" in ''|.*|*[!A-Za-z0-9._-]*) echo 'error: invalid cleanup generation' >&2; exit 2 ;; esac
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
  # shellcheck source=bin/fm-short-owner-lib.sh
  . "$SCRIPT_DIR/fm-short-owner-lib.sh"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
  fm_refuse_if_gate_agent
  [ "$(fm_lease_actor)" = main ] || { echo 'REFUSED: historical state cleanup belongs to MAIN' >&2; exit 6; }
  fm_lease_valid_id "$id" || exit 2
  data="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  historical_state_cleanup_release() {
    [ -z "$meta_lock" ] || fm_lock_release "$meta_lock"
    [ -z "$control_lock" ] || fm_lock_release "$control_lock"
    fm_lease_guard_release
    fm_short_owner_release
  }
  trap historical_state_cleanup_release EXIT
  fm_short_owner_enter cleanup "$id" || exit 1
  fm_lease_guard "$id" 'historical task state cleanup' || exit $?
  control_lock="$STATE/.control-$id.lock"
  fm_lock_try_acquire "$control_lock" || { echo "REFUSED: another lifecycle action is running for task $id" >&2; exit 1; }
  meta_lock=$(fm_meta_lock_path "$meta") || exit 1
  fm_lock_acquire_wait "$meta_lock" || exit 1

  [ ! -e "$meta" ] && [ ! -L "$meta" ] || {
    echo "REFUSED: task $id still has execution metadata; use ordinary task retirement" >&2
    exit 1
  }
  for path in "$STATE/$id.backlog-close" "$STATE/cloud-tasks/$id" "$STATE/remote-tasks/$id"; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || {
      echo "REFUSED: task $id has pending execution or backlog state at $path; use its owning retirement path" >&2
      exit 1
    }
  done
  disposition=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$data" \
    fm_cleanup_historical_completion_mode "$id" "$generation") || exit $?
  if [ -e "$STATE/$id.cleanup.json" ] || [ -L "$STATE/$id.cleanup.json" ]; then
    if ! { [ -f "$STATE/$id.cleanup.json" ] && [ ! -L "$STATE/$id.cleanup.json" ] \
      && jq -e --arg id "$id" --arg generation "$generation" \
        '.schema=="fm-task-cleanup.v1" and .task_id==$id and .spawn_gen==$generation' \
        "$STATE/$id.cleanup.json" >/dev/null; }; then
      echo "REFUSED: active cleanup receipt does not match task $id generation $generation" >&2
      exit 1
    fi
  fi
  receipt=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$data" \
    fm_cleanup_receipt completion-read "$id" "$generation") || exit 1
  facts=$(printf '%s' "$receipt" | jq -ce '
    .facts | select(.taskRecordRemoved == true and .endpointConfirmedGone == true and
      .bookkeepingComplete == true and
      (.copyDisposition == "returned-or-already-absent" or
       .copyDisposition == "retained-shared" or .copyDisposition == "retained-primary" or
       .copyDisposition == "retained-dirty" or .copyDisposition == "retained-unlanded" or
       .copyDisposition == "retained-unverified"))') || {
    echo "REFUSED: task $id cleanup completion facts are incomplete; preserving historical state" >&2
    exit 1
  }
  [ -n "$facts" ] || exit 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-task-handoff.sh" retirement-check "$id" || exit 1
  fm_task_inbox_retirement_guard "$STATE" "$id" || exit 1
  status_retire_presentation_task "$STATE" "$id" --check-settled || exit 1
  fm_pr_poll_cleanup_validate "$STATE" "$id" || exit 1

  for path in "$STATE/$id.status" "$STATE/.$id.open-decisions-cursor" \
    "$STATE/$id.busy-gen" "$STATE/$id.busy-state" "$STATE/$id.progress" \
    "$STATE/$id.turn-ended" "$STATE/$id.pi-ext.ts" "$STATE/$id.busy-session" \
    "$STATE/$id.herdr-presentation" "$STATE/$id.control-relaunch" \
    "$STATE/$id.control-relaunch.meta-prior" "$STATE/$id.control-relaunch.brief-prior" \
    "$STATE/$id.control-relaunch.note" "$STATE/$id.reconcile-nudged" \
    "$STATE/.$id.branch-outcome-index" "$STATE/$id.inbox" \
    "$STATE/$id.check.sh" "$STATE/$id.pr-poll" "$STATE/$id.pr-poll-registration" \
    "$STATE/$id.pr-poll-retirement" "$STATE/$id.pr-poll-merge-notified" \
    "$STATE/$id.merge-authority" "$STATE/$id.check-trust" \
    "$STATE/$id.cleanup.json" "$STATE/$id.merge-receipts.jsonl"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    paths+=("$path")
  done
  count=${#paths[@]}
  printf 'eligible: %s generation=%s disposition=%s artifacts=%s action=%s\n' \
    "$id" "$generation" "$disposition" "$count" "$action"
  for path in "${paths[@]+"${paths[@]}"}"; do printf '%s: %s\n' "$action" "$path"; done
  [ "$action" = apply ] || exit 0

  status_retire_presentation_task "$STATE" "$id" --require-settled || exit 1
  fm_pr_poll_cleanup_remove "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || exit 1
  if [ -e "$STATE/$id.busy-gen" ] || [ -L "$STATE/$id.busy-gen" ] \
    || [ -e "$STATE/$id.busy-state" ] || [ -L "$STATE/$id.busy-state" ]; then
    busy_gen=$(cat "$STATE/$id.busy-gen" 2>/dev/null || true)
    if [ -n "$busy_gen" ]; then
      "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$id" --gen "$busy_gen" || exit 1
    else
      "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$id" --current-gen || exit 1
    fi
  fi
  rm -f -- "$STATE/$id.turn-ended" "$STATE/$id.progress" "$STATE/$id.pi-ext.ts" \
    "$STATE/$id.busy-session" "$STATE/$id.herdr-presentation" \
    "$STATE/$id.control-relaunch" "$STATE/$id.control-relaunch.meta-prior" \
    "$STATE/$id.control-relaunch.brief-prior" "$STATE/$id.control-relaunch.note" \
    "$STATE/$id.reconcile-nudged" "$STATE/.$id.branch-outcome-index" || exit 1
  rm -rf -- "$STATE/$id.inbox" || exit 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$data" \
    fm_cleanup_receipt_archive_complete "$id" "$generation" || exit 1
  printf 'historical state retired: %s generation=%s; canonical and retained evidence preserved\n' "$id" "$generation"
)

if [ "${2:-}" = --historical-state ]; then
  [ "$#" -eq 5 ] && [ "${4:-}" = --generation ] || exit 2
  case "${3:-}" in dry-run|apply) ;; *) exit 2 ;; esac
  historical_state_cleanup "$3" "$5"
  exit $?
fi

if [ "${2:-}" = --complete-only ]; then
  [ "$#" -eq 2 ] || exit 2
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  # shellcheck source=bin/fm-teardown-endpoint-lib.sh
  . "$SCRIPT_DIR/fm-teardown-endpoint-lib.sh"
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
  fm_refuse_if_gate_agent
  [ "$(fm_lease_actor)" = main ] || { echo 'REFUSED: business completion belongs to MAIN' >&2; exit 6; }
  fm_lease_valid_id "$id" || exit 2
  fm_lease_guard "$id" 'business completion' || exit $?
  retire_rc=0
  lock=$(fm_meta_lock_path "$meta") || exit 1
  trap 'retire_rc=$?; fm_lock_release "$lock"; fm_lease_guard_release; exit "$retire_rc"' EXIT
  fm_lock_acquire_wait "$lock" || exit 1
  DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  ID=$id
  ENDPOINT_GENERATION=$(sed -n 's/^spawn_gen=//p' "$meta" | tail -1)
  [ -n "$ENDPOINT_GENERATION" ] || exit 1
  fm_cleanup_completion_guard "$id" "$ENDPOINT_GENERATION" || exit $?
  fm_cleanup_delivery_guard "$id" "$ENDPOINT_GENERATION" "$meta" || exit $?
  ENDPOINT_RECEIPT="$STATE/$ID.cleanup.json"
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2-)" || {
    echo "REFUSED: automatic business completion unavailable: ${FM_BACKLOG_TRANSITION_ERROR:-$FM_BACKLOG_TRANSITION_SKIP}" >&2
    exit 1
  }
  marker=$(fm_backlog_close_marker_path "$STATE" "$ID") || exit 1
  if [ ! -e "$ENDPOINT_RECEIPT" ] && [ ! -L "$ENDPOINT_RECEIPT" ]; then
    teardown_endpoint_receipt directory_return retained business-complete-resources-retained || exit 1
  fi
  fm_cleanup_receipt read "$ID" "$ENDPOINT_GENERATION" >/dev/null || exit 1
  args=()
  report="$DATA/$ID/report.md"
  if [ -f "$report" ] && [ ! -L "$report" ]; then args=(--report "data/$ID/report.md"); fi
  delivery=$(sed -n 's/^pr=//p' "$meta" | tail -1)
  if [ -z "$delivery" ]; then
    # shellcheck source=bin/fm-merge-receipt-lib.sh
    . "$SCRIPT_DIR/fm-merge-receipt-lib.sh"
    delivery=$(fm_merge_receipt_current "$ID" "$ENDPOINT_GENERATION" 2>/dev/null | jq -r '.url // empty' || true)
  fi
  case "$delivery" in
    https://*) args=(--pr "$delivery") ;;
    local:*) args=(--note 'local main') ;;
  esac
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_backlog_close_marker_validate "$marker" "$DATA" "$ID" "$STATE" || exit 1
    [ "$FM_BACKLOG_CLOSE_VALIDATED_MODE" = complete-only ] || {
      echo 'REFUSED: another pending retirement must be reconciled first' >&2; exit 1;
    }
  else
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$ENDPOINT_GENERATION" --complete-only "${args[@]+"${args[@]}"}" || exit 1
  fi
  fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA" || exit 1
  printf 'business disposition recorded: %s; resources and cleanup obligation retained\n' "$ID"
  exit 0
fi

if [ ! -f "$meta" ] || [ -L "$meta" ]; then
  exec "$SCRIPT_DIR/fm-teardown.sh" "$@"
fi

meta_value() {
  grep "^$1=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

executor=$(meta_value executor)
[ -n "$executor" ] || executor=local-agent
case "$executor" in
  local-agent)
    exec "$SCRIPT_DIR/fm-teardown.sh" "$@"
    ;;
  cloud-worker)
    [ "$#" -eq 1 ] || {
      printf 'error: cloud task retirement accepts no local teardown flags\n' >&2
      exit 2
    }
    provider=$(meta_value provider)
    case "$provider" in
      aime) exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" retire "$id" ;;
      *) printf 'error: unsupported cloud provider: %s\n' "${provider:-missing}" >&2; exit 1 ;;
    esac
    ;;
  remote-agent)
    [ "$#" -eq 1 ] || {
      printf 'error: remote task retirement accepts no local teardown flags\n' >&2
      exit 2
    }
    provider=$(meta_value provider)
    case "$provider" in
      aime) exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" retire "$id" ;;
      ida) exec "$SCRIPT_DIR/fm-remote-agent-ida.sh" retire "$id" ;;
      *) printf 'error: unsupported remote provider: %s\n' "${provider:-missing}" >&2; exit 1 ;;
    esac
    ;;
  *)
    printf 'error: unsupported task executor: %s\n' "$executor" >&2
    exit 1
    ;;
esac

#!/usr/bin/env bash
# Queue-driven provider-neutral lifecycle for one-task elastic workers.
#
# This wrapper never decides that work is landed and never deletes ambiguous
# work. The exact lifecycle, Azure setup, release receipt, recovery, cost, and
# acceptance contracts live in docs/azure-workers.md.
#
# Required environment:
#   FM_HOME
#   FM_AZURE_SUBSCRIPTION_ID
#   FM_AZURE_DEPLOYMENT_GENERATION
#   FM_AZURE_OWNER_TAG
#   FM_AZURE_NAMING_PREFIX
#   FM_AZURE_STORAGE_NAME (Azure adapter)
#
# Optional policy:
#   FM_AZURE_WORKER_POLICY_PHASE=commissioning|steady
#   FM_AZURE_WORKER_STEADY_TARGET_USD=1000
#   FM_AZURE_WORKER_COMMISSIONING_CEILING_USD=1500
#   FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD=3500
#   FM_AZURE_WORKER_ADMISSION_HOURS=24
#   FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=300
#   FM_AZURE_WORKER_DAILY_BOUND_USD=100        (unset = 100; <=0 or non-numeric refuses)
#   FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE=<utc-day>  (exact current day only)
#   FM_AZURE_WORKER_IDLE_RELEASE_SECONDS=14400 (600..604800)
#   FM_AZURE_WORKER_MAX=16
#   FM_AZURE_WORKER_WARM_IDLE=0
#   FM_WORKER_PROVIDER_COMMAND='python3 <provider-adapter>'
#
# Usage:
#   fm-worker-lifecycle.sh request <exact identity flags> --eligible
#   fm-worker-lifecycle.sh reconcile [--apply --confirm-subscription <uuid>]
#   fm-worker-lifecycle.sh capacity-reserve <exact specialized reservation flags>
#   fm-worker-lifecycle.sh capacity-reserve-shape <exact complete-shape constituents>
#   fm-worker-lifecycle.sh capacity-release <exact fence and cleanup receipt>
#   fm-worker-lifecycle.sh execute <exact assignment flags> -- <argv...>
#   fm-worker-lifecycle.sh authority-receipt <exact assignment flags> --output <json>
#   fm-worker-lifecycle.sh proof-template --task <id> --task-generation <id>
#   fm-worker-lifecycle.sh release --task <id> --task-generation <id> --proof-file <json>
#   fm-worker-lifecycle.sh withdraw --task <id> --task-generation <id> --confirm-withdraw --confirm-subscription <uuid>
#   fm-worker-lifecycle.sh abandon-claim --slot <n> --idempotency-key <sha256> --confirm-abandon --confirm-subscription <uuid>
#   fm-worker-lifecycle.sh surrender --task <id> --task-generation <id> --reason <text> --output <json> --confirm-surrender --confirm-subscription <uuid>
#   fm-worker-lifecycle.sh resume <exact recovery flags>
#   fm-worker-lifecycle.sh steer <exact assignment flags>
#   fm-worker-lifecycle.sh message-put <exact assignment flags> --file <json> | --attach <bundle>
#   fm-worker-lifecycle.sh message-collect <exact assignment flags> --output-dir <dir>
#   fm-worker-lifecycle.sh status [--live] [--json]
#   fm-worker-lifecycle.sh acceptance-plan
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-cloud-state-lib.sh
. "$SCRIPT_DIR/fm-cloud-state-lib.sh"

case "${1:-}" in
  request|release|resume|steer|execute|authority-receipt|capacity-reserve|capacity-reserve-shape|capacity-release|abandon-claim|message-put|message-collect)
    fm_refuse_if_gate_agent
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  withdraw)
    fm_refuse_if_gate_agent
    # A withdrawn request leaves no durable owner for the convergence artifacts
    # bin/fm-spawn.sh staged for it, including the COPIED PROVIDER CREDENTIAL at
    # $STATE/<id>.cloud-account/auth.json. fm-spawn's own rollback removes them
    # for exactly this reason, and teardown never runs for a task that never got
    # a worker, so the removal is owned here.
    #
    # Cleanup is keyed off the command's own FM-WITHDREW receipt, never off its
    # exit code and never off the argv. `--help` also exits 0 without
    # withdrawing anything, so an exit-code gate let `withdraw --task <id>
    # --help` destroy a LIVE task's credential, payload and returned result;
    # and an argv scan misses the --task=<value> form, silently leaving the
    # credential behind on a real withdrawal. The receipt names the exact entry
    # that was actually deleted, so cleanup cannot outrun the deletion.
    withdraw_output=$(python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@")
    printf '%s\n' "$withdraw_output"
    withdraw_receipt=$(printf '%s\n' "$withdraw_output" | awk '$1 == "FM-WITHDREW" { print $2; exit }')
    if [ -n "$withdraw_receipt" ]; then
      # Not `|| true`: fm_cloud_state_remove reports a stuck credential and
      # returns 0 so teardown can continue, but here it is the last step, so a
      # credential left on disk has to be visible to whatever ran this.
      fm_cloud_state_remove "${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}" "$withdraw_receipt"
      state_root="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
      if [ -e "$state_root/$withdraw_receipt.cloud-account/auth.json" ]; then
        echo "ELASTIC WORKER REFUSED: withdrew $withdraw_receipt but its staged provider credential remains" >&2
        exit 4
      fi
    fi
    exit 0
    ;;
  surrender)
    fm_refuse_if_gate_agent
    # A surrendered task's local cloud state has the same no-owner problem as a
    # withdrawn one: its endpoint, metadata and teardown are already gone (that
    # is what made surrender necessary), so nothing else will ever remove the
    # staged provider credential at $STATE/<id>.cloud-account/auth.json. The
    # cloud-side copies go later, through reconcile's fenced reset; the local
    # staging is owned here, keyed off the FM-SURRENDERED receipt for exactly
    # the reasons the withdraw lane documents above.
    surrender_output=$(python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@")
    printf '%s\n' "$surrender_output"
    surrender_receipt=$(printf '%s\n' "$surrender_output" | awk '$1 == "FM-SURRENDERED" { print $2; exit }')
    if [ -n "$surrender_receipt" ]; then
      fm_cloud_state_remove "${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}" "$surrender_receipt"
      state_root="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
      if [ -e "$state_root/$surrender_receipt.cloud-account/auth.json" ]; then
        echo "ELASTIC WORKER REFUSED: surrendered $surrender_receipt but its staged provider credential remains" >&2
        exit 4
      fi
    fi
    exit 0
    ;;
  reconcile)
    for argument in "$@"; do
      if [ "$argument" = --apply ]; then
        fm_refuse_if_gate_agent
        break
      fi
    done
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  proof-template|status|acceptance-plan)
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  help|-h|--help|"")
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" --help
    ;;
  *)
    printf 'ELASTIC WORKER REFUSED: unknown command: %s\n' "$1" >&2
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" --help
    ;;
esac

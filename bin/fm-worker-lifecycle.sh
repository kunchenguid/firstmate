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
#   fm-worker-lifecycle.sh execute <exact assignment flags> [--existing-task-disk --return-kind <ship|scout> --outcome-dir <dir>] -- <argv...>
#   fm-worker-lifecycle.sh authority-receipt <exact assignment flags> --output <json>
#   fm-worker-lifecycle.sh proof-template --task <id> --task-generation <id>
#   fm-worker-lifecycle.sh release --task <id> --task-generation <id> --proof-file <json>
#   fm-worker-lifecycle.sh withdraw --task <id> --task-generation <id> --confirm-withdraw --confirm-subscription <uuid>
#   fm-worker-lifecycle.sh abandon-claim --slot <n> --idempotency-key <sha256> --confirm-abandon --confirm-subscription <uuid>
#   fm-worker-lifecycle.sh surrender --task <id> --task-generation <id> --reason <text> --output <json> --confirm-surrender --confirm-subscription <uuid> [--confirm-discard-unlanded] [--confirm-orphan-children]
#   fm-worker-lifecycle.sh resume <exact recovery flags>
#   fm-worker-lifecycle.sh steer <exact assignment flags>
#   fm-worker-lifecycle.sh message-put <exact assignment flags> --file <json> | --attach <bundle>
#   fm-worker-lifecycle.sh message-collect <exact assignment flags> --output-dir <dir>
#   fm-worker-lifecycle.sh compartment-chain-tip <exact assignment flags> --sequence <n> --chain-digest <sha256>
#   fm-worker-lifecycle.sh capacity-retire-fence <exact released fence and reservation ids>
#   fm-worker-lifecycle.sh status [--live] [--json]
#   fm-worker-lifecycle.sh acceptance-plan
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-cloud-state-lib.sh
. "$SCRIPT_DIR/fm-cloud-state-lib.sh"

# The state directory a receipted task's cloud state was staged in.
#
# A compartment child lives in the SECONDMATE's home, while these commands
# necessarily run with FM_HOME on the primary: the controller document has
# exactly one home. Guessing from the task id would be worse than the leak,
# because ids are home-scoped and the same id can be live in two homes at once,
# so the answer comes from the CONTROLLER, which authorized that exact path for
# that exact task generation under its own lock and writes it to the file named
# by --task-home-out. Absent (every ordinary task), the controller's own state
# directory is the answer, exactly as before.
#
# A DEDICATED FILE, never a line in the command's stdout. On a shared stream
# the value's safety rested on two unrelated invariants holding forever: that
# stderr is never folded in, and that no id can contain a space or newline.
# Either relaxing would let some other line decide where a removal is aimed.
# The file is two lines exactly - parent, then home - so there is no parser.
fm_worker_receipt_state_dir() {  # <task home file> <controller state>
  local file=$1 fallback=$2 parent task_home canonical
  [ -f "$file" ] && [ ! -L "$file" ] || { printf '%s\n' "$fallback"; return 0; }
  IFS= read -r parent < "$file" || parent=
  task_home=$(sed -n '2p' "$file")
  [ -n "$parent" ] || { printf '%s\n' "$fallback"; return 0; }
  case "$task_home" in
    /*/../*|*/..|*/../*|'') printf '%s\n' "$fallback"; return 0 ;;
    /*) : ;;
    *) printf '%s\n' "$fallback"; return 0 ;;
  esac
  # The reader enforces exactly what the stager enforced, no more and no less.
  # bin/fm-spawn.sh resolved FM_SPAWN_TASK_HOME with `cd -P && pwd -P` and then
  # required the home's own marker to name the parent compartment, and the
  # controller stores that resolved path; a value that is not its own physical
  # path therefore did not come from an authorization. This is what makes a
  # symlinked home, a symlinked path component, and a home whose marker names a
  # different secondmate fall back instead of redirecting a removal.
  canonical=$(cd -P "$task_home" 2>/dev/null && pwd -P) || canonical=
  [ -n "$canonical" ] && [ "$canonical" = "$task_home" ] \
    || { printf '%s\n' "$fallback"; return 0; }
  [ -f "$task_home/.fm-secondmate-home" ] && [ ! -L "$task_home/.fm-secondmate-home" ] \
    || { printf '%s\n' "$fallback"; return 0; }
  [ "$(cat "$task_home/.fm-secondmate-home" 2>/dev/null || true)" = "$parent" ] \
    || { printf '%s\n' "$fallback"; return 0; }
  printf '%s\n' "$task_home/state"
}

# Did this task's staged credential survive the removal? True (0) when it did.
#
# Deliberately NOT scoped to the directory the removal resolved. When
# resolution falls back wrongly - which is the entire failure this change
# exists to make impossible - that directory never held a credential, so
# inspecting it passes and the command reports success while the plaintext file
# sits in the compartment home. A check whose subject is derived from the thing
# it audits cannot fail when that thing is wrong.
#
# The subjects are therefore fixed independently of the resolution: the home
# the CONTROLLER named for this task, read raw and tested rather than removed,
# plus the controller's own state directory, which is where an ordinary task's
# credential lives.
#
# Stated exactly, because a stronger claim would be false: `[ -e ]` FOLLOWS
# symlinks. A named home that is itself a symlink to an empty marked decoy
# therefore reports "gone" while the real credential survives behind the link.
# That shape was silent before this change too, so it is not a regression, and
# the two other symlink shapes now fail loudly rather than silently; but this
# audit is a net for a wrongly resolved removal, not a proof of absence.
fm_worker_receipt_credential_remains() {  # <task home file> <task id> <controller state>
  local file=$1 id=$2 fallback=$3 named=
  [ ! -e "$fallback/$id.cloud-account/auth.json" ] || return 0
  # The SAME gate the reader applies to the same channel. Two functions
  # applying different trust to one input is the seam that produced the first
  # defect on this branch; here it also matters mechanically, because sed on a
  # FIFO blocks forever and an indefinite hang is a worse failure than a wrong
  # answer.
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    named=$(sed -n '2p' "$file" 2>/dev/null) || named=
  fi
  case "$named" in
    /*) [ ! -e "$named/state/$id.cloud-account/auth.json" ] || return 0 ;;
  esac
  return 1
}

case "${1:-}" in
  request|release|resume|steer|execute|authority-receipt|capacity-reserve|capacity-reserve-shape|capacity-release|capacity-retire-fence|abandon-claim|message-put|message-collect|compartment-chain-tip)
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  withdraw)
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
    task_home_file=$(mktemp "${TMPDIR:-/tmp}/fm-task-home.XXXXXX") || exit 1
    withdraw_output=$(python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@" \
      --task-home-out "$task_home_file")
    printf '%s\n' "$withdraw_output"
    withdraw_receipt=$(printf '%s\n' "$withdraw_output" | awk '$1 == "FM-WITHDREW" { print $2; exit }')
    if [ -n "$withdraw_receipt" ]; then
      # Not `|| true`: fm_cloud_state_remove reports a stuck credential and
      # returns 0 so teardown can continue, but here it is the last step, so a
      # credential left on disk has to be visible to whatever ran this.
      state_root="${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}"
      # Where the credential actually is, which is not the controller's home
      # for a compartment child.
      staged_root=$(fm_worker_receipt_state_dir "$task_home_file" "$state_root")
      fm_cloud_state_remove "$staged_root" "$withdraw_receipt"
      if fm_worker_receipt_credential_remains "$task_home_file" "$withdraw_receipt" "$state_root"; then
        echo "ELASTIC WORKER REFUSED: withdrew $withdraw_receipt but its staged provider credential remains" >&2
        rm -f "$task_home_file"
        exit 4
      fi
    fi
    rm -f "$task_home_file"
    exit 0
    ;;
  surrender)
    # A surrendered task's local cloud state has the same no-owner problem as a
    # withdrawn one: its endpoint, metadata and teardown are already gone (that
    # is what made surrender necessary), so nothing else will ever remove the
    # staged provider credential at $STATE/<id>.cloud-account/auth.json. The
    # cloud-side copies go later, through reconcile's fenced reset; the local
    # staging is owned here, keyed off the FM-SURRENDERED receipt for exactly
    # the reasons the withdraw lane documents above.
    task_home_file=$(mktemp "${TMPDIR:-/tmp}/fm-task-home.XXXXXX") || exit 1
    surrender_output=$(python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@" \
      --task-home-out "$task_home_file")
    printf '%s\n' "$surrender_output"
    surrender_receipt=$(printf '%s\n' "$surrender_output" | awk '$1 == "FM-SURRENDERED" { print $2; exit }')
    if [ -n "$surrender_receipt" ]; then
      state_root="${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}"
      # Same source as the withdraw lane above, for the same reason: the
      # surrendered task's credential lives in ITS task home, which is the
      # secondmate's for a compartment child.
      staged_root=$(fm_worker_receipt_state_dir "$task_home_file" "$state_root")
      fm_cloud_state_remove "$staged_root" "$surrender_receipt"
      if fm_worker_receipt_credential_remains "$task_home_file" "$surrender_receipt" "$state_root"; then
        echo "ELASTIC WORKER REFUSED: surrendered $surrender_receipt but its staged provider credential remains" >&2
        rm -f "$task_home_file"
        exit 4
      fi
    fi
    rm -f "$task_home_file"
    exit 0
    ;;
  reconcile)
    for argument in "$@"; do
      if [ "$argument" = --apply ]; then
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

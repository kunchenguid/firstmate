#!/usr/bin/env bash
# Herdr tracking pane for one cloud-placed crewmate.
#
# The crewmate itself runs on an elastic Azure worker; this process is the
# local endpoint that keeps it visible and reapable in the same Herdr
# workspace as local crewmates. It renders the durable lifecycle state
# (queue/assignment from the worker controller, then the bounded execute log)
# and exits only after the digest-bound result is in local custody and its
# assignment has released, so endpoint loss can never strand account or
# capacity ownership behind an otherwise successful worker exit.
#
# Convergence duty: when the spawn-time reconcile left the request queued
# (transient admission evidence), a LATER reconcile assigns the worker after
# the spawn process is gone. This monitor is the surviving local owner, so on
# seeing status=assigned it dispatches the persisted entrypoint through the
# same bounded execute the spawn would have run. The dispatch marker file is
# claimed with O_EXCL and shared with fm-spawn.sh, so exactly one owner
# dispatches at a time; a claim whose bounded execute is provably over (marker
# older than the wall plus slack) with no result is reclaimed, which is safe
# because the lifecycle execute is digest-idempotent.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-cloud-state-lib.sh
. "$SCRIPT_DIR/fm-cloud-state-lib.sh"
ID=${1:?task id}
GENERATION=${2:?task generation id}
FM_HOME=${FM_HOME:?FM_HOME is required}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# The controller document is the ONE money authority, and it lives under the
# home FM_HOME names. $STATE is where THIS TASK's files live, which is the same
# directory for every ordinary crewmate and the secondmate's own home on the
# compartment-child lane; deriving the controller from $STATE there would read
# a document that does not exist and report the crewmate as forever unqueued.
CONTROLLER=$FM_HOME/state/azure-workers/controller.json
RESULT=$STATE/$ID.worker-result.json
EXEC_LOG=$STATE/$ID.worker-execute.log
ENTRYPOINT=$STATE/$ID.cloud-entrypoint
CLOUD_ENV=$STATE/$ID.cloud-env
DISPATCH_MARKER=$STATE/$ID.cloud-execute-dispatched
INTERVAL=${FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS:-30}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=30 ;; esac

queue_status() {
  python3 - "$CONTROLLER" "$ID" "$GENERATION" <<'PY'
import json
import sys

path, task, generation = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    print("controller-unreadable")
    raise SystemExit(0)
item = (state.get("queue") or {}).get("{}@{}".format(task, generation)) or {}
print(item.get("status") or "unqueued")
PY
}

assignment_generation() {
  python3 - "$CONTROLLER" "$ID" "$GENERATION" <<'PY'
import json
import sys

path, task, generation = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
item = (state.get("queue") or {}).get("{}@{}".format(task, generation)) or {}
if item.get("status") == "assigned" and item.get("assignment_generation"):
    print(item["assignment_generation"])
PY
}

persisted_wall_seconds() {
  local wall
  wall=$(sed -n 's/^export FM_SPAWN_CLOUD_WALL_SECONDS=//p' "$CLOUD_ENV" 2>/dev/null | head -1)
  case "$wall" in ''|*[!0-9]*) wall=3600 ;; esac
  printf '%s\n' "$wall"
}

reclaim_stale_dispatch() {
  # A held marker with no result after the bounded wall (plus slack) means
  # the claimed execute died, was refused, or the host rebooted mid-flight.
  # The lifecycle execute is digest-idempotent, so releasing the claim and
  # letting the next iteration redispatch is safe; a still-running execute
  # inside its wall is never touched.
  local mtime now wall
  [ -f "$DISPATCH_MARKER" ] || return 0
  [ ! -s "$RESULT" ] || return 0
  # Portable epoch mtime, branched on uname like bin/fm-lock-lib.sh. A
  # BSD-first `stat -f %m "$f" || stat -c %Y "$f"` chain is broken on GNU:
  # there -f selects a filesystem-format mode that takes no format operand, so
  # %m is read as a SECOND FILE operand. GNU stat prints the filesystem block
  # for %m's stat, errors on the real file, and the `||` does fire - but the
  # first command's output is already inside the captured substitution, so the
  # variable holds filesystem text plus the fallback's epoch and the numeric
  # guard below reads it as "not a number" and returns, disabling the reclaim
  # staleness check entirely on exactly the platform the workers run.
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$DISPATCH_MARKER" 2>/dev/null) || return 0
  else
    mtime=$(stat -c %Y "$DISPATCH_MARKER" 2>/dev/null) || return 0
  fi
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  wall=$(persisted_wall_seconds)
  [ $((now - mtime)) -gt $((wall + 300)) ] || return 0
  echo "cloud-crewmate $ID: dispatch claim is stale (no result after its bounded wall); reclaiming"
  rm -f "$DISPATCH_MARKER"
}

# account_directory_is_single_slot: the staged account directory holds exactly
# one provider slot, which is the only shape that may ride to a worker.
# A pooled directory would hand every signed-in account to the guest and let pi
# resolve the first slot - a shared-account placement whatever the queue says.
# The spawn writes this directory exactly once, from the single account the
# controller leased; this monitor outlives the spawn and dispatches on its own,
# so the shape is re-checked at the point of USE and not only where it is written.
account_directory_is_single_slot() {
  python3 - "$STATE/$ID.cloud-account/auth.json" <<'ACCOUNTSLOTS'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        parsed = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(parsed, dict) and len(parsed) == 1 else 1)
ACCOUNTSLOTS
}
dispatch_converged_execute() {
  local assignment
  # BEFORE the claim, deliberately. The claim is the exactly-once marker shared
  # with the spawn: standing down after taking it would leave both owners
  # believing the other dispatched, and nothing ever would. An account
  # directory that is not yet the leased single account means the spawn has not
  # finished narrowing it, so this poll simply does not claim and the next one
  # retries.
  if [ -d "$STATE/$ID.cloud-account" ] && ! account_directory_is_single_slot; then
    echo "cloud-crewmate $ID: staged account directory is not one leased provider slot yet; not dispatching this poll"
    return 0
  fi
  # Claim first (O_EXCL): if the spawn process already dispatched, or a prior
  # monitor iteration did, stand down. The whole dispatch runs in a subshell
  # so the sourced persisted environment never leaks into the monitor loop.
  (set -C; : > "$DISPATCH_MARKER") 2>/dev/null || return 0
  assignment=$(assignment_generation) || assignment=
  if [ -z "$assignment" ]; then
    rm -f "$DISPATCH_MARKER"
    return 0
  fi
  (
    entry=$(cat "$ENTRYPOINT" 2>/dev/null) || entry=
    if [ -z "$entry" ]; then
      echo "cloud-crewmate $ID: assigned but the persisted entrypoint is empty; not dispatching"
      rm -f "$DISPATCH_MARKER"
      exit 0
    fi
    # The persisted environment carries the allowlisted FM_AZURE_* identity
    # (and optional provider-command override) the spawn ran with; the Herdr
    # server's closed pane environment has neither.
    # shellcheck source=/dev/null
    . "$CLOUD_ENV" 2>/dev/null || true
    wall=${FM_SPAWN_CLOUD_WALL_SECONDS:-3600}
    case "$wall" in ''|*[!0-9]*) wall=3600 ;; esac
    echo "cloud-crewmate $ID: reconcile converged assignment $assignment; dispatching bounded execute"
    payload_args=()
    if [ -d "$STATE/$ID.cloud-payload" ] && [ -d "$STATE/$ID.cloud-account" ]; then
      payload_args=(--payload-dir "$STATE/$ID.cloud-payload" --account-dir "$STATE/$ID.cloud-account")
      # A staged repository means a landing task. Dropping --outcome-dir here
      # because a pre-D5 spawn left no directory would silently downgrade it
      # to fire-and-forget, which is exactly what the digest-bound
      # outcome_expected exists to prevent; create the directory instead.
      install -d -m 0700 "$STATE/$ID.cloud-outcome" 2>/dev/null || true
      payload_args+=(--outcome-dir "$STATE/$ID.cloud-outcome")
      case "${FM_SPAWN_CLOUD_RETURN_KIND:-}" in
        ship|scout) payload_args+=(--return-kind "$FM_SPAWN_CLOUD_RETURN_KIND") ;;
      esac
    fi
    nohup env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-worker-lifecycle.sh" execute \
      --task "$ID" --task-generation "$GENERATION" \
      --assignment-generation "$assignment" --wall-seconds "$wall" \
      ${payload_args[@]+"${payload_args[@]}"} \
      --confirm-execute --confirm-subscription "${FM_AZURE_SUBSCRIPTION_ID:-}" \
      -- /bin/bash -lc "$entry" \
      > "$RESULT" 2> "$EXEC_LOG" < /dev/null &
  )
}

result_field() {
  python3 - "$RESULT" "$1" <<'PY'
import json
import sys

path, field = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        result = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
value = result.get(field)
if isinstance(value, bool):
    print("1" if value else "")
elif value is not None:
    print(value)
PY
}

finalize_authorized_return() {
  local assignment status proof lifecycle
  assignment=$(result_field assignment_generation)
  [ -n "$assignment" ] || {
    echo "cloud-crewmate $ID: authorized return has no assignment generation"
    return 1
  }
  if ! python3 "$SCRIPT_DIR/fm-cloud-result.py" collect \
    --state "$STATE" --task "$ID" --task-generation "$GENERATION" \
    --assignment-generation "$assignment"; then
    echo "cloud-crewmate $ID: authorized return is not in local custody yet; retaining the assignment for retry"
    return 1
  fi
  lifecycle=${FM_CLOUD_RETURN_LIFECYCLE_COMMAND:-$SCRIPT_DIR/fm-worker-lifecycle.sh}
  status=$(queue_status)
  proof=$STATE/$ID.worker-release.json
  case "$status" in
    assigned)
      if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$lifecycle" authority-receipt \
        --task "$ID" --task-generation "$GENERATION" \
        --assignment-generation "$assignment" --output "$proof"; then
        echo "cloud-crewmate $ID: local custody is established but release authority is not ready; retrying"
        return 1
      fi
      if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$lifecycle" release \
        --task "$ID" --task-generation "$GENERATION" --proof-file "$proof"; then
        echo "cloud-crewmate $ID: local custody is established but release recording failed; retrying"
        return 1
      fi
      status=releasing
      ;;
    releasing) : ;;
    complete)
      fm_cloud_state_remove "$STATE" "$ID"
      echo "cloud-crewmate $ID: return is local and the worker assignment is released"
      return 0
      ;;
    *)
      echo "cloud-crewmate $ID: return is local but controller status is '$status'; retaining artifacts for retry"
      return 1
      ;;
  esac
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$lifecycle" reconcile --apply \
    --confirm-subscription "${FM_AZURE_SUBSCRIPTION_ID:-}" >/dev/null; then
    echo "cloud-crewmate $ID: worker release convergence failed; retrying without replaying the task"
    return 1
  fi
  status=$(queue_status)
  if [ "$status" != complete ]; then
    echo "cloud-crewmate $ID: worker release is '$status'; retrying until account and capacity are free"
    return 1
  fi
  fm_cloud_state_remove "$STATE" "$ID"
  echo "cloud-crewmate $ID: return is local and the worker assignment is released"
  return 0
}

land_outcome_bundle() {
  # Landing v1: the crewmate committed on the worker's copy of the leased
  # worktree and the bundle came home digest-verified. The landing authority
  # stays local, so all that happens here is a fast-forward of the same branch
  # the bundle was cut from; the ordinary landing flow (push, PR, teardown's
  # landed-work check) then proceeds unchanged.
  local bundle wt base head error tip
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$RESULT" 2>/dev/null; then
    # A refusal string or a torn write is not a result. Say so: silence here
    # would be indistinguishable from a task that simply had nothing to land.
    echo "cloud-crewmate $ID: worker result is not readable as a bound result; no outcome landing attempted"
    [ ! -s "$STATE/$ID.cloud-outcome/outcome.bundle" ] \
      || echo "cloud-crewmate $ID: a verified outcome bundle is waiting at $STATE/$ID.cloud-outcome/outcome.bundle"
    return 0
  fi
  error=$(result_field outcome_error)
  # Reported, but never a reason to discard work that did arrive: a failure in
  # one arm of the run (stream evidence, say) must not throw away a bundle the
  # controller already downloaded and verified.
  [ -z "$error" ] || echo "cloud-crewmate $ID: worker reported a failure during collection: $error"
  if [ -z "$(result_field outcome_present)" ]; then
    # A landing task that returns nothing is worth one line either way: the
    # operator otherwise cannot tell "read-only task" from "the crewmate
    # edited files and never committed them", and the second loses work.
    if [ -n "$(result_field outcome_uncommitted_changes)" ]; then
      echo "cloud-crewmate $ID: crewmate left uncommitted changes and returned no commits; nothing was landed"
    else
      echo "cloud-crewmate $ID: crewmate returned no commits; nothing to land"
    fi
    return 0
  fi
  bundle=$STATE/$ID.cloud-outcome/outcome.bundle
  if [ ! -s "$bundle" ]; then
    echo "cloud-crewmate $ID: result claims an outcome but no verified bundle landed locally"
    return 0
  fi
  wt=$(cat "$STATE/$ID.cloud-worktree" 2>/dev/null) || wt=
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "cloud-crewmate $ID: outcome bundle is at $bundle but the leased worktree is gone; landing skipped"
    return 0
  fi
  base=$(result_field repository_generation)
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head=
  if [ -z "$base" ] || [ -z "$head" ]; then
    echo "cloud-crewmate $ID: cannot read the leased worktree head; outcome kept at $bundle for manual landing"
    return 0
  fi
  if [ "$head" != "$base" ]; then
    # Already landed, or genuinely diverged. Only the bundle's own tip can
    # tell them apart, and reporting divergence for work we already landed
    # would send the operator hunting for nothing.
    tip=$(git -C "$wt" bundle list-heads "$bundle" 2>/dev/null | head -1)
    tip=${tip%% *}
    if [ -n "$tip" ] && git -C "$wt" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
      echo "cloud-crewmate $ID: outcome already landed in $wt"
      return 0
    fi
    echo "cloud-crewmate $ID: local worktree moved off $base since dispatch; outcome kept at $bundle for manual landing"
    return 0
  fi
  # Untracked files cannot conflict with a fast-forward; only tracked-tree
  # changes are a reason to refuse one.
  if [ -n "$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "cloud-crewmate $ID: local worktree has uncommitted changes; outcome kept at $bundle for manual landing"
    return 0
  fi
  if ! git -C "$wt" fetch --quiet "$bundle" HEAD 2>&1; then
    echo "cloud-crewmate $ID: outcome bundle could not be fetched into $wt; kept at $bundle"
    return 0
  fi
  if ! git -C "$wt" merge --ff-only FETCH_HEAD 2>&1; then
    echo "cloud-crewmate $ID: outcome bundle is not a fast-forward of $base; kept at $bundle"
    return 0
  fi
  echo "cloud-crewmate $ID: landed $(result_field outcome_commits) commit(s) into $wt"
}

shown_bytes=0
while :; do
  if [ -s "$RESULT" ]; then
    echo "cloud-crewmate $ID: worker result landed"
    python3 -m json.tool "$RESULT" 2>/dev/null | head -40 || cat "$RESULT"
    if [ -n "$(result_field return_present)" ]; then
      if finalize_authorized_return; then
        exit 0
      fi
      sleep "$INTERVAL"
      continue
    fi
    land_outcome_bundle
    exit 0
  fi
  status=$(queue_status)
  printf '%s cloud-crewmate %s worker=%s\n' "$(date -u +%H:%M:%SZ)" "$ID" "$status"
  if [ "$status" = assigned ]; then
    reclaim_stale_dispatch
    if [ ! -f "$DISPATCH_MARKER" ] && [ -f "$ENTRYPOINT" ] && [ -f "$CLOUD_ENV" ]; then
      dispatch_converged_execute
    fi
  fi
  if [ -f "$EXEC_LOG" ]; then
    size=$(wc -c < "$EXEC_LOG" 2>/dev/null | tr -d '[:space:]')
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -lt "$shown_bytes" ]; then
      # A redispatch truncated the log; start rendering it from the top.
      shown_bytes=0
    fi
    if [ "$size" -gt "$shown_bytes" ]; then
      tail -c +"$((shown_bytes + 1))" "$EXEC_LOG" 2>/dev/null
      shown_bytes=$size
    fi
  fi
  sleep "$INTERVAL"
done

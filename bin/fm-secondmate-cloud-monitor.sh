#!/usr/bin/env bash
# Compartment monitor for one cloud-placed secondmate (R2/R3 design C item 4).
#
# The secondmate agent process runs on an elastic Azure worker as a chain of
# bounded session legs (bin/fm-secondmate-session.py); the durable secondmate
# home stays on this machine. This monitor is the local owner of that chain:
#
#   - LEG DISPATCH: it dispatches every leg through the bounded lifecycle
#     execute, claiming a per-leg O_EXCL marker first (the discipline shared
#     with bin/fm-spawn-cloud-monitor.sh) so a crashed and respawned monitor
#     never double-dispatches a leg. Leg 1 carries the payload+account
#     staging pair; legs 2+ carry NEITHER manifest, hitting the supervisor's
#     verified staging-skip branch - a leg 2+ request with manifests would
#     rmtree the compartment's repository and reset its auth projection, so
#     the manifest-free shape is a structural invariant here, pinned by a
#     golden argv test.
#   - INBOUND RELAY: fm-send routes captain text for a cloud secondmate into
#     state/<id>.cloud-inbox/<seq>-<sha256>.json envelopes; this monitor
#     relays each file verbatim through the claim-exempt `message-put`
#     (content-addressed and idempotent, so a replayed relay is a no-op).
#   - OUTBOUND COLLECT + CHAIN VERIFICATION: it polls `message-collect` into
#     state/<id>.cloud-mailbox using the collect summary's cursor, then runs
#     bin/fm-secondmate-cloud-monitor.py, the chain authority: any gap,
#     reorder, or tamper refuses the WHOLE mailbox, writes a sticky
#     .chain-break marker, and freezes relay in both directions until an
#     operator investigates. Verified replies render into this pane;
#     verified leg-summary bundle declarations land into the local home
#     worktree by fast-forward only, else the bundle is kept and reported.
#   - CHILD RELAY: verified child-spawn and attach requests land under
#     state/<id>.cloud-childreq/ and are validated, spent, or refused by
#     bin/fm-secondmate-cloud-monitor.py child-relay (design B.5 steps 2-5).
#     An invalid request never reaches command_request; its refusal names the
#     exact failed check and is DELIVERED into this compartment's own inbox,
#     so a resend is a loud duplicate rather than a hopeful retry. A valid one
#     spawns through the ordinary lane as the secondmate, carrying the parent
#     pair, so the controller's bounds apply; an admission refusal round-trips
#     the same way. Child terminal status and requested delta bundles come
#     back through the inbox too.
#   - LEG LIFECYCLE: when a leg's execute returns, the verified leg summary
#     decides: reason=wall renews (next manifest-free leg, O_EXCL-guarded,
#     refused past FM_SECONDMATE_TTL_HOURS from first dispatch);
#     reason=close or idle ends the chain with a terminal status file.
#     Release is deliberately NOT performed here - closeout and release
#     receipts are operator work (design C item 6). The TTL is renewal-gated
#     only: the last admitted leg still runs to its wall, so the compute
#     overrun bound is FM_SECONDMATE_TTL_HOURS plus one wall
#     (leg_seconds + 1800), never an unbounded chain.
#
# Local-state fragility, named: losing state/<id>.cloud-inbox/.claims/
# re-anchors fm-send sequencing at 1 (old and new envelopes coexist under
# distinct content-addressed names, so nothing is lost or deduped away, but
# relay ordering between them is approximate) and losing the first-dispatch
# file re-anchors the TTL clock at the next dispatch. Recovery for anything
# worse is the sticky chain-break marker and the reclaim refusal above:
# loud stops, never silent repair.
#
# wall_seconds arithmetic (the runner's documented monitor contract): the
# runner leaves its poll loop at leg_seconds minus min(300, leg/10) and its
# finish-leg (bundle + summary upload) can spend up to 600s of git bundling
# plus 600s of blob PUT after that, so the supervisor wall must be at least
# leg_seconds + 900; this monitor grants leg_seconds + 1800 (the requirement
# plus equal slack) and therefore refuses leg_seconds above 19800 so the
# wall always fits the pinned supervisor's 21600 MAX_WALL_SECONDS ceiling.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ID=${1:?task id}
GENERATION=${2:?task generation id}
FM_HOME=${FM_HOME:?FM_HOME is required}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONTROLLER=$STATE/azure-workers/controller.json
CLOUD_ENV=$STATE/$ID.cloud-env
PAYLOAD_DIR=$STATE/$ID.cloud-payload
ACCOUNT_DIR=$STATE/$ID.cloud-account
WORKTREE_FILE=$STATE/$ID.cloud-worktree
INBOX=$STATE/$ID.cloud-inbox
RELAYED=$INBOX/.relayed
MAILBOX=$STATE/$ID.cloud-mailbox
CHILDREQ=$STATE/$ID.cloud-childreq
CHAIN_BREAK=$MAILBOX/.chain-break
STATE_FILE=$STATE/$ID.cloud-secondmate-state.json
STATUS_FILE=$STATE/$ID.cloud-secondmate-status
FIRST_DISPATCH=$STATE/$ID.cloud-secondmate-first-dispatch
CURSOR_FILE=$STATE/$ID.cloud-collect-cursor
HELPER=$SCRIPT_DIR/fm-secondmate-cloud-monitor.py
# The lifecycle and spawn seams exist for the hermetic tests (fixture CLIs
# capturing argv and returning canned JSON); operation always uses the sibling
# wrappers.
LIFECYCLE=${FM_SECONDMATE_LIFECYCLE_BIN:-$SCRIPT_DIR/fm-worker-lifecycle.sh}
SPAWN=${FM_SECONDMATE_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}

INTERVAL=${FM_SECONDMATE_MONITOR_INTERVAL_SECONDS:-15}
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=15 ;; esac

# The finish-leg budget this monitor grants beyond leg_seconds (see the
# header arithmetic), and the ceiling that keeps wall under the pinned
# supervisor's MAX_WALL_SECONDS=21600.
FINISH_LEG_BUDGET_SECONDS=1800
MAX_LEG_SECONDS=19800

persisted_env_value() {  # <name> [default]
  local name=$1 fallback=${2:-} value
  value=$(sed -n "s/^export $name=//p" "$CLOUD_ENV" 2>/dev/null | head -1)
  [ -n "$value" ] || value=$(eval "printf '%s' \"\${$name:-}\"")
  [ -n "$value" ] || value=$fallback
  printf '%s\n' "$value"
}

numeric_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

LEG_SECONDS=$(numeric_or "$(persisted_env_value FM_SECONDMATE_LEG_SECONDS)" 14400)
POLL_SECONDS=$(numeric_or "$(persisted_env_value FM_SECONDMATE_POLL_SECONDS)" 10)
IDLE_SECONDS=$(numeric_or "$(persisted_env_value FM_SECONDMATE_IDLE_SECONDS)" 7200)
TTL_HOURS=$(numeric_or "$(persisted_env_value FM_SECONDMATE_TTL_HOURS)" 72)
if [ "$LEG_SECONDS" -gt "$MAX_LEG_SECONDS" ]; then
  echo "error: FM_SECONDMATE_LEG_SECONDS=$LEG_SECONDS cannot fit its finish-leg budget (${FINISH_LEG_BUDGET_SECONDS}s) under the supervisor wall ceiling (21600s); the maximum is $MAX_LEG_SECONDS" >&2
  exit 1
fi
WALL_SECONDS=$((LEG_SECONDS + FINISH_LEG_BUDGET_SECONDS))

queue_snapshot() {
  # status <tab> assignment <tab> slot <tab> repository_generation
  python3 - "$CONTROLLER" "$ID" "$GENERATION" <<'PY'
import json
import sys

path, task, generation = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    print("controller-unreadable\t\t\t")
    raise SystemExit(0)
item = (state.get("queue") or {}).get("{}@{}".format(task, generation)) or {}
status = item.get("status") or "unqueued"
assignment = ""
slot = ""
repo = ""
if status == "assigned" and item.get("assignment_generation"):
    assignment = item["assignment_generation"]
    slot = str(item.get("slot", ""))
    worker = (state.get("workers") or {}).get(slot) or {}
    repo = (worker.get("bindings") or {}).get("repository_generation", "")
print("{}\t{}\t{}\t{}".format(status, assignment, slot, repo))
PY
}

state_field() {  # <field>
  python3 - "$STATE_FILE" "$1" <<'PY'
import json
import sys

path, field = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as handle:
        state = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
value = state.get("last_summary") or {}
value = value.get(field)
if value is not None:
    print(value)
PY
}

leg_count() {
  local count=0 marker
  for marker in "$STATE/$ID".cloud-secondmate-leg-*.dispatched; do
    [ -e "$marker" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

leg_marker() { printf '%s\n' "$STATE/$ID.cloud-secondmate-leg-$(printf '%04d' "$1").dispatched"; }
leg_result() { printf '%s\n' "$STATE/$ID.cloud-secondmate-leg-$(printf '%04d' "$1").result.json"; }
leg_log() { printf '%s\n' "$STATE/$ID.cloud-secondmate-leg-$(printf '%04d' "$1").log"; }

reclaim_stale_leg() {  # <n> <current-assignment>
  # Same reclaim rule as the crewmate monitor: a held marker whose bounded
  # execute is provably over (older than wall plus slack) with no result was
  # a dead dispatcher; the lifecycle execute is digest-idempotent, so
  # releasing the claim and redispatching the SAME request is safe.
  #
  # EXCEPT for a manifest-carrying leg whose worker assignment has MOVED
  # since the claim (a resume replaces the VM and OS disk and mints a new
  # assignment generation, destroying the guest's executed marker while the
  # retained task disk keeps the mid-leg commits): the redispatch would be a
  # NEW request digest still carrying --payload-dir/--account-dir, the
  # supervisor would re-stage, and stage_payload's rmtree would erase those
  # retained commits. The marker records the assignment it was claimed
  # under; a mismatch on a manifest-carrying leg refuses to auto-redispatch,
  # loudly, and leaves the claim held for an operator. A legacy marker with
  # no recorded assignment fails closed the same way.
  local n=$1 current=$2 marker result mtime now recorded
  marker=$(leg_marker "$n")
  result=$(leg_result "$n")
  [ -f "$marker" ] || return 0
  [ ! -s "$result" ] || return 0
  # Portable epoch mtime, branched on uname like bin/fm-lock-lib.sh. A
  # BSD-first `stat -f %m || stat -c %Y` chain is broken on GNU: -f selects a
  # filesystem-format mode taking no format operand, so %m becomes a second
  # file operand, the filesystem block is printed into the captured
  # substitution before the fallback runs, and the numeric guard below reads
  # the mixture as "not a number" and bails forever.
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$marker" 2>/dev/null) || return 0
  else
    mtime=$(stat -c %Y "$marker" 2>/dev/null) || return 0
  fi
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ $((now - mtime)) -gt $((WALL_SECONDS + 300)) ] || return 0
  if [ "$n" -eq 1 ] && [ -f "$FIRST_DISPATCH" ]; then
    recorded=$(head -1 "$marker" 2>/dev/null) || recorded=
    if [ "$recorded" != "$current" ]; then
      echo "secondmate $ID: REFUSING to reclaim the stale leg $n claim: it was dispatched under assignment '${recorded:-unrecorded}' but the worker is now '$current' (a resume moved the assignment); a manifest-carrying redispatch would re-stage and rmtree the retained task disk's mid-leg commits. Operator recovery required (collect the retained disk before any re-staging)."
      return 0
    fi
  fi
  echo "secondmate $ID: leg $n dispatch claim is stale (no result after its bounded wall); reclaiming"
  rm -f "$marker"
}

ttl_exhausted() {
  local first now
  first=$(cat "$FIRST_DISPATCH" 2>/dev/null) || return 1
  case "$first" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - first)) -ge $((TTL_HOURS * 3600)) ]
}

dispatch_leg() {  # <n> <assignment> <slot> <repo-generation>
  local n=$1 assignment=$2 slot=$3 repo_generation=$4 marker result log
  marker=$(leg_marker "$n")
  result=$(leg_result "$n")
  log=$(leg_log "$n")
  if [ "$n" -eq 1 ]; then
    if [ ! -d "$PAYLOAD_DIR" ] || [ ! -d "$ACCOUNT_DIR" ]; then
      echo "secondmate $ID: leg 1 staging pair is missing ($PAYLOAD_DIR / $ACCOUNT_DIR); not dispatching"
      return 0
    fi
  fi
  # Claim first (O_EXCL): exactly one owner dispatches a leg, ever. The
  # marker body records the assignment generation the claim was made under,
  # so a later reclaim can tell "same worker, replay is digest-idempotent"
  # from "assignment moved, a manifest-carrying redispatch would rmtree the
  # retained task disk" (see reclaim_stale_leg).
  (set -C; printf '%s\n' "$assignment" > "$marker") 2>/dev/null || return 0
  [ -f "$FIRST_DISPATCH" ] || date +%s > "$FIRST_DISPATCH"
  echo "secondmate $ID: dispatching session leg $n (wall ${WALL_SECONDS}s = leg ${LEG_SECONDS}s + finish-leg budget ${FINISH_LEG_BUDGET_SECONDS}s)"
  (
    # The persisted environment carries the allowlisted FM_AZURE_* identity
    # (and optional provider-command override); the pane environment is
    # closed. Sourced in this subshell only.
    # shellcheck source=/dev/null
    . "$CLOUD_ENV" 2>/dev/null || true
    container=$(printf 'worker-state-%02d' "$slot")
    # The FM_SECONDMATE_LEG=<n> prefix is a per-leg distinguisher: the
    # lifecycle dedupes executes by request digest, so without it leg n+1's
    # manifest-free request would be byte-identical to leg n's and would
    # replay its recorded result instead of running.
    entry="FM_SECONDMATE_LEG=$n python3 /mnt/task/.fm-task/fm-secondmate-session.py"
    entry="$entry --task $ID --task-generation $GENERATION"
    entry="$entry --assignment-generation $assignment"
    entry="$entry --repository-generation $repo_generation"
    entry="$entry --pi-ext /mnt/task/.fm-task/fm-secondmate-spawn.pi-ext.ts"
    entry="$entry --storage-account ${FM_AZURE_STORAGE_NAME:-} --container $container"
    entry="$entry --leg-seconds $LEG_SECONDS --poll-seconds $POLL_SECONDS --idle-seconds $IDLE_SECONDS"
    staging_args=()
    if [ "$n" -eq 1 ]; then
      # Leg 1 only: the D2 staging pair (repo bundle + runner + pi extension
      # + brief; pi auth projection). Legs 2+ MUST stay manifest-free - the
      # supervisor's staging-skip branch is what preserves the compartment's
      # repository and auth projection across legs (the rmtree guard).
      staging_args=(--payload-dir "$PAYLOAD_DIR" --account-dir "$ACCOUNT_DIR")
    fi
    nohup env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$LIFECYCLE" execute \
      --task "$ID" --task-generation "$GENERATION" \
      --assignment-generation "$assignment" --wall-seconds "$WALL_SECONDS" \
      ${staging_args[@]+"${staging_args[@]}"} \
      --confirm-execute --confirm-subscription "${FM_AZURE_SUBSCRIPTION_ID:-}" \
      -- /bin/bash -lc "$entry" \
      > "$result" 2> "$log" < /dev/null &
  )
}

relay_inbox() {  # <assignment>
  local assignment=$1 file base output
  [ -d "$INBOX" ] || return 0
  mkdir -p "$RELAYED" 2>/dev/null || true
  for file in "$INBOX"/*.json; do
    [ -e "$file" ] || continue
    base=${file##*/}
    [ ! -e "$RELAYED/$base" ] || continue
    if output=$(
      # shellcheck source=/dev/null
      . "$CLOUD_ENV" 2>/dev/null || true
      env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$LIFECYCLE" message-put \
        --task "$ID" --task-generation "$GENERATION" \
        --assignment-generation "$assignment" --file "$file" 2>&1
    ); then
      # The relay receipt is durable and per-envelope; message-put itself is
      # content-addressed, so a receipt lost to a crash only costs a
      # harmless replayed=true put on the next pass.
      printf '%s\n' "$output" > "$RELAYED/$base"
      echo "secondmate $ID: relayed captain message $base"
    else
      echo "warning: secondmate $ID relay failed for $base: $output"
    fi
  done
}

collect_mailbox() {  # <assignment>
  local assignment=$1 after cursor more output rounds=0
  mkdir -p "$MAILBOX" 2>/dev/null || true
  after=$(cat "$CURSOR_FILE" 2>/dev/null) || after=
  while :; do
    output=$(
      # shellcheck source=/dev/null
      . "$CLOUD_ENV" 2>/dev/null || true
      set -- message-collect \
        --task "$ID" --task-generation "$GENERATION" \
        --assignment-generation "$assignment" --output-dir "$MAILBOX"
      [ -z "$after" ] || set -- "$@" --after "$after"
      env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$LIFECYCLE" "$@" 2>&1
    ) || {
      echo "warning: secondmate $ID message collect failed: $output"
      return 0
    }
    # Defensive against both collect summary shapes: cursor/more are read
    # when present (the paginated interface) and treated as absent/false on
    # an older summary that lacks them.
    cursor=$(printf '%s\n' "$output" | python3 -c 'import json,sys
try:
    value = json.loads(sys.stdin.read() or "{}")
except ValueError:
    raise SystemExit(0)
cursor = value.get("cursor")
if isinstance(cursor, str) and cursor:
    print(cursor)') || cursor=
    more=$(printf '%s\n' "$output" | python3 -c 'import json,sys
try:
    value = json.loads(sys.stdin.read() or "{}")
except ValueError:
    raise SystemExit(0)
if value.get("more") is True:
    print(1)') || more=
    if [ -n "$cursor" ]; then
      printf '%s\n' "$cursor" > "$CURSOR_FILE"
      after=$cursor
    fi
    [ "$more" = 1 ] || break
    rounds=$((rounds + 1))
    [ "$rounds" -lt 16 ] || break
  done
}

process_mailbox() {
  local worktree
  worktree=$(cat "$WORKTREE_FILE" 2>/dev/null) || worktree=
  python3 "$HELPER" process-mailbox \
    --task "$ID" --mailbox "$MAILBOX" --state-file "$STATE_FILE" \
    --worktree "$worktree" --childreq "$CHILDREQ"
  # Exit 3 (chain break) already rendered its loud refusal; the sticky
  # marker freezes relay in both directions from the next loop check.
  return 0
}

child_relay() {  # <assignment>
  # Design B.5 steps 2-5. Only requests the chain verifier already accepted
  # reach here (process_mailbox lands them and acts on none), and only this
  # pass validates them, spends anything, or answers. Refusals and
  # announcements are written as ordinary inbox envelopes, so the relay below
  # carries them to the compartment on this same iteration.
  local assignment=$1 worktree
  [ -d "$CHILDREQ" ] || return 0
  worktree=$(cat "$WORKTREE_FILE" 2>/dev/null) || worktree=
  if [ -z "$worktree" ]; then
    echo "warning: secondmate $ID: no recorded secondmate home; child requests cannot be relayed"
    return 0
  fi
  (
    # The persisted environment carries the allowlisted FM_AZURE_* identity
    # the child's own request needs; sourced in this subshell only.
    # shellcheck source=/dev/null
    . "$CLOUD_ENV" 2>/dev/null || true
    python3 "$HELPER" child-relay \
      --task "$ID" --task-generation "$GENERATION" \
      --assignment-generation "$assignment" \
      --childreq "$CHILDREQ" --inbox "$INBOX" \
      --spawn-home "$FM_HOME" --home "$worktree" \
      --controller "$CONTROLLER" \
      --spawn-bin "$SPAWN" --lifecycle-bin "$LIFECYCLE"
  ) || echo "warning: secondmate $ID: the child relay pass refused (see above)"
  return 0
}

finish_terminal() {  # <reason>
  printf '%s\n' "$1" > "$STATUS_FILE"
  echo "secondmate $ID: session chain ended ($1); leg dispatch stopped. Release/closeout stays operator work - the compartment worker is still reserved until released."
}

leg_lifecycle() {  # <assignment> <slot> <repo-generation>
  local assignment=$1 slot=$2 repo_generation=$3 legs result reason completed
  legs=$(leg_count)
  if [ "$legs" -eq 0 ]; then
    dispatch_leg 1 "$assignment" "$slot" "$repo_generation"
    return 0
  fi
  result=$(leg_result "$legs")
  if [ ! -s "$result" ]; then
    reclaim_stale_leg "$legs" "$assignment"
    return 0
  fi
  reason=$(state_field reason)
  completed=$(state_field legs_completed)
  case "$completed" in ''|*[!0-9]*) completed=0 ;; esac
  if [ "$completed" -lt "$legs" ]; then
    echo "secondmate $ID: leg $legs execute returned but its verified leg summary has not been collected; renewal withheld until the chain shows it"
    return 0
  fi
  case "$reason" in
    wall)
      if ttl_exhausted; then
        echo "secondmate $ID: TTL of ${TTL_HOURS}h from first dispatch is exhausted; refusing to renew the session chain"
        finish_terminal ttl-exhausted
        return 1
      fi
      dispatch_leg $((legs + 1)) "$assignment" "$slot" "$repo_generation"
      ;;
    close)
      finish_terminal closed
      return 1
      ;;
    idle)
      finish_terminal idle
      return 1
      ;;
    *)
      echo "secondmate $ID: leg $legs summary carries unrecognized reason '${reason:-}'; renewal withheld"
      ;;
  esac
  return 0
}

shown_bytes=0
shown_leg=0
render_leg_log() {
  local legs log size
  legs=$(leg_count)
  [ "$legs" -gt 0 ] || return 0
  if [ "$legs" -ne "$shown_leg" ]; then
    shown_leg=$legs
    shown_bytes=0
  fi
  log=$(leg_log "$legs")
  [ -f "$log" ] || return 0
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -lt "$shown_bytes" ]; then
    shown_bytes=0
  fi
  if [ "$size" -gt "$shown_bytes" ]; then
    tail -c +"$((shown_bytes + 1))" "$log" 2>/dev/null
    shown_bytes=$size
  fi
}

while :; do
  if [ -f "$STATUS_FILE" ]; then
    echo "secondmate $ID: terminal status: $(cat "$STATUS_FILE" 2>/dev/null)"
    exit 0
  fi
  snapshot=$(queue_snapshot)
  status=${snapshot%%$'\t'*}
  rest=${snapshot#*$'\t'}
  assignment=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  slot=${rest%%$'\t'*}
  repo_generation=${rest#*$'\t'}
  printf '%s secondmate %s worker=%s legs=%s\n' "$(date -u +%H:%M:%SZ)" "$ID" "$status" "$(leg_count)"
  if [ -f "$CHAIN_BREAK" ]; then
    echo "secondmate $ID: OUTBOX CHAIN BREAK recorded at $CHAIN_BREAK; relay frozen in both directions until an operator investigates (files retained)"
  elif [ "$status" = assigned ] && [ -n "$assignment" ]; then
    collect_mailbox "$assignment"
    process_mailbox
    # The child relay runs BEFORE the outbound relay so a refusal, an
    # acceptance, an attach announcement or a child's terminal status written
    # this iteration reaches the compartment on this iteration - a delivered
    # refusal the agent waits a whole interval for reads like a lost message.
    child_relay "$assignment"
    relay_inbox "$assignment"
    if ! leg_lifecycle "$assignment" "$slot" "$repo_generation"; then
      render_leg_log
      exit 0
    fi
  fi
  render_leg_log
  sleep "$INTERVAL"
done

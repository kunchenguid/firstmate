#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         (--note <text> | --note-file <path>)
#                                         [--dispatch-resolved | --dispatch-override-reason <why>]
#                                         [--quota-fallback]
#
# Why this exists, and how it differs from fm-send.sh. bin/fm-send.sh is the
# DATA plane: conversational text for the agent to read, always routing-marked
# for a kind=secondmate target so the reply returns through the status path.
# That marking is right for a message and wrong for a lifecycle command - a
# marked "/quit" arrives as ordinary chat the agent reasons ABOUT instead of
# executing. This script is the control plane: semantic process control with a
# closed verb list, per-harness mechanics owned by an executable adapter
# (bin/fm-control-lib.sh) rather than improvised in agent prose, and a verified
# postcondition for every action. There is deliberately NO arbitrary-text and
# NO generic raw-key entry point here; fm-send remains the only way to send an
# agent something to read.
#
#   interrupt  Deliver the harness's verified interrupt sequence. The agent
#              keeps running. Postcondition: delivery succeeded, the endpoint
#              still exists, and the agent is still alive where the backend can
#              classify that. Cancellation is confirmed only from an adapter-
#              owned acknowledgement and otherwise reported unconfirmed. Busy
#              state is never rewritten as proof of the action.
#   exit       Stop the agent, preserving its terminal endpoint, worktree, and
#              every uncommitted change. Interrupts first when the task reads
#              busy, then submits the harness's exit command. Postcondition:
#              the backend's recovery-grade classifier reports the agent gone.
#              Already-stopped is success (idempotent).
#   relaunch   Transactionally replace the running agent with a new one, in the
#              SAME endpoint and SAME worktree, on the same or a newly chosen
#              harness/model/effort - so switching harness is one ordinary use
#              of this verb. An explicit `default` model or effort clears that
#              axis for the replacement. With no explicit axis, a secondmate
#              re-resolves its durable config/secondmate-harness pin (harness
#              plus its optional model and effort tokens) exactly as any other
#              respawn does, while a ship or scout keeps the exact adapter
#              already recorded for it.
#              A prefixed raw-command basename cannot reconstruct its launch
#              command, so relaunch requires an explicit --harness for it.
#              --note is required for a ship or scout, whose replacement
#              inherits the local copy but none of the conversation; a
#              secondmate reconciles its own home's records at startup, so its
#              standing charter is never rewritten.
#              When config/crew-dispatch.json is active, relaunch forwards
#              --dispatch-resolved or --dispatch-override-reason to
#              bin/fm-spawn.sh --relaunch (the same attestation a fresh spawn
#              needs). --quota-fallback picks the next same-class profile from
#              that file that bin/fm-quota-cooldown.sh authorize still allows,
#              generates the progress note from the last 5 status lines plus
#              git status --short and git log --oneline -3 of the recorded
#              worktree, and attests --dispatch-resolved. When matched_rule is
#              absent (an override), it recovers the class array from the
#              recorded profile plus the task's repo and records that rule.
#              It lifts an operational backlog hold (kind external or parked)
#              before relaunch and restores it if launch fails. It refuses
#              before stopping the agent when no eligible profile remains.
#              Records a durable checkpoint and that note, exits the old agent,
#              then delegates the launch to its single owner,
#              bin/fm-spawn.sh --relaunch. A failure before publication keeps
#              the prior durable record in place and reports the concrete
#              state; it never leaves a half-transitioned task claiming to be
#              running.
#
# Teardown and discard are NOT verbs here and never will be. `exit` stops an
# agent and preserves everything else; removing a worktree, killing an
# endpoint, or discarding work stays with bin/fm-teardown.sh, which owns the
# landed-work test.
#
# `resume` is not a verb: it is not deterministic across the verified adapters
# (bin/fm-control-lib.sh's header owns that reasoning). `relaunch` covers the
# same need for every adapter because the brief on disk, not a harness-private
# session, is the durable instruction.
#
# Targeting is EXACT: only a bare task id with a state/<id>.meta record in
# THIS home is accepted, and the record must pass the shared endpoint-identity
# validation (bin/fm-backend.sh's fm_backend_validate_task_endpoint). A legacy
# fm-<id> label, an explicit session:window endpoint, and a bare window name
# are all refused - a lifecycle command delivered to the wrong endpoint is far
# worse than a loud refusal.
#
# A remotely placed secondmate is refused by name: its agent runs on another
# host, so no postcondition this plane verifies could be read for it here.
#
# Fail-closed boundaries:
#   - An unverified harness, or a harness whose control mechanics are unknown,
#     is refused rather than guessed at.
#   - A backend that cannot deliver the harness's interrupt key is refused
#     (Orca's terminal API has no Escape).
#   - `exit` and `relaunch` require a backend with a recovery-grade agent-state
#     classifier (tmux, herdr), because without one the "the agent stopped"
#     postcondition cannot be proven. zellij, orca, and cmux are refused rather
#     than reported as successful blind.
#   - An ambiguous or unreadable endpoint state refuses; only a positively
#     classified state acts.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-control refuses to resolve a task without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-control cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-telemetry-lib.sh
. "$SCRIPT_DIR/fm-telemetry-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

CONTROL_LOCK=
CONTROL_LOCK_HELD=0
RELAUNCH_ACTIVE=0
RELAUNCH_PHASE=start

control_cleanup() {
  local status=$?
  if [ "$RELAUNCH_ACTIVE" = 1 ] \
     && declare -F relaunch_rollback >/dev/null 2>&1; then
    relaunch_rollback || true
  fi
  if declare -F quota_fallback_restore_hold >/dev/null 2>&1; then
    quota_fallback_restore_hold || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
  return "$status"
}

# --- argument parsing -------------------------------------------------------

RAW_ID=${1:-}
VERB=${2:-}
[ -n "$RAW_ID" ] && [ -n "$VERB" ] || { usage >&2; exit 2; }
shift 2

if ! fm_control_verb_allowed "$VERB"; then
  {
    if [ "$VERB" = resume ]; then
      echo "error: 'resume' is not a control verb: resuming an exited agent is not deterministic across the verified adapters (codex and grok need a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, and kimi have no verified pane-resume contract). Use 'relaunch', which carries the brief plus a progress note into a fresh agent on any adapter."
    else
      echo "error: '$VERB' is not a control verb"
    fi
    echo "allowed verbs:"
    fm_control_verbs | sed 's/^/  /'
  } >&2
  exit 2
fi

NEW_HARNESS=
NEW_MODEL=
NEW_EFFORT=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
NOTE=
NOTE_SET=0
DISPATCH_RESOLVED=0
DISPATCH_OVERRIDE_REASON=
DISPATCH_OVERRIDE_REASON_SET=0
DISPATCH_PROVIDER=
DISPATCH_PROVIDER_SET=0
QUOTA_FALLBACK=0
QUOTA_FALLBACK_FROM=
QUOTA_FALLBACK_STARTED_MS=0
QUOTA_FALLBACK_RULE=
QUOTA_FALLBACK_HOLD_LIFTED=0
QUOTA_FALLBACK_HOLD_KIND=
QUOTA_FALLBACK_HOLD_REASON=
control_want_value=
for control_arg in "$@"; do
  if [ -n "$control_want_value" ]; then
    case "$control_arg" in
      --*) die "--$control_want_value requires a value" ;;
    esac
    case "$control_want_value" in
      harness) NEW_HARNESS=$control_arg; HARNESS_SET=1 ;;
      model) NEW_MODEL=$control_arg; MODEL_SET=1 ;;
      effort) NEW_EFFORT=$control_arg; EFFORT_SET=1 ;;
      note) NOTE=$control_arg; NOTE_SET=1 ;;
      note_file)
        [ -f "$control_arg" ] || die "--note-file '$control_arg' is not a readable file"
        NOTE=$(cat "$control_arg")
        NOTE_SET=1
        ;;
      dispatch-override-reason)
        DISPATCH_OVERRIDE_REASON=$control_arg
        DISPATCH_OVERRIDE_REASON_SET=1
        ;;
    esac
    control_want_value=
    continue
  fi
  case "$control_arg" in
    --harness) control_want_value=harness ;;
    --harness=*) NEW_HARNESS=${control_arg#--harness=}; HARNESS_SET=1 ;;
    --model) control_want_value=model ;;
    --model=*) NEW_MODEL=${control_arg#--model=}; MODEL_SET=1 ;;
    --effort) control_want_value=effort ;;
    --effort=*) NEW_EFFORT=${control_arg#--effort=}; EFFORT_SET=1 ;;
    --note) control_want_value=note ;;
    --note=*) NOTE=${control_arg#--note=}; NOTE_SET=1 ;;
    --note-file) control_want_value=note_file ;;
    --note-file=*)
      [ -f "${control_arg#--note-file=}" ] || die "--note-file '${control_arg#--note-file=}' is not a readable file"
      NOTE=$(cat "${control_arg#--note-file=}")
      NOTE_SET=1
      ;;
    --dispatch-resolved) DISPATCH_RESOLVED=1 ;;
    --dispatch-override-reason) control_want_value=dispatch-override-reason ;;
    --dispatch-override-reason=*)
      DISPATCH_OVERRIDE_REASON=${control_arg#--dispatch-override-reason=}
      DISPATCH_OVERRIDE_REASON_SET=1
      ;;
    --quota-fallback) QUOTA_FALLBACK=1 ;;
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    && [ "$DISPATCH_RESOLVED" = 0 ] && [ "$DISPATCH_OVERRIDE_REASON_SET" = 0 ] && [ "$QUOTA_FALLBACK" = 0 ] \
    || die "--harness, --model, --effort, --note, dispatch attestation, and --quota-fallback apply to 'relaunch' only"
fi
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max|ultra) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max, ultra" ;;
esac
[ "$DISPATCH_OVERRIDE_REASON_SET" = 0 ] || [ -n "$DISPATCH_OVERRIDE_REASON" ] \
  || die "--dispatch-override-reason requires a non-empty value"
case "$DISPATCH_OVERRIDE_REASON" in
  *$'\n'*) die "--dispatch-override-reason must be a single line" ;;
esac
if [ "$DISPATCH_RESOLVED" = 1 ] && [ "$DISPATCH_OVERRIDE_REASON_SET" = 1 ]; then
  die "pass exactly one of --dispatch-resolved or --dispatch-override-reason, not both"
fi
if [ "$QUOTA_FALLBACK" = 1 ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "--quota-fallback chooses the successor profile and writes the progress note; do not also pass --harness, --model, --effort, or --note"
  [ "$DISPATCH_OVERRIDE_REASON_SET" = 0 ] \
    || die "--quota-fallback attests --dispatch-resolved; do not also pass --dispatch-override-reason"
  DISPATCH_RESOLVED=1
fi

# --- exact task-id resolution ----------------------------------------------

case "$RAW_ID" in
  *:*) die "'$RAW_ID' is an explicit backend endpoint; fm-control accepts an exact task id only, so a lifecycle command can never land on an endpoint this home does not own" ;;
esac
if ! fm_task_id_creation_valid "$RAW_ID"; then
  die "'$RAW_ID' is not a valid task id"
fi
ID=$RAW_ID
# Supervision lease guard: lifecycle control is overlap territory between the
# two Pi supervision actors; refuse while the OTHER actor holds this task's
# live lease (contract: bin/fm-lease-lib.sh; no-op in homes without leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_guard "$ID" "lifecycle control (fm-control)"
CONTROL_LOCK="$STATE/.control-$ID.lock"
trap control_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  case "$RAW_ID" in
    fm-*)
      if [ -f "$STATE/${RAW_ID#fm-}.meta" ]; then
        die "'$RAW_ID' is a window label, not a task id; pass the exact task id '${RAW_ID#fm-}'"
      fi
      ;;
  esac
  die "no task '$ID' in $STATE (fm-control resolves an exact task id only)"
fi

# A remotely placed secondmate records its endpoint on ANOTHER host, so every
# postcondition this plane verifies - the agent-state classification, the busy
# verdict, the endpoint's existence - would be read here for an endpoint that
# does not live here. Endpoint validation already refuses such a record, since
# `window=remote:<id>` can never match a local backend's required shape, so
# nothing can be delivered to a wrong endpoint either way. What that refusal
# cannot say is WHY, and "malformed metadata" is the wrong thing to tell an
# operator about a correctly configured remote route. Name the placement
# instead, using the same `remote_host` signal bin/fm-send.sh routes on.
if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
  die "task $ID is a remotely placed secondmate on $(fm_meta_get "$META" remote_host); its agent runs outside this home, so no lifecycle action here could verify that it interrupted, stopped, or came back. Drive its lifecycle on that host, and reconcile it through the secondmate recovery path rather than this plane"
fi

fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
T=$FM_BACKEND_VALIDATED_TARGET
LABEL="fm-$ID"
RECORDED_HARNESS=$(fm_meta_get "$META" harness)
KIND=$(fm_meta_get "$META" kind)
WT=$(fm_meta_get "$META" worktree)
[ -n "$KIND" ] || KIND=ship

HARNESS=$(fm_control_harness_family "$RECORDED_HARNESS") \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"
fm_control_harness_supported "$HARNESS" \
  || die "task $ID records harness '${RECORDED_HARNESS:-none}', which has no verified control mechanics; fm-control refuses to guess an interrupt key or exit command"

fm_backend_validate "$BACKEND" || exit 1

# --- shared helpers ---------------------------------------------------------

agent_state() {
  fm_backend_agent_state "$BACKEND" "$T"
}

busy_verdict() {
  fm_busy_classify_meta "$META" "$ID" "$STATE"
}

# wait_agent_state <wanted...> <timeout>: poll until agent_state prints one of
# the wanted values. Prints the final observed state; returns 0 on a match.
wait_agent_state() {  # <timeout> <wanted>...
  local timeout=$1 state want elapsed=0
  shift
  while :; do
    state=$(agent_state)
    for want in "$@"; do
      if [ "$state" = "$want" ]; then
        printf '%s' "$state"
        return 0
      fi
    done
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf '%s' "$state"
  return 1
}

require_state_verified_backend() {  # <verb>
  fm_control_backend_state_verified "$BACKEND" && return 0
  die "task $ID runs on the $BACKEND backend, which has no recovery-grade agent-state classifier, so '$1' cannot prove the agent actually stopped; refusing rather than reporting an unproven transition as done"
}

# send_interrupt_keys: deliver the harness's interrupt key the verified number
# of times, then the composer-clear key when the adapter needs one. Refuses
# before sending anything when the backend cannot deliver either key, because
# an interrupt that cancels the turn but leaves the restored prompt in the
# composer would make the next submitted line concatenate onto it.
send_interrupt_keys() {
  local key repeat clear i=0
  key=$(fm_control_interrupt_key "$HARNESS")
  repeat=$(fm_control_interrupt_repeat "$HARNESS")
  clear=$(fm_control_interrupt_clear_key "$HARNESS")
  fm_control_backend_supports_key "$BACKEND" "$key" \
    || die "harness $HARNESS interrupts with $key, which the $BACKEND backend cannot deliver; refusing to send a different key"
  [ -z "$clear" ] || fm_control_backend_supports_key "$BACKEND" "$clear" \
    || die "harness $HARNESS needs $clear to clear its composer after an interrupt, which the $BACKEND backend cannot deliver; refusing to leave the cancelled prompt where the next submitted line would concatenate onto it"
  while [ "$i" -lt "$repeat" ]; do
    fm_backend_send_key "$BACKEND" "$T" "$key" "$LABEL" \
      || die "interrupt key $key was not delivered to task $ID on $BACKEND"
    i=$((i + 1))
    [ "$i" -ge "$repeat" ] || sleep 0.2
  done
  [ -z "$clear" ] || fm_backend_send_key "$BACKEND" "$T" "$clear" "$LABEL" \
    || die "interrupt key $key reached task $ID, but $clear did not, so its composer still holds the cancelled prompt; clear it before the next lifecycle action"
}

prepare_interrupt_ack() {
  INTERRUPT_ACK_SOURCE=$(fm_control_interrupt_ack_source "$HARNESS")
  INTERRUPT_ACK_LOG=
  INTERRUPT_ACK_RUN=
  case "$INTERRUPT_ACK_SOURCE" in
    muse-session-terminal)
      INTERRUPT_ACK_LOG=$(fm_busy_muse_session_log "$STATE" "$ID" 2>/dev/null || true)
      [ -n "$INTERRUPT_ACK_LOG" ] || return 0
      INTERRUPT_ACK_RUN=$(fm_busy_muse_active_run_id "$INTERRUPT_ACK_LOG" 2>/dev/null || true)
      ;;
  esac
}

interrupt_cancel_claim() {
  local elapsed=0 terminal=
  case "$INTERRUPT_ACK_SOURCE:$INTERRUPT_ACK_RUN" in
    muse-session-terminal:?*) ;;
    *) printf 'unconfirmed'; return 0 ;;
  esac
  while :; do
    terminal=$(fm_busy_muse_run_terminal "$INTERRUPT_ACK_LOG" "$INTERRUPT_ACK_RUN" 2>/dev/null || true)
    case "$terminal" in
      cancelled) printf 'confirmed'; return 0 ;;
      ?*) printf 'unconfirmed'; return 0 ;;
    esac
    awk -v e="$elapsed" -v t="$SETTLE_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  printf 'unconfirmed'
}

# deliver_interrupt: deliver and observe the strongest adapter-owned
# cancellation claim available after delivery.
deliver_interrupt() {
  local cancel
  prepare_interrupt_ack
  send_interrupt_keys
  cancel=$(interrupt_cancel_claim)
  printf '%s' "$cancel"
}

verify_interrupt_running() {
  local proof after
  fm_backend_target_exists "$BACKEND" "$T" "$LABEL" \
    || die "task $ID's endpoint disappeared while interrupting it; no further control action is safe"
  proof=endpoint
  if fm_control_backend_state_verified "$BACKEND"; then
    # An interrupt cancels a turn; it must never have stopped the agent. This
    # is the postcondition that separates a landed interrupt from an accident.
    after=$(agent_state)
    [ "$after" = alive ] \
      || die "task $ID's agent is '$after' after its interrupt key; an interrupt must leave the agent running"
    proof=agent-alive
  fi
  printf '%s' "$proof"
}

do_interrupt() {
  local proof cancel
  cancel=$(deliver_interrupt) || return $?
  proof=$(verify_interrupt_running) || return $?
  printf '%s cancel=%s' "$proof" "$cancel"
}

retire_busy_incarnation() {
  if [ -f "$STATE/$ID.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --current-gen >/dev/null 2>&1 || true
  fi
}

# do_exit: stop the running agent, preserving endpoint and worktree. Prints
# `already-stopped` or `stopped`.
do_exit() {
  local state cmd verdict cancel interrupt_result=not-needed
  require_state_verified_backend exit
  state=$(agent_state)
  case "$state" in
    dead)
      printf 'already-stopped'
      return 0
      ;;
    alive) ;;
    missing) die "task $ID's recorded endpoint is gone, so there is no agent to stop; reconcile the task before any further control action" ;;
    *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint" ;;
  esac
  # A busy agent is interrupted first before the exit command is submitted.
  case "$(busy_verdict)" in
    busy*)
      cancel=$(deliver_interrupt) || return $?
      state=$(agent_state)
      case "$state" in
        dead)
          retire_busy_incarnation
          printf 'stopped'
          return 0
          ;;
        alive) interrupt_result="delivered verified=agent-alive cancel=$cancel" ;;
        missing) die "task $ID's recorded endpoint disappeared after interrupt delivery, so exit cannot prove whether the agent stopped" ;;
        *) die "task $ID's endpoint reads '$state' after interrupt delivery rather than a positively classified state; exit cannot prove whether the agent stopped" ;;
      esac
      ;;
  esac
  cmd=$(fm_control_exit_command "$HARNESS")
  # The submit verdict is NOT the postcondition here: a successful exit command
  # destroys the composer the verdict is read from, so a post-exit read can
  # legitimately report anything. Only a hard transport failure aborts; the
  # authoritative proof is the agent-state wait below. The retried Enter still
  # matters, because a slash command opens a completion popup on some TUIs that
  # swallows the first Enter.
  verdict=$(fm_backend_send_text_submit "$BACKEND" "$T" "$cmd" "$EXIT_RETRIES" "$POLL" 1.2 "$LABEL") \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  [ "$verdict" != send-failed ] \
    || die "the exit command could not be sent to task $ID on $BACKEND"
  state=$(wait_agent_state "$EXIT_WAIT" dead) || {
    die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s"
  }
  # The incarnation is over: retire its busy wiring so no stale record or
  # orphaned generation survives the agent that produced it.
  retire_busy_incarnation
  printf 'stopped'
}

# --- transactional relaunch -------------------------------------------------
#
# The transaction's durable record is state/<id>.control-relaunch, with the
# prior metadata and brief preserved beside it. Every failure path runs through
# relaunch_rollback (an EXIT trap, so a refusal raised deep inside a shared
# helper is covered too) and leaves either the pre-relaunch durable record or a
# concrete, named partial state - never a task whose record claims an agent
# that is not running.

JOURNAL="$STATE/$ID.control-relaunch"
META_PRIOR="$JOURNAL.meta-prior"
BRIEF_PRIOR="$JOURNAL.brief-prior"
NOTE_FILE="$JOURNAL.note"
RELAUNCH_META_PUBLISHED=0
RELAUNCH_AGENT_CONFIRMED=0
RELAUNCH_TX=
RELAUNCH_BRIEF=
PRIOR_HARNESS=$HARNESS
PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
CONFIG_HARNESS=
CONFIG_MODEL=
CONFIG_EFFORT=
PRIOR_MODEL=
PRIOR_EFFORT=
TARGET_HARNESS=$HARNESS
TARGET_MODEL=
TARGET_EFFORT=

journal_write() {  # <phase> [extra-line]...
  local phase=$1
  shift
  if {
    echo "v1"
    echo "task=$ID"
    echo "phase=$phase"
    echo "ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "backend=$BACKEND"
    echo "endpoint=$T"
    echo "worktree=$WT"
    echo "kind=$KIND"
    echo "from_harness=$PRIOR_RECORDED_HARNESS"
    echo "from_model=$PRIOR_MODEL"
    echo "from_effort=$PRIOR_EFFORT"
    echo "to_harness=$TARGET_HARNESS"
    echo "to_model=$TARGET_MODEL"
    echo "to_effort=$TARGET_EFFORT"
    local line
    for line in "$@"; do
      echo "$line"
    done
  } > "$JOURNAL.tmp" && mv -f "$JOURNAL.tmp" "$JOURNAL"; then
    RELAUNCH_PHASE=$phase
    return 0
  fi
  return 1
}

relaunch_rollback() {
  local state
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  [ "$RELAUNCH_PHASE" != complete ] || return 0
  RELAUNCH_ACTIVE=0
  case "$RELAUNCH_PHASE" in
    checkpoint|noted)
      # The old agent was never touched. Restore the instructions byte-exact so
      # a refused relaunch leaves nothing behind.
      if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
        cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
      fi
      journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored" || true
      echo "error: relaunch of $ID was refused before its agent was touched; nothing changed" >&2
      ;;
    stopping)
      state=$(agent_state 2>/dev/null || printf unknown)
      case "$state" in
        alive)
          if [ -n "$RELAUNCH_BRIEF" ] && [ -f "$BRIEF_PRIOR" ]; then
            cp -p "$BRIEF_PRIOR" "$RELAUNCH_BRIEF" 2>/dev/null || true
          fi
          journal_write "failed:$RELAUNCH_PHASE" "rollback=instructions-restored-agent-alive" || true
          echo "error: relaunch of $ID failed while stopping the old agent, which is still running; its original instructions were restored" >&2
          ;;
        dead)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept-agent-dead" || true
          echo "error: $ID's agent stopped but relaunch did not reach replacement launch; no agent is running, and its work plus progress note are preserved at $WT" >&2
          ;;
        *)
          journal_write "failed:$RELAUNCH_PHASE" "rollback=none-agent-state-$state" || true
          echo "error: relaunch of $ID failed while stopping the old agent and its state is '$state'; the durable record and progress note were retained for recovery" >&2
          ;;
      esac
      ;;
    exited|launching)
      if [ "$RELAUNCH_AGENT_CONFIRMED" = 1 ]; then
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-agent-confirmed" || true
        echo "error: $ID's replacement is running on $TARGET_HARNESS, but transaction completion could not be persisted; its published record was retained for reconciliation" >&2
      elif [ "$RELAUNCH_META_PUBLISHED" = 1 ] \
         || { [ -n "$RELAUNCH_TX" ] \
              && [ "$(fm_meta_get "$META" control_relaunch_tx)" = "$RELAUNCH_TX" ]; }; then
        # The launch owner published the new incarnation's record. Leaving it
        # in place is the honest state: the task is now recorded on the new
        # harness with no agent confirmed, which is exactly what recovery
        # reconciles. Rewriting it back to the old harness would be a second,
        # worse inaccuracy.
        journal_write "failed:$RELAUNCH_PHASE" "rollback=none-new-record-kept" || true
        echo "error: $ID was relaunched on $TARGET_HARNESS but no running agent could be confirmed; its work is preserved at $WT" >&2
      else
        journal_write "failed:$RELAUNCH_PHASE" "rollback=prior-record-kept" || true
        echo "error: $ID's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at $WT" >&2
      fi
      ;;
  esac
  return 0
}

quota_fallback_restore_hold() {
  [ "${QUOTA_FALLBACK_HOLD_LIFTED:-0}" = 1 ] || return 0
  QUOTA_FALLBACK_HOLD_LIFTED=0
  fm_backlog_mutate "$DATA" hold "$ID" \
    --reason "$QUOTA_FALLBACK_HOLD_REASON" \
    --kind "$QUOTA_FALLBACK_HOLD_KIND" >/dev/null 2>&1 || true
}

quota_fallback_maybe_lift_hold() {
  local show reason
  [ -f "$DATA/backlog.md" ] || return 0
  fm_backlog_row_probe "$DATA" "$ID" || return 0
  case "$FM_BACKLOG_ROW_HOLD_KIND" in
    external|parked)
      show=$(fm_backlog_row_show "$DATA" "$ID") \
        || die "quota fallback could not read $ID's backlog hold"
      reason=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: *//p' | head -1)
      case "$reason" in
        ''|'"-"'|-) reason="parked by firstmate" ;;
      esac
      fm_backlog_mutate "$DATA" unhold "$ID" \
        || die "quota fallback could not lift $ID's operational hold ($FM_BACKLOG_TRANSITION_ERROR)"
      QUOTA_FALLBACK_HOLD_LIFTED=1
      QUOTA_FALLBACK_HOLD_KIND=$FM_BACKLOG_ROW_HOLD_KIND
      QUOTA_FALLBACK_HOLD_REASON=$reason
      fm_backlog_row_probe "$DATA" "$ID" \
        || die "quota fallback could not re-read $ID's backlog item after lifting its hold"
      ;;
  esac
  if ! fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE"; then
    die "this home's backlog item $ID is not dispatchable in state $FM_BACKLOG_ROW_STATE"
  fi
}

quota_fallback_prepare() {
  local dispatch_file matched profiles n i profile harness model effort provider current_h current_m rc status_tail git_status git_log project repo resolved
  dispatch_file="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/crew-dispatch.json"
  [ -f "$dispatch_file" ] || die "quota fallback needs config/crew-dispatch.json"
  case "$KIND" in
    ship|scout) ;;
    *) die "quota fallback applies to ship or scout tasks, not $KIND" ;;
  esac
  current_h=$(fm_meta_get "$META" harness)
  current_m=$(fm_meta_get "$META" model)
  [ -n "$current_m" ] || current_m=default
  project=$(fm_meta_get "$META" project)
  repo=
  [ -z "$project" ] || repo=$(basename -- "$project")
  matched=$(fm_meta_get "$META" matched_rule)
  resolved=$(jq -c --arg rule "$matched" --arg harness "$current_h" --arg model "$current_m" --arg repo "$repo" '
    def profiles($v):
      if ($v | type) == "array" then $v
      elif ($v | type) == "object" then [$v]
      else [] end;
    def contains_current($use):
      profiles($use) | any(.harness == $harness and (.model // "default") == $model);
    def from_default:
      {rule:"default", profiles: profiles(.default)};
    def from_rule($i):
      if (.rules | type) == "array" and ($i < (.rules | length)) then
        {rule: ("rule-" + ($i | tostring)), profiles: profiles(.rules[$i].use)}
      else {rule:"default", profiles: []} end;
    if $rule == "default" then from_default
    elif ($rule | test("^rule-[0-9]+$")) then from_rule($rule | ltrimstr("rule-") | tonumber)
    elif $rule == "" then
      ([.rules // [] | to_entries[] | select(.value | contains_current(.use))]) as $hits
      | if ($hits | length) == 0 then from_default
        else
          (if $repo == "" then []
           else [$hits[] | select(.value.when != null and (.value.when | ascii_downcase | contains($repo | ascii_downcase)))]
           end) as $repo_hits
          | (if ($repo_hits | length) > 0 then $repo_hits[0] else $hits[0] end) as $pick
          | {rule: ("rule-" + ($pick.key | tostring)), profiles: profiles($pick.value.use)}
        end
    else from_default end
  ' "$dispatch_file") || die "quota fallback could not read $dispatch_file"
  profiles=$(printf '%s\n' "$resolved" | jq -c '.profiles')
  QUOTA_FALLBACK_RULE=$(printf '%s\n' "$resolved" | jq -r '.rule')
  n=$(printf '%s\n' "$profiles" | jq 'length')
  [ "$n" -gt 0 ] || die "no eligible same-class dispatch profile remains for $ID (quota fallback)"
  NEW_HARNESS=
  for i in $(seq 0 $((n - 1))); do
    profile=$(printf '%s\n' "$profiles" | jq -c --argjson i "$i" '.[$i]')
    harness=$(printf '%s\n' "$profile" | jq -r '.harness // empty')
    model=$(printf '%s\n' "$profile" | jq -r '.model // "default"')
    effort=$(printf '%s\n' "$profile" | jq -r '.effort // "default"')
    provider=$(printf '%s\n' "$profile" | jq -r '.provider // empty')
    [ -n "$harness" ] || continue
    [ "$harness" = "$current_h" ] && [ "$model" = "$current_m" ] && continue
    if [ -n "$provider" ]; then
      rc=0
      "$SCRIPT_DIR/fm-quota-cooldown.sh" authorize --harness "$harness" --provider "$provider" >/dev/null 2>&1 || rc=$?
    else
      rc=0
      "$SCRIPT_DIR/fm-quota-cooldown.sh" authorize --harness "$harness" >/dev/null 2>&1 || rc=$?
    fi
    [ "$rc" -eq 0 ] || continue
    NEW_HARNESS=$harness
    NEW_MODEL=$model
    NEW_EFFORT=$effort
    if [ -n "$provider" ]; then
      DISPATCH_PROVIDER=$provider
      DISPATCH_PROVIDER_SET=1
    fi
    break
  done
  [ -n "$NEW_HARNESS" ] || die "no eligible same-class dispatch profile remains for $ID (quota fallback)"
  HARNESS_SET=1
  MODEL_SET=1
  EFFORT_SET=1
  status_tail=$(tail -n 5 "$STATE/$ID.status" 2>/dev/null || true)
  git_status=$(git -C "$WT" status --short 2>/dev/null || true)
  git_log=$(git -C "$WT" log --oneline -3 2>/dev/null || true)
  NOTE=$(printf '%s\n' \
    "Quota exhausted on ${current_h}/${current_m}. Continue on ${NEW_HARNESS}/${NEW_MODEL}." \
    "" \
    "Last status:" \
    "$status_tail" \
    "" \
    "git status --short:" \
    "$git_status" \
    "" \
    "git log --oneline -3:" \
    "$git_log")
  NOTE_SET=1
  QUOTA_FALLBACK_FROM="${current_h}/${current_m}"
  DISPATCH_RESOLVED=1
  quota_fallback_maybe_lift_hold
}

resolve_relaunch_profile() {
  PRIOR_HARNESS=$HARNESS
  PRIOR_RECORDED_HARNESS=$RECORDED_HARNESS
  PRIOR_MODEL=$(fm_meta_get "$META" model)
  PRIOR_EFFORT=$(fm_meta_get "$META" effort)
  [ -n "$PRIOR_MODEL" ] || PRIOR_MODEL=default
  [ -n "$PRIOR_EFFORT" ] || PRIOR_EFFORT=default
  if [ "$HARNESS_SET" = 0 ] \
     && [ "$PRIOR_RECORDED_HARNESS" != "$PRIOR_HARNESS" ]; then
    die "task $ID records harness '$PRIOR_RECORDED_HARNESS', whose original launch command cannot be reconstructed from its recorded basename; relaunching without --harness would substitute the canonical adapter '$PRIOR_HARNESS' for the command actually running. Pass an explicit --harness to choose the replacement runtime deliberately"
  fi
  CONFIG_HARNESS=
  CONFIG_MODEL=
  CONFIG_EFFORT=
  if [ "$KIND" = secondmate ]; then
    # A secondmate's harness, model, and effort are a durable configured pin
    # that every respawn re-resolves (the secondmate-provisioning contract), so
    # a relaunch with no explicit harness picks up a newly configured one
    # instead of freezing whatever this incarnation happens to run. Crewmates
    # and scouts deliberately do NOT resolve config here: their harness comes
    # from firstmate's own dispatch-profile judgment at intake, and silently
    # re-resolving it would bypass that consultation.
    CONFIG_HARNESS=$("$SCRIPT_DIR/fm-harness.sh" secondmate 2>/dev/null || true)
    CONFIG_MODEL=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model 2>/dev/null || true)
    CONFIG_EFFORT=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    case "$CONFIG_EFFORT" in
      ''|low|medium|high|xhigh|max|ultra) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max, ultra; ignoring" >&2
        CONFIG_EFFORT=
        ;;
    esac
  fi
  if [ "$HARNESS_SET" = 1 ]; then
    fm_control_harness_supported "$NEW_HARNESS" \
      || die "'$NEW_HARNESS' is not a verified harness; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$NEW_HARNESS
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    fm_control_harness_supported "$CONFIG_HARNESS" \
      || die "the configured secondmate harness '$CONFIG_HARNESS' is not verified; fm-control refuses to relaunch onto an adapter with no verified control or launch mechanics"
    TARGET_HARNESS=$CONFIG_HARNESS
  else
    TARGET_HARNESS=$PRIOR_HARNESS
  fi
  # The launch owner refuses an adapter that cannot run this task's kind, but it
  # is only reached after the old agent has been stopped. Asking the same
  # capability table here keeps that refusal on the pre-stop side of the
  # transaction, where nothing has changed yet.
  fm_control_harness_supports_kind "$TARGET_HARNESS" "$KIND" \
    || die "'$TARGET_HARNESS' is not verified to run a $KIND task, so relaunching $ID onto it would stop the running agent for a launch that must be refused; choose an adapter verified for this kind"
  # A model or effort chosen for the previous harness does not transfer to a
  # different one, so an explicit harness change resets both axes unless the
  # caller names them too.
  if [ "$MODEL_SET" = 1 ]; then
    TARGET_MODEL=$NEW_MODEL
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_MODEL=${CONFIG_MODEL:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_MODEL=$PRIOR_MODEL
  else
    TARGET_MODEL=default
  fi
  if [ "$EFFORT_SET" = 1 ]; then
    TARGET_EFFORT=$NEW_EFFORT
  elif [ "$HARNESS_SET" = 0 ] && [ -n "$CONFIG_HARNESS" ]; then
    TARGET_EFFORT=${CONFIG_EFFORT:-default}
  elif [ "$TARGET_HARNESS" = "$PRIOR_HARNESS" ]; then
    TARGET_EFFORT=$PRIOR_EFFORT
  else
    TARGET_EFFORT=default
  fi
  if [ "$TARGET_EFFORT" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$TARGET_HARNESS" "$TARGET_MODEL" "$TARGET_EFFORT" || return 1
  fi
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  local recorded_access inside_git_dir
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
  if ! recorded_access=$(fm_meta_optional_exact_value "$META" access); then
    die "task $ID records ambiguous access metadata; refusing to relaunch until $META has exactly zero or one non-empty access= value"
  fi
  case "$recorded_access" in
    ''|writer) ;;
    reader)
      [ "$KIND" = scout ] \
        || die "task $ID records access=reader but kind=$KIND; refusing to relaunch a non-scout as a reader"
      wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null || true)
      inside_git_dir=$(git -C "$WT" rev-parse --is-inside-git-dir 2>/dev/null || true)
      if [ -n "$wt_top" ] || [ "$inside_git_dir" = true ]; then
        die "task $ID's recorded reader scratch $WT is inside a git checkout or git dir; refusing to relaunch without a checkout-free scratch"
      fi
      CHECKPOINT_LINES+=("access=reader" "scratch=$wt_real")
      return 0
      ;;
    *)
      die "task $ID records unknown access '$recorded_access'; refusing to relaunch until the access axis is repaired"
      ;;
  esac
  wt_top=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) \
    || die "task $ID's recorded worktree $WT is not a git worktree; refusing to relaunch without a checkout whose unlanded work can be accounted for"
  wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P) || wt_top_real=$wt_top
  [ "$wt_real" = "$wt_top_real" ] \
    || die "task $ID's recorded worktree $WT is not a worktree root (root is $wt_top); refusing to relaunch against an ambiguous checkout"
  if head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
    :
  elif head_ref=$(git -C "$WT" symbolic-ref -q HEAD 2>/dev/null); then
    if git -C "$WT" show-ref --verify --quiet "$head_ref" 2>/dev/null; then
      die "task $ID's worktree HEAD exists but cannot be resolved; refusing to relaunch from an unreadable checkout"
    else
      head_ref_status=$?
      [ "$head_ref_status" -eq 1 ] \
        || die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
      head=unborn
    fi
  else
    die "task $ID's worktree HEAD cannot be inspected; refusing to relaunch from an unreadable checkout"
  fi
  status_output=$(git -C "$WT" status --porcelain 2>/dev/null) \
    || die "task $ID's worktree status cannot be inspected; refusing to relaunch without accounting for local changes"
  if [ -n "$status_output" ]; then
    dirty=yes
  else
    dirty=no
  fi
  CHECKPOINT_LINES+=("worktree_head=$head" "worktree_dirty=$dirty")
  if [ "$KIND" = secondmate ]; then
    # A secondmate's own crewmates outlive its relaunch: they run in their own
    # endpoints, and the relaunched secondmate reconciles them from its home's
    # durable records at startup. The checkpoint proves those records are
    # readable BEFORE the agent stops, so a relaunch can never strand child
    # work behind an unreadable home.
    marker=$(cat "$WT/.fm-secondmate-home" 2>/dev/null || true)
    [ "$marker" = "$ID" ] \
      || die "task $ID's home $WT is not marked as its own seeded secondmate home (marker: ${marker:-none}); refusing to relaunch"
    [ -d "$WT/state" ] \
      || die "secondmate $ID's home has no readable state directory, so its child work cannot be accounted for; refusing to relaunch"
    find "$WT/state" -mindepth 1 -maxdepth 1 -print >/dev/null 2>&1 \
      || die "secondmate $ID's child records cannot be traversed; refusing to relaunch"
    children=0
    for child_meta in "$WT/state"/*.meta; do
      if [ ! -e "$child_meta" ] && [ ! -L "$child_meta" ]; then
        continue
      fi
      if [ ! -f "$child_meta" ] || [ -L "$child_meta" ] \
         || ! cat "$child_meta" >/dev/null 2>&1; then
        die "secondmate $ID's child record $child_meta is not a readable regular file; refusing to relaunch"
      fi
      children=$((children + 1))
    done
    CHECKPOINT_LINES+=("children=$children")
  fi
}

# record_note: put the required progress note somewhere durable, and - for a
# ship or scout, whose only record of the interrupted reasoning is the
# conversation about to be discarded - into the instructions the replacement
# actually reads. A secondmate's charter is a durable standing document and is
# never rewritten: a secondmate reconciles its own home's records at startup,
# so the note stays parent-side audit evidence.
record_note() {
  local stamp note_block noted_brief
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      note_block=$(mktemp "$JOURNAL.note-block.XXXXXX") \
        || die "could not allocate progress-note staging for task $ID"
      if ! {
        echo
        echo "# Relaunch context"
        echo
        echo "## Progress note ($stamp)"
        echo
        echo "This task was relaunched. Continue from here; the local copy and every"
        echo "uncommitted change are exactly as the previous worker left them."
        echo
        echo "First, check your instruction inbox: list $STATE/$ID.inbox/*.msg, act on"
        echo "each message in numeric order, then mv each handled file into"
        echo "$STATE/$ID.inbox/handled/. A steer sent before the relaunch survives there."
        echo
        printf '%s\n' "$NOTE"
      } > "$note_block"; then
        rm -f "$note_block"
        die "could not stage the progress note for task $ID"
      fi
      if grep -qx '^# Load-bearing contract$' "$RELAUNCH_BRIEF"; then
        # Structured briefs keep the repeated load-bearing contract at EOF.
        # Insert runtime context before that bookend so the opening and closing
        # task text remain byte-equivalent when fm-spawn validates the relaunch.
        noted_brief=$(mktemp "$RELAUNCH_BRIEF.relaunch-note.XXXXXX") || {
          rm -f "$note_block"
          die "could not allocate instruction staging for task $ID"
        }
        if ! cp -p "$RELAUNCH_BRIEF" "$noted_brief"; then
          rm -f "$note_block" "$noted_brief"
          die "could not stage task $ID's instructions for the progress note"
        fi
        if ! awk -v note_file="$note_block" '
          !inserted && /^# Load-bearing contract$/ {
            while ((getline line < note_file) > 0) print line
            close(note_file)
            inserted=1
          }
          { print }
          END { if (!inserted) exit 1 }
        ' "$RELAUNCH_BRIEF" > "$noted_brief"; then
          rm -f "$note_block" "$noted_brief"
          die "could not insert the progress note before task $ID's load-bearing contract"
        fi
        mv -f "$noted_brief" "$RELAUNCH_BRIEF" \
          || die "could not publish the progress note into task $ID's instructions"
      else
        cat "$note_block" >> "$RELAUNCH_BRIEF" \
          || die "could not append the progress note to task $ID's instructions"
      fi
      rm -f "$note_block"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line
  local -a spawn_args

  require_state_verified_backend relaunch
  if [ "$QUOTA_FALLBACK" = 1 ]; then
    QUOTA_FALLBACK_STARTED_MS=$(fm_telemetry_now_ms)
    quota_fallback_prepare
  fi
  resolve_relaunch_profile

  case "$KIND" in
    ship|scout)
      RELAUNCH_BRIEF="$DATA/$ID/brief.md"
      [ -f "$RELAUNCH_BRIEF" ] \
        || die "task $ID has no instructions at $RELAUNCH_BRIEF; refusing to relaunch a worker with nothing to work from"
      [ "$NOTE_SET" = 1 ] && [ -n "$NOTE" ] \
        || die "relaunch of a $KIND task requires --note (or --note-file): the replacement worker inherits the local copy but none of the conversation, so it must be told what happened"
      ;;
    secondmate)
      # The charter in the secondmate's own home is its instruction source and
      # stays untouched.
      RELAUNCH_BRIEF=
      ;;
    *)
      die "task $ID records kind '$KIND', which has no defined relaunch shape"
      ;;
  esac

  if [ -n "$NOTE" ]; then
    note_line="note_file=$NOTE_FILE"
  else
    note_line="note=none"
  fi
  safe_checkpoint
  cp -p "$META" "$META_PRIOR" || die "could not preserve task $ID's durable record before relaunching"
  RELAUNCH_ACTIVE=1
  journal_write checkpoint "${CHECKPOINT_LINES[@]}" "$note_line"

  record_note
  journal_write noted "${CHECKPOINT_LINES[@]}" "$note_line"

  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line"
  exit_result=$(do_exit)
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  if [ "$DISPATCH_RESOLVED" = 1 ]; then
    spawn_args+=(--dispatch-resolved)
  elif [ "$DISPATCH_OVERRIDE_REASON_SET" = 1 ]; then
    spawn_args+=(--dispatch-override-reason "$DISPATCH_OVERRIDE_REASON")
  fi
  [ "$DISPATCH_PROVIDER_SET" = 0 ] || spawn_args+=(--dispatch-provider "$DISPATCH_PROVIDER")
  [ -z "$QUOTA_FALLBACK_RULE" ] || spawn_args+=(--matched-rule "$QUOTA_FALLBACK_RULE")
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}" >/dev/null; then
    RELAUNCH_META_PUBLISHED=1
  else
    [ "$(fm_meta_get "$META" control_relaunch_tx)" != "$RELAUNCH_TX" ] \
      || RELAUNCH_META_PUBLISHED=1
    die "the replacement agent for $ID could not be launched on $TARGET_HARNESS"
  fi

  state=$(wait_agent_state "$LAUNCH_WAIT" alive) || {
    die "the replacement agent for $ID did not come up within ${LAUNCH_WAIT}s (endpoint reads '$state')"
  }
  RELAUNCH_AGENT_CONFIRMED=1

  journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  RELAUNCH_ACTIVE=0
  QUOTA_FALLBACK_HOLD_LIFTED=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
  if [ "$QUOTA_FALLBACK" = 1 ]; then
    fm_telemetry_record lifecycle "$(jq -nc \
      --arg from "$QUOTA_FALLBACK_FROM" \
      --arg to "${TARGET_HARNESS}/${TARGET_MODEL}" \
      --argjson elapsed "$(($(fm_telemetry_now_ms) - QUOTA_FALLBACK_STARTED_MS))" \
      '{op:"quota-fallback",from:$from,to:$to,reason:"quota-exhausted",elapsedMs:$elapsed}')"
  fi
}

# --- verbs ------------------------------------------------------------------

case "$VERB" in
  interrupt)
    state=$(agent_state)
    case "$state" in
      alive) ;;
      unverified)
        # No recovery-grade classifier on this backend. Interrupt is
        # non-destructive and its endpoint-existence postcondition is still
        # real, so it proceeds - the printed proof names exactly what was
        # verified rather than implying more.
        ;;
      dead|missing) die "no agent is running at task $ID's recorded endpoint (state: $state); there is nothing to interrupt" ;;
      *) die "task $ID's endpoint reads '$state' rather than a positively classified state; refusing to send a lifecycle key into an unattributed endpoint" ;;
    esac
    proof=$(do_interrupt)
    echo "interrupt-delivered $ID harness=$HARNESS backend=$BACKEND verified=$proof"
    ;;
  exit)
    result=$(do_exit)
    echo "$result $ID harness=$HARNESS backend=$BACKEND endpoint=$T worktree=$WT"
    ;;
  relaunch)
    do_relaunch
    ;;
esac

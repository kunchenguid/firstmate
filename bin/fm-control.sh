#!/usr/bin/env bash
# fm-control.sh - the CONTROL PLANE for a firstmate-owned agent: allowlisted
# lifecycle verbs addressed to an exact task id.
#
# Usage: fm-control.sh <task-id> interrupt
#        fm-control.sh <task-id> exit
#        fm-control.sh <task-id> relaunch [--harness <name>] [--model <name>]
#                                         [--effort <level>]
#                                         (--note <text> | --note-file <path>)
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
#              the backend's recovery-grade classifier reports the agent gone,
#              except for the exact released Herdr/Pi cache case proved below.
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
#   - One task-scoped exception repairs Herdr's stale Pi authority after a real
#     Treehouse nested-shell exit. It applies only to an ordinary pi/pi-signed
#     worker whose exact recorded pane, tab, workspace, task label, managed
#     Treehouse copy, Pi session source, foreground cwd, and two stable process
#     samples all agree. The samples must show only pane-shell -> treehouse get
#     -> nested shell, with no Pi process below the pane shell. After verifying
#     protocol support and the named session's owner-only socket, the fixed-
#     method `pane.clear_agent_authority` transport clears only `herdr:pi`; the
#     generic release command is intentionally not used because Herdr 0.8.2
#     ignores it for official integrations while reporting success. Two more
#     samples must prove the session and full-lifecycle authority disappeared
#     and the exact no-Pi process generation stayed unchanged. Herdr may still
#     expose its conservative cached Pi label, so relaunch crosses that state
#     only through a private transaction proof rechecked by the verified parent
#     immediately before launch. Any process, process-group, identity, session,
#     ownership, transport, or parse ambiguity refuses without terminal input.
#     The fleet-wide Herdr classifier remains conservative. A Pi replacement is
#     accepted only after a distinct valid `herdr:pi` generation and exactly one
#     new Pi engine are observed stably on the same pane and copy; a replacement
#     on another runtime is accepted only after exactly one independent target-
#     harness process, with no Pi engine left below the pane shell, is observed
#     the same way. A target whose process identity that proof cannot read is
#     refused before any replacement is launched.
#
# Environment knobs (all bounded waits, seconds):
#   FM_CONTROL_POLL              poll interval for postcondition waits (0.5)
#   FM_CONTROL_SETTLE_WAIT       adapter acknowledgement wait after interrupt (5)
#   FM_CONTROL_EXIT_WAIT         alive->dead wait after the exit command (30)
#   FM_CONTROL_LAUNCH_WAIT       dead->alive wait after a relaunch (90)
#   FM_CONTROL_EXIT_RETRIES      Enter retries for the exit command (3)
#   FM_CONTROL_HERDR_SAMPLE_WAIT delay between the two stale-process samples (0.2)
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
# shellcheck source=bin/fm-herdr-pi-recovery-lib.sh
. "$SCRIPT_DIR/fm-herdr-pi-recovery-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

POLL=${FM_CONTROL_POLL:-0.5}
SETTLE_WAIT=${FM_CONTROL_SETTLE_WAIT:-5}
EXIT_WAIT=${FM_CONTROL_EXIT_WAIT:-30}
LAUNCH_WAIT=${FM_CONTROL_LAUNCH_WAIT:-90}
EXIT_RETRIES=${FM_CONTROL_EXIT_RETRIES:-3}
HERDR_SAMPLE_WAIT=${FM_CONTROL_HERDR_SAMPLE_WAIT:-0.2}

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
  if [ -n "${HERDR_PI_RELEASE_PROOF:-}" ] && [ -n "${RELAUNCH_TX:-}" ] \
     && [ -f "$HERDR_PI_RELEASE_PROOF" ] && [ ! -L "$HERDR_PI_RELEASE_PROOF" ] \
     && [ "$(fm_backend_meta_exact_value "$HERDR_PI_RELEASE_PROOF" tx 2>/dev/null || true)" = "$RELAUNCH_TX" ]; then
    if ! rm -f "$HERDR_PI_RELEASE_PROOF"; then
      echo "error: could not retire task $ID's stale Herdr Pi release proof" >&2
      [ "$status" -ne 0 ] || status=1
    fi
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
    *) die "unexpected argument '$control_arg'" ;;
  esac
done
if [ -n "$control_want_value" ]; then
  [ "$control_want_value" = note_file ] && die "--note-file requires a value"
  die "--$control_want_value requires a value"
fi

if [ "$VERB" != relaunch ]; then
  [ "$HARNESS_SET" = 0 ] && [ "$MODEL_SET" = 0 ] && [ "$EFFORT_SET" = 0 ] && [ "$NOTE_SET" = 0 ] \
    || die "--harness, --model, --effort, and --note apply to 'relaunch' only"
fi
[ "$HARNESS_SET" = 0 ] || [ -n "$NEW_HARNESS" ] || die "--harness requires a non-empty value"
[ "$MODEL_SET" = 0 ] || [ -n "$NEW_MODEL" ] || die "--model requires a non-empty value"
[ "$EFFORT_SET" = 0 ] || [ -n "$NEW_EFFORT" ] || die "--effort requires a non-empty value"
case "$NEW_EFFORT" in
  ''|default|low|medium|high|xhigh|max) ;;
  *) die "--effort must be one of default, low, medium, high, xhigh, max" ;;
esac

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
fm_lock_acquire_task_control "$CONTROL_LOCK" \
  || die "another lifecycle action is already running for task $ID"
CONTROL_LOCK_HELD=1
# The identity fm-spawn verifies this process by: the pid recorded in the
# control lock, which is also fm-spawn's $PPID when this script launches it.
# Captured once at top level because every later reader may run inside a
# command substitution, where a subshell-aware pid would name the wrong
# process (bin/fm-spawn.sh fm_spawn_released_herdr_pi_proof_valid).
CONTROL_PID=$(cat "$CONTROL_LOCK/pid" 2>/dev/null || true)
case "$CONTROL_PID" in
  ''|*[!0-9]*|0) die "task $ID's lifecycle lock did not record a readable owner pid" ;;
esac
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
HERDR_PI_RELEASE_PROOF="$STATE/$ID.herdr-pi-release-proof"
HERDR_PI_STALE_RELEASED=0
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

control_real_dir() {  # <directory>
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

# Backend adapters are sourced lazily inside fm_backend_* calls. Those calls
# commonly run in command substitutions, whose sourced functions do not leak
# back into this shell. Recovery therefore enters Herdr through this local
# adapter-loading boundary on every direct CLI call.
control_herdr_cli() {  # <session> <herdr-subcommand-and-args...>
  fm_backend_source herdr || return 1
  fm_backend_herdr_cli "$@"
}

control_herdr_pi_session_generation_valid() {  # <kind> <value>
  local kind=$1 value=$2 owner expected_owner base platform
  case "$kind" in
    id)
      printf '%s\n' "$value" \
        | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      ;;
    path)
      case "$value" in /*) ;; *) return 1 ;; esac
      [ ! -L "$value" ] || return 1
      base=${value##*/}
      printf '%s\n' "$base" \
        | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{3}Z_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$' \
        || return 1
      if [ -e "$value" ]; then
        [ -f "$value" ] || return 1
        expected_owner=$(id -u 2>/dev/null) || return 1
        platform=$(uname -s 2>/dev/null) || return 1
        case "$platform" in
          Darwin) owner=$(stat -f %u "$value" 2>/dev/null) || return 1 ;;
          Linux) owner=$(stat -c %u "$value" 2>/dev/null) || return 1 ;;
          *) return 1 ;;
        esac
        [ "$owner" = "$expected_owner" ] || return 1
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

# The Pi engine's process-name vocabulary, kept identical to the single-owner
# classifier in bin/backends/tmux.sh: the launcher, the signed wrapper and the
# engine itself all name a running Pi.
control_herdr_pi_engine_process_name() {  # <name-or-path>
  local base=${1##*/}
  base=${base#-}
  case "$base" in
    pi|pi-signed|pi-launcher|Pi) return 0 ;;
  esac
  return 1
}

# Positive-only liveness probe for the pane's Pi engine, read BEFORE any
# identity, cwd or Treehouse-ownership gate. A Pi that is visibly running keeps
# the ordinary lifecycle path (exit interrupts busy workers on purpose), so a
# tool child holding the pane's foreground process group, a `pi-launcher` or
# `Pi` process name, or a foreground cwd below the worktree must never become a
# refusal. Returns 0 only on positive evidence; every other outcome falls
# through to the conservative stale-exit proof below.
control_herdr_pi_live_engine_present() {
  local session pane process_json shell_pid names name
  session=$(fm_backend_meta_exact_value "$META" herdr_session) || return 1
  pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || return 1
  process_json=$(control_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  names=$(printf '%s' "$process_json" | jq -r --arg pane "$pane" '
    .result
    | select(.type == "pane_process_info" and .process_info.pane_id == $pane)
    | .process_info.foreground_processes[]?
    | (.name // empty), (.argv0 // empty), (.argv[0]? // empty)
  ' 2>/dev/null) || names=
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if control_herdr_pi_engine_process_name "$name"; then
      return 0
    fi
  done <<EOF
$names
EOF
  shell_pid=$(printf '%s' "$process_json" | jq -er --arg pane "$pane" '
    .result
    | select(.type == "pane_process_info" and .process_info.pane_id == $pane)
    | .process_info.shell_pid
    | select(type == "number" and . > 1)
    | floor
  ' 2>/dev/null) || return 1
  names=$(fm_herdr_pi_descendant_commands "$shell_pid") || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if control_herdr_pi_engine_process_name "$name"; then
      return 0
    fi
  done <<EOF
$names
EOF
  return 1
}

# One complete read-only sample for the narrow stale-Pi recovery predicate.
# Return 0 is the exact nested-shell candidate and prints its stable identity
# fingerprint. Return 10 means a Pi process is positively visible, so ordinary
# lifecycle control remains applicable. Return 20 means unreadable or refused;
# callers must not fall through to terminal input.
control_herdr_pi_nested_shell_sample() {
  local session workspace tab pane endpoint_task pane_json tab_json agent_json process_json
  local pane_fields agent_fields process_fields pane_cwd pane_status pane_source pane_session_kind pane_session
  local agent_status agent_source agent_session_kind agent_session_value agent_state_seq shell_pid foreground_pgid
  local foreground_pid foreground_name foreground_argv0 foreground_cwd process_fingerprint wt_real
  session=$(fm_backend_meta_exact_value "$META" herdr_session) || return 20
  workspace=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || return 20
  tab=$(fm_backend_meta_exact_value "$META" herdr_tab_id) || return 20
  pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || return 20
  endpoint_task=$(fm_backend_meta_exact_value "$META" endpoint_task_id) || return 20
  [ "$endpoint_task" = "$ID" ] && [ "$T" = "$session:$pane" ] || return 20
  wt_real=$(control_real_dir "$WT") || return 20

  pane_json=$(control_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 20
  pane_fields=$(printf '%s' "$pane_json" | jq -er \
    --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
      .result as $result
      | select($result.type == "pane_info")
      | $result.pane
      | select(.pane_id == $pane and .tab_id == $tab and .workspace_id == $workspace)
      | select((.foreground_cwd | type) == "string" and (.foreground_cwd | length) > 0)
      | [ .foreground_cwd, (.agent_status // ""), (.agent_session.source // ""), (.agent_session.kind // ""), (.agent_session.value // "") ]
      | @tsv
    ' 2>/dev/null) || return 20
  IFS=$'\t' read -r pane_cwd pane_status pane_source pane_session_kind pane_session <<EOF
$pane_fields
EOF
  pane_cwd=$(control_real_dir "$pane_cwd") || return 20
  [ "$pane_cwd" = "$wt_real" ] || return 20

  tab_json=$(control_herdr_cli "$session" tab get "$tab" 2>/dev/null) || return 20
  printf '%s' "$tab_json" | jq -e \
    --arg tab "$tab" --arg workspace "$workspace" --arg label "fm-$ID" '
      .result.type == "tab_info"
      and .result.tab.tab_id == $tab
      and .result.tab.workspace_id == $workspace
      and .result.tab.label == $label
    ' >/dev/null 2>&1 || return 20

  agent_json=$(control_herdr_cli "$session" agent get "$pane" 2>/dev/null) || return 20
  agent_fields=$(printf '%s' "$agent_json" | jq -er \
    --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
      .result as $result
      | select($result.type == "agent_info")
      | $result.agent
      | select(.agent == "pi" and .pane_id == $pane and .tab_id == $tab and .workspace_id == $workspace)
      | select((.foreground_cwd | type) == "string" and (.foreground_cwd | length) > 0)
      | select((.state_change_seq | type) == "number" and .state_change_seq >= 0 and (.state_change_seq | floor) == .state_change_seq)
      | [ .agent_status, (.agent_session.source // ""), (.agent_session.kind // ""), (.agent_session.value // ""), .foreground_cwd, .state_change_seq ]
      | @tsv
    ' 2>/dev/null) || return 20
  IFS=$'\t' read -r agent_status agent_source agent_session_kind agent_session_value foreground_cwd agent_state_seq <<EOF
$agent_fields
EOF
  foreground_cwd=$(control_real_dir "$foreground_cwd") || return 20
  [ "$foreground_cwd" = "$wt_real" ] || return 20

  process_json=$(control_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 20
  printf '%s' "$process_json" | jq -e --arg pane "$pane" '
    .result.type == "pane_process_info"
    and .result.process_info.pane_id == $pane
    and (.result.process_info.shell_pid | type) == "number"
    and .result.process_info.shell_pid > 1
    and (.result.process_info.foreground_process_group_id | type) == "number"
    and .result.process_info.foreground_process_group_id > 1
    and (.result.process_info.foreground_processes | type) == "array"
  ' >/dev/null 2>&1 || return 20
  if printf '%s' "$process_json" | jq -e '
    def base:
      sub("^-"; "") | split("/")[-1];
    any(.result.process_info.foreground_processes[]?;
      (((.argv0 // .argv[0] // .name // "") | base) == "pi")
      or (((.argv0 // .argv[0] // .name // "") | base) == "pi-signed"))
  ' >/dev/null 2>&1; then
    return 10
  fi
  process_fields=$(printf '%s' "$process_json" | jq -er '
    .result.process_info as $process
    | select(($process.foreground_processes | length) == 1)
    | $process.foreground_processes[0] as $foreground
    | select(($foreground.pid | type) == "number" and $foreground.pid > 1)
    | select(($foreground.name | type) == "string" and ($foreground.name | length) > 0)
    | (($foreground.argv0 // $foreground.argv[0]) // "") as $argv0
    | select(($argv0 | type) == "string" and ($argv0 | length) > 0)
    | select(($foreground.cwd | type) == "string" and ($foreground.cwd | length) > 0)
    | [ $process.shell_pid, $process.foreground_process_group_id, $foreground.pid, $foreground.name, $argv0, $foreground.cwd ]
    | @tsv
  ' 2>/dev/null) || return 20
  IFS=$'\t' read -r shell_pid foreground_pgid foreground_pid foreground_name foreground_argv0 foreground_cwd <<EOF
$process_fields
EOF
  [ "$shell_pid" != "$foreground_pid" ] && [ "$foreground_pgid" = "$foreground_pid" ] || return 20
  foreground_name=${foreground_name#-}
  foreground_name=${foreground_name##*/}
  foreground_argv0=${foreground_argv0#-}
  foreground_argv0=${foreground_argv0##*/}
  [ "$foreground_name" = "$foreground_argv0" ] || return 20
  case "$foreground_name" in sh|bash|zsh|dash|ksh|fish) ;; *) return 20 ;; esac
  foreground_cwd=$(control_real_dir "$foreground_cwd") || return 20
  [ "$foreground_cwd" = "$wt_real" ] || return 20

  case "$agent_status" in idle|done|blocked) ;; *) return 20 ;; esac
  [ "$pane_status" = "$agent_status" ] \
    && [ "$agent_source" = herdr:pi ] \
    && [ "$pane_source" = "$agent_source" ] \
    && [ "$pane_session_kind" = "$agent_session_kind" ] \
    && [ "$pane_session" = "$agent_session_value" ] \
    || return 20
  control_herdr_pi_session_generation_valid "$agent_session_kind" "$agent_session_value" || return 20

  process_fingerprint=$(fm_herdr_pi_nested_shell_process_fingerprint "$shell_pid" "$foreground_pgid") || return 20
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$session" "$workspace" "$tab" "$pane" "$agent_status" \
    "$agent_session_kind" "$agent_session_value" "$agent_state_seq" "$process_fingerprint"
}

# Print a stable fingerprint only after the exact old herdr:pi authority is
# gone. Herdr 0.8.2 can conservatively retain its process-detected Pi label
# after releasing full-lifecycle hook authority, so agent=pi alone is not an
# ambiguity here: the session must be absent, screen detection must no longer
# be skipped, and the same no-Pi nested-shell process proof must still hold.
control_herdr_pi_released_shell_sample() {
  local session workspace tab pane endpoint_task wt_real pane_json pane_fields pane_cwd pane_status
  local tab_json agent_json agent_rc=0 agent_fields agent_cwd process_json process_fields
  local shell_pid foreground_pgid foreground_pid foreground_name foreground_argv0 foreground_cwd process_fingerprint
  session=$(fm_backend_meta_exact_value "$META" herdr_session) || return 1
  workspace=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || return 1
  tab=$(fm_backend_meta_exact_value "$META" herdr_tab_id) || return 1
  pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || return 1
  endpoint_task=$(fm_backend_meta_exact_value "$META" endpoint_task_id) || return 1
  [ "$endpoint_task" = "$ID" ] && [ "$T" = "$session:$pane" ] || return 1
  wt_real=$(control_real_dir "$WT") || return 1

  pane_json=$(control_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  pane_fields=$(printf '%s' "$pane_json" | jq -er \
    --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
      .result as $result
      | select($result.type == "pane_info")
      | $result.pane
      | select(.pane_id == $pane and .tab_id == $tab and .workspace_id == $workspace)
      | select(.agent_session == null)
      | select((.foreground_cwd | type) == "string" and (.foreground_cwd | length) > 0)
      | [ .foreground_cwd, (.agent_status // "unknown") ]
      | @tsv
    ' 2>/dev/null) || return 1
  IFS=$'\t' read -r pane_cwd pane_status <<EOF
$pane_fields
EOF
  case "$pane_status" in unknown|idle|done|blocked) ;; *) return 1 ;; esac
  pane_cwd=$(control_real_dir "$pane_cwd") || return 1
  [ "$pane_cwd" = "$wt_real" ] || return 1

  tab_json=$(control_herdr_cli "$session" tab get "$tab" 2>/dev/null) || return 1
  printf '%s' "$tab_json" | jq -e \
    --arg tab "$tab" --arg workspace "$workspace" --arg label "fm-$ID" '
      .result.type == "tab_info"
      and .result.tab.tab_id == $tab
      and .result.tab.workspace_id == $workspace
      and .result.tab.label == $label
    ' >/dev/null 2>&1 || return 1

  agent_json=$(control_herdr_cli "$session" agent get "$pane" 2>/dev/null) || agent_rc=$?
  if [ "$agent_rc" -eq 0 ]; then
    agent_fields=$(printf '%s' "$agent_json" | jq -er \
      --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
        .result as $result
        | select($result.type == "agent_info")
        | $result.agent
        | select(.agent == "pi" and .pane_id == $pane and .tab_id == $tab and .workspace_id == $workspace)
        | select(.agent_session == null and .screen_detection_skipped == false)
        | select(.agent_status == "idle" or .agent_status == "done" or .agent_status == "blocked")
        | select((.foreground_cwd | type) == "string" and (.foreground_cwd | length) > 0)
        | .foreground_cwd
      ' 2>/dev/null) || return 1
    agent_cwd=$(control_real_dir "$agent_fields") || return 1
    [ "$agent_cwd" = "$wt_real" ] || return 1
  else
    [ "$(fm_backend_agent_state herdr "$session:$pane" 2>/dev/null)" = dead ] || return 1
  fi

  process_json=$(control_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  process_fields=$(printf '%s' "$process_json" | jq -er --arg pane "$pane" '
    .result as $result
    | select($result.type == "pane_process_info" and $result.process_info.pane_id == $pane)
    | $result.process_info as $process
    | select(($process.shell_pid | type) == "number" and $process.shell_pid > 1)
    | select(($process.foreground_process_group_id | type) == "number" and $process.foreground_process_group_id > 1)
    | select(($process.foreground_processes | type) == "array" and ($process.foreground_processes | length) == 1)
    | $process.foreground_processes[0] as $foreground
    | select(($foreground.pid | type) == "number" and $foreground.pid > 1)
    | select(($foreground.name | type) == "string" and ($foreground.name | length) > 0)
    | (($foreground.argv0 // $foreground.argv[0]) // "") as $argv0
    | select(($argv0 | type) == "string" and ($argv0 | length) > 0)
    | select(($foreground.cwd | type) == "string" and ($foreground.cwd | length) > 0)
    | [ $process.shell_pid, $process.foreground_process_group_id, $foreground.pid, $foreground.name, $argv0, $foreground.cwd ]
    | @tsv
  ' 2>/dev/null) || return 1
  IFS=$'\t' read -r shell_pid foreground_pgid foreground_pid foreground_name foreground_argv0 foreground_cwd <<EOF
$process_fields
EOF
  [ "$shell_pid" != "$foreground_pid" ] && [ "$foreground_pgid" = "$foreground_pid" ] || return 1
  foreground_name=${foreground_name#-}; foreground_name=${foreground_name##*/}
  foreground_argv0=${foreground_argv0#-}; foreground_argv0=${foreground_argv0##*/}
  [ "$foreground_name" = "$foreground_argv0" ] || return 1
  case "$foreground_name" in sh|bash|zsh|dash|ksh|fish) ;; *) return 1 ;; esac
  foreground_cwd=$(control_real_dir "$foreground_cwd") || return 1
  [ "$foreground_cwd" = "$wt_real" ] || return 1
  process_fingerprint=$(fm_herdr_pi_nested_shell_process_fingerprint "$shell_pid" "$foreground_pgid") || return 1
  printf '%s\t%s\t%s\t%s\t%s' "$session" "$workspace" "$tab" "$pane" "$process_fingerprint"
}

control_stable_released_herdr_pi_now() {
  local first second
  first=$(control_herdr_pi_released_shell_sample) || return 1
  sleep "$HERDR_SAMPLE_WAIT"
  second=$(control_herdr_pi_released_shell_sample) || return 1
  [ "$first" = "$second" ] || return 1
  printf '%s' "$first"
}

control_wait_stable_released_herdr_pi() {
  local elapsed=0 sample previous='' stable=0
  while :; do
    sample=$(control_herdr_pi_released_shell_sample 2>/dev/null) || sample=
    if [ -n "$sample" ] && [ "$sample" = "$previous" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 1 ] && { printf '%s' "$sample"; return 0; }
    else
      stable=0
    fi
    previous=$sample
    awk -v e="$elapsed" -v t="$EXIT_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  return 1
}

control_herdr_pi_recovery_applicable() {
  [ "$BACKEND" = herdr ] || return 1
  case "$HARNESS" in pi|pi-signed) ;; *) return 1 ;; esac
  case "$KIND" in ship|scout) ;; *) return 1 ;; esac
  return 0
}

# Print recovered, live, not-applicable, or refused. A refused result is a hard
# stop for the caller: once a non-working registered Pi cannot be attributed to
# either a visible Pi process or the exact stable nested-shell exit, terminal
# input could land in an ordinary shell.
#
# Liveness is decided first and on its own evidence. Treehouse ownership is a
# precondition for RELEASING someone else's authority, not for typing into a
# pane that provably still hosts Pi, so an unprovable copy must never take the
# ordinary exit path away from a healthy worker.
control_maybe_release_stale_herdr_pi() {
  local first second sample_status session pane kind generation authority_seq released schema socket clearer
  control_herdr_pi_recovery_applicable || { printf 'not-applicable'; return 0; }
  if control_herdr_pi_live_engine_present; then
    printf 'live'
    return 0
  fi
  fm_herdr_pi_treehouse_copy_matches "$(fm_meta_get "$META" project)" "$WT" \
    || { printf 'refused'; return 0; }
  sample_status=0
  first=$(control_herdr_pi_nested_shell_sample) || sample_status=$?
  case "$sample_status" in
    0) ;;
    10) printf 'live'; return 0 ;;
    *)
      released=$(control_stable_released_herdr_pi_now 2>/dev/null) \
        || { printf 'refused'; return 0; }
      [ -n "$released" ] || { printf 'refused'; return 0; }
      printf 'recovered'
      return 0
      ;;
  esac
  sleep "$HERDR_SAMPLE_WAIT"
  sample_status=0
  second=$(control_herdr_pi_nested_shell_sample) || sample_status=$?
  [ "$sample_status" -eq 0 ] && [ "$second" = "$first" ] \
    || { printf 'refused'; return 0; }

  IFS=$'\t' read -r session _ _ pane _ kind generation _ _ <<EOF
$first
EOF
  control_herdr_pi_session_generation_valid "$kind" "$generation" \
    || { printf 'refused'; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf 'refused'; return 0; }
  schema=$(control_herdr_cli "$session" api schema --json 2>/dev/null) \
    || { printf 'refused'; return 0; }
  printf '%s' "$schema" | jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "pane.clear_agent_authority")
  ' >/dev/null 2>&1 || { printf 'refused'; return 0; }
  fm_backend_source herdr || { printf 'refused'; return 0; }
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session" 2>/dev/null) \
    || { printf 'refused'; return 0; }
  authority_seq=$(python3 -c 'import time; print(int(time.time() * 1000) * 1000, end="")' 2>/dev/null) \
    || { printf 'refused'; return 0; }
  case "$authority_seq" in ''|*[!0-9]*) printf 'refused'; return 0 ;; esac
  clearer=${FM_CONTROL_HERDR_PI_AUTHORITY_CLEARER:-$SCRIPT_DIR/backends/herdr-clear-agent-authority.py}
  [ -x "$clearer" ] || { printf 'refused'; return 0; }
  "$clearer" "$socket" "$pane" "$authority_seq" >/dev/null 2>&1 \
    || { printf 'refused'; return 0; }
  released=$(control_wait_stable_released_herdr_pi) \
    || { printf 'refused'; return 0; }
  [ -n "$released" ] || { printf 'refused'; return 0; }
  printf 'recovered'
}

control_write_herdr_pi_release_proof() {
  local sample session workspace tab pane process wt_real project_real tmp old_umask
  [ -n "$RELAUNCH_TX" ] || return 1
  [ ! -L "$HERDR_PI_RELEASE_PROOF" ] || return 1
  sample=$(control_stable_released_herdr_pi_now) || return 1
  IFS=$'\t' read -r session workspace tab pane process <<EOF
$sample
EOF
  wt_real=$(control_real_dir "$WT") || return 1
  project_real=$(control_real_dir "$(fm_meta_get "$META" project)") || return 1
  fm_herdr_pi_treehouse_copy_matches "$project_real" "$wt_real" || return 1
  tmp="$HERDR_PI_RELEASE_PROOF.tmp.${BASHPID:-$$}"
  old_umask=$(umask)
  umask 077
  if {
    printf '%s\n' 'v=1'
    printf 'task=%s\n' "$ID"
    printf 'control_pid=%s\n' "$CONTROL_PID"
    printf 'tx=%s\n' "$RELAUNCH_TX"
    printf 'endpoint=%s\n' "$T"
    printf 'worktree=%s\n' "$wt_real"
    printf 'project=%s\n' "$project_real"
    printf 'harness=%s\n' "$HARNESS"
    printf 'kind=%s\n' "$KIND"
    printf 'session=%s\n' "$session"
    printf 'workspace=%s\n' "$workspace"
    printf 'tab=%s\n' "$tab"
    printf 'pane=%s\n' "$pane"
    printf 'process=%s\n' "$process"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$HERDR_PI_RELEASE_PROOF"; then
    umask "$old_umask"
    return 0
  fi
  umask "$old_umask"
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

control_accept_recovered_herdr_pi() {
  HERDR_PI_STALE_RELEASED=1
  [ "$RELAUNCH_ACTIVE" = 1 ] || return 0
  control_write_herdr_pi_release_proof \
    || die "the stale Herdr Pi authority was released, but the transaction proof for guarded replacement launch could not be persisted"
}

# Snapshot a newly anchored Herdr Pi authority together with its pane-shell pid,
# accepting it only while exactly one Pi engine exists at or below that shell.
# The caller samples this twice so a transient registration or process cannot
# satisfy the relaunch postcondition.
# <prior-session-ref> is REQUIRED and carries the pre-relaunch generation, or
# the literal `none` when the pane provably had none. An empty value is an
# unread prior, which would make the distinctness test below vacuous, so it
# refuses instead.
control_herdr_pi_authority_snapshot() {  # <prior-session-ref>
  local prior=${1:-} session workspace tab pane agent_json fields status source kind value cwd state_seq wt_real
  local process_json shell_pid ps_bin rows counts pi_count signed_count pi_pid signed_pid pi_parent
  [ -n "$prior" ] || return 1
  session=$(fm_backend_meta_exact_value "$META" herdr_session) || return 1
  workspace=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || return 1
  tab=$(fm_backend_meta_exact_value "$META" herdr_tab_id) || return 1
  pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || return 1
  wt_real=$(control_real_dir "$WT") || return 1
  agent_json=$(control_herdr_cli "$session" agent get "$pane" 2>/dev/null) || return 1
  fields=$(printf '%s' "$agent_json" | jq -er \
    --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
      .result as $result
      | select($result.type == "agent_info")
      | $result.agent
      | select(.agent == "pi" and .pane_id == $pane and .tab_id == $tab and .workspace_id == $workspace)
      | select((.state_change_seq | type) == "number" and .state_change_seq >= 0 and (.state_change_seq | floor) == .state_change_seq)
      | [ .agent_status, (.agent_session.source // ""), (.agent_session.kind // ""), (.agent_session.value // ""), .foreground_cwd, .state_change_seq ]
      | @tsv
    ' 2>/dev/null) || return 1
  IFS=$'\t' read -r status source kind value cwd state_seq <<EOF
$fields
EOF
  case "$status" in working|idle|done|blocked) ;; *) return 1 ;; esac
  [ "$source" = herdr:pi ] || return 1
  control_herdr_pi_session_generation_valid "$kind" "$value" || return 1
  [ "$kind:$value" != "$prior" ] || return 1
  cwd=$(control_real_dir "$cwd") || return 1
  [ "$cwd" = "$wt_real" ] || return 1

  process_json=$(control_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  shell_pid=$(printf '%s' "$process_json" | jq -er --arg pane "$pane" '
    .result
    | select(.type == "pane_process_info" and .process_info.pane_id == $pane)
    | .process_info.shell_pid
    | select(type == "number" and . > 1)
    | floor
  ' 2>/dev/null) || return 1
  ps_bin=${FM_HERDR_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  rows=$("$ps_bin" -axo pid=,ppid=,pgid=,stat=,comm=,args= 2>/dev/null) || return 1
  counts=$(printf '%s\n' "$rows" | awk -v shell="$shell_pid" '
    function base(value, count, parts) {
      sub(/^-/, "", value)
      count = split(value, parts, "/")
      return parts[count]
    }
    {
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || NF < 5 || seen[$1]++) { bad = 1; next }
      parent[$1] = $2
      state[$1] = $4
      command[$1] = $5
      argv0[$1] = (NF >= 6 ? $6 : "")
      present[$1] = 1
      rows++
    }
    END {
      if (bad || !present[shell]) exit 1
      owned[shell] = 1
      for (pass = 0; pass <= rows; pass++) {
        for (pid in present) if (owned[parent[pid]]) owned[pid] = 1
      }
      # `comm` is not the last column here, so the platform truncates it (16
      # characters of the executable path on macOS, 15 of its basename on
      # Linux) and a Pi installed under a longer path reads as a name it does
      # not have. Count an engine when EITHER witness names it, exactly as
      # control_herdr_target_engine_snapshot below does: the untruncated argv0
      # is authoritative, and a spurious second match can only make the
      # exactly-one postcondition refuse.
      # A zombie is a reaped engine that no longer runs anything, so it is
      # neither the one live replacement nor a duplicate worker; both sibling
      # readers over this same ps format skip it, and counting it here would
      # report a relaunch with no worker running or refuse a healthy one.
      for (pid in owned) {
        if (!owned[pid] || state[pid] ~ /^Z/) continue
        name = base(command[pid])
        argname = base(argv0[pid])
        if (name == "pi" || argname == "pi") { pi++; pi_pid = pid }
        else if (name == "pi-signed" || argname == "pi-signed") { signed++; signed_pid = pid }
      }
      printf "%d %d %d %d %d", pi, signed, pi_pid, signed_pid, parent[pi_pid]
    }
  ') || return 1
  read -r pi_count signed_count pi_pid signed_pid pi_parent <<EOF
$counts
EOF
  [ "$pi_count" -eq 1 ] || return 1
  [ "$signed_count" -eq 0 ] || [ "$pi_parent" = "$signed_pid" ] || return 1
  case "$TARGET_HARNESS" in
    pi) [ "$signed_count" -le 1 ] || return 1 ;;
    pi-signed) [ "$signed_count" -eq 1 ] || return 1 ;;
    *) return 1 ;;
  esac
  printf '%s:%s\t%s:%s:%s:%s' "$kind" "$value" "$state_seq" "$shell_pid" "$pi_pid" "$signed_pid"
}

# Read the pane's CURRENT herdr:pi session generation as a three-way answer, so
# the relaunch postcondition can never silently degrade from "a DISTINCT valid
# generation" to "any valid generation".
#   0  prints `<kind>:<value>` - a readable, valid generation is registered.
#   2  prints `none` - the pane's own agent record positively proves no
#      herdr:pi generation is registered (a plain dead pane, or another
#      harness's agent), which the caller may safely compare against.
#   1  prints nothing - unreadable or ambiguous; the caller must refuse.
# The selector deliberately reads the same agent-level `agent == "pi"` and
# `agent_session.source == "herdr:pi"` fields as
# control_herdr_pi_authority_snapshot, so the before and after halves of the
# distinctness proof can never disagree about which field carries the identity.
control_current_herdr_pi_session_ref() {
  local session pane out rc=0 fields kind value
  [ "$BACKEND" = herdr ] || return 1
  session=$(fm_backend_meta_exact_value "$META" herdr_session) || return 1
  pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || return 1
  out=$(control_herdr_cli "$session" agent get "$pane" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$(fm_backend_agent_state herdr "$session:$pane" 2>/dev/null)" = dead ] || return 1
    printf 'none'
    return 2
  fi
  printf '%s' "$out" | jq -e '
    .result.type == "agent_info" and (.result.agent | type) == "object"
  ' >/dev/null 2>&1 || return 1
  fields=$(printf '%s' "$out" | jq -er '
    [ .result.agent
      | select(.agent == "pi")
      | .agent_session
      | select(type == "object" and .source == "herdr:pi")
      | select((.kind | type) == "string" and (.value | type) == "string")
      | [ .kind, .value ] | @tsv
    ] | .[0] // ""
  ' 2>/dev/null) || return 1
  if [ -z "$fields" ]; then
    printf 'none'
    return 2
  fi
  IFS=$'\t' read -r kind value <<EOF
$fields
EOF
  control_herdr_pi_session_generation_valid "$kind" "$value" || return 1
  printf '%s:%s' "$kind" "$value"
}

wait_new_herdr_pi_authority() {  # <prior-session-ref>
  local prior=${1:-} elapsed=0 sample previous='' stable=0
  [ -n "$prior" ] || return 1
  while :; do
    sample=$(control_herdr_pi_authority_snapshot "$prior" 2>/dev/null) || sample=
    if [ -n "$sample" ] && [ "$sample" = "$previous" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 1 ] && return 0
    else
      stable=0
    fi
    previous=$sample
    awk -v e="$elapsed" -v t="$LAUNCH_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  return 1
}

# True when the fleet's harness-process identity owner
# (bin/fm-session-lock-lib.sh) can name <harness> at all, which is the exact
# precondition for the non-Pi replacement proof below being able to answer.
# Asking that owner rather than growing a second harness-name table here is what
# keeps the two from disagreeing, and asking it for the SAME capability the
# proof uses is what keeps this pre-launch gate from admitting a target the
# post-launch proof could never read; an adapter it cannot name positively is
# ambiguity, and the caller refuses.
control_herdr_target_engine_nameable() {  # <harness>
  local harness=${1:-}
  [ -n "$harness" ] || return 1
  fm_harness_name_pattern "$harness" >/dev/null 2>&1
}

# True when the process described by <comm> and its full <args> is the named
# harness, decided by the fleet's single owner of that question so this proof
# recognizes exactly what the rest of the fleet does - a version-named native
# install, a macOS-truncated comm answered by argv[0], and an npm-installed
# Claude Code running under a bare `node`. Pi is not routed through here: it
# keeps its own vocabulary above, because the launcher and the signed wrapper
# both name a running Pi.
control_herdr_process_names_harness() {  # <harness> <comm> <args>
  fm_harness_process_is "${1:-}" "${2:-}" "${3:-}"
}

# One sample of a NON-Pi replacement running in the task's own endpoint after a
# released stale Pi authority. Herdr keeps exposing its cached process-detected
# `pi` label in that state, so the backend's `alive` verdict is a statement
# about the agent that already exited and can never prove the target runtime
# started. The pane's own process tree is the authority instead: exactly one
# independent target-harness process below the recorded pane shell, and no Pi
# engine left anywhere under it. Prints a stable fingerprint on success.
control_herdr_target_engine_snapshot() {  # <target-harness>
  local harness=${1:-} session workspace tab pane wt_real pane_json pane_cwd process_json shell_pid
  local ps_bin rows descendants pid ppid comm argv0 args target_pids=' ' target_rows='' roots=0
  local parent_map=' ' chain='' walk='' rest='' hops=0 independent=1 root_chain=''
  [ -n "$harness" ] || return 1
  control_herdr_target_engine_nameable "$harness" || return 1
  session=$(fm_backend_meta_exact_value "$META" herdr_session) || return 1
  workspace=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || return 1
  tab=$(fm_backend_meta_exact_value "$META" herdr_tab_id) || return 1
  pane=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || return 1
  [ "$T" = "$session:$pane" ] || return 1
  wt_real=$(control_real_dir "$WT") || return 1
  pane_json=$(control_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  pane_cwd=$(printf '%s' "$pane_json" | jq -er \
    --arg pane "$pane" --arg tab "$tab" --arg workspace "$workspace" '
      .result as $result
      | select($result.type == "pane_info")
      | $result.pane
      | select(.pane_id == $pane and .tab_id == $tab and .workspace_id == $workspace)
      | select((.foreground_cwd | type) == "string" and (.foreground_cwd | length) > 0)
      | .foreground_cwd
    ' 2>/dev/null) || return 1
  pane_cwd=$(control_real_dir "$pane_cwd") || return 1
  [ "$pane_cwd" = "$wt_real" ] || return 1

  process_json=$(control_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) || return 1
  shell_pid=$(printf '%s' "$process_json" | jq -er --arg pane "$pane" '
    .result
    | select(.type == "pane_process_info" and .process_info.pane_id == $pane)
    | .process_info.shell_pid
    | select(type == "number" and . > 1)
    | floor
  ' 2>/dev/null) || return 1
  ps_bin=${FM_HERDR_PS_BIN:-ps}
  command -v "$ps_bin" >/dev/null 2>&1 || return 1
  rows=$("$ps_bin" -axo pid=,ppid=,pgid=,stat=,comm=,args= 2>/dev/null) || return 1
  descendants=$(printf '%s\n' "$rows" | awk -v shell="$shell_pid" '
    {
      if ($1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || NF < 5 || seen[$1]++) {
        bad = 1
        next
      }
      parent[$1] = $2
      state[$1] = $4
      command[$1] = $5
      argv0[$1] = (NF >= 6 ? $6 : "")
      # The whole argument string, rejoined, so the identity owner can read the
      # script path of a bare interpreter the way it does everywhere else.
      full = ""
      for (i = 6; i <= NF; i++) full = (full == "" ? $i : full " " $i)
      args[$1] = full
      present[$1] = 1
    }
    END {
      if (bad || !present[shell]) exit 1
      owned[shell] = 1
      do {
        changed = 0
        for (pid in present) if (owned[pid] != 1 && owned[parent[pid]] == 1) {
          owned[pid] = 1
          changed = 1
        }
      } while (changed)
      for (pid in owned) {
        if (owned[pid] != 1 || pid == shell || state[pid] ~ /^Z/) continue
        printf "%s\t%s\t%s\t%s\t%s\n", pid, parent[pid], command[pid], argv0[pid], args[pid]
      }
    }
  ') || return 1

  while IFS=$'\t' read -r pid ppid comm argv0 args; do
    [ -n "$pid" ] || continue
    if control_herdr_pi_engine_process_name "$comm" \
       || { [ -n "$argv0" ] && control_herdr_pi_engine_process_name "$argv0"; }; then
      return 1
    fi
    parent_map="$parent_map$pid=$ppid "
    if control_herdr_process_names_harness "$harness" "$comm" "$args"; then
      target_pids="$target_pids$pid "
      target_rows="$target_rows$pid $ppid"$'\n'
    fi
  done <<EOF
$descendants
EOF

  # A harness may run its own nested worker chain (Claude Code's bg-pty-host
  # tree is contiguous, and a helper of its own can sit behind an intermediate
  # shell), so "exactly one replacement" counts INDEPENDENT target processes -
  # those with no target anywhere in their ancestry up to the pane shell - never
  # raw process instances and never immediate parentage alone. The accepted
  # root's whole ancestry is part of the fingerprint, so a replacement that
  # changes what it hangs from cannot pass as the same stable sample; an
  # ancestry that leaves the sampled tree or does not terminate is unreadable
  # evidence and refuses rather than counting as a root.
  while read -r pid ppid; do
    [ -n "$pid" ] || continue
    chain=$pid
    walk=$ppid
    hops=0
    independent=1
    while [ "$walk" != "$shell_pid" ]; do
      [ "$hops" -lt 64 ] || return 1
      case "$target_pids" in
        *" $walk "*) independent=0; break ;;
      esac
      chain="$chain<$walk"
      rest=${parent_map#*" $walk="}
      [ "$rest" != "$parent_map" ] || return 1
      walk=${rest%% *}
      case "$walk" in ''|*[!0-9]*) return 1 ;; esac
      hops=$((hops + 1))
    done
    [ "$independent" -eq 1 ] || continue
    roots=$((roots + 1))
    root_chain="$chain<$shell_pid"
  done <<EOF
$target_rows
EOF
  [ "$roots" -eq 1 ] || return 1
  printf '%s:%s' "$shell_pid" "$root_chain"
}

wait_new_herdr_target_engine() {  # <target-harness>
  local harness=${1:-} elapsed=0 sample previous='' stable=0
  [ -n "$harness" ] || return 1
  while :; do
    sample=$(control_herdr_target_engine_snapshot "$harness" 2>/dev/null) || sample=
    if [ -n "$sample" ] && [ "$sample" = "$previous" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 1 ] && return 0
    else
      stable=0
    fi
    previous=$sample
    awk -v e="$elapsed" -v t="$LAUNCH_WAIT" 'BEGIN{exit !(e < t)}' || break
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
  return 1
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
  local state cmd verdict cancel interrupt_result=not-needed stale_pi
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

  # Herdr can retain Pi's old full-lifecycle authority after Pi exits back into
  # Treehouse's nested shell. Check that exact task-scoped shape before typing:
  # recovered means the supported release boundary made the endpoint positively
  # agent-free; live means a Pi process is visibly present and ordinary exit is
  # still correct; refused means terminal input could hit an unattributed shell.
  stale_pi=not-applicable
  if control_herdr_pi_recovery_applicable; then
    stale_pi=$(control_maybe_release_stale_herdr_pi)
  fi
  case "$stale_pi" in
    recovered)
      control_accept_recovered_herdr_pi
      retire_busy_incarnation
      printf 'stopped'
      return 0
      ;;
    live|not-applicable) ;;
    *) die "task $ID has a non-working Herdr Pi registration, but its exact Treehouse nested-shell exit, process generation, or ownership could not be proved stable; refusing to send a lifecycle command or launch a replacement" ;;
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
  if ! state=$(wait_agent_state "$EXIT_WAIT" dead); then
    # The normal Pi exit may have landed while Herdr retained the old authority.
    # Re-run the same exact proof now that control returned from the TUI. This is
    # the only post-submit recovery and never retries the lifecycle command.
    stale_pi=not-applicable
    if control_herdr_pi_recovery_applicable; then
      stale_pi=$(control_maybe_release_stale_herdr_pi)
    fi
    case "$stale_pi" in
      recovered)
        control_accept_recovered_herdr_pi
        state=dead
        ;;
      *)
        die "exit-delivered $ID interrupt=$interrupt_result exit-command=delivered agent-state=$state exit=unconfirmed; the agent did not stop within ${EXIT_WAIT}s and no exact stable Herdr Pi nested-shell exit could be proved"
        ;;
    esac
  fi
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
      ''|low|medium|high|xhigh|max) ;;
      *)
        echo "warning: config/secondmate-harness effort token '$CONFIG_EFFORT' is not one of low, medium, high, xhigh, max; ignoring" >&2
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
}

# safe_checkpoint: prove, before anything is stopped, that the work a relaunch
# must preserve is actually there and recoverable afterwards. Fills
# CHECKPOINT_LINES with the journal lines describing what it proved, and
# refuses outright when any of it cannot be established.
CHECKPOINT_LINES=()
safe_checkpoint() {
  local wt_real wt_top wt_top_real head head_ref head_ref_status status_output dirty children marker child_meta
  CHECKPOINT_LINES=()
  [ -n "$WT" ] || die "task $ID has no recorded worktree; refusing to relaunch without a recorded local copy to preserve"
  [ -d "$WT" ] || die "task $ID's recorded worktree $WT is missing; refusing to relaunch and lose track of its work"
  wt_real=$(cd "$WT" 2>/dev/null && pwd -P) || die "task $ID's recorded worktree $WT cannot be resolved"
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
  local stamp
  [ -n "$NOTE" ] || return 0
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' "$NOTE" > "$NOTE_FILE"
  case "$KIND" in
    ship|scout)
      cp -p "$RELAUNCH_BRIEF" "$BRIEF_PRIOR" \
        || die "could not preserve task $ID's instructions before recording the progress note"
      {
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
      } >> "$RELAUNCH_BRIEF" \
        || die "could not append the progress note to task $ID's instructions"
      ;;
  esac
}

do_relaunch() {
  local exit_result state note_line prior_herdr_pi_session='' authority_line='' release_capability=''
  local prior_session_rc=1
  local -a spawn_args

  require_state_verified_backend relaunch
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

  RELAUNCH_TX="${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  journal_write stopping "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  # Read the identity the stale-authority postcondition will have to differ
  # from before do_exit can retire it, under every condition that can still
  # reach a release. Whether an unreadable answer is fatal is decided once that
  # release is known, because only a released authority runs that postcondition
  # - an ordinary relaunch proves its replacement by the endpoint's own
  # dead-then-alive transition and never consults this.
  if control_herdr_pi_recovery_applicable; then
    case "$TARGET_HARNESS" in
      pi|pi-signed)
        prior_session_rc=0
        prior_herdr_pi_session=$(control_current_herdr_pi_session_ref) || prior_session_rc=$?
        ;;
    esac
  fi
  exit_result=$(do_exit)
  if [ -f "$HERDR_PI_RELEASE_PROOF" ] && [ ! -L "$HERDR_PI_RELEASE_PROOF" ] \
     && [ "$(fm_backend_meta_exact_value "$HERDR_PI_RELEASE_PROOF" tx 2>/dev/null)" = "$RELAUNCH_TX" ]; then
    HERDR_PI_STALE_RELEASED=1
  fi
  journal_write exited "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"

  # Both halves of the released-authority postcondition are decided here, before
  # any replacement is launched: a Pi target can only be proved distinct from the
  # generation that was released, and a non-Pi target can only be proved by its
  # own process identity. Either answer is already known, so a target this
  # transaction could never verify is refused while the prior record still
  # stands and no replacement is running.
  if [ "$HERDR_PI_STALE_RELEASED" = 1 ]; then
    case "$TARGET_HARNESS" in
      pi|pi-signed)
        case "$prior_session_rc" in
          0|2) ;;
          *) die "task $ID's stale Herdr Pi authority was released, but the herdr:pi session identity it held could not be read, so a replacement could not be proved to anchor a DISTINCT herdr:pi generation; refusing rather than accepting any session as new" ;;
        esac
        ;;
      *)
        control_herdr_target_engine_nameable "$TARGET_HARNESS" \
          || die "task $ID's stale Herdr Pi authority was released, so only $TARGET_HARNESS's own processes could prove a replacement started - and $TARGET_HARNESS has no process identity this proof can read; refusing before any replacement is launched rather than reporting one the cached Pi label alone would have proved"
        ;;
    esac
  fi

  # The launch owner (fm-spawn --relaunch) clears the previous incarnation's
  # per-task harness wiring before arming the new one, so nothing to do here.
  journal_write launching "${CHECKPOINT_LINES[@]}" "$note_line" "relaunch_tx=$RELAUNCH_TX"
  spawn_args=("$ID" --relaunch --harness "$TARGET_HARNESS")
  [ "$TARGET_MODEL" = default ] || spawn_args+=(--model "$TARGET_MODEL")
  [ "$TARGET_EFFORT" = default ] || spawn_args+=(--effort "$TARGET_EFFORT")
  [ "$HERDR_PI_STALE_RELEASED" = 0 ] || release_capability=$RELAUNCH_TX
  if FM_CONTROL_RELAUNCH_TX="$RELAUNCH_TX" \
      FM_CONTROL_HERDR_PI_RELEASE_PROOF="$release_capability" \
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
  # A released stale Pi authority leaves Herdr exposing its cached
  # process-detected `pi` label, so wait_agent_state's `alive` verdict above
  # describes the agent that already exited. This is the only state where that
  # gap exists - an ordinary relaunch positively read `dead` before launching,
  # so its `alive` is already proof of the replacement - and here the runtime
  # that actually started proves itself or the relaunch refuses.
  if [ "$HERDR_PI_STALE_RELEASED" = 1 ]; then
    case "$TARGET_HARNESS" in
      pi|pi-signed)
        wait_new_herdr_pi_authority "$prior_herdr_pi_session" || {
          die "the replacement agent for $ID appeared, but a distinct stable herdr:pi session with exactly one Pi engine could not be verified on its recorded endpoint and worktree"
        }
        authority_line=herdr_pi_authority=new-session
        ;;
      *)
        wait_new_herdr_target_engine "$TARGET_HARNESS" || {
          die "the replacement agent for $ID could not be verified as exactly one stable $TARGET_HARNESS process, with no Pi engine left, on its recorded endpoint and worktree within ${LAUNCH_WAIT}s after its stale Herdr Pi authority was released"
        }
        authority_line=herdr_pi_authority=released-target-engine
        ;;
    esac
  fi
  RELAUNCH_AGENT_CONFIRMED=1
  if [ "$HERDR_PI_STALE_RELEASED" = 1 ]; then
    if [ -f "$HERDR_PI_RELEASE_PROOF" ] && [ ! -L "$HERDR_PI_RELEASE_PROOF" ]; then
      rm -f "$HERDR_PI_RELEASE_PROOF" \
        || die "the replacement agent is running, but its consumed stale-authority proof could not be retired"
    else
      die "the replacement agent is running, but its consumed stale-authority proof could not be retired"
    fi
  fi

  if [ -n "$authority_line" ]; then
    journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result" "$authority_line"
  else
    journal_write complete "${CHECKPOINT_LINES[@]}" "$note_line" "exit_result=$exit_result"
  fi
  RELAUNCH_ACTIVE=0
  echo "relaunched $ID harness=$TARGET_HARNESS from=$PRIOR_RECORDED_HARNESS model=$TARGET_MODEL effort=$TARGET_EFFORT backend=$BACKEND endpoint=$T worktree=$WT"
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

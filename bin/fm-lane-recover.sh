#!/usr/bin/env bash
# fm-lane-recover.sh - bounded recovery ladder for a dead or degraded response
# lane. Dry run by default; acting requires an explicit config off-switch.
#
# Usage:
#   fm-lane-recover.sh plan            print what the ladder would do, change nothing
#   fm-lane-recover.sh run             act, and only when RECOVERY=acting
#   fm-lane-recover.sh clear <lane>    release a lane parked at the escalation rung
#   fm-lane-recover.sh log <lane>      print that lane's ladder log
#   fm-lane-recover.sh --help          print this help
#
# The ladder does NOT decide whether a lane is unhealthy, and it contains no
# copy of that judgment. bin/fm-lane-liveness.sh is the single owner of the
# verdict; this script runs it once, reads the verdict per lane, and owns only
# the response. A lane's reading and a lane's remedy stay separable that way,
# and the read-only rail stays reviewable on its own.
#
# WHAT IT REFUSES, and these are the safety properties rather than niceties:
#
#   - It never targets THE-FM. The ladder is one-directional and always acts on
#     a response lane, never on the supervisor. A lane whose home is this home,
#     or whose record is not a secondmate, is refused by assertion.
#   - It never acts on a lane the rail could not read. An `unknown` verdict
#     means unread, and unread is not dead.
#   - It never relaunches on inconclusive evidence. Recovery is authorized only
#     by a probe state of `dead` or `missing`; `ambiguous`, `unreadable`, and
#     `unverified` leave the endpoint untouched, because relaunching beside a
#     live agent is how unlanded work gets destroyed.
#   - It never discards unlanded work. No rung removes a worktree, a branch, a
#     commit, or an inbox message.
#   - It stops. Each rung has a per-lane attempt ceiling and a cooldown, so a
#     permanently broken lane escalates once with its evidence instead of
#     flapping, and a lane parked at the escalation rung stays out of automatic
#     recovery until a person clears it. Recovery must not fight a human.
#
# NOTHING IS REIMPLEMENTED HERE. Endpoint probing is
# fm_secondmate_liveness_probe. A dead endpoint is restarted through
# fm_secondmate_liveness_relaunch, the one guarded relaunch path the
# session-start sweep and the watcher tick already use. A live endpoint that
# must change profile goes through `bin/fm-control.sh <lane> relaunch
# --harness/--model`, whose own contract owns that case: it replaces the agent
# transactionally in the SAME worktree, so switching profile is one ordinary use
# of that verb rather than a second recovery path invented here. Each rung uses
# the existing owner of its case and adds no mechanism of its own.
#
# THE LADDER, strictly ordered, stopping at the first rung that applies:
#   1 restart_lane_agent       a proven dead or missing endpoint, relaunched
#   2 switch_model_or_harness  any error class the rail matched as a provider
#                              error, and never on a missing endpoint, where the
#                              provider is not the cause
#   3 redispatch               once, into a lane that is alive again, so the
#                              work orders it never claimed are re-sent
#   4 escalate_captain         record the whole ladder log, report, and park.
#                              Money and policy decisions land here and are
#                              never taken automatically.
#
# ORDERING, and why it is not the obvious one. Endpoint-probe liveness is an
# INPUT to the decision and never a terminal answer. Evaluating it first looks
# natural and is wrong: a lane that is process-alive but provider-dead then
# exits reporting that its endpoint probes alive, before the error class is ever
# consulted, which is a silent no-op on precisely the case this ladder exists
# for. So a probe that is alive merely fails to authorize rung 1, and the ladder
# carries on to the error class.
#
# For the same reason a rail verdict of `dead` or `degraded` that this ladder
# cannot remedy ends at rung 4 carrying its evidence, NEVER at `rung=none`.
# `rung=none` on an unhealthy lane reports success while doing nothing, which is
# the silent-failure class the whole design exists to remove. `rung=none` is
# reserved for a lane that is genuinely healthy, one the rail could not read at
# all (unread is not dead), and one already parked for a person.
#
# THE ERROR-CLASS SET IS THE RAIL'S DATA, not a copy kept here. It comes from
# `bin/fm-lane-liveness.sh classes`, and every class the rail marks as a matched
# provider error is rung-2 eligible. A class the rail does not publish is
# recorded as `unhandled_errclass` and routed to rung 4; it is never dropped
# through a default branch, which is how a real fleet's own failure string once
# fell through and rung 2 silently never fired for the one lane it was written
# for.
#
# PERSIST BEFORE REPLACING A LIVE AGENT, BOUNDED. Replacing a live agent should
# first let it record the open work it holds only in conversation. But a lane
# looping a provider error cannot answer that request by definition, so an
# unbounded persist-first gate hangs on exactly the lanes rung 2 targets. The
# resolution is a bounded attempt: ask, wait PERSIST_TIMEOUT seconds, and on no
# answer record `persist_impossible` in the ladder log and proceed. The safety
# justification is recorded with it: an agent that cannot reach its provider
# cannot have landed work, so there is no in-progress state the replacement can
# lose, and the relaunch verb preserves the worktree and its unlanded commits by
# construction. Escalate-only for a live endpoint was considered and declined,
# because it would turn rung 2's entire purpose into a page.
#
# Config: config/response-lanes.conf, shared with the rail so there is one
# config surface for one subsystem. docs/configuration.md "Response lanes" owns
# the schema. RECOVERY is the off-switch and defaults to off.
#
# FM_LANE_RAIL names the rail this ladder asks for its verdicts and its class
# vocabulary, defaulting to the sibling bin/fm-lane-liveness.sh. Both questions
# go to the same one, so a ladder can never judge with one rail's verdict and
# another's vocabulary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG="$CONFIG_DIR/response-lanes.conf"
RAIL="${FM_LANE_RAIL:-$SCRIPT_DIR/fm-lane-liveness.sh}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"

RECOVERY=off
ATTEMPT_CEILING=2
# Rung 2 admits one model switch per lane, whatever ATTEMPT_CEILING says: the
# design's worst case is two restarts, one model switch, one redispatch, then a
# page, and that specific envelope overrides the generic default.
SWITCH_CEILING=1
COOLDOWN=3600
SWITCH_MODEL=
SWITCH_HARNESS=
RELAUNCH_TIMEOUT=300
PERSIST_TIMEOUT=30
SSH_TIMEOUT=10
SWEEP_INBOX=
SWEEP_SOURCE=

ACTING=
NOW=

usage() {
  cat <<'USAGE'
fm-lane-recover.sh - bounded recovery ladder for an unhealthy response lane.

  plan            print what the ladder would do, changing nothing
  run             act, and only when RECOVERY=acting in config
  clear <lane>    release a lane parked at the escalation rung
  log <lane>      print that lane's ladder log
  --help          print this help

bin/fm-lane-liveness.sh owns the verdict; this script owns only the response.
Rung 1 relaunches only a proven dead or missing endpoint, through the guarded
path in bin/fm-secondmate-liveness-lib.sh; rung 2 switches a provider-faulted
lane onto the configured profile through bin/fm-control.sh's relaunch verb.
THE-FM is never a target, and no rung discards unlanded work.
docs/configuration.md "Response lanes" owns the config schema.
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

is_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

config_load() {
  local line key value lanes=0 lineno=0
  [ -f "$CONFIG" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$(( lineno + 1 ))
    case "$line" in
      ''|'#'*) continue ;;
      'lane '*)
        lanes=$(( lanes + 1 ))
        continue
        ;;
    esac
    case "$line" in
      *=*)
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
          RECOVERY)
            case "$value" in
              off|dry-run|acting) RECOVERY=$value ;;
              *) die "response-lanes.conf line $lineno: RECOVERY must be off, dry-run, or acting" ;;
            esac
            ;;
          ATTEMPT_CEILING|PERSIST_TIMEOUT)
            is_int "$value" || die "response-lanes.conf line $lineno: $key needs a whole number"
            case "$key" in
              ATTEMPT_CEILING) ATTEMPT_CEILING=$value ;;
              PERSIST_TIMEOUT) PERSIST_TIMEOUT=$value ;;
            esac
            ;;
          COOLDOWN|RELAUNCH_TIMEOUT|SSH_TIMEOUT)
            is_int "$value" || die "response-lanes.conf line $lineno: $key needs a whole number"
            [ "$value" -gt 0 ] \
              || die "response-lanes.conf line $lineno: $key must be a positive whole number, because a zero bound disables the bound instead of applying it"
            case "$key" in
              COOLDOWN) COOLDOWN=$value ;;
              RELAUNCH_TIMEOUT) RELAUNCH_TIMEOUT=$value ;;
              SSH_TIMEOUT) SSH_TIMEOUT=$value ;;
            esac
            ;;
          SWITCH_MODEL) SWITCH_MODEL=$value ;;
          SWITCH_HARNESS) SWITCH_HARNESS=$value ;;
          # Every other key belongs to the rail, which validates its own.
          *) ;;
        esac
        ;;
      *) ;;
    esac
  done < "$CONFIG"
  [ "$lanes" -gt 0 ]
}

# --- the ladder log ----------------------------------------------------------
#
# One row per rung the ladder tried, so "each rung records what it tried" is a
# file a person can read rather than a claim. It is also the input to the
# per-rung ceiling, the cooldown, and the parked state.
#   <epoch>\t<rung>\t<outcome>\t<detail>

ladder_log() {  # <lane>
  printf '%s/.lane-recovery-%s' "$STATE" "$1"
}

ladder_record() {  # <lane> <rung> <outcome> <detail>
  local f
  f=$(ladder_log "$1")
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  umask 077
  printf '%s\t%s\t%s\t%s\n' "$NOW" "$2" "$3" "$4" >> "$f"
}

# Attempts of one rung for one lane inside the cooldown window, counted after
# the most recent `cleared` row so clearing a parked lane genuinely re-arms it.
ladder_attempts() {  # <lane> <rung>
  local f
  f=$(ladder_log "$1")
  [ -f "$f" ] || { printf '0'; return 0; }
  awk -F '\t' -v rung="$2" -v cutoff="$(( NOW - COOLDOWN ))" '
    $3 == "cleared" { n = 0; next }
    $1 ~ /^[0-9]+$/ && $1 >= cutoff && $2 == rung && $3 == "attempt" { n++ }
    END { print n + 0 }' "$f" 2>/dev/null
}

ladder_parked() {  # <lane>
  local f
  f=$(ladder_log "$1")
  [ -f "$f" ] || return 1
  awk -F '\t' '
    $3 == "cleared" { parked = 0; next }
    $3 == "parked" { parked = 1 }
    END { exit parked ? 0 : 1 }' "$f" 2>/dev/null
}

# --- lane eligibility --------------------------------------------------------

# lane_target_refusal <lane>: prints the refusal reason and returns 0 when this
# lane must never be a ladder target. THE-FM is the case this exists for.
lane_target_refusal() {  # <lane>
  local lane=$1 meta home kind
  meta="$STATE/$lane.meta"
  if [ ! -f "$meta" ]; then
    printf 'no lane record in this home, so nothing proves it is a response lane'
    return 0
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" != secondmate ]; then
    printf 'record is kind=%s rather than a response lane' "${kind:-unset}"
    return 0
  fi
  home=$(fm_meta_get "$meta" home)
  if [ -z "$home" ]; then
    printf 'record names no home, so the target cannot be proven to be a lane'
    return 0
  fi
  # The ladder is one-directional: never the supervisor it runs in.
  if [ "$(cd -- "$home" 2>/dev/null && pwd -P)" = "$(cd -- "$FM_HOME" 2>/dev/null && pwd -P)" ]; then
    printf 'target resolves to THE-FM itself, which the ladder never restarts or recreates'
    return 0
  fi
  return 1
}

# --- rung decision -----------------------------------------------------------
#
# Fills RUNG, RUNG_WHY, and RUNG_CMD for one lane. RUNG_CMD is the exact thing
# `run` would do, printed verbatim by `plan`, so the dry run and the acting run
# can never describe different actions.

# rail_classes: the class vocabulary the rail publishes, as "<class> <matched>"
# rows. Asked once per sweep. A rail that cannot answer leaves this empty, and an
# empty vocabulary makes every class unrecognised, which routes to rung 4 rather
# than quietly treating a real provider error as healthy.
RAIL_CLASSES=

rail_classes_load() {
  RAIL_CLASSES=$("$RAIL" classes 2>/dev/null \
    | awk '$1=="class" {sub(/^matched=/,"",$3); print $2, $3}') || RAIL_CLASSES=
}

# errclass_kind <class>: `fault` when the rail matched a provider error,
# `clean` when it published the class as not-a-fault, `unhandled` otherwise.
errclass_kind() {
  local want=$1 class matched
  while read -r class matched; do
    [ "$class" = "$want" ] || continue
    case "$matched" in
      yes) printf 'fault'; return 0 ;;
      no) printf 'clean'; return 0 ;;
    esac
  done <<EOF
$RAIL_CLASSES
EOF
  printf 'unhandled'
}

rung_decide() {  # <lane> <verdict> <errclass> <pending> <beatage>
  local lane=$1 verdict=$2 errclass=$3 pending=$4 beatage=$5 meta refusal kind restarts switches why
  RUNG=''
  RUNG_WHY=''
  RUNG_CMD=''
  RUNG_NOTE=''
  meta="$STATE/$lane.meta"

  if refusal=$(lane_target_refusal "$lane"); then
    RUNG=refused
    RUNG_WHY=$refusal
    return 0
  fi
  case "$verdict" in
    alive)
      RUNG=none
      RUNG_WHY='lane is alive, so the ladder has nothing to do'
      return 0
      ;;
    unknown)
      RUNG=none
      RUNG_WHY='the rail could not read this lane, and unread is not dead'
      return 0
      ;;
  esac
  if ladder_parked "$lane"; then
    RUNG=none
    RUNG_WHY='lane is parked at the escalation rung and stays out of automatic recovery until it is cleared'
    return 0
  fi

  # The probe is the authority on whether a RESTART is permitted. It is consulted
  # here as an input; an alive endpoint does not end the decision, it only fails
  # to authorize rung 1.
  fm_secondmate_liveness_probe "$meta" "$lane" poll
  if [ "$FM_SM_LIVE_STATUS" = silent ]; then
    RUNG=refused
    RUNG_WHY='record names no endpoint, which secondmate provisioning owns rather than the ladder'
    return 0
  fi

  kind=$(errclass_kind "$errclass")
  restarts=$(ladder_attempts "$lane" restart_lane_agent)
  switches=$(ladder_attempts "$lane" switch_model_or_harness)

  # Rung 1, only on evidence that proves no agent is running. ambiguous,
  # unreadable, and unverified never reach here.
  if [ "$FM_SM_LIVE_STATUS" = relaunchable ] && [ "$restarts" -lt "$ATTEMPT_CEILING" ]; then
    RUNG=restart_lane_agent
    RUNG_WHY="endpoint is $FM_SM_LIVE_STATE ($FM_SM_LIVE_CAUSE), attempt $(( restarts + 1 )) of $ATTEMPT_CEILING"
    RUNG_CMD="fm_secondmate_liveness_relaunch $STATE/$lane.meta $lane $RELAUNCH_TIMEOUT"
    return 0
  fi

  # Rung 2. Reached whether the endpoint is alive or already restarted to its
  # ceiling, because a provider fault is not cured by another restart. Only a
  # conclusive probe admits it: an endpoint the probe could not read is
  # escalated with that evidence instead of being replaced on a guess.
  if [ "$kind" = fault ]; then
    case "$FM_SM_LIVE_STATUS" in
      alive|relaunchable) ;;
      *)
        rung_escalate "$lane" "$pending" "error class $errclass with an endpoint probe the liveness library reports as inconclusive (status $FM_SM_LIVE_STATUS, state $FM_SM_LIVE_STATE), so no rung may replace an agent it could not read"
        return 0
        ;;
    esac
    if [ "$FM_SM_LIVE_STATE" = missing ]; then
      rung_escalate "$lane" "$pending" "error class $errclass on a missing endpoint, so the provider is not the cause and rung 2 does not apply"
      return 0
    fi
    if [ -z "$SWITCH_MODEL" ] && [ -z "$SWITCH_HARNESS" ]; then
      rung_escalate "$lane" "$pending" "error class $errclass needs a profile switch, and no SWITCH_MODEL or SWITCH_HARNESS is configured to move it onto"
      return 0
    fi
    if [ "$switches" -lt "$SWITCH_CEILING" ]; then
      RUNG=switch_model_or_harness
      RUNG_WHY="rail matched provider error class $errclass, so the provider is the suspect (endpoint $FM_SM_LIVE_STATE, switch attempt $(( switches + 1 )) of $SWITCH_CEILING)"
      RUNG_CMD="$SCRIPT_DIR/fm-control.sh $lane relaunch${SWITCH_HARNESS:+ --harness $SWITCH_HARNESS}${SWITCH_MODEL:+ --model $SWITCH_MODEL}"
      [ "$FM_SM_LIVE_STATUS" != relaunchable ] \
        && RUNG_NOTE="endpoint is alive, so persist is attempted for ${PERSIST_TIMEOUT}s first and persist_impossible is recorded on timeout"
      return 0
    fi
    rung_escalate "$lane" "$pending" "both the restart and the provider-switch ceilings are spent on error class $errclass"
    return 0
  fi

  if [ "$kind" = unhandled ]; then
    RUNG=escalate_captain
    RUNG_WHY="unhandled_errclass: the rail reported class '${errclass:-empty}', which its published vocabulary does not contain, so no rung may assume what it means"
    RUNG_NOTE=unhandled_errclass
    return 0
  fi

  # A clean error class and no restart authority. The lane is still unhealthy, so
  # this must escalate with its evidence rather than report nothing to do.
  if [ "$FM_SM_LIVE_STATUS" = relaunchable ]; then
    rung_escalate "$lane" "$pending" "restart ceiling of $ATTEMPT_CEILING reached and error class ${errclass:-unknown} is not a provider fault, so no further rung applies"
    return 0
  fi
  why="rail verdict $verdict with no provider fault and an endpoint this ladder may not relaunch (state $FM_SM_LIVE_STATE): ${FM_SM_LIVE_REASON:-no relaunch authority}"
  if is_int "$beatage" && [ "$beatage" -gt 0 ]; then
    why="$why; supervision beat age ${beatage}s is the evidence, and rearming another home's watcher has no scriptable primitive (fm_watch_arm_pi and fm_watch_arm_omp are in-harness tools of that home), so this escalates rather than pretending to repair it"
  elif [ "${beatage:-}" = - ]; then
    why="$why; watcher_beat_age_s=- is the supervision evidence this reading carries, because a beat that could never be established is a home with no supervision to weigh against the verdict"
  fi
  rung_escalate "$lane" "$pending" "$why"
}

# --- rung 3 -----------------------------------------------------------------
#
# Redispatch is the last rung before the page, and it applies only to a lane
# whose endpoint probes alive again: work re-sent into an endpoint running no
# agent is delivered to nobody. rung_escalate is how every escalation path
# asks for it first, so a recovered lane that still holds work it never
# claimed is re-sent that work once instead of being paged, and the attempt
# row the re-send writes makes the once-only cap at this rung reachable.

redispatch_applies() {  # <lane> <pending>
  local lane=$1 pending=$2
  is_int "$pending" && [ "$pending" -gt 0 ] || return 1
  [ "$(ladder_attempts "$lane" redispatch)" -lt 1 ] || return 1
}

rung_escalate() {  # <lane> <pending> <why>
  RUNG_WHY=$3
  if [ "$FM_SM_LIVE_STATUS" = alive ] && redispatch_applies "$1" "$2"; then
    RUNG=redispatch
    RUNG_CMD="redispatch_do $1"
    RUNG_WHY="endpoint probes alive again and the lane still holds $2 unclaimed work order(s), so rung 3 re-sends them once with fresh correlation ids so duplicates stay detectable, before the escalation this lane was headed for: $3"
    return 0
  fi
  RUNG=escalate_captain
}

# redispatch_frame <record-path>: the record as a `body <name>` header plus one
# line holding its body with backslashes doubled and each newline escaped, so a
# multi-line record crosses as exactly two lines and `printf %b` restores its
# bytes for the send loop.
redispatch_frame() {  # <record-path>
  printf 'body %s\n' "${1##*/}"
  awk 'p{print} /^--$/{p=1}' "$1" | sed -e 's/\\/\\\\/g' -e 's/$/\\n/' | tr -d '\n'
  printf '\n'
}

# shell_quote <value>: the value as one shell word. ssh joins its command
# arguments with spaces and the remote login shell parses that joined string,
# so a multi-word program crosses intact only when it is quoted for that parse.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# redispatch_frames: every unclaimed record of the lane's own inbox, read from
# the exact inbox path the rail printed after counting it, over ssh for the
# remote source the rail named and locally otherwise, so the inbox counted and
# the inbox re-sent are one string rather than two readings of one record.
redispatch_frames() {
  local inbox host f program remote
  inbox=$SWEEP_INBOX
  case "$inbox" in ''|-) return 1 ;; esac
  case "$SWEEP_SOURCE" in
    remote:*)
      host=${SWEEP_SOURCE#remote:}
      program=$(cat <<'REMOTE'
d=$1
[ -d "$d" ] || exit 0
for f in "$d"/*.msg; do
  [ -f "$f" ] || continue
  printf 'body %s\n' "${f##*/}"
  awk 'p{print} /^--$/{p=1}' "$f" | sed -e 's/\\/\\\\/g' -e 's/$/\\n/' | tr -d '\n'
  printf '\n'
done
REMOTE
)
      remote="sh -c $(shell_quote "$program") sh $(shell_quote "$inbox")"
      # stdin closed: this runs inside redispatch_do's frame loop, and a real
      # ssh drains its stdin, which would consume the loop's remaining lines.
      fm_run_timed "$SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
        "$host" "$remote" < /dev/null
      ;;
    *)
      for f in "$inbox"/*.msg; do
        [ -f "$f" ] || continue
        redispatch_frame "$f"
      done
      ;;
  esac
}

# redispatch_do <lane>: re-send each unclaimed record once through
# bin/fm-send.sh, and set REDISPATCH_SENT to how many were re-sent. The
# record's own correlation is stripped first so fm-send mints a fresh one:
# a fresh id keeps the re-send out of the remote enqueue's identical-body
# dedup and makes the duplicate detectable against the record it duplicates.
redispatch_do() {  # <lane>
  local lane=$1 frames line header='' name body failed=0
  REDISPATCH_SENT=0
  frames=$(redispatch_frames 2>/dev/null) || frames=
  [ -n "$frames" ] || return 1
  while IFS= read -r line; do
    if [ -n "$header" ]; then
      header=
      body=$(printf '%b' "$line")
      case "${body//[[:space:]]/}" in '') continue ;; esac
      body=$(printf '%s' "$body" | sed -E 's/corr=[A-Fa-f0-9]{16}//g')
      if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$lane" "$body" >/dev/null 2>&1; then
        REDISPATCH_SENT=$(( REDISPATCH_SENT + 1 ))
      else
        printf 'redispatch: %s could not be re-sent to %s\n' "$name" "$lane" >&2
        failed=$(( failed + 1 ))
      fi
      continue
    fi
    case "$line" in
      'body '*) name=${line#body }; header=1 ;;
    esac
  done <<EOF
$frames
EOF
  [ "$failed" -eq 0 ]
}

# --- modes ------------------------------------------------------------------

sweep() {
  local lane verdict errclass pending beatage line rail drained mover mode=dry-run
  rail_classes_load
  rail=$("$RAIL" read) || rail=
  if [ -z "$rail" ]; then
    printf 'error: the liveness rail produced no reading, so the ladder has no verdict to act on\n' >&2
    return 1
  fi
  [ -z "$ACTING" ] || mode=acting
  printf 'recovery=%s ceiling=%s cooldown=%ss mode=%s\n' \
    "$RECOVERY" "$ATTEMPT_CEILING" "$COOLDOWN" "$mode"
  printf '%s\n' "$rail" | while IFS= read -r line; do
    case "$line" in 'lane='*) ;; *) continue ;; esac
    lane=${line#lane=}
    lane=${lane%% *}
    verdict=$(printf '%s\n' "$line" | sed -n 's/.* verdict=\([^ ]*\).*/\1/p')
    errclass=$(printf '%s\n' "$line" | sed -n 's/.* error_signature_class=\([^ ]*\).*/\1/p')
    pending=$(printf '%s\n' "$line" | sed -n 's/.* pending_count=\([^ ]*\).*/\1/p')
    beatage=$(printf '%s\n' "$line" | sed -n 's/.* watcher_beat_age_s=\([^ ]*\).*/\1/p')
    drained=$(printf '%s\n' "$line" | sed -n 's/.* drained_while_error_active=\([^ ]*\).*/\1/p')
    mover=$(printf '%s\n' "$line" | sed -n 's/.* mover=\([^ ]*\).*/\1/p')
    SWEEP_INBOX=$(printf '%s\n' "$line" | sed -n 's/.* inbox=\([^ ]*\).*/\1/p')
    SWEEP_SOURCE=$(printf '%s\n' "$line" | sed -n 's/.* source=\([^ ]*\).*/\1/p')
    if [ "$drained" = yes ]; then
      if [ -z "$ACTING" ]; then
        printf 'lane=%s observation=drained_while_error_active mover=%s\n' \
          "$lane" "${mover:--}"
      elif ! ladder_record "$lane" rail drained_while_error_active "mover=${mover:--}"; then
        printf 'lane=%s observation=drained_while_error_active mover=%s reason=ladder log unwritable, so the observation is printed rather than recorded\n' \
          "$lane" "${mover:--}"
      fi
    fi
    # Acting holds the lane's own liveness lock across probe, decision, and
    # act, so the endpoint state the verdict rests on is the endpoint state
    # acted on and a concurrent supervisor cannot observe this replacement
    # mid-flight and classify the endpoint as dead. A lane whose lock is busy
    # is skipped whole; a plan never locks because it never acts.
    if [ -n "$ACTING" ]; then
      if fm_secondmate_liveness_lock "$lane"; then
        rung_decide "$lane" "$verdict" "$errclass" "$pending" "$beatage"
        lane_act "$lane" "$verdict" "$errclass"
        fm_secondmate_liveness_unlock "$lane"
      else
        printf 'lane=%s action=skipped reason=another supervisor holds this lane\n' "$lane"
      fi
    else
      rung_decide "$lane" "$verdict" "$errclass" "$pending" "$beatage"
      lane_act "$lane" "$verdict" "$errclass"
    fi
  done
}

# persist_attempt <lane>: bounded ask that a live lane record the open work it
# holds only in conversation, before its agent is replaced. Returns 0 when the
# lane answered inside the budget, 1 on timeout. Uses the ordinary steering
# plane; nothing here is a new transport.
persist_attempt() {  # <lane>
  local lane=$1 status_file before waited=0
  status_file="$STATE/$lane.status"
  before=$(wc -c < "$status_file" 2>/dev/null) || before=0
  "$SCRIPT_DIR/fm-send.sh" "$lane" \
    'Before your agent is replaced onto a different profile, durably record the open work you hold only in conversation: a task for each unfiled open record, and a status correction for each task whose recorded state is now stale.' \
    >/dev/null 2>&1 || return 1
  while [ "$waited" -lt "$PERSIST_TIMEOUT" ]; do
    sleep 1
    waited=$(( waited + 1 ))
    [ "$(wc -c < "$status_file" 2>/dev/null || printf 0)" -gt "$before" ] && return 0
  done
  return 1
}

lane_act() {  # <lane> <verdict> <errclass>
  local lane=$1 verdict=$2 errclass=$3 rc out detail lognote REDISPATCH_SENT=
  case "$RUNG" in
    none|refused)
      printf 'lane=%s verdict=%s rung=%s action=nothing reason=%s\n' \
        "$lane" "$verdict" "$RUNG" "$RUNG_WHY"
      return 0
      ;;
    escalate_captain)
      if [ -n "$ACTING" ]; then
        if { [ -z "$RUNG_NOTE" ] || ladder_record "$lane" escalate_captain "$RUNG_NOTE" "$RUNG_WHY"; } \
          && ladder_record "$lane" escalate_captain parked "$RUNG_WHY"; then
          printf 'lane=%s verdict=%s rung=escalate_captain action=parked%s reason=%s log=%s\n' \
            "$lane" "$verdict" "${RUNG_NOTE:+ note=$RUNG_NOTE}" "$RUNG_WHY" "$(ladder_log "$lane")"
        else
          printf 'lane=%s verdict=%s rung=escalate_captain action=skipped%s reason=ladder log unwritable, so no parked row was recorded and the lane stays under automatic recovery\n' \
            "$lane" "$verdict" "${RUNG_NOTE:+ note=$RUNG_NOTE}"
        fi
      else
        printf 'lane=%s verdict=%s rung=escalate_captain action=would-park%s reason=%s\n' \
          "$lane" "$verdict" "${RUNG_NOTE:+ note=$RUNG_NOTE}" "$RUNG_WHY"
      fi
      return 0
      ;;
  esac

  if [ -z "$ACTING" ]; then
    printf 'lane=%s verdict=%s rung=%s action=would-run cmd=%s reason=%s%s\n' \
      "$lane" "$verdict" "$RUNG" "$RUNG_CMD" "$RUNG_WHY" "${RUNG_NOTE:+ note=$RUNG_NOTE}"
    return 0
  fi

  # Acting. The caller holds this lane's liveness lock across the whole
  # episode (see sweep in this file), from probe through this act.
  if ! ladder_record "$lane" "$RUNG" attempt "$RUNG_WHY"; then
    printf 'lane=%s verdict=%s rung=%s action=skipped reason=ladder log unwritable, so nothing was tried\n' \
      "$lane" "$verdict" "$RUNG"
    return 0
  fi
  rc=0
  case "$RUNG" in
    restart_lane_agent)
      # The one guarded relaunch path, on an endpoint proven to run no agent.
      fm_secondmate_liveness_relaunch "$STATE/$lane.meta" "$lane" "$RELAUNCH_TIMEOUT" || rc=$?
      ;;
    switch_model_or_harness)
      # A live agent is asked to persist first, bounded. A provider-dead agent
      # cannot answer, and that is recorded with its justification rather than
      # allowed to block the rung it exists for. The gate is "not proven absent"
      # rather than "proven alive", so the request is never skipped for an
      # endpoint whose liveness is unknown.
      if [ "$FM_SM_LIVE_STATUS" != relaunchable ] && ! persist_attempt "$lane"; then
        if ! ladder_record "$lane" switch_model_or_harness persist_impossible \
          "no persist answer in ${PERSIST_TIMEOUT}s; an agent that cannot reach its provider cannot have landed work, and the relaunch verb keeps the worktree and its unlanded commits"; then
          printf 'lane=%s verdict=%s rung=%s action=unrecorded reason=ladder log unwritable, so the persist_impossible justification was not recorded\n' \
            "$lane" "$verdict" "$RUNG"
        fi
      fi
      # fm-control.sh owns replacing a running agent in the same worktree on a
      # newly chosen profile. Not a second recovery path; its documented use.
      # shellcheck disable=SC2086  # deliberate split of the configured profile flags
      out=$("$SCRIPT_DIR/fm-control.sh" "$lane" relaunch \
        ${SWITCH_HARNESS:+--harness "$SWITCH_HARNESS"} ${SWITCH_MODEL:+--model "$SWITCH_MODEL"} 2>&1) || rc=$?
      [ "$rc" -eq 0 ] || printf '%s\n' "$out" >&2
      ;;
    redispatch)
      redispatch_do "$lane" || rc=$?
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    detail='replaced through the existing owner of this case'
    [ "$RUNG" != redispatch ] \
      || detail="re-sent $REDISPATCH_SENT unclaimed record(s) through bin/fm-send.sh with fresh correlation ids"
    lognote=
    ladder_record "$lane" "$RUNG" succeeded "$detail" \
      || lognote='; the ladder log is unwritable, so the outcome row was not recorded'
    printf 'lane=%s verdict=%s rung=%s action=done%s reason=%s%s\n' \
      "$lane" "$verdict" "$RUNG" "${REDISPATCH_SENT:+ sent=$REDISPATCH_SENT}" "$RUNG_WHY" "$lognote"
  else
    lognote=
    ladder_record "$lane" "$RUNG" failed "exited $rc" \
      || lognote='; the ladder log is unwritable, so the outcome row was not recorded'
    printf 'lane=%s verdict=%s rung=%s action=failed rc=%s reason=%s%s\n' \
      "$lane" "$verdict" "$RUNG" "$rc" "$RUNG_WHY" "$lognote"
  fi
}

action_plan() {
  [ -f "$CONFIG" ] || { printf 'response lanes are not configured (%s is absent)\n' "$CONFIG"; return 0; }
  config_load || { printf 'response lanes are not configured (%s names no lane)\n' "$CONFIG"; return 0; }
  ACTING=
  sweep
}

action_run() {
  [ -f "$CONFIG" ] || die "$CONFIG is absent, so there is nothing to recover"
  config_load || die "$CONFIG names no lane, so there is nothing to recover"
  case "$RECOVERY" in
    acting) ACTING=1 ;;
    *)
      printf 'refusing to act: RECOVERY=%s in %s. The ladder acts only at RECOVERY=acting; this is the off-switch.\n' \
        "$RECOVERY" "$CONFIG" >&2
      printf 'Printing the plan instead, which changes nothing.\n' >&2
      ACTING=
      ;;
  esac
  sweep
}

action_clear() {
  local lane=${1:-}
  fm_pr_task_id_valid "$lane" || die 'clear needs a lane name'
  NOW=$(date +%s)
  ladder_parked "$lane" || die "lane $lane is not parked"
  ladder_record "$lane" escalate_captain cleared 'released by hand' \
    || die "could not write the ladder log for $lane"
  printf 'cleared: %s is re-armed for automatic recovery\n' "$lane"
}

action_log() {
  local lane=${1:-} f
  fm_pr_task_id_valid "$lane" || die 'log needs a lane name'
  f=$(ladder_log "$lane")
  [ -f "$f" ] || { printf 'no ladder log for %s\n' "$lane"; return 0; }
  printf 'epoch\trung\toutcome\tdetail\n'
  command cat "$f"
}

NOW=$(date +%s)

case "${1:-plan}" in
  plan) action_plan ;;
  run) action_run ;;
  clear) shift; action_clear "${1:-}" ;;
  log) shift; action_log "${1:-}" ;;
  --help|-h|help) usage ;;
  *) die "unknown mode ${1:-}" ;;
esac

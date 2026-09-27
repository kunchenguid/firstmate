#!/usr/bin/env bash
# Durable lifecycle owner for one automatic or coordinated /stow run.
#
# Usage:
#   FM_HOME=/path/to/home fm-stow-run.sh status
#   FM_HOME=/path/to/home fm-stow-run.sh request --reason KIND --session-id ID \
#     --session-file FILE --target-entry-id ID --branch-fingerprint SHA256
#   FM_HOME=/path/to/home fm-stow-run.sh begin --run-id UUID --session-id ID \
#     --generation TOKEN --target-entry-id ID --branch-fingerprint SHA256 \
#     --expected-revision N
#   FM_HOME=/path/to/home fm-stow-run.sh deliver --run-id UUID \
#     --generation TOKEN --expected-revision N
#   FM_HOME=/path/to/home fm-stow-run.sh delivery --run-id UUID \
#     --generation TOKEN --operation-id ID --expected-revision N
#   FM_HOME=/path/to/home fm-stow-run.sh step --run-id UUID --generation TOKEN \
#     --operation-id ID --phase prepared|verified --plan-ref RELATIVE_PATH \
#     --before-sha256 SHA256 --target-sha256 SHA256 [--actual-sha256 SHA256] \
#     --expected-revision N
#   FM_HOME=/path/to/home fm-stow-run.sh finish --run-id UUID --generation TOKEN \
#     --receipt-ref RELATIVE_PATH --interval-seconds N --expected-revision N
#   FM_HOME=/path/to/home fm-stow-run.sh defer --run-id UUID --generation TOKEN \
#     --reason REASON --expected-revision N
#   FM_HOME=/path/to/home fm-stow-run.sh recover --run-id UUID --session-id ID \
#     --generation TOKEN --target-entry-id ID --branch-fingerprint SHA256 \
#     --expected-revision N
#   FM_HOME=/path/to/home fm-stow-run.sh disable
#
# stdout is one version=1 JSON object. Exit 0 means the state operation was
# accepted, not that stow succeeded. Exit 2 is bad input/configuration, 3 is an
# ownership or compare-and-swap conflict, and 4 is durable I/O/verification
# failure. This script owns coordination evidence only; it never edits memory.
# reason=heartbeat replaces the automatic periodic producer, retaining the same
# run/CAS/step/pending owner. Successful/skipped heartbeat receipts additionally
# require heartbeat.{archival,continuation,knowledge}, each with status
# complete|unchanged and an evidence_ref (home data/state) plus its sha256.
# fm-heartbeat-receipt.py validates those evidence bindings, not goal semantics.
# Exhausted heartbeat offers retain their original attempt budget and use
# separately counted recovery deliveries with 60-second exponential backoff
# capped at 15 minutes. Delivery never proves execution or completion.
# Manual/precompact and legacy in-flight periodic runs keep their old contract.
set -u
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

usage() {
  sed -n '2,/^# stdout/p' "$0" | sed 's/^# \{0,1\}//'
}

answer() {
  jq -cn --arg outcome "$1" --arg message "${2:-}" --argjson revision "${3:-null}" \
    '{version:1,outcome:$outcome,message:$message,revision:$revision}'
}

die() {
  local code=$1 outcome=$2 message=$3
  answer "$outcome" "$message" null
  exit "$code"
}

need_value() {
  [ "$#" -ge 2 ] || die 2 invalid-arguments "missing value for $1"
}

canonical_existing_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (cd "$1" && pwd -P)
}

valid_id() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$'; }
valid_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }
valid_revision() { printf '%s' "$1" | grep -Eq '^(0|[1-9][0-9]{0,14})$'; }
valid_positive() { printf '%s' "$1" | grep -Eq '^[1-9][0-9]{0,14}$'; }

validate_relative_ref() {
  case "$1" in
    data/stow-runs/*/*) ;;
    *) return 1 ;;
  esac
  case "/$1/" in */../*|*/./*|*//* ) return 1 ;; esac
  [ "${1#/}" = "$1" ]
}

HOME_INPUT=${FM_HOME:-}
[ -n "$HOME_INPUT" ] || die 2 invalid-home "FM_HOME is required"
HOME_CANON=$(canonical_existing_dir "$HOME_INPUT") \
  || die 2 invalid-home "FM_HOME must be an existing non-symlink directory"
[ "$HOME_CANON" = "$HOME_INPUT" ] \
  || die 2 invalid-home "FM_HOME must be its normalized physical path"
case "${FM_SUPERVISION_ACTOR:-main}" in
  ''|main) ;;
  *) die 3 refused-role "only the main session may own a stow run" ;;
esac
[ -z "${FM_TASK_ID:-}" ] && [ -z "${FIRSTMATE_OP:-}" ] \
  || die 3 refused-role "task workers cannot own a main-session stow run"

STATE_DIR="$HOME_CANON/state/stow"
STATE_FILE="$STATE_DIR/state.json"
LOCK_FILE="$STATE_DIR/.lock"

# shellcheck disable=SC2016 # jq expands $home inside this literal filter.
state_filter='
  select(.version == 1 and .home == $home and
    (.revision | type == "number" and . >= 0 and . <= 9007199254740991 and floor == .) and
    (.last_success_at == null or (.last_success_at | type == "string")) and
    (.next_due_at == null or (.next_due_at | type == "string")) and
    (.pending == null or
      (.pending | type == "object" and
        (.reasons | type == "array") and (.reasons | all(. == "periodic" or . == "heartbeat" or . == "manual" or . == "precompact" or . == "cascade")) and
        (.target_session_id | type == "string") and (.target_session_file | type == "string") and
        (.target_entry_id | type == "string") and (.branch_fingerprint | test("^[0-9a-f]{64}$")))) and
    (.active == null or
      (.active | type == "object" and (.run_id | type == "string") and
        (.reasons | type == "array") and (.reasons | all(. == "periodic" or . == "heartbeat" or . == "manual" or . == "precompact" or . == "cascade")) and
        (.session_id | type == "string") and (.session_file | type == "string") and
        (.generation == null or (.generation | type == "string")) and
        (.offered_generation == null or (.offered_generation | type == "string")) and
        (.escalation_id == null or (.escalation_id | type == "string" and test("^e\\.[A-Za-z0-9._:-]{1,255}$"))) and
        (.escalation_generation == null or (.escalation_generation | type == "string")) and
        (.escalation_delivered_at == null or (.escalation_delivered_at | type == "string")) and
        ((.recovery_attempts // 0) | type == "number" and . >= 0 and . <= 9007199254740991 and floor == .) and
        (.recovery_not_before == null or (.recovery_not_before | type == "number" and . >= 0 and floor == .)) and
        (.phase == "requested" or .phase == "running" or .phase == "partial" or .phase == "blocked") and
        (.attempts | type == "number" and . >= 0 and . <= 3 and floor == .) and
        (.cutoff_entry_id | type == "string") and (.branch_fingerprint | test("^[0-9a-f]{64}$")) and
        (.steps | type == "array"))) and
    has("pending") and has("active") and has("last_result"))
'

COMMAND=${1:-}
[ -n "$COMMAND" ] || { usage; exit 2; }
shift || true

stow_lock_owned_by_self() {
  fm_session_lock_owned_by_self "$HOME_CANON/state" && return 0
  [ "${PI_CODING_AGENT:-}" = true ] || return 1
  local lock_pid pid
  lock_pid=$(cat "$HOME_CANON/state/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    [ "$pid" = "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*|1) break ;; esac
  done
  return 1
}

if [ "$COMMAND" != status ]; then
  stow_lock_owned_by_self \
    || die 3 refused-lock "current process does not descend from this home's session-lock owner"
fi

reason='' session_id='' session_file='' target_entry_id='' branch_fingerprint=''
run_id='' generation='' expected_revision='' operation_id='' phase=''
plan_ref='' receipt_ref='' before_sha='' target_sha='' actual_sha=''
interval_seconds=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reason) need_value "$@"; reason=$2; shift 2 ;;
    --session-id) need_value "$@"; session_id=$2; shift 2 ;;
    --session-file) need_value "$@"; session_file=$2; shift 2 ;;
    --target-entry-id) need_value "$@"; target_entry_id=$2; shift 2 ;;
    --branch-fingerprint) need_value "$@"; branch_fingerprint=$2; shift 2 ;;
    --run-id) need_value "$@"; run_id=$2; shift 2 ;;
    --generation) need_value "$@"; generation=$2; shift 2 ;;
    --expected-revision) need_value "$@"; expected_revision=$2; shift 2 ;;
    --operation-id) need_value "$@"; operation_id=$2; shift 2 ;;
    --phase) need_value "$@"; phase=$2; shift 2 ;;
    --plan-ref) need_value "$@"; plan_ref=$2; shift 2 ;;
    --receipt-ref) need_value "$@"; receipt_ref=$2; shift 2 ;;
    --before-sha256) need_value "$@"; before_sha=$2; shift 2 ;;
    --target-sha256) need_value "$@"; target_sha=$2; shift 2 ;;
    --actual-sha256) need_value "$@"; actual_sha=$2; shift 2 ;;
    --interval-seconds) need_value "$@"; interval_seconds=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 invalid-arguments "unknown argument: $1" ;;
  esac
done

if [ "$COMMAND" = status ]; then
  if [ ! -e "$STATE_FILE" ]; then
    jq -cn --arg home "$HOME_CANON" '{version:1,home:$home,revision:0,last_success_at:null,next_due_at:null,
      covered:null,observed:null,pending:null,active:null,last_result:null,outcome:"idle"}'
    exit 0
  fi
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] \
    || die 4 corrupt-state "state file is not a regular non-symlink file"
  jq -ce --arg home "$HOME_CANON" "$state_filter |
    . + {outcome:(if .active then .active.phase elif .pending then \"pending\" else \"idle\" end)}
  " "$STATE_FILE" 2>/dev/null || die 4 corrupt-state "state file is invalid or belongs to another home"
  exit 0
fi

mkdir -p "$STATE_DIR" || die 4 io-error "cannot create state/stow"
chmod 700 "$STATE_DIR" 2>/dev/null || die 4 io-error "cannot protect state/stow"

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
fm_lock_acquire_wait "$LOCK_FILE" || die 4 io-error "cannot acquire stow state lock"
trap 'fm_lock_release "$LOCK_FILE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

initial_state() {
  jq -cn --arg home "$HOME_CANON" '{
    version:1,home:$home,revision:0,last_success_at:null,next_due_at:null,
    covered:null,observed:null,pending:null,active:null,last_result:null
  }'
}

load_state() {
  if [ ! -e "$STATE_FILE" ]; then
    initial_state
    return
  fi
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] \
    || die 4 corrupt-state "state file is not a regular non-symlink file"
  local loaded
  loaded=$(jq -ce --arg home "$HOME_CANON" "$state_filter" "$STATE_FILE" 2>/dev/null) \
    || die 4 corrupt-state "state file is invalid or belongs to another home"
  printf '%s\n' "$loaded"
}

commit_state() {
  local json=$1 tmp
  tmp=$(mktemp "$STATE_DIR/.state.json.XXXXXX") || die 4 io-error "cannot create atomic state temporary"
  if ! printf '%s\n' "$json" >"$tmp" || ! chmod 600 "$tmp" || ! node -e '
    const fs=require("node:fs"); const fd=fs.openSync(process.argv[1],"r"); fs.fsyncSync(fd); fs.closeSync(fd);
  ' "$tmp"; then
    rm -f "$tmp"
    die 4 io-error "cannot durably write state temporary"
  fi
  if ! mv -f "$tmp" "$STATE_FILE" || ! node -e '
    const fs=require("node:fs"); const fd=fs.openSync(process.argv[1],"r"); fs.fsyncSync(fd); fs.closeSync(fd);
  ' "$STATE_DIR"; then
    rm -f "$tmp"
    die 4 io-error "cannot atomically publish state"
  fi
}

STATE=$(load_state)
REVISION=$(printf '%s' "$STATE" | jq -r '.revision')
[ "$REVISION" -lt 9007199254740991 ] || die 4 corrupt-state "state revision reached the safe-integer limit"

require_revision() {
  valid_revision "$expected_revision" || die 2 invalid-revision "expected revision is required"
  [ "$REVISION" = "$expected_revision" ] \
    || die 3 stale-revision "expected revision $expected_revision but found $REVISION"
}

require_active_identity() {
  if ! valid_id "$run_id" || ! valid_id "$generation"; then
    die 2 invalid-identity "run_id and generation are required"
  fi
  local active_run active_generation
  active_run=$(printf '%s' "$STATE" | jq -r '.active.run_id // ""')
  active_generation=$(printf '%s' "$STATE" | jq -r '.active.generation // ""')
  [ "$active_run" = "$run_id" ] || die 3 stale-run "run_id does not own the active run"
  [ "$active_generation" = "$generation" ] || die 3 stale-generation "generation does not own the active run"
}

next_revision=$((REVISION + 1))
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

case "$COMMAND" in
  status)
    printf '%s\n' "$STATE" | jq -c '. + {outcome:(if .active then .active.phase elif .pending then "pending" else "idle" end)}'
    ;;
  request)
    case "$reason" in heartbeat|periodic|manual|precompact|cascade) ;; *) die 2 invalid-reason "unsupported request reason" ;; esac
    if ! valid_id "$session_id" || ! valid_id "$target_entry_id" || ! valid_sha "$branch_fingerprint"; then
      die 2 invalid-request "invalid session, entry, or branch fingerprint"
    fi
    [ -f "$session_file" ] && [ ! -L "$session_file" ] \
      || die 2 invalid-session-file "session_file must be a persistent regular non-symlink file"
    session_file=$(cd "$(dirname "$session_file")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$session_file")")
    existing=$(printf '%s' "$STATE" | jq -r '.active.run_id // ""')
    if [ -n "$existing" ]; then
      STATE=$(printf '%s' "$STATE" | jq -c --arg r "$reason" --arg sid "$session_id" \
        --arg sf "$session_file" --arg eid "$target_entry_id" --arg fp "$branch_fingerprint" \
        --argjson rev "$next_revision" '
          .revision=$rev |
          .active.reasons=((.active.reasons + [$r]) | unique) |
          .pending=(if .active.session_id==$sid and .active.cutoff_entry_id==$eid and .active.branch_fingerprint==$fp
            then .pending
            else {reasons:((.pending.reasons // [])+[$r]|unique),since:(.pending.since // (now|todate)),
              target_session_id:$sid,target_session_file:$sf,target_entry_id:$eid,branch_fingerprint:$fp}
            end)
        ')
      commit_state "$STATE"
      printf '%s\n' "$STATE" | jq -c --arg run "$existing" '{version:1,outcome:"existing",run_id:$run,revision:.revision,phase:.active.phase}'
      exit 0
    fi
    run_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null) \
      || die 4 random-failure "cannot generate run_id"
    STATE=$(printf '%s' "$STATE" | jq -c --arg run "$run_id" --arg r "$reason" --arg now "$now" \
      --arg sid "$session_id" --arg sf "$session_file" --arg eid "$target_entry_id" \
      --arg fp "$branch_fingerprint" --argjson rev "$next_revision" '
        .revision=$rev |
        .pending=null |
        .active={run_id:$run,reasons:[$r],session_id:$sid,session_file:$sf,generation:null,
          phase:"requested",cutoff_entry_id:$eid,branch_fingerprint:$fp,offered_generation:null,plan_ref:null,
          receipt_ref:null,attempts:0,escalation_id:null,escalation_generation:null,
          escalation_delivered_at:null,steps:[],defer_reason:null,started_at:$now,parent_run_id:null}
      ')
    commit_state "$STATE"
    printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"requested",run_id:.active.run_id,revision:.revision,phase:.active.phase}'
    ;;
  begin)
    require_revision
    if ! valid_id "$run_id" || ! valid_id "$session_id" || ! valid_id "$generation" || \
       ! valid_id "$target_entry_id" || ! valid_sha "$branch_fingerprint"; then
      die 2 invalid-identity "run_id, session_id, generation, cutoff entry, and branch fingerprint are required"
    fi
    [ "$(printf '%s' "$STATE" | jq -r '.active.run_id // ""')" = "$run_id" ] \
      || die 3 stale-run "run_id does not own the active run"
    [ "$(printf '%s' "$STATE" | jq -r '.active.session_id')" = "$session_id" ] \
      || die 3 wrong-session "session_id does not own the active run"
    [ "$(printf '%s' "$STATE" | jq -r '.active.cutoff_entry_id')" = "$target_entry_id" ] && \
      [ "$(printf '%s' "$STATE" | jq -r '.active.branch_fingerprint')" = "$branch_fingerprint" ] \
      || die 3 wrong-tree "cutoff entry or ordered ancestry fingerprint changed"
    [ "$(printf '%s' "$STATE" | jq -r '.active.offered_generation // ""')" = "$generation" ] \
      || die 3 stale-generation "generation was not offered this run"
    active_generation=$(printf '%s' "$STATE" | jq -r '.active.generation // ""')
    active_phase=$(printf '%s' "$STATE" | jq -r '.active.phase')
    if [ -n "$active_generation" ] && [ "$active_generation" != "$generation" ]; then
      die 3 resume-required "active run belongs to another generation; recover it first"
    fi
    case "$active_phase" in requested|running|partial) ;; *) die 3 invalid-phase "active run cannot begin from $active_phase" ;; esac
    STATE=$(printf '%s' "$STATE" | jq -c --arg gen "$generation" --argjson rev "$next_revision" '
      .revision=$rev | .active.generation=$gen | .active.phase="running" |
      .active.defer_reason=null
    ')
    commit_state "$STATE"
    printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"granted",run_id:.active.run_id,revision:.revision,phase:.active.phase,cutoff_entry_id:.active.cutoff_entry_id}'
    ;;
  deliver)
    require_revision
    if ! valid_id "$run_id" || ! valid_id "$generation"; then
      die 2 invalid-identity "run_id and generation are required"
    fi
    [ "$(printf '%s' "$STATE" | jq -r '.active.run_id // ""')" = "$run_id" ] \
      || die 3 stale-run "run_id does not own the active run"
    active_phase=$(printf '%s' "$STATE" | jq -r '.active.phase')
    heartbeat_run=$(printf '%s' "$STATE" | jq -r '[.active.reasons[]|select(.=="heartbeat")]|length>0')
    case "$active_phase" in
      requested|partial) ;;
      running) [ "$heartbeat_run" = true ] || die 3 invalid-phase "only heartbeat runs may recover at an idle boundary" ;;
      *) die 3 invalid-phase "run cannot be delivered from $active_phase" ;;
    esac
    attempts=$(printf '%s' "$STATE" | jq -r '.active.attempts')
    if [ "$attempts" -ge 3 ]; then
      heartbeat_run=$(printf '%s' "$STATE" | jq -r '[.active.reasons[]|select(.=="heartbeat")]|length>0')
      [ "$heartbeat_run" = true ] || die 3 delivery-exhausted "the same run_id has already been offered three times"
      escalation_id=$(printf '%s' "$STATE" | jq -r --arg run "$run_id" '.active.escalation_id // ("e."+$run)')
      delivered_at=$(printf '%s' "$STATE" | jq -r '.active.escalation_delivered_at // ""')
      if [ -n "$delivered_at" ]; then
        # Legacy receipts derive the first deadline from their actual delivery.
        due=$(printf '%s' "$STATE" | jq -r '.active.recovery_not_before // ((.active.escalation_delivered_at|fromdateiso8601)+60)')
        if [ "$(date -u +%s)" -lt "$due" ]; then
          printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"escalated",run_id:.active.run_id,revision:.revision,
            attempts:.active.attempts,escalation_id:.active.escalation_id}'
          exit 0
        fi
        recovery_attempts=$(printf '%s' "$STATE" | jq -r '.active.recovery_attempts // 0')
        [ "$recovery_attempts" -lt 9007199254740991 ] || die 4 recovery-exhausted "recovery counter exhausted"
        recovery_attempts=$((recovery_attempts + 1))
        escalation_id="e.$run_id.r.$recovery_attempts"
        STATE=$(printf '%s' "$STATE" | jq -c --argjson count "$recovery_attempts" '
          .active.recovery_attempts=$count | .active.escalation_delivered_at=null')
      fi
      if [ -n "$delivered_at" ] || [ "$(printf '%s' "$STATE" | jq -r '.active.escalation_generation // ""')" != "$generation" ]; then
        STATE=$(printf '%s' "$STATE" | jq -c --arg gen "$generation" --arg id "$escalation_id" --argjson rev "$next_revision" '
          .revision=$rev | .active.offered_generation=$gen | .active.escalation_id=$id |
          .active.escalation_generation=$gen
        ')
        commit_state "$STATE"
      fi
      printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"escalate",run_id:.active.run_id,revision:.revision,
        attempts:.active.attempts,escalation_id:.active.escalation_id}'
      exit 0
    fi
    STATE=$(printf '%s' "$STATE" | jq -c --arg gen "$generation" --argjson rev "$next_revision" '
      .revision=$rev | .active.offered_generation=$gen | .active.attempts=(.active.attempts+1)
    ')
    commit_state "$STATE"
    printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"deliver",run_id:.active.run_id,revision:.revision,attempts:.active.attempts}'
    ;;
  delivery)
    require_revision
    if ! valid_id "$run_id" || ! valid_id "$generation" || ! valid_id "$operation_id"; then
      die 2 invalid-identity "run_id, generation, and operation_id are required"
    fi
    [ "$(printf '%s' "$STATE" | jq -r '.active.run_id // ""')" = "$run_id" ] \
      || die 3 stale-run "run_id does not own the active run"
    [ "$(printf '%s' "$STATE" | jq -r '.active.escalation_id // ""')" = "$operation_id" ] \
      || die 3 stale-delivery "operation_id does not own the escalation"
    [ "$(printf '%s' "$STATE" | jq -r '.active.escalation_generation // ""')" = "$generation" ] \
      || die 3 stale-generation "generation does not own the escalation"
    if [ "$(printf '%s' "$STATE" | jq -r '.active.escalation_delivered_at // ""')" = "" ]; then
      STATE=$(printf '%s' "$STATE" | jq -c --arg now "$now" --argjson rev "$next_revision" '
        .revision=$rev | .active.escalation_delivered_at=$now |
        .active.recovery_not_before=(($now|fromdateiso8601) +
          ([900, (60 * pow(2; ([.active.recovery_attempts // 0, 4]|min)))]|min))
      ')
      commit_state "$STATE"
    fi
    printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"delivered",run_id:.active.run_id,revision:.revision,
      attempts:.active.attempts,escalation_id:.active.escalation_id}'
    ;;
  step)
    require_revision
    require_active_identity
    if ! valid_id "$operation_id" || ! validate_relative_ref "$plan_ref" || ! valid_sha "$before_sha" || ! valid_sha "$target_sha"; then
      die 2 invalid-step "invalid operation, plan reference, or digest"
    fi
    [ -f "$HOME_CANON/$plan_ref" ] && [ ! -L "$HOME_CANON/$plan_ref" ] \
      || die 4 missing-plan "plan_ref does not name a regular file in this home"
    case "$phase" in prepared) [ -z "$actual_sha" ] || die 2 invalid-step "prepared step must not carry actual_sha256" ;; verified) valid_sha "$actual_sha" || die 2 invalid-step "verified step requires actual_sha256" ;; *) die 2 invalid-step "phase must be prepared or verified" ;; esac
    existing=$(printf '%s' "$STATE" | jq -c --arg op "$operation_id" '.active.steps[]? | select(.operation_id==$op)' | head -1)
    if [ -n "$existing" ]; then
      same=$(printf '%s' "$existing" | jq -r --arg p "$plan_ref" --arg b "$before_sha" --arg t "$target_sha" \
        '(.plan_ref==$p and .before_sha256==$b and .target_sha256==$t)')
      [ "$same" = true ] || die 3 operation-conflict "operation_id was already prepared with different content"
      if [ "$phase" = prepared ] || [ "$(printf '%s' "$existing" | jq -r '.phase')" = verified ]; then
        printf '%s\n' "$STATE" | jq -c --arg op "$operation_id" '{version:1,outcome:"unchanged",operation_id:$op,revision:.revision,phase:(.active.steps[]|select(.operation_id==$op)|.phase)}'
        exit 0
      fi
      [ "$actual_sha" = "$target_sha" ] \
        || die 4 verification-failed "readback digest does not equal the planned target"
      STATE=$(printf '%s' "$STATE" | jq -c --arg op "$operation_id" --arg actual "$actual_sha" --argjson rev "$next_revision" '
        .revision=$rev | .active.steps=(.active.steps|map(if .operation_id==$op then .phase="verified"|.actual_sha256=$actual else . end))
      ')
    else
      [ "$phase" = prepared ] || die 3 missing-preparation "operation must be prepared before it can be verified"
      STATE=$(printf '%s' "$STATE" | jq -c --arg op "$operation_id" --arg p "$plan_ref" --arg b "$before_sha" --arg t "$target_sha" --argjson rev "$next_revision" '
        .revision=$rev | .active.plan_ref=(.active.plan_ref // $p) |
        .active.steps += [{operation_id:$op,phase:"prepared",plan_ref:$p,before_sha256:$b,target_sha256:$t,actual_sha256:null}]
      ')
    fi
    commit_state "$STATE"
    printf '%s\n' "$STATE" | jq -c --arg op "$operation_id" '{version:1,outcome:"recorded",operation_id:$op,revision:.revision,phase:(.active.steps[]|select(.operation_id==$op)|.phase)}'
    ;;
  defer)
    require_revision
    require_active_identity
    [ -n "$reason" ] || die 2 invalid-reason "defer reason is required"
    STATE=$(printf '%s' "$STATE" | jq -c --arg reason "$reason" --argjson rev "$next_revision" '
      .revision=$rev | .active.defer_reason=$reason |
      .active.phase=(if .active.phase=="running" then "partial" else .active.phase end)
    ')
    commit_state "$STATE"
    printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"deferred",run_id:.active.run_id,revision:.revision,phase:.active.phase,reason:.active.defer_reason}'
    ;;
  recover)
    require_revision
    if ! valid_id "$run_id" || ! valid_id "$session_id" || ! valid_id "$generation" || \
       ! valid_id "$target_entry_id" || ! valid_sha "$branch_fingerprint"; then
      die 2 invalid-identity "run_id, session_id, generation, cutoff entry, and branch fingerprint are required"
    fi
    [ "$(printf '%s' "$STATE" | jq -r '.active.run_id // ""')" = "$run_id" ] \
      || die 3 stale-run "run_id does not own the active run"
    [ "$(printf '%s' "$STATE" | jq -r '.active.session_id')" = "$session_id" ] \
      || die 3 wrong-session "only the bound session may recover this run"
    [ "$(printf '%s' "$STATE" | jq -r '.active.cutoff_entry_id')" = "$target_entry_id" ] && \
      [ "$(printf '%s' "$STATE" | jq -r '.active.branch_fingerprint')" = "$branch_fingerprint" ] \
      || die 3 wrong-tree "cutoff entry or ordered ancestry fingerprint changed"
    [ "$(printf '%s' "$STATE" | jq -r '.active.offered_generation // ""')" = "$generation" ] \
      || die 3 stale-generation "generation was not offered this recovery"
    STATE=$(printf '%s' "$STATE" | jq -c --arg gen "$generation" --argjson rev "$next_revision" '
      .revision=$rev | .active.generation=$gen |
      .active.phase=(if ([.active.steps[]?|select(.phase=="prepared")]|length)>0 then "partial" else "running" end) |
      .active.defer_reason=null
    ')
    commit_state "$STATE"
    printf '%s\n' "$STATE" | jq -c '{version:1,outcome:"recovered",run_id:.active.run_id,revision:.revision,phase:.active.phase,steps:.active.steps}'
    ;;
  finish)
    require_revision
    require_active_identity
    validate_relative_ref "$receipt_ref" || die 2 invalid-receipt "receipt_ref must stay under data/stow-runs"
    valid_positive "$interval_seconds" || die 2 invalid-interval "interval_seconds must be positive"
    RECEIPT="$HOME_CANON/$receipt_ref"
    [ -f "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || die 4 missing-receipt "receipt_ref does not name a regular file"
    receipt_outcome=$(jq -er --arg run "$run_id" --arg gen "$generation" '
      select(.version==1 and .run_id==$run and .generation==$gen) | .outcome |
      select(.=="succeeded" or .=="skipped" or .=="partial" or .=="blocked")
    ' "$RECEIPT" 2>/dev/null) || die 4 invalid-receipt "receipt identity or outcome is invalid"
    periodic_run=$(printf '%s' "$STATE" | jq -r '[.active.reasons[]|select(.=="periodic" or .=="heartbeat")]|length>0')
    heartbeat_run=$(printf '%s' "$STATE" | jq -r '[.active.reasons[]|select(.=="heartbeat")]|length>0')
    if [ "$heartbeat_run" = true ] && { [ "$receipt_outcome" = succeeded ] || [ "$receipt_outcome" = skipped ]; }; then
      python3 "$ROOT/bin/fm-heartbeat-receipt.py" "$HOME_CANON" "$RECEIPT" \
        || die 4 unfinished-heartbeat "all three heartbeat duties require verified evidence; unfinished duties remain active"
    fi
    if [ "$receipt_outcome" = succeeded ]; then
      jq -e '
        .budget.ok==true and
        ([.local_steps[]?|select(.verified!=true)]|length)==0
      ' "$RECEIPT" >/dev/null 2>&1 || die 4 invalid-receipt "success receipt lacks verified local or budget evidence"
      if [ "$periodic_run" = true ]; then
        jq -e '
          .preflight.complete==true and
          ([.preflight.homes[]?|select(.status!="eligible")]|length)==0 and
          ([.cascade[]?|select(.outcome!="succeeded" and .outcome!="skipped")]|length)==0
        ' "$RECEIPT" >/dev/null 2>&1 \
          || die 4 invalid-receipt "automatic success receipt lacks an eligible all-home preflight"
      fi
      prepared_count=$(printf '%s' "$STATE" | jq '[.active.steps[]?|select(.phase=="prepared")]|length')
      [ "$prepared_count" -eq 0 ] || die 4 unverified-steps "prepared operations remain unverified"
    fi
    if [ "$receipt_outcome" = skipped ]; then
      [ "$(printf '%s' "$STATE" | jq '.active.steps|length')" -eq 0 ] \
        || die 4 invalid-receipt "a run with write steps cannot finish skipped"
      jq -e '.noop == {uncovered_material:false,due_maintenance:false,external_memory_change:false,
        budget_change:false,anomaly:false,unfinished_cascade:false}' "$RECEIPT" >/dev/null 2>&1 \
        || die 4 invalid-receipt "skip receipt does not prove every no-op condition"
      if [ "$periodic_run" = true ]; then
        jq -e '
          .preflight.complete==true and
          ([.preflight.homes[]?|select(.status!="eligible")]|length)==0
        ' "$RECEIPT" >/dev/null 2>&1 \
          || die 4 invalid-receipt "automatic no-op receipt lacks an eligible all-home preflight"
      fi
    fi
    if [ "$receipt_outcome" = partial ] || [ "$receipt_outcome" = blocked ]; then
      STATE=$(printf '%s' "$STATE" | jq -c --arg outcome "$receipt_outcome" --arg ref "$receipt_ref" --argjson rev "$next_revision" '
        .revision=$rev | .active.phase=$outcome | .active.receipt_ref=$ref |
        .last_result={run_id:.active.run_id,outcome:$outcome,reason:(.active.defer_reason // "receipt"),receipt_ref:$ref}
      ')
    else
      next_due=$(node -e 'process.stdout.write(new Date(Date.now()+Number(process.argv[1])*1000).toISOString().replace(/\.000Z$/,"Z"))' "$interval_seconds" 2>/dev/null) \
        || die 4 clock-error "cannot calculate next due time"
      next_run_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null) \
        || die 4 random-failure "cannot generate pending run_id"
      STATE=$(printf '%s' "$STATE" | jq -c --arg outcome "$receipt_outcome" --arg ref "$receipt_ref" \
        --arg now "$now" --arg due "$next_due" --arg next "$next_run_id" --argjson rev "$next_revision" '
          .active.run_id as $completed |
          .revision=$rev |
          .observed={session_id:.active.session_id,entry_id:.active.cutoff_entry_id,branch_fingerprint:.active.branch_fingerprint} |
          (if $outcome=="succeeded" then
            .covered=.observed | .last_success_at=$now
          else . end) |
          .next_due_at=$due |
          .last_result={run_id:$completed,outcome:$outcome,reason:null,receipt_ref:$ref} |
          .active=(if .pending then
            {run_id:$next,reasons:.pending.reasons,session_id:.pending.target_session_id,
              session_file:.pending.target_session_file,generation:null,phase:"requested",
              cutoff_entry_id:.pending.target_entry_id,branch_fingerprint:.pending.branch_fingerprint,
              offered_generation:null,plan_ref:null,receipt_ref:null,attempts:0,escalation_id:null,
              escalation_generation:null,escalation_delivered_at:null,steps:[],
              defer_reason:null,started_at:$now,parent_run_id:$completed}
            else null end) |
          .pending=null
        ')
    fi
    commit_state "$STATE"
    printf '%s\n' "$STATE" | jq -c --arg outcome "$receipt_outcome" '{version:1,outcome:$outcome,revision:.revision,next_due_at:.next_due_at,last_success_at:.last_success_at,active:.active}'
    ;;
  disable)
    active_phase=$(printf '%s' "$STATE" | jq -r '.active.phase // ""')
    periodic_only=$(printf '%s' "$STATE" | jq -r '(.active != null) and (.active.phase=="requested") and ((.active.reasons|length)>0) and ([.active.reasons[]|select(.!="periodic" and .!="heartbeat")]|length==0)')
    if [ "$periodic_only" = true ]; then
      STATE=$(printf '%s' "$STATE" | jq -c --argjson rev "$next_revision" '.revision=$rev|.active=null|.pending=null')
      commit_state "$STATE"
      answer disabled "unconsumed periodic-only request withdrawn" "$next_revision"
    else
      answer preserved "manual or begun recovery evidence remains intact (${active_phase:-idle})" "$REVISION"
    fi
    ;;
  *) die 2 invalid-command "unknown command: $COMMAND" ;;
esac

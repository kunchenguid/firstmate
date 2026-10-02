#!/usr/bin/env bash
# fm-task-handoff.sh - durably transfer one exact instruction from one task's
# outcome to another local worker without crossing a supervision lease.
#
# Usage:
#   fm-task-handoff.sh send <source-task> <target-task> --id <handoff-id> [--action-id <prepared-id>] <text...>
#   fm-task-handoff.sh retry <handoff-id>
#   fm-task-handoff.sh retry-task <target-task>
#   fm-task-handoff.sh retry-all
#   fm-task-handoff.sh inspect <handoff-id>
#
# This is the narrow cross-task companion to fm-send.sh. Ordinary same-task
# steering still uses fm-send. A cross-task caller records the complete body,
# source, intended recipient, and stable id here BEFORE target-lease
# arbitration. If the other Pi supervision actor owns the target, the attempt
# exits 6 as a retryable refusal and the exact body remains in
# state/task-handoffs/records/<id>.msg. A later retry - including the automatic
# retry performed when fm-lease releases or sweeps the conflicting
# owner - converges onto one target inbox record identified by `handoff=<id>`.
# The worker's existing handled/ acknowledgement and watcher re-ring ladder
# then apply unchanged.
#
# The immutable handoff record plus atomic status sidecar is the one owner of
# this lifecycle:
#   pending             prepared, including recovery after interruption;
#   retryable-refusal   another actor currently owns the target;
#   delivered           one inbox record owns the exact instruction;
#   rejected            concrete terminal target/contract failure.
#
# The stable id makes sender retries, ownership changes, and process restarts
# idempotent. Reusing an id with a different source, recipient, or body is a
# terminal collision and never changes the original handoff. Delivery and
# status publication are ordered inbox-first: a crash after enqueue but before
# the delivered status is repaired by the next retry, which finds the same
# handoff id in the inbox rather than writing a duplicate.
#
# Delegated v2 sources require a prepared action binding. Its immutable header
# binds both goal/brief/execution identities and source delegation revision.
# Delivery takes sorted, nonblocking task/meta locks under the command lock;
# contention retains the pending record instead of holding one task for another.
# After attempted, retry never enqueues: observe the exact original inbox receipt.
# Scope is deliberately local and textual. Recorded crewmate/scout task
# selectors on every supported local runtime backend use the shared durable
# inbox and backend doorbell. Historical persistent-home and remote-home
# records are refused here.
# Harness-native parser invocations are also refused because they belong to
# fm-send's direct native-prompt plane, not a durable cross-task command.
#
# Exit codes: 0 delivered/already delivered/no matching retry-task work;
# 2 usage; 6 retryable supervision-ownership refusal; 7 durable terminal
# refusal; other nonzero means the handoff stays pending for a safe retry.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_ROOT

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-task-handoff refuses to resolve task records without an explicit firstmate home" >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"

FM_TASK_HANDOFF_SCHEMA='fm-task-handoff.v1'
FM_TASK_HANDOFF_REJECT_EXIT=7
HANDOFF_ROOT="$STATE/task-handoffs"
HANDOFF_RECORDS="$HANDOFF_ROOT/records"
HANDOFF_STATUS="$HANDOFF_ROOT/status"
HANDOFF_LOCK="$STATE/.fm-lease-command.lock"
HANDOFF_ACTION_ID=
HANDOFF_META_HELD=0
# shellcheck source=bin/fm-task-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"

usage() {
  echo "usage: fm-task-handoff.sh send <source-task> <target-task> --id <handoff-id> [--action-id <prepared-id>] <text...> | retry <handoff-id> | retry-task <target-task> | retry-all | inspect <handoff-id>" >&2
  exit 2
}

handoff_valid_atom() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) [ "${#1}" -le 160 ] ;;
  esac
}

handoff_prepare_dirs() {
  local dir
  for dir in "$HANDOFF_ROOT" "$HANDOFF_RECORDS" "$HANDOFF_STATUS"; do
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      [ -d "$dir" ] && [ ! -L "$dir" ] || {
        echo "error: unsafe task-handoff state directory: $dir" >&2
        return 1
      }
    else
      (umask 077; mkdir "$dir") || return 1
    fi
  done
}

handoff_record_path() { printf '%s/%s.msg' "$HANDOFF_RECORDS" "$1"; }
handoff_status_path() { printf '%s/%s.state' "$HANDOFF_STATUS" "$1"; }

handoff_record_field() {  # <record> <field>
  local record=$1 field=$2 line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  while IFS= read -r line; do
    [ "$line" != -- ] || return 1
    case "$line" in
      "$field="*) printf '%s' "${line#*=}"; return 0 ;;
    esac
  done < "$record"
  return 1
}

handoff_record_body() {  # <record>
  local line
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

handoff_state() {  # <id>
  local file line
  file=$(handoff_status_path "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'pending'; return 0; }
  while IFS= read -r line; do
    case "$line" in state=*) printf '%s' "${line#state=}"; return 0 ;; esac
  done < "$file"
  printf 'pending'
}

handoff_write_state() {  # <id> <state> <reason> [inbox-record]
  local id=$1 state=$2 reason=$3 inbox_record=${4:-} tmp dest
  dest=$(handoff_status_path "$id")
  tmp=$(umask 077; mktemp "$HANDOFF_STATUS/.state.XXXXXX") || return 1
  if ! {
    printf 'schema=%s\n' "$FM_TASK_HANDOFF_SCHEMA"
    printf 'state=%s\n' "$state"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -z "$reason" ] || printf 'reason=%s\n' "$reason"
    [ -z "$inbox_record" ] || printf 'inbox_record=%s\n' "$inbox_record"
  } > "$tmp" || ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
}

handoff_prepare_record_locked() {  # <id> <source> <target> <body>
  local id=$1 source=$2 target=$3 body=$4 record tmp want have got_source got_target
  record=$(handoff_record_path "$id")
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || {
      echo "error: unsafe task-handoff record: $record" >&2
      return 1
    }
    got_source=$(handoff_record_field "$record" from 2>/dev/null || true)
    got_target=$(handoff_record_field "$record" target 2>/dev/null || true)
    want=$(mktemp "$HANDOFF_ROOT/.want.XXXXXX") || return 1
    have=$(mktemp "$HANDOFF_ROOT/.have.XXXXXX") || { rm -f "$want"; return 1; }
    printf '%s' "$body" > "$want" || { rm -f "$want" "$have"; return 1; }
    handoff_record_body "$record" > "$have" || { rm -f "$want" "$have"; return 1; }
    if [ "$got_source" != "$source" ] || [ "$got_target" != "$target" ] || ! cmp -s "$want" "$have"; then
      rm -f "$want" "$have"
      echo "error: task-handoff id '$id' already belongs to a different source, recipient, or instruction; the original durable handoff is unchanged" >&2
      return "$FM_TASK_HANDOFF_REJECT_EXIT"
    fi
    rm -f "$want" "$have"
    return 0
  fi
  local binding=null
  if [ -f "${FM_DATA_OVERRIDE:-$FM_HOME/data}/$source/lifecycle.json" ]; then
    binding=$(fm_task_lifecycle handoff-binding "$source" --target "$target" --action-id "$HANDOFF_ACTION_ID") || return 6
  elif [ -n "$HANDOFF_ACTION_ID" ]; then
    echo 'REFUSED: bound handoff source is unknown' >&2; return 6
  fi
  tmp=$(umask 077; mktemp "$HANDOFF_RECORDS/.record.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_HANDOFF_SCHEMA"
    printf 'id=%s\n' "$id"
    printf 'from=%s\n' "$source"
    printf 'target=%s\n' "$target"
    [ "$binding" = null ] || printf 'lifecycle=%s\n' "$binding"
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '--\n'
    printf '%s' "$body"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! ln "$tmp" "$record" 2>/dev/null; then
    rm -f "$tmp"
    handoff_prepare_record_locked "$id" "$source" "$target" "$body"
    return $?
  fi
  rm -f "$tmp"
  handoff_write_state "$id" pending ''
}

handoff_reject_locked() {  # <id> <reason>
  local id=$1 reason=$2
  handoff_write_state "$id" rejected "$reason" || return 1
  echo "error: task handoff '$id' rejected: $reason; inspect with FM_HOME='$FM_HOME' $SCRIPT_DIR/fm-task-handoff.sh inspect '$id'" >&2
  return "$FM_TASK_HANDOFF_REJECT_EXIT"
}

handoff_retryable_locked() {  # <id> <reason>
  local id=$1 reason=$2
  handoff_write_state "$id" retryable-refusal "$reason" || return 1
  echo "error: task handoff '$id' not started: $reason. The exact instruction remains durable; retry with FM_HOME='$FM_HOME' $SCRIPT_DIR/fm-task-handoff.sh retry '$id' after ownership settles" >&2
  return "$FM_LEASE_REFUSE_EXIT"
}

# These helpers execute inside this subshell; its lock flag is deliberately local.
# shellcheck disable=SC2030,SC2031
handoff_deliver_locked() (  # <id>; release short critical locks on every exit
  local id=$1 record source target task lock binding
  local -a locks=()
  record=$(handoff_record_path "$id")
  binding=$(handoff_record_field "$record" lifecycle 2>/dev/null || true)
  if [ -z "$binding" ]; then
    _handoff_deliver_locked "$id"
    exit $?
  fi
  source=$(handoff_record_field "$record" from)
  target=$(handoff_record_field "$record" target)
  trap 'for lock in "${locks[@]}"; do fm_lock_release "$lock"; done' EXIT
  for task in $(printf '%s\n%s\n' "$source" "$target" | LC_ALL=C sort -u); do
    lock="$STATE/.fm-lease-task-$task.lock"
    if ! fm_lock_try_acquire "$lock"; then
      handoff_retryable_locked "$id" "task critical section is busy; immutable handoff retained"
      exit $?
    fi
    locks+=("$lock")
    if [ -e "$STATE/.short-operation-$task.json" ] || { fm_lease_live "$task" && [ "$FM_LEASE_ACTOR" != "$(fm_lease_actor)" ]; }; then
      handoff_retryable_locked "$id" "task has another effect owner"
      exit $?
    fi
  done
  for task in $(printf '%s\n%s\n' "$source" "$target" | LC_ALL=C sort -u); do
    lock=$(fm_meta_lock_path "$STATE/$task.meta") || exit 1
    if ! fm_lock_try_acquire "$lock"; then
      handoff_retryable_locked "$id" "task metadata is busy; immutable handoff retained"
      exit $?
    fi
    locks+=("$lock")
  done
  HANDOFF_META_HELD=1
  _handoff_deliver_locked "$id"
)

handoff_release_meta() {
  # shellcheck disable=SC2031 # Called within the lock-owning subshell.
  [ "$HANDOFF_META_HELD" = 1 ] || fm_lock_release "$1"
}

_handoff_deliver_locked() {  # <id>
  local id=$1 record state source target body_file body actor meta kind remote backend endpoint meta_lock inbox_record write_rc=0 ring_rc=0
  record=$(handoff_record_path "$id")
  [ -f "$record" ] && [ ! -L "$record" ] || {
    echo "error: no durable task handoff '$id' under $HANDOFF_RECORDS" >&2
    return 1
  }
  state=$(handoff_state "$id")
  case "$state" in
    delivered)
      printf 'task handoff %s already delivered\n' "$id"
      return 0
      ;;
    rejected)
      echo "error: task handoff '$id' is terminally rejected; inspect its durable record before creating a new handoff" >&2
      return "$FM_TASK_HANDOFF_REJECT_EXIT"
      ;;
    pending|retryable-refusal) ;;
    *) handoff_reject_locked "$id" "its state record is malformed ('$state')"; return $? ;;
  esac
  source=$(handoff_record_field "$record" from 2>/dev/null || true)
  target=$(handoff_record_field "$record" target 2>/dev/null || true)
  if [ "$source" = "$target" ]; then
    handoff_reject_locked "$id" "source and target are both '$target'; ordinary same-task steering must use fm-send.sh"
    return $?
  fi
  meta="$STATE/$target.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    handoff_reject_locked "$id" "target task '$target' has no safe live metadata record at $meta"
    return $?
  fi
  kind=$(fm_meta_get "$meta" kind)
  remote=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote" ] || [ "$kind" = secondmate ]; then
    handoff_reject_locked "$id" "target '$target' is a historical persistent-home record; task handoff is no longer supported"
    return $?
  fi
  actor=$(fm_lease_actor) || {
    handoff_retryable_locked "$id" "the current supervision actor identity is invalid"
    return $?
  }
  if fm_lease_live "$target"; then
    if [ "$FM_LEASE_ACTOR" != "$actor" ]; then
      handoff_retryable_locked "$id" "target '$target' is leased to the $FM_LEASE_ACTOR supervision actor"
      return $?
    fi
  else
    fm_lease_clear_stale "$target" || return 1
  fi
  backend=$(fm_backend_of_meta "$meta")
  endpoint=$(fm_backend_target_of_meta "$meta")
  if ! fm_backend_validate "$backend" >/dev/null 2>&1 || [ -z "$endpoint" ]; then
    handoff_reject_locked "$id" "target '$target' has unsupported or incomplete backend metadata"
    return $?
  fi
  body_file=$(mktemp "$HANDOFF_ROOT/.body.XXXXXX") || return 1
  handoff_record_body "$record" > "$body_file" || { rm -f "$body_file"; return 1; }
  body=$(cat "$body_file"; printf '\001')
  body=${body%?}
  rm -f "$body_file"
  case "$body" in
    /*)
      handoff_reject_locked "$id" "the instruction is a harness-native invocation; cross-task handoffs accept ordinary text only"
      return $?
      ;;
    \$*)
      if [ "$(fm_meta_get "$meta" harness)" = codex ]; then
        handoff_reject_locked "$id" "the instruction is a Codex-native invocation; cross-task handoffs accept ordinary text only"
        return $?
      fi
      ;;
  esac
  meta_lock=$(fm_meta_lock_path "$meta") || return 1
  # shellcheck disable=SC2031 # Called within the lock-owning subshell.
  if [ "$HANDOFF_META_HELD" != 1 ] && ! fm_task_inbox_lock_acquire "$meta_lock"; then
    handoff_retryable_locked "$id" "target '$target' metadata could not be locked for delivery validation"
    return $?
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ] \
    || [ "$(fm_backend_of_meta "$meta")" != "$backend" ] \
    || [ "$(fm_backend_target_of_meta "$meta")" != "$endpoint" ] \
    || [ "$(fm_meta_get "$meta" kind)" = secondmate ] \
    || [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    handoff_release_meta "$meta_lock"
    handoff_reject_locked "$id" "target '$target' retired or changed route during delivery validation"
    return $?
  fi
  # The original handoff remains durable on a semantic stop or uncertainty.
  # A delivered retry above is readback only, never another enqueue.
  # shellcheck source=bin/fm-task-lifecycle-lib.sh
  . "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
  local binding bound_effect effect_rc
  binding=$(handoff_record_field "$record" lifecycle 2>/dev/null || true)
  if [ -n "$binding" ]; then
    if ! fm_task_lifecycle_execution_guard "$target"; then
      handoff_release_meta "$meta_lock"
      handoff_retryable_locked "$id" "bound handoff requires identity/authority reconciliation or effect readback"
      return $?
    fi
    effect_rc=0
    bound_effect=$(fm_task_lifecycle handoff-effect "$source" --target "$target" --record "$record") || effect_rc=$?
    if [ "$effect_rc" -eq 7 ]; then
      handoff_release_meta "$meta_lock"
      handoff_reject_locked "$id" "its exact bound source is terminal; no delivery occurred and the retained instruction must not be retried"
      return $?
    fi
    if [ "$effect_rc" -ne 0 ]; then
      handoff_release_meta "$meta_lock"
      handoff_retryable_locked "$id" "bound handoff requires identity/authority reconciliation or effect readback"
      return $?
    fi
    inbox_record=$(printf '%s' "$bound_effect" | jq -r '.readback // empty')
    if [ -n "$inbox_record" ]; then
      handoff_release_meta "$meta_lock"
      handoff_write_state "$id" delivered '' "$inbox_record" || return 1
      printf 'task handoff %s delivery recovered by readback at %s\n' "$id" "$inbox_record"
      return 0
    fi
  elif [ -f "${FM_DATA_OVERRIDE:-$FM_HOME/data}/$source/lifecycle.json" ] && [ "$(jq -r .schema "${FM_DATA_OVERRIDE:-$FM_HOME/data}/$source/lifecycle.json")" = fm-task-lifecycle.v2 ]; then
    handoff_release_meta "$meta_lock"
    handoff_retryable_locked "$id" "legacy handoff cannot acquire a delegated task's authority"
    return $?
  elif ! fm_task_lifecycle_execution_guard "$source" || ! fm_task_lifecycle_execution_guard "$target"; then
    handoff_release_meta "$meta_lock"
    handoff_retryable_locked "$id" "semantic stop or uncertain effect requires main reconciliation"
    return $?
  fi
  inbox_record=$(fm_task_inbox_write_handoff "$STATE" "$target" "$body" "$id" "$(fm_meta_get "$meta" spawn_gen)") || write_rc=$?
  handoff_release_meta "$meta_lock"
  if [ "$write_rc" -eq 2 ]; then
    handoff_reject_locked "$id" "target inbox already contains handoff id '$id' with a different instruction"
    return $?
  fi
  if [ "$write_rc" -ne 0 ]; then
    handoff_retryable_locked "$id" "target '$target' inbox could not be written"
    return $?
  fi
  handoff_write_state "$id" delivered '' "$inbox_record" || {
    echo "error: handoff '$id' reached $inbox_record but its delivered status could not be recorded; do not resend blindly - retrying the same id repairs status without duplicating the inbox record" >&2
    return 1
  }
  fm_task_inbox_ring "$backend" "$endpoint" "$inbox_record" "fm-$target" || ring_rc=$?
  case "$ring_rc" in
    2) echo "fm-task-handoff: doorbell did not reach $endpoint; delivered at $inbox_record and the watcher will re-ring" >&2 ;;
    4)
      if fm_wake_append stale "$endpoint" "stale: $endpoint (handoff doorbell submission outcome is uncertain for $inbox_record; do not replay blindly; inspect the worker)"; then
        if ! fm_task_inbox_record_escalated "$STATE" "$target" "$inbox_record"; then
          echo "fm-task-handoff: uncertainty wake was queued for $endpoint, but its inbox escalation marker could not be recorded; the watcher may report it again" >&2
        else
          echo "fm-task-handoff: doorbell submission is uncertain; delivered at $inbox_record and will not be replayed blindly" >&2
        fi
      else
        echo "fm-task-handoff: uncertainty wake could not be queued for $endpoint; leaving $inbox_record unmarked so the watcher can retry" >&2
      fi
      ;;
  esac
  printf 'task handoff %s delivered at %s\n' "$id" "$inbox_record"
}

handoff_retry_task_locked() {  # <target>
  local target=$1 record id record_target state matched=0 status=0 rc
  for record in "$HANDOFF_RECORDS"/*.msg; do
    [ -e "$record" ] || continue
    id=${record##*/}; id=${id%.msg}
    record_target=$(handoff_record_field "$record" target 2>/dev/null || true)
    [ "$record_target" = "$target" ] || continue
    state=$(handoff_state "$id")
    case "$state" in pending|retryable-refusal) ;; *) continue ;; esac
    matched=1
    rc=0
    handoff_deliver_locked "$id" || rc=$?
    [ "$rc" -eq 0 ] || status=$rc
  done
  [ "$matched" -eq 1 ] || return 0
  return "$status"
}

handoff_retry_all_locked() {
  local record id state matched=0 status=0 rc
  for record in "$HANDOFF_RECORDS"/*.msg; do
    [ -e "$record" ] || continue
    id=${record##*/}; id=${id%.msg}
    state=$(handoff_state "$id")
    case "$state" in pending|retryable-refusal) ;; *) continue ;; esac
    matched=1
    rc=0
    handoff_deliver_locked "$id" || rc=$?
    [ "$rc" -eq 0 ] || status=$rc
  done
  [ "$matched" -eq 1 ] || return 0
  return "$status"
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  send)
    [ "$#" -ge 5 ] || usage
    SOURCE=$1
    TARGET=$2
    shift 2
    [ "${1:-}" = --id ] && [ "$#" -ge 3 ] || usage
    ID=$2
    shift 2
    if [ "${1:-}" = --action-id ]; then
      [ $# -ge 3 ] || usage
      HANDOFF_ACTION_ID=$2
      shift 2
    fi
    MESSAGE=$*
    handoff_valid_atom "$SOURCE" || usage
    handoff_valid_atom "$TARGET" || usage
    handoff_valid_atom "$ID" || usage
    [ -n "$MESSAGE" ] || usage
    ;;
  retry|inspect)
    [ "$#" -eq 1 ] || usage
    ID=$1
    handoff_valid_atom "$ID" || usage
    ;;
  retry-task)
    [ "$#" -eq 1 ] || usage
    TARGET=$1
    handoff_valid_atom "$TARGET" || usage
    ;;
  retry-all)
    [ "$#" -eq 0 ] || usage
    ;;
  *) usage ;;
esac

if [ "$CMD" = inspect ]; then
  RECORD=$(handoff_record_path "$ID")
  STATUS_FILE=$(handoff_status_path "$ID")
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || {
    echo "error: no durable task handoff '$ID'" >&2
    exit 1
  }
  [ ! -e "$STATUS_FILE" ] || { [ -f "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ]; } || {
    echo "error: unsafe task-handoff status record: $STATUS_FILE" >&2
    exit 1
  }
  [ ! -f "$STATUS_FILE" ] || cat "$STATUS_FILE"
  cat "$RECORD"
  exit 0
fi

# Lease release and session-start sweep call the scoped retry commands even in
# homes that have never created a handoff. Keep that ordinary path a true
# no-op rather than materializing an empty ledger.
case "$CMD" in
  retry-task|retry-all)
    if [ ! -e "$HANDOFF_RECORDS" ] && [ ! -L "$HANDOFF_RECORDS" ]; then
      exit 0
    fi
    ;;
esac

fm_lock_acquire_wait "$HANDOFF_LOCK"
trap 'fm_lock_release "$HANDOFF_LOCK"' EXIT
handoff_prepare_dirs

case "$CMD" in
  send)
    handoff_prepare_record_locked "$ID" "$SOURCE" "$TARGET" "$MESSAGE" || exit $?
    handoff_deliver_locked "$ID"
    ;;
  retry)
    handoff_deliver_locked "$ID"
    ;;
  retry-task)
    handoff_retry_task_locked "$TARGET"
    ;;
  retry-all)
    handoff_retry_all_locked
    ;;
esac

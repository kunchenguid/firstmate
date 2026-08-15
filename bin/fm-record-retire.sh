#!/usr/bin/env bash
# Retire one ordinary task's runtime record and supervision footprint without
# resolving or touching any project, working copy, branch, or runtime endpoint.
# This is deliberately separate from fm-teardown.sh and never calls it.
#
# Usage:
#   fm-record-retire.sh <task-id> --work-safety scout-report
#   fm-record-retire.sh <task-id> --work-safety remote-ref \
#     --remote-url <url> --remote-ref <full-ref>
#
# No work-safety mode is inferred.
# `scout-report` requires kind=scout, a regular single-link
# data/<task-id>/report.md, and the existing unresolved-decision completion gate.
# This is sound because Firstmate's scout contract declares that report to be the
# complete durable work product and treats the disposable copy as scratch.
#
# `remote-ref` requires kind=ship and two exact metadata attestations recorded by
# an operator while the task's own copy identity was independently established:
#   record_retire_work_head=<40-or-64-hex commit>
#   record_retire_worktree_clean=1
# It then requires the caller-named GitHub remote ref to advertise that exact
# commit now.
# The clean attestation excludes uncommitted work, and the remote-tip equality
# proves every committed byte at that head is held outside the local copy.
# Missing attestations, remote access, the ref, or exact equality all refuse.
#
# The command reads task metadata, task state, the scout report when selected,
# and a caller-named remote ref when selected.
# It does not read worktree= or project= values from metadata and does not run
# git against any local repository.
# It never calls a backend, signals a process, removes tasktmp, runs treehouse,
# changes a branch, refreshes a clone, or deletes a working copy.
# Before mutating state it locks the home task set and every other metadata
# record, then refuses any raw runtime-slot or collapsed watcher-key collision.
#
# A successful retirement leaves state/.record-retired-<task-id>, whose format
# is owned by fm-record-retire-lib.sh.
# That marker mutes late status and turn-end writes from the intentionally
# untouched agent until a later fresh spawn of the same id clears it.
# It never mutes slot-keyed stale wakes because those carry no task identity.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ID=${1:-}
fm_record_retire_id_valid "$ID" || { usage >&2; exit 2; }
shift

WORK_SAFETY=
REMOTE_URL=
REMOTE_REF=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --work-safety)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      WORK_SAFETY=$2
      shift 2
      ;;
    --remote-url)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REMOTE_URL=$2
      shift 2
      ;;
    --remote-ref)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REMOTE_REF=$2
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$WORK_SAFETY" in
  scout-report|remote-ref) ;;
  '') refuse "--work-safety is required; no unlanded-work proof is inferred" ;;
  *) refuse "unsupported --work-safety value '$WORK_SAFETY'" ;;
esac
case "$WORK_SAFETY" in
  scout-report)
    [ -z "$REMOTE_URL" ] && [ -z "$REMOTE_REF" ] \
      || refuse "scout-report safety does not accept remote-ref arguments"
    ;;
  remote-ref)
    [ -n "$REMOTE_URL" ] || refuse "remote-ref safety requires --remote-url"
    [ -n "$REMOTE_REF" ] || refuse "remote-ref safety requires --remote-ref"
    ;;
esac

[ -d "$STATE" ] && [ ! -L "$STATE" ] || refuse "state directory is absent or unsafe at $STATE"
[ -d "$DATA" ] && [ ! -L "$DATA" ] || refuse "data directory is absent or unsafe at $DATA"
fm_refuse_if_gate_agent

META="$STATE/$ID.meta"
CONTROL_LOCK="$STATE/.control-$ID.lock"
TASK_SET_LOCK=
META_LOCK=
CONTROL_LOCK_HELD=0
TASK_SET_LOCK_HELD=0
META_LOCK_HELD=0
QUEUE_LOCK_HELD=0
OTHER_META_LOCKS=()

release_locks() {
  local status=$?
  if [ "$QUEUE_LOCK_HELD" = 1 ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    QUEUE_LOCK_HELD=0
  fi
  local index
  index=${#OTHER_META_LOCKS[@]}
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    fm_lock_release "${OTHER_META_LOCKS[$index]}" || true
  done
  OTHER_META_LOCKS=()
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  if [ "$TASK_SET_LOCK_HELD" = 1 ]; then
    fm_lock_release "$TASK_SET_LOCK" || true
    TASK_SET_LOCK_HELD=0
  fi
  return "$status"
}
trap release_locks EXIT

TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") \
  || refuse "task-set lock cannot be resolved for $STATE"
fm_lock_try_acquire "$TASK_SET_LOCK" \
  || refuse "the task set is changing; runtime-slot exclusivity cannot be established"
TASK_SET_LOCK_HELD=1
fm_lock_try_acquire "$CONTROL_LOCK" \
  || refuse "another lifecycle action is already running for task $ID; nothing was changed"
CONTROL_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] || refuse "task $ID has no regular metadata at $META"
META_LOCK=$(fm_meta_lock_path "$META") || refuse "task $ID metadata lock cannot be resolved"
fm_lock_acquire_wait "$META_LOCK" || refuse "task $ID metadata lock cannot be acquired"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] || refuse "task $ID metadata disappeared before retirement"

meta_exact() {  # <key>
  local key=$1 count value
  count=$(grep -c "^$key=" "$META" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  value=$(grep "^$key=" "$META" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

meta_file_exact() {  # <metadata-path> <key>
  local file=$1 key=$2 count value
  count=$(grep -c "^$key=" "$file" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  value=$(grep "^$key=" "$file" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

watcher_state_key() {  # <window>
  local key=$1
  key=${key//:/_}
  key=${key//\//_}
  key=${key//./_}
  printf '%s' "$key"
}

STATE_DEVICE=$(fm_pr_file_device "$STATE") || refuse "state device cannot be established"
DATA_DEVICE=$(fm_pr_file_device "$DATA") || refuse "data device cannot be established"

regular_single_link() {  # <path> <device>
  local path=$1 device=$2
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_link_count "$path")" = 1 ] || return 1
  [ "$(fm_pr_file_device "$path")" = "$device" ]
}

regular_state_artifact_if_present() {  # <path>
  local path=$1
  [ -e "$path" ] || [ -L "$path" ] || return 0
  regular_single_link "$path" "$STATE_DEVICE" \
    || refuse "unsafe task-state artifact at $path; no task state was retired"
}

regular_single_link "$META" "$STATE_DEVICE" \
  || refuse "task metadata is not a regular single-link file on the state device"
ENDPOINT_TASK_ID=$(meta_exact endpoint_task_id) \
  || refuse "metadata must contain exactly one nonempty endpoint_task_id"
[ "$ENDPOINT_TASK_ID" = "$ID" ] \
  || refuse "metadata belongs to task $ENDPOINT_TASK_ID, not $ID"
KIND=$(meta_exact kind) || refuse "metadata must contain exactly one nonempty kind"
WINDOW=$(meta_exact window) || refuse "metadata must contain exactly one nonempty window"
case "$WINDOW" in *$'\t'*|*$'\r'*|*$'\n'*) refuse "metadata window contains a control character" ;; esac
case "$KIND" in
  scout|ship) ;;
  secondmate) refuse "secondmate homes require the dedicated teardown path" ;;
  *) refuse "unsupported task kind '$KIND'" ;;
esac

lock_and_verify_runtime_slot_exclusive() {
  local other other_id other_window other_key other_lock target_key
  target_key=$(watcher_state_key "$WINDOW")
  for other in "$STATE"/*.meta; do
    [ -e "$other" ] || [ -L "$other" ] || continue
    [ "$other" != "$META" ] || continue
    regular_single_link "$other" "$STATE_DEVICE" \
      || refuse "runtime-slot exclusivity is unprovable because metadata is unsafe at $other"
    other_lock=$(fm_meta_lock_path "$other") \
      || refuse "runtime-slot exclusivity is unprovable because a metadata lock cannot be resolved for $other"
    fm_lock_try_acquire "$other_lock" \
      || refuse "runtime-slot exclusivity is unprovable because metadata is changing at $other"
    OTHER_META_LOCKS+=("$other_lock")
    regular_single_link "$other" "$STATE_DEVICE" \
      || refuse "runtime-slot exclusivity is unprovable because metadata changed at $other"
    other_id=$(meta_file_exact "$other" endpoint_task_id) \
      || refuse "runtime-slot exclusivity requires one exact endpoint_task_id in $other"
    [ "${other##*/}" = "$other_id.meta" ] \
      || refuse "runtime-slot exclusivity found a mismatched task binding in $other"
    other_window=$(meta_file_exact "$other" window) \
      || refuse "runtime-slot exclusivity requires one exact window in $other"
    if [ "$other_window" = "$WINDOW" ]; then
      refuse "runtime slot is also recorded by $other_id; no record state was retired"
    fi
    other_key=$(watcher_state_key "$other_window")
    if [ "$other_key" = "$target_key" ]; then
      refuse "watcher state key is also recorded by $other_id; no record state was retired"
    fi
  done
}

lock_and_verify_runtime_slot_exclusive

validate_report_safety() {
  local report
  [ "$KIND" = scout ] || refuse "scout-report safety requires kind=scout"
  report="$DATA/$ID/report.md"
  regular_single_link "$report" "$DATA_DEVICE" \
    || refuse "scout report is absent or not a regular single-link file at $report"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$ID" >/dev/null \
    || refuse "scout unresolved-decision completion gate cannot be verified"
}

remote_url_valid() {
  case "$1" in
    https://github.com/*/*|ssh://git@github.com/*/*|git@github.com:*/*) ;;
    *) return 1 ;;
  esac
  case "$1" in -*|*[[:space:]]*) return 1 ;; esac
}

validate_remote_ref_safety() {
  local work_head clean ls_output matches advertised
  [ "$KIND" = ship ] || refuse "remote-ref safety requires kind=ship"
  work_head=$(meta_exact record_retire_work_head) \
    || refuse "metadata must contain exactly one record_retire_work_head attestation"
  [[ "$work_head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] \
    || refuse "record_retire_work_head is not a full lowercase commit id"
  clean=$(meta_exact record_retire_worktree_clean) \
    || refuse "metadata must contain exactly one record_retire_worktree_clean attestation"
  [ "$clean" = 1 ] \
    || refuse "record_retire_worktree_clean must equal 1"
  remote_url_valid "$REMOTE_URL" \
    || refuse "--remote-url must name an explicit GitHub HTTPS or SSH repository"
  case "$REMOTE_REF" in refs/*) ;; *) refuse "--remote-ref must be a full refs/... name" ;; esac
  git check-ref-format "$REMOTE_REF" >/dev/null 2>&1 \
    || refuse "--remote-ref is not a valid full ref name"
  ls_output=$(git ls-remote --exit-code "$REMOTE_URL" "$REMOTE_REF" 2>/dev/null) \
    || refuse "remote ref cannot be read at $REMOTE_URL $REMOTE_REF"
  matches=$(printf '%s\n' "$ls_output" | awk -v ref="$REMOTE_REF" '$2 == ref { print $1 }')
  [ "$(printf '%s\n' "$matches" | sed '/^$/d' | LC_ALL=C wc -l | tr -d ' ')" = 1 ] \
    || refuse "remote did not return exactly one match for $REMOTE_REF"
  advertised=$(printf '%s\n' "$matches" | sed -n '1p')
  [ "$advertised" = "$work_head" ] \
    || refuse "remote ref advertises $advertised, not attested work head $work_head"
}

case "$WORK_SAFETY" in
  scout-report) validate_report_safety ;;
  remote-ref) validate_remote_ref_safety ;;
esac

if fm_pf_relay_active "$FM_HOME" && fm_pf_has_registrations "$STATE"; then
  refuse "public-followup registrations exist; settle or remove them before record retirement"
fi

refuse_bound_records() {  # <directory> <field>
  local dir=$1 field=$2 record
  [ -e "$dir" ] || [ -L "$dir" ] || return 0
  [ -d "$dir" ] && [ ! -L "$dir" ] \
    || refuse "runtime binding directory is unsafe at $dir"
  for record in "$dir"/*; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    [ -f "$record" ] && [ ! -L "$record" ] \
      || refuse "runtime binding record is unsafe at $record"
    if grep -qxF "$field=$ID" "$record" 2>/dev/null; then
      refuse "task $ID still owns runtime binding $record"
    fi
  done
}
refuse_bound_records "$STATE/terminal-outcomes" task_id
refuse_bound_records "$STATE/procevent" task_id
refuse_bound_records "$STATE/pending-replies" task_id

ARTIFACTS=(
  "$STATE/$ID.status"
  "$STATE/$ID.turn-ended"
  "$STATE/$ID.pi-ext.ts"
  "$STATE/$ID.grok-turnend-token"
  "$STATE/$ID.kimi-turnend-token"
  "$STATE/$ID.muse-session"
  "$STATE/$ID.muse-session-current"
  "$STATE/$ID.cursor-session"
  "$STATE/$ID.control-relaunch"
  "$STATE/$ID.control-relaunch.meta-prior"
  "$STATE/$ID.control-relaunch.brief-prior"
  "$STATE/$ID.control-relaunch.note"
  "$STATE/$ID.herdr-presentation"
  "$STATE/$ID.busy-gen"
  "$STATE/$ID.busy-state"
  "$STATE/$ID.check.sh"
  "$STATE/$ID.check-trust"
  "$STATE/$ID.pr-poll"
  "$STATE/$ID.pr-poll-registration"
  "$STATE/$ID.pr-poll-retirement"
  "$STATE/.$ID.open-decisions-cursor"
  "$STATE/.seen-${ID}_status"
  "$STATE/.seen-${ID}_turn-ended"
  "$STATE/.hb-surfaced-$ID"
)
WINDOW_KEY=$(watcher_state_key "$WINDOW")
for prefix in hash count stale stale-since paused paused-rechecked paused-resurfaced wedge-escalations; do
  ARTIFACTS+=("$STATE/.$prefix-$WINDOW_KEY")
done
for artifact in "${ARTIFACTS[@]}"; do
  regular_state_artifact_if_present "$artifact"
done
if [ -e "$STATE/$ID.busy-state.lock" ] || [ -L "$STATE/$ID.busy-state.lock" ]; then
  refuse "busy-state writer lock exists for task $ID"
fi

QUARANTINE="$STATE/.pr-check-quarantine"
if [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
  [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] \
    || refuse "PR-check quarantine path is unsafe at $QUARANTINE"
  for artifact in "$QUARANTINE/$ID."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    regular_single_link "$artifact" "$STATE_DEVICE" \
      || refuse "unsafe task quarantine entry at $artifact"
  done
fi

BUSY_GEN=$(meta_exact busy_gen 2>/dev/null || true)
if { [ -e "$STATE/$ID.busy-gen" ] || [ -e "$STATE/$ID.busy-state" ]; } && [ -z "$BUSY_GEN" ]; then
  refuse "busy-state exists but metadata has no exact busy_gen; incarnation safety is unprovable"
fi
META_SHA256=$(fm_record_retire_sha256_file "$META") \
  || refuse "SHA-256 support is required to bind the retirement marker"
RETIREMENT_MARKER=$(fm_record_retire_marker_path "$STATE" "$ID")
if [ -e "$RETIREMENT_MARKER" ] || [ -L "$RETIREMENT_MARKER" ]; then
  regular_single_link "$RETIREMENT_MARKER" "$STATE_DEVICE" \
    || refuse "existing record-retirement marker is unsafe at $RETIREMENT_MARKER"
  fm_record_retire_marker_valid "$STATE" "$ID" \
    || refuse "existing record-retirement marker is invalid at $RETIREMENT_MARKER"
  [ "$(fm_record_retire_marker_window "$STATE" "$ID")" = "$WINDOW" ] \
    || refuse "existing record-retirement marker names a different runtime target"
  [ "$(sed -n '4s/^meta_sha256=//p' "$RETIREMENT_MARKER")" = "$META_SHA256" ] \
    || refuse "existing record-retirement marker names a different metadata generation"
fi

# Retire status presentation first through its existing serialized owner.
# All safety checks above have passed, and a failure here leaves metadata intact.
status_retire_presentation_task "$STATE" "$ID" \
  || refuse "status presentation state could not be retired safely"
if [ -n "$BUSY_GEN" ]; then
  "$SCRIPT_DIR/fm-busy-event.sh" retire "$STATE" "$ID" --gen "$BUSY_GEN" \
    || refuse "busy-state incarnation could not be retired safely"
fi

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || refuse "wake-queue lock cannot be acquired"
QUEUE_LOCK_HELD=1
fm_record_retire_marker_publish "$STATE" "$ID" "$WINDOW" "$META_SHA256" \
  || refuse "record-retirement marker could not be published safely"

retire_queue_rows_locked() {
  local queue=$FM_WAKE_QUEUE tmp
  [ -e "$queue" ] || [ -L "$queue" ] || return 0
  regular_single_link "$queue" "$STATE_DEVICE" || return 1
  tmp="$queue.retire.${BASHPID:-$$}"
  awk -F '\t' -v id="$ID" -v window="$WINDOW" -v check="$STATE/$ID.check.sh" '
    NF < 5 { print; next }
    $3 == "signal" && ($4 == id ".status" || $4 == id ".turn-ended") { next }
    $3 == "stale" && $4 == window { next }
    $3 == "check" && $4 == check { next }
    { print }
  ' "$queue" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$queue" || { rm -f -- "$tmp"; return 1; }
}
retire_queue_rows_locked || refuse "task wake rows could not be retired safely"

fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || refuse "PR-poll retirement state could not be reconciled safely"
rm -f -- "$STATE/$ID.check.sh" "$STATE/$ID.check-trust" \
  "$STATE/$ID.pr-poll" "$STATE/$ID.pr-poll-registration" \
  "$STATE/$ID.pr-poll-retirement"
if [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ]; then
  for artifact in "$QUARANTINE/$ID."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    rm -f -- "$artifact"
  done
  rmdir "$QUARANTINE" 2>/dev/null || true
fi

rm -f -- "${ARTIFACTS[@]}" "$META"
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
QUEUE_LOCK_HELD=0
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

printf 'record retirement %s complete; no endpoint, process, branch, project, or working copy was touched\n' "$ID"

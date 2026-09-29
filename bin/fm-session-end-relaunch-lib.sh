#!/usr/bin/env bash
# shellcheck disable=SC2034 # Output globals are read by the watcher tick and tests.
# fm-session-end-relaunch-lib.sh - relaunch an in-flight ship or scout whose
# SessionEnd busy record says the worker is gone.
#
# The watcher tick is the only driver. This is not a supervisor, daemon, or
# state machine. Eligibility, the deliberate-exit skip, the pause and hold
# skip, and the attempt caps live here. Replacement goes through
# bin/fm-control.sh relaunch, which keeps the recorded worktree and does not
# discard uncommitted work.
#
# A task is eligible when all of these hold:
#   - kind is ship or scout (a secondmate keeps its own liveness path)
#   - state/<id>.meta and the recorded worktree still exist, and
#     state/<id>.backlog-close is absent
#   - the current busy record is event=session-end
#   - the latest status verb is not done or failed
#   - no declared pause or captain-held status line
#   - fm_backend_agent_state is dead (pane at a shell, no agent) or missing
#   - fm-captain-hold.sh open reports no open captain call (exit 1); an open
#     call or an answer it cannot establish skips the lane
#   - state/<id>.control-exit does not name this busy generation
#   - no control lock is held, and no in-progress control-relaunch journal
#
# A completed fm-control exit retires the busy record, so its session-end
# is never seen here. The control-exit marker covers the exit whose command
# was delivered but whose agent did not stop within the exit wait: that
# exit never retired the record, and its later session-end is still
# deliberate.
#
# Caps count attempt rows in state/.session-end-relaunch-<id>: at most one
# attempt per task in 30 minutes, and at most 3 per task in a day.
# Past either cap the tick does not relaunch and wakes once for that
# session-end generation. A later generation is a new episode.
# One fm-control call is bounded to 300 seconds, above its own launch wait
# (pinned to 90 seconds) plus the fm-spawn --relaunch run, so a slow start
# ends through fm-control's own rollback rather than the bound.
#
# fm_session_end_relaunch_scan sets FM_SESSION_END_WAKE to the first check
# line that should be printed, or empty when this pass has nothing to say.
# It also appends each check row to the durable wake queue. It stops after
# the first relaunch attempt, so one watcher cycle runs at most one bounded
# fm-control call; the next cycle takes the next lane.
#
# FM_SESSION_END_CONTROL overrides the control binary only when FM_TEST_SEAM=1.
set -u

_FM_SESSION_END_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
if ! declare -F fm_wake_append >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_SESSION_END_DIR/fm-wake-lib.sh"
fi
if ! declare -F fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_SESSION_END_DIR/fm-backend.sh"
fi
if ! declare -F fm_busy_record_read >/dev/null 2>&1; then
  # shellcheck source=bin/fm-busy-lib.sh
  . "$_FM_SESSION_END_DIR/fm-busy-lib.sh"
fi
if ! declare -F last_status_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_SESSION_END_DIR/fm-classify-lib.sh"
fi
if ! declare -F fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$_FM_SESSION_END_DIR/fm-timeout-lib.sh"
fi

FM_SESSION_END_MIN_SECS=1800
FM_SESSION_END_DAY_SECS=86400
FM_SESSION_END_DAY_MAX=3
FM_SESSION_END_LAUNCH_WAIT=90
FM_SESSION_END_TIMEOUT=300

fm_session_end_control_bin() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_SESSION_END_CONTROL:-}" ]; then
    printf '%s' "$FM_SESSION_END_CONTROL"
    return 0
  fi
  printf '%s' "$_FM_SESSION_END_DIR/fm-control.sh"
}

fm_session_end_ledger_path() {  # <state-dir> <id>
  printf '%s/.session-end-relaunch-%s' "$1" "$2"
}

fm_session_end_handled_path() {  # <state-dir> <id>
  printf '%s/.session-end-handled-%s' "$1" "$2"
}

# Count attempt rows no older than <window-secs>. Prints a number. Non-zero
# when the ledger cannot be read.
fm_session_end_count_attempts() {  # <state-dir> <id> <window-secs>
  local state=$1 id=$2 window=$3 ledger now cutoff n=0 epoch kind
  ledger=$(fm_session_end_ledger_path "$state" "$id")
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  [ -f "$ledger" ] && [ ! -L "$ledger" ] && [ -r "$ledger" ] || return 1
  now=$(date +%s) || return 1
  cutoff=$((now - window))
  while IFS=$'\t' read -r epoch kind || [ -n "$epoch" ]; do
    [ "$kind" = attempt ] || continue
    case "$epoch" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$epoch" -ge "$cutoff" ] || continue
    n=$((n + 1))
  done < "$ledger"
  printf '%s\n' "$n"
}

fm_session_end_ledger_add() {  # <state-dir> <id> <attempt|relaunched|failed>
  local ledger
  ledger=$(fm_session_end_ledger_path "$1" "$2")
  printf '%s\t%s\n' "$(date +%s)" "$3" >> "$ledger" 2>/dev/null
}

# A current session-end record. Prints "gen seq" or nothing.
fm_session_end_identity() {  # <state-dir> <id>
  local state=$1 id=$2 gen out r_state r_source r_event r_seq
  out=$(fm_busy_record_read "$state" "$id" 2>/dev/null) || return 1
  read -r r_state r_source r_event r_seq <<< "$out"
  [ "$r_state" = idle ] && [ "$r_event" = session-end ] && [ -n "$r_seq" ] || return 1
  gen=$(fm_busy_current_gen "$state" "$id") || return 1
  printf '%s %s\n' "$gen" "$r_seq"
}

fm_session_end_note() {
  printf '%s' "The previous worker session ended while this task was still open. The local copy and every uncommitted change were left as the previous worker left them. Continue from the instructions and the instruction inbox."
}

fm_session_end_first_line() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | head -1)
  line=${line//$'\t'/ }
  printf '%s' "${line:0:180}"
}

fm_session_end_queue_wake() {  # <key> <reason>
  local queued
  [ -n "${FM_WAKE_QUEUE:-}" ] || FM_WAKE_QUEUE="$STATE/.wake-queue"
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  if printf '%s\n' "$queued" | grep -Fx "$1" >/dev/null 2>&1; then
    return 0
  fi
  fm_wake_append check "$1" "$2"
}

# Decide and, when eligible, relaunch. Sets FM_SESSION_END_ACTION to
# relaunch, failed, capped, or skip, and FM_SESSION_END_REASON to a check
# line or empty. Returns 0 for a completed decision, 1 when a required
# ledger or wake row could not be written.
fm_session_end_relaunch_consider() {  # <state-dir> <id>
  local state=$1 id=$2 meta kind wt backend window agent
  local identity gen seq last verb hold_rc marker marker_gen
  local journal phase lock recent day handled
  local handled_gen handled_seq handled_outcome
  local bin out rc=0 reason key which
  FM_SESSION_END_ACTION=skip
  FM_SESSION_END_REASON=
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ ! -e "$state/$id.backlog-close" ] && [ ! -L "$state/$id.backlog-close" ] || return 0
  kind=$(fm_meta_get "$meta" kind 2>/dev/null || true)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *) return 0 ;;
  esac
  wt=$(fm_meta_get "$meta" worktree 2>/dev/null || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  identity=$(fm_session_end_identity "$state" "$id") || return 0
  gen=${identity%% *}
  seq=${identity#* }
  marker="$state/$id.control-exit"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    marker_gen=$(sed -n 's/^gen=//p' "$marker" | head -1)
    [ "$marker_gen" != "$gen" ] || return 0
  fi
  recent=$(fm_session_end_count_attempts "$state" "$id" "$FM_SESSION_END_MIN_SECS") || return 1
  day=$(fm_session_end_count_attempts "$state" "$id" "$FM_SESSION_END_DAY_SECS") || return 1
  handled=$(fm_session_end_handled_path "$state" "$id")
  handled_gen='' handled_seq='' handled_outcome=''
  if [ -f "$handled" ] && [ ! -L "$handled" ]; then
    IFS=$'\t' read -r handled_gen handled_seq handled_outcome < "$handled" || true
  fi
  if [ "$handled_gen" = "$gen" ] && [ "$handled_seq" = "$seq" ] \
     && { [ "$handled_outcome" = relaunched ] || [ "$handled_outcome" = failed ]; } \
     && [ "$recent" -ge 1 ]; then
    return 0
  fi
  which=
  if [ "$recent" -ge 1 ]; then
    which=min
  elif [ "$day" -ge "$FM_SESSION_END_DAY_MAX" ]; then
    which=day
  fi
  if [ -n "$which" ] && [ "$handled_gen" = "$gen" ] && [ "$handled_seq" = "$seq" ] \
     && [ "$handled_outcome" = "capped-$which" ]; then
    return 0
  fi
  last=$(last_status_line "$state/$id.status" 2>/dev/null || true)
  verb=$(status_line_verb "$last" 2>/dev/null || true)
  case "$verb" in
    done|failed) return 0 ;;
  esac
  if [ -n "$(status_declared_wait_line "$state/$id.status" 2>/dev/null || true)" ]; then
    return 0
  fi
  backend=$(fm_meta_get "$meta" backend 2>/dev/null || true)
  [ -n "$backend" ] || backend=tmux
  window=$(fm_meta_get "$meta" window 2>/dev/null || true)
  [ -n "$window" ] || return 0
  agent=$(fm_backend_agent_state "$backend" "$window" 2>/dev/null || printf 'unreadable')
  case "$agent" in
    dead|missing) ;;
    *) return 0 ;;
  esac
  if [ -n "${FM_HOME:-}" ] && [ -x "$_FM_SESSION_END_DIR/fm-captain-hold.sh" ]; then
    hold_rc=0
    FM_HOME="$FM_HOME" "$_FM_SESSION_END_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 || hold_rc=$?
    [ "$hold_rc" -eq 1 ] || return 0
  fi
  lock="$state/.control-$id.lock"
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    if ! fm_lock_try_acquire "$lock"; then
      return 0
    fi
    fm_lock_release "$lock" || return 1
  fi
  journal="$state/$id.control-relaunch"
  if [ -f "$journal" ] && [ ! -L "$journal" ]; then
    phase=$(sed -n 's/^phase=//p' "$journal" | head -1)
    case "$phase" in
      ''|complete|failed:*) ;;
      *) return 0 ;;
    esac
  fi
  if [ -n "$which" ]; then
    if [ "$which" = min ]; then
      reason="check: $id auto-relaunch paused after 1 attempt in ${FM_SESSION_END_MIN_SECS}s; session-end still recorded"
    else
      reason="check: $id auto-relaunch paused after $FM_SESSION_END_DAY_MAX attempts in ${FM_SESSION_END_DAY_SECS}s; session-end still recorded"
    fi
    key="session-end-relaunch-capped-$id-$gen-$seq-$which"
    fm_session_end_queue_wake "$key" "$reason" || return 1
    printf '%s\t%s\tcapped-%s\n' "$gen" "$seq" "$which" > "$handled" || return 1
    FM_SESSION_END_ACTION=capped
    FM_SESSION_END_REASON=$reason
    return 0
  fi
  fm_session_end_ledger_add "$state" "$id" attempt || return 1
  bin=$(fm_session_end_control_bin)
  rc=0
  out=$(fm_run_timed "$FM_SESSION_END_TIMEOUT" env FM_HOME="${FM_HOME:-}" FM_STATE_OVERRIDE="$state" \
    FM_CONTROL_LAUNCH_WAIT="$FM_SESSION_END_LAUNCH_WAIT" \
    "$bin" "$id" relaunch --note "$(fm_session_end_note)" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    fm_session_end_ledger_add "$state" "$id" relaunched || return 1
    reason="check: $id auto-relaunched after session-end"
    key="session-end-relaunch-$id-$gen-$seq"
    fm_session_end_queue_wake "$key" "$reason" || return 1
    printf '%s\t%s\trelaunched\n' "$gen" "$seq" > "$handled" || return 1
    FM_SESSION_END_ACTION=relaunch
    FM_SESSION_END_REASON=$reason
    return 0
  fi
  fm_session_end_ledger_add "$state" "$id" failed || return 1
  reason="check: $id auto-relaunch failed after session-end: $(fm_session_end_first_line "$out")"
  key="session-end-relaunch-failed-$id-$gen-$seq"
  fm_session_end_queue_wake "$key" "$reason" || return 1
  printf '%s\t%s\tfailed\n' "$gen" "$seq" > "$handled" || return 1
  FM_SESSION_END_ACTION=failed
  FM_SESSION_END_REASON=$reason
  return 0
}

# Scan this home's task records. Sets FM_SESSION_END_WAKE to the first
# supervisor-visible line, or empty. Returns non-zero only when a required
# write failed.
fm_session_end_relaunch_scan() {  # <state-dir>
  local state=$1 meta id reason first=
  FM_SESSION_END_WAKE=
  [ -d "$state" ] || return 0
  [ -n "${FM_WAKE_QUEUE:-}" ] || FM_WAKE_QUEUE="$state/.wake-queue"
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    if ! fm_session_end_relaunch_consider "$state" "$id"; then
      return 1
    fi
    reason=$FM_SESSION_END_REASON
    if [ -n "$reason" ] && [ -z "$first" ]; then
      first=$reason
    fi
    case "$FM_SESSION_END_ACTION" in
      relaunch|failed) break ;;
    esac
  done
  FM_SESSION_END_WAKE=$first
  return 0
}

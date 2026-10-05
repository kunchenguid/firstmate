#!/usr/bin/env bash
# Codex Stop-owned idle continuity for process-event reconciliation.
#
# Codex Stop hooks are synchronous and asynchronous command hooks are not
# available (codex-cli 0.154.0, developers.openai.com/codex/hooks). Holding
# the watcher inside the hook would keep the turn in progress. This script
# therefore starts one detached supervisor only on the allowing stop
# (stop_hook_active true), after the one forced continuation, and then
# forwards the original payload to bin/fm-turnend-guard.sh.
#
# The supervisor is not a shell job of the hook. It is detached with a perl
# fork-and-setsid, because util-linux setsid is absent on macOS, so the hook
# returns as soon as the new session exists. The supervisor backgrounds one
# bin/fm-watch-arm.sh at a time and waits on it, so it can stop the arm when
# the recorded Codex process exits. While that process lives, each
# actionable arm close is queued back into the same thread with
# `codex queue`. FM_CODEX_IDLE_QUEUE, when set, receives that text on stdin
# instead. FM_CODEX_IDLE_OWNER_PID overrides the Codex ancestor walk.
#
# Away mode is checked again whenever an arm closes and before the next one
# starts: an away-mode close is not queued and the watcher is not stopped,
# because the away daemon owns triage from then on.
#
# A home that opted into config/supervision-host is not covered yet
# (https://github.com/kunchenguid/firstmate/issues/5899): it never starts a
# supervisor, and its in-turn checkpoint is unchanged.
#
# Only the session that owns state/.lock, as bin/fm-session-lock-lib.sh
# decides it, starts or repairs a supervisor; a dead recorded owner is
# reclaimed through bin/fm-lock.sh first, as bin/fm-claude-stop-autoarm.sh
# does. An idle home, away mode, a child worktree, or a stop that is still the
# first one in the turn does not start a supervisor. A live supervisor is
# left in place. This script never prints on the spawn path: the guard's
# stdout and stderr are the hook output.
#
# The supervisor owns only the idle gap. bin/fm-watch-checkpoint.sh runs
# `--handover` before it starts a watcher, and only when this process's
# session owns state/.lock: that stops this home's supervisor, matched by its
# recorded pid identity, and waits for the watcher lock to be free, so the
# turn's checkpoint owns supervision until the next allowing stop starts a
# fresh supervisor. A checkpoint from any other session leaves the owner's
# supervisor running. The lock directory is written before the detached
# supervisor exists, with the hook pid in `starting`, and neither a second
# stop nor a handover treats that directory as stale until `pid` is recorded
# or the hook pid is dead. Stops that overlap take
# state/.codex-idle-continuity-claim.lock in turn to check, reclaim and
# create that directory, so only one of them starts a supervisor. An arm cycle that ends because another owner took
# or ended the watcher is a handover, not a failure. A later
# `attached watcher ... stalled` line is a failure even when an earlier line
# said `watcher: attached`.
#
# When the recorded Codex owner exits, the supervisor stops a watcher only
# when this supervisor's own arm printed `watcher: started`. An arm that only
# attached is following a watcher someone else started, and a home-wide
# `--stop` would take that watcher down with the owner.
#
# The arm after a queued close is a handling successor
# (FM_WATCH_PREDECESSOR_ARM_PID, as bin/fm-claude-stop-autoarm.sh passes): the
# queued wake is already on its way, so that watcher does not resurface
# watcher downtime the primary has not drained yet.
#
# After three failed arms the supervisor queues one `check:` line and records
# the episode in state/.codex-idle-continuity-failure-notified. While that
# record stands no allowing stop starts a supervisor, so a watcher that stays
# broken wakes the thread once rather than once per turn. An actionable
# supervisor close or a successful bin/fm-watch-checkpoint.sh clears it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LOCK="$STATE/.codex-idle-continuity.lock"
CLAIM_MUTEX="$STATE/.codex-idle-continuity-claim.lock"
FAILURE_NOTICE="$STATE/.codex-idle-continuity-failure-notified"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"

codex_ancestor() {
  local pid comm
  if [ -n "${FM_CODEX_IDLE_OWNER_PID:-}" ]; then
    printf '%s\n' "$FM_CODEX_IDLE_OWNER_PID"
    return 0
  fi
  pid=$PPID
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    comm=$(ps -p "$pid" -o comm= 2>/dev/null) || comm=
    case "$(basename -- "$comm" 2>/dev/null)" in
      codex) printf '%s\n' "$pid"; return 0 ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]') || pid=
  done
  return 1
}

supervisor_live() {
  local pid
  [ -f "$LOCK/pid" ] || return 1
  IFS= read -r pid < "$LOCK/pid" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

reclaim_stale_lock() {
  local starter
  supervisor_live && return 1
  # pid is written by the child after the parent has already created the lock.
  # Until that write, the hook pid in `starting` is the proof the lock is live.
  if [ -f "$LOCK/starting" ] && [ ! -s "$LOCK/pid" ]; then
    IFS= read -r starter < "$LOCK/starting" || starter=
    case "$starter" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$starter" 2>/dev/null && return 1 ;;
    esac
  fi
  rm -rf "$LOCK"
  return 0
}

stop_home_supervisor() {
  local pid identity i starter
  if [ ! -s "$LOCK/pid" ] && [ -f "$LOCK/starting" ]; then
    IFS= read -r starter < "$LOCK/starting" || starter=
    i=0
    while [ "$i" -lt 50 ] && [ ! -s "$LOCK/pid" ]; do
      case "$starter" in
        ''|*[!0-9]*) break ;;
      esac
      kill -0 "$starter" 2>/dev/null || break
      sleep 0.1
      i=$((i + 1))
    done
    if [ ! -s "$LOCK/pid" ]; then
      case "$starter" in
        ''|*[!0-9]*) return 0 ;;
      esac
      kill -0 "$starter" 2>/dev/null && return 1
      return 0
    fi
  fi
  [ -f "$LOCK/pid" ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  IFS= read -r pid < "$LOCK/pid" || return 0
  IFS= read -r identity < "$LOCK/pid-identity" || return 0
  fm_pid_alive "$pid" || return 0
  [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 150 ] && fm_pid_alive "$pid"; do
    sleep 0.1
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 50 ] && fm_pid_alive "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)"; do
    sleep 0.1
    i=$((i + 1))
  done
  ! fm_pid_alive "$pid" && ! fm_pid_alive "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)"
}

claim_lock() {  # <owner-pid> <session-id>
  supervisor_live && return 1
  reclaim_stale_lock || return 1
  mkdir "$LOCK" 2>/dev/null || return 1
  # Record the hook pid before the child exists so a second stop cannot
  # reclaim this directory in the gap before `pid` is written.
  printf '%s\n' "$$" > "$LOCK/starting"
  printf '%s\n' "$1" > "$LOCK/owner"
  printf '%s\n' "$2" > "$LOCK/session"
}

ensure_supervisor() {  # <session-id>
  local owner session=$1 lock_pid recover_session_lock=0 i claimed
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  # shellcheck source=bin/fm-supervision-engine-lib.sh
  . "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || return 0
  if ! fm_session_lock_owned_by_self "$STATE"; then
    lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
    case "$lock_pid" in
      ''|*[!0-9]*) return 0 ;;
    esac
    fm_harness_pid_alive "$lock_pid" && return 0
    recover_session_lock=1
  fi
  [ -e "$STATE/.afk" ] && return 0
  fm_supervision_host_enabled "$CONFIG" codex && return 0
  [ -e "$FAILURE_NOTICE" ] && return 0
  fm_supervision_needed "$STATE" || return 0
  if [ "$recover_session_lock" -eq 1 ]; then
    "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || return 0
    fm_session_lock_owned_by_self "$STATE" || return 0
  fi
  owner=$(codex_ancestor) || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # Judging the lock stale, removing it, and writing `starting` into the new
  # one are separate steps. Without this mutex an overlapping stop removes a
  # directory another stop has just created, and both start a supervisor.
  fm_lock_try_acquire "$CLAIM_MUTEX" || return 0
  claim_lock "$owner" "$session"
  claimed=$?
  fm_lock_release "$CLAIM_MUTEX"
  [ "$claimed" -eq 0 ] || return 0
  if ! perl -MPOSIX -e 'defined(my $pid = fork) or exit 1; exit 0 if $pid; POSIX::setsid(); exec @ARGV or exit 127' \
    "$0" --supervise </dev/null >/dev/null 2>&1; then
    rm -rf "$LOCK"
    return 0
  fi
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$LOCK/pid" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$LOCK/pid" ]; then
    rm -rf "$LOCK"
  fi
}

queue_text() {
  local text=$1 session
  [ -n "$text" ] || return 0
  if [ -n "${FM_CODEX_IDLE_QUEUE:-}" ]; then
    printf '%s\n' "$text" | "$FM_CODEX_IDLE_QUEUE"
    return 0
  fi
  IFS= read -r session < "$LOCK/session" || session=
  [ -n "$session" ] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  codex queue --thread "$session" --message "$text" >/dev/null 2>&1 || true
}

actionable_text() {
  awk '/^(signal:|stale:|check:|heartbeat(:|$))/'
}

handed_over() {
  # The last arm outcome wins. An earlier `watcher: attached` does not hide a
  # later stall; a clean attached close or a signal exit still is a handover.
  awk '
    /^watcher: attached / { outcome = "handover" }
    /^watcher: started / { outcome = "started" }
    /^watcher: FAILED - watcher cycle exited [0-9]+ / {
      if ($7 + 0 > 128) outcome = "handover"; else outcome = "failed"
    }
    /^watcher: FAILED - cycle ended without an actionable reason/ {
      if (outcome != "handover") outcome = "failed"
    }
    /^watcher: FAILED - attached watcher pid=/ && / stalled / { outcome = "failed" }
    /^watcher: FAILED - no live watcher/ { outcome = "failed" }
    END { exit (outcome == "handover") ? 0 : 1 }
  '
}

attached_only() {
  [ -f "$LOCK/arm.out" ] || return 1
  grep -q '^watcher: attached ' "$LOCK/arm.out" || return 1
  ! grep -q '^watcher: started ' "$LOCK/arm.out"
}

owner_left() {
  if ! attached_only; then
    "$ARM" --stop >/dev/null 2>&1 || true
  fi
  if [ -n "${arm_pid:-}" ]; then
    kill -TERM "$arm_pid" 2>/dev/null || true
    wait "$arm_pid" 2>/dev/null || true
    arm_pid=
  fi
  rm -rf "$LOCK"
  exit 0
}

end_supervision() {
  if [ -n "${arm_pid:-}" ]; then
    kill -TERM "$arm_pid" 2>/dev/null || true
    wait "$arm_pid" 2>/dev/null || true
  fi
  "$ARM" --stop >/dev/null 2>&1 || true
  rm -rf "$LOCK"
  exit 0
}

leave_watcher() {
  rm -rf "$LOCK"
  exit 0
}

supervise() {
  local owner arm_pid='' closed_arm text fails=0 predecessor=''
  IFS= read -r owner < "$LOCK/owner" || exit 0
  case "$owner" in ''|*[!0-9]*) exit 0 ;; esac
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_pid_identity "$$" > "$LOCK/pid-identity" || { rm -rf "$LOCK"; exit 0; }
  printf '%s\n' "$$" > "$LOCK/pid"
  rm -f "$LOCK/starting"
  trap end_supervision TERM INT
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  while kill -0 "$owner" 2>/dev/null; do
    [ -e "$STATE/.afk" ] && leave_watcher
    fm_supervision_needed "$STATE" || break
    FM_WATCH_PREDECESSOR_ARM_PID=$predecessor "$ARM" >"$LOCK/arm.out" 2>&1 &
    arm_pid=$!
    predecessor=
    while kill -0 "$arm_pid" 2>/dev/null; do
      if ! kill -0 "$owner" 2>/dev/null; then
        owner_left
      fi
      sleep 0.5
    done
    wait "$arm_pid" || true
    closed_arm=$arm_pid
    arm_pid=
    [ -e "$STATE/.afk" ] && leave_watcher
    text=$(actionable_text < "$LOCK/arm.out" || true)
    if [ -n "$text" ]; then
      fails=0
      rm -f "$FAILURE_NOTICE"
      queue_text "$text" || true
      predecessor=$closed_arm
      continue
    fi
    if ! handed_over < "$LOCK/arm.out"; then
      fails=$((fails + 1))
      if [ "$fails" -ge 3 ]; then
        if (set -C; : > "$FAILURE_NOTICE") 2>/dev/null; then
          queue_text "check: codex idle continuity stopped after $fails failed watcher arms: $(tail -n 1 "$LOCK/arm.out")" || true
        fi
        break
      fi
    fi
    sleep 1
  done
  if ! kill -0 "$owner" 2>/dev/null; then
    owner_left
  fi
  end_supervision
}

case "${1:-}" in
  --supervise) supervise ;;
  --handover) stop_home_supervisor; exit $? ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
export FM_ROOT FM_HOME STATE FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$FM_ROOT}"
if command -v jq >/dev/null 2>&1; then
  stop_active=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" and .stop_hook_active == true then "true" else "false" end' 2>/dev/null || printf 'false')
  session=$(printf '%s' "$PAYLOAD" | jq -r 'if type == "object" then (.session_id // "") else "" end' 2>/dev/null || printf '')
  if [ "$stop_active" = "true" ]; then
    ensure_supervisor "$session"
  fi
fi
printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh"
exit $?

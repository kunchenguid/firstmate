#!/usr/bin/env bash
# fm-supervision-session-end.sh - keep the supervision host running after a
# Claude main session ends without /afk (opt-in: config/supervision-host-session-end).
#
# Registered in tracked .claude/settings.json as the SessionEnd command hook.
# The Claude primary's supervision host runs inside its Stop hook
# (bin/fm-claude-stop-autoarm.sh), and Claude kills that hook when its process
# exits, so without this nothing supervises the home until the next session's
# first turn ends, and a check wake such as a daily run starts nobody.
# docs/supervision-host.md "After the main session ends" owns the design.
#
# HOOK MODE (no arguments; the SessionEnd payload on stdin). It does nothing
# unless every one of these holds:
#   - the payload is Claude's own (not Cursor's or pi-code's) and its reason is
#     not clear or resume, the two ends after which the same Claude process
#     runs on and its parked host survives;
#   - the root is a genuine primary checkout (bin/fm-primary-scope-lib.sh);
#   - config/supervision-host-session-end exists, the home runs the host on a
#     Claude primary, and the host has an engine
#     (bin/fm-supervision-engine-lib.sh);
#   - this session holds the session lock (bin/fm-session-lock-lib.sh);
#   - no away-posture record (state/.afk-contract, away or quiet) and no away
#     daemon flag (state/.afk) exist, so /afk and /quiet are never changed;
#   - the home needs supervision (bin/fm-supervision-lib.sh).
# Then it enters the away posture with no words through bin/fm-afk-launch.sh
# enter, because the captain is gone and only the away posture lets the
# host's engine take every wake, check wakes included, on standing authority.
# Last, it starts the keeper below detached: nohup, stdio closed, in a process
# group of its own, the one way a process outlives a Claude hook
# (docs/verification/supervision.md). The hook prints nothing and exits 0.
#
# KEEPER MODE (keep <autoarm-gen> <confirmed-epoch> <session-pid>; private to
# the hook). It waits up to 30 seconds for the ended session's process to
# exit, then runs bin/fm-supervision-host.sh park with
# FM_SUPERVISION_HOST_SESSION_END_GEN and FM_SUPERVISION_HOST_SESSION_END_RECORD,
# and starts it again whenever it exits, while
# fm_supervision_host_session_end_owned holds: no Stop hook has claimed a later
# auto-arm generation, and the away record this hook entered still stands. The
# next session's first Stop and the captain's return (which archives that
# record) each end it; the keeper then stops its host, whose cleanup stops its
# watcher cycle. A host run shorter than
# FM_SUPERVISION_SESSION_END_RESTART_SECONDS (default 60) waits out the rest of
# that interval before the next start. The host's own output has no reader: every
# wake it hands back stays durable in the wake queue for the next drain.
# state/.supervision-session-end records the keeper's pid and identity while
# it runs.
set -u

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

MODE=hook
case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  keep)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    MODE=keep
    ;;
  *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
KEEPER_RECORD="$STATE/.supervision-session-end"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

if [ "$MODE" = keep ]; then
  GEN=$2
  RECORD=$3
  SESSION_PID=$4
  RESTART=${FM_SUPERVISION_SESSION_END_RESTART_SECONDS:-60}
  case "$RESTART" in ''|*[!0-9]*) RESTART=60 ;; esac
  HOST=
  owned() { fm_supervision_host_session_end_owned "$STATE" "$GEN" "$RECORD"; }
  # shellcheck disable=SC2329 # EXIT trap.
  cleanup() {
    if [ -n "$HOST" ] && fm_pid_alive "$HOST"; then
      kill -TERM "$HOST" 2>/dev/null || true
      wait "$HOST" 2>/dev/null || true
    fi
    [ "$(cut -f1 "$KEEPER_RECORD" 2>/dev/null)" != "$$" ] || rm -f "$KEEPER_RECORD"
  }
  trap cleanup EXIT
  trap 'exit 0' TERM INT
  identity=$(fm_pid_identity "$$") || exit 1
  tmp=$(mktemp "$KEEPER_RECORD.XXXXXX") || exit 1
  printf '%s\t%s\n' "$$" "$identity" > "$tmp" && mv -f "$tmp" "$KEEPER_RECORD" || exit 1
  i=0
  while [ "$i" -lt 30 ] && fm_pid_alive "$SESSION_PID"; do
    sleep 1
    i=$((i + 1))
  done
  while owned; do
    started=$SECONDS
    FM_SUPERVISION_HOST_PRIMARY=claude \
      FM_SUPERVISION_HOST_SESSION_END_GEN="$GEN" FM_SUPERVISION_HOST_SESSION_END_RECORD="$RECORD" \
      "$SCRIPT_DIR/fm-supervision-host.sh" park >/dev/null 2>&1 </dev/null &
    HOST=$!
    while fm_pid_alive "$HOST"; do
      owned || exit 0
      sleep 1
    done
    wait "$HOST" 2>/dev/null || true
    HOST=
    while owned && [ $((SECONDS - started)) -lt "$RESTART" ]; do
      sleep 1
    done
  done
  exit 0
fi

# Hook mode.
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
PAYLOAD=$(cat 2>/dev/null || true)
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
REASON=$(printf '%s' "$PAYLOAD" | jq -r '.reason // empty | strings' 2>/dev/null || true)
case "$REASON" in ''|clear|resume) exit 0 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ -e "$CONFIG/supervision-host-session-end" ] || exit 0
fm_supervision_host_config "$CONFIG" claude && [ -n "$FM_SUPERVISION_ENGINE" ] || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0
[ ! -e "$STATE/.afk" ] && ! fm_afk_contract_present "$STATE" || exit 0
fm_supervision_needed "$STATE" "${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}" || exit 0

SESSION_PID=$(sed -n '1p' "$STATE/.lock" 2>/dev/null)
FM_AFK_MODE=away "$SCRIPT_DIR/fm-afk-launch.sh" enter >/dev/null 2>&1 || exit 0
RECORD=$(fm_afk_contract_read_field "$(fm_afk_contract_path "$STATE")" confirmed_epoch 2>/dev/null)
[ -n "$RECORD" ] || exit 0
GEN=
! fm_autoarm_ledger_read "$STATE" || GEN=$FM_AUTOARM_GEN
set -m
nohup "$SCRIPT_DIR/fm-supervision-session-end.sh" keep "$GEN" "$RECORD" "$SESSION_PID" >/dev/null 2>&1 </dev/null &
set +m
exit 0

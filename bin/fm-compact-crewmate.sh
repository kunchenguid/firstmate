#!/usr/bin/env bash
# fm-compact-crewmate.sh — ON-DEMAND, one-call context compaction for a single
# crewmate, invokable by a secondmate (or the main firstmate).
#
# This is the watch daemon's fire-once cycle, run NOW against one crewmate instead
# of waiting for the threshold poll. It REUSES the exact cycle the daemon uses:
# fm_ctx_fire_once from fm-context-watch.sh (sourced below) — the same checkpoint ->
# wait-for-handoff -> /clear -> mark-cooldown implementation, no copy-paste fork. The
# rehydrate after /clear is driven by fm-captain-bootstrap.sh, which reads the
# resume-directive sentinel this command writes so the reset is deterministic.
#
# Resolution: the crewmate's tmux target comes from its ctx-<key>.json sentinel via
# fm_ctx_target_for (the same helper the daemon uses). <id> is the window key: a task
# id resolves to its fm-<id> window's sentinel key, or pass the sanitized key
# directly. With no live sentinel for <id>, the command refuses rather than guessing.
#
# Guards (mirror the daemon's collision/cooldown guards):
#   * refuses if no sentinel / no resolvable target for <id> (no such crewmate).
#   * refuses if a compact is already in flight for <id> (per-id mkdir lock).
#   * honors the existing cooldown: a window fired within FM_CTX_COOLDOWN is skipped
#     (idempotent — safe to call repeatedly).
#
# Usage:
#   fm-compact-crewmate.sh <id> [--resume frontier|restart]
#     <id>                 task id / window key of the crewmate to compact.
#     --resume frontier    (default) rehydrate tells the crewmate to resume its
#                          leave-off Frontier.
#     --resume restart     rehydrate tells the crewmate to RESTART the task from the
#                          compacted brief instead of resuming mid-frontier.
#
# Env: same knobs as fm-context-watch.sh (FM_HOME / FM_STATE_OVERRIDE scope the state
# dir, FM_CTX_COOLDOWN, FM_CTX_HANDOFF_TIMEOUT, FM_CTX_SEND_CMD for tests, ...).
set -u

FM_CC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the watch component: this brings in fm_ctx_fire_once and every resolution /
# cooldown helper WITHOUT running the daemon (its main loop is guarded by the
# BASH_SOURCE==0 check, which is false when we source it).
# shellcheck source=bin/fm-context-watch.sh
. "$FM_CC_DIR/fm-context-watch.sh"
# The mkdir-based lock helpers (fm_lock_try_acquire / fm_lock_release) the daemon
# uses for its singleton; sourced here for the per-id in-flight guard.
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$FM_CC_DIR/fm-wake-lib.sh"

_cc_die() { printf 'fm-compact-crewmate: %s\n' "$*" >&2; exit 1; }

# fm_cc_resume_dir: where the resume directive sentinel lives (one per window key).
# Read by fm-captain-bootstrap.sh's rehydrate path.
fm_cc_resume_path() { printf '%s/resume-%s.directive' "$1" "$2"; }  # <statedir> <key>

# fm_cc_compact: run the shared fire-once cycle for one window key, deterministically
# directing the post-/clear rehydrate. Returns fm_ctx_fire_once's status.
fm_cc_compact() {  # <statedir> <key> <resume_mode>
  local state=$1 key=$2 resume=$3 target
  target=$(fm_ctx_target_for "$state" "$key")
  [ -n "$target" ] || _cc_die "no live context sentinel/target for '$key' (state/ctx-$key.json) — is the crewmate running?"

  # In-flight guard: one compact per window key at a time (per-id mkdir lock; same
  # primitive as the daemon's singleton, just scoped to this key). Released explicitly
  # on every return path (a RETURN trap can't see the local under set -u at teardown).
  local lock="$state/.compact-$key.lock"
  if ! fm_lock_try_acquire "$lock"; then
    _cc_die "a compact is already in flight for '$key' (lock $lock held)"
  fi

  # Cooldown guard: honor the same suppression the daemon respects, so a repeat call
  # right after a fire is a safe no-op rather than a second disruptive cycle.
  if _ctx_in_cooldown "$state" "$key"; then
    printf 'fm-compact-crewmate: %s is in cooldown (fired within %ss) — skipping (idempotent)\n' \
      "$key" "${FM_CTX_COOLDOWN:-600}" >&2
    fm_lock_release "$lock" 2>/dev/null || true
    return 0
  fi

  # Write the resume directive BEFORE the cycle, so the rehydrate after /clear reads
  # the intended mode. An explicit frontier still writes it so the sentinel is
  # unambiguous; the rehydrate consumes it after one boot.
  local rp; rp=$(fm_cc_resume_path "$state" "$key")
  printf '%s\n' "$resume" > "$rp" 2>/dev/null || true

  printf 'fm-compact-crewmate: compacting %s (%s); resume=%s\n' "$key" "$target" "$resume" >&2
  local rc=0
  fm_ctx_fire_once "$state" "$key" || rc=$?
  fm_lock_release "$lock" 2>/dev/null || true
  return "$rc"
}

fm_cc_main() {
  local id="" resume="frontier"
  while [ $# -gt 0 ]; do
    case "$1" in
      --resume)
        shift; [ $# -gt 0 ] || _cc_die "--resume needs an argument (frontier|restart)"
        resume=$1 ;;
      --resume=*) resume=${1#--resume=} ;;
      -h|--help)
        sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
      --*) _cc_die "unknown flag: $1" ;;
      *) [ -z "$id" ] || _cc_die "unexpected extra argument: $1"; id=$1 ;;
    esac
    shift
  done
  [ -n "$id" ] || _cc_die "usage: fm-compact-crewmate.sh <id> [--resume frontier|restart]"
  case "$resume" in
    frontier|restart) ;;
    *) _cc_die "--resume must be 'frontier' or 'restart' (got: $resume)" ;;
  esac

  local state; state="$(_ctx_state_root)"
  [ -d "$state" ] || _cc_die "state dir not found: $state"
  # Resolve the window key the same way the watchdog filenames it.
  local key; key=$(fm_ctx_sanitize_key "$id")
  fm_cc_compact "$state" "$key" "$resume"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_cc_main "$@"
fi

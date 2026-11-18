#!/usr/bin/env bash
# fm-watchdog-beat.sh - the recurring watcher-beat watchdog tick (S5 away
# autonomy): a systemd user timer (firstmate-watchdog-beat.timer, rendered by
# bin/fm-boot-resume-install.sh, 5-minute cadence) runs this so a watcher that
# went silent after a reboot or crash is detected and recovered without captain
# action.
#
# Usage:
#   fm-watchdog-beat.sh            run one gated watchdog tick
#   fm-watchdog-beat.sh --check    print the verdicts, change nothing
#
# What counts as healthy is owned once by bin/fm-wake-lib.sh's
# fm_watcher_healthy (live pid + lock identity + beacon
# state/.last-watcher-beat fresh inside the stale bound); this script owns only
# the recovery ladder, and every rung is an existing safe path:
#   healthy            - nothing to do, exit 0 (no log line: a healthy tick is
#                        silent, the bounded log keeps only actions).
#   stale and the      - the primary harness is alive, so the verified arm
#   primary is alive     belongs to IT, not to a shell: one standing nudge
#                        prompt into the primary's pane (herdr agent prompt;
#                        resolved through the same exact recorded-conversation
#                        match as boot resume) plus one idempotent inbox note.
#                        The primary re-arms per watcher-continuity - its arm
#                        owns stalled-holder eviction - and a rejected prompt
#                        (agent busy) is not retried inside this tick.
#   stale and no       - run the guarded primary restore from
#   live primary         bin/fm-boot-resume-lib.sh; its SessionStart/Stop hook
#                        chain re-establishes the watcher with everything else.
# Every action spends from the shared bounded attempt ledger and parks after
# FM_BOOT_RESUME_ATTEMPT_MAX tries in the window with one final inbox note, so
# a dead agent can never turn a 5-minute timer into a prompt storm.
#
# Gates before anything: the kill switch (config/boot-resume-off) and the
# unattended posture (away record or active goal). An attended home never
# nudges anything.
#
# Exit status: 0 healthy, skipped, nudged, or parked (a timer tick must never
# wedge), 2 invalid use.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_BTR_LIB_DIR="$SCRIPT_DIR"
export FM_HOME

# shellcheck source=bin/fm-boot-resume-lib.sh
. "$SCRIPT_DIR/fm-boot-resume-lib.sh"

FM_WATCHDOG_BEAT_STALE_SECS=${FM_WATCHDOG_BEAT_STALE_SECS:-600}
# The watcher script path fm_watcher_healthy proves identity against.
FM_WATCHDOG_BEAT_WATCH="$SCRIPT_DIR/fm-watch.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

fm_watchdog_beat_healthy() {
  fm_watcher_healthy "$FM_BTR_STATE" "$FM_WATCHDOG_BEAT_WATCH" \
    "$FM_WATCHDOG_BEAT_STALE_SECS" "$FM_HOME"
}

# The nudge ladder: budget -> pane -> prompt + durable note. The prompt names
# the skills that own the fix; it never restates their procedure.
fm_watchdog_beat_nudge() {
  local session pane budget_rc
  fm_btr_budget watchdog-nudge; budget_rc=$?
  case "$budget_rc" in
    0) ;;
    1) fm_btr_log "watchdog: skipped - nudge parked this window"; return 1 ;;
    2)
      fm_btr_park watchdog-nudge "watcher stayed silent; primary nudges exhausted"
      return 1
      ;;
  esac
  if ! fm_btr_primary_pane; then
    fm_btr_attempt_ledger watchdog-nudge fail
    fm_btr_log "watchdog: FAILED - primary pane unresolved: $FM_BTR_PRIMARY_WHY"
    return 1
  fi
  session=$FM_BTR_PRIMARY_SESSION
  pane=$FM_BTR_PRIMARY_PANE
  if fm_btr_herdr --session "$session" agent prompt "$pane" \
      "watchdog: the watcher beacon has been silent for over ${FM_WATCHDOG_BEAT_STALE_SECS}s while supervision stands. Re-arm the watcher per watcher-continuity (your Stop-hook auto-arm or a verified fm-watch-arm.sh background arm; its own rules evict a stalled holder). Never discard unlanded work." \
      >/dev/null 2>&1; then
    fm_btr_attempt_ledger watchdog-nudge relaunched
    fm_btr_log "watchdog: watcher silent; nudged primary in $session:$pane"
  else
    fm_btr_attempt_ledger watchdog-nudge fail
    fm_btr_log "watchdog: watcher silent; nudge rejected by $session:$pane (agent busy will be re-nudged next tick)"
  fi
  fm_btr_inbox_note "watchdog-beat-$(fm_btr_boot_id)-$(date +%Y%m%d%H%M)" \
    "watchdog: the watcher beacon was silent past ${FM_WATCHDOG_BEAT_STALE_SECS}s; the primary pane was nudged to re-arm per watcher-continuity."
  return 0
}

main() {
  case "${1:-}" in
    '') ;;
    -h|--help) usage; exit 0 ;;
    --check)
      if fm_watchdog_beat_healthy; then
        echo "watcher: healthy (pid ${FM_WATCHER_HEALTHY_PID:-unknown}, beacon fresh)"
      else
        echo "watcher: NOT healthy"
      fi
      echo "lock: $(fm_btr_lock_state)"
      echo "budget primary: $(fm_btr_attempts_recent primary)/$FM_BTR_ATTEMPT_MAX attempts; budget nudge: $(fm_btr_attempts_recent watchdog-nudge)/$FM_BTR_ATTEMPT_MAX"
      exit 0
      ;;
    *)
      echo "error: unexpected argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac

  fm_btr_kill_switch_engaged && exit 0
  fm_btr_posture_active || exit 0
  fm_watchdog_beat_healthy && exit 0

  if [ "$(fm_btr_lock_state)" = held ]; then
    fm_btr_log "watchdog: watcher silent while primary live (pid ${FM_LOCK_INSPECT_PID:-unknown})"
    fm_watchdog_beat_nudge || true
  else
    fm_btr_log "watchdog: watcher silent and no live primary; restoring"
    if ! fm_btr_restore_primary; then
      fm_btr_secondmate_sweep || true
    fi
  fi
  exit 0
}

main "$@"

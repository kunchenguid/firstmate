#!/usr/bin/env bash
# fm-boot-resume.sh - the boot-time entry point of firstmate's boot resume
# (S5 away autonomy): after a WSL restart or crash, bring the primary firstmate
# session, the secondmates, and recorded workers back without captain action.
#
# Run by the systemd user unit bin/fm-boot-resume-install.sh renders
# (firstmate-boot-resume.service, WantedBy=default.target, soft-ordered after
# the herdr bucket unit), or by hand for a rehearsal:
#   fm-boot-resume.sh            run the gated boot resume
#   fm-boot-resume.sh --check    print the gate verdicts and the resolved
#                                primary pane, change nothing
#
# The decision surface (gates, primary restore, secondmate fallback, attempt
# ledger) is owned once by bin/fm-boot-resume-lib.sh; this script owns only the
# boot sequencing:
#   1. kill switch / posture gates (typed skip line, exit 0 - a present
#      captain or a switched-off home is a clean no-op, never a failure),
#   2. per-boot idempotence (state/.boot-resume-boot holds this boot id),
#   3. bounded herdr readiness, then the guarded primary restore: herdr's
#      reboot restore leaves the primary's pane behind as a shell, and the
#      restore starts the same conversation (claude --resume of the recorded
#      state/.lock-session id) in exactly that pane, then submits one standing
#      recovery prompt. The primary's own SessionStart hook has already run
#      session start (locked secondmate-liveness sweep included) and its Stop
#      hook re-arms the watcher chain,
#   4. secondmate fallback sweep only when the primary restore failed, so the
#      mates never wait on one broken conversation,
#   5. one durable inbox note when anything needed the fallback or failed, so
#      the captain and the next drain both see it.
#
# Never discards unlanded work, never forces an endpoint, administers no shared
# infrastructure: it only drives this home's existing safe paths
# (fm-session-start via the hook chain, the shared secondmate recovery
# contract, and - through the recovery prompt - the agent-owned
# stuck-crewmate-recovery/fm-control relaunch decisions).
#
# Exit status: 0 resumed, skipped, or parked (the watchdog timer owns
# retries; a boot unit must not wedge default.target); 1 the primary restore
# failed (typed line, sweep attempted, inbox noted); 2 invalid use.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_BTR_LIB_DIR="$SCRIPT_DIR"
export FM_HOME

# shellcheck source=bin/fm-boot-resume-lib.sh
. "$SCRIPT_DIR/fm-boot-resume-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

# Newest typed line from the bounded log, for the inbox note below; the log
# is append-only here, so this read can never race a writer from this process.
fm_btr_log_line_newest() {
  tail -n 1 "$FM_BTR_LOG" 2>/dev/null || printf 'see %s' "$FM_BTR_LOG"
}

main() {
  local rc=0
  case "${1:-}" in
    '') ;;
    -h|--help) usage; exit 0 ;;
    --check)
      fm_btr_kill_switch_engaged && echo "kill-switch: engaged (config/boot-resume-off)" \
        || echo "kill-switch: off"
      if fm_btr_posture_active; then
        if fm_btr_posture_away; then echo "posture: away record stands"; else echo "posture: active goal"; fi
      else
        echo "posture: attended (no away record, no active goal) - nothing to resume"
      fi
      echo "lock: $(fm_btr_lock_state)"
      echo "boot: $(fm_btr_boot_id)$(fm_btr_boot_handled && printf ' (already handled)')"
      if fm_btr_primary_pane; then
        echo "primary pane: $FM_BTR_PRIMARY_SESSION:$FM_BTR_PRIMARY_PANE"
      else
        echo "primary pane: unresolved - $FM_BTR_PRIMARY_WHY"
      fi
      exit 0
      ;;
    *)
      echo "error: unexpected argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac

  if fm_btr_kill_switch_engaged; then
    fm_btr_log "boot: skipped - kill switch config/boot-resume-off"
    exit 0
  fi
  if ! fm_btr_posture_active; then
    fm_btr_log "boot: skipped - captain present (no away record, no active goal)"
    exit 0
  fi
  if fm_btr_boot_handled; then
    fm_btr_log "boot: skipped - already resumed this boot"
    exit 0
  fi
  fm_btr_mark_boot_handled

  if fm_btr_restore_primary; then
    exit 0
  fi
  rc=$?
  fm_btr_secondmate_sweep
  fm_btr_inbox_note "boot-resume-$(fm_btr_boot_id)" \
    "boot-resume: the primary could not be restored this boot ($(fm_btr_log_line_newest)); the guarded secondmate fallback sweep ran. Recover the primary per docs/boot-resume.md; the watcher-beat watchdog keeps retrying."
  exit "$rc"
}

main "$@"

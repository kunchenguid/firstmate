#!/usr/bin/env bash
# Count ordinary task workers still able to spend in this home.
# Usage: fm-afk-spend-count.sh <state-dir>
# This is an admission snapshot shared with return reporting, not token metering.
# Live lifecycle locks and unresolved launch cleanup reserve spending capacity.
# Unreadable, ambiguous and unverified endpoint state counts conservatively.
# Orca, Zellij and cmux have no recovery-grade death classifier, so a failed
# presence probe cannot exclude their recorded endpoints. Raw tmux absence is
# also unproven: fm_control_endpoint_absence_verdict owns that proof boundary.
# Current-turn busy activity overrides a done delivery, even with an unchanged
# HEAD and a completed attributed no-mistakes run. Otherwise a ship's done
# status is excluded only for a mode-specific terminal delivery accepted by the
# DoD predicate and fm-crew-state.sh's current-state and named-head gates;
# a no-mistakes pre-validation implementation handoff remains counted.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
. "$SCRIPT_DIR/fm-busy-lib.sh"
. "$SCRIPT_DIR/fm-control-lib.sh"

STATE=${1:-}
[ -d "$STATE" ] || { echo "usage: fm-afk-spend-count.sh <state-dir>" >&2; exit 2; }
# shellcheck source=bin/fm-wake-lib.sh
FM_STATE_OVERRIDE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh"

live=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
  meta_lock=$(fm_meta_lock_path "$meta") || exit 1
  if fm_pid_alive "$(cat "$meta_lock/pid" 2>/dev/null)"; then
    live=$((live + 1))
    continue
  fi
  id=${meta##*/}
  id=${id%.meta}
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || continue
  endpoint_state=$(fm_backend_worker_state "$backend" "$target" 2>/dev/null) || endpoint_state=unreadable
  if [ "$endpoint_state" = missing ]; then
    if [ "$backend" = herdr ]; then
      fm_backend_source "$backend" && fm_backend_herdr_endpoint_confirmed_gone "$target" \
        || endpoint_state=unreadable
    else
      absence=$(fm_control_endpoint_absence_verdict "$backend" "$target")
      [ "${absence%%$'\t'*}" = gone ] || endpoint_state=unreadable
    fi
  fi
  if [ "$(fm_meta_get "$meta" cleanup_recovery)" = launch ] && [ "$endpoint_state" != missing ]; then
    live=$((live + 1))
    continue
  fi
  case "$endpoint_state" in dead|missing) continue ;; esac

  status="$STATE/$id.status"
  kind=$(fm_meta_get "$meta" kind)
  line=$(status_current_line "$status" "$kind")
  if [ "$(status_line_verb "$line")" = "done" ] && {
    [ "$kind" != ship ] || fm_dod_should_gate_ship_done "$kind" "$(fm_meta_get "$meta" mode)" "$line"
  }; then
    activity=$(fm_busy_classify_meta "$meta" "$id" "$STATE" 2>/dev/null) || activity=unknown
    if [ "${activity%% *}" = busy ]; then
      live=$((live + 1))
      continue
    fi
    current=$(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || current=
    case "$current" in "state: done "*) continue ;; esac
  fi
  live=$((live + 1))
done
printf '%s\n' "$live"

#!/usr/bin/env bash
# Count ordinary task workers still able to spend in this home.
# Usage: fm-afk-spend-count.sh <state-dir>
# This is an admission snapshot shared with return reporting, not token metering.
# Live lifecycle locks and unresolved launch cleanup reserve spending capacity.
# Unreadable, ambiguous, unverified and timed-out reads count conservatively.
# Backend presence, activity and current-state calls each have a 5s budget.
# Orca, Zellij and cmux have no recovery-grade death classifier, so a failed
# presence probe cannot exclude their recorded endpoints. Raw tmux absence is
# also unproven: fm_control_endpoint_absence_verdict owns that proof boundary.
# Excluding a live done or waiting worker requires proven idle activity;
# busy, unknown or unreadable activity keeps it counted.
# Idle paused, captain-held and needs-decision workers also pass
# fm-crew-state.sh's current-state gate, so a worker paused while its validation
# run executes still reserves capacity.
# A newer non-wait event prevents exclusion despite an older open decision.
# Idle uses fm-busy-lib.sh's trusted sources: Grok's rendered-tail fallback
# infers idle from a missing cancel footer and is weaker than semantic hooks.
# A done delivery additionally requires acceptance by the DoD predicate and
# fm-crew-state.sh's current-state and named-head gates;
# a no-mistakes pre-validation implementation handoff remains counted.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

STATE=${1:-}
[ -d "$STATE" ] || { echo "usage: fm-afk-spend-count.sh <state-dir>" >&2; exit 2; }
# shellcheck source=bin/fm-wake-lib.sh
FM_STATE_OVERRIDE="$STATE" . "$SCRIPT_DIR/fm-wake-lib.sh"
paused_verb=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
held_verb=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
resolve_verb=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}

# Return the newest event preceding any trailing resolutions, using the
# classifier's event boundary so continuation text cannot mask activity.
spend_latest_non_resolved_verb() {
  local line verb i=0 legacy_re
  local -a lines=()
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  while IFS= read -r line || [ -n "$line" ]; do
    lines[i]=$line
    i=$((i + 1))
  done
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    line=${lines[i]}
    _fm_status_line_is_event "$line" "$legacy_re" || continue
    status_line_verb "$line" verb
    [ "$verb" != "$resolve_verb" ] || continue
    printf '%s\n' "$verb"
    return 0
  done
  return 1
}

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
  # Child-shell arguments expand there; bound all nested CLI reads together.
  # shellcheck disable=SC2016
  endpoint_state=$(fm_run_timed 5 bash -c '. "$1"; fm_backend_worker_state "$2" "$3"' \
    _ "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" 2>/dev/null) || endpoint_state=unreadable
  if [ "$endpoint_state" = missing ]; then
    if [ "$backend" = herdr ]; then
      # shellcheck disable=SC2016
      fm_run_timed 5 bash -c '. "$1"; fm_backend_source herdr && fm_backend_herdr_endpoint_confirmed_gone "$2"' \
        _ "$SCRIPT_DIR/fm-backend.sh" "$target" \
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
  case "$endpoint_state" in
    dead|missing) continue ;;
    alive|ambiguous) ;;
    *) live=$((live + 1)); continue ;;
  esac

  status="$STATE/$id.status"
  kind=$(fm_meta_get "$meta" kind)
  line=$(status_current_line "$status" "$kind")
  verb=$(status_line_verb "$line")
  case "$verb" in
    "$paused_verb"|"$held_verb"|needs-decision)
      newest_verb=$(tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$status" 2>/dev/null \
        | spend_latest_non_resolved_verb) \
        || newest_verb=$(spend_latest_non_resolved_verb < "$status") || newest_verb=
      case "$newest_verb" in
        "$paused_verb"|"$held_verb"|needs-decision) ;;
        *) live=$((live + 1)); continue ;;
      esac
      ;;
    done)
      if [ "$kind" = ship ] && ! fm_dod_should_gate_ship_done "$kind" "$(fm_meta_get "$meta" mode)" "$line"; then
        live=$((live + 1))
        continue
      fi
      ;;
    *) live=$((live + 1)); continue ;;
  esac
  # shellcheck disable=SC2016
  activity=$(fm_run_timed 5 bash -c '. "$1/fm-backend.sh"; . "$1/fm-busy-lib.sh"; fm_busy_classify_meta "$2" "$3" "$4"' \
    _ "$SCRIPT_DIR" "$meta" "$id" "$STATE" 2>/dev/null) || activity=unknown
  if [ "${activity%% *}" != idle ]; then
    live=$((live + 1))
    continue
  fi
  current=$(fm_run_timed 5 env FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
    "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || current=
  case "$verb:$current" in
    done:"state: done "*) continue ;;
    "$paused_verb":"state: paused "*|"$paused_verb":"state: parked "*) continue ;;
    needs-decision:"state: parked "*|"$held_verb":"state: parked "*) continue ;;
    # Bare held declarations have no mapped state; accept only this exact
    # idle fallback, not a missing worktree or another unavailable source.
    "$held_verb":"state: unknown · source: none · no current-state source available") continue ;;
  esac
  live=$((live + 1))
done
printf '%s\n' "$live"

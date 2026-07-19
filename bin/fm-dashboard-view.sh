#!/usr/bin/env bash
# Render one read-only FirstMate dashboard pane.
# Usage: fm-dashboard-view.sh <coordinator|roster|details> [--target SESSION] [--snapshot FILE]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}
[ -n "$MODE" ] || { echo "error: pane mode is required" >&2; exit 2; }
shift || true
TARGET=
SNAPSHOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET=${2:?missing target}; shift 2 ;;
    --snapshot) SNAPSHOT=${2:?missing snapshot}; shift 2 ;;
    -h|--help)
      sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done

fit() {  # <text> <width>
  local text=$1 width=$2
  if [ "${#text}" -le "$width" ]; then printf '%s' "$text"
  elif [ "$width" -gt 1 ]; then printf '%s…' "${text:0:$((width - 1))}"
  fi
}

age_label() {
  local seconds=${1:-}
  case "$seconds" in ''|null|*[!0-9]*) printf 'n/a'; return ;; esac
  if [ "$seconds" -lt 60 ]; then printf '%ss' "$seconds"
  elif [ "$seconds" -lt 3600 ]; then printf '%sm' "$((seconds / 60))"
  elif [ "$seconds" -lt 86400 ]; then printf '%sh' "$((seconds / 3600))"
  else printf '%sd' "$((seconds / 86400))"; fi
}

snapshot_json() {
  if [ -n "$SNAPSHOT" ]; then cat "$SNAPSHOT"
  else "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json
  fi
}

render_coordinator() {
  [ -n "$TARGET" ] || { echo "FirstMate coordinator: target unavailable"; return; }
  printf 'FIRSTMATE · %s · read-only capture\n' "$TARGET"
  printf 'Detach: Ctrl-b d\n\n'
  if ! tmux has-session -t "$TARGET" 2>/dev/null; then
    printf 'Target session is unavailable. The dashboard does not wake it.\n'
    return
  fi
  tmux capture-pane -p -t "$TARGET" -S -200 2>/dev/null || printf 'Coordinator pane is unavailable.\n'
}

render_roster() {
  local json cols id role profile state age line
  json=$(snapshot_json) || { echo "ROSTER · snapshot source unavailable"; return 1; }
  cols=$(tput cols 2>/dev/null || printf 100)
  printf 'ROSTER · workers=%s · snapshot=%s\n' \
    "$(printf '%s' "$json" | jq '.tasks | length')" \
    "$(printf '%s' "$json" | jq -r '.generated // "n/d"')"
  printf '%-22s %-13s %-25s %-12s %s\n' ID ROLE MODEL STATE AGE
  printf '%s\n' '────────────────────────────────────────────────────────────────────────────'
  while IFS=$'\t' read -r id role profile state age; do
    line=$(printf '%-22s %-13s %-25s %-12s %s' \
      "$(fit "$id" 22)" "$(fit "$role" 13)" "$(fit "$profile" 25)" "$(fit "$state" 12)" "$(age_label "$age")")
    fit "$line" "$cols"
    printf '\n'
  done < <(printf '%s' "$json" | jq -r '.tasks[]? | [.id,.role,(.harness+"/"+.model+"/"+.effort),.current_state.state,(.activity.age_seconds // "null")] | @tsv')
  if [ "$(printf '%s' "$json" | jq '.tasks | length')" -eq 0 ]; then
    printf 'No active or recorded workers.\n'
  fi
  printf '\nSources: state/meta + current-state; no model polling.\n'
}

render_details() {
  local json active
  json=$(snapshot_json) || { echo "DETAILS · snapshot source unavailable"; return 1; }
  active=$(printf '%s' "$json" | jq '[.tasks[]? | select(.current_state.state != "done" and .current_state.state != "failed")] | length')
  printf 'DETAILS · active/waiting=%s\n' "$active"
  printf 'Session/work order: %s\n' "${TARGET:-unavailable}"
  if [ "$active" -eq 0 ]; then
    printf 'No active worker. Last terminal result: '
    printf '%s\n' "$(printf '%s' "$json" | jq -r '[.tasks[]? | select(.current_state.state == "done" or .current_state.state == "failed")][0].current_state.state // "unavailable"')"
  else
    printf '%s' "$json" | jq -r '
      [.tasks[]? | select(.current_state.state != "done" and .current_state.state != "failed")][0]
      | "ID: \(.id)\nRole: \(.role)\nProfile: \(.harness)/\(.model)/\(.effort)\nState: \(.current_state.state) · source=\(.current_state.source)\nRepo: \(.git.repo // .project // "unavailable")\nBranch: \(.git.branch // "unavailable")\nWorktree: \(.paths.worktree.path // "unavailable")\nHeartbeat/change: \(.activity.age_seconds // "n/a") s · source=\(.activity.source)\nGate: \(if .hints.pending_decision then "decision-needed" elif .hints.blocked_event then "blocked" else "none" end)\nLast event: \(.hints.last_event_text // "unavailable")"
    '
  fi
  printf '\nWork-order scope: unavailable in current telemetry\n'
  printf '\nPhase/wave: unavailable in current telemetry\n'
  printf 'Tools/safe events: unavailable in current telemetry\n'
  printf 'Source state: snapshot=%s\n' "$(printf '%s' "$json" | jq -r '.schema // "unavailable"')"
}

case "$MODE" in
  coordinator) render_coordinator ;;
  roster) render_roster ;;
  details) render_details ;;
  *) echo "error: mode must be coordinator, roster, or details" >&2; exit 2 ;;
esac

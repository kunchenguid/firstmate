#!/usr/bin/env bash
# fm-codex-effort.sh - switch one idle Codex crewmate's reasoning effort in place.
#
# Usage:
#   FM_HOME=/absolute/firstmate/home bin/fm-codex-effort.sh <task-id> <effort>
#
# Supported efforts are low, medium, high, and xhigh.
# The task must be an idle Codex TUI recorded on Herdr or tmux.
# Herdr is the preferred production path and receives the verified literal
# Alt+, or Alt+. byte chord through pane send-text.
# Tmux receives the same public Codex keybinding through tmux's M-, or M-.
# The installed Codex 0.146.0 exposes these bindings as Chat Decrease Reasoning
# and Chat Increase Reasoning in /keymap.
#
# This operation fails closed unless task identity, harness, backend endpoint,
# live agent, worktree, empty composer, and the current model/effort footer all
# agree before input.
# It verifies every one-level transition from the rendered Codex footer and
# revalidates the unchanged endpoint before atomically replacing effort= in
# state/<id>.meta.
# It never submits a turn, changes the model, exits or resumes Codex, changes
# the worktree, or rewrites task ownership.
# A swallowed chord, changed UI, busy turn, ambiguous state, or missing footer
# leaves metadata unchanged and reports refusal.
set -u

ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FM_HOME=${FM_HOME:-}

usage() {
  cat <<'USAGE'
Usage: FM_HOME=/absolute/firstmate/home bin/fm-codex-effort.sh <task-id> <low|medium|high|xhigh>

Switch an idle Codex crewmate's reasoning effort without ending its session.
Only verified Herdr and tmux task endpoints are supported.
USAGE
}

refuse() {
  echo "REFUSED: $*" >&2
  exit 1
}

if [ "$#" -eq 1 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac
fi
[ "$#" -eq 2 ] || { usage >&2; exit 2; }
task_id=$1
requested_effort=$2

case "$task_id" in
  ''|*[!A-Za-z0-9._-]*) refuse "invalid task id." ;;
esac
case "$requested_effort" in
  low|medium|high|xhigh) ;;
  *) refuse "unsupported Codex effort '$requested_effort'; expected low, medium, high, or xhigh." ;;
esac
case "$FM_HOME" in
  /*) ;;
  *) refuse "FM_HOME must be an explicit absolute firstmate home." ;;
esac

STATE="$FM_HOME/state"
meta="$STATE/$task_id.meta"
[ -d "$STATE" ] || refuse "state directory does not exist at $STATE."
[ -f "$meta" ] && [ ! -L "$meta" ] || refuse "task $task_id has no regular metadata at $meta."

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

control_lock="$STATE/.control-$task_id.lock"
meta_lock=$(fm_meta_lock_path "$meta") \
  || refuse "could not resolve the metadata lock for task $task_id."
if ! fm_lock_try_acquire "$control_lock"; then
  refuse "another lifecycle action is already running for task $task_id."
fi
control_lock_held=1
if ! fm_lock_try_acquire "$meta_lock"; then
  fm_lock_release "$control_lock"
  control_lock_held=0
  refuse "another metadata update is already running for task $task_id."
fi
meta_lock_held=1
tmp_meta=
cleanup() {
  [ -z "$tmp_meta" ] || rm -f -- "$tmp_meta" 2>/dev/null || true
  if [ "$meta_lock_held" = 1 ]; then
    fm_lock_release "$meta_lock"
    meta_lock_held=0
  fi
  if [ "$control_lock_held" = 1 ]; then
    fm_lock_release "$control_lock"
    control_lock_held=0
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fm_backend_validate_task_endpoint "$meta" "$task_id" || exit 1
backend=$FM_BACKEND_VALIDATED_BACKEND
target=$FM_BACKEND_VALIDATED_TARGET
case "$backend" in
  herdr|tmux) ;;
  *) refuse "backend '$backend' has no verified in-session Codex effort-switch path." ;;
esac

harness=$(fm_backend_meta_exact_value "$meta" harness) \
  || refuse "task $task_id has a missing or ambiguous harness."
[ "$harness" = codex ] || refuse "task $task_id uses harness '$harness', not Codex."
model=$(fm_backend_meta_exact_value "$meta" model) \
  || refuse "task $task_id has a missing or ambiguous model."
recorded_effort=$(fm_backend_meta_exact_value "$meta" effort) \
  || refuse "task $task_id has a missing or ambiguous effort."
case "$recorded_effort" in
  low|medium|high|xhigh) ;;
  *) refuse "task $task_id records unsupported effort '$recorded_effort'." ;;
esac
worktree=$(fm_backend_meta_exact_value "$meta" worktree) \
  || refuse "task $task_id has a missing or ambiguous worktree."
meta_fingerprint=$(cksum < "$meta") || refuse "could not fingerprint task metadata."

fm_backend_source "$backend" || refuse "could not load backend '$backend'."

current_path() {
  case "$backend" in
    herdr) fm_backend_herdr_current_path "$target" ;;
    tmux) fm_backend_tmux_current_path "$target" ;;
  esac
}

capture_tail() {
  fm_backend_capture "$backend" "$target" 40 2>/dev/null | tail -n 20
}

footer_effort() {
  local cap line effort found=
  cap=$(capture_tail) || return 1
  while IFS= read -r line; do
    case "$line" in
      *"$model low ·"*) effort=low ;;
      *"$model medium ·"*) effort=medium ;;
      *"$model high ·"*) effort=high ;;
      *"$model xhigh ·"*) effort=xhigh ;;
      *) continue ;;
    esac
    found=$effort
  done <<EOF
$cap
EOF
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

endpoint_is_safe_idle() {
  local agent path composer busy cap live_effort
  agent=$(fm_backend_agent_state "$backend" "$target")
  [ "$agent" = alive ] || refuse "task $task_id endpoint state is '$agent', not a verified live Codex agent."
  path=$(current_path)
  [ "$path" = "$worktree" ] || refuse "task $task_id live worktree does not match its recorded worktree."
  if [ "$backend" = herdr ]; then
    busy=$(fm_backend_busy_state "$backend" "$target")
    [ "$busy" = idle ] || refuse "task $task_id native agent state is '$busy', not idle."
  fi
  cap=$(capture_tail) || refuse "task $task_id UI could not be read."
  if printf '%s\n' "$cap" | grep -qi 'esc to interrupt'; then
    refuse "task $task_id has a busy Codex turn."
  fi
  composer=$(fm_backend_composer_state "$backend" "$target")
  [ "$composer" = empty ] || refuse "task $task_id composer state is '$composer', not verified empty."
  live_effort=$(footer_effort) || refuse "task $task_id has no verifiable Codex model/effort footer."
  printf '%s' "$live_effort"
}

live_effort=$(endpoint_is_safe_idle) || exit 1
[ "$live_effort" = "$recorded_effort" ] \
  || refuse "task $task_id live effort '$live_effort' disagrees with recorded effort '$recorded_effort'."

rank_of() {
  case "$1" in
    low) printf 1 ;;
    medium) printf 2 ;;
    high) printf 3 ;;
    xhigh) printf 4 ;;
  esac
}

send_effort_step() {  # <up|down>
  local direction=$1
  case "$backend:$direction" in
    herdr:up) fm_backend_herdr_send_literal "$target" "$(printf '\033.')" ;;
    herdr:down) fm_backend_herdr_send_literal "$target" "$(printf '\033,')" ;;
    tmux:up) fm_backend_tmux_send_key "$target" M-. ;;
    tmux:down) fm_backend_tmux_send_key "$target" M-, ;;
    *) return 1 ;;
  esac
}

next_effort() {  # <effort> <up|down>
  case "$1:$2" in
    low:up) printf medium ;;
    medium:up) printf high ;;
    high:up) printf xhigh ;;
    xhigh:down) printf high ;;
    high:down) printf medium ;;
    medium:down) printf low ;;
    *) return 1 ;;
  esac
}

current_rank=$(rank_of "$live_effort")
requested_rank=$(rank_of "$requested_effort")
while [ "$current_rank" -ne "$requested_rank" ]; do
  if [ "$current_rank" -lt "$requested_rank" ]; then direction=up
  else direction=down
  fi
  expected=$(next_effort "$live_effort" "$direction") \
    || refuse "cannot move from effort '$live_effort' toward '$requested_effort'."
  [ "$(cksum < "$meta")" = "$meta_fingerprint" ] \
    || refuse "task $task_id metadata changed before the live effort switch completed."
  send_effort_step "$direction" \
    || refuse "backend '$backend' could not deliver the Codex reasoning keybinding."
  confirmed=
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    sleep 0.05
    confirmed=$(footer_effort 2>/dev/null || true)
    [ "$confirmed" = "$expected" ] && break
    attempt=$((attempt + 1))
  done
  [ "$confirmed" = "$expected" ] \
    || refuse "Codex did not confirm expected effort '$expected' after input; metadata is unchanged."
  live_effort=$confirmed
  current_rank=$(rank_of "$live_effort")
done

final_effort=$(endpoint_is_safe_idle) || exit 1
[ "$final_effort" = "$requested_effort" ] \
  || refuse "final Codex footer did not confirm effort '$requested_effort'."
[ "$(cksum < "$meta")" = "$meta_fingerprint" ] \
  || refuse "task $task_id metadata changed before confirmation; live effort changed but metadata was preserved."
fm_backend_validate_task_endpoint "$meta" "$task_id" >/dev/null \
  || refuse "task $task_id endpoint identity changed before metadata update."
[ "$FM_BACKEND_VALIDATED_BACKEND" = "$backend" ] \
  && [ "$FM_BACKEND_VALIDATED_TARGET" = "$target" ] \
  || refuse "task $task_id endpoint changed before metadata update."

tmp_meta=$(mktemp "$STATE/.$task_id.meta.XXXXXX") \
  || refuse "could not create a metadata update beside $meta."
awk -v effort="$requested_effort" '
  /^effort=/ { print "effort=" effort; next }
  { print }
' "$meta" > "$tmp_meta" || refuse "could not prepare metadata update."
if mode=$(stat -c %a "$meta" 2>/dev/null); then :
elif mode=$(stat -f %Lp "$meta" 2>/dev/null); then :
else mode=600
fi
chmod "$mode" "$tmp_meta" || refuse "could not preserve metadata permissions."
mv -f -- "$tmp_meta" "$meta" || refuse "could not atomically record the confirmed effort."
tmp_meta=

printf '%s: %s %s (%s, session preserved)\n' "$task_id" "$model" "$requested_effort" "$backend"

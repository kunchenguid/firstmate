#!/usr/bin/env bash
# fm-codex-effort.sh - switch one idle Codex crewmate's reasoning effort in place.
#
# Usage:
#   FM_HOME=/absolute/firstmate/home bin/fm-codex-effort.sh <task-id> <effort>
#
# Supported efforts are low, medium, high, and xhigh.
# The task must be an idle Codex TUI recorded on Herdr.
# Herdr is the preferred production path and receives the verified literal
# Alt+, or Alt+. byte chord through pane send-text.
# Codex 0.146.0 exposes these bindings as Chat Decrease Reasoning and Chat
# Increase Reasoning in /keymap.
# Codex 0.147.0 renders the verified footer with an optional home-abbreviated
# worktree and a trailing Context percentage.
#
# This operation fails closed unless task identity, harness, backend endpoint,
# live agent, worktree, empty composer, and the current model/effort footer all
# agree before input.
# Its per-task endpoint input lock serializes every chord with ordinary steering and repeats the semantic idle and empty-composer checks before every chord.
# It verifies every one-level transition from the rendered Codex footer and
# revalidates the unchanged endpoint before atomically replacing effort= in
# state/<id>.meta.
# Before its first chord it writes a durable recovery record, so a delivered
# chord followed by interruption, a UI failure, or metadata-write failure is
# reconciled from the next verified live footer before any further input.
# It never submits a turn, changes the model, exits or resumes Codex, changes
# the worktree, or rewrites task ownership.
# A swallowed chord, changed UI, busy turn, ambiguous state, or missing footer
# leaves metadata unchanged and reports refusal with any recovery record intact.
set -u

ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FM_HOME=${FM_HOME:-}

usage() {
  cat <<'USAGE'
Usage: FM_HOME=/absolute/firstmate/home bin/fm-codex-effort.sh <task-id> <low|medium|high|xhigh>

Switch an idle Codex crewmate's reasoning effort without ending its session.
Only the verified Herdr task endpoint is currently supported.
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

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

fm_task_id_creation_valid "$task_id" || refuse "invalid task id."
[ -f "$meta" ] && [ ! -L "$meta" ] || refuse "task $task_id has no regular metadata at $meta."

control_lock="$STATE/.control-$task_id.lock"
meta_lock=$(fm_meta_lock_path "$meta") \
  || refuse "could not resolve the metadata lock for task $task_id."
input_lock=$(fm_task_input_lock_path "$STATE" "$task_id") \
  || refuse "could not resolve the endpoint input lock for task $task_id."
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
input_lock_held=0
tmp_meta=
tmp_recovery=
recovery="$STATE/$task_id.codex-effort-recovery"
cleanup() {
  [ -z "$tmp_meta" ] || rm -f -- "$tmp_meta" 2>/dev/null || true
  [ -z "$tmp_recovery" ] || rm -f -- "$tmp_recovery" 2>/dev/null || true
  if [ "$meta_lock_held" = 1 ]; then
    fm_lock_release "$meta_lock"
    meta_lock_held=0
  fi
  if [ "$input_lock_held" = 1 ]; then
    fm_lock_release "$input_lock"
    input_lock_held=0
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
  herdr) ;;
  tmux) refuse "task $task_id has no verified semantic Codex idle source on tmux." ;;
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

fm_lock_acquire_wait "$input_lock" \
  || refuse "could not acquire the endpoint input lock for task $task_id."
input_lock_held=1

current_path() {
  fm_backend_herdr_current_path "$target"
}

capture_tail() {
  fm_backend_capture "$backend" "$target" 40 2>/dev/null | tail -n 20
}

footer_effort_from_capture() {  # <captured-screen>
  local cap=$1 line footer='' effort displayed_worktree
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] && footer=$line
  done <<EOF
$cap
EOF
  for effort in low medium high xhigh; do
    displayed_worktree=$worktree
    case "$footer" in
      "$model $effort · $displayed_worktree"|"$model $effort · $displayed_worktree · Context "[0-9]*'% use…')
        printf '%s' "$effort"
        return 0
        ;;
    esac
    if [ -n "${HOME:-}" ] && [ "${worktree#"$HOME"/}" != "$worktree" ]; then
      displayed_worktree="~${worktree#"$HOME"}"
      case "$footer" in
        "$model $effort · $displayed_worktree"|"$model $effort · $displayed_worktree · Context "[0-9]*'% use…')
          printf '%s' "$effort"
          return 0
          ;;
      esac
    fi
  done
  return 1
}

footer_effort() {
  local cap
  cap=$(capture_tail) || return 1
  footer_effort_from_capture "$cap"
}

endpoint_is_safe_idle() {
  local agent path composer busy cap live_effort
  agent=$(fm_backend_agent_state "$backend" "$target")
  [ "$agent" = alive ] || refuse "task $task_id endpoint state is '$agent', not a verified live Codex agent."
  path=$(current_path)
  [ "$path" = "$worktree" ] || refuse "task $task_id live worktree does not match its recorded worktree."
  busy=$(fm_backend_busy_state "$backend" "$target")
  [ "$busy" = idle ] || refuse "task $task_id native agent state is '$busy', not idle."
  cap=$(capture_tail) || refuse "task $task_id UI could not be read."
  if printf '%s\n' "$cap" | grep -qi 'esc to interrupt'; then
    refuse "task $task_id has a busy Codex turn."
  fi
  composer=$(fm_backend_composer_state "$backend" "$target")
  [ "$composer" = empty ] || refuse "task $task_id composer state is '$composer', not verified empty."
  live_effort=$(footer_effort_from_capture "$cap") \
    || refuse "task $task_id has no verifiable Codex model/effort footer."
  printf '%s' "$live_effort"
}

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

metadata_identity_checksum() {
  awk '!/^effort=/' "$meta" | cksum
}

metadata_fingerprint_matches() {
  [ "$(cksum < "$meta")" = "$meta_fingerprint" ]
}

verify_unchanged_endpoint() {
  fm_backend_validate_task_endpoint "$meta" "$task_id" >/dev/null \
    || refuse "task $task_id endpoint identity changed before metadata update."
  [ "$FM_BACKEND_VALIDATED_BACKEND" = "$backend" ] \
    && [ "$FM_BACKEND_VALIDATED_TARGET" = "$target" ] \
    || refuse "task $task_id endpoint changed before metadata update."
}

replace_metadata_effort() {  # <effort>
  local effort=$1 mode
  tmp_meta=$(mktemp "$STATE/.$task_id.meta.XXXXXX") \
    || refuse "could not create a metadata update beside $meta."
  awk -v effort="$effort" '
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
}

begin_recovery() {
  local identity_checksum
  [ ! -e "$recovery" ] && [ ! -L "$recovery" ] \
    || refuse "task $task_id already has an unresolved Codex effort recovery record."
  identity_checksum=$(metadata_identity_checksum) \
    || refuse "could not fingerprint task metadata identity for recovery."
  tmp_recovery=$(mktemp "$STATE/.$task_id.codex-effort-recovery.XXXXXX") \
    || refuse "could not prepare a Codex effort recovery record."
  {
    printf '%s\n' \
      'version=1' \
      "task_id=$task_id" \
      "backend=$backend" \
      "target=$target" \
      "harness=$harness" \
      "model=$model" \
      "worktree=$worktree" \
      "metadata_identity_checksum=$identity_checksum" \
      "recorded_effort=$recorded_effort" \
      "requested_effort=$requested_effort"
  } > "$tmp_recovery" || refuse "could not write a Codex effort recovery record."
  chmod 600 "$tmp_recovery" || refuse "could not secure a Codex effort recovery record."
  mv -f -- "$tmp_recovery" "$recovery" \
    || refuse "could not durably start Codex effort recovery."
  tmp_recovery=
}

recovery_value() {  # <key>
  fm_backend_meta_exact_value "$recovery" "$1"
}

validate_recovery() {
  local value current_identity
  [ -f "$recovery" ] && [ ! -L "$recovery" ] \
    || refuse "task $task_id has a non-regular Codex effort recovery record."
  value=$(recovery_value version) || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = 1 ] || refuse "task $task_id has an unsupported Codex effort recovery record."
  value=$(recovery_value task_id) || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = "$task_id" ] || refuse "task $task_id recovery record belongs to another task."
  value=$(recovery_value backend) || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = "$backend" ] || refuse "task $task_id recovery backend no longer matches its endpoint."
  value=$(recovery_value target) || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = "$target" ] || refuse "task $task_id recovery target no longer matches its endpoint."
  value=$(recovery_value harness) || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = "$harness" ] || refuse "task $task_id recovery harness no longer matches metadata."
  value=$(recovery_value model) || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = "$model" ] || refuse "task $task_id recovery model no longer matches metadata."
  value=$(recovery_value worktree) || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = "$worktree" ] || refuse "task $task_id recovery worktree no longer matches metadata."
  value=$(recovery_value recorded_effort) || refuse "task $task_id has malformed Codex effort recovery metadata."
  case "$value" in low|medium|high|xhigh) ;; *) refuse "task $task_id recovery effort is invalid." ;; esac
  value=$(recovery_value requested_effort) || refuse "task $task_id has malformed Codex effort recovery metadata."
  case "$value" in low|medium|high|xhigh) ;; *) refuse "task $task_id recovery requested effort is invalid." ;; esac
  current_identity=$(metadata_identity_checksum) \
    || refuse "could not fingerprint task metadata identity during recovery."
  value=$(recovery_value metadata_identity_checksum) \
    || refuse "task $task_id has malformed Codex effort recovery metadata."
  [ "$value" = "$current_identity" ] \
    || refuse "task $task_id metadata identity changed during Codex effort recovery."
}

reconcile_recovery() {
  local observed_effort
  validate_recovery
  observed_effort=$(endpoint_is_safe_idle) || exit 1
  if [ "$observed_effort" != "$recorded_effort" ]; then
    metadata_fingerprint_matches \
      || refuse "task $task_id metadata changed before Codex effort recovery."
    verify_unchanged_endpoint
    replace_metadata_effort "$observed_effort"
    recorded_effort=$observed_effort
    meta_fingerprint=$(cksum < "$meta") \
      || refuse "could not fingerprint reconciled task metadata."
  fi
  rm -f -- "$recovery" \
    || refuse "task $task_id live effort was reconciled but its recovery record could not be removed."
}

if [ -e "$recovery" ] || [ -L "$recovery" ]; then
  reconcile_recovery
fi
live_effort=$(endpoint_is_safe_idle) || exit 1
[ "$live_effort" = "$recorded_effort" ] \
  || refuse "task $task_id live effort '$live_effort' disagrees with recorded effort '$recorded_effort'."

current_rank=$(rank_of "$live_effort")
requested_rank=$(rank_of "$requested_effort")
if [ "$current_rank" -ne "$requested_rank" ]; then
  begin_recovery
fi
while [ "$current_rank" -ne "$requested_rank" ]; do
  if [ "$current_rank" -lt "$requested_rank" ]; then direction=up
  else direction=down
  fi
  expected=$(next_effort "$live_effort" "$direction") \
    || refuse "cannot move from effort '$live_effort' toward '$requested_effort'."
  metadata_fingerprint_matches \
    || refuse "task $task_id metadata changed before the live effort switch completed."
  rechecked_effort=$(endpoint_is_safe_idle) || exit 1
  [ "$rechecked_effort" = "$live_effort" ] \
    || refuse "task $task_id live effort changed before its reasoning chord."
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
[ "$current_rank" = "$requested_rank" ] || refuse "Codex did not reach the requested effort."
metadata_fingerprint_matches \
  || refuse "task $task_id metadata changed before confirmation; live effort changed but metadata was preserved."
verify_unchanged_endpoint
replace_metadata_effort "$requested_effort"
if [ -e "$recovery" ] || [ -L "$recovery" ]; then
  rm -f -- "$recovery" \
    || refuse "task $task_id switched effort but its recovery record could not be removed."
fi

printf '%s: %s %s (%s, session preserved)\n' "$task_id" "$model" "$requested_effort" "$backend"

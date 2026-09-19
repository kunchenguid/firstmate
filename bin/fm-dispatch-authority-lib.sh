# shellcheck shell=bash
# Dispatch-authority primitives: the captain's standing crewmate-concurrency cap
# and the Opus authorization gate, enforced in the spawn path instead of relying
# on the agent remembering them.
#
# Usage: . bin/fm-dispatch-authority-lib.sh   (after bin/fm-backend.sh)
#
# Both restrictions are captain authority, not tuning. The default path refuses,
# so drifting past them takes a deliberate flag that names what it asserts
# rather than a forgotten rule. bin/fm-spawn.sh owns the flag and the refusal
# text; this library owns the measurement and the predicates.
#
# What is deliberately NOT mechanized here: captain.md's rule that a persistent
# secondmate counts toward the cap "only while actively processing a task"
# requires a current-state read per secondmate (bin/fm-crew-state.sh), which the
# spawn path deliberately avoids - it is slow, can touch remote hosts, and would
# make every spawn depend on remote reachability. The count below therefore
# covers ordinary crewmates only, and the secondmate nuance remains a
# model-level invariant stated in data/captain.md.

FM_DISPATCH_CONCURRENCY_CAP_FILE="crew-concurrency-cap"
FM_DISPATCH_CONCURRENCY_CAP_DEFAULT="2"
FM_DISPATCH_AUTHORITY_ERROR=""

# fm_dispatch_authority_error
# Prints the reason the last cap read failed. Callers use this rather than the
# variable directly so the failure text has one accessor.
fm_dispatch_authority_error() {
  printf '%s\n' "$FM_DISPATCH_AUTHORITY_ERROR"
}

# fm_dispatch_concurrency_cap_read <config-dir>
# Prints the effective cap. The optional override file is held to the same exact
# format as the other budget knobs: one positive decimal and one newline in a
# regular, single-linked file. A malformed override is an error rather than a
# silent fallback, because silently reverting to the default would quietly widen
# a captain restriction.
fm_dispatch_concurrency_cap_read() {
  local config_dir=$1 path value links
  FM_DISPATCH_AUTHORITY_ERROR=""
  path="$config_dir/$FM_DISPATCH_CONCURRENCY_CAP_FILE"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '%s\n' "$FM_DISPATCH_CONCURRENCY_CAP_DEFAULT"
    return 0
  fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    FM_DISPATCH_AUTHORITY_ERROR="config/$FM_DISPATCH_CONCURRENCY_CAP_FILE is not a regular file"
    return 1
  fi
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f %l "$path" 2>/dev/null)
  else
    links=$(stat -c %h "$path" 2>/dev/null)
  fi
  if [ "$links" != 1 ]; then
    FM_DISPATCH_AUTHORITY_ERROR="config/$FM_DISPATCH_CONCURRENCY_CAP_FILE is hardlinked"
    return 1
  fi
  value=$(<"$path")
  case "$value" in
    ''|*[!0-9]*)
      FM_DISPATCH_AUTHORITY_ERROR="config/$FM_DISPATCH_CONCURRENCY_CAP_FILE must be one non-negative decimal integer"
      return 1
      ;;
  esac
  if ! printf '%s\n' "$value" | cmp -s "$path" -; then
    FM_DISPATCH_AUTHORITY_ERROR="config/$FM_DISPATCH_CONCURRENCY_CAP_FILE must contain exactly one value followed by one newline"
    return 1
  fi
  printf '%s\n' "$value"
}

# fm_dispatch_harness_is_claude <harness>
# The cap the captain set is specifically on Claude-backed crewmates.
fm_dispatch_harness_is_claude() {
  case "${1:-}" in
    claude) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_dispatch_model_is_opus <model>
# Matches any Opus model id, case-insensitively, across naming generations
# (opus, claude-opus-5, claude-3-opus-...). An empty or "default" model is NOT
# Opus: it defers to the harness's own configured default, which this gate has
# no authority over and must not silently claim to have checked.
fm_dispatch_model_is_opus() {
  local model=${1:-}
  [ -n "$model" ] || return 1
  [ "$model" != default ] || return 1
  case "$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')" in
    *opus*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_dispatch_active_claude_crew <state-dir>
# Prints the ids of Claude-backed ORDINARY crewmates (kind=ship or kind=scout)
# whose recorded endpoint is still alive, one per line.
#
# Liveness is what makes the cap honest: a finished-but-not-torn-down task whose
# endpoint is gone must not consume a slot, or the cap would ratchet shut as
# dead records accumulate. A record with no window recorded cannot be proven
# alive and is therefore not counted.
fm_dispatch_active_claude_crew() {
  local state_dir=$1 meta id kind harness window target backend
  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in
      ship|scout) ;;
      *) continue ;;
    esac
    harness=$(fm_meta_get "$meta" harness)
    fm_dispatch_harness_is_claude "$harness" || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] || continue
    id=$(basename "$meta" .meta)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if fm_backend_target_exists "$backend" "${target:-$window}" "fm-$id"; then
      printf '%s\n' "$id"
    fi
  done
}

# fm_dispatch_active_claude_count <state-dir>
fm_dispatch_active_claude_count() {
  fm_dispatch_active_claude_crew "$1" | grep -c . || true
}

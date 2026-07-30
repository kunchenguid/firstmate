#!/usr/bin/env bash
# fm-herdr-ci-cleanup.sh - bounded cleanup of CI-owned Herdr lab sessions.
#
# Snapshot the session list before the real-Herdr suite, then at job end only
# stop/delete sessions that:
#   1. match the guarded fm-lab-* name pattern,
#   2. were not present in the pre-suite snapshot (job-proven ownership),
#   3. report default:false on a fresh session list.
#
# Never touches the default session. Never adopts or force-deletes non-lab
# names. Missing herdr is a no-op (exit 0) so portable jobs can call this
# harmlessly; destructive failures for known lab leftovers exit non-zero.
#
# Usage:
#   fm-herdr-ci-cleanup.sh snapshot <path>
#   fm-herdr-ci-cleanup.sh teardown <snapshot-path>
set -eu

die() {
  printf 'fm-herdr-ci-cleanup.sh: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'fm-herdr-ci-cleanup.sh: %s\n' "$*" >&2
}

cmd=${1:-}
path=${2:-}
[ -n "$cmd" ] && [ -n "$path" ] || die "usage: fm-herdr-ci-cleanup.sh snapshot|teardown <path>"

if ! command -v herdr >/dev/null 2>&1; then
  log "herdr not on PATH; nothing to $cmd"
  exit 0
fi
command -v jq >/dev/null 2>&1 || die "jq is required"

list_sessions_json() {
  herdr session list --json 2>/dev/null \
    || die "could not list Herdr sessions"
}

is_lab_name() {
  local name=$1
  [[ "$name" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

case "$cmd" in
  snapshot)
    list_sessions_json | jq -c '[.sessions[]? | .name] | unique | sort' >"$path" \
      || die "failed to write session snapshot to $path"
    log "wrote session snapshot to $path ($(jq -r 'length' "$path") names)"
    ;;
  teardown)
    [ -f "$path" ] || die "snapshot file not found: $path"
    before=$(cat "$path")
    after_json=$(list_sessions_json)
    # Candidates: lab-named, default:false, not in the pre-suite snapshot.
    candidates=$(printf '%s' "$after_json" | jq -r --argjson before "$before" '
      .sessions[]?
      | select(.default == false)
      | select(.name | test("^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$"))
      | select((.name as $n | $before | index($n) | not))
      | .name
    ')
    failed=0
    if [ -z "$candidates" ]; then
      log "no job-owned fm-lab-* sessions to clean"
      exit 0
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      is_lab_name "$name" || {
        log "refusing non-lab name from candidate set: $name"
        failed=1
        continue
      }
      # Fresh refuse-default check immediately before each destructive call.
      flag=$(herdr session list --json 2>/dev/null \
        | jq -r --arg n "$name" '.sessions[]? | select(.name == $n) | .default' 2>/dev/null || true)
      if [ "$flag" != "false" ]; then
        log "refusing cleanup of '$name' (default=${flag:-<not found>})"
        failed=1
        continue
      fi
      log "stopping job-owned lab session $name"
      herdr session stop "$name" --json >/dev/null 2>&1 || true
      sleep 0.3
      flag=$(herdr session list --json 2>/dev/null \
        | jq -r --arg n "$name" '.sessions[]? | select(.name == $n) | .default' 2>/dev/null || true)
      if [ "$flag" != "false" ]; then
        log "refusing delete of '$name' after stop (default=${flag:-<not found>})"
        failed=1
        continue
      fi
      if herdr session delete "$name" --json >/dev/null 2>&1; then
        log "deleted job-owned lab session $name"
      else
        # Already gone is success; still present is failure.
        still=$(herdr session list --json 2>/dev/null \
          | jq -r --arg n "$name" '.sessions[]? | select(.name == $n) | .name' 2>/dev/null || true)
        if [ -n "$still" ]; then
          log "failed to delete lab session $name"
          failed=1
        else
          log "lab session $name already absent after stop"
        fi
      fi
    done <<<"$candidates"
    [ "$failed" -eq 0 ] || die "one or more job-owned lab sessions could not be cleaned"
    ;;
  *)
    die "unknown command: $cmd (use snapshot or teardown)"
    ;;
esac

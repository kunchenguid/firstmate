#!/usr/bin/env bash
# bin/fm-self-heal.sh - Local recovery watchdog for secondmate sessions.
#
# Runs in a secondmate's own home and checks whether the secondmate's agent
# session (its tmux/herdr pane) is alive. When the session is dead or
# authoritatively missing, it relaunches with the same `fm-spawn.sh --secondmate`
# parameters the primary firstmate would use, so recovery does not depend on
# the primary's watcher being alive.
#
# This is Option B of data/fm-frentes-linha-de-comando-solo/report.md, approved
# by the captain on 2026-07-28. It does NOT create tasks, dispatch work, or
# communicate with the captain. It only reanimates a dead session. The primary
# firstmate retains ownership of lost-response (pending-reply) detection -
# this script never touches pending-reply records or writes a corr= token.
#
# The liveness check and recovery-grade state vocabulary are owned by
# bin/fm-backend.sh's fm_backend_agent_state, exactly as the primary's
# session-start secondmate_liveness_sweep (bin/fm-bootstrap.sh) uses them.
# This script mirrors that sweep's safety contract: only dead or missing
# endpoints are respawned; ambiguous, unreadable, and unverified-harness
# states are skipped to prevent duplicate launches.
#
# Usage:
#   fm-self-heal.sh                # one-shot: check this secondmate and heal
#   fm-self-heal.sh --loop         # check periodically (default 60s interval)
#   fm-self-heal.sh --interval N   # loop with N-second interval
#   fm-self-heal.sh --dry-run      # report what would happen without relaunching
#   fm-self-heal.sh --all          # from primary: check all registered secondmates
#
# Environment:
#   FM_PRIMARY_ROOT         override the primary checkout path (testing or
#                          standalone-clone secondmate homes that lack a
#                          git worktree linkage to the primary)
#   FM_SELF_HEAL_INTERVAL   loop interval in seconds (default 60)
#
# Printed reason lines (successful alive/respawn lines go to stdout; skips,
# errors, and respawn failures go to stderr; routing is identical in loop mode):
#   self-heal: secondmate <id>: alive (backend=<backend>)
#   self-heal: secondmate <id>: respawned after <cause> (backend=<backend>)
#   self-heal: secondmate <id>: skipped: <reason> (backend=<backend>)
#   self-heal: secondmate <id>: respawn failed after <cause>: <reason>
#   self-heal: error: <message>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

SUB_HOME_MARKER=".fm-secondmate-home"
LOOP=0
DRY_RUN=0
ALL=0
INTERVAL="${FM_SELF_HEAL_INTERVAL:-60}"

# Crash-loop damper. In --loop mode a secondmate that dies immediately after
# every launch would otherwise be respawned forever, and each respawn would
# append an identical line to the primary's status file. RESPAWN_COUNT_MAP
# tracks consecutive respawns per id; once it reaches FM_SELF_HEAL_MAX_RESPAWNS
# the script stops respawning that id until a check reads alive (which resets
# it). LAST_STATUS_KEY_MAP de-duplicates status writes so an ongoing failure
# records at most one line. One-shot invocations start with empty maps, so a
# single respawn always proceeds and one status line is written - unchanged.
#
# The maps are newline-terminated "<id><TAB><value>" strings, not associative
# arrays: this file is parse-swept under stock macOS bash 3.2 (the
# macos-stock-bash CI job over bin/fm-lint.sh's file set), which predates
# `declare -A`. bin/fm-classify-lib.sh keeps the same no-associative-arrays
# discipline for the same reason.
FM_SELF_HEAL_MAX_RESPAWNS="${FM_SELF_HEAL_MAX_RESPAWNS:-5}"
TAB=$(printf '\t')
RESPAWN_COUNT_MAP=''
DAMPED_ANNOUNCED_MAP=''
LAST_STATUS_KEY_MAP=''

# _map_lookup <map> <id>: print the value bound to <id>, empty if unbound.
_map_lookup() {
  local map=$1 id=$2 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$id$TAB"*) printf '%s' "${line#*"$TAB"}"; return 0 ;;
    esac
  done <<EOF
$map
EOF
  return 1
}

# _map_set <map> <id> <value>: print <map> with <id> (re)bound to <value>.
_map_set() {
  local map=$1 id=$2 value=$3 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$id$TAB"*) ;;
      *) out="$out$line
" ;;
    esac
  done <<EOF
$map
EOF
  printf '%s%s%s%s\n' "$out" "$id" "$TAB" "$value"
}

# _map_drop <map> <id>: print <map> with any binding for <id> removed.
_map_drop() {
  local map=$1 id=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$id$TAB"*) ;;
      *) out="$out$line
" ;;
    esac
  done <<EOF
$map
EOF
  printf '%s' "$out"
}

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --loop) LOOP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --all) ALL=1 ;;
    --interval)
      shift
      [ $# -gt 0 ] || { echo "error: --interval requires a value" >&2; exit 2; }
      INTERVAL=$1
      ;;
    --interval=*) INTERVAL=${1#--interval=} ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$INTERVAL" in
  ''|*[!0-9]*) echo "error: --interval must be a positive integer" >&2; exit 2 ;;
esac
[ "$INTERVAL" -gt 0 ] || { echo "error: --interval must be a positive integer" >&2; exit 2; }

case "$FM_SELF_HEAL_MAX_RESPAWNS" in
  ''|*[!0-9]*) echo "error: FM_SELF_HEAL_MAX_RESPAWNS must be a positive integer" >&2; exit 2 ;;
esac
[ "$FM_SELF_HEAL_MAX_RESPAWNS" -gt 0 ] || { echo "error: FM_SELF_HEAL_MAX_RESPAWNS must be a positive integer" >&2; exit 2; }

# resolve_primary_root: find the primary firstmate checkout from this home's
# git worktree linkage. A secondmate home is a git worktree of the same repo,
# so `git rev-parse --git-common-dir` yields the primary's .git directory and
# its parent is the primary checkout. FM_PRIMARY_ROOT overrides for testing.
resolve_primary_root() {
  local common_dir primary
  [ -n "${FM_PRIMARY_ROOT:-}" ] && { printf '%s\n' "$FM_PRIMARY_ROOT"; return 0; }
  common_dir=$(git -C "$FM_HOME" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common_dir" ] || return 1
  primary=$(cd "$common_dir/.." 2>/dev/null && pwd -P) || return 1
  [ -d "$primary/bin" ] && [ -d "$primary/state" ] || return 1
  printf '%s\n' "$primary"
}

# is_secondmate_home: 0 if this home has the .fm-secondmate-home identity marker.
is_secondmate_home() {
  [ -f "$FM_HOME/$SUB_HOME_MARKER" ]
}

# secondmate_id_from_marker: print the id recorded in .fm-secondmate-home.
secondmate_id_from_marker() {
  cat "$FM_HOME/$SUB_HOME_MARKER" 2>/dev/null || true
}

# report_status: append a non-captain-relevant status line to the primary's
# state/<id>.status so the principal is informed that the secondmate
# self-healed. The "self-healed" verb is deliberately not in the
# captain-relevant set (done|needs-decision|blocked|failed) nor in the
# nonterminal absorb set (working|resolved|captain-held|paused), so it surfaces
# as an informational no-verb line without triggering a captain wake or
# interfering with pending-reply detection. It never carries a corr= token.
report_status() {  # <primary-state-dir> <id> <message>
  local state_dir=$1 id=$2 msg=$3 status_file
  # De-duplicate: an ongoing crash loop respawns with an identical message every
  # iteration; record it once rather than growing the status file without bound.
  # The key resets when the id next reads alive (damper_reset), so a genuine
  # later re-heal after recovery is recorded again.
  [ "$(_map_lookup "$LAST_STATUS_KEY_MAP" "$id")" = "$msg" ] && return 0
  status_file="$state_dir/$id.status"
  mkdir -p "$state_dir" 2>/dev/null || true
  [ -d "$state_dir" ] || return 0
  printf 'self-healed: %s (fm-self-heal watchdog, no corr)\n' "$msg" >> "$status_file" 2>/dev/null || true
  LAST_STATUS_KEY_MAP=$(_map_set "$LAST_STATUS_KEY_MAP" "$id" "$msg")
}

# --- crash-loop damper (loop mode) ------------------------------------------
# Consecutive respawns per id are bounded so a secondmate that dies immediately
# after every launch is not relaunched forever. The counter is process-local, so
# one-shot invocations (which start with an empty map) always allow one respawn.

# damper_allow_respawn: 0 if a respawn for <id> is still within the consecutive
# bound, 1 if the bound is reached (respawn suppressed). Announces the
# suppression once per id on stderr with a non-captain-relevant "skipped" verb.
damper_allow_respawn() {  # <id>
  local id=$1 count
  count=$(_map_lookup "$RESPAWN_COUNT_MAP" "$id") || count=0
  if [ "$count" -ge "$FM_SELF_HEAL_MAX_RESPAWNS" ]; then
    if [ -z "$(_map_lookup "$DAMPED_ANNOUNCED_MAP" "$id")" ]; then
      echo "self-heal: secondmate $id: skipped: crash-loop damper engaged after $count consecutive respawns" >&2
      DAMPED_ANNOUNCED_MAP=$(_map_set "$DAMPED_ANNOUNCED_MAP" "$id" 1)
    fi
    return 1
  fi
  return 0
}

# damper_note_respawn: record one successful respawn attempt for <id>.
damper_note_respawn() {  # <id>
  local id=$1 count
  count=$(_map_lookup "$RESPAWN_COUNT_MAP" "$id") || count=0
  RESPAWN_COUNT_MAP=$(_map_set "$RESPAWN_COUNT_MAP" "$id" "$((count + 1))")
}

# damper_reset: clear all crash-loop state for <id> once it reads alive.
damper_reset() {  # <id>
  local id=$1
  RESPAWN_COUNT_MAP=$(_map_drop "$RESPAWN_COUNT_MAP" "$id")
  DAMPED_ANNOUNCED_MAP=$(_map_drop "$DAMPED_ANNOUNCED_MAP" "$id")
  LAST_STATUS_KEY_MAP=$(_map_drop "$LAST_STATUS_KEY_MAP" "$id")
}

# do_respawn: the single gated respawn path shared by every recovery branch.
# Applies the crash-loop damper, performs the spawn, reports status on success,
# and prints the standard success/failure lines. Returns 0 on success or a
# damper-suppressed skip, 1 on spawn failure.
do_respawn() {  # <id> <primary_root> <primary_state> <success_suffix> <status_msg> <fail_cause>
  local id=$1 primary_root=$2 primary_state=$3 success_suffix=$4 status_msg=$5 fail_cause=$6 out
  damper_allow_respawn "$id" || return 0
  if out=$(fm_spawn_secondmate "$primary_root" "$id" 2>&1); then
    damper_note_respawn "$id"
    echo "self-heal: secondmate $id: $success_suffix"
    report_status "$primary_state" "$id" "$status_msg"
    return 0
  fi
  echo "self-heal: secondmate $id: respawn failed after $fail_cause: $(first_line "$out")" >&2
  return 1
}

# fm_spawn_secondmate: invoke the primary's fm-spawn.sh to relaunch a secondmate.
# Sets FM_ROOT_OVERRIDE and FM_HOME to the primary root so that config, state,
# and inheritance resolve exactly as the primary's own recovery would do them,
# regardless of how SCRIPT_DIR resolves (e.g. through a symlinked bin/). The
# FM_SPAWN_NO_GUARD flag skips the watcher guard - the whole point of the
# self-heal is that the primary's watcher may be down.
fm_spawn_secondmate() {  # <primary_root> <id>
  local primary_root=$1 id=$2
  FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$primary_root" FM_HOME="$primary_root" \
    "$primary_root/bin/fm-spawn.sh" "$id" --secondmate 2>&1
}

# check_and_heal_one: the core liveness check and recovery for one secondmate.
# Mirrors bin/fm-bootstrap.sh's secondmate_liveness_sweep safety contract:
# only dead or missing endpoints are respawned; ambiguous, unreadable, and
# unverified-harness states are skipped. The respawn uses the primary's
# fm-spawn.sh so config, state, and inheritance resolve exactly as the
# primary's own recovery would do them.
#
# Arguments:
#   $1 = id           the secondmate task id
#   $2 = primary_root the primary firstmate checkout path
# Returns: 0 on success or no-op, 1 on heal failure.
check_and_heal_one() {  # <id> <primary_root>
  local id=$1 primary_root=$2
  local primary_state meta backend target harness agent_state cause
  primary_state="$primary_root/state"
  meta="$primary_state/$id.meta"

  if [ ! -f "$meta" ]; then
    # No meta: cannot check liveness (no recorded endpoint). The session is
    # not alive, but we also cannot distinguish "never spawned" from "spawned
    # and cleaned up". Attempt a respawn from the registry - fm-spawn.sh
    # resolves home= from data/secondmates.md when meta is absent.
    echo "self-heal: secondmate $id: no meta found, attempting respawn from registry" >&2
    if [ "$DRY_RUN" = 1 ]; then
      echo "self-heal: secondmate $id: dry-run: would respawn (no meta)" >&2
      return 0
    fi
    do_respawn "$id" "$primary_root" "$primary_state" \
      "respawned after no meta found (fm-self-heal watchdog)" \
      "secondmate $id respawned after no meta found" \
      "no meta found"
    return $?
  fi

  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  harness=$(fm_meta_get "$meta" harness)

  if [ -z "$target" ]; then
    # Meta exists but has no endpoint: treat as dead (no session to check).
    echo "self-heal: secondmate $id: no endpoint in meta, attempting respawn" >&2
    if [ "$DRY_RUN" = 1 ]; then
      echo "self-heal: secondmate $id: dry-run: would respawn (no endpoint)" >&2
      return 0
    fi
    do_respawn "$id" "$primary_root" "$primary_state" \
      "respawned after no endpoint in meta (fm-self-heal watchdog)" \
      "secondmate $id respawned after no endpoint in meta" \
      "no endpoint in meta"
    return $?
  fi

  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable

  # Mirror the liveness sweep's harness verification: an unverified harness
  # blocks recovery even on a dead reading, so an unknown adapter never
  # licenses a duplicate launch.
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi) ;;
    *)
      case "$agent_state" in dead|missing) agent_state=unverified-harness ;; esac
      ;;
  esac

  case "$agent_state" in
    alive)
      damper_reset "$id"
      echo "self-heal: secondmate $id: alive (backend=$backend)"
      return 0
      ;;
    dead)
      cause="confirmed agent absence on existing endpoint"
      if [ "$DRY_RUN" = 1 ]; then
        echo "self-heal: secondmate $id: dry-run: would kill and respawn after $cause (backend=$backend)" >&2
        return 0
      fi
      damper_allow_respawn "$id" || return 0
      fm_backend_kill "$backend" "$target" 2>/dev/null || true
      do_respawn "$id" "$primary_root" "$primary_state" \
        "respawned after $cause (backend=$backend)" \
        "secondmate $id respawned after $cause (backend=$backend)" \
        "$cause"
      return $?
      ;;
    missing)
      cause="recorded endpoint confidently missing"
      if [ "$DRY_RUN" = 1 ]; then
        echo "self-heal: secondmate $id: dry-run: would respawn after $cause (backend=$backend)" >&2
        return 0
      fi
      do_respawn "$id" "$primary_root" "$primary_state" \
        "respawned after $cause (backend=$backend)" \
        "secondmate $id respawned after $cause (backend=$backend)" \
        "$cause"
      return $?
      ;;
    ambiguous)
      echo "self-heal: secondmate $id: skipped: existing endpoint has ambiguous agent process (backend=$backend)" >&2
      return 0
      ;;
    unreadable)
      echo "self-heal: secondmate $id: skipped: endpoint probe unreadable (backend=$backend)" >&2
      return 0
      ;;
    unverified-harness)
      echo "self-heal: secondmate $id: skipped: recorded harness '$harness' is unverified for recovery (backend=$backend)" >&2
      return 0
      ;;
    *)
      echo "self-heal: secondmate $id: skipped: agent recovery classifier unverified (backend=$backend, state=$agent_state)" >&2
      return 0
      ;;
  esac
}

# heal_all: iterate over every kind=secondmate meta in the primary's state/
# and check-and-heal each. This is the --all mode for running from the primary.
heal_all() {  # <primary_root>
  local primary_root=$1 primary_state meta id rc=0
  primary_state="$primary_root/state"
  [ -d "$primary_state" ] || { echo "self-heal: error: primary state dir not found: $primary_state" >&2; return 1; }
  for meta in "$primary_state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    check_and_heal_one "$id" "$primary_root" || rc=1
  done
  return "$rc"
}

# run_once: one pass of the self-heal check.
run_once() {
  local primary_root rc=0
  if [ "$ALL" = 1 ]; then
    # --all mode: run from the primary, checking all secondmates.
    primary_root="$FM_ROOT"
    [ -d "$primary_root/state" ] || { echo "self-heal: error: no state dir at $primary_root/state (--all runs from the primary)" >&2; return 1; }
    heal_all "$primary_root" || rc=1
    return "$rc"
  fi

  if is_secondmate_home; then
    local id
    id=$(secondmate_id_from_marker)
    if [ -z "$id" ]; then
      echo "self-heal: error: $SUB_HOME_MARKER marker is empty" >&2
      return 1
    fi
    primary_root=$(resolve_primary_root) || {
      echo "self-heal: error: cannot resolve primary checkout from $FM_HOME (set FM_PRIMARY_ROOT to override)" >&2
      return 1
    }
    check_and_heal_one "$id" "$primary_root" || rc=1
    return "$rc"
  fi

  echo "self-heal: error: not a secondmate home (no $SUB_HOME_MARKER marker). Use --all to check all secondmates from the primary." >&2
  return 1
}

if [ "$LOOP" = 1 ]; then
  # FM_SELF_HEAL_MAX_PASSES bounds the loop to N passes (0 = unlimited, the
  # production default). It exists so the crash-loop damper, whose state spans
  # iterations within one process, can be exercised deterministically; the
  # final pass skips the trailing sleep so a bounded run returns promptly.
  max_passes="${FM_SELF_HEAL_MAX_PASSES:-0}"
  case "$max_passes" in ''|*[!0-9]*) max_passes=0 ;; esac
  pass=0
  while true; do
    run_once || true
    pass=$((pass + 1))
    [ "$max_passes" -gt 0 ] && [ "$pass" -ge "$max_passes" ] && break
    sleep "$INTERVAL"
  done
else
  run_once
fi
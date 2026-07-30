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
# Printed reason lines (stdout for one-shot, stderr for loop):
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
  status_file="$state_dir/$id.status"
  mkdir -p "$state_dir" 2>/dev/null || true
  [ -d "$state_dir" ] || return 0
  printf 'self-healed: %s (fm-self-heal watchdog, no corr)\n' "$msg" >> "$status_file" 2>/dev/null || true
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
  local primary_state meta backend target harness agent_state cause out
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
    if out=$(fm_spawn_secondmate "$primary_root" "$id" 2>&1); then
      echo "self-heal: secondmate $id: respawned after no meta found (fm-self-heal watchdog)"
      report_status "$primary_state" "$id" "secondmate $id respawned after no meta found"
      return 0
    else
      echo "self-heal: secondmate $id: respawn failed after no meta found: $(first_line "$out")" >&2
      return 1
    fi
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
    if out=$(fm_spawn_secondmate "$primary_root" "$id" 2>&1); then
      echo "self-heal: secondmate $id: respawned after no endpoint in meta (fm-self-heal watchdog)"
      report_status "$primary_state" "$id" "secondmate $id respawned after no endpoint in meta"
      return 0
    else
      echo "self-heal: secondmate $id: respawn failed after no endpoint in meta: $(first_line "$out")" >&2
      return 1
    fi
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
      echo "self-heal: secondmate $id: alive (backend=$backend)"
      return 0
      ;;
    dead)
      cause="confirmed agent absence on existing endpoint"
      if [ "$DRY_RUN" = 1 ]; then
        echo "self-heal: secondmate $id: dry-run: would kill and respawn after $cause (backend=$backend)" >&2
        return 0
      fi
      fm_backend_kill "$backend" "$target" 2>/dev/null || true
      if out=$(fm_spawn_secondmate "$primary_root" "$id" 2>&1); then
        echo "self-heal: secondmate $id: respawned after $cause (backend=$backend)"
        report_status "$primary_state" "$id" "secondmate $id respawned after $cause (backend=$backend)"
        return 0
      else
        echo "self-heal: secondmate $id: respawn failed after $cause: $(first_line "$out")" >&2
        return 1
      fi
      ;;
    missing)
      cause="recorded endpoint confidently missing"
      if [ "$DRY_RUN" = 1 ]; then
        echo "self-heal: secondmate $id: dry-run: would respawn after $cause (backend=$backend)" >&2
        return 0
      fi
      if out=$(fm_spawn_secondmate "$primary_root" "$id" 2>&1); then
        echo "self-heal: secondmate $id: respawned after $cause (backend=$backend)"
        report_status "$primary_state" "$id" "secondmate $id respawned after $cause (backend=$backend)"
        return 0
      else
        echo "self-heal: secondmate $id: respawn failed after $cause: $(first_line "$out")" >&2
        return 1
      fi
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
  while true; do
    run_once || true
    sleep "$INTERVAL"
  done
else
  run_once
fi
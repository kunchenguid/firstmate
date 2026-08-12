#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - restart-firstmate-watcher: yes|no
#   - restart-secondmate-watchers: <window-targets...>|none
#   - nudge-secondmates: <window-targets...>|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help|--ack-reread-firstmate <generation>|--ack-secondmate-nudge <target> <generation>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "update" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-watcher-protocol-lib.sh
. "$SCRIPT_DIR/fm-watcher-protocol-lib.sh"

"$SCRIPT_DIR/fm-guard.sh"

usage() {
  echo "usage: fm-update.sh [--help|--ack-reread-firstmate <generation>|--ack-secondmate-nudge <target> <generation>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ack_secondmate_nudge() {
  local target=$1 generation=$2 id="" record_id candidate home window meta marker matches=0
  home=""
  while IFS='|' read -r record_id candidate window meta; do
    if [ "$window" = "$target" ]; then
      matches=$((matches + 1))
      id=$record_id
      home=$candidate
    fi
  done < <(live_secondmate_meta_records "$STATE" "$SECONDMATES_MD")
  [ "$matches" -eq 1 ] || {
    echo "secondmate nudge acknowledgement: target is not uniquely live: $target" >&2
    return 1
  }
  validate_secondmate_home "$id" "$home" || {
    echo "secondmate nudge acknowledgement: unsafe home for $target: $VALIDATION_ERROR" >&2
    return 1
  }
  marker="$VALIDATED_HOME/state/.watch-protocol-reread-required"
  fm_update_obligation_ack "$marker" "$generation" "$VALIDATED_HOME" || {
    echo "secondmate nudge acknowledgement: generation mismatch for $target" >&2
    return 1
  }
  echo "acknowledged-secondmate-nudge: $target"
}

case "${1:-}" in
  --ack-reread-firstmate)
    [ $# -eq 2 ] || { usage; exit 1; }
    fm_update_obligation_ack "$(fm_watcher_protocol_reread_marker "$STATE")" "$2" "$FM_ROOT" || {
      echo "firstmate reread acknowledgement: generation mismatch" >&2
      exit 1
    }
    echo "acknowledged-reread-firstmate: yes"
    exit 0
    ;;
  --ack-secondmate-nudge)
    [ $# -eq 3 ] || { usage; exit 1; }
    ack_secondmate_nudge "$2" "$3"
    exit $?
    ;;
  '')
    ;;
  *)
    usage
    exit 1
    ;;
esac

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
reread_firstmate_generation=""
restart_firstmate_watcher="no"
reread_marker=$(fm_watcher_protocol_reread_marker "$STATE")
fm_update_obligation_pending "$reread_marker" "$FM_ROOT" && reread_firstmate="yes"
ff_target "$FM_ROOT" "firstmate" origin no no "$reread_marker" instructions
reread_firstmate_generation=$FF_OBLIGATION_GENERATION
if [ "$FF_STATUS" = "updated" ]; then
  installed_update="$FM_ROOT/bin/fm-update.sh"
  script_root=$(cd "$SCRIPT_DIR/.." && pwd -P)
  root_real=$(cd "$FM_ROOT" && pwd -P)
  if [ "${FM_UPDATE_REEXECED:-0}" != 1 ] \
    && [ "$script_root" = "$root_real" ] \
    && [ -x "$installed_update" ]; then
    export FM_UPDATE_REEXECED=1
    export FM_HOME
    export FM_ROOT_OVERRIDE="$FM_ROOT"
    export FM_STATE_OVERRIDE="$STATE"
    exec "$installed_update"
  fi
fi
fm_update_obligation_pending "$reread_marker" "$FM_ROOT" && reread_firstmate="yes"
if ! fm_watcher_protocol_restart_if_required "$FM_HOME" "$STATE" "$FM_ROOT"; then
  echo "firstmate: skipped: watcher protocol restart could not be verified" >&2
  exit 1
fi
if [ "$FM_WATCHER_PROTOCOL_RESTARTED" -eq 1 ]; then
  restart_firstmate_watcher="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_NUDGE_GENERATIONS=""
FF_SEEN_HOMES=""
restart_secondmate_watchers=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

while IFS='|' read -r id home window _meta; do
  [ -n "$window" ] || continue
  validate_secondmate_home "$id" "$home" || continue
  home="$VALIDATED_HOME"
  if ! fm_watcher_protocol_restart_if_required "$home" "$home/state" "$home"; then
    echo "secondmate $id: skipped: watcher protocol restart could not be verified" >&2
    exit 1
  fi
  if [ "$FM_WATCHER_PROTOCOL_RESTARTED" -eq 1 ]; then
    restart_secondmate_watchers="$restart_secondmate_watchers $window"
  fi
done < <(live_secondmate_meta_records "$STATE" "$SECONDMATES_MD")

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "reread-firstmate-generation: ${reread_firstmate_generation:-none}"
echo "restart-firstmate-watcher: $restart_firstmate_watcher"
echo "restart-secondmate-watchers:${restart_secondmate_watchers:- none}"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
while IFS='|' read -r target generation; do
  [ -n "$target" ] || continue
  echo "nudge-secondmate-generation: $target|$generation"
done <<< "$FF_NUDGE_GENERATIONS"

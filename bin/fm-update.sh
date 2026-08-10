#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. FAST-FORWARD ONLY, exactly like
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
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
# Checkout ownership is coordinated with dependency checks by
# bin/fm-dependency-lock-lib.sh. When a coordinating caller supplies
# FM_UPDATE_ACTION_DIR, prepared and completed action records make its required
# reread and nudge follow-ups recoverable across interruption.
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-update-action-lib.sh
. "$SCRIPT_DIR/fm-update-action-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

fm_update_action_enabled() {
  [ -n "${FM_UPDATE_ACTION_DIR:-}" ]
}

fm_update_target_is_firstmate() {
  [ "$(resolve_path "$1")" = "$(resolve_path "$FM_ROOT")" ]
}

fm_ff_before_fast_forward() {
  local dir=$1 before=$2 after=$3 instructions=$4
  fm_update_action_enabled || return 0
  if fm_update_target_is_firstmate "$dir"; then
    [ -n "$instructions" ] || return 0
    fm_update_action_write_firstmate prepared "$FM_ROOT" "$before" "$after"
    return
  fi
  [ -n "$FF_UPDATE_SECOND_MATE_ID" ] && [ -n "$FF_UPDATE_SECOND_MATE_WINDOW" ] \
    || return 0
  fm_update_action_write_secondmate prepared "$FF_UPDATE_SECOND_MATE_ID" \
    "$FF_UPDATE_SECOND_MATE_HOME" "$before" "$after" 0 "" ""
}

fm_ff_after_fast_forward() {
  local dir=$1 before=$2 after=$3 instructions=$4
  fm_update_action_enabled || return 0
  if fm_update_target_is_firstmate "$dir"; then
    [ -n "$instructions" ] || return 0
    fm_update_action_write_firstmate updated "$FM_ROOT" "$before" "$after"
    return
  fi
  [ -n "$FF_UPDATE_SECOND_MATE_ID" ] && [ -n "$FF_UPDATE_SECOND_MATE_WINDOW" ] \
    || return 0
  fm_update_action_write_secondmate updated "$FF_UPDATE_SECOND_MATE_ID" \
    "$FF_UPDATE_SECOND_MATE_HOME" "$before" "$after" 0 "" ""
}

fm_ff_abort_fast_forward() {
  local dir=$1 instructions=$4
  fm_update_action_enabled || return 0
  if fm_update_target_is_firstmate "$dir"; then
    [ -n "$instructions" ] || return 0
    fm_update_action_remove_firstmate
    return
  fi
  [ -n "$FF_UPDATE_SECOND_MATE_ID" ] && [ -n "$FF_UPDATE_SECOND_MATE_WINDOW" ] \
    || return 0
  fm_update_action_remove_secondmate "$FF_UPDATE_SECOND_MATE_ID"
}

remote_secondmate_action_required() {
  local id=$1 home=$2 remote_host=$3 remote_root=$4 meta meta_kind meta_home
  local meta_remote_host meta_remote_root
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  meta_kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$meta_kind" = secondmate ] || return 1
  meta_home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$meta_home" ] || meta_home=$home
  meta_remote_host=$(grep '^remote_host=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  meta_remote_root=$(grep '^remote_root=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$meta_home" = "$home" ] && [ "$meta_remote_host" = "$remote_host" ] \
    && [ "$meta_remote_root" = "$remote_root" ]
}

run_update_locked() {
  local reread_firstmate="no" id home line remote_out remote_result remote_action remote_commit
  local remote_host remote_root

  if fm_update_action_enabled; then
    fm_update_action_dir_is_valid "$FM_UPDATE_ACTION_DIR" || {
      echo "firstmate: skipped: update action journal is unavailable" >&2
      return 1
    }
  fi

  # --- main firstmate repo ---------------------------------------------------

  ff_target "$FM_ROOT" "firstmate" origin no no
  if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
    reread_firstmate="yes"
  fi

  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""

  # --- secondmates -----------------------------------------------------------
  # An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
  # is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
  # same condition it has always used.

  # Live direct reports first: state/<id>.meta with kind=secondmate carries the
  # authoritative home= path.
  sweep_live_secondmate_metas "$STATE" origin no

  # Registry backstop: a secondmate registered in data/secondmates.md but without
  # a live meta (e.g. between restarts) is still its persistent on-disk home.
  if [ -f "$SECONDMATES_MD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*) ;;
        *) continue ;;
      esac
      if ! secondmate_registry_parse_line "$line"; then
        echo "secondmate registry: skipped malformed entry: $line" >&2
        continue
      fi
      id=$SECONDMATE_REGISTRY_ID
      home=$SECONDMATE_REGISTRY_HOME
      if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
        remote_host=$SECONDMATE_REGISTRY_HOST
        remote_root=$SECONDMATE_REGISTRY_ROOT
        remote_action=0
        if remote_secondmate_action_required "$id" "$home" "$remote_host" "$remote_root"; then
          remote_action=1
          if fm_update_action_enabled \
            && ! fm_update_action_write_secondmate prepared "$id" "$home" "" "" 1 \
              "$remote_host" "$remote_root"; then
            echo "remote secondmate $id: skipped on $remote_host: update action journal is unavailable" >&2
            continue
          fi
        fi
        if remote_out=$(FM_ON_EXPECTED_HOST="$remote_host" \
          FM_ON_EXPECTED_ROOT="$remote_root" FM_ON_EXPECTED_HOME="$home" \
          "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" \
          < /dev/null 2>&1); then
          remote_result=$(printf '%s\n' "$remote_out" | tail -1)
          case "$remote_result" in
            synced:*)
              remote_commit=${remote_result#synced: }
              if ! fm_update_action_commit_is_valid "$remote_commit"; then
                echo "remote secondmate $id: skipped on $remote_host: malformed update result" >&2
                if [ "$remote_action" -eq 1 ] && fm_update_action_enabled; then
                  FF_ACTION_JOURNAL_FAILED=1
                fi
                continue
              fi
              echo "remote secondmate $id: updated on $remote_host ($remote_commit)"
              if [ "$remote_action" -eq 1 ]; then
                if fm_update_action_enabled; then
                  fm_update_action_write_secondmate updated "$id" "$home" "" "$remote_commit" 1 \
                    "$remote_host" "$remote_root" || FF_ACTION_JOURNAL_FAILED=1
                fi
                FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
              fi
              ;;
            current:*)
              remote_commit=${remote_result#current: }
              if ! fm_update_action_commit_is_valid "$remote_commit"; then
                echo "remote secondmate $id: skipped on $remote_host: malformed update result" >&2
                if [ "$remote_action" -eq 1 ] && fm_update_action_enabled; then
                  FF_ACTION_JOURNAL_FAILED=1
                fi
                continue
              fi
              echo "remote secondmate $id: already current on $remote_host ($remote_commit)"
              if [ "$remote_action" -eq 1 ] && fm_update_action_enabled; then
                fm_update_action_remove_secondmate "$id" || FF_ACTION_JOURNAL_FAILED=1
              fi
              ;;
            *)
              echo "remote secondmate $id: skipped on $remote_host: malformed update result" >&2
              if [ "$remote_action" -eq 1 ] && fm_update_action_enabled; then
                FF_ACTION_JOURNAL_FAILED=1
              fi
              ;;
          esac
        else
          echo "remote secondmate $id: skipped on $remote_host: ${remote_out%%$'\n'*}" >&2
          if [ "$remote_action" -eq 1 ] && fm_update_action_enabled; then
            FF_ACTION_JOURNAL_FAILED=1
          fi
        fi
      else
        process_secondmate "$id" "$home" "" origin no
      fi
    done < "$SECONDMATES_MD"
  fi

  # --- caller action summary -------------------------------------------------

  echo "reread-firstmate: $reread_firstmate"
  echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
  ff_action_journal_succeeded
}

update_status=0
fm_dependency_with_host_lock run_update_locked || update_status=$?
if [ "$update_status" -eq 75 ]; then
  echo "firstmate: skipped: dependency check is active"
  echo "reread-firstmate: no"
  echo "nudge-secondmates: none"
  exit 0
fi
if [ "$update_status" -ne 0 ]; then
  if [ "$FM_DEPENDENCY_LOCK_OUTCOME" = callback-failed ]; then
    echo "firstmate: skipped: checkout update or action journal failed" >&2
  else
    echo "firstmate: skipped: dependency lock is unavailable" >&2
  fi
  echo "reread-firstmate: no"
  echo "nudge-secondmates: none"
  exit 1
fi

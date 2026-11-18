#!/usr/bin/env bash
# fm-stage-ladder-lib.sh - the one owner of the per-project stage ladder file.
#
# Sourced, never executed. A stage ladder says how far a project's work can
# travel after its PR merges ("merged", then "deployed", then "live"), and how
# to tell, with a command, that a rung has been reached. bin/fm-goal.sh reads a
# ladder to validate an item's `target=` and to run `fm-goal.sh probe`, which
# moves the item's stage mark; the goal record stays the one place a stage is
# recorded.
#
# THE FILE (home-local, gitignored: <config>/stage-ladders/<project>). The
# project name is the item's `project=` value, path-safe like a goal id. Lines,
# lowest rung first:
#   # comment
#   stage <name>: <probe command>
# <name> is path-safe (no empty value, leading dot, slash, or character outside
# [A-Za-z0-9._-]) and appears once. The probe is one shell command line that
# fm-goal.sh runs under `bash -c` with a hard bound; it is the captain's own
# home-local configuration and is trusted as such, so a ladder file is never
# committed and never read from a project checkout. A symlinked ladder is
# refused.
# Miko has a bundled fallback when no home-local file exists: merged uses the
# shared PR probe; deployed and live require explicit marks (their probes never
# pass). A merge is progress, not evidence that a real finish condition holds.
#
# PROBE CONTRACT. Exit 0 means the rung is reached; any other exit means it is
# not, and exit 124 means the bound was hit. The first stdout line is the
# evidence (a PR URL, a run id) and goes into the stage mark's note. The probe
# environment carries FM_GOAL_ID, FM_GOAL_ITEM, FM_GOAL_PROJECT,
# FM_GOAL_TASK ('' when the item names none), FM_GOAL_STAGE (the rung being
# probed), and FM_GOAL_HOME (the home whose state the goal lives in).
# bin/fm-goal-probe-pr-merged.sh is the shared probe for a "PR merged" rung.
#
# Provides:
#   fm_stage_name_valid <name>
#   fm_stage_ladder_path <config-dir> <project>
#   fm_stage_ladder_load <config-dir> <project>
#       rc 0 and FM_STAGE_LADDER_NAMES / FM_STAGE_LADDER_PROBES set; rc 1 when
#       the project has no ladder file or bundled default (FM_STAGE_LADDER_ERROR
#       empty); rc 2 when
#       the file is unreadable, a symlink, or malformed (FM_STAGE_LADDER_ERROR
#       says why).
#   fm_stage_ladder_rank <stage>   prints the 0-based rung, rc 1 when not on it

# Consumed by the sourcing caller (bin/fm-goal.sh).
# shellcheck disable=SC2034
FM_STAGE_LADDER_NAMES=()
# shellcheck disable=SC2034
FM_STAGE_LADDER_PROBES=()
# shellcheck disable=SC2034
FM_STAGE_LADDER_ERROR=''

fm_stage_name_valid() {  # <name>
  local name=${1-} LC_ALL=C
  case "$name" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_stage_ladder_path() {  # <config-dir> <project>
  printf '%s/stage-ladders/%s\n' "$1" "$2"
}

# shellcheck disable=SC2034  # the results are read by the sourcing caller
fm_stage_ladder_load() {  # <config-dir> <project>
  local path line name probe seen
  FM_STAGE_LADDER_NAMES=()
  FM_STAGE_LADDER_PROBES=()
  FM_STAGE_LADDER_ERROR=''
  fm_stage_name_valid "$2" || { FM_STAGE_LADDER_ERROR="unsafe project name: $2"; return 2; }
  path=$(fm_stage_ladder_path "$1" "$2")
  if [ -L "$path" ]; then
    FM_STAGE_LADDER_ERROR="ladder is a symlink: $path"
    return 2
  fi
  if [ ! -e "$path" ]; then
    [ "$2" = miko ] || return 1
    FM_STAGE_LADDER_NAMES=(merged deployed live)
    local probe_dir
    probe_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    printf -v probe_dir '%q' "$probe_dir/fm-goal-probe-pr-merged.sh"
    FM_STAGE_LADDER_PROBES=("bash $probe_dir" false false)
    return 0
  fi
  if ! { [ -f "$path" ] && [ -r "$path" ]; }; then
    FM_STAGE_LADDER_ERROR="ladder is unreadable: $path"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      'stage '*:*) ;;
      *) FM_STAGE_LADDER_ERROR="malformed ladder line in $path: $line"; return 2 ;;
    esac
    name=${line#stage }
    name=${name%%:*}
    probe=${line#*:}
    probe=${probe# }
    fm_stage_name_valid "$name" || { FM_STAGE_LADDER_ERROR="unsafe stage name in $path: $name"; return 2; }
    case "$probe" in
      *[![:space:]]*) ;;
      *) FM_STAGE_LADDER_ERROR="stage $name has no probe in $path"; return 2 ;;
    esac
    for seen in ${FM_STAGE_LADDER_NAMES[@]+"${FM_STAGE_LADDER_NAMES[@]}"}; do
      [ "$seen" != "$name" ] || { FM_STAGE_LADDER_ERROR="duplicate stage $name in $path"; return 2; }
    done
    FM_STAGE_LADDER_NAMES[${#FM_STAGE_LADDER_NAMES[@]}]=$name
    FM_STAGE_LADDER_PROBES[${#FM_STAGE_LADDER_PROBES[@]}]=$probe
  done < "$path"
  [ "${#FM_STAGE_LADDER_NAMES[@]}" -ge 1 ] || { FM_STAGE_LADDER_ERROR="ladder has no stages: $path"; return 2; }
  return 0
}

fm_stage_ladder_rank() {  # <stage>
  local i=0
  while [ "$i" -lt "${#FM_STAGE_LADDER_NAMES[@]}" ]; do
    if [ "${FM_STAGE_LADDER_NAMES[$i]}" = "$1" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

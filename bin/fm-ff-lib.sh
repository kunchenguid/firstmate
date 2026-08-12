# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# collision-safe fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch, bin/fm-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# A linked-worktree secondmate home already holds the primary's commit in the
# shared object store, so its local-HEAD sync is a purely local fast-forward that
# never touches the network. A standalone clone moves through that path only when
# it already has the target; otherwise it is skipped until the origin path updates it.
# A tracked-files fast-forward never touches the gitignored operational dirs
# (data/, state/, config/, projects/, .no-mistakes/), so it cannot disturb a
# secondmate's backlog, projects, or in-flight work.
# The seeded .fm-secondmate-home identity marker is gitignored too; the local
# sync tolerates only that marker during the one-time upgrade of pre-ignore
# linked-worktree homes.
# Homes are leased at a detached HEAD on the
# default branch, so the fast-forward advances HEAD only and never moves the
# shared default branch or any other worktree's checkout.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-registry-lib.sh"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="secondmate $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the active firstmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the firstmate repo"
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$FM_HOME") || {
    VALIDATION_ERROR="active firstmate home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$FM_ROOT") || {
    VALIDATION_ERROR="firstmate repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="secondmate home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="secondmate home cannot be the active firstmate home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="secondmate home cannot be the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the firstmate repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="secondmate marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="not a seeded secondmate home"
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for secondmate ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a firstmate home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a firstmate home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md symlinks), its agent-loaded skills
# (.agents/skills/), and its tooling (bin/). Public skills/ is installer-facing
# and intentionally not part of this watched instruction surface.
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

# A dirty checkout blocks a fast-forward only when its uncommitted paths collide
# with the exact HEAD..base change set. Both listings are NUL-delimited so spaces
# and non-ASCII path bytes are preserved. Any status or diff state that cannot be
# classified confidently fails closed instead of becoming an empty change set.
#
# Sets FF_COLLISION_ERROR for an unclassifiable state and FF_COLLISION_DETAILS
# to one entry per genuine collision. Returns 0 when safe, 1 for collisions, and
# 2 for an unclassifiable state.
FF_COLLISION_ERROR=""
FF_COLLISION_DETAILS=()
FF_INCOMING_PATHS=()
FF_INCOMING_ACTIONS=()
FF_INCOMING_ACTION=""
FF_UNTRACKED_COLLISION=""

ff_operation_marker() {  # <dir> <git-path> <description>
  local dir=$1 marker=$2 description=$3 path
  path=$(git -C "$dir" rev-parse --git-path "$marker" 2>/dev/null) || {
    FF_COLLISION_ERROR="git rev-parse --git-path $marker failed"
    return 2
  }
  case "$path" in
    /*) : ;;
    *) path="$dir/$path" ;;
  esac
  [ ! -e "$path" ] || {
    FF_COLLISION_ERROR="$description"
    return 2
  }
  return 0
}

ff_operation_status() {  # <dir>
  local dir=$1
  ff_operation_marker "$dir" MERGE_HEAD "merge in progress" || return $?
  ff_operation_marker "$dir" CHERRY_PICK_HEAD "cherry-pick in progress" || return $?
  ff_operation_marker "$dir" REVERT_HEAD "revert in progress" || return $?
  ff_operation_marker "$dir" sequencer/todo "cherry-pick or revert sequence in progress" || return $?
  ff_operation_marker "$dir" rebase-merge "rebase in progress" || return $?
  ff_operation_marker "$dir" rebase-apply/applying "patch application in progress" || return $?
  ff_operation_marker "$dir" rebase-apply "rebase in progress" || return $?
  ff_operation_marker "$dir" BISECT_LOG "bisect in progress" || return $?
  return 0
}

ff_incoming_action() {  # <path>
  local want=$1 i=0
  while [ "$i" -lt "${#FF_INCOMING_PATHS[@]}" ]; do
    if [ "${FF_INCOMING_PATHS[$i]}" = "$want" ]; then
      FF_INCOMING_ACTION=${FF_INCOMING_ACTIONS[$i]}
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

ff_untracked_collision() {  # <path>
  local want=$1 i=0 add lead nested
  lead="untracked file here"
  nested="needs that path to be a directory to add"
  case "$want" in
    */)
      want=${want%/}
      lead="untracked directory here that git will not descend into"
      nested="adds a file beneath it at"
      ;;
  esac
  while [ "$i" -lt "${#FF_INCOMING_PATHS[@]}" ]; do
    if [ "${FF_INCOMING_ACTIONS[$i]}" = adds ]; then
      add=${FF_INCOMING_PATHS[$i]}
      if [ "$add" = "$want" ]; then
        FF_UNTRACKED_COLLISION="$lead, while the fast-forward adds that path"
        return 0
      fi
      case "$add" in
        "$want"/*)
          FF_UNTRACKED_COLLISION="$lead, while the fast-forward $nested '$add'"
          return 0
          ;;
      esac
      case "$want" in
        "$add"/*)
          FF_UNTRACKED_COLLISION="$lead, while the fast-forward adds '$add' where a directory exists"
          return 0
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 1
}

ff_collision_check() {  # <dir> <base> <ignore-seed-marker>
  local dir=$1 base=$2 ignore_seed_marker=${3:-no}
  local tmp status_file incoming_file entry code path other change rc=0
  local -a dirty_paths untracked_paths

  FF_COLLISION_ERROR=""
  FF_COLLISION_DETAILS=()
  FF_INCOMING_PATHS=()
  FF_INCOMING_ACTIONS=()
  dirty_paths=()
  untracked_paths=()

  ff_operation_status "$dir" || return 2

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-ff-collision.XXXXXX") || {
    FF_COLLISION_ERROR="cannot create collision-check temporary directory"
    return 2
  }
  status_file="$tmp/status"
  incoming_file="$tmp/incoming"

  if ! git -C "$dir" status --porcelain=v1 -z --untracked-files=all > "$status_file" 2>/dev/null; then
    FF_COLLISION_ERROR="git status failed"
    rc=2
  fi

  if [ "$rc" -eq 0 ]; then
    while IFS= read -r -d '' entry; do
      if [ "${#entry}" -lt 4 ]; then
        FF_COLLISION_ERROR="truncated git status entry"
        rc=2
        break
      fi
      code=${entry:0:2}
      path=${entry:3}
      case "$code" in
        '??')
          if [ "$ignore_seed_marker" != yes ] || [ "$path" != "$SUB_HOME_MARKER" ]; then
            untracked_paths+=("$path")
          fi
          continue
          ;;
        'DD'|'AA'|U?|?U)
          FF_COLLISION_ERROR="unresolved conflict at '$path'"
          rc=2
          break
          ;;
      esac
      case "${code:0:1}" in
        ' '|M|T|A|D|R|C) : ;;
        *)
          FF_COLLISION_ERROR="unrecognized git status code '$code' at '$path'"
          rc=2
          break
          ;;
      esac
      case "${code:1:1}" in
        ' '|M|T|A|D|R|C) : ;;
        *)
          FF_COLLISION_ERROR="unrecognized git status code '$code' at '$path'"
          rc=2
          break
          ;;
      esac
      dirty_paths+=("$path")
      case "$code" in
        *R*|*C*)
          if ! IFS= read -r -d '' other; then
            FF_COLLISION_ERROR="truncated '$code' rename entry at '$path'"
            rc=2
            break
          fi
          dirty_paths+=("$other")
          ;;
      esac
    done < "$status_file"
  fi

  if [ "$rc" -eq 0 ] && ! git -C "$dir" diff -z --name-status HEAD "$base" -- > "$incoming_file" 2>/dev/null; then
    FF_COLLISION_ERROR="git diff failed between HEAD and $base"
    rc=2
  fi

  if [ "$rc" -eq 0 ]; then
    while IFS= read -r -d '' change; do
      if ! IFS= read -r -d '' path; then
        FF_COLLISION_ERROR="truncated '$change' entry in incoming diff"
        rc=2
        break
      fi
      case "$change" in
        A)
          FF_INCOMING_PATHS+=("$path"); FF_INCOMING_ACTIONS+=(adds)
          ;;
        M|M[0-9]*|T|T[0-9]*)
          FF_INCOMING_PATHS+=("$path"); FF_INCOMING_ACTIONS+=(changes)
          ;;
        D)
          FF_INCOMING_PATHS+=("$path"); FF_INCOMING_ACTIONS+=(removes)
          ;;
        R|R[0-9]*)
          if ! IFS= read -r -d '' other; then
            FF_COLLISION_ERROR="truncated '$change' rename entry at '$path'"
            rc=2
            break
          fi
          FF_INCOMING_PATHS+=("$path"); FF_INCOMING_ACTIONS+=(removes)
          FF_INCOMING_PATHS+=("$other"); FF_INCOMING_ACTIONS+=(adds)
          ;;
        C|C[0-9]*)
          if ! IFS= read -r -d '' other; then
            FF_COLLISION_ERROR="truncated '$change' copy entry at '$path'"
            rc=2
            break
          fi
          FF_INCOMING_PATHS+=("$other"); FF_INCOMING_ACTIONS+=(adds)
          ;;
        *)
          FF_COLLISION_ERROR="unrecognized git diff status '$change' at '$path'"
          rc=2
          break
          ;;
      esac
    done < "$incoming_file"
  fi

  if [ "$rc" -eq 0 ]; then
    for path in "${dirty_paths[@]}"; do
      if ff_incoming_action "$path"; then
        FF_COLLISION_DETAILS+=("$path - uncommitted changes here, while the fast-forward $FF_INCOMING_ACTION it")
      fi
    done
    for path in "${untracked_paths[@]}"; do
      if ff_untracked_collision "$path"; then
        FF_COLLISION_DETAILS+=("$path - $FF_UNTRACKED_COLLISION")
      fi
    done
    if [ "${#FF_COLLISION_DETAILS[@]}" -gt 0 ]; then
      rc=1
    fi
  fi

  rm -f -- "$status_file" "$incoming_file"
  rmdir -- "$tmp" 2>/dev/null || true
  return "$rc"
}

# List this home's LIVE secondmate direct reports from state/<id>.meta records.
# The meta file is the liveness signal; data/secondmates.md is only the fallback
# for durable fields such as home= when an older/incomplete meta lacks them.
# Output is pipe-delimited: id|home|window|meta-file.
live_secondmate_meta_records() {
  local state=$1 registry=${2:-} meta id home window
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$home" ] && [ -n "$registry" ]; then
      home=$(secondmate_registry_field "$registry" "$id" home || true)
    fi
    window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    printf '%s|%s|%s|%s\n' "$id" "$home" "$window" "$meta"
  done
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /updatefirstmate
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: ff-only (never force/merge/stash); skip a
# colliding, unclassifiable, diverged, or wrong-branch target and leave its work
# untouched. Unrelated uncommitted paths do not block an otherwise safe update.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  FF_STATUS="skipped"
  FF_INSTR=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi

  local default base cur instr local_rev base_rev before after out collision_rc collision
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }

  collision_rc=0
  ff_collision_check "$dir" "$base" "$ignore_seed_marker" || collision_rc=$?
  if [ "$collision_rc" -eq 2 ]; then
    echo "$label: skipped: cannot classify working tree: $FF_COLLISION_ERROR"
    return 0
  fi
  if [ "$collision_rc" -eq 1 ]; then
    echo "$label: skipped: uncommitted paths collide with fast-forward:"
    for collision in "${FF_COLLISION_DETAILS[@]}"; do
      echo "  $collision"
    done
    return 0
  fi
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  FF_STATUS="updated"
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets both before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Validate and fast-forward one secondmate home, accumulating its stable
# fm-<id> task selector into FF_NUDGE_WINDOWS when it should be live-converged.
# Args:
#   id home window base_mode nudge_requires_instr
# A home is nudged only when it ACTUALLY advanced (FF_STATUS=updated) and has a
# live window. With nudge_requires_instr=yes the advance must also have changed
# the instruction surface (FF_INSTR non-empty): an already-current home, or one
# whose only change was non-instruction tracked files, is left undisturbed. The
# firstmate repo itself (FM_ROOT) is never processed as its own secondmate, and
# each resolved home is processed at most once.
process_secondmate() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no} home_real fm_root_real
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  fm_root_real=$(resolve_path "$FM_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  ff_target "$home_real" "secondmate $id" "$base_mode" yes yes
  if [ "$FF_STATUS" = "updated" ] && [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ] && [ -z "$FF_INSTR" ]; then
      return 0
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
    if [ "$nudge_requires_instr" = yes ] && [ -n "$FF_INSTR" ] \
      && type fm_ff_after_instruction_update >/dev/null 2>&1; then
      fm_ff_after_instruction_update "$id" "$home_real" "$window" "$FF_INSTR"
    fi
  fi
}

# Sweep this home's LIVE secondmate direct reports - state/<id>.meta files with
# kind=secondmate - fast-forwarding each to base_mode. Passes base_mode and
# nudge_requires_instr through to process_secondmate. Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
# The registry argument is only for home= fallback on older or incomplete meta records.
sweep_live_secondmate_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} registry=${4:-$FM_HOME/data/secondmates.md} id home window meta
  [ -d "$state" ] || return 0
  while IFS='|' read -r id home window meta; do
    if grep -q '^remote_host=.' "$meta" 2>/dev/null; then continue; fi
    process_secondmate "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr"
  done < <(live_secondmate_meta_records "$state" "$registry")
}

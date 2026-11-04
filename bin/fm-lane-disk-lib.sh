#!/usr/bin/env bash
# Opt-in lane disk settings shared by bin/fm-spawn.sh, bin/fm-brief.sh, and
# bin/fm-teardown.sh. docs/configuration.md "Lane disk use" documents the three
# settings; this header owns their exact resolution and safety mechanics.
# Every setting is off by default, and an off setting changes no spawn, brief,
# or teardown behavior.
#
# Build-output root: config/build-output-root holds one absolute directory on
# its first non-blank, non-comment line. FM_BUILD_OUTPUT_ROOT overrides it: an
# absolute path enables that root, off/0/false/no disables, and unset or empty
# defers to the file. A relative or otherwise invalid value warns and disables.
# A fresh ship or scout spawn records build_output_dir=<root>/<task-id> in the
# task record, creates it, and exports FM_BUILD_OUTPUT_DIR plus the variables
# fm_lane_disk_build_env_pairs lists. A relaunch reuses the recorded directory
# and never resolves the setting again. Teardown removes only the recorded
# directory, only after its landed-work gates pass, and refuses a recorded path
# that is not absolute, does not end in the task id, or equals or contains the
# task's worktree.
#
# Clone discipline: the config/clone-discipline presence flag, overridden by
# FM_CLONE_DISCIPLINE (1/on/true/yes enables, any other non-empty value
# disables, unset or empty defers to the file). When on, ship and scout briefs
# gain the "# Disk use" checkout rule and teardown warns about every separate
# full clone it finds in the task's worktree, temp root, or build directory. The
# warning never deletes anything and never blocks teardown.
#
# Scratch cleanup: config/scratch-dirs lists one path per line, relative to the
# task worktree root; blank lines and lines starting with # are ignored.
# FM_SCRATCH_DIRS overrides the file with a colon-separated list, off disables,
# and unset or empty defers to the file. A path that is absolute, empty, ".",
# contains a ".." component, or starts with a ".git" component is skipped with a
# warning. At teardown, after the landed-work gates pass and before the copy is
# returned, each declared path that exists is removed, except a path that holds
# tracked files or resolves through a symlinked parent outside the worktree;
# a declared path that is itself a symlink has only the link removed.

fm_lane_disk_warn() { printf 'warning: %s\n' "$*" >&2; }

# fm_lane_disk_override_state <value>: prints on, off, or empty (defer).
fm_lane_disk_override_state() {
  local v
  [ -n "${1:-}" ] || return 0
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$v" in
    1|on|true|yes) printf 'on' ;;
    *) printf 'off' ;;
  esac
}

# fm_lane_disk_build_root <config-dir>: prints the enabled absolute root and
# returns 0, or returns 1 when the setting is off or invalid.
fm_lane_disk_build_root() {
  local config=$1 root=
  if [ -n "${FM_BUILD_OUTPUT_ROOT:-}" ]; then
    case "$(printf '%s' "$FM_BUILD_OUTPUT_ROOT" | tr '[:upper:]' '[:lower:]')" in
      off|0|false|no) return 1 ;;
    esac
    root=$FM_BUILD_OUTPUT_ROOT
  elif [ -f "$config/build-output-root" ]; then
    root=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$config/build-output-root" \
      | grep -v -e '^$' -e '^#' | head -1) || root=
    [ -n "$root" ] || return 1
  else
    return 1
  fi
  case "$root" in
    /*) ;;
    *) fm_lane_disk_warn "build-output root '$root' is not an absolute path; per-lane build output stays off"; return 1 ;;
  esac
  while [ "$root" != / ] && [ "${root%/}" != "$root" ]; do root=${root%/}; done
  case "/$root/" in
    */../*|*/./*) fm_lane_disk_warn "build-output root '$root' has a . or .. component; per-lane build output stays off"; return 1 ;;
  esac
  [ "$root" != / ] || { fm_lane_disk_warn "build-output root must not be /; per-lane build output stays off"; return 1; }
  printf '%s\n' "$root"
}

# fm_lane_disk_build_env_pairs <dir>: NAME=VALUE lines the spawn exports.
# Only variables the tools themselves document as overriding their output
# location are listed (docs/configuration.md names each source).
fm_lane_disk_build_env_pairs() {
  local dir=$1
  printf 'FM_BUILD_OUTPUT_DIR=%s\n' "$dir"
  printf 'CARGO_TARGET_DIR=%s\n' "$dir/cargo-target"
  printf 'PYTHONPYCACHEPREFIX=%s\n' "$dir/pycache"
}

_fm_lane_disk_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_lane_disk_build_env_exports <dir>: one shell line of export statements.
fm_lane_disk_build_env_exports() {
  local pair out=
  while IFS= read -r pair; do
    out="${out}export ${pair%%=*}=$(_fm_lane_disk_quote "${pair#*=}"); "
  done < <(fm_lane_disk_build_env_pairs "$1")
  printf '%s' "$out"
}

# fm_lane_disk_build_dir_valid <dir> <task-id> [<worktree>]
fm_lane_disk_build_dir_valid() {
  local dir=$1 id=$2 wt=${3:-}
  case "$dir" in /*) ;; *) return 1 ;; esac
  case "/$dir/" in */../*|*/./*) return 1 ;; esac
  [ "${dir##*/}" = "$id" ] || return 1
  [ -n "${dir%/*}" ] || return 1
  if [ -n "$wt" ]; then
    case "$wt/" in "$dir"/*) return 1 ;; esac
  fi
  return 0
}

# fm_lane_disk_remove_build_dir <dir> <task-id> [<worktree>]: removes the
# recorded per-lane build directory. Never fatal.
fm_lane_disk_remove_build_dir() {
  local dir=$1 id=$2 wt=${3:-}
  [ -n "$dir" ] || return 0
  if ! fm_lane_disk_build_dir_valid "$dir" "$id" "$wt"; then
    fm_lane_disk_warn "recorded build-output directory '$dir' for $id is not <root>/$id outside the worktree; left in place"
    return 0
  fi
  if [ -L "$dir" ]; then
    rm -f -- "$dir" || fm_lane_disk_warn "could not remove build-output link $dir"
  elif [ -e "$dir" ]; then
    rm -rf -- "$dir" || fm_lane_disk_warn "could not fully remove build-output directory $dir"
  fi
  return 0
}

# fm_lane_disk_clone_discipline_on <config-dir>
fm_lane_disk_clone_discipline_on() {
  case "$(fm_lane_disk_override_state "${FM_CLONE_DISCIPLINE:-}")" in
    on) return 0 ;;
    off) return 1 ;;
  esac
  [ -e "$1/clone-discipline" ]
}

# fm_lane_disk_full_clones <worktree-or-empty> <dir>...: prints the top of each
# separate full clone found within four levels of each directory. A clone that
# borrows objects through objects/info/alternates (git clone --reference or
# --shared) is not full; the worktree's own top-level .git is skipped.
fm_lane_disk_full_clones() {
  local wt=$1 root gitdir repo
  shift
  for root in "$@"; do
    [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || continue
    while IFS= read -r gitdir; do
      [ -n "$gitdir" ] || continue
      [ -z "$wt" ] || [ "$gitdir" != "$wt/.git" ] || continue
      if [ "${gitdir##*/}" = .git ]; then
        repo=${gitdir%/.git}
      else
        [ -f "$gitdir/HEAD" ] && [ -d "$gitdir/objects" ] || continue
        repo=$gitdir
      fi
      [ -d "$gitdir/objects" ] || continue
      [ ! -s "$gitdir/objects/info/alternates" ] || continue
      printf '%s\n' "$repo"
    done < <(find "$root" -maxdepth 4 -type d -name '*.git' -prune -print 2>/dev/null)
  done
}

# fm_lane_disk_clone_warn <task-id> <worktree-or-empty> <dir>...
fm_lane_disk_clone_warn() {
  local id=$1 wt=$2 repo
  shift 2
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    fm_lane_disk_warn "task $id holds a separate full clone at $repo; make extra checkouts with git clone --reference or a worktree instead (clone discipline warns only and deleted nothing)"
  done < <(fm_lane_disk_full_clones "$wt" "$@")
  return 0
}

# fm_lane_disk_scratch_entries <config-dir>: prints the raw declared entries.
fm_lane_disk_scratch_entries() {
  local config=$1
  if [ -n "${FM_SCRATCH_DIRS:-}" ]; then
    [ "$(printf '%s' "$FM_SCRATCH_DIRS" | tr '[:upper:]' '[:lower:]')" != off ] || return 0
    printf '%s\n' "$FM_SCRATCH_DIRS" | tr ':' '\n'
  elif [ -f "$config/scratch-dirs" ]; then
    grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$config/scratch-dirs" || true
  fi
}

# fm_lane_disk_scratch_path_valid <relative-path>: the normalized path on stdout.
fm_lane_disk_scratch_path_valid() {
  local rel=$1
  rel=$(printf '%s' "$rel" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  while [ "${rel%/}" != "$rel" ]; do rel=${rel%/}; done
  while [ "${rel#./}" != "$rel" ]; do rel=${rel#./}; done
  case "$rel" in
    ''|.|/*) return 1 ;;
    .git|.git/*) return 1 ;;
  esac
  case "/$rel/" in */../*|*/./*) return 1 ;; esac
  printf '%s\n' "$rel"
}

# fm_lane_disk_scratch_cleanup <worktree> <config-dir>: removes declared
# scratch paths under the worktree. Never fatal.
fm_lane_disk_scratch_cleanup() {
  local wt=$1 config=$2 entry rel target parent wt_real parent_real tracked
  [ -d "$wt" ] || return 0
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if ! rel=$(fm_lane_disk_scratch_path_valid "$entry"); then
      fm_lane_disk_warn "scratch path '$entry' is not a plain path inside the task copy; skipped"
      continue
    fi
    target="$wt/$rel"
    [ -e "$target" ] || [ -L "$target" ] || continue
    parent=$(dirname "$target")
    parent_real=$(cd "$parent" 2>/dev/null && pwd -P) || continue
    case "$parent_real/" in
      "$wt_real"/*) ;;
      *) fm_lane_disk_warn "scratch path '$rel' resolves outside the task copy; skipped"; continue ;;
    esac
    if [ -L "$target" ]; then
      rm -f -- "$target" || fm_lane_disk_warn "could not remove scratch link $target"
      continue
    fi
    if ! tracked=$(git -C "$wt" ls-files -- ":(literal)$rel" 2>/dev/null); then
      fm_lane_disk_warn "could not check scratch path '$rel' for tracked files; skipped"
      continue
    fi
    if [ -n "$tracked" ]; then
      fm_lane_disk_warn "scratch path '$rel' holds tracked files; skipped"
      continue
    fi
    rm -rf -- "$target" || fm_lane_disk_warn "could not fully remove scratch path $target"
  done < <(fm_lane_disk_scratch_entries "$config")
  return 0
}

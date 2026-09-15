#!/usr/bin/env bash
# Per-project store of material that must reach a worker without ever entering
# the project's history.
#
# Some of a project's knowledge can never be committed: a collaborator-owned
# repository firstmate does not get to add files to, material holding real
# client or patient data, per-machine configuration, and - for a project whose
# canonical home is a local checkout rather than its repository - simply
# everything that lives outside git there. This store carries that material into
# every task copy at spawn time, so a worker starts with what the captain's own
# sessions have, and it never becomes a commit.
#
# Layout, under the active firstmate home:
#   data/project-local/<project>/material/   files staged into each task copy
#   data/project-local/<project>/manifest    optional: paths `sync` pulls from
#                                            the project's canonical home
#
# The store is private and gitignored with the rest of data/, is never inherited
# by a secondmate home, and survives teardown: teardown removes the task copy,
# never this.
#
# Usage:
#   fm-project-local.sh list <project>
#   fm-project-local.sh add <project> <file-or-dir>
#   fm-project-local.sh remove <project> <relative-path>
#   fm-project-local.sh sync <project>
#   fm-project-local.sh stage <project> <worktree>
#
# `sync` copies each manifest path out of the project's canonical home
# (bin/fm-project-memory.sh home) into the store. It only ever reads that
# directory; the captain's live checkout is never written, staged, or cleaned.
# That checkout is shared rather than still - he works in it while firstmate has
# work going - so sync reports when the folder was being written while the copy
# was taken instead of presenting a possibly torn file as clean, and says so
# separately when that could not be determined at all.
# The store holds regular files only, so a manifest path that is a symlink or a
# directory holding one is not transportable. `sync` names it on stderr, leaves
# it un-updated, and carries the rest of the manifest: one untransportable path
# must never keep the material a worker does need from reaching it.
# A path `sync` cannot refresh - untransportable, or gone from the home - keeps
# the copy an earlier run took, because that copy can be the last one left and
# deleting the captain's material is not firstmate's call. It is marked
# instead: `sync` records the path, the reason, and the date it stopped being
# confirmable, and `stage` writes those marks into the task copy as
# `.fm-local/.fm-unverified.md`, so the worker reads an old copy as old rather
# than as the project's current material.
#
# `stage` is the spawn-time step, called by bin/fm-spawn.sh once a task copy is
# known to be isolated. It is idempotent and self-cleaning: a pool slot reused by
# a later task never keeps the previous task's staged material, whether or not
# this task stages any of its own. It refuses rather than staging when the destination is a
# tracked path, and after copying it verifies that git reports nothing under the
# destination - a staged store git can still see is removed and the spawn fails,
# because a worker cannot be told not to commit something git is offering it.
# A copy that could not read the store in full - a `sync` of the same project is
# not serialised against a spawn and can replace a tree under the read - is
# removed and refuses the spawn the same way, because a worker handed a subset
# of the project's material would read it as the whole of it.
# The destination is added to the repository's exclude file, the same mechanism
# fm-spawn already uses for the per-task harness files it writes into a copy.
# What lands there is the store and nothing else, so material named like
# anything firstmate might write is never shadowed; the launch brief is what
# tells the worker what the directory is and that it never becomes a commit.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STORE_ROOT="$DATA/project-local"

# The single name of the staged directory inside a task copy. Everything that
# reads or excludes it derives from this constant.
STAGE_DIR_NAME='.fm-local'

# The note staging writes beside the material when the store carries a copy the
# last sync could not refresh. `.fm-` is firstmate's own prefix inside a task
# copy, and `valid_relative_path` keeps it out of the store, so material can
# never shadow this note nor be shadowed by it.
STAGE_NOTE_NAME='.fm-unverified.md'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "project-local: $1" >&2
  exit 1
}

valid_project_name() {  # <name>
  case "$1" in
    '' | .* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  case "$1" in
    *..*) return 1 ;;
  esac
  return 0
}

# A store-relative path must stay inside the store and inside the task copy it
# is later written into, so the same test gates `add`, `remove`, and every
# manifest line.
valid_relative_path() {  # <path>
  case "$1" in
    '' | /* | -*) return 1 ;;
    *[[:cntrl:]]*) return 1 ;;
    .fm-*) return 1 ;;
  esac
  case "/$1/" in
    */../* | */./*) return 1 ;;
  esac
  return 0
}

store_dir() {  # <project>
  printf '%s\n' "$STORE_ROOT/$1"
}

material_dir() {  # <project>
  printf '%s\n' "$STORE_ROOT/$1/material"
}

# A path the sync could not refresh keeps the copy an earlier sync took: that
# copy can be the last one left of the captain's material, so deleting it is
# not firstmate's call. What firstmate owes instead is the mark - which path,
# why, and since when - so the worker never reads an old copy as current, the
# same contract the recipe catalog keeps with a lapsed entry.
unverified_file() {  # <project>
  printf '%s\n' "$STORE_ROOT/$1/unverified"
}

# Matched on the path alone: the date says since when this copy stopped being
# confirmable, and that does not restart because the reason it cannot be
# refreshed changed - or because `find` named a different symlink this time. A
# sync that does refresh the path drops the record, so a real restart still
# starts over.
unverified_since() {  # <record file> <rel>; prints the date already recorded
  [ -f "$1" ] || return 1
  awk -F'\t' -v rel="$2" '
    $1 == rel { print $2; found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

require_project() {  # <project>
  valid_project_name "$1" || die "invalid project name: $1"
}

# A symlink in the store would resolve against whatever the task copy happens to
# contain, so the store holds regular files and directories only. The source
# tree is checked BEFORE anything is copied, so a refusal never leaves a
# poisoned store behind that would block every later stage - and with it every
# spawn of the project - until someone removes it by hand. The store itself is
# checked again before it is staged.
first_symlink() {  # <dir>; prints the first symlink under it, empty when there is none
  find "$1" -type l -print -quit 2>/dev/null || true
}

refuse_symlinks() {  # <dir> <what>
  local found
  found=$(first_symlink "$1")
  [ -z "$found" ] || die "refusing symlink in $2: $found"
}

# The store never loses the copy it already holds to a copy that failed: the new
# one is built beside the store and swapped in only once it is whole. For a
# project whose knowledge lives outside git, what is in the store can be the
# last copy left of the captain's material, and a half-finished read of his home
# - a OneDrive placeholder that will not hydrate offline, a file Windows has
# open, an I/O error on /mnt/c - must never be what replaces it. The swap also
# settles the shape: a path that was a directory and is a file now lands in its
# place rather than inside the directory it used to be.
# The one place a tree is copied, and the only place the pipeline's two statuses
# are read. tar's extractor succeeds over a truncated stream, so the reader's
# status is what says whether the whole tree was actually read. Callers reach
# this through a condition, which is what keeps `set -e` from ending the script
# on the pipeline itself and leaving the cleanup and the explanation unrun.
copy_tree() {  # <source dir> <destination dir>
  (cd "$1" && tar cf - .) | (cd "$2" && tar xf -)
  [ "${PIPESTATUS[0]}:${PIPESTATUS[1]}" = "0:0" ]
}

copy_into_store() {  # <project> <source> <destination under material>
  local staging payload rc=1
  mkdir -p "$(store_dir "$1")" || return 1
  # A name of its own per call, not per process: a cleanup that cannot finish -
  # the source made a directory read-only, so the copy is stuck there - must
  # never leave something the NEXT manifest path would be extracted on top of
  # and carried into the store as its own material.
  staging=$(mktemp -d "$(store_dir "$1")/.incoming.XXXXXX") || return 1
  payload="$staging/payload"
  if [ -d "$2" ]; then
    if mkdir -p "$payload" && copy_tree "$2" "$payload"; then
      rc=0
    fi
  elif cp -- "$2" "$payload"; then
    rc=0
  fi
  if [ "$rc" -ne 0 ] || ! mkdir -p "$(dirname "$3")"; then
    remove_tree "$staging"
    return 1
  fi
  remove_tree "$3"
  if ! mv -- "$payload" "$3"; then
    remove_tree "$staging"
    return 1
  fi
  remove_tree "$staging"
  chmod -R u+w "$3" 2>/dev/null || true
  return 0
}

# Material copied out of a source tree carries that tree's permissions, so a
# directory the captain made read-only would defeat a plain `rm -rf` and leave
# the store holding something nobody meant it to keep.
remove_tree() {  # <path>
  [ -e "$1" ] || return 0
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf -- "$1"
}

canonical_home() {  # <project>
  "$SCRIPT_DIR/fm-project-memory.sh" home "$1"
}

# Only `activity`'s own "active" answer counts as someone working in the home;
# a failed check is reported as exactly that, never as activity observed.
HOME_ACTIVE=0
HOME_ACTIVITY_UNKNOWN=0
note_home_activity() {  # <home-dir>
  local rc=0
  "$SCRIPT_DIR/fm-project-memory.sh" activity --home "$1" >/dev/null 2>&1 || rc=$?
  case $rc in
    0) ;;
    3) HOME_ACTIVE=1 ;;
    *) HOME_ACTIVITY_UNKNOWN=1 ;;
  esac
}

# --- staging ----------------------------------------------------------------

stage_material() {  # <project> <worktree>
  local project=$1 wt=$2 material dest excl seen empty=0 record marks='' rel since reason
  material=$(material_dir "$project")
  if [ ! -d "$material" ] ||
    [ -z "$(find "$material" -mindepth 1 -print -quit 2>/dev/null || true)" ]; then
    empty=1
  else
    refuse_symlinks "$material" "the local material store"
  fi

  [ -d "$wt" ] || die "task copy is not a directory: $wt"
  local top
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || die "task copy is not a git worktree: $wt"
  [ "$(cd "$wt" && pwd -P)" = "$(cd "$top" && pwd -P)" ] || die "task copy is not a worktree root: $wt"

  # A project that already tracks this path would have the staged material
  # silently overwrite committed files, and the exclude entry would not apply.
  if git -C "$wt" ls-files --error-unmatch -- "$STAGE_DIR_NAME" >/dev/null 2>&1; then
    [ "$empty" -eq 1 ] && return 0
    die "$wt tracks $STAGE_DIR_NAME; refusing to stage local material over a tracked path"
  fi
  if [ -e "$wt/$STAGE_DIR_NAME" ] && [ ! -d "$wt/$STAGE_DIR_NAME" ]; then
    die "$wt/$STAGE_DIR_NAME exists and is not a directory"
  fi

  # Pool slots are reused across a project's tasks, so a previous task's staged
  # material has to go even when this task stages none; leaving it would hand a
  # worker material nobody decided it should have.
  remove_tree "${wt:?}/$STAGE_DIR_NAME"
  [ "$empty" -eq 0 ] || return 0

  # git resolves --git-path relative to the worktree, not to this process's cwd,
  # so a relative answer has to be anchored before anything writes through it.
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  case $excl in
    '' | /*) ;;
    *) excl="$wt/$excl" ;;
  esac
  if [ -n "$excl" ]; then
    mkdir -p "$(dirname "$excl")"
    grep -qxF "$STAGE_DIR_NAME/" "$excl" 2>/dev/null || printf '%s/\n' "$STAGE_DIR_NAME" >>"$excl"
  fi

  dest="$wt/$STAGE_DIR_NAME"
  mkdir -p "$dest"
  # The store can change under this read, because a `sync` of the same project
  # is not serialised against a spawn. A worker handed a subset of the project's
  # material would read it as the whole of it, which is exactly what the
  # unverified marks exist to prevent.
  if ! copy_tree "$material" "$dest"; then
    remove_tree "$dest"
    die "could not read $project's local material in full while staging it into $dest; refusing to launch a worker over a partial copy"
  fi
  record=$(unverified_file "$project")
  if [ -s "$record" ]; then
    while IFS="$(printf '\t')" read -r rel since reason; do
      [ -n "$rel" ] && [ -e "$dest/$rel" ] || continue
      marks="${marks}- \`$rel\` (UNVERIFIED since $since - $reason)
"
    done <"$record"
  fi
  if [ -n "$marks" ]; then
    {
      printf '# Unverified material\n\n'
      printf 'The last sync could not refresh these paths from the project'"'"'s canonical home, so what is staged here is the copy an earlier sync took. Confirm anything you take from them against the project before you rely on it, and say so in your report if it turns out to be wrong.\n\n'
      printf '%s' "$marks"
    } >"$dest/$STAGE_NOTE_NAME"
  fi
  find "$dest" -type f -exec chmod 0444 {} + 2>/dev/null || true

  # The mechanism, not the instruction: if git can still see anything under the
  # staged directory, a worker could commit it, so the material is removed again
  # and the caller is refused rather than launched.
  seen=$(git -C "$wt" status --porcelain --untracked-files=all -- "$STAGE_DIR_NAME" 2>/dev/null || true)
  if [ -n "$seen" ]; then
    remove_tree "$dest"
    die "git still reports paths under $STAGE_DIR_NAME in $wt after excluding it; refusing to stage material a worker could commit"
  fi
  printf 'staged: %s local material into %s\n' "$project" "$dest"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  -h | --help | '')
    usage
    exit 0
    ;;
esac

CMD=$1
shift

case "$CMD" in
  list)
    NAME=${1:-}
    [ -n "$NAME" ] || die "usage: list <project>"
    require_project "$NAME"
    MATERIAL=$(material_dir "$NAME")
    if [ ! -d "$MATERIAL" ]; then
      echo "empty"
      exit 0
    fi
    FOUND=$(cd "$MATERIAL" && find . -mindepth 1 \( -type f -o -type l \) -print 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)
    if [ -z "$FOUND" ]; then
      echo "empty"
    else
      printf '%s\n' "$FOUND"
    fi
    ;;
  add)
    NAME=${1:-}
    SRC=${2:-}
    [ -n "$NAME" ] && [ -n "$SRC" ] || die "usage: add <project> <file-or-dir>"
    require_project "$NAME"
    shift 2
    [ "$#" -eq 0 ] || die "unknown option: $1"
    [ -e "$SRC" ] || die "no such file or directory: $SRC"
    [ -L "$SRC" ] && die "refusing to add a symlink: $SRC"
    AS=$(basename "$SRC")
    valid_relative_path "$AS" || die "invalid destination path: $AS"
    [ -d "$SRC" ] && refuse_symlinks "$SRC" "$SRC"
    MATERIAL=$(material_dir "$NAME")
    copy_into_store "$NAME" "$SRC" "$MATERIAL/$AS" || die "could not copy $SRC in full; the store keeps what it already had"
    echo "added: $NAME <- $AS"
    ;;
  remove)
    NAME=${1:-}
    REL=${2:-}
    [ -n "$NAME" ] && [ -n "$REL" ] || die "usage: remove <project> <relative-path>"
    require_project "$NAME"
    valid_relative_path "$REL" || die "invalid path: $REL"
    MATERIAL=$(material_dir "$NAME")
    [ -e "$MATERIAL/$REL" ] || die "not in the store: $REL"
    remove_tree "${MATERIAL:?}/$REL"
    echo "removed: $NAME $REL"
    ;;
  sync)
    NAME=${1:-}
    [ -n "$NAME" ] || die "usage: sync <project>"
    require_project "$NAME"
    STORE=$(store_dir "$NAME")
    MANIFEST="$STORE/manifest"
    [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST; list one path per line to pull from the project's canonical home"
    HOME_DIR=$(canonical_home "$NAME") || die "could not resolve the canonical home for $NAME"
    # The canonical home can be a live folder the captain is working in while
    # this copy is taken, so a file can be caught mid-write. This never blocks
    # the sync - the store is a private cache and a re-run is free - but it must
    # never be silent either, because a truncated file that reaches every worker
    # is far worse than one that arrives late.
    note_home_activity "$HOME_DIR"
    MATERIAL=$(material_dir "$NAME")
    mkdir -p "$MATERIAL"
    RECORD=$(unverified_file "$NAME")
    RECORD_NEW="$STORE/.unverified.$$"
    : >"$RECORD_NEW"
    TODAY=$(date -u +%Y-%m-%d)
    UPDATED=0
    KEPT=0
    NOTHING=0
    # A path this run could not carry never loses the copy an earlier run took.
    # It is recorded instead, so staging can hand the worker the copy AND the
    # reason it is no longer known to be current.
    not_updated() {  # <rel> <reason>
      local since
      if [ -e "$MATERIAL/$1" ]; then
        since=$(unverified_since "$RECORD" "$1") || since=$TODAY
        printf '%s\t%s\t%s\n' "$1" "$since" "$2" >>"$RECORD_NEW"
        KEPT=$((KEPT + 1))
        echo "project-local: $1 was not updated ($2); the copy from an earlier sync stays in the store and reaches every worker marked UNVERIFIED since $since" >&2
      else
        NOTHING=$((NOTHING + 1))
        echo "project-local: $1 did not travel ($2) and the store has no earlier copy of it" >&2
      fi
    }
    # `|| [ -n "$REL" ]`: the manifest is written by hand, and a file whose last
    # line carries no newline would otherwise lose that path with no count and
    # no message - the silent blindness this whole capability exists to end.
    while IFS= read -r REL || [ -n "$REL" ]; do
      case "$REL" in
        '' | \#*) continue ;;
      esac
      if ! valid_relative_path "$REL"; then
        die "manifest line is not a safe relative path: $REL"
      fi
      if [ -L "$HOME_DIR/$REL" ]; then
        not_updated "$REL" "it is a symlink, so it is not transportable"
        continue
      fi
      if [ ! -e "$HOME_DIR/$REL" ]; then
        not_updated "$REL" "it is absent from the project's home"
        continue
      fi
      if [ -d "$HOME_DIR/$REL" ]; then
        NESTED=$(first_symlink "$HOME_DIR/$REL")
        if [ -n "$NESTED" ]; then
          not_updated "$REL" "it holds the symlink ${NESTED#"$HOME_DIR/"}, so it is not transportable"
          continue
        fi
      fi
      if ! copy_into_store "$NAME" "$HOME_DIR/$REL" "$MATERIAL/$REL"; then
        not_updated "$REL" "it could not be read in full from the project's home"
        continue
      fi
      UPDATED=$((UPDATED + 1))
    done <"$MANIFEST"
    if [ -s "$RECORD_NEW" ]; then
      mv -- "$RECORD_NEW" "$RECORD"
    else
      rm -f -- "$RECORD_NEW" "$RECORD"
    fi
    note_home_activity "$HOME_DIR"
    printf 'synced: %s from %s (%s paths updated, %s kept from an earlier sync and marked UNVERIFIED, %s with nothing to carry)\n' \
      "$NAME" "$HOME_DIR" "$UPDATED" "$KEPT" "$NOTHING"
    if [ "$HOME_ACTIVE" -eq 1 ]; then
      printf 'warning: %s was being worked in while this copy was taken, so a file may have been caught mid-write; re-run sync once it is quiet if anything looks truncated\n' "$HOME_DIR" >&2
    elif [ "$HOME_ACTIVITY_UNKNOWN" -eq 1 ]; then
      # shellcheck disable=SC2016 # Backticks quote the command in the warning text, not a command substitution.
      printf 'warning: could not determine whether %s was in use while this copy was taken (the activity check failed); check it with `fm-project-memory.sh activity --home %s` and re-run sync if anything looks truncated\n' "$HOME_DIR" "$HOME_DIR" >&2
    fi
    ;;
  stage)
    NAME=${1:-}
    WT=${2:-}
    [ -n "$NAME" ] && [ -n "$WT" ] || die "usage: stage <project> <worktree>"
    # A project whose directory name cannot address a store can never have one,
    # so staging is a no-op rather than a refusal. Every spawn calls this, and a
    # project named outside the store's own character set must not lose the
    # ability to be worked at all over material it does not have.
    if ! valid_project_name "$NAME"; then
      exit 0
    fi
    stage_material "$NAME" "$WT"
    ;;
  *)
    die "unknown command: $CMD (try --help)"
    ;;
esac

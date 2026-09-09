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
#   fm-project-local.sh add <project> <file-or-dir> [--as <relative-path>]
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
#
# `stage` is the spawn-time step, called by bin/fm-spawn.sh once a task copy is
# known to be isolated. It is idempotent and self-cleaning: a pool slot reused by
# a later task never keeps the previous task's staged material, whether or not
# this task stages any of its own. It refuses rather than staging when the destination is a
# tracked path, and after copying it verifies that git reports nothing under the
# destination - a staged store git can still see is removed and the spawn fails,
# because a worker cannot be told not to commit something git is offering it.
# The destination is added to the repository's exclude file, the same mechanism
# fm-spawn already uses for the per-task harness files it writes into a copy.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STORE_ROOT="$DATA/project-local"

# The single name of the staged directory inside a task copy. Everything that
# reads or excludes it derives from this constant.
STAGE_DIR_NAME='.fm-local'

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
# is later written into, so the same test gates `add --as`, `remove`, and every
# manifest line.
valid_relative_path() {  # <path>
  case "$1" in
    '' | /* | -*) return 1 ;;
    *[[:cntrl:]]*) return 1 ;;
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

require_project() {  # <project>
  valid_project_name "$1" || die "invalid project name: $1"
}

# A symlink in the store would resolve against whatever the task copy happens to
# contain, so the store holds regular files and directories only. Checked when
# material enters the store and again before it is staged.
refuse_symlinks() {  # <dir>
  local found
  found=$(find "$1" -type l -print -quit 2>/dev/null || true)
  [ -z "$found" ] || die "refusing symlink in the local material store: $found"
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

# The note that travels with the material into every task copy. It is the
# worker-facing half of the contract; the exclude entry and the post-stage
# verification below are the half that does not depend on the worker reading it.
stage_readme() {  # <project>
  cat <<EOF
# Local material - $1

Firstmate placed this directory here at spawn time. It carries project knowledge
that is deliberately NOT in the repository: material that belongs to someone
else, holds real client data, is machine-specific, or lives only in the checkout
this project is actually worked in.

Read it. Never commit it, never copy its contents into a tracked file, and never
quote its raw contents into a PR, an issue, or any other outward-facing surface.
It is excluded from this repository, and this whole directory disappears with the
task copy.

If something in here should become part of the project, say so in your report or
status line and let firstmate take the decision to the captain.
EOF
}

stage_material() {  # <project> <worktree>
  local project=$1 wt=$2 material dest excl seen empty=0
  material=$(material_dir "$project")
  if [ ! -d "$material" ] ||
    [ -z "$(find "$material" -mindepth 1 -print -quit 2>/dev/null || true)" ]; then
    empty=1
  else
    refuse_symlinks "$material"
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
  if [ -e "$wt/$STAGE_DIR_NAME" ]; then
    chmod -R u+w "$wt/$STAGE_DIR_NAME" 2>/dev/null || true
    rm -rf -- "${wt:?}/$STAGE_DIR_NAME"
  fi
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
  (cd "$material" && tar cf - .) | (cd "$dest" && tar xf -) || die "could not stage local material into $dest"
  stage_readme "$project" >"$dest/README.md"
  find "$dest" -type f -exec chmod 0444 {} + 2>/dev/null || true

  # The mechanism, not the instruction: if git can still see anything under the
  # staged directory, a worker could commit it, so the material is removed again
  # and the caller is refused rather than launched.
  seen=$(git -C "$wt" status --porcelain --untracked-files=all -- "$STAGE_DIR_NAME" 2>/dev/null || true)
  if [ -n "$seen" ]; then
    chmod -R u+w "$dest" 2>/dev/null || true
    rm -rf -- "$dest"
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
    [ -n "$NAME" ] && [ -n "$SRC" ] || die "usage: add <project> <file-or-dir> [--as <relative-path>]"
    require_project "$NAME"
    shift 2
    AS=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --as)
          [ "$#" -gt 1 ] || die "--as requires a relative path"
          AS=$2
          shift 2
          ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [ -e "$SRC" ] || die "no such file or directory: $SRC"
    [ -L "$SRC" ] && die "refusing to add a symlink: $SRC"
    [ -z "$AS" ] && AS=$(basename "$SRC")
    valid_relative_path "$AS" || die "invalid destination path: $AS"
    MATERIAL=$(material_dir "$NAME")
    mkdir -p "$MATERIAL/$(dirname "$AS")"
    if [ -d "$SRC" ]; then
      rm -rf -- "${MATERIAL:?}/$AS"
      mkdir -p "$MATERIAL/$AS"
      (cd "$SRC" && tar cf - .) | (cd "$MATERIAL/$AS" && tar xf -) || die "could not copy $SRC"
    else
      cp -- "$SRC" "$MATERIAL/$AS" || die "could not copy $SRC"
    fi
    chmod -R u+w "$MATERIAL/$AS" 2>/dev/null || true
    refuse_symlinks "$MATERIAL"
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
    chmod -R u+w "$MATERIAL/$REL" 2>/dev/null || true
    rm -rf -- "${MATERIAL:?}/$REL"
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
    COPIED=0
    MISSING=0
    while IFS= read -r REL; do
      case "$REL" in
        '' | \#*) continue ;;
      esac
      if ! valid_relative_path "$REL"; then
        die "manifest line is not a safe relative path: $REL"
      fi
      if [ -L "$HOME_DIR/$REL" ]; then
        echo "project-local: skipping symlink $REL" >&2
        continue
      fi
      if [ ! -e "$HOME_DIR/$REL" ]; then
        echo "project-local: manifest path absent in $HOME_DIR: $REL" >&2
        MISSING=$((MISSING + 1))
        continue
      fi
      mkdir -p "$MATERIAL/$(dirname "$REL")"
      if [ -d "$HOME_DIR/$REL" ]; then
        chmod -R u+w "${MATERIAL:?}/$REL" 2>/dev/null || true
        rm -rf -- "${MATERIAL:?}/$REL"
        mkdir -p "$MATERIAL/$REL"
        (cd "$HOME_DIR/$REL" && tar cf - .) | (cd "$MATERIAL/$REL" && tar xf -) || die "could not copy $REL"
      else
        cp -- "$HOME_DIR/$REL" "$MATERIAL/$REL" || die "could not copy $REL"
      fi
      chmod -R u+w "$MATERIAL/$REL" 2>/dev/null || true
      COPIED=$((COPIED + 1))
    done <"$MANIFEST"
    refuse_symlinks "$MATERIAL"
    note_home_activity "$HOME_DIR"
    printf 'synced: %s from %s (%s paths copied, %s absent)\n' "$NAME" "$HOME_DIR" "$COPIED" "$MISSING"
    if [ "$HOME_ACTIVE" -eq 1 ]; then
      printf 'warning: %s was being worked in while this copy was taken, so a file may have been caught mid-write; re-run sync once it is quiet if anything looks truncated\n' "$HOME_DIR" >&2
    elif [ "$HOME_ACTIVITY_UNKNOWN" -eq 1 ]; then
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

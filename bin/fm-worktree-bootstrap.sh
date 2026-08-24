#!/usr/bin/env bash
# fm-worktree-bootstrap.sh - fill a task worktree's untracked dev environment
# from this firstmate home's own clone of the same project.
#
# WHY THIS EXISTS
#   `git worktree add` checks out TRACKED files only. Untracked dev material -
#   local secrets (.dev.vars, .env) and local database state (.wrangler's
#   miniflare D1) - never comes along, so the app either will not start or
#   starts against whatever stale state a reused pool worktree still holds.
#
# WHAT IT DOES
#   Copies the project's declared untracked dev paths from the home's own
#   clone of that project into the task worktree, always overwriting file by
#   file, and never writes anything back to the source clone. The source is
#   $FM_HOME/projects/<worktree-name> - the same single source of project
#   material bin/fm-spawn.sh provisions from (bin/fm-worktree-runtime-lib.sh)
#   - so a project with no clone in this home is a silent no-op rather than a
#     new configuration surface.
#
# WHAT TO COPY
#   The repository's own `.worktreeinclude`, one repo-relative path per line,
#   `#` comments allowed. Absent = this project declares no dev material, so
#   the tool is a silent no-op. The project declares its needs; firstmate
#   decides where they come from. Neither side hardcodes the other.
#
# CONTRACT
#   Copies what exists; skips what does not silently; warns on copy failure
#   without failing the task (best-effort, like every provisioning copy step);
#   refuses an unsafe declaration path loudly. There is deliberately NO
#   deletion path: copies overwrite destination files in place, stale extra
#   files are left for teardown to discard with the whole worktree, so nothing
#   here can destroy material the worker or a previous occupant created.
#
# USAGE
#   bin/fm-worktree-bootstrap.sh                 run from inside the worktree
#   bin/fm-worktree-bootstrap.sh <worktree-dir>  or name it explicitly
#
#   FM_HOME resolves exactly like every other firstmate script: an explicit
#   FM_HOME wins, else FM_ROOT_OVERRIDE, else this checkout's root.
#
# EXIT
#   0 on success and on every no-op and best-effort warning (missing config,
#   missing declaration, missing source project, individual copy failures).
#   A worker running this in an unrelated repository must not be blocked by it.
#   Non-zero only for malformed input it refuses to act on: a bad directory
#   argument, a path outside git, or an unsafe path inside .worktreeinclude.
set -euo pipefail

log() { printf '[fm-worktree-bootstrap] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

WT="${1:-$PWD}"
[ -d "$WT" ] || die "not a directory: $WT"
WT=$(cd "$WT" && git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository: ${1:-$PWD}"
WT=$(cd "$WT" && pwd -P)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

PROJECT=$(basename "$WT")
SRC="$FM_HOME/projects/$PROJECT"
if [ ! -d "$SRC" ]; then
  log "no project clone for '$PROJECT' under $FM_HOME/projects - nothing to copy (this is normal)"
  exit 0
fi
SRC=$(cd "$SRC" && pwd -P)

if [ "$SRC" = "$WT" ]; then
  log "this IS the project clone - refusing to copy onto itself"
  exit 0
fi

DECL="$WT/.worktreeinclude"
if [ ! -f "$DECL" ]; then
  log "$PROJECT declares no .worktreeinclude - nothing to copy"
  exit 0
fi

log "from: $SRC"
log "into: $WT"

copied=0
missing=0
failed=0

# Copy one declared entry file by file: cp -p overwrites each existing
# destination file in place, so a fresh copy always replaces recycled content
# without any rm of what is already there. A missing source is a silent skip;
# a failure to create a directory or copy a file is a stderr warning only.
copy_entry() {  # <src-path> <dst-path> <declared-rel>
  local src=$1 dst=$2 rel=$3 f destfile destdir
  if [ ! -d "$src" ]; then
    destdir=$(dirname "$dst")
    if ! mkdir -p "$destdir" 2>/dev/null; then
      echo "warning: fm-worktree-bootstrap: could not create directory $destdir for '$rel'" >&2
      return 1
    fi
    if ! cp -p "$src" "$dst" 2>/dev/null; then
      echo "warning: fm-worktree-bootstrap: failed to copy '$src' of '$rel' into $dst" >&2
      return 1
    fi
    return 0
  fi
  local list ok=1 readable=1
  list=$(mktemp "${TMPDIR:-/tmp}/fm-wt-boot.XXXXXX") || {
    echo "warning: fm-worktree-bootstrap: could not create a scratch file for '$rel'" >&2
    return 1
  }
  find -L "$src" -type f -print0 >"$list" 2>/dev/null || readable=0
  while IFS= read -r -d '' f; do
    # For a bare-file entry <dst> already names the destination file itself,
    # and find echoes exactly that source path; anything deeper keeps its
    # path below the declared entry.
    if [ "$f" = "$src" ]; then
      destfile=$dst
    else
      destfile=$dst/${f#"$src"/}
    fi
    destdir=$(dirname "$destfile")
    if ! mkdir -p "$destdir" 2>/dev/null; then
      echo "warning: fm-worktree-bootstrap: could not create directory $destdir for '$rel'" >&2
      ok=0
      break
    fi
    if ! cp -p "$f" "$destfile" 2>/dev/null; then
      echo "warning: fm-worktree-bootstrap: failed to copy '$f' of '$rel' into $dst" >&2
      ok=0
      break
    fi
  done <"$list"
  rm -f "$list"
  [ "$ok" -eq 1 ] || return 1
  if [ "$readable" -eq 0 ]; then
    echo "warning: fm-worktree-bootstrap: could not read '$src' of '$rel', nothing copied from it" >&2
    return 1
  fi
  return 0
}

while IFS= read -r rel || [ -n "$rel" ]; do
  rel="${rel%%#*}"
  rel="$(printf '%s' "$rel" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$rel" ] || continue
  case "$rel" in
    /*|*..*) die "refusing unsafe path in .worktreeinclude: $rel" ;;
  esac
  norm=$rel
  while :; do
    case $norm in
      ./*) norm=${norm#./} ;;
      /) norm="" ;;
      */) norm=${norm%/} ;;
      *) break ;;
    esac
  done
  if [ -z "$norm" ] || [ "$norm" = "." ]; then
    die "refusing unsafe path in .worktreeinclude: $rel"
  fi

  src="$SRC/$rel"
  dst="$WT/$rel"
  if [ ! -e "$src" ]; then
    missing=$((missing + 1))
    continue
  fi
  # Always overwrite. A preserved leftover is exactly the failure this tool
  # exists to prevent, so there is deliberately no keep-if-present option -
  # and equally no removal: stale files the source no longer has stay until
  # teardown discards the worktree whole.
  if copy_entry "$src" "$dst" "$rel"; then
    copied=$((copied + 1))
  else
    failed=$((failed + 1))
  fi
done < "$DECL"

log "done - $copied entries copied, $missing absent in the project clone, $failed copy failures (warnings above)"
exit 0

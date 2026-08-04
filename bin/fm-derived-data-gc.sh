#!/usr/bin/env bash
# Garbage-collect Xcode DerivedData folders that belonged to a removed firstmate
# task worktree, or that are otherwise orphaned.
#
# Two modes:
#   --worktree <path>   Remove DerivedData dirs whose info.plist WorkspacePath is
#                       the given worktree path or lives under it. This is the
#                       mode bin/fm-teardown.sh uses after a task worktree has
#                       been returned/removed; it matches on WorkspacePath only
#                       and never touches no-plist dirs.
#   --orphans           Remove every DerivedData dir whose info.plist
#                       WorkspacePath no longer exists on disk. With
#                       --include-no-plist, also remove dirs that have no usable
#                       info.plist AND whose directory modification time is at
#                       least --no-plist-age-hours old (default 48). The age gate
#                       is mandatory for no-plist deletion: a fresh no-plist dir
#                       may belong to a build still in flight.
#
# Hard safety rules (from field incidents):
#   - NEVER delete the shared caches ModuleCache.noindex,
#     CompilationCache.noindex, SDKStatCaches.noindex, SymbolCache.noindex (any
#     *.noindex entry at the DerivedData root is skipped).
#   - NEVER delete a folder whose WorkspacePath resolves to a path that still
#     exists on disk, in either mode.
#   - A dir without a readable WorkspacePath is never deleted in --worktree
#     mode, and in --orphans mode only with --include-no-plist plus the age gate.
#
# The DerivedData root defaults to ~/Library/Developer/Xcode/DerivedData and can
# be overridden with FM_DERIVED_DATA_ROOT (tests use a fixture root).
# plutil is required to read WorkspacePath; without it nothing can be verified,
# so the script exits 0 having deleted nothing (fail safe).
#
# Usage: fm-derived-data-gc.sh (--worktree <path> | --orphans) [--dry-run]
#        [--include-no-plist] [--no-plist-age-hours <n>]
# Exit: 0 on success (including nothing to do), 1 if any removal failed,
#       2 on usage error.
set -eu

usage() {
  cat <<'EOF'
Usage: fm-derived-data-gc.sh (--worktree <path> | --orphans) [options]

Modes:
  --worktree <path>       remove DerivedData dirs whose info.plist WorkspacePath
                          equals or lives under <path> (teardown mode)
  --orphans               remove DerivedData dirs whose WorkspacePath no longer
                          exists on disk

Options:
  --include-no-plist      in --orphans mode, also remove dirs with no usable
                          info.plist that are at least --no-plist-age-hours old
  --no-plist-age-hours n  age gate for --include-no-plist (default: 48)
  --dry-run               print what would be removed without removing anything
  -h, --help              show this help

Environment:
  FM_DERIVED_DATA_ROOT    DerivedData root (default: ~/Library/Developer/Xcode/DerivedData)

Safety: never deletes *.noindex caches, never deletes a dir whose WorkspacePath
still exists, never deletes a no-plist dir without the explicit age gate.
EOF
}

MODE=
WORKTREE=
DRY_RUN=0
INCLUDE_NO_PLIST=0
NO_PLIST_AGE_HOURS=48

while [ "$#" -gt 0 ]; do
  case "$1" in
    --worktree)
      [ "$#" -ge 2 ] || { echo "error: --worktree requires a path" >&2; exit 2; }
      MODE=worktree
      WORKTREE=$2
      shift 2
      ;;
    --orphans)
      MODE=orphans
      shift
      ;;
    --include-no-plist)
      INCLUDE_NO_PLIST=1
      shift
      ;;
    --no-plist-age-hours)
      [ "$#" -ge 2 ] || { echo "error: --no-plist-age-hours requires a number" >&2; exit 2; }
      NO_PLIST_AGE_HOURS=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  worktree)
    [ -n "$WORKTREE" ] || { echo "error: --worktree requires a non-empty path" >&2; exit 2; }
    ;;
  orphans)
    ;;
  *)
    echo "error: one of --worktree <path> or --orphans is required" >&2
    usage >&2
    exit 2
    ;;
esac

case "$NO_PLIST_AGE_HOURS" in
  ''|*[!0-9]*)
    echo "error: --no-plist-age-hours must be a non-negative integer" >&2
    exit 2
    ;;
esac

ROOT="${FM_DERIVED_DATA_ROOT:-$HOME/Library/Developer/Xcode/DerivedData}"

if [ ! -d "$ROOT" ]; then
  # No DerivedData root (non-macOS host, or Xcode never ran): nothing to do.
  exit 0
fi

if ! command -v plutil >/dev/null 2>&1; then
  # Without plutil no WorkspacePath can be verified; delete nothing (fail safe).
  echo "warning: plutil not found; skipping DerivedData GC under $ROOT" >&2
  exit 0
fi

# Strip trailing slashes so prefix matching compares canonical directory paths.
strip_trailing_slashes() {
  local p=$1
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do
    p=${p%/}
  done
  printf '%s\n' "$p"
}

WORKTREE=$(strip_trailing_slashes "$WORKTREE")
NO_PLIST_AGE_SECS=$(( NO_PLIST_AGE_HOURS * 3600 ))
NOW=$(date +%s)

read_workspace_path() {
  plutil -extract WorkspacePath raw -o - "$1" 2>/dev/null
}

# Directory modification time in epoch seconds; BSD stat first, GNU fallback.
# Each probe's output is accepted only when it is a bare epoch. A failing probe
# can still write to stdout: GNU stat reads `-f` as "print filesystem status"
# and `%m` as a file operand, so it emits a multi-line filesystem summary and
# exits non-zero. Chaining that straight into the fallback would capture the
# summary concatenated with the epoch, and the caller's age arithmetic would
# then abort the run under `set -u`.
dir_mtime() {
  local candidate
  candidate=$(stat -f %m "$1" 2>/dev/null || true)
  case "$candidate" in
    ''|*[!0-9]*) candidate=$(stat -c %Y "$1" 2>/dev/null || true) ;;
  esac
  case "$candidate" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$candidate"
}

is_protected_cache() {
  case "$1" in
    ModuleCache.noindex|CompilationCache.noindex|SDKStatCaches.noindex|SymbolCache.noindex|*.noindex)
      return 0
      ;;
  esac
  return 1
}

FAILED=0

remove_dir() {
  local dir=$1 why=$2
  if [ "$DRY_RUN" = 1 ]; then
    printf 'would remove: %s (%s)\n' "$dir" "$why"
    return 0
  fi
  if rm -rf -- "$dir"; then
    printf 'removed: %s (%s)\n' "$dir" "$why"
  else
    echo "warning: failed to remove $dir" >&2
    FAILED=1
  fi
}

for entry in "$ROOT"/*; do
  [ -e "$entry" ] || continue
  base=${entry##*/}
  if is_protected_cache "$base"; then
    continue
  fi
  # Only real directories are GC candidates; skip files and symlinks.
  if [ ! -d "$entry" ] || [ -L "$entry" ]; then
    continue
  fi

  plist="$entry/info.plist"
  ws=
  if [ -f "$plist" ]; then
    ws=$(read_workspace_path "$plist" || true)
  fi
  if [ -n "$ws" ]; then
    ws=$(strip_trailing_slashes "$ws")
  fi

  if [ -n "$ws" ] && [ -e "$ws" ]; then
    # Hard rule: never delete a folder whose WorkspacePath still exists.
    continue
  fi

  if [ "$MODE" = worktree ]; then
    [ -n "$ws" ] || continue
    case "$ws" in
      "$WORKTREE"|"$WORKTREE"/*)
        remove_dir "$entry" "WorkspacePath $ws belonged to removed worktree $WORKTREE"
        ;;
    esac
  else
    if [ -n "$ws" ]; then
      remove_dir "$entry" "WorkspacePath $ws no longer exists"
    elif [ "$INCLUDE_NO_PLIST" = 1 ]; then
      mtime=$(dir_mtime "$entry" || true)
      if [ -n "$mtime" ] && [ $(( NOW - mtime )) -ge "$NO_PLIST_AGE_SECS" ]; then
        remove_dir "$entry" "no info.plist and older than ${NO_PLIST_AGE_HOURS}h"
      fi
    fi
  fi
done

exit "$FAILED"

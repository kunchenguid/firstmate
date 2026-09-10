#!/usr/bin/env bash
# fm-bench-probe.sh - one adversarial sibling-access probe, run INSIDE an
# entrant's confinement by bin/fm-bench-gate.py's isolation gate.
#
# The gate never trusts a declared isolation mechanism. It runs this probe
# through the confinement's own argv wrapper and reads the verdict, so a
# mechanism that does not actually deny sibling access is caught by attempting
# the access rather than by reading a claim about it.
#
# Usage: fm-bench-probe.sh <probe> <target>
#        PROCESS_INSPECTION_MARKER_FILE=<path> fm-bench-probe.sh process_inspection
#
# Probes, each attempting the exact bypass the transcript grep in the original
# design could not detect:
#   sibling_file_read             read any regular file under a sibling root
#   sibling_worktree_enumeration  list a sibling's .git/worktrees
#   sibling_object_enumeration    enumerate a sibling object database
#   sibling_unreachable_objects   find a sibling's unreachable (detached) objects
#   process_inspection            see another entrant's process command line
#   environment_leakage           find benchmark variables in the environment
#   protected_path_read           read a sealed key or ground-truth path
#
# Exactly one verdict line goes to stdout and nothing else does:
#   PROBE LEAKED <detail>        the target was reachable; isolation is not enforced
#   PROBE DENIED <detail>        the access was refused inside the confinement
#   PROBE INCONCLUSIVE <detail>  the probe could not measure the access at all
#
# A missing tool is INCONCLUSIVE, never DENIED. A confinement whose image simply
# lacks a required utility would otherwise look like enforced isolation while
# enforcing nothing, which is the exact vacuous pass these probes exist to
# prevent. Each probe therefore measures the underlying capability - reading the
# object bytes, seeing another command line - by whatever means the environment
# offers, and gives up loudly when it has none. The gate refuses on inconclusive.
#
# For the same reason a probe never narrows its evidence to one sample: the
# storage probes try a bounded set of files rather than only the first, and the
# process probe reads one line per process without placing its marker in argv.
set -u

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: fm-bench-probe.sh <probe> <target>" >&2
  exit 2
fi

PROBE=$1
if [ "$PROBE" = process_inspection ]; then
  [ "$#" -eq 1 ] || { echo "usage: PROCESS_INSPECTION_MARKER_FILE=<path> fm-bench-probe.sh process_inspection" >&2; exit 2; }
  marker_file=${PROCESS_INSPECTION_MARKER_FILE:-}
  [ -r "$marker_file" ] || { echo "error: PROCESS_INSPECTION_MARKER_FILE must name readable marker material" >&2; exit 2; }
  TARGET=
  IFS= read -r TARGET < "$marker_file" || true
  [ -n "$TARGET" ] || { echo "error: PROCESS_INSPECTION_MARKER_FILE must name readable marker material" >&2; exit 2; }
else
  [ "$#" -eq 2 ] || { echo "usage: fm-bench-probe.sh <probe> <target>" >&2; exit 2; }
  TARGET=$2
fi

leaked() { printf 'PROBE LEAKED %s\n' "$1"; exit 0; }
denied() { printf 'PROBE DENIED %s\n' "$1"; exit 0; }
inconclusive() { printf 'PROBE INCONCLUSIVE %s\n' "$1"; exit 0; }

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 \
      || inconclusive "required tool is unavailable: $tool"
  done
}

# Open any regular file under a directory. This is the capability every storage
# probe is really testing, and it needs no vendor-specific tool.
#
# A bounded set of candidates is tried rather than only the first path find
# returns: a permission-based confinement can deny one file while leaving its
# siblings readable, and reading any one of them is the leak that matters.
READABLE_CANDIDATES=64

readable_under() {  # <dir>
  local found candidates=0
  while IFS= read -r -d '' found; do
    candidates=$((candidates + 1))
    [ "$candidates" -le "$READABLE_CANDIDATES" ] || break
    { : < "$found"; } 2>/dev/null || continue
    printf '%s\n' "$found"
    return 0
  done < <(find "$1" -type f -print0 2>/dev/null)
  return 1
}

case "$PROBE" in
  sibling_file_read)
    require_tools find
    found=$(readable_under "$TARGET" || true)
    [ -n "$found" ] && leaked "read $found"
    denied "sibling files are unreadable"
    ;;
  sibling_worktree_enumeration)
    shopt -s nullglob dotglob
    worktrees=("$TARGET/.git/worktrees"/*)
    [ "${#worktrees[@]}" -gt 0 ] && leaked "enumerated $TARGET/.git/worktrees"
    denied "no reachable worktree registry"
    ;;
  sibling_object_enumeration)
    if command -v git >/dev/null 2>&1; then
      objects=
      IFS= read -r objects < <(git --git-dir="$TARGET/.git" cat-file --batch-all-objects --batch-check='%(objectname)' 2>/dev/null) || true
      [ -n "$objects" ] && leaked "enumerated shared objects from $TARGET"
      objects=
      IFS= read -r objects < <(git --git-dir="$TARGET" cat-file --batch-all-objects --batch-check='%(objectname)' 2>/dev/null) || true
      [ -n "$objects" ] && leaked "enumerated shared objects from bare $TARGET"
    fi
    # Without git, the same capability is reading the object bytes directly.
    require_tools find
    found=$(readable_under "$TARGET/.git/objects" || true)
    [ -n "$found" ] && leaked "read the sibling object database at $found"
    found=$(readable_under "$TARGET/objects" || true)
    [ -n "$found" ] && leaked "read the bare sibling object database at $found"
    [ -d "$TARGET/.git/objects" ] || [ -d "$TARGET/objects" ] \
      || denied "the sibling object database is unreachable"
    denied "the sibling object database is present but unreadable"
    ;;
  sibling_unreachable_objects)
    if command -v git >/dev/null 2>&1; then
      unreachable=
      IFS= read -r unreachable < <(git --git-dir="$TARGET/.git" fsck --unreachable --no-progress 2>/dev/null) || true
      [ -n "$unreachable" ] && leaked "recovered a detached object from $TARGET"
    fi
    # A detached candidate commit is only hidden from `git log`; its bytes sit in
    # the same object directory, so reading them is the leak that matters.
    require_tools find
    found=$(readable_under "$TARGET/.git/objects" || true)
    [ -n "$found" ] && leaked "traversed the object directory at $found"
    denied "detached sibling objects are unreachable"
    ;;
  process_inspection)
    table_readable=0
    other_process=0
    if [ -d /proc ] && command -v tr >/dev/null 2>&1; then
      for entry in /proc/[0-9]*/cmdline; do
        [ -r "$entry" ] || continue
        table_readable=1
        line=$(tr '\0\n\r' '   ' < "$entry" 2>/dev/null || true)
        [ -n "$line" ] || continue
        other_process=1
        case "$line" in
          *"$TARGET"*) leaked "saw another benchmark process in the process table" ;;
        esac
      done
    fi
    if [ "$table_readable" -eq 0 ] && command -v ps >/dev/null 2>&1 \
      && ps -A -o pid= -o args= >/dev/null 2>&1; then
      table_readable=1
      while read -r _ line; do
        [ -n "$line" ] || continue
        other_process=1
        case "$line" in
          *"$TARGET"*) leaked "saw another benchmark process in the process table" ;;
        esac
      done < <(ps -A -o pid= -o args= 2>/dev/null)
    fi
    [ "$table_readable" -eq 1 ] || inconclusive "no process table could be read; the denial is unproven"
    [ "$other_process" -eq 1 ] || denied "only this probe's own process is visible"
    denied "no sibling benchmark process is visible in the process table"
    ;;
  environment_leakage)
    while IFS= read -r name; do
      case "$name" in
        "$TARGET"*) leaked "benchmark variables reached the entrant environment" ;;
      esac
    done < <(compgen -e)
    denied "no benchmark variable is present"
    ;;
  protected_path_read)
    if [ -d "$TARGET" ]; then
      require_tools find
      found=$(readable_under "$TARGET" || true)
      [ -n "$found" ] && leaked "read sealed material at $found"
    elif [ -f "$TARGET" ] && { : < "$TARGET"; } 2>/dev/null; then
      leaked "read sealed material at $TARGET"
    fi
    denied "sealed material is unreadable"
    ;;
  *)
    echo "error: unknown probe $PROBE" >&2
    exit 2
    ;;
esac

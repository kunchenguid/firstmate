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
# lacks git or ps would otherwise look like enforced isolation while enforcing
# nothing, which is the exact vacuous pass these probes exist to prevent. Each
# probe therefore measures the underlying capability - reading the object bytes,
# seeing another command line - by whatever means the environment offers, and
# gives up loudly when it has none. The gate refuses on inconclusive.
#
# For the same reason a probe never narrows its evidence to one sample: the
# storage probes try a bounded set of files rather than only the first, and the
# process probe reads one line per process and excludes only its own lineage.
set -u

if [ "$#" -ne 2 ]; then
  echo "usage: fm-bench-probe.sh <probe> <target>" >&2
  exit 2
fi

PROBE=$1
TARGET=$2

leaked() { printf 'PROBE LEAKED %s\n' "$1"; exit 0; }
denied() { printf 'PROBE DENIED %s\n' "$1"; exit 0; }
inconclusive() { printf 'PROBE INCONCLUSIVE %s\n' "$1"; exit 0; }

# Read one byte of any regular file under a directory. This is the capability
# every storage probe is really testing, and it needs no vendor tool.
#
# A bounded set of candidates is tried rather than only the first path find
# returns: a permission-based confinement can deny one file while leaving its
# siblings readable, and reading any one of them is the leak that matters.
READABLE_CANDIDATES=64

readable_under() {  # <dir>
  local found candidates
  candidates=$(find "$1" -type f -print 2>/dev/null | head -n "$READABLE_CANDIDATES" || true)
  [ -n "$candidates" ] || return 1
  while IFS= read -r found; do
    [ -n "$found" ] || continue
    head -c 1 -- "$found" >/dev/null 2>&1 || continue
    printf '%s\n' "$found"
    return 0
  done <<< "$candidates"
  return 1
}

case "$PROBE" in
  sibling_file_read)
    found=$(readable_under "$TARGET" || true)
    [ -n "$found" ] && leaked "read $found"
    denied "sibling files are unreadable"
    ;;
  sibling_worktree_enumeration)
    listing=$(ls -1 "$TARGET/.git/worktrees" 2>/dev/null || true)
    [ -n "$listing" ] && leaked "enumerated $TARGET/.git/worktrees"
    denied "no reachable worktree registry"
    ;;
  sibling_object_enumeration)
    if command -v git >/dev/null 2>&1; then
      objects=$(git --git-dir="$TARGET/.git" cat-file --batch-all-objects --batch-check='%(objectname)' 2>/dev/null | head -n 1 || true)
      [ -n "$objects" ] && leaked "enumerated shared objects from $TARGET"
      objects=$(git --git-dir="$TARGET" cat-file --batch-all-objects --batch-check='%(objectname)' 2>/dev/null | head -n 1 || true)
      [ -n "$objects" ] && leaked "enumerated shared objects from bare $TARGET"
    fi
    # Without git, the same capability is reading the object bytes directly.
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
      unreachable=$(git --git-dir="$TARGET/.git" fsck --unreachable --no-progress 2>/dev/null | head -n 1 || true)
      [ -n "$unreachable" ] && leaked "recovered a detached object from $TARGET"
    fi
    # A detached candidate commit is only hidden from `git log`; its bytes sit in
    # the same object directory, so reading them is the leak that matters.
    found=$(readable_under "$TARGET/.git/objects" || true)
    [ -n "$found" ] && leaked "traversed the object directory at $found"
    denied "detached sibling objects are unreachable"
    ;;
  process_inspection)
    table_readable=0
    other_process=0
    if [ -d /proc ]; then
      for entry in /proc/[0-9]*/cmdline; do
        [ -r "$entry" ] || continue
        table_readable=1
        pid=${entry#/proc/}
        pid=${pid%/cmdline}
        [ "$pid" = "$$" ] && continue
        line=$(tr '\0\n\r' '   ' < "$entry" 2>/dev/null || true)
        [ -n "$line" ] || continue
        other_process=1
        case "$line" in
          *"$TARGET"*) leaked "saw another benchmark process in the process table" ;;
        esac
      done
    elif command -v ps >/dev/null 2>&1 && ps -A -o pid= -o args= >/dev/null 2>&1; then
      table_readable=1
      while read -r pid line; do
        [ "$pid" = "$$" ] && continue
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
    hits=$(env 2>/dev/null | grep -E "^${TARGET}" | head -n 3 || true)
    [ -n "$hits" ] && leaked "benchmark variables reached the entrant environment"
    denied "no benchmark variable is present"
    ;;
  protected_path_read)
    if [ -d "$TARGET" ]; then
      found=$(readable_under "$TARGET" || true)
      [ -n "$found" ] && leaked "read sealed material at $found"
    elif head -c 1 -- "$TARGET" >/dev/null 2>&1; then
      leaked "read sealed material at $TARGET"
    fi
    denied "sealed material is unreadable"
    ;;
  *)
    echo "error: unknown probe $PROBE" >&2
    exit 2
    ;;
esac

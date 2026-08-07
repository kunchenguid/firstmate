#!/usr/bin/env bash
# fm-workspace-busy.sh - advisory, read-only check: does this directory look
# actively mid-work right now?
#
# WHY: A verifier that reads a tree while a writer is mid-edit can report
# confident nonsense from half-written files. This check lets a reader stand
# down and wait, or report "someone is working here", instead of trusting a
# momentarily inconsistent record.
#
# HONEST BOUNDARY: ADVISORY ONLY.
# Every agent on a shared Mac typically runs as the same OS user, so nothing
# here can prevent another process from writing, and a quiet result is not
# exclusive access. This protects against reading mid-write; it does not lock,
# serialize, or exclude a determined or ignorant writer. Never describe this
# tool as a lock or a guarantee of exclusive use.
#
# This script never writes anywhere: no lock file, no marker, no state, no
# temp file under the target tree. It only reads git metadata, file mtimes,
# and (when requested) process working directories.
#
# CHECKS, in order (first match wins and prints one short reason line):
#   1. A git operation in progress (index.lock, MERGE_HEAD, REBASE_HEAD, ...)
#   2. Uncommitted changes in the working tree (git status --porcelain)
#   3. A recent non-ignored file mtime within --window seconds (default 180)
#   4. Optional (--process): a live process whose cwd is inside the tree,
#      via one bounded `lsof -a -d cwd` scan (same approach as fm-teardown).
#      Off by default so a reader whose own shell sits in the tree is not
#      counted as foreign activity. Requires lsof; when lsof is absent the
#      process check is skipped and documented as unavailable, not half-done.
#
# Performance: does not walk the whole tree naively. Dirty and lock checks use
# git (index-backed). The mtime scan iterates only paths git reports as tracked
# or untracked-and-not-ignored (`git ls-files --cached --others --exclude-standard`),
# so ignored bulk (caches, build products) never contributes cost or a false
# busy. Measured cost lives in docs/workspace-busy.md.
#
# CONTRACT:
#   stdout: one short reason line when busy; empty when quiet
#   exit 0: looks quiet
#   exit 1: looks busy (reason on stdout)
#   exit 2: usage error (bad args, missing path, not a directory, not a git work tree)
#
# Usage:
#   fm-workspace-busy.sh <dir> [--window SECS] [--process] [--no-process]
#   fm-workspace-busy.sh -h | --help
#
# Flags:
#   --window SECS   recent-mtime window (default: FM_WORKSPACE_BUSY_WINDOW_SECS or 180)
#   --process       also treat a foreign live cwd under <dir> as busy
#   --no-process    explicit default: skip the process scan
set -eu

usage() {
  cat <<'EOF' >&2
usage: fm-workspace-busy.sh <dir> [--window SECS] [--process] [--no-process]

Advisory, read-only: print one short reason line and exit 1 when <dir> looks
mid-work; print nothing and exit 0 when it looks quiet; exit 2 on usage errors
(missing path, not a directory, not a git work tree).

This is not a lock. Same-user agents can still write at any time.

  --window SECS   recent-mtime window (default 180, or FM_WORKSPACE_BUSY_WINDOW_SECS)
  --process       also scan for a live process cwd under <dir> (needs lsof)
  --no-process    skip the process scan (default)
EOF
}

DIR=
WINDOW=${FM_WORKSPACE_BUSY_WINDOW_SECS:-180}
WANT_PROCESS=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --window)
      shift
      [ $# -gt 0 ] || { echo "error: --window needs a seconds argument" >&2; exit 2; }
      WINDOW=$1
      shift
      ;;
    --process)
      WANT_PROCESS=1
      shift
      ;;
    --no-process)
      WANT_PROCESS=0
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [ -n "$DIR" ]; then
        echo "error: unexpected argument: $1" >&2
        usage
        exit 2
      fi
      DIR=$1
      shift
      ;;
  esac
done

if [ $# -gt 0 ]; then
  echo "error: unexpected argument: $1" >&2
  usage
  exit 2
fi

[ -n "$DIR" ] || { usage; exit 2; }

case "$WINDOW" in
  ''|*[!0-9]*)
    echo "error: --window must be a non-negative integer (seconds), got: $WINDOW" >&2
    exit 2
    ;;
esac

if [ ! -e "$DIR" ]; then
  echo "error: path does not exist: $DIR" >&2
  exit 2
fi
if [ ! -d "$DIR" ]; then
  echo "error: not a directory: $DIR" >&2
  exit 2
fi

# Resolve to a physical path so later prefix checks are stable. Read-only.
if ! DIR=$(cd "$DIR" && pwd -P); then
  echo "error: cannot resolve directory: $DIR" >&2
  exit 2
fi

if ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not a git work tree: $DIR" >&2
  exit 2
fi

# Work-tree root (physical) for path reporting and cwd prefix checks.
ROOT=$(git -C "$DIR" rev-parse --show-toplevel) || {
  echo "error: not a git work tree: $DIR" >&2
  exit 2
}
ROOT=$(cd "$ROOT" && pwd -P) || {
  echo "error: cannot resolve work tree root: $DIR" >&2
  exit 2
}

busy() {
  # One short reason line on stdout; exit 1.
  printf '%s\n' "$1"
  exit 1
}

# Resolve a `git rev-parse --git-path` result to an absolute path. Git often
# returns a relative spelling such as `.git/index.lock`; without this, a
# caller whose cwd is not the work tree would miss in-progress markers.
abs_git_path() {
  local p=$1
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s/%s' "$DIR" "$p" ;;
  esac
}

# --- 1. git operation in progress -------------------------------------------
# Named markers git leaves while a multi-step operation holds the repo.
# Paths come from `git rev-parse --git-path` so linked worktrees resolve
# correctly (index.lock may live under .git/worktrees/<name>/).

git_ops_markers=(
  index.lock
  MERGE_HEAD
  CHERRY_PICK_HEAD
  REVERT_HEAD
  REBASE_HEAD
  BISECT_LOG
  AUTO_MERGE
  rebase-merge
  rebase-apply
  sequencer/todo
)

for marker in "${git_ops_markers[@]}"; do
  path=$(git -C "$DIR" rev-parse --git-path "$marker" 2>/dev/null) || continue
  path=$(abs_git_path "$path")
  if [ -e "$path" ]; then
    busy "git operation in progress ($marker)"
  fi
done

# --- 2. uncommitted changes -------------------------------------------------
# Porcelain is index-backed and skips ignored paths by design.
if [ -n "$(git -C "$DIR" status --porcelain --untracked-files=normal 2>/dev/null | head -1)" ]; then
  busy "uncommitted changes"
fi

# --- 3. recent non-ignored file mtime ---------------------------------------
# Iterate only paths git cares about: tracked files and untracked files that
# are not ignored. Never walks ignored bulk directories.
#
# A per-file `stat` fork is too slow on multi-thousand-file trees (tens of
# seconds). Prefer one python3 process over the null-delimited path list; fall
# back to a pure-shell loop only when python3 is absent.

now=$(date +%s)
# WINDOW=0 means "only future or exact-now mtimes count"; still valid.
cutoff=$((now - WINDOW))

file_mtime() {
  # Portable epoch seconds. Prefer BSD stat (macOS), then GNU.
  local f=$1 m
  if m=$(stat -f %m "$f" 2>/dev/null); then
    printf '%s' "$m"
    return 0
  fi
  if m=$(stat -c %Y "$f" 2>/dev/null); then
    printf '%s' "$m"
    return 0
  fi
  return 1
}

recent_rel=
if command -v python3 >/dev/null 2>&1; then
  # Prints the first relative path with mtime >= cutoff, or nothing.
  # Exit 0 always from python; empty stdout means no recent non-ignored file.
  recent_rel=$(
    git -C "$DIR" ls-files -z --cached --others --exclude-standard 2>/dev/null \
      | FM_WB_ROOT="$ROOT" FM_WB_CUTOFF="$cutoff" python3 -c '
import os, sys
root = os.environ["FM_WB_ROOT"]
cutoff = float(os.environ["FM_WB_CUTOFF"])
data = sys.stdin.buffer.read().split(b"\0")
enc = sys.getfilesystemencoding() or "utf-8"
for raw in data:
    if not raw:
        continue
    rel = raw.decode(enc, "surrogateescape")
    path = os.path.join(root, rel)
    try:
        st = os.stat(path)
    except OSError:
        continue
    if not os.path.isfile(path):
        continue
    if st.st_mtime >= cutoff:
        sys.stdout.write(rel)
        break
'
  ) || recent_rel=
else
  # Slow path: one stat(1) per path. Acceptable on small trees only.
  while IFS= read -r -d '' rel; do
    [ -n "$rel" ] || continue
    full="$ROOT/$rel"
    [ -f "$full" ] || continue
    mtime=$(file_mtime "$full") || continue
    case "$mtime" in ''|*[!0-9]*) continue ;; esac
    if [ "$mtime" -ge "$cutoff" ]; then
      recent_rel=$rel
      break
    fi
  done < <(git -C "$DIR" ls-files -z --cached --others --exclude-standard 2>/dev/null)
fi

if [ -n "${recent_rel:-}" ]; then
  busy "recent write: $recent_rel"
fi

# --- 4. optional live process cwd -------------------------------------------
# Same bounded system-wide scan fm-teardown uses (lsof -a -d cwd), never the
# recursive +D tree walk. Excludes this script's own pid. When lsof is missing
# or the scan fails, skip rather than invent a half-answer.

if [ "$WANT_PROCESS" -eq 1 ]; then
  if ! command -v lsof >/dev/null 2>&1; then
    # Availability is documented; quiet is still a valid advisory result for
    # the checks that did run. Do not pretend a process scan happened.
    :
  else
    # lsof -Fpn: p<pid>, fcwd, n<path> records. Failures skip the check.
    if out=$(lsof -a -d cwd -Fpn 2>/dev/null); then
      pid=
      while IFS= read -r line; do
        case "$line" in
          p*)
            pid=${line#p}
            case "$pid" in ''|*[!0-9]*) pid= ;; esac
            ;;
          n*)
            [ -n "$pid" ] || continue
            [ "$pid" = "$$" ] && continue
            path=${line#n}
            case "$path" in
              "$ROOT"|"$ROOT"/*)
                busy "live process cwd under tree (pid $pid)"
                ;;
            esac
            ;;
        esac
      done <<EOF
$out
EOF
    fi
  fi
fi

# Quiet: no stdout, exit 0.
exit 0

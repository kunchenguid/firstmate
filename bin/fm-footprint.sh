#!/usr/bin/env bash
# fm-footprint.sh - one machine's footprint: report, close-time task cleanup,
# shared-cache cap, old task-folder preview, and the daily pass. No model is
# ever called.
#
# Usage:
#   fm-footprint.sh report [--json] [--days N]
#   fm-footprint.sh task-close <task-id> <scratch-dir> [<project>]
#   fm-footprint.sh caches [--json]
#   fm-footprint.sh trim-caches [--dry-run]
#   fm-footprint.sh old-tasks [--days N]
#   fm-footprint.sh old-tasks --apply <preview-id>
#   fm-footprint.sh sweep [--dry-run]
#   fm-footprint.sh owns-scratch <task-id> <scratch-dir>
#   fm-footprint.sh check | arm | disarm
#   fm-footprint.sh --help
#
# Every command takes only the flags shown: anything else, including a flag
# in a position that takes a task id or path, exits 2 before anything is read
# or removed, and -h or --help anywhere prints this help and does nothing else.
#
# Settings come from the optional config/footprint (docs/configuration.md
# "Footprint" owns its keys and defaults); bin/fm-footprint-lib.sh owns the
# scratch layout and the Docker label set.
#
# report
#   Read-only. Prints this machine's footprint in one page, or one JSON
#   document (schema fm-footprint-report.v1) with --json:
#   - platform (macOS, Linux, or Linux under WSL, read from /proc/version) and
#     free disk on the filesystem holding this home;
#   - disk by kind: this home's records and evidence (data/, with its three
#     largest task folders), this home's task scratch areas and how many have
#     no live task, other homes' scratch on this machine, per-task temp roots
#     (/tmp/fm-*), and the system temp directories;
#   - Docker: "not present" when the CLI is absent or the daemon does not
#     answer, else docker system df by type plus the containers and volumes
#     labelled for this home, and on macOS the Docker disk image's size on disk
#     (FM_FOOTPRINT_DOCKER names the client for every command here: unset is
#     `docker` on PATH, empty is absent, which tests/lib.sh sets);
#   - shared caches against the cap (see caches);
#   - leftover processes: any process whose working directory is inside this
#     home's scratch area for a task with no record, or inside a /tmp/fm-<id>
#     root with no record here; processes under another home's scratch are
#     counted but never judged;
#   - allowance used per lane over the last N days (default 7) read from the
#     worker tools' own transcripts by modification time: Claude Code
#     (${CLAUDE_CONFIG_DIR:-~/.claude}/projects/**/*.jsonl, usage per distinct
#     message id) and Codex (${CODEX_HOME:-~/.codex}/sessions/**/*.jsonl, last
#     cumulative token_count per session). A session is "main" when its working
#     directory is this home, "secondmate" when it is another Firstmate home
#     (a directory holding bin/fm-spawn.sh, AGENTS.md, and state/), "worker"
#     when one of its first forty lines carries a Firstmate launch brief or
#     operational-input notice (a Claude subagent transcript takes its parent
#     session's lane), and "other" otherwise. Every other tool is
#     reported as unmeasured.
#   Every measurement is bounded (du 60 s per path, docker 15 s, lsof 8 s,
#   each transcript scan 120 s) and an unmeasurable value prints as "unknown"
#   rather than failing the report; a transcript scan cut short leaves the
#   allowance figures a lower bound.
#   FM_FOOTPRINT_TMP_ROOT (default /tmp) and FM_FOOTPRINT_SYSTEM_TMPDIR
#   (default the macOS per-user temp directory, empty for none) replace the
#   temp directories measured (tests and diagnosis).
#
# What is never removed. Every removal below refuses whatever it cannot
#   prove disposable, so fewer cases are cleaned rather than any case risked:
#   - version-controlled work: a tree holding a .git, .hg, .svn, .jj, .bzr,
#     .pijul, _darcs, .sl, _FOSSIL_ or .fslckout entry,
#     or any entry named HEAD (a bare git repository), is never removed,
#     whether or not its commits look published, because no cheap check
#     covers every commit, stash, reflog entry, ignored file, and linked
#     worktree;
#   - a tree holding a name with a control character or a backslash, or one
#     that cannot be read in full within its bound;
#   - anything whose ownership is not proven (the key directory test below);
#   - a set-aside folder (.fm-closing-* or .fm-reclaim-*) left by an
#     interrupted removal: it is reported, never removed again by its name.
#   Before a directory is removed it is renamed aside (the daily pass and
#   old-folder apply do so under the task's spawn lock; task close runs while
#   teardown still holds the task's record), and whether it may go is then
#   decided from its own frozen contents, never from no process seeming to
#   use it (the removal boundary, fp_settle, below): it is frozen, flushed,
#   snapshotted, checked for running processes (which can only add a reason
#   to keep), left for removal-grace-seconds, checked for version-controlled
#   work again, and snapshotted again; only a positive record of every step
#   lets it go, and anything else puts it back with its permissions restored.
#   The removal then deletes, by descriptor and identity, exactly the entries
#   the verified snapshot lists, so anything that changed or appeared later
#   stays, with the folder around it. Firstmate never ends a process to free space;
#   teardown ends only the closing task's own processes, before task-close
#   runs.
#
# owns-scratch <task-id> <scratch-dir>
#   Exit 0 only when <scratch-dir> is this home's own area for the task (the
#   ownership test below). bin/fm-teardown.sh asks before ending processes
#   there, so a recorded path naming anything else never has its processes
#   ended.
#
# task-close <task-id> <scratch-dir> [<project>]
#   Called by bin/fm-teardown.sh only after every landed-work check passed, so
#   a refused cleanup never reaches it. With task-cleanup off it removes
#   nothing. Otherwise it removes the task's scratch area only when:
#   - the key directory <scratch-root>/<home-key> is a real directory, not a
#     link, owned by this user, writable by nobody else, physically a direct
#     child of the root, and its .fm-home names this home's physical path
#     (written by spawn when it made the directory);
#   - the recorded path is physically that key directory's child named for
#     the task, a real directory owned by this user and writable by nobody
#     else, on the same filesystem;
#   - nothing in it is in the never-removed list above, checked before and
#     after it is set aside. The task's own landed-work checks cover its own
#     copy only, so an area holding a repository is kept whole and named, and
#     once that repository is gone the daily pass removes the area.
#   Removal stays on one filesystem and never follows links. Docker: the
#   task's generation is read from <area>/.fm-generation, and only from an
#   area that passed the ownership test; without one, nothing in Docker is
#   removed (unproven). When the daemon answers within its bound, it removes
#   the containers (with their anonymous volumes), networks, volumes, and
#   images carrying exactly that generation's firstmate.task label or compose
#   project label, and never anything else: no prune, no name or prefix
#   match. Docker absent is a normal case and is skipped. When a listing
#   fails (unknown), some objects remain (partial), or the daemon does not
#   answer (down), the task and its generation are queued in
#   state/footprint-docker-retry for the daily pass; every change to that
#   queue holds its own short lock, and the daily pass removes only the
#   entries it retired from the queue as it is at that moment, so a close
#   queueing during the pass never loses its entry (when the queue cannot be
#   written, the summary names the label to remove by hand). It appends one line to
#   data/footprint-ledger.tsv (mode 0600): epoch, task, project, kept KB
#   (data/<task-id>/), scratch KB, Docker objects verified removed, Docker
#   status (removed, partial, unknown, down, absent, unproven), scratch status
#   (removed, partial, refused, kept, none), and "oversized" when the kept
#   folder is over keep-warn-mb (else "-"). An oversized folder is named in
#   the summary and kept whole: nothing kept is ever removed for its size.
#   Every step is best effort and the steps are independent, not one
#   transaction: it always exits 0 and prints one summary line, so a failure
#   is visible but never fails cleanup.
#
# caches
#   Lists the known shared download caches present on this machine with size,
#   last use (newest modification time of the cache directory and its direct
#   entries, a modification-age stand-in for last use: reading a cached item
#   need not change those times), and the tool's own trim command: uv (uv cache prune), npm (npm
#   cache verify), pip (pip3 cache purge), bun (bun pm cache rm), pnpm (pnpm
#   store prune), yarn (yarn cache clean), go build and module caches (go clean
#   -cache, go clean -modcache), Playwright browsers (playwright uninstall),
#   cargo registry (report only, no trim command), and Docker build cache
#   (docker builder prune --max-used-space, falling back to --keep-storage).
#   A cache whose tool is not installed has no trim command and is reported
#   only. FM_FOOTPRINT_CACHE_NAMES, a space-separated subset of those names
#   (empty for none), restricts the set (tests and diagnosis).
#
# trim-caches [--dry-run]
#   Only when cache-cap-gb is set. While the measured total is over the cap, it
#   runs the least recently used cache's own trim command (bounded to 300 s),
#   re-measures, and moves to the next; it never deletes inside a cache itself.
#   A cache with no trim command, or whose command fails, is skipped and named.
#   --dry-run prints the order and commands without running them.
#
# old-tasks [--days N] / old-tasks --apply <preview-id>
#   Previews, then removes, rebuildable material inside finished task folders.
#   A task folder is a directory directly under data/ that holds brief.md,
#   launch-brief.md, report.md, or a status*.log, has no state/<id>.meta (no
#   live task), and whose newest direct entry is older than N days (default
#   old-task-days). One bounded scan reads every such folder's whole tree,
#   and one sort and one pass with an ancestor stack classify it, so the cost
#   grows linearly with the tree; a folder holding a name with a control
#   character or a backslash, or whose scan does not complete, offers
#   nothing. Only one kind of entry is offered: the outermost directory whose
#   name is a known rebuildable layout (node_modules, .venv, venv, .tox, .nox,
#   __pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .next, .turbo,
#   .parcel-cache, .gradle, .terraform, .pnpm-store, .npm, .uv-cache,
#   ms-playwright, .cache) that holds no version-controlled work and no record
#   (brief.md, launch-brief.md, report.md, evidence.md, backlog.md, *.meta,
#   status*.log, decision*, dispatch-resolution.json), is not inside a
#   repository or another rebuildable directory, and is not under children/:
#   the name makes a candidate, the contents decide. Nothing inside a
#   repository is ever offered, published or not. Each entry's physical path
#   must be its folder's physical path plus the same relative path. Files are
#   never offered, so records, reports, decisions, and the task list
#   (data/backlog.md) never are. The preview prints every entry with its size
#   and writes state/footprint-old-tasks.preview naming a preview id: the
#   SHA-256 of the entry list and of the identity print of every entry - the
#   device, inode, mode, size, and modification and change times of
#   everything under it, and the SHA-256 of every file's contents. --apply
#   <id> recomputes the list and its id and stops, removing nothing, unless
#   both are identical. It then sets every entry aside, each under its task's
#   spawn lock with the task rechecked as finished and the entry as
#   contained, and prints the set-aside copies under their entry names: only
#   when that print equals the preview's and no copy holds anything in the
#   never-removed list does it remove them; otherwise it puts every entry
#   back and removes nothing. A copy that cannot be fully removed stays at
#   its set-aside name and is named. Removal is the captain's decision: apply
#   only a preview the captain approved.
#
# sweep [--dry-run]
#   The daily pass, rebuildable classes only. When this home's key directory
#   passes the ownership test, it removes the scratch areas there whose task
#   has no record, that are older than orphan-grace-hours, and that hold
#   nothing in the never-removed list; each is set aside only after taking
#   that task's spawn lock (bin/fm-spawn.sh holds it from before it makes the
#   area until the task is recorded) and rechecking that no record exists, so
#   a spawn reusing the id either is recorded first and keeps its area or
#   starts later with a fresh one. Every set-aside copy is checked again and
#   put back if it now blocks. It then retries queued Docker cleanups: each
#   only while Docker answers, under the task's spawn lock with no task
#   record present, and only for the queued generation, so a later task that
#   reuses the id is never touched (the lock is held while Docker removes, so
#   a spawn of that id in that moment is refused and can be retried). Then it
#   runs trim-caches when a cap is set. It prints one finding line naming
#   kept areas, set-aside folders left from an interrupted removal, an
#   untrusted key directory, pending Docker cleanups, and caches still over
#   the cap or a failed trim command.
#
# check / arm / disarm
#   arm writes state/footprint.check.sh and binds it through
#   bin/fm-check-register.sh, so the existing watcher slow-check cadence calls
#   check. Because one check may run for at most FM_CHECK_TIMEOUT (default
#   30 s), check starts sweep at most once every 86400 seconds as a detached
#   run in its own process group (daily-run; one at a time, lock
#   state/.footprint-daily.lock, result state/.footprint-daily.result) and
#   returns at once; a later check prints that run's finding only when it
#   differs from the last one reported (record: state/.footprint-check).
#   disarm removes the shim, its trust binding, the record, and the result.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CHECK_ID=footprint
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
CHECK_RECORD="$STATE/.footprint-check"
PREVIEW_FILE="$STATE/footprint-old-tasks.preview"
LEDGER="$DATA_DIR/footprint-ledger.tsv"
CHECK_INTERVAL=86400

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-footprint-lib.sh
. "$SCRIPT_DIR/fm-footprint-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
FP_OS=$(fm_footprint_os)

usage() {
  sed -n '2,15{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-footprint: %s\n' "$1" >&2
  exit 1
}

# fp_only_flags <allowed> <args...>: every argument must be the one allowed
# flag (none when empty), at most once; -h or --help prints the help and exits
# before anything is read or removed; anything else exits 2.
fp_only_flags() {  # <allowed> <args...>
  local allowed=$1
  shift
  case "${1:-}" in -h|--help) sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
  [ "$#" -eq 0 ] && return 0
  if [ -n "$allowed" ] && [ "$#" -eq 1 ] && [ "$1" = "$allowed" ]; then
    return 0
  fi
  printf 'fm-footprint: unknown argument: %s\n' "$*" >&2
  usage >&2
  exit 2
}

# fp_locks: the per-task spawn lock bin/fm-spawn.sh holds from before it
# creates a task's scratch area until it has recorded the task, loaded only
# by the commands that remove material a spawn could reuse.
fp_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

fp_task_lock() {  # <id>: 0 when this process now holds the task's spawn lock
  fp_locks
  fm_lock_try_acquire "$STATE/.spawn-$1.lock" 2>/dev/null
}

fp_task_unlock() {  # <id>
  fm_lock_release "$STATE/.spawn-$1.lock" >/dev/null 2>&1 || true
}

fp_task_live() {  # <id>
  [ -e "$STATE/$1.meta" ] || [ -L "$STATE/$1.meta" ]
}

now_epoch() {
  case "${FM_FOOTPRINT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_FOOTPRINT_NOW" ;;
  esac
}

fp_mtime() {  # <path>
  if [ "$FP_OS" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fp_device() {  # <path>
  if [ "$FP_OS" = Darwin ]; then
    /usr/bin/stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fp_du_kb() {  # <path> [seconds]: prints KB, or nothing when unmeasurable
  local kb
  [ -e "$1" ] || { printf '0\n'; return 0; }
  kb=$(fm_run_timed "${2:-60}" du -sk "$1" 2>/dev/null </dev/null | awk 'NR == 1 {print $1}')
  case "$kb" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$kb"
}

# fp_du_many <out> <path>...: one bounded du for many paths, writing
# "kb<TAB>path" rows for those it measured.
fp_du_many() {  # <out> <path>...
  local out=$1
  shift
  : > "$out"
  [ "$#" -gt 0 ] || return 0
  fm_run_timed 300 du -sk "$@" </dev/null > "$out" 2>/dev/null || true
}

fp_human() {  # <kb or empty>
  case "${1:-}" in
    ''|*[!0-9]*) printf 'unknown' ;;
    *) awk -v k="$1" 'BEGIN {
         if (k >= 1048576) printf "%.1f GB", k / 1048576
         else if (k >= 1024) printf "%.1f MB", k / 1024
         else printf "%d KB", k }' ;;
  esac
}

fp_config() {
  fm_footprint_config_read "$CONFIG_DIR" || die "$FP_CONFIG_ERROR"
  fm_footprint_scratch_root "$FM_HOME" || die "$FP_CONFIG_ERROR"
  FP_ROOT=$FP_SCRATCH_ROOT
  FP_KEY=$(fm_footprint_home_key "$FM_HOME") || die "cannot hash this home's path (shasum or sha256sum is required)"
}

# A name holding a control character (a newline above all) or a backslash
# would make one path read as two or be escaped differently by the tools that
# list it, so any tree holding one is never inspected or removed.
FP_CTRL_GLOB=$(printf '*[\001-\037\177]*')

# Version-control markers. A tree holding a .git, .hg, .svn, .jj, .bzr,
# .pijul, _darcs, .sl, _FOSSIL_ or .fslckout entry, or any entry named HEAD (a bare git repository), may hold the only copy of
# work, and no cheap check proves every commit, stash, reflog entry, ignored
# file, and linked worktree of it is safe elsewhere, so such a tree is never
# removed, whatever its remotes say.
FP_VCS_TESTS='-name .git -o -name .hg -o -name .svn -o -name .jj -o -name .bzr -o -name .pijul -o -name _darcs -o -name .sl -o -name _FOSSIL_ -o -name .fslckout -o -name HEAD'

# fp_marker_scan <root>...: one bounded scan printing every version-control
# marker under the roots (without descending into one), and the line
# FM-CONTROL-NAME, stopping there, at the first name holding a control
# character or a backslash. Returns 1 when the scan did not complete or could
# not read everything.
fp_marker_scan() {  # <root>...
  # shellcheck disable=SC2086 # FP_VCS_TESTS is a fixed list of find tests
  (set -f; fm_run_timed 300 find "$@" -xdev \
    \( \( -name "$FP_CTRL_GLOB" -o -name '*\\*' \) -exec printf '%s\n' FM-CONTROL-NAME \; -quit \) \
    -o \( \( $FP_VCS_TESTS \) -print -prune \) </dev/null 2>/dev/null)
}

# fp_blocked <out> <root>...: writes to <out> every root that cannot be proven
# disposable: something under it is a version-control marker or has a name
# with a control character or a backslash, or its scan did not complete. One
# scan covers every root; when it stops or fails, or a line cannot be traced
# to its root, each root is scanned on its own. Returns 1 when <out> could
# not be written, which the caller treats as every root blocked.
fp_blocked() {  # <out> <root>...
  local out=$1 scan r mapped
  shift
  : > "$out" 2>/dev/null || return 1
  [ "$#" -gt 0 ] || return 0
  if scan=$(fp_marker_scan "$@") && case "$scan" in *FM-CONTROL-NAME*) false ;; *) true ;; esac; then
    [ -n "$scan" ] || return 0
    if mapped=$(printf '%s\n' "$scan" | awk 'NR == FNR { root[$0] = 1; next }
        NF { p = $0; found = 0
             while (p != "") { if (p in root) { print p; found = 1; break }; if (!sub(/\/[^\/]*$/, "", p)) break }
             if (!found) bad = 1 }
        END { exit bad }' <(printf '%s\n' "$@") -); then
      printf '%s\n' "$mapped" | sort -u > "$out" 2>/dev/null || return 1
      return 0
    fi
  fi
  for r in "$@"; do
    if ! scan=$(fp_marker_scan "$r") || [ -n "$scan" ]; then printf '%s\n' "$r" >> "$out" 2>/dev/null || return 1; fi
  done
}

# fp_tree_disposable <dir>: 0 when nothing under <dir> blocks its removal
# (fp_blocked). Sets FP_BLOCKER to the reason otherwise.
fp_tree_disposable() {  # <dir>
  local scan
  FP_BLOCKER=
  if ! scan=$(fp_marker_scan "$1"); then
    FP_BLOCKER="$1 could not be read in full"
    return 1
  fi
  case "$scan" in
    '') return 0 ;;
    *FM-CONTROL-NAME*) FP_BLOCKER="$1 holds a name with a control character or a backslash" ;;
    *) FP_BLOCKER="$(printf '%s\n' "$scan" | head -n 1) is version-controlled work" ;;
  esac
  return 1
}

# fp_key_dir_ok: this home's scratch key directory carries this home's
# identity (fm_footprint_key_dir_trusted). Every removal under it needs this.
fp_key_dir_ok() {
  fm_footprint_key_dir_trusted "$FP_ROOT" "$FP_KEY" "$FM_HOME"
}

# fp_scratch_owned <dir> <id>: <dir> is physically this home's area for <id>:
# the trusted key directory's direct child named <id>, a real directory owned
# by this user, writable by nobody else, on the key directory's filesystem.
fp_scratch_owned() {  # <dir> <id>
  local dir=$1 id=$2 key_real dir_real
  fp_key_dir_ok || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  [ -z "$(find "$dir" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ] || return 1
  key_real=$(fm_footprint_physical_dir "$FP_ROOT/$FP_KEY") || return 1
  dir_real=$(fm_footprint_physical_dir "$dir") || return 1
  [ "$dir_real" = "$key_real/$id" ] || return 1
  [ "$(fp_device "$dir_real")" = "$(fp_device "$key_real")" ]
}

# fp_set_aside <dir> <tag>: renames a checked directory to a hidden name
# beside it, so a spawn that reuses the task id afterwards gets a fresh area.
# The caller checks the set-aside copy again before removing it, because the
# directory could change between the first check and the rename. Prints the
# new path.
fp_set_aside() {  # <dir> <tag>
  local dir=$1 parent n=0 to
  parent=${dir%/*}
  to="$parent/.fm-$2-${dir##*/}.$$"
  while [ -e "$to" ] || [ -L "$to" ]; do n=$((n + 1)); to="$parent/.fm-$2-${dir##*/}.$$.$n"; done
  mv -- "$dir" "$to" 2>/dev/null || return 1
  printf '%s\n' "$to"
}

# --- the removal boundary ----------------------------------------------------
#
# Whether a set-aside directory may go is decided from its own contents at
# the moment of removal, never from no process seeming to use it, and the
# removal itself is bound to the objects that were verified, never to path
# text. fp_settle runs every removal (task close, the daily pass, old-folder
# apply) through the same steps, each of which can only add reasons to keep:
#   1. freeze: write permission is removed from every directory and file, by
#      descriptor and never through a link, so no ordinary process can
#      create, rename, remove or open anything for writing there any more; a
#      file with more than one link is never changed, because its mode is
#      shared with a name outside, and keeps the whole copy;
#   2. flush: dirty pages are written out, so a later write through a memory
#      mapping or a descriptor opened earlier changes the entry's times;
#   3. snapshot: type, permissions, device, inode, size, blocks,
#      nanosecond modification and change times, and link count of every
#      entry;
#   4. the process check (fp_in_use): a copy a running process still uses, or
#      every copy when the processes cannot be listed in full, is kept;
#   5. the grace window (removal-grace-seconds);
#   6. the content check again (version-controlled work, unsafe names, or
#      anything unreadable keeps the copy), now that nothing new can appear;
#   7. a second snapshot that must equal the first, entry for entry.
# A copy is removable only when a positive record says every step verified
# it; a step that fails or cannot write its result keeps it, and a kept copy
# gets its permissions and its old name back, as does every copy when a stop
# signal arrives mid-way (fp_guard_set; the freeze writes each permission to
# its record before changing it). fp_fs remove then deletes, at
# once, exactly the entries the verified snapshot lists, each checked against
# its snapshotted identity in a parent opened by descriptor, giving each
# directory its write bit back only when its own entries go; anything that
# changed or appeared stays, with every directory above it.
# The limit: a process that already holds a file open or mapped for writing,
# that the process check cannot see (another user, such as root or a
# container writing through a bind mount), and that writes only after the
# second snapshot can lose that write; the grace window, not the process
# check, is what protects against such a writer. Between an entry's identity
# check and its unlink, an atomic save over the same name could still be
# removed: POSIX has no unlink by identity, so that window is two system
# calls wide, not zero. The whole boundary costs time linear in the entries
# (about 14 s for an area of 100,000 files on Mac 16).

# fp_fs <command> <args...>: runs the descriptor-safe filesystem engine
# (bin/fm-footprint-fs.py, whose header owns each command's contract), bound
# in time. Returns 4 when python3 is missing, so nothing can be removed.
FP_FS="$SCRIPT_DIR/fm-footprint-fs.py"
fp_fs() {  # <command> <args...>
  command -v python3 >/dev/null 2>&1 || return 4
  fm_run_timed 600 python3 -I -B "$FP_FS" "$@" </dev/null
}

# fp_thaw <modes> <dir>: gives every object under <dir> whose identity the
# freeze recorded its permissions back. Returns 1 when any could not be.
fp_thaw() {  # <modes> <dir>
  fp_fs thaw "$1" "$2" 2>/dev/null
}

# fp_why_all <work-dir> <reason>: gives every root in <work-dir>/roots a reason to keep.
fp_why_all() {  # <work-dir> <reason>
  awk -v r="$2" '{ print $0 "\t" r }' "$1/roots" >> "$1/why"
}

# fp_engine_failed <work-dir> <status>: an engine run that could not write its
# record or output (status 3) returns 1, so the caller keeps everything as
# unrecorded; one that stopped or failed otherwise gives every root the
# reason "unfinished" and returns 0.
fp_engine_failed() {  # <work-dir> <status>
  [ "$2" != 3 ] || return 1
  fp_why_all "$1" unfinished 2>/dev/null
}

# fp_guard_set <pairs> <modes> / fp_guard_clear: while set, a stop signal
# (TERM, INT, HUP, as a timed-out caller sends) gives every set-aside copy
# in <pairs> ("aside<TAB>dir") its recorded permissions back from <modes>
# and its old name back, then exits, so an interrupted removal never leaves
# a frozen copy behind.
FP_GUARD_PAIRS=
FP_GUARD_MODES=
fp_guard_set() {  # <pairs> <modes>
  FP_GUARD_PAIRS=$1 FP_GUARD_MODES=$2
  trap 'fp_guard_fire' TERM INT HUP
}

fp_guard_clear() {
  FP_GUARD_PAIRS=''
  FP_GUARD_MODES=''
  trap - TERM INT HUP
}

fp_guard_fire() {
  local aside area
  trap - TERM INT HUP
  if [ -n "$FP_GUARD_PAIRS" ] && [ -f "$FP_GUARD_PAIRS" ]; then
    while IFS='	' read -r aside area; do
      [ -n "$aside" ] || continue
      [ -e "$aside" ] || [ -L "$aside" ] || continue
      [ -z "$FP_GUARD_MODES" ] || [ ! -f "$FP_GUARD_MODES" ] || fp_thaw "$FP_GUARD_MODES" "$aside" || true
      fp_restore "$aside" "$area" || true
    done < "$FP_GUARD_PAIRS"
  fi
  exit 143
}

# fp_settle <pairs> <ok-out> <kept-out>: runs the removal boundary over the
# set-aside copies listed in <pairs> ("aside<TAB>dir"). A copy may be removed
# only when a positive record says every step verified it; a step that fails,
# cannot record its result, or leaves no snapshot keeps it. Writes each copy
# that may be removed now, still frozen, as a pair to <ok-out>, its verified
# snapshot to <ok-out>.snap and its recorded permissions to <ok-out>.modes
# for fp_fs remove, and each kept one as "reason<TAB>aside<TAB>dir" to
# <kept-out> after putting it back with its permissions restored. Reasons:
# notool, frozen, linked, mount, unsafe, unreadable, in-use, unlisted,
# blocked, changed, unfinished, unrecorded. A stop signal meanwhile puts
# every copy back writable (fp_guard_set); the caller clears that guard once
# it has removed the verified copies. Returns 1 when its own records could not be
# written, after putting every copy back.
fp_settle() {  # <pairs> <ok-out> <kept-out>
  local pairs=$1 ok=$2 kept=$3 w aside area why grace listed=1 bad=0
  local -a roots_all=()
  FP_UNLISTED_NAMES=
  while IFS='	' read -r aside area; do [ -n "$aside" ] && roots_all+=("$aside"); done < "$pairs"
  { : > "$ok" && : > "$ok.snap" && : > "$ok.modes" && : > "$kept"; } 2>/dev/null || bad=1
  [ "${#roots_all[@]}" -gt 0 ] || return "$bad"
  w=$(mktemp -d "${TMPDIR:-/tmp}/fm-footprint-settle.XXXXXX" 2>/dev/null) || w=
  if [ -z "$w" ] || [ "$bad" = 1 ]; then
    [ -z "$w" ] || rmdir "$w" 2>/dev/null || true
    while IFS='	' read -r aside area; do
      fp_restore "$aside" "$area" || true
      printf 'unrecorded\t%s\t%s\n' "$aside" "$area" >> "$kept" 2>/dev/null || true
    done < "$pairs"
    return 1
  fi
  {
    printf '%s\n' "${roots_all[@]}" > "$w/roots" && : > "$w/why" && : > "$w/modes" &&
      : > "$w/frozen" && : > "$w/s1" && : > "$w/s2" && : > "$w/busy" && : > "$w/blocked"
  } 2>/dev/null || bad=1
  fp_guard_set "$pairs" "$w/modes"
  if ! command -v python3 >/dev/null 2>&1; then
    fp_why_all "$w" notool 2>/dev/null || bad=1
  else
    # 1. Freeze, by descriptor and never through a link (fp_fs freeze).
    fp_fs freeze "$w/modes" "${roots_all[@]}" > "$w/frozen" 2>/dev/null || fp_engine_failed "$w" "$?" || bad=1
    # 2. Flush, so a write through an earlier mapping or descriptor changes
    #    an entry's times. 3. Snapshot.
    fm_run_timed 120 sync </dev/null >/dev/null 2>&1 || fp_why_all "$w" unreadable 2>/dev/null || bad=1
    fp_fs snapshot "${roots_all[@]}" > "$w/s1" 2>/dev/null || fp_engine_failed "$w" "$?" || bad=1
    # 4. The process check only adds reasons to keep.
    if fp_in_use "$w/busy" "${roots_all[@]}"; then
      awk '{ print $0 "\tin-use" }' "$w/busy" >> "$w/why" 2>/dev/null || bad=1
    else
      listed=0
    fi
    # 5. The grace window. 6. The content check again. 7. Snapshot again.
    grace=${FM_FOOTPRINT_REMOVAL_GRACE_OVERRIDE:-$FP_REMOVAL_GRACE_SECONDS}
    case "$grace" in ''|*[!0-9]*) grace=5 ;; esac
    [ "$grace" = 0 ] || sleep "$grace"
    fp_blocked "$w/blocked" "${roots_all[@]}" || bad=1
    fp_fs snapshot "${roots_all[@]}" > "$w/s2" 2>/dev/null || fp_engine_failed "$w" "$?" || bad=1
  fi
  # The positive record: a root is verified only when it was frozen, both
  # snapshots hold it in full with every non-directory singly linked and
  # are identical for it (each second-snapshot line is looked up by root and
  # path in the first, and the counts must match, so the cost is linear), the process listing was complete and names
  # nothing in it, and the content check found nothing. Every other root
  # gets the first reason that applies.
  awk -F '\t' -v listed="$listed" '
    FILENAME == ARGV[1] { fz[$1] = $2; next }
    FILENAME == ARGV[2] { if ($2 == "!") bad1[$1] = $3; else { one[$1 SUBSEP $11] = $0; n1[$1]++; if ($11 == ".") top1[$1] = 1; if ($2 != "d" && $10 != 1) linked[$1] = 1 }; next }
    FILENAME == ARGV[3] { if ($2 == "!") bad2[$1] = $3; else { k = $1 SUBSEP $11; if (!(k in one) || one[k] != $0) diff[$1] = 1; n2[$1]++; if ($11 == ".") top2[$1] = 1; if ($2 != "d" && $10 != 1) linked[$1] = 1 }; next }
    FILENAME == ARGV[4] { busy[$0] = 1; next }
    FILENAME == ARGV[5] { blk[$0] = 1; next }
    FILENAME == ARGV[6] { if (!($1 in why)) why[$1] = $2; next }
    { r = $0
      if (r in why) w = why[r]
      else if (!(r in fz)) w = "unrecorded"
      else if (fz[r] != "ok") w = fz[r]
      else if (r in bad1) w = bad1[r]
      else if (r in linked) w = "linked"
      else if (!(r in top1) || !(r in top2)) w = "unrecorded"
      else if (r in busy) w = "in-use"
      else if (listed != 1) w = "unlisted"
      else if (r in blk) w = "blocked"
      else if (r in bad2) w = bad2[r]
      else if ((r in diff) || n1[r] != n2[r]) w = "changed"
      else w = "verified"
      print r "\t" w }' "$w/frozen" "$w/s1" "$w/s2" "$w/busy" "$w/blocked" "$w/why" "$w/roots" > "$w/verdict" 2>/dev/null || bad=1
  if [ "$bad" = 0 ]; then
    awk -F '\t' '$2 == "verified" { print $1 }' "$w/verdict" > "$w/verified" 2>/dev/null &&
      awk -F '\t' 'FILENAME == ARGV[1] { v[$0] = 1; next } ($1 in v)' "$w/verified" "$w/s2" > "$ok.snap" 2>/dev/null &&
      cp "$w/modes" "$ok.modes" 2>/dev/null || bad=1
  fi
  while IFS='	' read -r aside area; do
    [ -n "$aside" ] || continue
    why=$(awk -F '\t' -v a="$aside" '$1 == a { print $2; exit }' "$w/verdict" 2>/dev/null)
    [ "$bad" = 0 ] || why=unrecorded
    if [ "$why" = verified ] && printf '%s\t%s\n' "$aside" "$area" >> "$ok" 2>/dev/null; then
      continue
    fi
    fp_thaw "$w/modes" "$aside" || true
    fp_restore "$aside" "$area" || true
    printf '%s\t%s\t%s\n' "${why:-unrecorded}" "$aside" "$area" >> "$kept" 2>/dev/null || bad=1
  done < "$pairs"
  # Until the caller has removed the verified copies, an interruption still
  # thaws and restores them from the copied record.
  fp_guard_set "$pairs" "$ok.modes"
  rm -f "$w/roots" "$w/why" "$w/modes" "$w/frozen" "$w/s1" "$w/s2" "$w/busy" "$w/blocked" "$w/verdict" "$w/verified"
  rmdir "$w" 2>/dev/null || true
  return "$bad"
}

# fp_remove_verified <ok-prefix> <out> <aside>...: removes the verified
# copies through fp_fs remove, which deletes only what <ok-prefix>.snap lists
# and checks each entry's identity first. Writes "aside<TAB>removed|partial
# <TAB>kb" lines to <out>; a copy is removed only when its line says so and
# it is gone.
fp_remove_verified() {  # <ok-prefix> <out> <aside>...
  local prefix=$1 out=$2
  shift 2
  fp_fs remove "$prefix.snap" "$prefix.modes" "$@" > "$out" 2>/dev/null
}

# fp_removed <out> <aside>: 0 when <out> records <aside> as removed and it is
# gone; prints the removed KB.
fp_removed() {  # <out> <aside>
  local kb
  kb=$(awk -F '\t' -v a="$2" '$1 == a && $2 == "removed" { print $3; exit }' "$1" 2>/dev/null)
  [ -n "$kb" ] && [ ! -e "$2" ] && [ ! -L "$2" ] && printf '%s\n' "$kb"
}

# fp_restore <aside> <dir>: puts a set-aside directory back when its old name
# is free. Returns 1 when it stays aside.
fp_restore() {  # <aside> <dir>
  [ ! -e "$2" ] && [ ! -L "$2" ] && mv -- "$1" "$2" 2>/dev/null
}

# fp_in_use <out> <dir>...: the quiescence check, made after directories are
# set aside and before their contents are checked the last time and removed.
# Writes to <out> each listed directory a running process of this user still
# uses: its working directory, or any file it holds open, at or below it. A
# set-aside directory has a name no other process knows, so once no process
# is rooted in it or holds anything open inside it, nothing can write there
# again, and the content check that follows sees everything ever written.
# The listing covers every open file of every process, never a walk of the
# directories, and it must be shown complete: every live process of this
# user seen both before and after the listing appears in it, and so does a
# probe file this process holds open. Otherwise, or on a timeout, it returns
# 1 with <out> empty and the caller removes nothing. A process is never ended
# to free space.
# macOS lists with lsof, which names memory-mapped files too; Linux reads
# each process's cwd and fd links and its file-backed memory maps under /proc
# (FM_PROC_ROOT_OVERRIDE in tests), where a readable fd directory and maps
# file are the proof that process was read. This check only ever adds reasons
# to keep: fp_settle never takes its silence as proof that a copy is safe.
fp_in_use() {  # <out> <dir>...
  local out=$1 dir parent phys last_parent='' last_phys='' rc=0 lrc probe_dir probe uid p st proc
  local -a fds=() cwds=() maps=()
  shift
  : > "$out" || return 1
  uid=$(id -u 2>/dev/null) || return 1
  # Each directory under its own path and its physical one.
  for dir in "$@"; do
    parent=${dir%/*}
    if [ "$parent" != "$last_parent" ]; then
      last_parent=$parent
      last_phys=$(fm_footprint_physical_dir "$parent") || last_phys=$parent
    fi
    phys="$last_phys/${dir##*/}"
    printf '%s\t%s\n%s\t%s\n' "$dir" "$dir" "$phys" "$dir"
  done > "$out.dirs"
  probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-footprint-probe.XXXXXX") || { rm -f "$out.dirs"; return 1; }
  probe_dir=$(fm_footprint_physical_dir "$probe_dir") || probe_dir=
  probe="$probe_dir/open"
  : > "$out.paths"
  if [ -z "$probe_dir" ] || [ ! -d "$probe_dir" ] || ! exec 9>"$probe"; then
    rc=1
  elif [ "$FP_OS" = Darwin ]; then
    ps -u "$uid" -o pid=,stat= > "$out.ps1" 2>/dev/null || rc=1
    fm_run_timed 120 lsof -n -P -w -u "$uid" -Fpn </dev/null > "$out.lsof" 2>/dev/null
    lrc=$?
    ps -u "$uid" -o pid=,stat= > "$out.ps2" 2>/dev/null || rc=1
    [ "$lrc" != 124 ] || rc=1
    # Every process alive and not a zombie at both ends must be listed.
    if [ "$rc" = 0 ] && ! awk 'FILENAME == ARGV[1] { if ($2 !~ /Z/) a[$1] = 1; next }
        FILENAME == ARGV[2] { if (($1 in a) && $2 !~ /Z/) need[$1] = 1; next }
        /^p/ { seen[substr($0, 2)] = 1 }
        END { for (q in need) if (!(q in seen)) exit 3; exit 0 }' "$out.ps1" "$out.ps2" "$out.lsof"; then
      rc=1
    fi
    grep -Fqx -- "n$probe" "$out.lsof" || rc=1
    sed -n 's/^n//p' "$out.lsof" > "$out.paths"
    rm -f "$out.ps1" "$out.ps2" "$out.lsof"
  else
    # This user's processes that are not zombies: state is the first field
    # after the last ")" of stat.
    proc=${FM_PROC_ROOT_OVERRIDE:-/proc}
    while IFS= read -r p; do
      st=
      { read -r st < "$p/stat"; } 2>/dev/null || continue
      st=${st##*) }
      case "${st%% *}" in Z|X|'') continue ;; esac
      fds+=("$p/fd")
      cwds+=("$p/cwd")
      maps+=("$p/maps")
    done < <(find "$proc" -mindepth 1 -maxdepth 1 -name '[0-9]*' -user "$uid" 2>/dev/null)
    if [ "${#fds[@]}" -eq 0 ]; then
      rc=1
    else
      fm_run_timed 120 find "${fds[@]}" -mindepth 1 -maxdepth 1 -type l -exec readlink -- {} + \
        </dev/null > "$out.paths" 2> "$out.err"
      lrc=$?
      [ "$lrc" != 124 ] || rc=1
      readlink -- "${cwds[@]}" >> "$out.paths" 2>/dev/null || true
      # File-backed memory mappings, which outlive their descriptor.
      fm_run_timed 120 cat -- "${maps[@]}" </dev/null 2>> "$out.err" | fp_maps_paths >> "$out.paths"
      # A process that exited meanwhile is gone. A process caught part-way
      # through an exec briefly refuses its fd directory or maps, so each
      # refused one is read again; it counts only once it reads in full or is
      # gone. Any other error, or a refusal that persists, means the listing
      # is incomplete.
      grep -v 'No such file or directory' "$out.err" > "$out.err2" || true
      if grep -v 'Permission denied' "$out.err2" | grep -q .; then
        rc=1
      else
        while IFS= read -r p; do
          case "$p" in "$proc"/[0-9]*) ;; *) rc=1; continue ;; esac
          if ! fp_proc_reread "$p" "$out.paths"; then
            rc=1
            st=$(head -c 64 "$p/comm" 2>/dev/null | tr -cd 'A-Za-z0-9._+-') || st=
            FP_UNLISTED_NAMES="${FP_UNLISTED_NAMES:+$FP_UNLISTED_NAMES, }${st:-a process} (pid ${p##*/})"
          fi
        done < <(grep -Eo "$proc/[0-9]+/(fd|maps)" "$out.err2" | sed 's|/[a-z]*$||' | sort -u)
      fi
      grep -Fqx -- "$probe" "$out.paths" || rc=1
      rm -f "$out.err" "$out.err2"
    fi
  fi
  exec 9>&-
  # The probe directory holds only the probe file, so it is emptied and
  # removed without a recursive delete.
  case "$probe_dir" in
    */fm-footprint-probe.*) rm -f -- "$probe"; rmdir -- "$probe_dir" 2>/dev/null || true ;;
  esac
  if [ "$rc" = 0 ]; then
    # Walk each used path's ancestors; the first that is a listed directory
    # marks it in use.
    awk -F'\t' 'FILENAME == ARGV[1] { dir[$1] = $2; next }
      { p = $0
        while (p != "") {
          if (p in dir) { if (!(dir[p] in seen)) { seen[dir[p]] = 1; print dir[p] }; break }
          if (p !~ /\//) break
          sub(/\/[^\/]*$/, "", p)
        }
      }' "$out.dirs" "$out.paths" > "$out" || rc=1
  fi
  [ "$rc" = 0 ] || : > "$out"
  rm -f "$out.dirs" "$out.paths"
  return "$rc"
}

# fp_maps_paths: reads /proc maps lines and prints each mapped file's path,
# everything after the fifth field.
fp_maps_paths() {
  awk 'NF >= 6 { p = $0; for (i = 1; i <= 5; i++) sub(/^[^ ]+ +/, "", p); if (p ~ /^\//) print p }'
}

# fp_proc_reread <proc-pid-dir> <paths-out>: reads one process's fd links and
# maps again, for up to about two seconds, appending what it holds to
# <paths-out>. Returns 0 once both read cleanly, or once the process is gone
# or a zombie; 1 when they stay unreadable.
fp_proc_reread() {  # <proc-pid-dir> <paths-out>
  local p=$1 n=0 st
  while [ "$n" -lt 20 ]; do
    [ -e "$p" ] || return 0
    st=
    { read -r st < "$p/stat"; } 2>/dev/null || return 0
    st=${st##*) }
    case "${st%% *}" in Z|X|'') return 0 ;; esac
    if find "$p/fd" -mindepth 1 -maxdepth 1 -type l -exec readlink -- {} + </dev/null > "$2.one" 2> "$2.oneerr" &&
      cat -- "$p/maps" 2>> "$2.oneerr" </dev/null | fp_maps_paths >> "$2.one" &&
      ! grep -v 'No such file or directory' "$2.oneerr" | grep -q .; then
      cat "$2.one" >> "$2"
      rm -f "$2.one" "$2.oneerr"
      return 0
    fi
    [ -e "$p" ] || { rm -f "$2.one" "$2.oneerr"; return 0; }
    sleep 0.1
    n=$((n + 1))
  done
  rm -f "$2.one" "$2.oneerr"
  return 1
}

# fp_settle_one <aside> <dir>: runs the removal boundary for one set-aside
# copy. Returns 0 only when the positive record verified it, with FP_SETTLED
# naming the prefix of its verified snapshot and permissions for
# fp_remove_verified (the caller removes those files); otherwise it is back
# at <dir> and FP_BLOCKER and FP_KEPT_HINT say why and what clears it.
fp_settle_one() {  # <aside> <dir>
  local f why
  FP_KEPT_HINT='move or remove that'
  FP_SETTLED=
  f=$(mktemp "${TMPDIR:-/tmp}/fm-footprint-one.XXXXXX" 2>/dev/null) || f=
  if [ -z "$f" ] || ! printf '%s\t%s\n' "$1" "$2" > "$f" 2>/dev/null; then
    [ -z "$f" ] || rm -f "$f"
    fp_restore "$1" "$2" || true
    FP_BLOCKER="its check could not be recorded (is the temporary directory full?)"
    FP_KEPT_HINT='it stays until it can be'
    return 1
  fi
  if fp_settle "$f" "$f.ok" "$f.kept" && grep -Fqx -- "$(printf '%s\t%s' "$1" "$2")" "$f.ok" 2>/dev/null; then
    # The pairs file stays for the interruption guard until the caller is done.
    rm -f "$f.ok" "$f.kept"
    FP_SETTLED="$f.ok"
    FP_SETTLED_PAIRS=$f
    return 0
  fi
  fp_guard_clear
  why=$(cut -f1 "$f.kept" 2>/dev/null | head -n 1)
  rm -f "$f" "$f.ok" "$f.kept" "$f.ok.snap" "$f.ok.modes"
  # Whatever the reason, the copy is not removed; make sure it is back.
  [ ! -e "$1" ] || fp_restore "$1" "$2" || true
  case "$why" in
    blocked)
      fp_tree_disposable "$2" || true
      [ -n "$FP_BLOCKER" ] || FP_BLOCKER="it holds something that may not be removed"
      ;;
    in-use)
      FP_BLOCKER="a running process still works in it or holds a file open or mapped there"
      FP_KEPT_HINT='end that process once its work is safe'
      ;;
    unlisted)
      FP_BLOCKER="the running processes could not be listed in full${FP_UNLISTED_NAMES:+ ($FP_UNLISTED_NAMES cannot be inspected; on Linux nothing is removed while such a process, for example ssh-agent or gpg-agent, runs)}"
      FP_KEPT_HINT='it stays until they can be'
      ;;
    changed)
      FP_BLOCKER="something in it changed while it waited to be removed"
      FP_KEPT_HINT='whatever still writes there should finish first'
      ;;
    linked)
      FP_BLOCKER="it holds a file hard-linked from elsewhere, such as a package store, whose permissions it shares"
      FP_KEPT_HINT='remove those links by hand once its work is safe'
      ;;
    notool)
      FP_BLOCKER="python3, which removal needs, is not installed"
      FP_KEPT_HINT='it stays until it is'
      ;;
    mount)
      FP_BLOCKER="another filesystem is mounted inside it"
      FP_KEPT_HINT='unmount it first'
      ;;
    unrecorded)
      FP_BLOCKER="its check could not be recorded (is the temporary directory full?)"
      FP_KEPT_HINT='it stays until it can be'
      ;;
    unfinished)
      FP_BLOCKER="its check did not finish (the removal engine stopped or failed)"
      FP_KEPT_HINT='it stays until a check finishes'
      ;;
    *)
      FP_BLOCKER="it could not be frozen and checked in full"
      FP_KEPT_HINT='it stays until it can be'
      ;;
  esac
  return 1
}

# --- Docker -------------------------------------------------------------

FP_DOCKER_STATE=

# FM_FOOTPRINT_DOCKER names the Docker client: unset means `docker` on PATH,
# empty means Docker is absent (the test suites' default, so no test ever
# reaches a live daemon), and a path selects that client.
FP_DOCKER_BIN=${FM_FOOTPRINT_DOCKER-docker}

fp_docker() {  # <seconds> <args...>
  local secs=$1
  shift
  fm_run_timed "$secs" "$FP_DOCKER_BIN" "$@" </dev/null 2>/dev/null
}

fp_docker_up() {
  if [ -z "$FP_DOCKER_STATE" ]; then
    if [ -z "$FP_DOCKER_BIN" ] || ! command -v "$FP_DOCKER_BIN" >/dev/null 2>&1; then
      FP_DOCKER_STATE=absent
    elif fp_docker 15 info --format '{{.ServerVersion}}' >/dev/null; then
      FP_DOCKER_STATE=up
    else
      FP_DOCKER_STATE=down
    fi
  fi
  [ "$FP_DOCKER_STATE" = up ]
}

# fp_docker_ids <kind> <label> <compose>: object ids carrying either label.
# Returns 1 when any listing failed, so an incomplete inventory is never
# read as "nothing to remove".
fp_docker_ids() {  # <ps|network|volume|image> <label> <compose>
  local kind=$1 label=$2 compose=$3 f out rc=0 all=''
  for f in "label=$label" "label=com.docker.compose.project=$compose"; do
    case "$kind" in
      ps) out=$(fp_docker 15 ps -aq --filter "$f") || rc=1 ;;
      network) out=$(fp_docker 15 network ls -q --filter "$f") || rc=1 ;;
      volume) out=$(fp_docker 15 volume ls -q --filter "$f") || rc=1 ;;
      image) out=$(fp_docker 15 image ls -q --filter "$f") || rc=1 ;;
    esac
    all="$all
$out"
  done
  printf '%s\n' "$all" | awk 'NF && !seen[$0]++'
  return "$rc"
}

# fp_docker_task_remove <id> <generation>: removes the objects carrying the
# exact label or compose project of that generation of the task, and nothing
# else. Sets FP_DOCKER_REMOVED (objects verified gone) and FP_DOCKER_RESULT:
# removed (none left), partial (some remain), unknown (an inventory could not
# be taken), absent, or down.
fp_docker_task_remove() {  # <id> <generation>
  local id=$1 gen=$2 label compose kind ids before=0 after=0 n failed=0
  FP_DOCKER_REMOVED=0
  if ! fp_docker_up; then
    FP_DOCKER_RESULT=$FP_DOCKER_STATE
    return 0
  fi
  label=$(fm_footprint_docker_label "$FP_KEY" "$id" "$gen")
  compose=$(fm_footprint_compose_project "$FP_KEY" "$id" "$gen")
  for kind in ps network volume image; do
    ids=$(fp_docker_ids "$kind" "$label" "$compose") || failed=1
    [ -n "$ids" ] || continue
    n=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
    before=$((before + n))
    # shellcheck disable=SC2086 # one docker object id per word
    case "$kind" in
      ps) fp_docker 60 rm -f -v $ids >/dev/null ;;
      network) fp_docker 60 network rm $ids >/dev/null ;;
      volume) fp_docker 60 volume rm -f $ids >/dev/null ;;
      image) fp_docker 120 image rm -f $ids >/dev/null ;;
    esac
  done
  for kind in ps network volume image; do
    ids=$(fp_docker_ids "$kind" "$label" "$compose") || { failed=1; continue; }
    [ -z "$ids" ] || after=$((after + $(printf '%s\n' "$ids" | wc -l | tr -d ' ')))
  done
  if [ "$failed" = 1 ]; then
    FP_DOCKER_RESULT=unknown
  elif [ "$after" -gt 0 ]; then
    FP_DOCKER_RESULT=partial
  else
    FP_DOCKER_RESULT=removed
  fi
  [ "$failed" = 1 ] || FP_DOCKER_REMOVED=$((before > after ? before - after : 0))
}

# Closed tasks whose Docker cleanup was incomplete (partial, unknown, or a
# daemon that did not answer): "id<TAB>epoch<TAB>generation" lines the daily
# pass retries. Each retry removes only that generation's objects, and only
# while holding the task's spawn lock with no task record present, so a later
# task reusing the id is never touched. Every change to the queue holds its
# own short lock, and the daily pass removes only the entries it retired
# from the queue as it is at that moment, so an entry a close appends while
# the pass runs is never lost; the slow Docker work runs without that lock.
DOCKER_RETRY="$STATE/footprint-docker-retry"
DOCKER_RETRY_LOCK="$STATE/.footprint-docker-retry.lock"

fp_docker_retry_lock() {
  fp_locks
  fm_lock_acquire_wait_max "$DOCKER_RETRY_LOCK" 30 2>/dev/null
}

fp_docker_retry_unlock() {
  fm_lock_release "$DOCKER_RETRY_LOCK" >/dev/null 2>&1 || true
}

fp_docker_retry_add() {  # <id> <generation>
  local rc=0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ ! -L "$DOCKER_RETRY" ] || return 1
  fp_docker_retry_lock || return 1
  if ! grep -q "^$1	[0-9]*	$2\$" "$DOCKER_RETRY" 2>/dev/null; then
    (umask 077 && printf '%s\t%s\t%s\n' "$1" "$(now_epoch)" "$2" >> "$DOCKER_RETRY") || rc=1
  fi
  fp_docker_retry_unlock
  return "$rc"
}

# fp_docker_retry_retire <retired-file>: removes exactly the listed entries
# from the queue as it is now, under the queue lock, keeping every other
# line, including any appended since the pass read it.
fp_docker_retry_retire() {  # <retired-file>
  local retired=$1 stage
  [ -s "$retired" ] || return 0
  fp_docker_retry_lock || return 1
  if [ -f "$DOCKER_RETRY" ] && [ ! -L "$DOCKER_RETRY" ] &&
    stage=$(umask 077 && mktemp "$STATE/.footprint-docker-retry.XXXXXX"); then
    if awk 'FILENAME == ARGV[1] { gone[$0] = 1; next } !($0 in gone)' "$retired" "$DOCKER_RETRY" > "$stage"; then
      if [ -s "$stage" ]; then
        mv -f "$stage" "$DOCKER_RETRY" || rm -f "$stage"
      else
        rm -f "$stage" "$DOCKER_RETRY"
      fi
    else
      rm -f "$stage"
    fi
  fi
  fp_docker_retry_unlock
}

# fp_docker_retry_run <dry>: retries each listed closed task's Docker cleanup
# while Docker answers; sets FP_DOCKER_PENDING to the entries still pending.
# A malformed entry is kept and counted, never acted on.
fp_docker_retry_run() {  # <dry>
  local dry=$1 id at gen n=0 snap retired
  FP_DOCKER_PENDING=0
  [ -f "$DOCKER_RETRY" ] && [ ! -L "$DOCKER_RETRY" ] || return 0
  snap=$(mktemp "${TMPDIR:-/tmp}/fm-footprint-retry.XXXXXX") || return 0
  retired="$snap.retired"
  : > "$retired"
  fp_docker_retry_lock || { rm -f "$snap" "$retired"; return 0; }
  cat "$DOCKER_RETRY" > "$snap" 2>/dev/null
  fp_docker_retry_unlock
  while IFS='	' read -r id at gen; do
    [ -n "$id$at$gen" ] || continue
    if [ "$dry" = 1 ] || ! fm_task_id_path_safe "$id" || ! fm_footprint_generation_valid "$gen" ||
      ! fp_docker_up || ! fp_task_lock "$id"; then
      n=$((n + 1))
      continue
    fi
    if fp_task_live "$id"; then
      fp_task_unlock "$id"
      n=$((n + 1))
      continue
    fi
    fp_docker_task_remove "$id" "$gen"
    fp_task_unlock "$id"
    if [ "$FP_DOCKER_RESULT" = removed ]; then
      fp_ledger_append "$(now_epoch)" "$id" - - 0 "$FP_DOCKER_REMOVED" docker-retry removed - || true
      printf '%s\t%s\t%s\n' "$id" "$at" "$gen" >> "$retired"
    else
      n=$((n + 1))
    fi
  done < "$snap"
  FP_DOCKER_PENDING=$n
  [ "$dry" = 1 ] || fp_docker_retry_retire "$retired" || true
  rm -f "$snap" "$retired"
}

# --- task-close -------------------------------------------------------------

fp_ledger_append() {  # <fields...>
  local line
  line=$(printf '%s\t' "$@")
  line=${line%	}
  [ -d "$DATA_DIR" ] && [ ! -L "$DATA_DIR" ] || return 1
  if [ -L "$LEDGER" ] || { [ -e "$LEDGER" ] && [ ! -f "$LEDGER" ]; }; then
    return 1
  fi
  (umask 077 && printf '%s\n' "$line" >> "$LEDGER")
}

# cmd_owns_scratch <id> <scratch>: exit 0 only when <scratch> is this home's
# own area for <id>. Teardown asks before ending processes there.
cmd_owns_scratch() {  # <id> <scratch>
  fm_task_id_path_safe "$1" || exit 1
  [ -n "$2" ] || exit 1
  fm_footprint_config_read "$CONFIG_DIR" || exit 1
  fm_footprint_scratch_root "$FM_HOME" || exit 1
  FP_KEY=$(fm_footprint_home_key "$FM_HOME") || exit 1
  FP_ROOT=$FP_SCRATCH_ROOT
  fp_scratch_owned "$2" "$1"
}

cmd_task_close() {  # <id> <scratch> [project]
  local id=$1 scratch=$2 project=${3:-} kept scratch_kb=0 scratch_result=none oversized=- aside gen='' queue_lost=0 kept_hint='move or remove that'
  fm_task_id_path_safe "$id" || die "invalid task id: $id"
  if ! fm_footprint_config_read "$CONFIG_DIR"; then
    printf 'footprint: %s; removed nothing for %s\n' "$FP_CONFIG_ERROR" "$id"
    return 0
  fi
  if [ "$FP_TASK_CLEANUP" = off ]; then
    printf 'footprint: task-cleanup is off; kept the scratch area and Docker material of %s\n' "$id"
    return 0
  fi
  if ! fm_footprint_scratch_root "$FM_HOME" || ! FP_KEY=$(fm_footprint_home_key "$FM_HOME"); then
    printf 'footprint: %s; removed nothing for %s\n' "${FP_CONFIG_ERROR:-cannot hash this home path}" "$id"
    return 0
  fi
  FP_ROOT=$FP_SCRATCH_ROOT
  # A caller whose temp directory lies inside the area being removed (a
  # worker's own environment) would lose every later bounded call's temp
  # files, so later steps run with the system temp instead.
  case "${TMPDIR:-}/" in "$scratch"/*) export TMPDIR=/tmp ;; esac
  local owned=0
  if [ -n "$scratch" ] && { [ -e "$scratch" ] || [ -L "$scratch" ]; }; then
    if ! fp_scratch_owned "$scratch" "$id"; then
      scratch_result=refused
    else
      owned=1
      # The Docker identity is read only from an area proven to be this
      # task's, and before anything in it is removed.
      gen=$(fm_footprint_task_generation "$scratch") || gen=
    fi
  fi
  # Docker first: a task container still running could write into the area
  # through a bind mount as another user, which the process check cannot see.
  if [ -n "$gen" ]; then
    fp_docker_task_remove "$id" "$gen"
    case "$FP_DOCKER_RESULT" in partial|unknown|down) fp_docker_retry_add "$id" "$gen" || queue_lost=1 ;; esac
  elif fp_docker_up || [ "$FP_DOCKER_STATE" = down ]; then
    FP_DOCKER_REMOVED=0
    FP_DOCKER_RESULT=unproven
  else
    FP_DOCKER_REMOVED=0
    FP_DOCKER_RESULT=absent
  fi
  if [ "$owned" = 1 ]; then
    scratch_kb=$(fp_du_kb "$scratch" 60) || scratch_kb=
    if ! fp_tree_disposable "$scratch"; then
      # The landed-work checks cover the task's own copy, not a
      # repository the worker made inside its scratch area.
      scratch_result=kept
    elif ! aside=$(fp_set_aside "$scratch" closing); then
      scratch_result=partial
      FP_BLOCKER="$scratch could not be set aside"
    elif ! fp_settle_one "$aside" "$scratch"; then
      # The removal boundary kept it and put it back (see fp_settle).
      scratch_result=kept
      kept_hint=$FP_KEPT_HINT
    else
      if fp_remove_verified "$FP_SETTLED" "$FP_SETTLED.rm" "$aside" && fp_removed "$FP_SETTLED.rm" "$aside" >/dev/null; then
        scratch_result=removed
      else
        scratch_result=partial
        FP_BLOCKER="what is left, including anything that appeared or changed after it was checked, is at $aside"
      fi
      fp_guard_clear
      rm -f "$FP_SETTLED.snap" "$FP_SETTLED.modes" "$FP_SETTLED.rm" "$FP_SETTLED_PAIRS"
    fi
  fi
  kept=$(fp_du_kb "$DATA_DIR/$id" 30) || kept=
  oversized=-
  case "$kept" in ''|*[!0-9]*) ;; *) [ "$kept" -le $((FP_KEEP_WARN_MB * 1024)) ] || oversized=oversized ;; esac
  fp_ledger_append "$(now_epoch)" "$id" "${project:--}" "${kept:-unknown}" "${scratch_kb:-unknown}" \
    "$FP_DOCKER_REMOVED" "$FP_DOCKER_RESULT" "$scratch_result" "$oversized" || true
  case "$scratch_result" in
    refused) printf 'footprint: %s scratch path %s is not this home'"'"'s area for the task; left it in place. ' "$id" "$scratch" ;;
    partial) printf 'footprint: %s scratch area %s was only partly removed: %s. ' "$id" "$scratch" "$FP_BLOCKER" ;;
    kept) printf 'footprint: %s scratch area %s kept whole (%s): %s; %s, and the daily pass removes the area. ' \
      "$id" "$scratch" "$(fp_human "$scratch_kb")" "$FP_BLOCKER" "$kept_hint" ;;
    *) printf 'footprint: %s scratch %s (%s). ' "$id" "$scratch_result" "$(fp_human "$scratch_kb")" ;;
  esac
  case "$FP_DOCKER_RESULT" in
    absent) printf 'Docker not present.' ;;
    unproven) printf 'Docker: no task generation could be read from a proven area, so no Docker object was removed.' ;;
    down) printf 'Docker did not answer; ' ;;
    unknown) printf 'Docker did not list the task'"'"'s objects; ' ;;
    partial) printf 'Docker: %s labelled object(s) removed, some remain; ' "$FP_DOCKER_REMOVED" ;;
    *) printf 'Docker: %s labelled object(s) %s.' "$FP_DOCKER_REMOVED" "$FP_DOCKER_RESULT" ;;
  esac
  case "$FP_DOCKER_RESULT" in
    down|unknown|partial)
      if [ "$queue_lost" = 1 ]; then
        printf 'its cleanup could not be queued, so remove what carries label %s by hand.' "$(fm_footprint_docker_label "$FP_KEY" "$id" "$gen")"
      else
        printf 'its cleanup is queued for the daily pass.'
      fi
      ;;
  esac
  if [ "$oversized" = oversized ]; then
    printf ' Kept folder data/%s is %s, over %s MB; kept whole, review it.\n' "$id" "$(fp_human "$kept")" "$FP_KEEP_WARN_MB"
  else
    printf '\n'
  fi
  return 0
}

# --- caches ------------------------------------------------------------

FP_ALL_CACHES="uv npm pip bun pnpm yarn go-build go-mod playwright cargo docker-build"

fp_cache_path() {  # <name>
  local p=
  case "$1" in
    uv) command -v uv >/dev/null 2>&1 && p=$(fm_run_timed 10 uv cache dir 2>/dev/null </dev/null) ;;
    npm) if command -v npm >/dev/null 2>&1; then p=$(fm_run_timed 10 npm config get cache 2>/dev/null </dev/null); fi
         [ -n "$p" ] || p="$HOME/.npm" ;;
    pip) command -v pip3 >/dev/null 2>&1 && p=$(fm_run_timed 10 pip3 cache dir 2>/dev/null </dev/null) ;;
    bun) command -v bun >/dev/null 2>&1 && p=$(fm_run_timed 10 bun pm cache 2>/dev/null </dev/null)
         [ -n "$p" ] || p="${BUN_INSTALL_CACHE_DIR:-$HOME/.bun/install/cache}" ;;
    pnpm) command -v pnpm >/dev/null 2>&1 && p=$(fm_run_timed 10 pnpm store path 2>/dev/null </dev/null) ;;
    yarn) command -v yarn >/dev/null 2>&1 && p=$(fm_run_timed 10 yarn cache dir 2>/dev/null </dev/null) ;;
    go-build) command -v go >/dev/null 2>&1 && p=$(fm_run_timed 10 go env GOCACHE 2>/dev/null </dev/null) ;;
    go-mod) command -v go >/dev/null 2>&1 && p=$(fm_run_timed 10 go env GOMODCACHE 2>/dev/null </dev/null) ;;
    playwright)
      if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then p=$PLAYWRIGHT_BROWSERS_PATH
      elif [ "$FP_OS" = Darwin ]; then p="$HOME/Library/Caches/ms-playwright"
      else p="${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright"; fi ;;
    cargo) p="${CARGO_HOME:-$HOME/.cargo}/registry" ;;
  esac
  p=$(printf '%s' "$p" | awk 'NF {print; exit}')
  case "$p" in /*) printf '%s\n' "$p" ;; esac
}

fp_cache_trim_cmd() {  # <name>: prints the trim command, empty when none
  case "$1" in
    uv) command -v uv >/dev/null 2>&1 && printf 'uv cache prune\n' ;;
    npm) command -v npm >/dev/null 2>&1 && printf 'npm cache verify\n' ;;
    pip) command -v pip3 >/dev/null 2>&1 && printf 'pip3 cache purge\n' ;;
    bun) command -v bun >/dev/null 2>&1 && printf 'bun pm cache rm\n' ;;
    pnpm) command -v pnpm >/dev/null 2>&1 && printf 'pnpm store prune\n' ;;
    yarn) command -v yarn >/dev/null 2>&1 && printf 'yarn cache clean\n' ;;
    go-build) command -v go >/dev/null 2>&1 && printf 'go clean -cache\n' ;;
    go-mod) command -v go >/dev/null 2>&1 && printf 'go clean -modcache\n' ;;
    playwright) command -v playwright >/dev/null 2>&1 && printf 'playwright uninstall\n' ;;
    docker-build) fp_docker_up && printf 'docker builder prune -f --max-used-space\n' ;;
  esac
  return 0
}

fp_cache_last_used() {  # <path>: newest mtime of the directory and its direct entries, one stat call
  local args
  if [ "$FP_OS" = Darwin ]; then args='-f %m'; else args='-c %Y'; fi
  # shellcheck disable=SC2086 # args is a fixed stat format flag pair
  { if [ "$FP_OS" = Darwin ]; then /usr/bin/stat $args -- "$1" "$1"/* "$1"/.[!.]* 2>/dev/null
    else stat $args -- "$1" "$1"/* "$1"/.[!.]* 2>/dev/null; fi; } |
    awk '$1 ~ /^[0-9]+$/ && $1 > m { m = $1 } END { printf "%d\n", m }'
}

fp_docker_build_cache_kb() {
  fp_docker_up || return 1
  fp_docker 15 system df --format '{{.Type}}\t{{.Size}}' | awk -F '\t' '
    $1 == "Build Cache" { s = $2; n = s + 0; u = s; gsub(/[0-9.]/, "", u)
      f = (u == "kB" || u == "KB") ? 1 : (u == "MB") ? 1024 : (u == "GB") ? 1048576 : (u == "TB") ? 1073741824 : (u == "B") ? 1 / 1024 : 0
      printf "%d\n", n * f; exit }'
}

# fp_caches_table <out-file>: one "name<TAB>path<TAB>kb<TAB>last_used<TAB>trim" row
# per cache present on this machine.
fp_caches_table() {  # <out>
  local out=$1 name path kb last trim
  : > "$out"
  for name in ${FM_FOOTPRINT_CACHE_NAMES-$FP_ALL_CACHES}; do
    case " $FP_ALL_CACHES " in *" $name "*) ;; *) continue ;; esac
    if [ "$name" = docker-build ]; then
      kb=$(fp_docker_build_cache_kb) || continue
      path=docker
      last=$(now_epoch)
    else
      path=$(fp_cache_path "$name")
      [ -n "$path" ] && [ -d "$path" ] && [ ! -L "$path" ] || continue
      kb=$(fp_du_kb "$path" 60) || kb=unknown
      last=$(fp_cache_last_used "$path")
    fi
    trim=$(fp_cache_trim_cmd "$name")
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$path" "$kb" "$last" "${trim:--}" >> "$out"
  done
}

fp_cap_kb() {
  [ -n "$FP_CACHE_CAP_GB" ] || return 1
  awk -v g="$FP_CACHE_CAP_GB" 'BEGIN { printf "%d\n", g * 1048576 }'
}

fp_table_total_kb() {  # <table>
  awk -F '\t' '$3 ~ /^[0-9]+$/ { t += $3 } END { printf "%d\n", t }' "$1"
}

fp_age() {  # <epoch>
  local now d
  now=$(now_epoch)
  case "${1:-}" in ''|*[!0-9]*|0) printf 'unknown'; return ;; esac
  d=$(( (now - $1) / 86400 ))
  [ "$d" -ge 0 ] || d=0
  printf '%sd ago' "$d"
}

cmd_caches() {  # [--json]
  local json=0 table cap total
  [ "${1:-}" = --json ] && json=1
  fp_config
  table=$(mktemp "${TMPDIR:-/tmp}/fm-footprint-caches.XXXXXX") || die "cannot create a temporary file"
  fp_caches_table "$table"
  total=$(fp_table_total_kb "$table")
  cap=$(fp_cap_kb) || cap=
  if [ "$json" = 1 ]; then
    jq -R -s --arg cap "${cap:-}" --arg total "$total" '
      { schema: "fm-footprint-caches.v1",
        cap_kb: (if $cap == "" then null else ($cap | tonumber) end),
        total_kb: ($total | tonumber),
        caches: [ split("\n")[] | select(length > 0) | split("\t")
          | { name: .[0], path: .[1], kb: (.[2] | tonumber? // null),
              last_used: (.[3] | tonumber? // null), trim: (if .[4] == "-" then null else .[4] end) } ] }' "$table"
  else
    printf 'Shared caches: %s' "$(fp_human "$total")"
    if [ -n "$cap" ]; then printf ' of a %s GB cap\n' "$FP_CACHE_CAP_GB"; else printf ' (no cap set; report only)\n'; fi
    while IFS='	' read -r name path kb last trim; do
      printf '  %-12s %10s  last used %-10s %-28s %s\n' "$name" "$(fp_human "$kb")" "$(fp_age "$last")" \
        "$( [ "$trim" = - ] && printf 'no trim command' || printf '%s' "$trim")" "$path"
    done < "$table"
  fi
  rm -f "$table"
}

fp_run_trim() {  # <name> <trim> <excess-kb>
  local name=$1 trim=$2 excess=$3 size keep
  case "$name" in
    docker-build)
      size=$(fp_docker_build_cache_kb) || return 1
      keep=$(( size > excess ? (size - excess) * 1024 : 0 ))
      fp_docker 300 builder prune -f --max-used-space "$keep" >/dev/null ||
        fp_docker 300 builder prune -f --keep-storage "$keep" >/dev/null
      ;;
    *)
      # shellcheck disable=SC2086 # the trim command is a fixed word list from fp_cache_trim_cmd
      fm_run_timed 300 $trim </dev/null >/dev/null 2>&1
      ;;
  esac
}

# fp_trim_caches <dry-run 0|1>: sets FP_TRIM_FINDING (empty when fine).
fp_trim_caches() {  # <dry>
  local dry=$1 table cap total order name path kb last trim newkb excess failed=''
  FP_TRIM_FINDING=
  cap=$(fp_cap_kb) || { printf 'No cache cap set (cache-cap-gb); nothing to trim.\n'; return 0; }
  table=$(mktemp "${TMPDIR:-/tmp}/fm-footprint-caches.XXXXXX") || die "cannot create a temporary file"
  fp_caches_table "$table"
  total=$(fp_table_total_kb "$table")
  if [ "$total" -le "$cap" ]; then
    printf 'Shared caches %s are under the %s GB cap.\n' "$(fp_human "$total")" "$FP_CACHE_CAP_GB"
    rm -f "$table"
    return 0
  fi
  printf 'Shared caches %s are over the %s GB cap; trimming least recently used first.\n' "$(fp_human "$total")" "$FP_CACHE_CAP_GB"
  order=$(sort -t '	' -k4,4n "$table")
  while IFS='	' read -r name path kb last trim; do
    [ -n "$name" ] || continue
    [ "$total" -gt "$cap" ] || break
    if [ "$trim" = - ]; then
      printf '  %s: no trim command, skipped\n' "$name"
      continue
    fi
    case "$kb" in ''|*[!0-9]*) printf '  %s: size unknown, skipped\n' "$name"; continue ;; esac
    if [ "$dry" = 1 ]; then
      printf '  would run: %s (%s, last used %s)\n' "$trim" "$(fp_human "$kb")" "$(fp_age "$last")"
      total=$((total - kb))
      continue
    fi
    excess=$((total - cap))
    if ! fp_run_trim "$name" "$trim" "$excess"; then
      printf '  %s: %s failed, skipped\n' "$name" "$trim"
      failed="$failed $name"
      continue
    fi
    if [ "$name" = docker-build ]; then newkb=$(fp_docker_build_cache_kb) || newkb=$kb
    else newkb=$(fp_du_kb "$path" 60) || newkb=$kb; fi
    printf '  ran: %s (%s -> %s)\n' "$trim" "$(fp_human "$kb")" "$(fp_human "$newkb")"
    total=$((total - kb + newkb))
  done <<EOF
$order
EOF
  rm -f "$table"
  [ "$dry" = 1 ] && return 0
  if [ "$total" -gt "$cap" ]; then
    FP_TRIM_FINDING="shared caches still $(fp_human "$total") over the $FP_CACHE_CAP_GB GB cap after trimming"
  fi
  [ -z "$failed" ] || FP_TRIM_FINDING="${FP_TRIM_FINDING:+$FP_TRIM_FINDING; }trim failed for:$failed"
  printf 'Shared caches now %s.\n' "$(fp_human "$total")"
}

cmd_trim_caches() {  # [--dry-run]
  local dry=0
  [ "${1:-}" = --dry-run ] && dry=1
  fp_config
  fp_trim_caches "$dry"
  [ -z "$FP_TRIM_FINDING" ] || printf 'finding: %s\n' "$FP_TRIM_FINDING"
}

# --- old task folders ---------------------------------------------------------

FP_REBUILDABLE_NAMES="node_modules .venv venv .tox .nox __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo .parcel-cache .gradle .terraform .pnpm-store .npm .uv-cache ms-playwright .cache"

fp_rebuildable_name() {  # <basename>
  case " $FP_REBUILDABLE_NAMES " in *" $1 "*) return 0 ;; esac
  return 1
}

fp_task_folder() {  # <dir>
  local f
  for f in "$1/brief.md" "$1/launch-brief.md" "$1/report.md" "$1"/status*.log; do
    [ -f "$f" ] && [ ! -L "$f" ] && return 0
  done
  return 1
}

fp_newest_entry() {  # <dir>
  fp_cache_last_used "$1"
}

# Files whose presence under a directory means it holds a record, so the
# directory is never offered whatever its name.
FP_RECORD_TESTS='-name brief.md -o -name launch-brief.md -o -name report.md -o -name evidence.md -o -name backlog.md -o -name *.meta -o -name status*.log -o -name decision* -o -name dispatch-resolution.json'

fp_scan_args() {  # sets FP_SCAN_REBUILD: the rebuildable-name tests of an old-folder scan
  local expr='' name
  for name in $FP_REBUILDABLE_NAMES; do expr="$expr${expr:+ -o }-name $name"; done
  FP_SCAN_REBUILD=$expr
}

# fp_folder_scan <folder>...: one bounded scan of whole folder trees printing
# tagged lines: "G<TAB>marker" for each version-control marker (fp_marker_scan,
# not descended into), "C<TAB>file" for each record, "R<TAB>dir" for each
# directory with a rebuildable name, and the line FM-CONTROL-NAME, stopping
# there, at the first name holding a control character or a backslash.
# Returns 1 when the scan did not complete.
fp_folder_scan() {  # <folder>...
  fp_scan_args
  # shellcheck disable=SC2086 # the test lists are fixed find tests
  (set -f; fm_run_timed 300 find "$@" -xdev \
    \( \( -name "$FP_CTRL_GLOB" -o -name '*\\*' \) -exec printf '%s\n' FM-CONTROL-NAME \; -quit \) \
    -o \( \( $FP_VCS_TESTS \) -prune -exec printf 'G\t%s\n' {} + \) \
    -o \( -type f \( $FP_RECORD_TESTS \) -exec printf 'C\t%s\n' {} + \) \
    -o \( -type d \( $FP_SCAN_REBUILD \) -exec printf 'R\t%s\n' {} + \) </dev/null 2>/dev/null)
}

# fp_folder_classify <scan-file>: the offered entries, one path per line, from
# a tagged scan of finished task folders, in one sort and one pass with an
# ancestor stack, so the cost grows with the number of lines, not with
# candidates squared. An entry is the outermost directory with a rebuildable
# name that holds no version-control marker and no record, is not inside a
# repository (the directory holding a marker) or another rebuildable
# directory, and is neither a folder itself nor inside its children/. Returns
# 1 when a line lies outside data/.
fp_folder_classify() {  # <scan-file>
  local keyed
  keyed=$(awk -F '\t' -v data="$DATA_DIR/" '
    NF != 2 || index($2, data) != 1 { bad = 1; exit }
    {
      t = $1; p = $2; rel = substr(p, length(data) + 1)
      if (t == "G") { sub(/\/[^\/]*$/, "", p); o = 1 }
      else if (t == "R") { if (rel !~ /\// || rel ~ /^[^\/]*\/children(\/|$)/) next; o = 2 }
      else if (t == "C") o = 3
      else { bad = 1; exit }
      k = p; gsub(/\//, "\001", k)
      printf "%s\t%d\t%s\t%s\n", k, o, t, p
    }
    END { exit bad }' "$1") || return 1
  [ -n "$keyed" ] || return 0
  printf '%s\n' "$keyed" | LC_ALL=C sort -t '	' -k1,1 -k2,2n | awk -F '\t' '
    function within(a, b) { return b == a || index(b, a "/") == 1 }
    function pop(   e) {
      e = sp--
      if (taint[e] && sp > 0) taint[sp] = 1
      if (kind[e] == "R" && outer[e] && !taint[e]) print path[e]
    }
    {
      t = $3; p = $4
      while (sp > 0 && !within(path[sp], p)) pop()
      if (t == "C") { if (sp > 0) taint[sp] = 1; next }
      if (t == "G" && sp > 0) taint[sp] = 1
      sp++; path[sp] = p; kind[sp] = t; taint[sp] = (t == "G"); outer[sp] = (sp == 1)
    }
    END { while (sp > 0) pop() }'
}

# fp_contained <list-file>: the listed directories that are real directories,
# not links, owned by this user, whose physical path is their task folder's
# physical path plus the same relative path, so nothing outside the folder can
# be named. One subshell for the whole list, with no process per entry.
fp_contained() {  # <list-file>
  local data=$DATA_DIR
  (
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      rel=${e#"$data"/}
      folder="$data/${rel%%/*}"
      [ -d "$e" ] && [ ! -L "$e" ] && [ -O "$e" ] && [ ! -L "$folder" ] || continue
      CDPATH='' cd -P -- "$folder" 2>/dev/null || continue
      fr=$PWD
      CDPATH='' cd -P -- "$e" 2>/dev/null || continue
      [ "$PWD" = "$fr/${rel#*/}" ] && printf '%s\n' "$e"
    done < "$1"
  )
}

# fp_old_task_entries <days> <out>: "kind<TAB>kb<TAB>path" rows, sorted.
fp_old_task_entries() {  # <days> <out>
  local days=$1 out=$2 now cutoff folder id newest kind entry
  local -a folders=()
  now=$(now_epoch)
  cutoff=$((now - days * 86400))
  : > "$out.entries"
  for folder in "$DATA_DIR"/*/; do
    folder=${folder%/}
    [ -d "$folder" ] && [ ! -L "$folder" ] || continue
    id=${folder##*/}
    fm_task_id_path_safe "$id" || continue
    fp_task_folder "$folder" || continue
    fp_task_live "$id" && continue
    newest=$(fp_newest_entry "$folder")
    [ "$newest" -le "$cutoff" ] || continue
    folders+=("$folder")
  done
  # One scan across every eligible folder; when it meets an unsafe name (and
  # stops) or fails, each folder is scanned on its own instead, so only the
  # folder it concerns is withheld.
  if [ "${#folders[@]}" -gt 0 ]; then
    if fp_folder_scan "${folders[@]}" > "$out.scan" && ! grep -q '^FM-CONTROL-NAME$' "$out.scan"; then
      fp_folder_classify "$out.scan" > "$out.entries" || : > "$out.entries"
    else
      for folder in "${folders[@]}"; do
        if fp_folder_scan "$folder" > "$out.scan" && ! grep -q '^FM-CONTROL-NAME$' "$out.scan"; then
          fp_folder_classify "$out.scan" >> "$out.entries" || true
        fi
      done
    fi
  fi
  fp_contained "$out.entries" > "$out.kinds"
  # One bounded du for every entry; an entry it could not measure is not offered.
  local -a paths=()
  while IFS= read -r entry; do [ -n "$entry" ] && paths+=("$entry"); done < "$out.kinds"
  fp_du_many "$out.du" "${paths[@]+"${paths[@]}"}"
  awk -F '\t' 'NR == FNR { kb[$2] = $1; next } ($0 in kb) { print "rebuildable\t" kb[$0] "\t" $0 }' "$out.du" "$out.kinds" |
    sort -t '	' -k3,3 > "$out"
  rm -f "$out.kinds" "$out.du" "$out.scan" "$out.entries"
}

fp_sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}

# fp_tree_print <map-file>: the identity of the trees named in <map-file>
# ("root<TAB>label" lines) with every path rewritten from its root to its
# label: device, inode, mode, size, modification and change time of everything
# under each root, then the SHA-256 of every file's contents, sorted. A root's
# own change time is left out, because setting a directory aside changes it.
# So the set-aside copy of an entry prints exactly what the entry printed
# under its own name, and anything added, removed, replaced, or edited
# changes the print. Returns 1 when a tree could not be read in full.
fp_tree_print() {  # <map-file>
  local map=$1 root label listing sums sumtool
  local -a roots=()
  while IFS='	' read -r root label; do [ -n "$root" ] && roots+=("$root"); done < "$map"
  [ "${#roots[@]}" -gt 0 ] || return 0
  if [ "$FP_OS" = Darwin ]; then
    listing=$(fm_run_timed 600 find "${roots[@]}" -xdev -exec /usr/bin/stat -f '%d %i %p %z %m %c %N' {} + </dev/null 2>/dev/null) || return 1
  else
    listing=$(fm_run_timed 600 find "${roots[@]}" -xdev -exec stat -c '%d %i %f %s %Y %Z %n' {} + </dev/null 2>/dev/null) || return 1
  fi
  if command -v shasum >/dev/null 2>&1; then sumtool='shasum -a 256'; else sumtool=sha256sum; fi
  # shellcheck disable=SC2086 # sumtool is a fixed command and its flags
  sums=$(fm_run_timed 600 find "${roots[@]}" -xdev -type f -exec $sumtool {} + </dev/null 2>/dev/null) || return 1
  { printf '%s\n' "$listing" | sed 's/^/S /'; printf '%s\n' "$sums" | sed 's/^/H /'; } | awk -F '\t' '
    NR == FNR { label[$1] = $2; next }
    function relabel(q,   p, rest) {
      p = q; rest = ""
      while (p != "") {
        if (p in label) return label[p] rest
        if (!match(p, /\/[^\/]*$/)) break
        rest = substr(p, RSTART) rest; p = substr(p, 1, RSTART - 1)
      }
      bad = 1; return ""
    }
    /^S / {
      n = split(substr($0, 3), f, " "); if (n < 7) { bad = 1; next }
      q = substr($0, 3); for (i = 1; i <= 6; i++) sub(/^[^ ]* /, "", q)
      ctime = (q in label) ? "-" : f[6]
      print "S " f[1] " " f[2] " " f[3] " " f[4] " " f[5] " " ctime " " relabel(q); next
    }
    /^H / {
      q = substr($0, 3); if (q ~ /^\\/ || length(q) < 67) { bad = 1; next }
      print "H " substr(q, 1, 64) " " relabel(substr(q, 67)); next
    }
    NF { bad = 1 }
    END { exit bad }' "$map" - | LC_ALL=C sort
}

# fp_old_task_id <rows> <print-out>: the preview id, the SHA-256 of the rows
# and of the identity print of every offered entry (fp_tree_print), written
# to <print-out> as well. Returns 1 when that could not be read in full.
fp_old_task_id() {  # <rows> <print-out>
  local rows=$1 kind kb entry
  : > "$2.map"
  while IFS='	' read -r kind kb entry; do [ -n "$entry" ] && printf '%s\t%s\n' "$entry" "$entry" >> "$2.map"; done < "$rows"
  fp_tree_print "$2.map" > "$2" || { rm -f "$2.map"; return 1; }
  rm -f "$2.map"
  { cat "$rows"; cat "$2"; } | fp_sha256_stream
}

# fp_print_unfrozen: reads fp_tree_print lines and drops what freezing a
# tree changes: the write bits of each mode (octal on macOS, hexadecimal on
# Linux) and each change time.
fp_print_unfrozen() {
  awk -v os="$FP_OS" '
    function clearw(m,   v, i, c, d, n, p, out) {
      v = 0
      if (os == "Darwin") { for (i = 1; i <= length(m); i++) v = v * 8 + substr(m, i, 1) }
      else { for (i = 1; i <= length(m); i++) { c = tolower(substr(m, i, 1)); v = v * 16 + index("0123456789abcdef", c) - 1 } }
      p = v % 512; n = v - p; out = 0
      for (d = 1; d <= 64; d *= 8) { c = int(p / d) % 8; if (int(c / 2) % 2) c -= 2; out += c * d }
      return n + out
    }
    /^S / { $4 = clearw($4); $7 = "-"; print; next }
    { print }'
}

# fp_restore_all <pairs>: puts every set-aside entry ("aside<TAB>entry") back.
fp_restore_all() {  # <pairs>
  local aside entry
  while IFS='	' read -r aside entry; do
    [ -n "$aside" ] || continue
    fp_restore "$aside" "$entry" || printf 'could not put %s back; it is at %s\n' "$entry" "$aside"
  done < "$1"
}

cmd_old_tasks() {  # [--days N] | --apply <id>
  local days apply='' tmp id want total kind kb entry task folder aside gone left
  fp_config
  days=$FP_OLD_TASK_DAYS
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days) _fm_footprint_whole "${2:-}" || die "--days needs a whole number"; days=$2; shift 2 ;;
      --apply) case "${2:-}" in ''|-*) die "--apply needs a preview id" ;; esac; apply=$2; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-footprint-old.XXXXXX") || die "cannot create a temporary file"
  if [ -n "$apply" ]; then
    [ -f "$PREVIEW_FILE" ] && [ ! -L "$PREVIEW_FILE" ] || { rm -f "$tmp"; die "no preview to apply; run old-tasks first"; }
    want=$(awk -F '\t' '$1 == "id" {print $2; exit}' "$PREVIEW_FILE")
    days=$(awk -F '\t' '$1 == "days" {print $2; exit}' "$PREVIEW_FILE")
    [ "$want" = "$apply" ] || { rm -f "$tmp"; die "preview id $apply is not the current preview ($want); nothing removed"; }
    fp_old_task_entries "$days" "$tmp"
    if ! id=$(fp_old_task_id "$tmp" "$tmp.print") || [ "$id" != "$want" ]; then
      rm -f "$tmp" "$tmp.print"
      die "task folders changed since preview $want, or could not be read in full; nothing removed - run old-tasks again"
    fi
    # Set every entry aside, each under its task's spawn lock with the task
    # rechecked as finished and the entry as contained in its folder; any
    # failure puts back what was set aside and removes nothing.
    : > "$tmp.pairs"
    : > "$tmp.map"
    local -a entries=()
    while IFS='	' read -r kind kb entry; do [ -n "$entry" ] && entries+=("$entry"); done < "$tmp"
    for entry in "${entries[@]+"${entries[@]}"}"; do
      task=${entry#"$DATA_DIR"/}
      task=${task%%/*}
      folder="$DATA_DIR/$task"
      if ! fp_task_lock "$task"; then
        fp_restore_all "$tmp.pairs"
        rm -f "$tmp" "$tmp.print" "$tmp.pairs" "$tmp.map"
        die "task $task is being spawned; nothing removed - run old-tasks again"
      fi
      printf '%s\n' "$entry" > "$tmp.one"
      if fp_task_live "$task" || [ "$(fp_contained "$tmp.one")" != "$entry" ] || ! aside=$(fp_set_aside "$entry" reclaim); then
        fp_task_unlock "$task"
        fp_restore_all "$tmp.pairs"
        rm -f "$tmp" "$tmp.print" "$tmp.pairs" "$tmp.map" "$tmp.one"
        die "$entry changed or its task is live again; nothing removed - run old-tasks again"
      fi
      fp_task_unlock "$task"
      printf '%s\t%s\n' "$aside" "$entry" >> "$tmp.pairs"
      printf '%s\t%s\n' "$aside" "$entry" >> "$tmp.map"
    done
    rm -f "$tmp.one"
    # The set-aside copies must print exactly what the preview printed and
    # still hold nothing that blocks removal; otherwise everything goes back.
    local -a asides=()
    while IFS='	' read -r aside entry; do asides+=("$aside"); done < "$tmp.pairs"
    # The removal boundary (see fp_settle) for the whole batch; if it keeps
    # any entry, every entry goes back.
    local settled=0
    fp_settle "$tmp.pairs" "$tmp.ok" "$tmp.kept" && settled=1
    if [ "$settled" = 0 ] || [ -s "$tmp.kept" ]; then
      while IFS='	' read -r aside entry; do
        fp_thaw "$tmp.ok.modes" "$aside" || true
        fp_restore "$aside" "$entry" || printf 'could not put %s back; it is at %s\n' "$entry" "$aside"
      done < "$tmp.ok"
      case "$(cut -f1 "$tmp.kept" 2>/dev/null | head -n 1)" in
        in-use|unlisted) left="a running process still uses an entry, or the running processes could not be listed in full${FP_UNLISTED_NAMES:+ ($FP_UNLISTED_NAMES cannot be inspected; on Linux nothing is removed while such a process, for example ssh-agent or gpg-agent, runs)}" ;;
        linked) left="an entry holds a file hard-linked from elsewhere, such as a package store" ;;
        notool) left="python3, which removal needs, is not installed" ;;
        unrecorded|'') left="the check could not be recorded (is the temporary directory full?)" ;;
        *) left="an entry changed while it was being set aside or waiting to be removed" ;;
      esac
      rm -f "$tmp" "$tmp.print" "$tmp.pairs" "$tmp.map" "$tmp.ok" "$tmp.ok.snap" "$tmp.ok.modes" "$tmp.kept"
      die "$left; nothing removed - run old-tasks again"
    fi
    # The frozen copies must still print what the preview printed, apart from
    # the write bits and change times the freeze itself altered.
    if ! fp_tree_print "$tmp.map" > "$tmp.print2" ||
      ! cmp -s <(fp_print_unfrozen < "$tmp.print") <(fp_print_unfrozen < "$tmp.print2"); then
      while IFS='	' read -r aside entry; do
        fp_thaw "$tmp.ok.modes" "$aside" || true
        fp_restore "$aside" "$entry" || printf 'could not put %s back; it is at %s\n' "$entry" "$aside"
      done < "$tmp.ok"
      rm -f "$tmp" "$tmp.print" "$tmp.print2" "$tmp.pairs" "$tmp.map" "$tmp.ok" "$tmp.ok.snap" "$tmp.ok.modes" "$tmp.kept"
      die "an entry changed while it was being set aside or waiting to be removed; nothing removed - run old-tasks again"
    fi
    fp_remove_verified "$tmp.ok" "$tmp.rm" "${asides[@]}" || true
    fp_guard_clear
    total=0 gone=0 left=0
    while IFS='	' read -r kind kb entry; do
      aside=$(awk -F '\t' -v e="$entry" '$2 == e { print $1; exit }' "$tmp.pairs")
      if fp_removed "$tmp.rm" "$aside" >/dev/null; then
        printf 'removed %s %s %s\n' "$kind" "$(fp_human "$kb")" "$entry"
        total=$((total + kb))
        gone=$((gone + 1))
      else
        printf 'could not fully remove %s; what is left is at %s\n' "$entry" "$aside"
        left=$((left + 1))
      fi
    done < "$tmp"
    rm -f "$tmp" "$tmp.print" "$tmp.print2" "$tmp.pairs" "$tmp.map" "$tmp.ok" "$tmp.ok.snap" "$tmp.ok.modes" "$tmp.kept" "$tmp.rm" "$PREVIEW_FILE"
    printf 'Removed %s entries, %s, from old task folders.' "$gone" "$(fp_human "$total")"
    [ "$left" = 0 ] && printf '\n' || printf ' %s could not be fully removed.\n' "$left"
    return 0
  fi
  fp_old_task_entries "$days" "$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$PREVIEW_FILE"
    printf 'Nothing to offer in task folders older than %s days.\n' "$days"
    return 0
  fi
  id=$(fp_old_task_id "$tmp" "$tmp.print") || { rm -f "$tmp" "$tmp.print"; die "could not read the offered entries in full; nothing previewed"; }
  rm -f "$tmp.print"
  total=$(awk -F '\t' '{ t += $2 } END { printf "%d\n", t }' "$tmp")
  {
    printf 'id\t%s\n' "$id"
    printf 'days\t%s\n' "$days"
    cat "$tmp"
  } > "$PREVIEW_FILE.tmp" && mv -f "$PREVIEW_FILE.tmp" "$PREVIEW_FILE"
  printf 'Offered in task folders older than %s days (records, reports, decisions and version-controlled work are never offered):\n' "$days"
  awk -F '\t' '{ k = $2
    if (k >= 1048576) h = sprintf("%.1f GB", k / 1048576); else if (k >= 1024) h = sprintf("%.1f MB", k / 1024); else h = sprintf("%d KB", k)
    printf "  %-16s %10s  %s\n", $1, h, $3 }' "$tmp"
  printf 'Total %s. Preview %s.\nRemove exactly this list with: %s old-tasks --apply %s\n' \
    "$(fp_human "$total")" "$id" "$0" "$id"
  rm -f "$tmp"
}

# --- sweep and check ----------------------------------------------------------------

cmd_sweep() {  # [--dry-run]
  local dry=0 base area id age_cut now uid work removed=0 removed_kb=0 kb path aside entry
  local kept=0 kept_ids='' busy=0 findings='' leftover=0 leftover_names='' back=0 inuse=0 inuse_ids='' unlisted=0 changed=0 changed_ids='' linked=0 linked_ids='' kb
  local -a cands=() orphans=() asides=()
  [ "${1:-}" = --dry-run ] && dry=1
  fp_config
  now=$(now_epoch)
  age_cut=$((now - FP_ORPHAN_GRACE_HOURS * 3600))
  base="$FP_ROOT/$FP_KEY"
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-footprint-sweep.XXXXXX") || die "cannot create a temporary directory"
  if [ -d "$base" ] || [ -L "$base" ]; then
    if ! fp_key_dir_ok; then
      findings="scratch directory $base does not carry this home's identity, so nothing in it was removed"
    else
      # A set-aside area a close or an earlier pass did not finish removing is
      # never removed again on the strength of its name; it is reported.
      for aside in "$base"/.fm-reclaim-* "$base"/.fm-closing-*; do
        [ -e "$aside" ] || [ -L "$aside" ] || continue
        leftover=$((leftover + 1))
        [ "$leftover" -gt 5 ] || leftover_names="$leftover_names${leftover_names:+, }${aside##*/}"
      done
      for area in "$base"/*; do
        [ -d "$area" ] && [ ! -L "$area" ] || continue
        id=${area##*/}
        fm_task_id_path_safe "$id" || continue
        fp_task_live "$id" && continue
        cands+=("$area")
      done
    fi
  fi
  if [ "${#cands[@]}" -gt 0 ]; then
    # One stat for every candidate: old enough, owned by this user, and on the
    # key directory's own filesystem.
    uid=$(id -u)
    { if [ "$FP_OS" = Darwin ]; then /usr/bin/stat -f '%m %d %u %N' -- "$base" "${cands[@]}"
      else stat -c '%Y %d %u %n' -- "$base" "${cands[@]}"; fi; } 2>/dev/null |
      awk -v cut="$age_cut" -v uid="$uid" 'NR == 1 { dev = $2; next }
        { p = $0; sub(/^[^ ]+ [^ ]+ [^ ]+ /, "", p); if ($1 <= cut && $2 == dev && $3 == uid) print p }' > "$work/orphans"
    while IFS= read -r path; do orphans+=("$path"); done < "$work/orphans"
  fi
  if [ "${#orphans[@]}" -gt 0 ]; then
    # One scan across every orphan; an orphan holding version-controlled work
    # or an unsafe name, or one that cannot be read in full, is kept whole.
    fp_blocked "$work/blocked" "${orphans[@]}"
    for area in "${orphans[@]}"; do
      id=${area##*/}
      if grep -Fqx -- "$area" "$work/blocked"; then
        kept=$((kept + 1))
        [ "$kept" -gt 5 ] || kept_ids="$kept_ids${kept_ids:+, }$id"
        continue
      fi
      if [ "$dry" = 1 ]; then
        printf 'would remove orphaned scratch %s (%s)\n' "$area" "$(fp_human "$(fp_du_kb "$area" 60)")"
        continue
      fi
      # Under the task's spawn lock, so a spawn reusing the id either finished
      # recording the task (and the recheck keeps the area) or starts after
      # the area was set aside and gets a fresh one.
      if ! fp_task_lock "$id"; then
        busy=$((busy + 1))
        continue
      fi
      if fp_task_live "$id" || [ ! -d "$area" ] || [ -L "$area" ] || ! aside=$(fp_set_aside "$area" reclaim); then
        fp_task_unlock "$id"
        continue
      fi
      fp_task_unlock "$id"
      printf '%s\t%s\n' "$aside" "$area" >> "$work/pairs"
      asides+=("$aside")
    done
  fi
  if [ "${#asides[@]}" -gt 0 ]; then
    # The removal boundary (see fp_settle): an orphan has no task, but a
    # process left behind can still work in it, so whether it may go is
    # decided from its frozen contents after a grace window, and the process
    # check only ever adds reasons to keep.
    fp_settle "$work/pairs" "$work/ok" "$work/kept" || true
    asides=()
    while IFS='	' read -r aside area; do asides+=("$aside"); done < "$work/ok"
    while IFS='	' read -r why aside area; do
      case "$why" in
        in-use)
          inuse=$((inuse + 1))
          [ "$inuse" -gt 5 ] || inuse_ids="$inuse_ids${inuse_ids:+, }${area##*/}"
          ;;
        unlisted) unlisted=$((unlisted + 1)) ;;
        linked)
          linked=$((linked + 1))
          [ "$linked" -gt 5 ] || linked_ids="$linked_ids${linked_ids:+, }${area##*/}"
          ;;
        changed)
          changed=$((changed + 1))
          [ "$changed" -gt 5 ] || changed_ids="$changed_ids${changed_ids:+, }${area##*/}"
          ;;
        *)
          kept=$((kept + 1))
          [ "$kept" -gt 5 ] || kept_ids="$kept_ids${kept_ids:+, }${area##*/}"
          ;;
      esac
      [ -e "$aside" ] || [ -L "$aside" ] || continue
      back=$((back + 1))
    done < "$work/kept"
  fi
  if [ "${#asides[@]}" -gt 0 ]; then
    # Removed at once after verification; the reclaimed size comes from the
    # verified snapshot, so nothing slow runs in between.
    fp_remove_verified "$work/ok" "$work/rm" "${asides[@]}" || true
    fp_guard_clear
    for aside in "${asides[@]}"; do
      if kb=$(fp_removed "$work/rm" "$aside"); then
        id=${aside##*/.fm-reclaim-}
        id=${id%.*}
        removed=$((removed + 1))
        removed_kb=$((removed_kb + kb))
        printf '%s\t%s\t-\t-\t%s\t0\tsweep\torphan-removed\t-\n' "$now" "$id" "$kb" >> "$work/ledger"
        continue
      fi
      [ -e "$aside" ] || [ -L "$aside" ] || continue
      leftover=$((leftover + 1))
      [ "$leftover" -gt 5 ] || leftover_names="$leftover_names${leftover_names:+, }${aside##*/}"
    done
    if [ -s "$work/ledger" ] && [ -d "$DATA_DIR" ] && [ ! -L "$DATA_DIR" ] && [ ! -L "$LEDGER" ]; then
      (umask 077 && cat "$work/ledger" >> "$LEDGER") || true
    fi
  fi
  rm -rf "$work"
  [ "$dry" = 1 ] || printf 'Removed %s orphaned scratch area(s), %s.\n' "$removed" "$(fp_human "$removed_kb")"
  if [ "$kept" -gt 0 ]; then
    printf 'Kept %s orphaned scratch area(s) whole because they hold version-controlled work, an unsafe name, or something that could not be checked in full: %s.\n' "$kept" "$kept_ids"
    findings="${findings:+$findings; }$kept orphaned scratch area(s) kept because they hold version-controlled work or could not be checked ($kept_ids)"
  fi
  if [ "$unlisted" -gt 0 ]; then
    if [ -n "$FP_UNLISTED_NAMES" ]; then
      printf 'Kept %s orphaned scratch area(s) because the running processes could not be listed in full: %s cannot be inspected. On Linux, cleanup removes nothing while a process of this user that cannot be inspected, such as ssh-agent or gpg-agent, is running.\n' "$unlisted" "$FP_UNLISTED_NAMES"
      findings="${findings:+$findings; }$unlisted orphaned scratch area(s) kept because the running processes could not be listed ($FP_UNLISTED_NAMES cannot be inspected; Linux cleanup removes nothing while such a process, for example ssh-agent or gpg-agent, runs)"
    else
      printf 'Kept %s orphaned scratch area(s) because the running processes could not be listed in full.\n' "$unlisted"
      findings="${findings:+$findings; }$unlisted orphaned scratch area(s) kept because the running processes could not be listed"
    fi
  fi
  if [ "$linked" -gt 0 ]; then
    printf 'Kept %s orphaned scratch area(s) whole because they hold files hard-linked from elsewhere, such as a package store, whose permissions they share: %s. Remove them by hand once their work is safe.\n' "$linked" "$linked_ids"
    findings="${findings:+$findings; }$linked orphaned scratch area(s) kept because they hold hard-linked files ($linked_ids)"
  fi
  if [ "$inuse" -gt 0 ]; then
    printf 'Kept %s orphaned scratch area(s) a running process still works in or holds open: %s. End that process when its work is safe, and the daily pass removes the area.\n' "$inuse" "$inuse_ids"
    findings="${findings:+$findings; }$inuse orphaned scratch area(s) kept because a process still uses them ($inuse_ids)"
  fi
  if [ "$changed" -gt 0 ]; then
    printf 'Kept %s orphaned scratch area(s) that changed while they waited to be removed: %s.\n' "$changed" "$changed_ids"
    findings="${findings:+$findings; }$changed orphaned scratch area(s) kept because they changed while waiting to be removed ($changed_ids)"
  fi
  if [ "$leftover" -gt 0 ]; then
    printf 'Left %s set-aside scratch folder(s) in %s untouched: %s. Inspect and remove them by hand.\n' "$leftover" "$base" "$leftover_names"
    findings="${findings:+$findings; }$leftover set-aside scratch folder(s) in $base need a look ($leftover_names)"
  fi
  [ "$back" = 0 ] || printf '%s kept area(s) could not be put back under their task name and stay set aside.\n' "$back"
  [ "$busy" = 0 ] || printf 'Skipped %s orphaned scratch area(s) whose task was being spawned.\n' "$busy"
  fp_docker_retry_run "$dry"
  if [ "$FP_DOCKER_PENDING" -gt 0 ]; then
    printf 'Docker cleanup is pending for %s closed task(s).\n' "$FP_DOCKER_PENDING"
    findings="${findings:+$findings; }Docker cleanup is pending for $FP_DOCKER_PENDING closed task(s)"
  fi
  FP_TRIM_FINDING=
  [ -z "$FP_CACHE_CAP_GB" ] || fp_trim_caches "$dry"
  [ -z "$FP_TRIM_FINDING" ] || findings="${findings:+$findings; }$FP_TRIM_FINDING"
  [ -z "$findings" ] || printf 'finding: %s\n' "$findings"
}

# The daily pass can take longer than the watcher allows one check
# (FM_CHECK_TIMEOUT, default 30 s), and a killed check records nothing, so
# check only starts the pass as a detached run in its own process group and
# reports a finished run's finding on a later poll.
DAILY_LOCK="$STATE/.footprint-daily.lock"
DAILY_RESULT="$STATE/.footprint-daily.result"

fp_daily_running() {
  local pid
  [ -d "$DAILY_LOCK" ] || return 1
  pid=$(cat "$DAILY_LOCK/pid" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

cmd_daily_run() {
  local out finding
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
  rm -rf "$DAILY_LOCK.stale.$$" 2>/dev/null
  if ! mkdir "$DAILY_LOCK" 2>/dev/null; then
    fp_daily_running && exit 0
    mv "$DAILY_LOCK" "$DAILY_LOCK.stale.$$" 2>/dev/null && rm -rf "$DAILY_LOCK.stale.$$"
    mkdir "$DAILY_LOCK" 2>/dev/null || exit 0
  fi
  printf '%s\n' "$$" > "$DAILY_LOCK/pid"
  out=$(cmd_sweep 2>&1)
  finding=$(printf '%s\n' "$out" | awk '/^finding: / { sub(/^finding: /, ""); print; exit }')
  case "$out" in
    'fm-footprint: '*) finding=${out#fm-footprint: } ;;
  esac
  { printf 'finished\t%s\n' "$(now_epoch)"; [ -z "$finding" ] || printf 'finding\t%s\n' "$finding"; } \
    > "$DAILY_RESULT.tmp" && mv -f "$DAILY_RESULT.tmp" "$DAILY_RESULT"
  rm -rf "$DAILY_LOCK"
}

cmd_check() {
  local now last finished finding previous reported_at
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
  now=$(now_epoch)
  last=$(awk -F '\t' '$1 == "last_eval" {print $2; exit}' "$CHECK_RECORD" 2>/dev/null)
  previous=$(awk -F '\t' '$1 == "reported" {print $2; exit}' "$CHECK_RECORD" 2>/dev/null)
  reported_at=$(awk -F '\t' '$1 == "result_seen" {print $2; exit}' "$CHECK_RECORD" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # Report a finished run once, and only a finding that changed.
  finished=$(awk -F '\t' '$1 == "finished" {print $2; exit}' "$DAILY_RESULT" 2>/dev/null)
  if [ -n "$finished" ] && [ "$finished" != "${reported_at:-}" ]; then
    finding=$(awk -F '\t' '$1 == "finding" {print $2; exit}' "$DAILY_RESULT" 2>/dev/null)
    if [ -n "$finding" ] && [ "$finding" != "$previous" ]; then
      printf 'footprint: %s\n' "$finding"
    fi
    previous=$finding
    reported_at=$finished
  fi
  if [ $((now - last)) -ge "$CHECK_INTERVAL" ] && ! fp_daily_running; then
    last=$now
    perl -e 'setpgrp(0, 0); exec @ARGV' "$0" daily-run </dev/null >/dev/null 2>&1 &
  fi
  {
    printf 'last_eval\t%s\n' "$last"
    [ -z "$previous" ] || printf 'reported\t%s\n' "$previous"
    [ -z "${reported_at:-}" ] || printf 'result_seen\t%s\n' "$reported_at"
  } > "$CHECK_RECORD.tmp" && mv -f "$CHECK_RECORD.tmp" "$CHECK_RECORD"
}

cmd_arm() {
  local home device want
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  home=$(fm_footprint_physical_dir "$FM_HOME") || die "cannot resolve FM_HOME $FM_HOME"
  device=$(fm_pr_file_device "$STATE") || die "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || die "check shim path is unavailable"
  want=$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-footprint.sh") check")
  (umask 077 && printf '%s\n' "$want" > "$CHECK_SHIM.tmp") || die "cannot write the check shim"
  { chmod 0700 "$CHECK_SHIM.tmp" && mv -f "$CHECK_SHIM.tmp" "$CHECK_SHIM"; } || die "cannot write the check shim"
  FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null || {
    rm -f "$CHECK_SHIM" "$CHECK_TRUST"
    die "could not register the check shim"
  }
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

cmd_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$CHECK_RECORD" "$DAILY_RESULT"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

# --- report ----------------------------------------------------------------

fp_platform() {
  local proc=${FM_PROC_ROOT_OVERRIDE:-/proc}
  case "$FP_OS" in
    Darwin) printf 'macOS\n' ;;
    Linux)
      if grep -qi microsoft "$proc/version" 2>/dev/null; then printf 'Linux (WSL)\n'; else printf 'Linux\n'; fi ;;
    *) printf '%s\n' "$FP_OS" ;;
  esac
}

fp_free_kb() {  # <path>
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }'
}

fp_firstmate_home() {  # <dir>
  [ -f "$1/bin/fm-spawn.sh" ] && [ -f "$1/AGENTS.md" ] && [ -d "$1/state" ]
}

# fp_transcript_rows <days> <out>: "tool<TAB>cwd<TAB>worker<TAB>calls<TAB>fresh<TAB>cache_write<TAB>cache_read<TAB>output<TAB>max_ctx"
fp_transcript_rows() {  # <days> <out>
  local days=$1 out=$2 claude codex
  claude="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  codex="${CODEX_HOME:-$HOME/.codex}/sessions"
  : > "$out"
  if [ -d "$claude" ]; then
    fm_run_timed 120 find "$claude" -name '*.jsonl' -type f -mtime "-$days" -exec grep -Hn -e '"usage":{' \
      -e 'FIRSTMATE_OP: v1 launch-brief' -e 'Firstmate operational input waiting' /dev/null {} + 2>/dev/null | awk '
      function num(s, key,   r) { if (match(s, "\"" key "\":[0-9]+")) { r = substr(s, RSTART, RLENGTH); sub(/.*:/, "", r); return r + 0 } return 0 }
      {
        if (!match($0, /:[0-9]+:/)) next
        file = substr($0, 1, RSTART - 1); ln = substr($0, RSTART + 1, RLENGTH - 2) + 0; body = substr($0, RSTART + RLENGTH)
        if (!(file in seen_file)) { seen_file[file] = 1; order[++nf] = file }
        if (cwd[file] == "" && match(body, /"cwd":"[^"]*"/)) { c = substr(body, RSTART + 7, RLENGTH - 8); cwd[file] = c }
        if (ln <= 40 && (index(body, "FIRSTMATE_OP: v1 launch-brief") || index(body, "Firstmate operational input waiting"))) worker[file] = 1
        p = index(body, "\"usage\":{"); if (!p) next
        u = substr(body, p, 400)
        id = ""
        if (match(body, /"id":"msg_[A-Za-z0-9_]*"/)) id = substr(body, RSTART, RLENGTH)
        if (id != "") { if ((file SUBSEP id) in seen_msg) next; seen_msg[file SUBSEP id] = 1 }
        i = num(u, "input_tokens"); cw = num(u, "cache_creation_input_tokens"); cr = num(u, "cache_read_input_tokens"); o = num(u, "output_tokens")
        calls[file]++; fr[file] += i; cwr[file] += cw; crd[file] += cr; out[file] += o
        ctx = i + cw + cr; if (ctx > mx[file]) mx[file] = ctx
      }
      END { for (k = 1; k <= nf; k++) { f = order[k]; if (calls[f] == 0) continue
        # A subagent transcript (<session>/subagents/*.jsonl) belongs to its parent session'"'"'s lane.
        w = worker[f] + 0; p = index(f, "/subagents/"); if (p) { parent = substr(f, 1, p - 1) ".jsonl"; if (worker[parent]) w = 1 }
        printf "claude\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", cwd[f], w, calls[f], fr[f], cwr[f], crd[f], out[f], mx[f] } }' >> "$out"
  fi
  if [ -d "$codex" ]; then
    fm_run_timed 120 find "$codex" -name '*.jsonl' -type f -mtime "-$days" -exec grep -Hn -e '"type":"session_meta"' -e '"type":"token_count"' \
      -e 'FIRSTMATE_OP: v1 launch-brief' -e 'Firstmate operational input waiting' /dev/null {} + 2>/dev/null | awk '
      function num(s, key,   r) { if (match(s, "\"" key "\":[0-9]+")) { r = substr(s, RSTART, RLENGTH); sub(/.*:/, "", r); return r + 0 } return 0 }
      {
        if (!match($0, /:[0-9]+:/)) next
        file = substr($0, 1, RSTART - 1); ln = substr($0, RSTART + 1, RLENGTH - 2) + 0; body = substr($0, RSTART + RLENGTH)
        if (!(file in seen_file)) { seen_file[file] = 1; order[++nf] = file }
        if (cwd[file] == "" && index(body, "\"type\":\"session_meta\"") && match(body, /"cwd":"[^"]*"/)) cwd[file] = substr(body, RSTART + 7, RLENGTH - 8)
        if (ln <= 40 && (index(body, "FIRSTMATE_OP: v1 launch-brief") || index(body, "Firstmate operational input waiting"))) worker[file] = 1
        if (!index(body, "\"type\":\"token_count\"")) next
        if (match(body, /"total_token_usage":\{[^}]*\}/)) { t = substr(body, RSTART, RLENGTH)
          tot = num(t, "total_tokens"); if (tot != last[file]) { calls[file]++; last[file] = tot }
          ti[file] = num(t, "input_tokens"); tc[file] = num(t, "cached_input_tokens"); tw[file] = num(t, "cache_write_input_tokens"); to[file] = num(t, "output_tokens") }
        if (match(body, /"last_token_usage":\{[^}]*\}/)) { l = substr(body, RSTART, RLENGTH); c = num(l, "input_tokens"); if (c > mx[file]) mx[file] = c }
      }
      END { for (k = 1; k <= nf; k++) { f = order[k]; if (calls[f] == 0) continue
        fresh = ti[f] - tc[f]; if (fresh < 0) fresh = 0
        printf "codex\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", cwd[f], worker[f] + 0, calls[f], fresh, tw[f], tc[f], to[f], mx[f] } }' >> "$out"
  fi
}

# fp_lane_rows <transcript-rows> <out>: "lane<TAB>tool<TAB>sessions<TAB>calls<TAB>fresh<TAB>cw<TAB>cr<TAB>out<TAB>max"
fp_lane_rows() {  # <in> <out>
  local in=$1 out=$2 home cwd lanes
  home=$(fm_footprint_physical_dir "$FM_HOME") || home=$FM_HOME
  lanes="$out.lanes"
  : > "$lanes"
  cut -f2 "$in" | sort -u | while IFS= read -r cwd; do
    if [ -n "$cwd" ] && { [ "$cwd" = "$home" ] || [ "$cwd" = "$FM_HOME" ]; }; then
      printf '%s\tmain\n' "$cwd"
    elif [ -n "$cwd" ] && fp_firstmate_home "$cwd"; then
      printf '%s\tsecondmate\n' "$cwd"
    else
      printf '%s\t-\n' "$cwd"
    fi
  done > "$lanes"
  awk -F '\t' 'NR == FNR { lane[$1] = $2; next }
    { l = lane[$2]; if (l == "-" || l == "") l = ($3 == 1) ? "worker" : "other"
      k = l "\t" $1; s[k]++; c[k] += $4; f[k] += $5; w[k] += $6; r[k] += $7; o[k] += $8; if ($9 > m[k]) m[k] = $9 }
    END { for (k in s) printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", k, s[k], c[k], f[k], w[k], r[k], o[k], m[k] }' "$lanes" "$in" |
    sort > "$out"
  rm -f "$lanes"
}

# fp_leftover_processes <out>: "pid<TAB>mem_kb<TAB>class<TAB>cwd"
fp_leftover_processes() {  # <out>
  local out=$1 procs pid mem cwd rest id key tmp_root tmp_real
  # Per-task temp roots live under FM_FOOTPRINT_TMP_ROOT (default /tmp),
  # matched by its own path and its physical one (/private/tmp on macOS).
  tmp_root=${FM_FOOTPRINT_TMP_ROOT:-/tmp}
  tmp_real=$(fm_footprint_physical_dir "$tmp_root") || tmp_real=$tmp_root
  procs="$out.procs"
  : > "$out"
  # shellcheck source=bin/fm-lane-vitals-lib.sh
  . "$SCRIPT_DIR/fm-lane-vitals-lib.sh"
  fm_lane_vitals_processes "$FP_OS" "$procs" 2>/dev/null || FP_PROCS_UNREADABLE=1
  while IFS='	' read -r pid _ mem _ cwd; do
    [ -n "$cwd" ] || continue
    case "$cwd" in
      "$FP_ROOT"/*)
        rest=${cwd#"$FP_ROOT"/}
        key=${rest%%/*}
        rest=${rest#*/}
        id=${rest%%/*}
        if [ "$key" != "$FP_KEY" ]; then
          printf '%s\t%s\tother-home\t%s\n' "$pid" "$mem" "$cwd" >> "$out"
        elif [ -n "$id" ] && [ ! -e "$STATE/$id.meta" ]; then
          printf '%s\t%s\tno-task\t%s\n' "$pid" "$mem" "$cwd" >> "$out"
        fi
        ;;
      "$tmp_root"/fm-*|"$tmp_real"/fm-*)
        rest=${cwd#"$tmp_root"/fm-}
        [ "$rest" != "$cwd" ] || rest=${cwd#"$tmp_real"/fm-}
        id=${rest%%/*}
        id=${id%%+*}
        [ -n "$id" ] && [ ! -e "$STATE/$id.meta" ] && printf '%s\t%s\tno-task\t%s\n' "$pid" "$mem" "$cwd" >> "$out"
        ;;
    esac
  done < "$procs"
  rm -f "$procs"
}

fp_scratch_summary() {  # sets FP_S_HOME_KB FP_S_HOME_N FP_S_ORPHAN_N FP_S_OTHER_KB
  local area id all
  FP_S_HOME_KB=0 FP_S_HOME_N=0 FP_S_ORPHAN_N=0 FP_S_OTHER_KB=0
  if [ -d "$FP_ROOT/$FP_KEY" ]; then
    FP_S_HOME_KB=$(fp_du_kb "$FP_ROOT/$FP_KEY" 60) || FP_S_HOME_KB=
    for area in "$FP_ROOT/$FP_KEY"/*; do
      [ -d "$area" ] || continue
      id=${area##*/}
      FP_S_HOME_N=$((FP_S_HOME_N + 1))
      [ -e "$STATE/$id.meta" ] || FP_S_ORPHAN_N=$((FP_S_ORPHAN_N + 1))
    done
  fi
  if [ -d "$FP_ROOT" ]; then
    all=$(fp_du_kb "$FP_ROOT" 60) || all=
    case "$all:$FP_S_HOME_KB" in
      *[!0-9:]*|:*|*:) FP_S_OTHER_KB= ;;
      *) FP_S_OTHER_KB=$((all - FP_S_HOME_KB)) ;;
    esac
  fi
}

cmd_report() {  # [--json] [--days N]
  local json=0 days=7 work platform free data_kb data_partial d top tmp_kb tmp_n tmpdir_kb slash_tmp slash_tmp_kb sys_tmp
  local docker_rows docker_lab_c docker_lab_v docker_img_kb caches_total cap name path kb last trim
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --days) _fm_footprint_whole "${2:-}" && [ "$2" -gt 0 ] || die "--days needs a positive whole number"; days=$2; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  fp_config
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-footprint-report.XXXXXX") || die "cannot create a temporary directory"
  platform=$(fp_platform)
  free=$(fp_free_kb "$FM_HOME")
  # One bounded walk of data/ gives both the total and the per-folder sizes.
  : > "$work/top"
  data_kb='' data_partial=0
  : > "$work/du"
  local -a data_entries=()
  [ ! -d "$DATA_DIR" ] || for d in "$DATA_DIR"/* "$DATA_DIR"/.[!.]*; do [ -e "$d" ] || [ -L "$d" ] && data_entries+=("$d"); done
  # A home with no data/ folder, or an empty one, holds no records: 0, not unknown.
  if [ "${#data_entries[@]}" -eq 0 ]; then
    data_kb=0
  else
    # du exits non-zero when part of the tree is unreadable but still prints what
    # it measured: report that as a lower bound marked partial, never a silent total.
    fm_run_timed 120 du -sk "${data_entries[@]}" </dev/null > "$work/du" 2>/dev/null || data_partial=1
  fi
  # Nothing measured at all (a timeout or a wholly unreadable data/) stays unknown.
  [ -s "$work/du" ] || data_partial=0
  if [ -s "$work/du" ]; then
    data_kb=$(awk '{ t += $1 } END { printf "%d\n", t }' "$work/du")
    while IFS='	' read -r kb d; do
      { [ -d "$d" ] && [ ! -L "$d" ] && fp_task_folder "$d"; } || continue
      printf '%s\t%s\n' "$kb" "${d##*/}" >> "$work/top"
    done < "$work/du"
  fi
  top=$(sort -t '	' -k1,1nr "$work/top" | head -3)
  fp_scratch_summary
  tmp_kb=0 tmp_n=0
  slash_tmp=${FM_FOOTPRINT_TMP_ROOT:-/tmp}
  for d in "$slash_tmp"/fm-*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    case "${d##*/}" in *+*) continue ;; esac
    tmp_n=$((tmp_n + 1))
    kb=$(fp_du_kb "$d" 20) && tmp_kb=$((tmp_kb + kb))
  done
  sys_tmp=${FM_FOOTPRINT_SYSTEM_TMPDIR-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}
  sys_tmp=${sys_tmp%/}
  tmpdir_kb=
  [ -z "$sys_tmp" ] || tmpdir_kb=$(fp_du_kb "$sys_tmp" 60) || tmpdir_kb=
  slash_tmp_kb=$(fp_du_kb "$slash_tmp" 60) || slash_tmp_kb=
  : > "$work/docker"
  docker_lab_c=0 docker_lab_v=0 docker_img_kb=
  if fp_docker_up; then
    fp_docker 15 system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Active}}\t{{.Size}}\t{{.Reclaimable}}' > "$work/docker"
    docker_lab_c=$(fp_docker 15 ps -a --filter "label=firstmate.task" --format '{{.Label "firstmate.task"}}' | grep -c "^$FP_KEY/" || true)
    docker_lab_v=$(fp_docker 15 volume ls --filter "label=firstmate.task" --format '{{.Label "firstmate.task"}}' | grep -c "^$FP_KEY/" || true)
    if [ "$FP_OS" = Darwin ]; then
      d="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
      [ ! -f "$d" ] || docker_img_kb=$(du -k "$d" 2>/dev/null | awk '{print $1}')
    fi
  fi
  docker_rows=$(cat "$work/docker")
  fp_caches_table "$work/caches"
  caches_total=$(fp_table_total_kb "$work/caches")
  cap=$(fp_cap_kb) || cap=
  FP_PROCS_UNREADABLE=0
  fp_leftover_processes "$work/procs"
  fp_transcript_rows "$days" "$work/transcripts"
  fp_lane_rows "$work/transcripts" "$work/lanes"
  if [ "$json" = 1 ]; then
    jq -n \
      --arg platform "$platform" --arg host "$(hostname 2>/dev/null || printf unknown)" \
      --arg free "${free:-}" --arg data "${data_kb:-}" --arg data_partial "$data_partial" --arg top "$top" \
      --arg s_home "${FP_S_HOME_KB:-}" --arg s_n "$FP_S_HOME_N" --arg s_orph "$FP_S_ORPHAN_N" --arg s_other "${FP_S_OTHER_KB:-}" \
      --arg root "$FP_ROOT" --arg key "$FP_KEY" \
      --arg tmp_kb "$tmp_kb" --arg tmp_n "$tmp_n" --arg sys_tmp "$sys_tmp" --arg sys_tmp_kb "${tmpdir_kb:-}" --arg slash_tmp "${slash_tmp_kb:-}" \
      --arg docker_state "$FP_DOCKER_STATE" --arg docker_rows "$docker_rows" --arg lab_c "$docker_lab_c" --arg lab_v "$docker_lab_v" --arg img "${docker_img_kb:-}" \
      --rawfile caches "$work/caches" --arg cap "${cap:-}" --arg ctotal "$caches_total" \
      --rawfile procs "$work/procs" --arg procs_unreadable "$FP_PROCS_UNREADABLE" \
      --rawfile lanes "$work/lanes" --arg days "$days" '
      def n: if . == "" then null else (tonumber? // null) end;
      def rows: split("\n") | map(select(length > 0) | split("\t"));
      { schema: "fm-footprint-report.v1", host: $host, platform: $platform, free_kb: ($free | n),
        disk: { records_and_evidence_kb: ($data | n), records_and_evidence_partial: ($data_partial == "1"),
                largest_task_folders: ($top | rows | map({ task: .[1], kb: (.[0] | n) })),
                scratch: { root: $root, home_key: $key, this_home_kb: ($s_home | n), areas: ($s_n | n), areas_without_task: ($s_orph | n), other_homes_kb: ($s_other | n) },
                task_temp_roots: { count: ($tmp_n | n), kb: ($tmp_kb | n) },
                system_temp: { path: (if $sys_tmp == "" then null else $sys_tmp end), kb: ($sys_tmp_kb | n), slash_tmp_kb: ($slash_tmp | n) } },
        docker: { state: (if $docker_state == "up" then "running" else "not present" end),
                  types: ($docker_rows | rows | map({ type: .[0], total: (.[1] | n), active: (.[2] | n), size: .[3], reclaimable: .[4] })),
                  labelled_for_this_home: { containers: ($lab_c | n), volumes: ($lab_v | n) },
                  disk_image_kb: ($img | n) },
        caches: { cap_kb: ($cap | n), total_kb: ($ctotal | n),
                  entries: ($caches | rows | map({ name: .[0], path: .[1], kb: (.[2] | n), last_used: (.[3] | n), trim: (if .[4] == "-" then null else .[4] end) })) },
        leftover_processes: { unreadable: ($procs_unreadable == "1"),
                  entries: ($procs | rows | map({ pid: (.[0] | n), mem_kb: (.[1] | n), class: .[2], cwd: .[3] })) },
        allowance: { days: ($days | n), unmeasured_tools: "every tool other than claude and codex",
                  lanes: ($lanes | rows | map({ lane: .[0], tool: .[1], sessions: (.[2] | n), calls: (.[3] | n), fresh: (.[4] | n), cache_write: (.[5] | n), cache_read: (.[6] | n), output: (.[7] | n), largest_context: (.[8] | n) })) } }'
    rm -rf "$work"
    return 0
  fi
  printf 'Footprint report - %s (%s) - %s\n' "$(hostname 2>/dev/null || printf unknown)" "$platform" "$(date -u '+%Y-%m-%d %H:%M UTC')"
  printf 'Free disk where this home lives: %s\n\n' "$(fp_human "$free")"
  printf 'Disk by kind\n'
  if [ "$data_partial" = 1 ]; then
    printf '  records and evidence (data/)      at least %s (part of data/ was unreadable)\n' "$(fp_human "$data_kb")"
  else
    printf '  records and evidence (data/)      %s\n' "$(fp_human "$data_kb")"
  fi
  if [ -n "$top" ]; then
    printf '%s\n' "$top" | while IFS='	' read -r kb name; do printf '    largest task folder: %s %s\n' "$name" "$(fp_human "$kb")"; done
  fi
  printf '  task scratch, this home           %s in %s area(s), %s without a live task (%s/%s)\n' \
    "$(fp_human "$FP_S_HOME_KB")" "$FP_S_HOME_N" "$FP_S_ORPHAN_N" "$FP_ROOT" "$FP_KEY"
  printf '  task scratch, other homes         %s\n' "$(fp_human "$FP_S_OTHER_KB")"
  printf '  task temp roots (/tmp/fm-*)       %s in %s\n' "$(fp_human "$tmp_kb")" "$tmp_n"
  [ -z "$sys_tmp" ] || printf '  system temp (%s)  %s\n' "$sys_tmp" "$(fp_human "$tmpdir_kb")"
  printf '  /tmp                              %s\n\n' "$(fp_human "$slash_tmp_kb")"
  printf 'Docker\n'
  if [ "$FP_DOCKER_STATE" != up ]; then
    printf '  not present\n\n'
  else
    printf '%s\n' "$docker_rows" | while IFS='	' read -r type total active size recl; do
      [ -n "$type" ] && printf '  %-14s %4s total, %4s active, %9s, %s reclaimable\n' "$type" "$total" "$active" "$size" "$recl"
    done
    printf '  labelled for this home: %s container(s), %s volume(s)\n' "$docker_lab_c" "$docker_lab_v"
    [ -z "$docker_img_kb" ] || printf '  Docker disk image on disk: %s\n' "$(fp_human "$docker_img_kb")"
    printf '\n'
  fi
  printf 'Shared caches: %s' "$(fp_human "$caches_total")"
  if [ -n "$cap" ]; then printf ' of a %s GB cap\n' "$FP_CACHE_CAP_GB"; else printf ' (no cap set; report only)\n'; fi
  while IFS='	' read -r name path kb last trim; do
    printf '  %-12s %10s  last used %-10s %s\n' "$name" "$(fp_human "$kb")" "$(fp_age "$last")" \
      "$( [ "$trim" = - ] && printf 'no trim command' || printf 'trim: %s' "$trim")"
  done < "$work/caches"
  printf '\nLeftover processes: %s' "$(grep -c . "$work/procs" || true)"
  [ "$FP_PROCS_UNREADABLE" = 0 ] && printf '\n' || printf ' (process table only partly readable)\n'
  while IFS='	' read -r pid mem class cwd; do
    printf '  pid %-7s %10s  %-10s %s\n' "$pid" "$(fp_human "$mem")" "$class" "$cwd"
  done < "$work/procs"
  printf '\nAllowance used, last %s days, from transcripts (tokens; tools other than claude and codex unmeasured)\n' "$days"
  if [ ! -s "$work/lanes" ]; then
    printf '  no transcripts found\n'
  else
    printf '  %-10s %-6s %8s %8s %14s %14s %16s %12s %14s\n' lane tool sessions calls fresh cache-write cache-read output largest-ctx
    while IFS='	' read -r lane tool s c f w r o m; do
      printf '  %-10s %-6s %8s %8s %14s %14s %16s %12s %14s\n' "$lane" "$tool" "$s" "$c" "$f" "$w" "$r" "$o" "$m"
    done < "$work/lanes"
  fi
  rm -rf "$work"
}

# Help anywhere prints help and does nothing else, and a command that takes
# positions never reads a flag as one, so no mistyped command removes anything.
for fp_arg in "$@"; do
  case "$fp_arg" in -h|--help) sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;; esac
done
case "${1:-}" in
  task-close|owns-scratch)
    for fp_arg in "${@:2}"; do
      case "$fp_arg" in -*) printf 'fm-footprint: unknown argument: %s\n' "$fp_arg" >&2; usage >&2; exit 2 ;; esac
    done ;;
esac
case "${1:-}" in
  report) shift; cmd_report "$@" ;;
  task-close)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage >&2; exit 2; }
    cmd_task_close "$2" "$3" "${4:-}" ;;
  caches) shift; fp_only_flags "--json" "$@"; cmd_caches "$@" ;;
  trim-caches) shift; fp_only_flags "--dry-run" "$@"; cmd_trim_caches "$@" ;;
  old-tasks) shift; cmd_old_tasks "$@" ;;
  sweep) shift; fp_only_flags "--dry-run" "$@"; cmd_sweep "$@" ;;
  owns-scratch)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    cmd_owns_scratch "$2" "$3" ;;
  check) shift; fp_only_flags "" "$@"; cmd_check ;;
  daily-run) shift; fp_only_flags "" "$@"; cmd_daily_run ;;
  arm) shift; fp_only_flags "" "$@"; cmd_arm ;;
  disarm) shift; fp_only_flags "" "$@"; cmd_disarm ;;
  -h|--help|help) sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0" ;;
  *) usage >&2; exit 2 ;;
esac

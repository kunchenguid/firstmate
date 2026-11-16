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
# Every command takes only the flags shown: anything else exits 2 before
# anything is read or removed, and -h or --help after any command prints this
# help and does nothing else.
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
#   Every measurement is bounded (du 60 s per path, docker 15 s, lsof 8 s) and
#   an unmeasurable value prints as "unknown" rather than failing the report.
#   FM_FOOTPRINT_TMP_ROOT (default /tmp) and FM_FOOTPRINT_SYSTEM_TMPDIR
#   (default the macOS per-user temp directory, empty for none) replace the
#   temp directories measured (tests and diagnosis).
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
#   - nothing in the area needs a landing proof it lacks: every git
#     repository inside (a checkout or a bare repository) passes the landing
#     proof below, no name inside holds a control character, and the scan
#     completes. The task's own landed-work checks cover its own copy only, so
#     an area holding a checkout whose work has not landed is kept whole and
#     named, and the daily pass keeps reporting it.
#   The area is first renamed to a hidden name beside it, then removed, so a
#   spawn reusing the task id always gets a fresh area. Removal stays on one
#   filesystem and never follows links. When the Docker daemon answers within
#   its bound, it then removes the containers (with their anonymous volumes),
#   networks, volumes, and images carrying the task's firstmate.task label or
#   its compose project label, and never anything else: no prune, no name
#   match. Docker absent is a normal case and is skipped. When a listing fails
#   (unknown), some objects remain (partial), or the daemon does not answer
#   (down), the task is queued in state/footprint-docker-retry for the daily
#   pass. It appends one line to
#   data/footprint-ledger.tsv (mode 0600): epoch, task, project, kept KB
#   (data/<task-id>/), scratch KB, Docker objects verified removed, Docker
#   status (removed, partial, unknown, down, absent), scratch status (removed,
#   partial, refused, kept-unlanded, none), and "oversized" when the kept
#   folder is over
#   keep-warn-mb (else "-"). An oversized folder is named in the summary and
#   kept whole: nothing kept is ever removed for its size. Every step is best
#   effort and the steps are independent, not one transaction: it always exits
#   0 and prints one summary line, so a failure is visible but never fails
#   cleanup.
#
# Landing proof (for a checkout or bare repository found in a scratch area or
#   an old task folder): a checkout must be its own top level with no
#   uncommitted, untracked, or stashed change and only rebuildable-layout
#   ignored files; for either kind, HEAD, every local branch, and every tag
#   must be contained in a remote-tracking ref other than
#   refs/remotes/no-mistakes/*, the local validation gate. Any git error or
#   timeout (60 s per call) means "not landed". git runs with
#   GIT_OPTIONAL_LOCKS=0, so the proof never rewrites the index.
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
#   old-task-days). One bounded scan reads each folder's whole tree; a folder
#   holding any name with a control character, or whose scan does not
#   complete, offers nothing. Only two kinds of entry are offered, never
#   nested in each other:
#   - the outermost directory whose name is a known rebuildable layout
#     (node_modules, .venv, venv, .tox, .nox, __pycache__, .pytest_cache,
#     .mypy_cache, .ruff_cache, .next, .turbo, .parcel-cache, .gradle,
#     .terraform, .pnpm-store, .npm, .uv-cache, ms-playwright, .cache) that
#     holds no repository and no record (brief.md, launch-brief.md, report.md,
#     evidence.md, backlog.md, *.meta, status*.log, decision*,
#     dispatch-resolution.json) and is not inside a repository: the name
#     makes a candidate, the contents decide;
#   - a repository root, not inside another repository or a rebuildable
#     directory, holding no further repository, that passes the landing proof
#     above (its rebuildable directories go with it).
#   Each entry's physical path must be its folder's physical path plus the
#   same relative path. Files are never offered, so records, reports,
#   decisions, and the task list (data/backlog.md) never are, and neither is
#   children/. The preview prints every entry with its size and writes
#   state/footprint-old-tasks.preview naming a preview id: the SHA-256 of the
#   entry list together with the device, inode, type, size, modification and
#   change times of everything under each entry and the SHA-256 of every
#   file's contents. --apply <id> recomputes the selection and its id and
#   removes the list only when both are identical, so a same-size edit, a
#   replaced entry, or an added or removed entry refuses and removes nothing;
#   each entry is then rechecked and set aside under its task's spawn lock
#   before removal. Removal is the captain's decision: apply only a preview
#   the captain approved.
#
# sweep [--dry-run]
#   The daily pass, rebuildable classes only. When this home's key directory
#   passes the ownership test, it removes the scratch areas there whose task
#   has no record, that are older than orphan-grace-hours, and that hold
#   nothing needing a landing proof it lacks; each is removed only after
#   taking that task's spawn lock (bin/fm-spawn.sh holds it from before it
#   makes the area until the task is recorded), rechecking that no record
#   exists, and renaming the area aside, so a spawn reusing the id either is
#   recorded first and keeps its area or starts later with a fresh one. It
#   then retries queued Docker cleanups while Docker answers, and runs
#   trim-caches when a cap is set. It prints one finding line naming kept
#   areas that hold unlanded work, an untrusted key directory, pending Docker
#   cleanups, and caches still over the cap or a failed trim command.
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

# fp_remove_tree <dir>: removes a directory tree without leaving its
# filesystem; read-only directories (a Go module cache) are made writable
# first. Returns 1 when anything is left behind.
fp_remove_tree() {  # <dir>
  local dir=$1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  fm_run_timed 600 find "$dir" -xdev -type d ! -perm -u+w -exec chmod u+w {} + </dev/null 2>/dev/null || true
  fm_run_timed 600 find "$dir" -xdev -depth -delete </dev/null 2>/dev/null || true
  [ ! -e "$dir" ] && [ ! -L "$dir" ]
}

# A name holding a control character (a newline above all) would make one
# path read as two, so any tree holding one is never inspected or removed.
FP_CTRL_GLOB=$(printf '*[\001-\037\177]*')

# fp_names_unsafe <dir>: 0 when a name under <dir> holds a control character
# or the tree could not be read in full.
fp_names_unsafe() {  # <dir>
  local out
  out=$(fm_run_timed 120 find "$1" -xdev -name "$FP_CTRL_GLOB" -print -quit </dev/null 2>/dev/null) || return 0
  [ -n "$out" ]
}

# fp_repo_roots <dir>: every git repository under <dir>, one root per line: a
# directory holding .git (a directory or a worktree file) and a bare
# repository (HEAD beside objects/ and refs/). Returns 1 when the scan could
# not complete. Call only after fp_names_unsafe found nothing.
fp_repo_roots() {  # <dir>
  local out line d
  out=$(fm_run_timed 120 find "$1" -xdev \( -name .git -o \( -type f -name HEAD \) \) -print </dev/null 2>/dev/null) || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      */.git) printf '%s\n' "${line%/.git}" ;;
      */.git/*) ;;
      */HEAD)
        d=${line%/HEAD}
        [ -d "$d/objects" ] && [ -d "$d/refs" ] && printf '%s\n' "$d"
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

# Read-only git: GIT_OPTIONAL_LOCKS=0 keeps status from refreshing the index,
# so a landing proof never changes the tree the preview fingerprints.
fp_git() {  # <repo> <args...>
  local repo=$1
  shift
  GIT_OPTIONAL_LOCKS=0 fm_run_timed 60 git -C "$repo" "$@" </dev/null 2>/dev/null
}

# fp_checkout_landed <repo>: every commit of the repository exists on a
# remote other than the local validation gate. For a checkout: it is its own
# top level, has no uncommitted, untracked, or stashed changes, and its
# ignored files are only rebuildable layouts. For checkout and bare
# repository alike: HEAD, every local branch, and every tag are contained in a
# remote-tracking ref other than refs/remotes/no-mistakes/*, which is the
# local validation gate rather than a published copy (the same exclusion
# bin/fm-teardown.sh makes). Any git failure or timeout is "not landed".
fp_checkout_landed() {  # <repo>
  local d=$1 bare top st line path base stash locals head remotes extra
  bare=$(fp_git "$d" rev-parse --is-bare-repository) || return 1
  if [ "$bare" != true ]; then
    top=$(fp_git "$d" rev-parse --show-toplevel) || return 1
    [ "$(fm_footprint_physical_dir "$top")" = "$(fm_footprint_physical_dir "$d")" ] || return 1
    st=$(fp_git "$d" status --porcelain --ignored) || return 1
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in '!! '*) ;; *) return 1 ;; esac
      path=${line#!! }
      path=${path%/}
      base=${path##*/}
      fp_rebuildable_name "$base" || return 1
    done <<EOF
$st
EOF
    stash=$(fp_git "$d" stash list) || return 1
    [ -z "$stash" ] || return 1
    head=$(fp_git "$d" rev-parse --verify -q HEAD) || head=
  else
    head=
    [ -z "$(fp_git "$d" for-each-ref refs/stash)" ] || return 1
  fi
  locals=$(fp_git "$d" for-each-ref --format='%(objectname)' refs/heads refs/tags) || return 1
  locals=$(printf '%s\n%s\n' "$head" "$locals" | awk 'NF && !seen[$0]++')
  [ -n "$locals" ] || return 0
  remotes=$(fp_git "$d" for-each-ref --format='%(refname)' refs/remotes) || return 1
  remotes=$(printf '%s\n' "$remotes" | awk 'NF && $0 !~ /^refs\/remotes\/no-mistakes\//')
  [ -n "$remotes" ] || return 1
  # shellcheck disable=SC2086 # object names and ref names are single words
  extra=$(fp_git "$d" rev-list --max-count=1 $locals --not $remotes) || return 1
  [ -z "$extra" ]
}

# fp_tree_disposable <dir>: 0 when nothing under <dir> needs a landing proof
# it lacks. Sets FP_UNLANDED to the first blocking repository or reason.
fp_tree_disposable() {  # <dir>
  local roots r
  FP_UNLANDED=
  if fp_names_unsafe "$1"; then
    FP_UNLANDED="a name with a control character, or an unreadable entry, under $1"
    return 1
  fi
  roots=$(fp_repo_roots "$1") || { FP_UNLANDED="could not scan $1 for checkouts"; return 1; }
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    fp_checkout_landed "$r" || { FP_UNLANDED=$r; return 1; }
  done <<EOF
$roots
EOF
  return 0
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

# fp_set_aside <dir> <tag>: renames a validated directory to a hidden name
# beside it, so a spawn that reuses the task id afterwards gets a fresh area
# and the removal works only on what was validated. Prints the new path.
fp_set_aside() {  # <dir> <tag>
  local dir=$1 parent n=0 to
  parent=${dir%/*}
  to="$parent/.fm-$2-${dir##*/}.$$"
  while [ -e "$to" ] || [ -L "$to" ]; do n=$((n + 1)); to="$parent/.fm-$2-${dir##*/}.$$.$n"; done
  mv -- "$dir" "$to" 2>/dev/null || return 1
  printf '%s\n' "$to"
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

# fp_docker_task_remove <id>: sets FP_DOCKER_REMOVED (objects verified gone)
# and FP_DOCKER_RESULT: removed (none left), partial (some remain), unknown
# (an inventory could not be taken), absent, or down.
fp_docker_task_remove() {  # <id>
  local id=$1 label compose kind ids before=0 after=0 n failed=0
  FP_DOCKER_REMOVED=0
  if ! fp_docker_up; then
    FP_DOCKER_RESULT=$FP_DOCKER_STATE
    return 0
  fi
  label=$(fm_footprint_docker_label "$FP_KEY" "$id")
  compose=$(fm_footprint_compose_project "$FP_KEY" "$id") || { FP_DOCKER_RESULT=unknown; return 0; }
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
# daemon that did not answer): "id<TAB>epoch" lines the daily pass retries.
DOCKER_RETRY="$STATE/footprint-docker-retry"

fp_docker_retry_add() {  # <id>
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ ! -L "$DOCKER_RETRY" ] || return 1
  grep -q "^$1	" "$DOCKER_RETRY" 2>/dev/null && return 0
  (umask 077 && printf '%s\t%s\n' "$1" "$(now_epoch)" >> "$DOCKER_RETRY")
}

# fp_docker_retry_run <dry>: retries each listed closed task's Docker cleanup
# while Docker answers; sets FP_DOCKER_PENDING to the tasks still pending.
fp_docker_retry_run() {  # <dry>
  local dry=$1 id at keep='' n=0
  FP_DOCKER_PENDING=0
  [ -f "$DOCKER_RETRY" ] && [ ! -L "$DOCKER_RETRY" ] || return 0
  while IFS='	' read -r id at; do
    [ -n "$id" ] || continue
    fm_task_id_path_safe "$id" || continue
    if [ "$dry" = 1 ] || fp_task_live "$id" || ! fp_docker_up; then
      keep="$keep$id	$at
"
      n=$((n + 1))
      continue
    fi
    fp_docker_task_remove "$id"
    if [ "$FP_DOCKER_RESULT" = removed ]; then
      fp_ledger_append "$(now_epoch)" "$id" - - 0 "$FP_DOCKER_REMOVED" docker-retry removed - || true
    else
      keep="$keep$id	$at
"
      n=$((n + 1))
    fi
  done < "$DOCKER_RETRY"
  FP_DOCKER_PENDING=$n
  [ "$dry" = 1 ] && return 0
  if [ -n "$keep" ]; then
    (umask 077 && printf '%s' "$keep" > "$DOCKER_RETRY.tmp" && mv -f "$DOCKER_RETRY.tmp" "$DOCKER_RETRY")
  else
    rm -f "$DOCKER_RETRY"
  fi
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
  local id=$1 scratch=$2 project=${3:-} kept scratch_kb=0 scratch_result=none oversized=- aside
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
  if [ -n "$scratch" ] && { [ -e "$scratch" ] || [ -L "$scratch" ]; }; then
    if ! fp_scratch_owned "$scratch" "$id"; then
      scratch_result=refused
    elif ! fp_tree_disposable "$scratch"; then
      # The landed-work checks cover the task's own copy, not a checkout the
      # worker made inside its scratch area, so that one needs its own proof.
      scratch_result='kept-unlanded'
      scratch_kb=$(fp_du_kb "$scratch" 60) || scratch_kb=
    else
      scratch_kb=$(fp_du_kb "$scratch" 60) || scratch_kb=
      if aside=$(fp_set_aside "$scratch" closing) && fp_remove_tree "$aside"; then
        scratch_result=removed
      else
        scratch_result=partial
      fi
    fi
  fi
  fp_docker_task_remove "$id"
  case "$FP_DOCKER_RESULT" in partial|unknown|down) fp_docker_retry_add "$id" || true ;; esac
  kept=$(fp_du_kb "$DATA_DIR/$id" 30) || kept=
  oversized=-
  case "$kept" in ''|*[!0-9]*) ;; *) [ "$kept" -le $((FP_KEEP_WARN_MB * 1024)) ] || oversized=oversized ;; esac
  fp_ledger_append "$(now_epoch)" "$id" "${project:--}" "${kept:-unknown}" "${scratch_kb:-unknown}" \
    "$FP_DOCKER_REMOVED" "$FP_DOCKER_RESULT" "$scratch_result" "$oversized" || true
  case "$scratch_result" in
    refused) printf 'footprint: %s scratch path %s is not this home'"'"'s area for the task; left it in place. ' "$id" "$scratch" ;;
    partial) printf 'footprint: %s scratch area %s was only partly removed. ' "$id" "$scratch" ;;
    kept-unlanded) printf 'footprint: %s scratch area %s kept whole (%s): %s holds work that has not landed; land it, then remove the area. ' \
      "$id" "$scratch" "$(fp_human "$scratch_kb")" "$FP_UNLANDED" ;;
    *) printf 'footprint: %s scratch %s (%s). ' "$id" "$scratch_result" "$(fp_human "$scratch_kb")" ;;
  esac
  case "$FP_DOCKER_RESULT" in
    absent) printf 'Docker not present.' ;;
    down) printf 'Docker did not answer; its cleanup is queued for the daily pass.' ;;
    unknown) printf 'Docker did not list the task'"'"'s objects; its cleanup is queued for the daily pass.' ;;
    partial) printf 'Docker: %s labelled object(s) removed, some remain; the rest is queued for the daily pass.' "$FP_DOCKER_REMOVED" ;;
    *) printf 'Docker: %s labelled object(s) %s.' "$FP_DOCKER_REMOVED" "$FP_DOCKER_RESULT" ;;
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

fp_under() {  # <path> <list>: 0 when <path> is inside (or is) a path in <list>
  local p=$1 q
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    case "$p/" in "$q/"*) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

fp_holds() {  # <dir> <list>: 0 when a path in <list> lies strictly inside <dir>
  local d=$1 q
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    case "$q" in "$d"/*) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

# fp_folder_entries <folder>: "kind<TAB>path" rows for one finished task
# folder, from one bounded scan of its whole tree. Prints nothing when any
# name in it holds a control character or the scan did not complete, so such
# a folder is never offered. Offered entries never nest:
#   rebuildable      the outermost directory with a rebuildable name that
#                    holds no repository and no record, and is not inside a
#                    repository;
#   landed-checkout  a repository root holding no further repository, not
#                    inside another repository or a rebuildable directory,
#                    whose work fp_checkout_landed proves landed.
fp_scan_args() {  # sets FP_SCAN_REBUILD: the rebuildable-name tests of an old-folder scan
  local expr='' name
  for name in $FP_REBUILDABLE_NAMES; do expr="$expr${expr:+ -o }-name $name"; done
  FP_SCAN_REBUILD=$expr
}

# fp_folder_scan <folder>...: one bounded scan of whole folder trees, printing
# repository markers, records, and rebuildable-named directories, plus the
# line FM-CONTROL-NAME (and stopping) at the first name holding a control
# character. Returns 1 when the scan did not complete.
fp_folder_scan() {  # <folder>...
  fp_scan_args
  # shellcheck disable=SC2086 # FP_SCAN_REBUILD and FP_RECORD_TESTS are fixed lists of find tests
  (set -f; fm_run_timed 300 find "$@" -xdev \
    \( -name "$FP_CTRL_GLOB" -exec printf '%s\n' FM-CONTROL-NAME \; -quit \) \
    -o \( -name .git -print -prune \) \
    -o \( -type f \( -name HEAD -o $FP_RECORD_TESTS \) -print \) \
    -o \( -type d \( $FP_SCAN_REBUILD \) -print \) </dev/null 2>/dev/null)
}

# fp_folder_entries <folder>: fp_folder_classify over its own scan.
fp_folder_entries() {  # <folder>
  local scan
  scan=$(fp_folder_scan "$1") || return 0
  fp_folder_classify "$1" "$scan"
}

# fp_folder_classify <folder> <scan>: "kind<TAB>path" rows for one finished
# task folder from its scan. Prints nothing when the scan saw a name with a
# control character or a line outside the folder, so such a folder is never
# offered. Offered entries never nest:
#   rebuildable      the outermost directory with a rebuildable name that
#                    holds no repository and no record, and is not inside a
#                    repository;
#   landed-checkout  a repository root holding no further repository, not
#                    inside another repository or a rebuildable directory,
#                    whose work fp_checkout_landed proves landed.
fp_folder_classify() {  # <folder> <scan>
  local folder=$1 scan=$2 folder_real line rebuild='' repos='' records='' cand d
  case "$scan" in *FM-CONTROL-NAME*) return 0 ;; esac
  folder_real=$(fm_footprint_physical_dir "$folder") || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$folder"/*) ;;
      *) return 0 ;;
    esac
    case "$line" in
      */.git/*) ;;
      */.git) repos="$repos${line%/.git}
" ;;
      */HEAD)
        d=${line%/HEAD}
        if [ -d "$d/objects" ] && [ -d "$d/refs" ]; then repos="$repos$d
"; fi
        ;;
      *)
        if [ -d "$line" ] && [ ! -L "$line" ]; then rebuild="$rebuild$line
"
        else records="$records$line
"; fi
        ;;
    esac
  done <<EOF
$scan
EOF
  # Records at the folder's own top level are the task's records, never inside a candidate.
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    case "$cand" in "$folder/children"|"$folder/children/"*) continue ;; esac
    fp_under "${cand%/*}" "$rebuild" && continue
    fp_under "$cand" "$repos" && continue
    fp_holds "$cand" "$repos" && continue
    fp_holds "$cand" "$records" && continue
    fp_entry_contained "$cand" "$folder" "$folder_real" || continue
    printf 'rebuildable\t%s\n' "$cand"
  done <<EOF
$rebuild
EOF
  while IFS= read -r cand; do
    [ -n "$cand" ] && [ "$cand" != "$folder" ] || continue
    case "$cand" in "$folder/children"|"$folder/children/"*) continue ;; esac
    fp_under "${cand%/*}" "$repos" && continue
    fp_under "$cand" "$rebuild" && continue
    fp_holds "$cand" "$repos" && continue
    fp_entry_contained "$cand" "$folder" "$folder_real" || continue
    fp_checkout_landed "$cand" || continue
    printf 'landed-checkout\t%s\n' "$cand"
  done <<EOF
$repos
EOF
}

# fp_entry_contained <entry> <folder> <folder-physical>: <entry> is a real
# directory, not a link, whose physical path is the folder's own path plus
# the same relative path, so nothing outside the folder can be named.
fp_entry_contained() {  # <entry> <folder> <folder-physical>
  local real
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  real=$(fm_footprint_physical_dir "$1") || return 1
  [ "$real" = "$3/${1#"$2"/}" ]
}

# fp_classify_grouped <scan>: classifies a scan over several folders, whose
# lines find prints grouped by folder in argument order.
fp_classify_grouped() {  # <scan>
  local scan=$1 line folder current='' chunk=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in "$DATA_DIR"/*) ;; *) continue ;; esac
    folder=${line#"$DATA_DIR"/}
    folder="$DATA_DIR/${folder%%/*}"
    if [ "$folder" != "$current" ]; then
      [ -z "$current" ] || fp_folder_classify "$current" "$chunk"
      current=$folder
      chunk=''
    fi
    chunk="$chunk$line
"
  done <<EOF
$scan
EOF
  [ -z "$current" ] || fp_folder_classify "$current" "$chunk"
}

# fp_old_task_entries <days> <out>: "kind<TAB>kb<TAB>path" rows, sorted.
fp_old_task_entries() {  # <days> <out>
  local days=$1 out=$2 now cutoff folder id newest kind entry scan
  local -a folders=()
  now=$(now_epoch)
  cutoff=$((now - days * 86400))
  : > "$out.kinds"
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
  # One scan across every eligible folder; when it meets a name with a
  # control character (and stops), each folder is scanned on its own instead,
  # so only the folder holding that name is withheld.
  if [ "${#folders[@]}" -gt 0 ]; then
    if scan=$(fp_folder_scan "${folders[@]}") && case "$scan" in *FM-CONTROL-NAME*) false ;; *) true ;; esac; then
      fp_classify_grouped "$scan" >> "$out.kinds"
    else
      for folder in "${folders[@]}"; do fp_folder_entries "$folder" >> "$out.kinds"; done
    fi
  fi
  # One bounded du for every entry; an entry it could not measure is not offered.
  local -a paths=()
  while IFS='	' read -r kind entry; do paths+=("$entry"); done < "$out.kinds"
  fp_du_many "$out.du" "${paths[@]+"${paths[@]}"}"
  awk -F '\t' 'NR == FNR { kb[$2] = $1; next } ($2 in kb) { print $1 "\t" kb[$2] "\t" $2 }' "$out.du" "$out.kinds" |
    sort -t '	' -k3,3 > "$out"
  rm -f "$out.kinds" "$out.du"
}

fp_sha256_stream() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}

# fp_old_task_id <rows>: the preview id: the SHA-256 of the rows together with
# the identity of everything under each offered entry - device, inode, type,
# size, modification and change times of every entry, and the SHA-256 of every
# file's contents - so a same-size edit, a replaced entry, or any added or
# removed entry changes it. Returns 1 when that could not be read in full.
fp_old_task_id() {  # <rows>
  local rows=$1 kind kb entry listing sums sumtool
  local -a paths=()
  while IFS='	' read -r kind kb entry; do [ -n "$entry" ] && paths+=("$entry"); done < "$rows"
  if [ "${#paths[@]}" -gt 0 ]; then
    if [ "$FP_OS" = Darwin ]; then
      listing=$(fm_run_timed 600 find "${paths[@]}" -xdev -exec /usr/bin/stat -f '%d %i %HT %z %m %c %N' {} + </dev/null 2>/dev/null) || return 1
    else
      listing=$(fm_run_timed 600 find "${paths[@]}" -xdev -exec stat -c '%d %i %F %s %Y %Z %n' {} + </dev/null 2>/dev/null) || return 1
    fi
    if command -v shasum >/dev/null 2>&1; then sumtool='shasum -a 256'; else sumtool=sha256sum; fi
    # shellcheck disable=SC2086 # sumtool is a fixed command and its flags
    sums=$(fm_run_timed 600 find "${paths[@]}" -xdev -type f -exec $sumtool {} + </dev/null 2>/dev/null) || return 1
  else
    listing='' sums=''
  fi
  { cat "$rows"; printf '%s\n' "$listing" | sort; printf '%s\n' "$sums" | sort; } | fp_sha256_stream
}

cmd_old_tasks() {  # [--days N] | --apply <id>
  local days apply='' tmp id want total kind kb entry task folder aside
  fp_config
  days=$FP_OLD_TASK_DAYS
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) fp_only_flags "" --help ;;
      --days) _fm_footprint_whole "${2:-}" || die "--days needs a whole number"; days=$2; shift 2 ;;
      --apply) [ -n "${2:-}" ] || die "--apply needs a preview id"; apply=$2; shift 2 ;;
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
    if ! id=$(fp_old_task_id "$tmp") || [ "$id" != "$want" ]; then
      rm -f "$tmp"
      die "task folders changed since preview $want, or could not be read in full; nothing removed - run old-tasks again"
    fi
    total=0
    while IFS='	' read -r kind kb entry; do
      [ -n "$entry" ] || continue
      task=${entry#"$DATA_DIR"/}
      task=${task%%/*}
      folder="$DATA_DIR/$task"
      # Under the task's spawn lock, recheck that the task is still finished
      # and the entry is still the same real directory inside its folder.
      if ! fp_task_lock "$task"; then
        printf 'skipped %s: its task is being spawned\n' "$entry"
        continue
      fi
      if fp_task_live "$task" || ! fp_entry_contained "$entry" "$folder" "$(fm_footprint_physical_dir "$folder")" ||
        ! aside=$(fp_set_aside "$entry" reclaim); then
        fp_task_unlock "$task"
        printf 'skipped %s: it changed or its task is live again\n' "$entry"
        continue
      fi
      fp_task_unlock "$task"
      if fp_remove_tree "$aside"; then
        printf 'removed %s %s %s\n' "$kind" "$(fp_human "$kb")" "$entry"
        total=$((total + kb))
      else
        printf 'could not fully remove %s (left as %s)\n' "$entry" "$aside"
      fi
    done < "$tmp"
    rm -f "$tmp" "$PREVIEW_FILE"
    printf 'Removed %s from old task folders.\n' "$(fp_human "$total")"
    return 0
  fi
  fp_old_task_entries "$days" "$tmp"
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$PREVIEW_FILE"
    printf 'Nothing to offer in task folders older than %s days.\n' "$days"
    return 0
  fi
  id=$(fp_old_task_id "$tmp") || { rm -f "$tmp"; die "could not read the offered entries in full; nothing previewed"; }
  total=$(awk -F '\t' '{ t += $2 } END { printf "%d\n", t }' "$tmp")
  {
    printf 'id\t%s\n' "$id"
    printf 'days\t%s\n' "$days"
    cat "$tmp"
  } > "$PREVIEW_FILE.tmp" && mv -f "$PREVIEW_FILE.tmp" "$PREVIEW_FILE"
  printf 'Offered in task folders older than %s days (records, reports, decisions and unlanded work are never offered):\n' "$days"
  while IFS='	' read -r kind kb entry; do
    printf '  %-16s %10s  %s\n' "$kind" "$(fp_human "$kb")" "$entry"
  done < "$tmp"
  printf 'Total %s. Preview %s.\nRemove exactly this list with: %s old-tasks --apply %s\n' \
    "$(fp_human "$total")" "$id" "$0" "$id"
  rm -f "$tmp"
}

# --- sweep and check ----------------------------------------------------------------

cmd_sweep() {  # [--dry-run]
  local dry=0 base area id age_cut now uid work removed=0 removed_kb=0 kb path root roots aside out
  local kept=0 kept_ids='' busy=0 findings='' scan_each=0
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
      # Set-aside areas a previous pass or close validated but did not finish removing.
      for aside in "$base"/.fm-reclaim-* "$base"/.fm-closing-*; do
        [ -d "$aside" ] && [ ! -L "$aside" ] && [ "$dry" = 0 ] || continue
        fp_remove_tree "$aside" || true
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
    # One scan for unsafe names and one for repositories across every orphan;
    # an orphan holding a repository not proven landed is kept whole.
    if out=$(fm_run_timed 300 find "${orphans[@]}" -xdev -name "$FP_CTRL_GLOB" -print -quit </dev/null 2>/dev/null) && [ -z "$out" ]; then
      scan_each=0
    else
      scan_each=1
    fi
    : > "$work/blocked"
    if [ "$scan_each" = 0 ]; then
      if roots=$(fm_run_timed 300 find "${orphans[@]}" -xdev \( -name .git -o \( -type f -name HEAD \) \) -print </dev/null 2>/dev/null); then
        printf '%s\n' "$roots" | while IFS= read -r root; do
          case "$root" in ''|*/.git/*) continue ;; */.git) root=${root%/.git} ;;
            */HEAD) root=${root%/HEAD}; [ -d "$root/objects" ] && [ -d "$root/refs" ] || continue ;; esac
          fp_checkout_landed "$root" && continue
          area=${root#"$base"/}
          printf '%s\n' "$base/${area%%/*}"
        done | sort -u > "$work/blocked"
      else
        scan_each=1
      fi
    fi
    for area in "${orphans[@]}"; do
      id=${area##*/}
      if [ "$scan_each" = 1 ]; then
        fp_tree_disposable "$area" || printf '%s\n' "$area" >> "$work/blocked"
      fi
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
      asides+=("$aside")
    done
  fi
  if [ "${#asides[@]}" -gt 0 ]; then
    fp_du_many "$work/du" "${asides[@]}"
    fm_run_timed 600 find "${asides[@]}" -xdev -type d ! -perm -u+w -exec chmod u+w {} + </dev/null 2>/dev/null || true
    fm_run_timed 600 find "${asides[@]}" -xdev -depth -delete </dev/null 2>/dev/null || true
    while IFS='	' read -r kb path; do
      [ ! -e "$path" ] && [ ! -L "$path" ] || continue
      id=${path##*/.fm-reclaim-}
      id=${id%.*}
      removed=$((removed + 1))
      removed_kb=$((removed_kb + kb))
      printf '%s\t%s\t-\t-\t%s\t0\tsweep\torphan-removed\t-\n' "$now" "$id" "$kb"
    done < "$work/du" > "$work/ledger"
    if [ -s "$work/ledger" ] && [ -d "$DATA_DIR" ] && [ ! -L "$DATA_DIR" ] && [ ! -L "$LEDGER" ]; then
      (umask 077 && cat "$work/ledger" >> "$LEDGER") || true
    fi
  fi
  rm -rf "$work"
  [ "$dry" = 1 ] || printf 'Removed %s orphaned scratch area(s), %s.\n' "$removed" "$(fp_human "$removed_kb")"
  if [ "$kept" -gt 0 ]; then
    printf 'Kept %s orphaned scratch area(s) whole because they hold work that has not landed: %s.\n' "$kept" "$kept_ids"
    findings="${findings:+$findings; }$kept orphaned scratch area(s) hold work that has not landed ($kept_ids)"
  fi
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
    find "$claude" -name '*.jsonl' -type f -mtime "-$days" -exec grep -Hn -e '"usage":{' \
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
    find "$codex" -name '*.jsonl' -type f -mtime "-$days" -exec grep -Hn -e '"type":"session_meta"' -e '"type":"token_count"' \
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
  local out=$1 procs pid mem cwd rest id key
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
      /tmp/fm-*|/private/tmp/fm-*)
        rest=${cwd#*/tmp/fm-}
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

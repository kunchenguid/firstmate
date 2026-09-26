#!/usr/bin/env bash
# Reclaim unowned lane scratch under /tmp that no live process still uses.
#
# Usage:
#   fm-tmp-sweep.sh [--dry-run] [--older-than-days N] [--state DIR]
#   fm-tmp-sweep.sh --task ID [--dry-run] [--state DIR]
#   fm-tmp-sweep.sh --if-due [--dry-run] [--state DIR] [--older-than-days N]
#   fm-tmp-sweep.sh --help
#
# The recorded per-task temp root (tasktmp=, normally /tmp/fm-<task>/) is
# removed by fm-teardown.sh itself. This script owns every other unowned /tmp
# producer named by that cleanup: lane names under /tmp/hhe*, the exact
# directory /tmp/jest_rs, Claude session directories at
# /tmp/claude-1000/<project>/<session>, and, at teardown, names that belong
# to the task id being cleaned up.
#
# Daily predicate (the default, and what --if-due runs):
#   - a /tmp/hhe* file or directory
#   - the exact path /tmp/jest_rs (one measured lane directory, not a glob)
#   - a child of /tmp/claude-1000/<project>/ (the session)
#   - a /tmp/claude-1000/<project> directory that has no children
#   A candidate is removed only when this user owns it, it is not a symlink,
#   its resolved path stays inside the sweep root, nothing in it is newer
#   than the age gate (default 3 days), and no live process has its working
#   directory on it or under it. /tmp/fm-* is never a daily candidate.
#   When --state names a directory, a live task whose id begins with hhe plus
#   digits keeps every name that belongs to that issue token, so a lane that
#   has not been torn down yet does not lose scratch to the daily pass.
#
# Teardown predicate (--task ID):
#   No age gate. Removes a name that is exactly the task id, or the task id
#   followed by `-`, `.`, `_`, or `+`. A raw star is not used: hhe1802 must
#   not eat hhe18020. The id must be path-safe and at least 8 characters;
#   a shorter id removes nothing. Another live task id in --state that is a
#   prefix of the name at a separator boundary keeps the name.
#
# --if-due runs the daily predicate only when state/.tmp-sweep-stamp is older
# than FM_TMP_SWEEP_INTERVAL seconds (default 86400, a positive whole number).
# The stamp is written at the start of an attempt that is actually due, so a
# scan that cannot finish does not retry on every watcher cycle. --dry-run
# never writes the stamp or state/.tmp-sweep-last.
#
# Prints one line per removed candidate and one line per candidate kept
# because a live process is rooted under it. Fresh names and live-task names
# are silent. Exits 0 when the sweep ran or was not due. Exits 2 when it
# refuses the arguments or cannot establish the live-process scan, and in
# that case it removes nothing.
#
# FM_TMP_SWEEP_TEST=1 with FM_TMP_SWEEP_ROOT set to an absolute directory
# retargets the sweep for tests. Without that flag the root is /tmp even if
# FM_TMP_SWEEP_ROOT is set. FM_TMP_SWEEP_CWD_FILE replaces the lsof scan only
# together with the test flag, and an empty scan still removes nothing.
set -u

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DRY_RUN=0
OLDER_THAN_DAYS=3
TASK_ID=
IF_DUE=0
STATE_DIR=
MODE=daily

sweep_die() { printf 'fm-tmp-sweep: %s\n' "$1" >&2; exit 2; }

sweep_usage() {
  cat <<'TXT'
Usage:
  fm-tmp-sweep.sh [--dry-run] [--older-than-days N] [--state DIR]
  fm-tmp-sweep.sh --task ID [--dry-run] [--state DIR]
  fm-tmp-sweep.sh --if-due [--dry-run] [--state DIR] [--older-than-days N]

Remove unowned /tmp lane scratch. The daily pass applies the age gate
(default 3 days). --task removes that task id's own names with no age gate.
--if-due runs the daily pass when its stamp is old enough. --dry-run removes
nothing. Read this script's header for the full rule.
TXT
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --if-due) IF_DUE=1 ;;
    --task)
      [ "$#" -ge 2 ] || sweep_die "--task requires a task id"
      TASK_ID=$2
      MODE=task
      shift
      ;;
    --state)
      [ "$#" -ge 2 ] || sweep_die "--state requires a directory"
      STATE_DIR=$2
      shift
      ;;
    --older-than-days)
      [ "$#" -ge 2 ] || sweep_die "--older-than-days requires a value"
      case "$2" in
        ''|*[!0-9]*|0) sweep_die "--older-than-days must be a positive whole number of days" ;;
      esac
      OLDER_THAN_DAYS=$2
      shift
      ;;
    --older-than-days=*)
      case "${1#--older-than-days=}" in
        ''|*[!0-9]*|0) sweep_die "--older-than-days must be a positive whole number of days" ;;
      esac
      OLDER_THAN_DAYS=${1#--older-than-days=}
      ;;
    -h|--help) sweep_usage; exit 0 ;;
    *) sweep_die "unknown argument: $1" ;;
  esac
  shift
done

if [ -n "$TASK_ID" ] && [ "$IF_DUE" -eq 1 ]; then
  sweep_die "--task and --if-due are different sweeps"
fi

ROOT=/tmp
if [ "${FM_TMP_SWEEP_TEST:-}" = 1 ]; then
  ROOT=${FM_TMP_SWEEP_ROOT:-}
  case "$ROOT" in
    ''|/*) ;;
    *) sweep_die "FM_TMP_SWEEP_ROOT must be an absolute directory" ;;
  esac
  [ -n "$ROOT" ] && [ "$ROOT" != / ] || sweep_die "FM_TMP_SWEEP_ROOT must be an absolute directory other than /"
  [ -d "$ROOT" ] && [ ! -L "$ROOT" ] || sweep_die "FM_TMP_SWEEP_ROOT is not a real directory"
  ROOT=${ROOT%/}
fi

INTERVAL=${FM_TMP_SWEEP_INTERVAL:-86400}
case "$INTERVAL" in
  ''|*[!0-9]*|0) sweep_die "FM_TMP_SWEEP_INTERVAL must be a positive whole number of seconds" ;;
esac

# A name belongs to a prefix when it is the prefix or the prefix plus a
# separator. A raw star is rejected so hhe1802 does not eat hhe18020.
name_has_prefix() { # <name> <prefix>
  local name=$1 prefix=$2
  [ -n "$prefix" ] || return 1
  case "$name" in
    "$prefix"|"$prefix"-*|"$prefix".*|"$prefix"_*|"$prefix"+*) return 0 ;;
  esac
  return 1
}

task_id_path_safe() { # <id>
  local id=$1
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# hhe1802-some-task -> hhe1802. Ids that do not start with hhe plus digits
# have no issue token.
issue_token() { # <id>
  local id=$1 rest digits
  case "$id" in
    hhe[0-9]*) ;;
    *) return 1 ;;
  esac
  rest=${id#hhe}
  digits=${rest%%[!0-9]*}
  [ -n "$digits" ] || return 1
  printf 'hhe%s\n' "$digits"
}

sweep_realpath() { # <path>
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

# 0 when something inside is newer than the age gate, or when freshness
# cannot be read. Callers then keep the candidate.
content_is_fresh() { # <path> <cutoff-minutes>
  local path=$1 cutoff=$2 found
  found=$(find "$path" -xdev -mmin -"$cutoff" -print -quit 2>/dev/null) || return 0
  [ -n "$found" ]
}

# 0 when some live cwd is the candidate or under it.
live_cwd_under() { # <candidate> <cwd-file>
  local candidate=$1 cwd_file=$2 line
  [ -f "$cwd_file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    while [ "$line" != / ] && [ "${line%/}" != "$line" ]; do
      line=${line%/}
    done
    case "$line" in
      "$candidate"|"$candidate"/*) return 0 ;;
    esac
  done <"$cwd_file"
  return 1
}

COLLECTED_CWD=
sweep_cleanup() {
  [ -n "${COLLECTED_CWD:-}" ] && rm -f "$COLLECTED_CWD"
  [ -n "${LIVE_IDS:-}" ] && rm -f "$LIVE_IDS"
  [ -n "${LIVE_TOKENS:-}" ] && rm -f "$LIVE_TOKENS"
}
trap sweep_cleanup EXIT

collect_live_cwds() { # <output-file>
  local out=$1 raw rc=0
  if [ "${FM_TMP_SWEEP_TEST:-}" = 1 ] && [ -n "${FM_TMP_SWEEP_CWD_FILE:-}" ]; then
    [ -s "$FM_TMP_SWEEP_CWD_FILE" ] || return 1
    cp "$FM_TMP_SWEEP_CWD_FILE" "$out" || return 1
    return 0
  fi
  raw=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tmp-sweep-lsof.XXXXXX") || return 1
  fm_run_timed 20 lsof -n -a -d cwd -Fpn >"$raw" 2>/dev/null || rc=$?
  if [ "$rc" -eq 124 ]; then
    rm -f "$raw"
    return 1
  fi
  LC_ALL=C awk '
    /^n/ {
      path = substr($0, 2)
      if (path != "") print path
    }
  ' "$raw" | LC_ALL=C sort -u >"$out"
  rm -f "$raw"
  [ -s "$out" ]
}

LIVE_IDS=
LIVE_TOKENS=
load_live_ids() {
  local meta base token
  LIVE_IDS=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tmp-sweep-ids.XXXXXX") || sweep_die "cannot stage live task ids"
  LIVE_TOKENS=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tmp-sweep-tokens.XXXXXX") || sweep_die "cannot stage live issue tokens"
  : >"$LIVE_IDS"
  : >"$LIVE_TOKENS"
  [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || return 0
  for meta in "$STATE_DIR"/*.meta; do
    [ -e "$meta" ] || continue
    [ -L "$meta" ] && continue
    base=$(basename "$meta" .meta)
    task_id_path_safe "$base" || continue
    printf '%s\n' "$base" >>"$LIVE_IDS"
    token=$(issue_token "$base" || true)
    [ -n "$token" ] && printf '%s\n' "$token" >>"$LIVE_TOKENS"
  done
}

other_live_id_owns() { # <basename>
  local name=$1 id
  [ -n "$LIVE_IDS" ] && [ -f "$LIVE_IDS" ] || return 1
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    [ "$id" = "$TASK_ID" ] && continue
    name_has_prefix "$name" "$id" && return 0
  done <"$LIVE_IDS"
  return 1
}

live_issue_owns() { # <basename>
  local name=$1 token
  [ -n "$LIVE_TOKENS" ] && [ -f "$LIVE_TOKENS" ] || return 1
  while IFS= read -r token || [ -n "$token" ]; do
    [ -n "$token" ] || continue
    name_has_prefix "$name" "$token" && return 0
  done <"$LIVE_TOKENS"
  return 1
}

ROOT_REAL=
ROOT_REAL=$(sweep_realpath "$ROOT") || sweep_die "cannot resolve the sweep root"
case "$ROOT_REAL" in
  ''|/) sweep_die "refusing to sweep an empty or filesystem root" ;;
esac

REMOVED=0
SKIPPED_LIVE=0
CUTOFF_MIN=$((OLDER_THAN_DAYS * 24 * 60))

# 0 when the candidate is eligible and was removed (or would be). 1 when kept.
# Prints the live-process skip. Fresh and protected names stay silent.
consider() { # <path> <age-gate: 0|1> <protect: none|issue|task>
  local path=$1 age_gate=$2 protect=$3 base real
  [ -e "$path" ] || return 1
  [ -L "$path" ] && return 1
  case "$path" in
    "$ROOT"|"$ROOT"/) return 1 ;;
  esac
  base=$(basename "$path")
  case "$base" in
    ''|.|..) return 1 ;;
  esac
  [ -O "$path" ] || return 1
  real=$(sweep_realpath "$path") || return 1
  case "$real" in
    "$ROOT_REAL"|"$ROOT_REAL"/*) ;;
    *) return 1 ;;
  esac
  case "$protect" in
    issue) live_issue_owns "$base" && return 1 ;;
    task) other_live_id_owns "$base" && return 1 ;;
  esac
  if [ "$age_gate" -eq 1 ] && content_is_fresh "$path" "$CUTOFF_MIN"; then
    return 1
  fi
  if live_cwd_under "$path" "$CWD_FILE"; then
    printf 'skip (live process rooted under it): %s\n' "$path"
    SKIPPED_LIVE=$((SKIPPED_LIVE + 1))
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would remove: %s\n' "$path"
    return 0
  fi
  if rm -rf -- "$path"; then
    printf 'removed: %s\n' "$path"
    REMOVED=$((REMOVED + 1))
    return 0
  fi
  printf 'fm-tmp-sweep: remove failed: %s\n' "$path" >&2
  return 1
}

project_has_hidden() { # <project-dir>
  local hidden
  for hidden in "$1"/.[!.]* "$1"/..?*; do
    [ -e "$hidden" ] || continue
    return 0
  done
  return 1
}

sweep_daily() {
  local candidate project session kept_child eligible_child had_child
  shopt -s nullglob
  for candidate in "$ROOT"/hhe* "$ROOT"/jest_rs; do
    [ -e "$candidate" ] || continue
    case "$(basename "$candidate")" in
      hhe*) ;;
      jest_rs) [ "$candidate" = "$ROOT/jest_rs" ] || continue ;;
      *) continue ;;
    esac
    consider "$candidate" 1 issue || true
  done
  if [ -d "$ROOT/claude-1000" ] && [ ! -L "$ROOT/claude-1000" ]; then
    for project in "$ROOT/claude-1000"/*; do
      [ -e "$project" ] || continue
      if [ ! -d "$project" ] || [ -L "$project" ]; then
        continue
      fi
      had_child=0
      kept_child=0
      eligible_child=0
      # A dotfile is not a session. Its presence keeps the project directory.
      if project_has_hidden "$project"; then
        kept_child=1
      fi
      for session in "$project"/*; do
        had_child=1
        if consider "$session" 1 none; then
          eligible_child=$((eligible_child + 1))
        else
          kept_child=1
        fi
      done
      if [ "$had_child" -eq 0 ]; then
        consider "$project" 1 none || true
      elif [ "$kept_child" -eq 0 ] && [ "$eligible_child" -gt 0 ]; then
        # Every session was eligible. Age already passed on the sessions, so
        # the project directory goes with them instead of waiting out a fresh
        # mtime caused by removing those sessions.
        consider "$project" 0 none || true
      fi
    done
  fi
  shopt -u nullglob
}

sweep_task() {
  local candidate
  task_id_path_safe "$TASK_ID" || sweep_die "task id is not path-safe"
  # Eight characters is the shortest prefix that is not itself an issue id
  # of the hheNNNN shape this fleet uses. Shorter ids stay for the daily pass.
  [ "${#TASK_ID}" -ge 8 ] || {
    printf 'fm-tmp-sweep: skipping prefix sweep for short task id\n' >&2
    return 0
  }
  shopt -s nullglob
  for candidate in \
    "$ROOT/$TASK_ID" \
    "$ROOT/$TASK_ID"-* \
    "$ROOT/$TASK_ID".* \
    "$ROOT/$TASK_ID"_* \
    "$ROOT/$TASK_ID"+*
  do
    [ -e "$candidate" ] || continue
    name_has_prefix "$(basename "$candidate")" "$TASK_ID" || continue
    consider "$candidate" 0 task || true
  done
  shopt -u nullglob
}

due_stamp_path() {
  printf '%s\n' "$STATE_DIR/.tmp-sweep-stamp"
}

if_due_should_run() {
  local stamp now mtime age
  [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || sweep_die "--if-due requires --state to name a real directory"
  stamp=$(due_stamp_path)
  [ -f "$stamp" ] || return 0
  mtime=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null || true)
  case "$mtime" in
    ''|*[!0-9]*) return 0 ;;
  esac
  now=$(date +%s)
  age=$((now - mtime))
  [ "$age" -ge "$INTERVAL" ]
}

write_due_stamp() {
  local stamp
  stamp=$(due_stamp_path)
  umask 077
  date +%s >"$stamp" || sweep_die "cannot write the sweep stamp"
}

write_last_result() {
  local last
  [ -n "$STATE_DIR" ] && [ -d "$STATE_DIR" ] || return 0
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ "$MODE" = daily ] || return 0
  last=$STATE_DIR/.tmp-sweep-last
  umask 077
  printf 'removed=%s skipped_live=%s\n' "$REMOVED" "$SKIPPED_LIVE" >"$last" || true
}

if [ "$IF_DUE" -eq 1 ]; then
  if ! if_due_should_run; then
    exit 0
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    write_due_stamp
  fi
fi

CWD_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-tmp-sweep-cwds.XXXXXX") || sweep_die "cannot stage the live-cwd scan"
COLLECTED_CWD=$CWD_FILE
collect_live_cwds "$CWD_FILE" || sweep_die "cannot scan live process working directories"
load_live_ids

if [ "$MODE" = task ]; then
  sweep_task
else
  sweep_daily
fi
write_last_result
sweep_cleanup
LIVE_IDS=
LIVE_TOKENS=
COLLECTED_CWD=
exit 0

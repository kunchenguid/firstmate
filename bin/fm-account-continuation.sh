#!/usr/bin/env bash
# Build one provider-neutral continuation packet for a managed task.
# Usage: fm-account-continuation.sh <task-id> <new-attempt-id>
#
# The packet is task-owned state under data/<id>/ and supplies historical context
# for a fresh cross-profile continuation; fm-handoff.sh owns live custody at delivery.
# It requires a dead recorded endpoint, an inspectable original worktree/home,
# a non-empty original brief or charter, and a verified repository snapshot.
# It carries available task-owned status, reports, decisions, steering,
# checkpoint, account-lineage, and PR state without reading or
# copying provider homes, credentials, or transcripts.
# The continuation precedence is live external state, verified repository
# state, checkpoint/handoff intent, then recalled provider context.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PACKET_TMP=
PACKET_PRIOR_TMP=
PACKET_PRIOR_ID=
PACKET_PRIOR_GENERATION=
PUBLISHED_PACKET_ID=
PUBLISHED_PACKET_GENERATION=
PACKET_LOCK=
PACKET_LOCK_TOKEN=
STATUS_SNAPSHOT_TMP=
STATUS_IDENTITY_TMP=
STATUS_REVALIDATION_TMP=
LOG_SNAPSHOT_TMP=
META_SNAPSHOT_TMP=
BRIEF_SNAPSHOT_TMP=
TASK_SNAPSHOT_DIR=
MAX_PACKET_BYTES=65536
MAX_SNAPSHOT_BYTES=8192
MAX_REPOSITORY_FINGERPRINT_FILES=${FM_ACCOUNT_CONTINUATION_FINGERPRINT_FILES:-100000}
MAX_REPOSITORY_FINGERPRINT_BYTES=${FM_ACCOUNT_CONTINUATION_FINGERPRINT_BYTES:-268435456}
MAX_REPOSITORY_ENUMERATION_BYTES=${FM_ACCOUNT_CONTINUATION_ENUMERATION_BYTES:-33554432}
MAX_REPOSITORY_FINGERPRINT_SECONDS=${FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS:-30}
path_identity() {
  if [ "$(uname)" = Darwin ]; then
    stat -f '%d:%i' "$1" 2>/dev/null
  else
    stat -c '%d:%i' "$1" 2>/dev/null
  fi
}

file_generation_identity() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

value = os.stat(sys.argv[1], follow_symlinks=False)
if not stat.S_ISREG(value.st_mode):
    raise SystemExit(1)
print(f"{value.st_dev}:{value.st_ino}:{value.st_size}:{value.st_mtime_ns}:{value.st_ctime_ns}")
PY
}

remove_owned_path() {
  local path=$1 identity=$2
  [ -n "$path" ] && [ -n "$identity" ] || return 0
  [ "$(path_identity "$path" 2>/dev/null || true)" = "$identity" ] || return 0
  rm -f -- "$path"
}

process_start_time() {
  LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

packet_lock_state() {
  local pid started token extra current
  [ -f "$PACKET_LOCK" ] && [ ! -L "$PACKET_LOCK" ] || { printf 'unknown'; return; }
  pid=$(sed -n '1p' "$PACKET_LOCK"); started=$(sed -n '2p' "$PACKET_LOCK")
  token=$(sed -n '3p' "$PACKET_LOCK"); extra=$(sed -n '4p' "$PACKET_LOCK")
  case "$pid" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
  [ -n "$started" ] && [ -n "$token" ] && [ -z "$extra" ] || { printf 'unknown'; return; }
  if ! kill -0 "$pid" 2>/dev/null; then printf 'stale'; return; fi
  current=$(process_start_time "$pid") || { printf 'unknown'; return; }
  if [ "$current" = "$started" ]; then printf 'live'; else printf 'stale'; fi
}

packet_reclaim_state() {
  local reclaim=$1 pid started token extra current
  [ -f "$reclaim" ] && [ ! -L "$reclaim" ] || { printf 'unknown'; return; }
  pid=$(sed -n '1p' "$reclaim"); started=$(sed -n '2p' "$reclaim")
  token=$(sed -n '3p' "$reclaim"); extra=$(sed -n '4p' "$reclaim")
  case "$pid" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
  [ -n "$started" ] && [ -n "$token" ] && [ -z "$extra" ] || { printf 'unknown'; return; }
  if ! kill -0 "$pid" 2>/dev/null; then printf 'stale'; return; fi
  current=$(process_start_time "$pid") || { printf 'unknown'; return; }
  if [ "$current" = "$started" ]; then printf 'live'; else printf 'stale'; fi
}

packet_lock_acquire() {
  local candidate reclaim_candidate started state reclaim reclaim_state reclaim_id quarantine attempt
  PACKET_LOCK="$TASK_DIR/.continuation-$ATTEMPT.publish-lock"
  PACKET_LOCK_TOKEN="$$.$RANDOM.$(date +%s)"
  started=$(process_start_time "$$") || return 1
  candidate=$(mktemp "$TASK_DIR/.continuation-$ATTEMPT.lock.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$$" "$started" "$PACKET_LOCK_TOKEN" > "$candidate" || return 1
  reclaim="$PACKET_LOCK.reclaim"
  reclaim_candidate=$(mktemp "$TASK_DIR/.continuation-$ATTEMPT.reclaim.XXXXXX") || return 1
  printf '%s\n%s\n%s\n' "$$" "$started" "$PACKET_LOCK_TOKEN" > "$reclaim_candidate" || return 1
  for attempt in $(seq 1 100); do
    if [ ! -e "$reclaim" ] && ln "$candidate" "$PACKET_LOCK" 2>/dev/null; then
      rm -f "$candidate" "$reclaim_candidate"
      return 0
    fi
    state=$(packet_lock_state)
    if [ "$state" = stale ] && ln "$reclaim_candidate" "$reclaim" 2>/dev/null; then
      state=$(packet_lock_state)
      if [ "$state" = stale ]; then
        quarantine="$PACKET_LOCK.stale.$PACKET_LOCK_TOKEN"
        mv "$PACKET_LOCK" "$quarantine" 2>/dev/null || true
        rm -f "$quarantine"
      fi
      [ "$(sed -n '3p' "$reclaim" 2>/dev/null || true)" != "$PACKET_LOCK_TOKEN" ] || rm -f "$reclaim"
      [ "$state" != stale ] || continue
    fi
    reclaim_state=$(packet_reclaim_state "$reclaim")
    if [ "$reclaim_state" = stale ]; then
      reclaim_id=$(path_identity "$reclaim" 2>/dev/null || true)
      [ -z "$reclaim_id" ] || python3 "$SCRIPT_DIR/fm-contained-read.py" remove-owned-file-fd \
        "${reclaim#./}" "$reclaim_id" ".continuation-$ATTEMPT.reclaim-retired.$PACKET_LOCK_TOKEN" 3< . \
        >/dev/null 2>&1 || true
    fi
    sleep 0.01
  done
  rm -f "$candidate" "$reclaim_candidate"
  echo "error: continuation packet publication is already in progress for $ID" >&2
  return 1
}

packet_lock_release() {
  [ -n "$PACKET_LOCK" ] || return 0
  [ -f "$PACKET_LOCK" ] && [ ! -L "$PACKET_LOCK" ] || return 0
  [ "$(sed -n '3p' "$PACKET_LOCK")" = "$PACKET_LOCK_TOKEN" ] || return 0
  rm -f "$PACKET_LOCK"
}

cleanup_packet_tmp() {
  [ -z "$PACKET_TMP" ] || rm -f "$PACKET_TMP"
  remove_owned_path "$PACKET_PRIOR_TMP" "$PACKET_PRIOR_ID"
  [ -z "$STATUS_SNAPSHOT_TMP" ] || rm -f "$STATUS_SNAPSHOT_TMP"
  [ -z "$STATUS_IDENTITY_TMP" ] || rm -f "$STATUS_IDENTITY_TMP"
  [ -z "$STATUS_REVALIDATION_TMP" ] || rm -f "$STATUS_REVALIDATION_TMP"
  [ -z "$LOG_SNAPSHOT_TMP" ] || rm -f "$LOG_SNAPSHOT_TMP"
  [ -z "$META_SNAPSHOT_TMP" ] || rm -f "$META_SNAPSHOT_TMP"
  [ -z "$BRIEF_SNAPSHOT_TMP" ] || rm -f "$BRIEF_SNAPSHOT_TMP"
  [ -z "$TASK_SNAPSHOT_DIR" ] || rm -rf "$TASK_SNAPSHOT_DIR"
  packet_lock_release
}
trap cleanup_packet_tmp EXIT
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${1:-}
ATTEMPT=${2:-}
[ -n "$ID" ] && [ -n "$ATTEMPT" ] || { echo "usage: fm-account-continuation.sh <task-id> <new-attempt-id>" >&2; exit 2; }
case "$MAX_REPOSITORY_FINGERPRINT_FILES" in
  ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_CONTINUATION_FINGERPRINT_FILES must be a positive integer" >&2; exit 2 ;;
esac
case "$MAX_REPOSITORY_FINGERPRINT_BYTES" in
  ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_CONTINUATION_FINGERPRINT_BYTES must be a positive integer" >&2; exit 2 ;;
esac
case "$MAX_REPOSITORY_ENUMERATION_BYTES" in
  ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_CONTINUATION_ENUMERATION_BYTES must be a positive integer" >&2; exit 2 ;;
esac
case "$MAX_REPOSITORY_FINGERPRINT_SECONDS" in
  ''|*[!0-9]*|0) echo "error: FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS must be a positive integer" >&2; exit 2 ;;
esac
fm_account_valid_id "$ID" || { echo "error: invalid task id '$ID'" >&2; exit 1; }
fm_account_valid_id "$ATTEMPT" || { echo "error: invalid account attempt '$ATTEMPT'" >&2; exit 1; }

CONTAINED_READ="$SCRIPT_DIR/fm-contained-read.cjs"
META_SOURCE="$STATE/$ID.meta"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: unsafe continuation state directory at $STATE" >&2; exit 1; }
[ -f "$META_SOURCE" ] && [ ! -L "$META_SOURCE" ] || { echo "error: no safe managed metadata for continuation at $META_SOURCE" >&2; exit 1; }
META_SNAPSHOT_TMP=$(mktemp "$STATE/.continuation-meta-$ID.XXXXXX") \
  || { echo "error: cannot stage continuation metadata for $ID" >&2; exit 1; }
if ! node "$CONTAINED_READ" "$STATE" "$META_SOURCE" "$MAX_PACKET_BYTES" > "$META_SNAPSHOT_TMP"; then
  echo "error: cannot safely snapshot continuation metadata for $ID" >&2
  exit 1
fi
META="$META_SNAPSHOT_TMP"
PROFILE=$(fm_meta_get "$META" account_profile)
POOL=$(fm_meta_get "$META" account_pool)
HARNESS=$(fm_meta_get "$META" harness)
ACCOUNT_TASK=$(fm_meta_get "$META" account_task)
[ -n "$ACCOUNT_TASK" ] || ACCOUNT_TASK=$ID
[ -n "$PROFILE" ] && [ -n "$POOL" ] || { echo "error: task $ID is not a managed account task" >&2; exit 1; }
case "$HARNESS" in claude|codex) ;; *) echo "error: provider-neutral continuation supports only claude and codex" >&2; exit 1 ;; esac

KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
BACKEND=$(fm_backend_of_meta "$META")
TARGET=$(fm_backend_target_of_meta "$META")
TMUX_SESSION_TARGET=$(fm_meta_get "$META" tmux_session_target)
[ -n "$TMUX_SESSION_TARGET" ] || TMUX_SESSION_TARGET=$(fm_meta_get "$META" window)
SECONDMATE_HOME=$(fm_meta_get "$META" home)
[ -n "$SECONDMATE_HOME" ] || SECONDMATE_HOME=$(fm_meta_get "$META" worktree)
PROBE_HOME=$(fm_backend_endpoint_home "$BACKEND" "$KIND" "$FM_HOME" "$SECONDMATE_HOME")
if [ "$PROBE_HOME" = "$FM_HOME" ]; then
  ENDPOINT_STATE=$(fm_backend_target_state "$BACKEND" "$TARGET" "fm-$ID" "$TMUX_SESSION_TARGET" 2>/dev/null)
else
  ENDPOINT_STATE=$(unset FM_ROOT_OVERRIDE; FM_HOME="$PROBE_HOME" FM_ROOT="$PROBE_HOME" fm_backend_target_state "$BACKEND" "$TARGET" "fm-$ID" "$TMUX_SESSION_TARGET" 2>/dev/null)
fi
case "$ENDPOINT_STATE" in
  absent) ;;
  present) echo "error: managed continuation endpoint is still alive for $ID" >&2; exit 1 ;;
  *) echo "error: managed continuation endpoint state is unknown for $ID" >&2; exit 1 ;;
esac

WORKTREE=$(fm_meta_get "$META" worktree)
PROJECT=$(fm_meta_get "$META" project)
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] || { echo "error: recorded continuation worktree/home is unavailable for $ID" >&2; exit 1; }
WORKTREE_REAL=$(cd "$WORKTREE" && pwd -P)
WORKTREE_ID=$(path_identity "$WORKTREE_REAL") \
  || { echo "error: continuation worktree is not inspectable for $ID" >&2; exit 1; }
if [ -n "${FM_ACCOUNT_CONTINUATION_ROOT_TEST_READY:-}" ] \
  && [ -n "${FM_ACCOUNT_CONTINUATION_ROOT_TEST_PROCEED:-}" ]; then
  : > "$FM_ACCOUNT_CONTINUATION_ROOT_TEST_READY"
  while [ ! -e "$FM_ACCOUNT_CONTINUATION_ROOT_TEST_PROCEED" ]; do sleep 0.01; done
fi
ORIGINAL_CWD=$PWD
cd "$WORKTREE_REAL" \
  || { echo "error: continuation worktree cannot be pinned for $ID" >&2; exit 1; }
[ "$(path_identity . 2>/dev/null || true)" = "$WORKTREE_ID" ] \
  || { echo "error: continuation worktree changed before pinning for $ID" >&2; exit 1; }
exec 9< . \
  || { echo "error: continuation worktree cannot be pinned for $ID" >&2; exit 1; }
cd "$ORIGINAL_CWD" || exit 1
git_pinned() {
  python3 "$SCRIPT_DIR/fm-contained-read.py" git-fd "$@" 3<&9
}
TOP=$(git_pinned rev-parse --show-toplevel 2>/dev/null) || { echo "error: continuation worktree is not inspectable for $ID" >&2; exit 1; }
TOP_REAL=$(cd "$TOP" && pwd -P)
[ "$TOP_REAL" = "$WORKTREE_REAL" ] || { echo "error: continuation path is not the recorded worktree root for $ID" >&2; exit 1; }
HEAD=$(git_pinned rev-parse HEAD 2>/dev/null) || { echo "error: cannot verify continuation HEAD for $ID" >&2; exit 1; }
BRANCH=$(git_pinned branch --show-current 2>/dev/null)
[ -n "$BRANCH" ] || BRANCH=detached
STATUS_IDENTITY_TMP=$(mktemp "$STATE/.continuation-status-identity-$ID.XXXXXX") \
  || { echo "error: cannot stage continuation repository status identity for $ID" >&2; exit 1; }

capture_repository_identity() {
  local output=$1
  python3 "$SCRIPT_DIR/fm-contained-read.py" repository-identity-fd \
    "$MAX_REPOSITORY_FINGERPRINT_FILES" "$MAX_REPOSITORY_FINGERPRINT_BYTES" \
    "$MAX_REPOSITORY_ENUMERATION_BYTES" "$MAX_REPOSITORY_FINGERPRINT_SECONDS" \
    3<&9 > "$output"
}

capture_repository_identity "$STATUS_IDENTITY_TMP" \
  || {
    echo "error: cannot verify continuation repository status for $ID; reduce repository scope or adjust FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS, FM_ACCOUNT_CONTINUATION_FINGERPRINT_FILES, FM_ACCOUNT_CONTINUATION_FINGERPRINT_BYTES, or FM_ACCOUNT_CONTINUATION_ENUMERATION_BYTES" >&2
    exit 1
  }

TASK_DIR=$(fm_account_task_dir "$DATA" "$ID" create) \
  || { echo "error: continuation task directory is unsafe for $ID" >&2; exit 1; }
TASK_DIR_PATH=$TASK_DIR
TASK_DIR_ID=$(path_identity "$TASK_DIR_PATH") \
  || { echo "error: continuation task directory is unsafe for $ID" >&2; exit 1; }
cd "$TASK_DIR_PATH" || { echo "error: continuation task directory is unavailable for $ID" >&2; exit 1; }
[ "$(path_identity .)" = "$TASK_DIR_ID" ] \
  || { echo "error: continuation task directory changed for $ID" >&2; exit 1; }
TASK_DIR=.

TASK_SNAPSHOT_DIR=$(mktemp -d "$STATE/.continuation-task-$ID.XXXXXX") \
  || { echo "error: cannot stage continuation task snapshot for $ID" >&2; exit 1; }
TASK_SNAPSHOT_SOURCES=(
  brief.md report.md completion.md decisions.md steering.md steering-pending.md steering-journal.md
  steering-unconfirmed.md side-effects.md do-not-rerun.md next-action.md checkpoint.md
  handoff.md recalled.md transcript-summary.md account-attempts.md
)
if ! node "$CONTAINED_READ" snapshot "$TASK_DIR" "$TASK_SNAPSHOT_DIR" 1048576 "${TASK_SNAPSHOT_SOURCES[@]}"; then
  echo "error: cannot safely snapshot continuation task artifacts for $ID" >&2
  exit 1
fi

if [ "$KIND" = secondmate ]; then
  BRIEF_SNAPSHOT_TMP=$(mktemp "$STATE/.continuation-brief-$ID.XXXXXX") \
    || { echo "error: cannot stage original brief or charter for continuation of $ID" >&2; exit 1; }
  if python3 "$SCRIPT_DIR/fm-contained-read.py" cat-optional-fd data/charter.md "$MAX_PACKET_BYTES" 3<&9 \
    > "$BRIEF_SNAPSHOT_TMP" 2>/dev/null; then
    [ -s "$BRIEF_SNAPSHOT_TMP" ] \
      || { echo "error: secondmate charter is empty for continuation of $ID" >&2; exit 1; }
  else
    charter_status=$?
    if [ "$charter_status" -eq 3 ]; then
      rm -f "$BRIEF_SNAPSHOT_TMP"
      BRIEF_SNAPSHOT_TMP="$TASK_SNAPSHOT_DIR/0.snapshot"
    else
      echo "error: secondmate charter is present but unsafe for continuation of $ID" >&2
      exit 1
    fi
  fi
else
  BRIEF_SNAPSHOT_TMP="$TASK_SNAPSHOT_DIR/0.snapshot"
fi
[ -s "$BRIEF_SNAPSHOT_TMP" ] \
  || { echo "error: no safe non-empty original brief or charter for continuation of $ID" >&2; exit 1; }

PACKET="$TASK_DIR/continuation-$ATTEMPT.md"
PACKET_TMP=$(mktemp "$TASK_DIR/.continuation-$ATTEMPT.XXXXXX") \
  || { echo "error: cannot safely stage continuation packet for $ID" >&2; exit 1; }

packet_bytes() {
  local bytes
  bytes=$(wc -c < "$PACKET_TMP" | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$bytes"
}

packet_size_error() {
  echo "error: continuation packet for $ID is $1 bytes; maximum is $MAX_PACKET_BYTES" >&2
  return 1
}

packet_check_budget() {
  local bytes
  bytes=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  [ "$bytes" -le "$MAX_PACKET_BYTES" ] || packet_size_error "$bytes"
}

snapshot_bytes() {
  local file=$1 bytes
  bytes=$(wc -c < "$file" | tr -d '[:space:]')
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$bytes"
}

capture_command_snapshot() {
  local file=$1 failure_mode=$2 command_rc head_rc bytes
  local pipeline_status
  shift 2
  set +e
  "$@" 2>&1 | head -c "$((MAX_SNAPSHOT_BYTES + 1))" > "$file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  command_rc=${pipeline_status[0]:-1}
  head_rc=${pipeline_status[1]:-1}
  [ "$head_rc" -eq 0 ] || return "$head_rc"
  bytes=$(snapshot_bytes "$file") || return 1
  if [ "$command_rc" -eq 0 ] \
    || { [ "$bytes" -gt "$MAX_SNAPSHOT_BYTES" ] \
      && { [ "$command_rc" -eq 141 ] || [ "$failure_mode" = unavailable ]; }; }; then
    return 0
  fi
  [ "$failure_mode" = unavailable ] || return "$command_rc"
  printf 'unavailable\n' > "$file"
}

capture_file_snapshot() {
  local file=$1 source=$2
  head -c "$((MAX_SNAPSHOT_BYTES + 1))" "$source" > "$file"
}

append_snapshot_section() {
  local heading=$1 file=$2 current source_bytes data_bytes framing_bytes projected truncated
  current=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  source_bytes=$(snapshot_bytes "$file") || { echo "error: cannot measure continuation snapshot $file" >&2; return 1; }
  data_bytes=$source_bytes
  truncated=0
  if [ "$data_bytes" -gt "$MAX_SNAPSHOT_BYTES" ]; then
    data_bytes=$MAX_SNAPSHOT_BYTES
    truncated=1
  fi
  framing_bytes=$({
    printf '\n## %s\n\n```text\n' "$heading"
    if [ "$truncated" -eq 1 ]; then
      printf '\n[Snapshot truncated at %s bytes.]\n```\n' "$MAX_SNAPSHOT_BYTES"
    else
      printf '\n```\n'
    fi
  } | wc -c | tr -d '[:space:]')
  case "$framing_bytes" in ''|*[!0-9]*) echo "error: cannot measure continuation snapshot framing" >&2; return 1 ;; esac
  projected=$((current + data_bytes + framing_bytes))
  [ "$projected" -le "$MAX_PACKET_BYTES" ] || packet_size_error "$projected"
  {
    printf '\n## %s\n\n```text\n' "$heading"
    [ "$data_bytes" -eq 0 ] || head -c "$data_bytes" "$file"
    if [ "$truncated" -eq 1 ]; then
      printf '\n[Snapshot truncated at %s bytes.]\n```\n' "$MAX_SNAPSHOT_BYTES"
    else
      printf '\n```\n'
    fi
  } >> "$PACKET_TMP"
  packet_check_budget
}

append_staged_file_section() {  # <heading> <snapshot>
  local heading=$1 source_tmp=$2 current file_bytes framing_bytes projected copy_start copy_end copied copy_rc
  file_bytes=$(snapshot_bytes "$source_tmp") || return 1
  current=$(packet_bytes) || {
    echo "error: cannot measure continuation packet for $ID" >&2
    return 1
  }
  framing_bytes=$(printf '\n## %s\n\n\n' "$heading" | wc -c | tr -d '[:space:]')
  case "$file_bytes$framing_bytes" in
    *[!0-9]*)
      echo "error: cannot measure staged continuation source" >&2
      return 1
      ;;
  esac
  projected=$((current + file_bytes + framing_bytes))
  if [ "$projected" -gt "$MAX_PACKET_BYTES" ]; then
    packet_size_error "$projected"
    return 1
  fi
  printf '\n## %s\n\n' "$heading" >> "$PACKET_TMP" || return 1
  copy_start=$(packet_bytes) || {
    echo "error: cannot measure continuation packet for $ID" >&2
    return 1
  }
  set +e
  head -c "$file_bytes" "$source_tmp" >> "$PACKET_TMP"
  copy_rc=$?
  set -e
  [ "$copy_rc" -eq 0 ] || { echo "error: cannot copy staged continuation source" >&2; return 1; }
  copy_end=$(packet_bytes) || { echo "error: cannot measure continuation packet for $ID" >&2; return 1; }
  copied=$((copy_end - copy_start))
  [ "$copied" -eq "$file_bytes" ] || packet_size_error "$((current + framing_bytes + copied))"
  printf '\n' >> "$PACKET_TMP" || return 1
  packet_check_budget
}

append_file_section() {  # <heading> <root> <file>
  local heading=$1 root=$2 file=$3 source_tmp rc
  [ -f "$file" ] || return 0
  [ ! -L "$file" ] || { echo "error: refusing symlinked continuation source $file" >&2; return 1; }
  source_tmp=$(mktemp "$TASK_DIR/.continuation-source.XXXXXX") \
    || { echo "error: cannot stage continuation source $file" >&2; return 1; }
  if ! node "$CONTAINED_READ" "$root" "$file" 1048576 > "$source_tmp"; then
    rm -f "$source_tmp"
    echo "error: cannot safely read continuation source $file" >&2
    return 1
  fi
  append_staged_file_section "$heading" "$source_tmp"
  rc=$?
  rm -f "$source_tmp"
  return "$rc"
}

append_task_snapshot() {  # <heading> <snapshot-index>
  local heading=$1 source_tmp="$TASK_SNAPSHOT_DIR/$2.snapshot"
  [ -f "$source_tmp" ] || return 0
  append_staged_file_section "$heading" "$source_tmp"
}

repository_snapshot_matches() {
  local current_worktree_real current_worktree_id current_top current_top_real current_head current_branch
  local verified_worktree_real verified_worktree_id verified_top verified_top_real verified_head verified_branch
  current_worktree_real=$(cd "$WORKTREE" && pwd -P 2>/dev/null || true)
  current_worktree_id=$(path_identity "$WORKTREE_REAL" 2>/dev/null || true)
  current_top=$(git_pinned rev-parse --show-toplevel 2>/dev/null || true)
  current_top_real=$([ -n "$current_top" ] && cd "$current_top" && pwd -P || true)
  current_head=$(git_pinned rev-parse HEAD 2>/dev/null || true)
  current_branch=$(git_pinned branch --show-current 2>/dev/null || true)
  [ -n "$current_branch" ] || current_branch=detached
  [ "$current_worktree_real" = "$WORKTREE_REAL" ] \
    && [ "$current_worktree_id" = "$WORKTREE_ID" ] \
    && [ "$current_top_real" = "$WORKTREE_REAL" ] \
    && [ "$current_head" = "$HEAD" ] \
    && [ "$current_branch" = "$BRANCH" ] \
    || return 1
  capture_repository_identity "$STATUS_REVALIDATION_TMP" \
    || return 1
  verified_worktree_real=$(cd "$WORKTREE" && pwd -P 2>/dev/null || true)
  verified_worktree_id=$(path_identity "$WORKTREE_REAL" 2>/dev/null || true)
  verified_top=$(git_pinned rev-parse --show-toplevel 2>/dev/null || true)
  verified_top_real=$([ -n "$verified_top" ] && cd "$verified_top" && pwd -P || true)
  verified_head=$(git_pinned rev-parse HEAD 2>/dev/null || true)
  verified_branch=$(git_pinned branch --show-current 2>/dev/null || true)
  [ -n "$verified_branch" ] || verified_branch=detached
  [ "$verified_worktree_real" = "$WORKTREE_REAL" ] \
    && [ "$verified_worktree_id" = "$WORKTREE_ID" ] \
    && [ "$verified_top_real" = "$WORKTREE_REAL" ] \
    && [ "$verified_head" = "$HEAD" ] \
    && [ "$verified_branch" = "$BRANCH" ] \
    && cmp -s "$STATUS_IDENTITY_TMP" "$STATUS_REVALIDATION_TMP"
}

{
  printf '# Provider-neutral continuation for %s\n\n' "$ID"
  printf 'This is a fresh provider session for the same Firstmate task, not a replay from the beginning.\n'
  printf 'Re-verify live external state before acting, then trust current repository state, then explicit checkpoint and handoff intent, and use recalled provider context only as a final aid.\n'
  printf 'Do not repeat completed side effects unless current external and repository evidence proves they did not land.\n'
  printf 'Continue in the recorded worktree and preserve its branch, commits, uncommitted changes, task identity, and delivery state.\n\n'
  printf '## Verified continuation anchor\n\n'
  printf -- "- Task: \`%s\`\n" "$ID"
  printf -- "- New attempt: \`%s\`\n" "$ATTEMPT"
  printf -- "- Previous Agent Fleet task: \`%s\`\n" "$ACCOUNT_TASK"
  printf -- "- Previous provider/profile/pool: \`%s\` / \`%s\` / \`%s\`\n" "$HARNESS" "$PROFILE" "$POOL"
  printf -- "- Recorded endpoint: dead (\`%s\`, \`%s\`)\n" "$BACKEND" "${TARGET:-none}"
  printf -- "- Worktree: \`%s\`\n" "$WORKTREE_REAL"
  printf -- "- Project: \`%s\`\n" "$PROJECT"
  printf -- "- Branch: \`%s\`\n" "$BRANCH"
  printf -- "- HEAD: \`%s\`\n" "$HEAD"
} >> "$PACKET_TMP"
packet_check_budget

STATUS_SNAPSHOT_TMP=$(mktemp "$TASK_DIR/.continuation-status.XXXXXX") || STATUS_SNAPSHOT_TMP=
LOG_SNAPSHOT_TMP=$(mktemp "$TASK_DIR/.continuation-log.XXXXXX") || LOG_SNAPSHOT_TMP=
if [ -z "$STATUS_SNAPSHOT_TMP" ] || [ -z "$LOG_SNAPSHOT_TMP" ]; then
  echo "error: cannot safely stage continuation snapshots for $ID" >&2
  exit 1
fi

capture_command_snapshot "$STATUS_SNAPSHOT_TMP" fatal git_pinned status --short --branch \
  || { echo "error: cannot snapshot continuation repository status for $ID" >&2; exit 1; }
append_snapshot_section "Verified repository status" "$STATUS_SNAPSHOT_TMP"

capture_command_snapshot "$LOG_SNAPSHOT_TMP" fatal git_pinned log --oneline --decorate -20 \
  || { echo "error: cannot snapshot continuation repository history for $ID" >&2; exit 1; }
append_snapshot_section "Recent repository history" "$LOG_SNAPSHOT_TMP"

append_snapshot_section "Recorded task metadata" "$META_SNAPSHOT_TMP"

append_staged_file_section "Original brief or charter" "$BRIEF_SNAPSHOT_TMP"
append_file_section "Wake-event and progress status" "$STATE" "$STATE/$ID.status"
append_task_snapshot "Task report" 1
append_task_snapshot "Completion report" 2
append_task_snapshot "Decisions" 3
append_task_snapshot "Steering trail" 4
append_task_snapshot "Pending steering audit" 5
append_task_snapshot "Steering journal" 6
append_task_snapshot "Unconfirmed steering" 7
append_task_snapshot "Completed side effects" 8
append_task_snapshot "Do not rerun" 9
append_task_snapshot "Next action" 10
append_task_snapshot "Checkpoint" 11
append_task_snapshot "Handoff" 12
append_task_snapshot "Recalled context" 13
append_task_snapshot "Provider transcript summary" 14
append_task_snapshot "Account attempt lineage" 15

packet_check_budget
STATUS_REVALIDATION_TMP=$(mktemp "$STATE/.continuation-status-revalidation-$ID.XXXXXX") \
  || { echo "error: cannot restage continuation repository status identity for $ID" >&2; exit 1; }
if [ -n "${FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY:-}" ] \
  && [ -n "${FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED:-}" ]; then
  : > "$FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_READY"
  while [ ! -e "$FM_ACCOUNT_CONTINUATION_REPOSITORY_TEST_PROCEED" ]; do sleep 0.01; done
fi
if ! repository_snapshot_matches; then
  echo "error: continuation repository snapshot changed for $ID" >&2
  exit 1
fi

rollback_published_packet() {
  local current_generation prior_generation preserved_id preserved_path quarantine
  current_generation=$(file_generation_identity "$PACKET" 2>/dev/null || true)
  if [ "$current_generation" != "$PUBLISHED_PACKET_GENERATION" ]; then
    echo "error: continuation packet generation changed before rollback for $ID" >&2
    if [ -n "$PACKET_PRIOR_TMP" ]; then
      prior_generation=$(file_generation_identity "$PACKET_PRIOR_TMP" 2>/dev/null || true)
      if [ "$prior_generation" = "$PACKET_PRIOR_GENERATION" ]; then
        preserved_id=${PACKET_PRIOR_ID//:/-}
        preserved_path="$TASK_DIR/continuation-$ATTEMPT.displaced-$preserved_id.md"
        if [ ! -e "$preserved_path" ] && ln -- "$PACKET_PRIOR_TMP" "$preserved_path" 2>/dev/null; then
          remove_owned_path "$PACKET_PRIOR_TMP" "$PACKET_PRIOR_ID"
          echo "error: displaced continuation packet preserved at $TASK_DIR_PATH/${preserved_path#./}" >&2
        else
          echo "error: displaced continuation packet preserved at $TASK_DIR_PATH/${PACKET_PRIOR_TMP#./}" >&2
        fi
      fi
      PACKET_PRIOR_TMP=
      PACKET_PRIOR_ID=
      PACKET_PRIOR_GENERATION=
    fi
    return 1
  fi
  if [ -n "$PACKET_PRIOR_TMP" ]; then
    prior_generation=$(file_generation_identity "$PACKET_PRIOR_TMP" 2>/dev/null || true)
    [ "$prior_generation" = "$PACKET_PRIOR_GENERATION" ] \
      || { echo "error: displaced continuation packet generation changed for $ID" >&2; return 1; }
    python3 "$SCRIPT_DIR/fm-contained-read.py" exchange-files-fd \
      "${PACKET_PRIOR_TMP#./}" "${PACKET#./}" "$PACKET_PRIOR_ID" "$PUBLISHED_PACKET_ID" 3< . \
      || return 1
    remove_owned_path "$PACKET_PRIOR_TMP" "$PUBLISHED_PACKET_ID"
    PACKET_PRIOR_TMP=
    PACKET_PRIOR_ID=
    PACKET_PRIOR_GENERATION=
  else
    quarantine=".continuation-$ATTEMPT.rollback.$PACKET_LOCK_TOKEN"
    python3 "$SCRIPT_DIR/fm-contained-read.py" remove-owned-file-fd \
      "${PACKET#./}" "$PUBLISHED_PACKET_ID" "$quarantine" 3< . \
      || return 1
  fi
  PUBLISHED_PACKET_ID=
  PUBLISHED_PACKET_GENERATION=
}

publish_packet() {
  local destination_id
  packet_lock_acquire || return 1
  PUBLISHED_PACKET_ID=$(path_identity "$PACKET_TMP" 2>/dev/null || true)
  [ -n "$PUBLISHED_PACKET_ID" ] || return 1
  if [ -e "$PACKET" ]; then
    destination_id=$(path_identity "$PACKET" 2>/dev/null || true)
    [ -n "$destination_id" ] || return 1
    if [ -n "${FM_ACCOUNT_CONTINUATION_PREPUBLISH_TEST_READY:-}" ] \
      && [ -n "${FM_ACCOUNT_CONTINUATION_PREPUBLISH_TEST_PROCEED:-}" ]; then
      : > "$FM_ACCOUNT_CONTINUATION_PREPUBLISH_TEST_READY"
      while [ ! -e "$FM_ACCOUNT_CONTINUATION_PREPUBLISH_TEST_PROCEED" ]; do sleep 0.01; done
    fi
    python3 "$SCRIPT_DIR/fm-contained-read.py" exchange-files-fd \
      "${PACKET_TMP#./}" "${PACKET#./}" "$PUBLISHED_PACKET_ID" "$destination_id" 3< . \
      || return 1
    PACKET_PRIOR_TMP=$PACKET_TMP
    PACKET_PRIOR_ID=$destination_id
    PACKET_PRIOR_GENERATION=$(file_generation_identity "$PACKET_PRIOR_TMP" 2>/dev/null || true)
    PUBLISHED_PACKET_GENERATION=$(file_generation_identity "$PACKET" 2>/dev/null || true)
    [ -n "$PACKET_PRIOR_GENERATION" ] && [ -n "$PUBLISHED_PACKET_GENERATION" ] || return 1
    PACKET_TMP=
    return 0
  fi
  if ! ln -- "$PACKET_TMP" "$PACKET"; then
    if [ -n "$PACKET_PRIOR_TMP" ] && [ ! -e "$PACKET" ] \
      && [ "$(path_identity "$PACKET_PRIOR_TMP" 2>/dev/null || true)" = "$PACKET_PRIOR_ID" ]; then
      ln -- "$PACKET_PRIOR_TMP" "$PACKET" 2>/dev/null || true
      PACKET_PRIOR_TMP=
      PACKET_PRIOR_ID=
    fi
    return 1
  fi
  rm -f -- "$PACKET_TMP" || return 1
  PACKET_TMP=
  PUBLISHED_PACKET_GENERATION=$(file_generation_identity "$PACKET" 2>/dev/null || true)
  [ "$(path_identity "$PACKET" 2>/dev/null || true)" = "$PUBLISHED_PACKET_ID" ] \
    && [ -n "$PUBLISHED_PACKET_GENERATION" ]
}

fail_after_publish() {
  local message=$1
  rollback_published_packet || true
  echo "$message" >&2
  exit 1
}

if [ -n "${FM_ACCOUNT_CONTINUATION_DESTINATION_TEST_READY:-}" ] \
  && [ -n "${FM_ACCOUNT_CONTINUATION_DESTINATION_TEST_PROCEED:-}" ]; then
  : > "$FM_ACCOUNT_CONTINUATION_DESTINATION_TEST_READY"
  while [ ! -e "$FM_ACCOUNT_CONTINUATION_DESTINATION_TEST_PROCEED" ]; do sleep 0.01; done
fi
[ -d "$TASK_DIR_PATH" ] && [ ! -L "$TASK_DIR_PATH" ] \
  && [ "$(path_identity "$TASK_DIR_PATH" 2>/dev/null || true)" = "$TASK_DIR_ID" ] \
  && [ "$(path_identity . 2>/dev/null || true)" = "$TASK_DIR_ID" ] \
  || { echo "error: continuation task directory changed for $ID" >&2; exit 1; }
if [ -L "$PACKET" ] || { [ -e "$PACKET" ] && [ ! -f "$PACKET" ]; }; then
  echo "error: unsafe continuation packet destination for $ID" >&2
  exit 1
fi
if ! repository_snapshot_matches; then
  echo "error: continuation repository snapshot changed for $ID" >&2
  exit 1
fi
publish_packet || { echo "error: cannot safely publish continuation packet for $ID" >&2; exit 1; }
if [ -n "${FM_ACCOUNT_CONTINUATION_INSTALL_TEST_READY:-}" ] \
  && [ -n "${FM_ACCOUNT_CONTINUATION_INSTALL_TEST_PROCEED:-}" ]; then
  : > "$FM_ACCOUNT_CONTINUATION_INSTALL_TEST_READY"
  while [ ! -e "$FM_ACCOUNT_CONTINUATION_INSTALL_TEST_PROCEED" ]; do sleep 0.01; done
fi
if ! repository_snapshot_matches; then
  fail_after_publish "error: continuation repository snapshot changed for $ID"
fi
[ -d "$TASK_DIR_PATH" ] && [ ! -L "$TASK_DIR_PATH" ] \
  && [ "$(path_identity "$TASK_DIR_PATH" 2>/dev/null || true)" = "$TASK_DIR_ID" ] \
  && [ "$(path_identity . 2>/dev/null || true)" = "$TASK_DIR_ID" ] \
  || fail_after_publish "error: continuation task directory changed for $ID"
[ "$(file_generation_identity "$PACKET" 2>/dev/null || true)" = "$PUBLISHED_PACKET_GENERATION" ] \
  || fail_after_publish "error: continuation packet generation changed before finalization for $ID"
remove_owned_path "$PACKET_PRIOR_TMP" "$PACKET_PRIOR_ID"
PACKET_PRIOR_TMP=
PACKET_PRIOR_ID=
PACKET_PRIOR_GENERATION=
PACKET_GENERATION="continuation-$ATTEMPT.generation-$PACKET_LOCK_TOKEN.md"
if [ "${FM_ACCOUNT_CONTINUATION_EMIT_PROMPT_B64:-}" = 1 ]; then
  printf '%s\n' "$TASK_DIR_PATH/$PACKET_GENERATION"
  python3 "$SCRIPT_DIR/fm-contained-read.py" copy-file-fd \
    "${PACKET#./}" "$PACKET_GENERATION" "$PUBLISHED_PACKET_ID" emit-base64 3< . \
    || { echo "error: cannot pin continuation packet generation for $ID" >&2; exit 1; }
  printf '\n'
else
  python3 "$SCRIPT_DIR/fm-contained-read.py" copy-file-fd \
    "${PACKET#./}" "$PACKET_GENERATION" "$PUBLISHED_PACKET_ID" 3< . \
    || { echo "error: cannot pin continuation packet generation for $ID" >&2; exit 1; }
  printf '%s\n' "$TASK_DIR_PATH/$PACKET_GENERATION"
fi

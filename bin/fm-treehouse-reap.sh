#!/usr/bin/env bash
# Inspect Treehouse capacity and conservatively reap dead Firstmate tasks.
#
# Usage:
#   fm-treehouse-reap.sh capacity [--low-only]
#   fm-treehouse-reap.sh reap --auto
#   fm-treehouse-reap.sh reap <task-id>...
#
# `capacity` scans the active home's managed pool plus the legacy user-level
# pool, counts only clean unleased worktrees as available, and prints the
# threshold that classified each pool.
# The default low-water mark is 50 percent of recorded slots, rounded up.
# Override it with FM_TREEHOUSE_CAPACITY_THRESHOLD_PERCENT=1..100.
#
# `reap --auto` considers only tasks whose last durable status is done/failed or
# whose spawn never created an endpoint.
# An explicit task id permits incident recovery of a stale non-terminal status,
# but never relaxes the safety checks below.
# Every reap requires one real metadata file, one exact worktree-path lease owned
# by `firstmate-<task-id>`, no recorded or branch-discovered open PR, and
# fm-teardown.sh --reap-dead.
# That teardown mode proves the endpoint absent without killing it, applies the
# ordinary landed-work proof, refuses any uncommitted work, repeats the proofs
# under the checkout lock, and uses non-forcing `treehouse return`.
# A missing proof is a retained lease, never an invitation to force cleanup.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MANAGED_TREEHOUSE_ROOT="$FM_HOME/.treehouse"
TREEHOUSE_ROOT="${FM_TREEHOUSE_ROOT:-$HOME/.treehouse}"
TEARDOWN="${FM_TREEHOUSE_REAP_TEARDOWN:-$SCRIPT_DIR/fm-teardown.sh}"
TEARDOWN_REAP_SAFETY_REFUSAL=75

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-process-tree-lib.sh
. "$SCRIPT_DIR/fm-process-tree-lib.sh"

usage() {
  echo "usage: fm-treehouse-reap.sh capacity [--low-only] | reap (--auto | <task-id>...)" >&2
}

capacity() {
  local low_only=0
  case "${1:-}" in
    '') ;;
    --low-only) low_only=1 ;;
    *) usage; return 2 ;;
  esac
  [ "$#" -le 1 ] || { usage; return 2; }
  command -v python3 >/dev/null 2>&1 || {
    echo "TREEHOUSE_CAPACITY: unavailable reason=python3-missing"
    return 0
  }
  FM_TREEHOUSE_CAPACITY_LOW_ONLY=$low_only python3 - "$MANAGED_TREEHOUSE_ROOT" "$TREEHOUSE_ROOT" <<'PY'
import json
import math
import os
import stat
import subprocess
import sys

MAX_POOLS = 128
MAX_ENTRIES = 256
MAX_STATE_BYTES = 1024 * 1024
PER_WORKTREE_SECONDS = 2


def integer_env(name, default, minimum, maximum):
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if minimum <= value <= maximum else default


threshold_percent = integer_env(
    "FM_TREEHOUSE_CAPACITY_THRESHOLD_PERCENT", 50, 1, 100
)
low_only = os.environ.get("FM_TREEHOUSE_CAPACITY_LOW_ONLY") == "1"
roots = []
for candidate in sys.argv[1:]:
    if not os.path.isdir(candidate) or os.path.islink(candidate):
        continue
    canonical = os.path.realpath(candidate)
    if canonical not in roots:
        roots.append(canonical)

pools = []
for root in roots:
    try:
        entries = sorted(os.scandir(root), key=lambda entry: entry.name)
    except OSError as error:
        print(f"TREEHOUSE_CAPACITY: unavailable root={root} reason={error}")
        continue
    for entry in entries:
        try:
            metadata = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            state_path = os.path.join(entry.path, "treehouse-state.json")
            if os.path.isfile(state_path) and not os.path.islink(state_path):
                pools.append((entry.path, state_path))

if len(pools) > MAX_POOLS:
    print(
        f"TREEHOUSE_CAPACITY: unavailable reason=pool-limit "
        f"observed={len(pools)} limit={MAX_POOLS}"
    )
    pools = pools[:MAX_POOLS]

for pool, state_path in pools:
    try:
        state_metadata = os.lstat(state_path)
        if not stat.S_ISREG(state_metadata.st_mode) or state_metadata.st_size > MAX_STATE_BYTES:
            raise OSError("state is not a bounded regular file")
        with open(state_path, encoding="utf-8") as stream:
            state = json.load(stream)
        worktrees = state.get("worktrees")
        if not isinstance(worktrees, list) or len(worktrees) > MAX_ENTRIES:
            raise ValueError("worktrees is not a bounded array")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"TREEHOUSE_CAPACITY: unavailable pool={pool} reason={error}")
        continue

    available = 0
    leased = 0
    dirty = 0
    invalid = 0
    for entry in worktrees:
        if not isinstance(entry, dict):
            invalid += 1
            continue
        path = entry.get("path")
        if not isinstance(path, str) or not os.path.isabs(path):
            invalid += 1
            continue
        if entry.get("leased") is True:
            leased += 1
            continue
        try:
            result = subprocess.run(
                [
                    "git",
                    "-C",
                    path,
                    "status",
                    "--porcelain=v1",
                    "--untracked-files=all",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=PER_WORKTREE_SECONDS,
                check=False,
                text=True,
            )
        except (OSError, subprocess.TimeoutExpired):
            invalid += 1
            continue
        if result.returncode == 0 and not result.stdout:
            available += 1
        else:
            dirty += 1

    total = len(worktrees)
    if total == 0:
        continue
    threshold = max(1, math.ceil(total * threshold_percent / 100))
    low = available < threshold
    if low_only and not low:
        continue
    level = "LOW" if low else "OK"
    print(
        f"TREEHOUSE_CAPACITY: {level} pool={pool} available={available} "
        f"total={total} leased={leased} dirty={dirty} invalid={invalid} "
        f"threshold={threshold} threshold_percent={threshold_percent}"
    )
PY
}

task_id_valid() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

meta_value() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

task_is_terminal() {
  local id=$1 meta=$2 line verb
  if [ "$(meta_value "$meta" direct_spawn_endpoint)" = not-created ]; then
    return 0
  fi
  [ -f "$STATE/$id.status" ] && [ ! -L "$STATE/$id.status" ] || return 1
  line=$(grep -v '^[[:space:]]*$' "$STATE/$id.status" 2>/dev/null | tail -1)
  verb=${line%%:*}
  case "$verb" in done|failed) return 0 ;; esac
  return 1
}

lease_record_for_worktree() {
  local worktree=$1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$worktree" "$MANAGED_TREEHOUSE_ROOT" "$TREEHOUSE_ROOT" <<'PY'
import json
import os
import stat
import sys

expected = os.path.realpath(sys.argv[1])
matches = []
seen_roots = set()
for raw_root in sys.argv[2:]:
    if not os.path.isdir(raw_root) or os.path.islink(raw_root):
        continue
    root = os.path.realpath(raw_root)
    if root in seen_roots:
        continue
    seen_roots.add(root)
    try:
        pools = sorted(os.scandir(root), key=lambda entry: entry.name)
    except OSError:
        continue
    for pool in pools:
        try:
            pool_metadata = pool.stat(follow_symlinks=False)
        except OSError:
            continue
        if not stat.S_ISDIR(pool_metadata.st_mode) or stat.S_ISLNK(pool_metadata.st_mode):
            continue
        state_path = os.path.join(pool.path, "treehouse-state.json")
        try:
            state_metadata = os.lstat(state_path)
            if not stat.S_ISREG(state_metadata.st_mode) or state_metadata.st_size > 1024 * 1024:
                continue
            with open(state_path, encoding="utf-8") as stream:
                state = json.load(stream)
            entries = state.get("worktrees")
            if not isinstance(entries, list) or len(entries) > 256:
                continue
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                path = entry.get("path")
                if not isinstance(path, str) or not os.path.isabs(path):
                    continue
                if os.path.realpath(path) != expected or entry.get("destroying") is True:
                    continue
                holder = entry.get("lease_holder")
                if entry.get("leased") is True and isinstance(holder, str):
                    matches.append((state_path, pool.path, holder, "leased"))
                elif entry.get("leased") in (None, False) and holder in (None, ""):
                    matches.append((state_path, pool.path, "-", "returned"))
        except (OSError, ValueError, json.JSONDecodeError):
            continue

if len(matches) != 1:
    raise SystemExit(1)
print("\t".join(matches[0]))
PY
}

pr_state() {
  local pr=$1 rest owner repo number out timeout status
  case "$pr" in
    https://github.com/*/*/pull/[0-9]*)
      rest=${pr#https://github.com/}
      owner=${rest%%/*}
      rest=${rest#*/}
      repo=${rest%%/*}
      number=${rest#*/pull/}
      number=${number%%[!0-9]*}
      ;;
    *) printf 'unknown'; return 0 ;;
  esac
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$number" ] || {
    printf 'unknown'
    return 0
  }
  command -v gh-axi >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  timeout=${FM_TREEHOUSE_REAP_GH_TIMEOUT:-10}
  case "$timeout" in ''|*[!0-9]*|0) timeout=10 ;; esac
  if fm_run_bounded_capture --combine-stderr out "$timeout" \
      gh-axi pr view "$number" --repo "$owner/$repo"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ] || ! fm_process_tree_cleanup_verified; then
    printf 'unknown'
    return 0
  fi
  status=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*state:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
  case "$status" in open|merged|closed) printf '%s' "$status" ;; *) printf 'unknown' ;; esac
}

github_repo_for_worktree() {
  local worktree=$1 url rest owner repo
  url=$(git -C "$worktree" remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    https://github.com/*) rest=${url#https://github.com/} ;;
    git@github.com:*) rest=${url#git@github.com:} ;;
    ssh://git@github.com/*) rest=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  rest=${rest%.git}
  owner=${rest%%/*}
  repo=${rest#*/}
  [ -n "$owner" ] && [ -n "$repo" ] && [ "$repo" != "$rest" ] \
    && [ "${repo#*/}" = "$repo" ] || return 1
  printf '%s/%s' "$owner" "$repo"
}

open_pr_for_worktree() {
  local worktree=$1 meta=$2 repo branch recorded_ref out status count url seen='|'
  repo=$(github_repo_for_worktree "$worktree") || {
    printf 'none'
    return 0
  }
  command -v gh-axi >/dev/null 2>&1 || {
    printf 'unknown'
    return 0
  }
  recorded_ref=$(meta_value "$meta" worktree_git_ref)
  case "$recorded_ref" in refs/heads/*) recorded_ref=${recorded_ref#refs/heads/} ;; *) recorded_ref= ;; esac
  for branch in "$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null)" "$recorded_ref"; do
    [ -n "$branch" ] || continue
    case "$seen" in *"|$branch|"*) continue ;; esac
    seen="$seen$branch|"
    if fm_run_bounded_capture --combine-stderr out 10 \
        gh-axi pr list --repo "$repo" --state open --head "$branch" --limit 2 --fields url; then
      status=0
    else
      status=$?
    fi
    if [ "$status" -ne 0 ] || ! fm_process_tree_cleanup_verified; then
      printf 'unknown'
      return 0
    fi
    count=$(printf '%s\n' "$out" | sed -n 's/^count:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    case "$count" in
      ''|*[!0-9]*)
        printf 'unknown'
        return 0
        ;;
      0) ;;
      *)
        url=$(printf '%s\n' "$out" \
          | grep -Eo 'https://github\.com/[^",[:space:]]+/[^",[:space:]]+/pull/[0-9]+' \
          | head -1)
        printf 'open\t%s\t%s' "$branch" "${url:--}"
        return 0
        ;;
    esac
  done
  [ "$seen" != '|' ] || {
    printf 'unknown'
    return 0
  }
  printf 'none'
}

reap_one() {
  local id=$1 explicit=$2 meta kind worktree record state_path pool holder lease_state pr state out status
  local branch_pr branch_state branch_name branch_url
  local report_wait_seconds report_wait_ms
  task_id_valid "$id" || {
    echo "TREEHOUSE_REAP: retained task=$id reason=invalid-task-id"
    return 2
  }
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || {
    echo "TREEHOUSE_REAP: retained task=$id reason=metadata-unavailable"
    return 0
  }
  kind=$(meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != ship ]; then
    echo "TREEHOUSE_REAP: retained task=$id reason=unsupported-kind kind=$kind"
    return 0
  fi
  if [ "$explicit" -ne 1 ] && ! task_is_terminal "$id" "$meta"; then
    return 0
  fi
  worktree=$(meta_value "$meta" worktree)
  [ -n "$worktree" ] && [ -d "$worktree" ] || {
    echo "TREEHOUSE_REAP: retained task=$id reason=worktree-unavailable"
    return 0
  }
  record=$(lease_record_for_worktree "$worktree") || {
    echo "TREEHOUSE_REAP: retained task=$id reason=exact-lease-unprovable"
    return 0
  }
  IFS=$'\t' read -r state_path pool holder lease_state <<EOF
$record
EOF
  : "$state_path" "$pool"
  case "$lease_state" in
    leased)
      [ "$holder" = "firstmate-$id" ] || {
        echo "TREEHOUSE_REAP: retained task=$id reason=lease-holder-mismatch holder=$holder"
        return 0
      }
      ;;
    returned) ;;
    *)
      echo "TREEHOUSE_REAP: retained task=$id reason=exact-lease-unprovable"
      return 0
      ;;
  esac
  pr=$(meta_value "$meta" pr)
  if [ -n "$pr" ]; then
    state=$(pr_state "$pr")
    case "$state" in
      merged|closed) ;;
      open)
        echo "TREEHOUSE_REAP: retained task=$id reason=open-pr pr=$pr"
        return 0
        ;;
      *)
        echo "TREEHOUSE_REAP: retained task=$id reason=pr-state-unprovable pr=$pr"
        return 0
        ;;
    esac
  fi
  branch_pr=$(open_pr_for_worktree "$worktree" "$meta")
  IFS=$'\t' read -r branch_state branch_name branch_url <<EOF
$branch_pr
EOF
  case "$branch_state" in
    none) ;;
    open)
      echo "TREEHOUSE_REAP: retained task=$id reason=open-pr branch=$branch_name pr=$branch_url"
      return 0
      ;;
    *)
      echo "TREEHOUSE_REAP: retained task=$id reason=branch-pr-state-unprovable"
      return 0
      ;;
  esac
  report_wait_seconds=${FM_TREEHOUSE_REAP_REPORT_WAIT_SECONDS:-600}
  case "$report_wait_seconds" in
    ''|*[!0-9]*|0) report_wait_seconds=600 ;;
  esac
  [ "$report_wait_seconds" -le 900 ] || report_wait_seconds=900
  report_wait_ms=$((report_wait_seconds * 1000))
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_REPORT_LOCK_WAIT_MS="$report_wait_ms" \
      "$TEARDOWN" "$id" --reap-dead 2>&1); then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    echo "TREEHOUSE_REAP: retained task=$id reason=teardown-refused status=$status"
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    [ "$status" -eq "$TEARDOWN_REAP_SAFETY_REFUSAL" ] && return 0
    echo "TREEHOUSE_REAP: operational-error task=$id reason=teardown-failed status=$status" >&2
    return 1
  fi
  if [ "$lease_state" = returned ]; then
    echo "TREEHOUSE_REAP: reconciled task=$id worktree=$worktree"
  else
    echo "TREEHOUSE_REAP: released task=$id worktree=$worktree"
  fi
  return 0
}

reap() {
  local explicit=1 failed=0 meta id
  fm_refuse_if_gate_agent || return $?
  [ -x "$TEARDOWN" ] || {
    echo "TREEHOUSE_REAP: operational-error reason=teardown-unavailable path=$TEARDOWN" >&2
    return 1
  }
  if [ "${1:-}" = --auto ]; then
    [ "$#" -eq 1 ] || { usage; return 2; }
    explicit=0
    [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      id=$(basename "$meta" .meta)
      reap_one "$id" "$explicit" || failed=1
    done
  else
    [ "$#" -gt 0 ] || { usage; return 2; }
    for id in "$@"; do
      reap_one "$id" "$explicit" || failed=1
    done
  fi
  [ "$failed" -eq 0 ]
}

case "${1:-}" in
  capacity)
    shift
    capacity "$@"
    ;;
  reap)
    shift
    reap "$@"
    ;;
  *)
    usage
    exit 2
    ;;
esac

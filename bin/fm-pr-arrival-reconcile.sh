#!/usr/bin/env bash
# Discover an open non-draft GitHub PR that belongs to an in-flight PR-based
# ship task but has not reached Firstmate through the task's status channel.
#
# This is the single owner of the unreported-PR reconciliation contract.
# A candidate is eligible only when all of these independently-derived facts
# agree:
#   - state/<id>.meta is a regular single-link task record with kind=ship,
#     mode=no-mistakes or direct-PR, and no recorded pr= identity;
#   - its worktree is a real Git top-level on the exact generated fm/<id> branch;
#   - that worktree's origin is a supported canonical GitHub remote;
#   - gh-axi, run inside that worktree and filtered to the exact branch, reports
#     an open non-draft PR whose canonical URL names the same origin repository.
# Drafts, local-only tasks, scouts, secondmates, detached or renamed branches,
# already-recorded PRs, unrelated repositories, and unrelated branches are
# silent skips.
#
# On the first exact match, append a durable check wake before printing the same
# actionable reason and exiting 0.
# A clean scan with no match exits 1 silently.
# The outer scan is foreground-only and bounded by --timeout, including every
# gh-axi lookup; it never creates a shell background process.
# A timeout or an inability to inspect any otherwise-eligible task exits 3 with
# a diagnostic so the checkpoint treats the scan as failed instead of claiming
# a quiet interval.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TIMEOUT_SECONDS=${FM_PR_ARRIVAL_RECONCILE_TIMEOUT:-10}
INTERNAL_SCAN=${FM_PR_ARRIVAL_RECONCILE_INTERNAL:-0}

usage() {
  cat <<'EOF'
Usage: fm-pr-arrival-reconcile.sh [--timeout <seconds>]

Scan this home's in-flight PR-based ship tasks for an unreported open non-draft
GitHub PR on the task's exact fm/<task-id> branch.

On a match, queue and print:
  check: unreported PR for task <id>: <url> (open non-draft PR matches <branch>; run bin/fm-pr-check.sh <id> <url>)

Exit 0 when a reconciliation wake was queued, 1 when no PR matched, 2 for
invalid arguments, and 3 when the bounded scan could not inspect eligible work.
The timeout defaults to FM_PR_ARRIVAL_RECONCILE_TIMEOUT, then 10 seconds.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)
      [ "$#" -gt 1 ] || { echo "error: --timeout requires a value" >&2; exit 2; }
      TIMEOUT_SECONDS=$2
      shift 2
      ;;
    --timeout=*)
      TIMEOUT_SECONDS=${1#--timeout=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "error: --timeout must be a positive integer" >&2; exit 2 ;;
  0) echo "error: --timeout must be greater than zero" >&2; exit 2 ;;
esac

run_with_perl_timeout() {
  perl -e '
    my $seconds = shift;
    my $pid = fork;
    die "fork failed\n" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!\n";
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$TIMEOUT_SECONDS" "$0"
}

if [ "$INTERNAL_SCAN" != 1 ]; then
  scan_status=0
  if command -v timeout >/dev/null 2>&1; then
    FM_PR_ARRIVAL_RECONCILE_INTERNAL=1 \
      timeout "$TIMEOUT_SECONDS" "$0" || scan_status=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    FM_PR_ARRIVAL_RECONCILE_INTERNAL=1 \
      gtimeout "$TIMEOUT_SECONDS" "$0" || scan_status=$?
  else
    FM_PR_ARRIVAL_RECONCILE_INTERNAL=1 \
      run_with_perl_timeout || scan_status=$?
  fi
  case "$scan_status" in
    0|1|2|3) exit "$scan_status" ;;
    124|137|143)
      echo "error: PR arrival reconciliation timed out after ${TIMEOUT_SECONDS}s" >&2
      exit 3
      ;;
    *)
      echo "error: PR arrival reconciliation failed with exit $scan_status" >&2
      exit 3
      ;;
  esac
fi

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

meta_value_once() {
  local meta=$1 key=$2 count
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  sed -n "s/^${key}=//p" "$meta"
}

github_remote_path() {
  local remote=$1 path
  case "$remote" in
    https://github.com/*)
      path=${remote#https://github.com/}
      ;;
    git@github.com:*)
      path=${remote#git@github.com:}
      ;;
    ssh://git@github.com/*)
      path=${remote#ssh://git@github.com/}
      ;;
    *)
      return 1
      ;;
  esac
  path=${path%.git}
  fm_pr_url_parse "https://github.com/$path/pull/1" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  printf '%s\n' "$FM_PR_PATH"
}

command -v gh-axi >/dev/null 2>&1 || {
  echo "error: PR arrival reconciliation requires gh-axi" >&2
  exit 3
}

eligible=0
inspected=0
failed_ids=
row_pattern='^[[:space:]]*([0-9]+),.*,open,[^,]+,(yes|no),[^,]+,"(https://github\.com/[^"[:space:]]+/pull/[0-9]+)"[[:space:]]*$'
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  [ "$(fm_pr_file_link_count "$meta")" = 1 ] || continue
  id=$(basename "$meta" .meta)
  fm_pr_task_id_valid "$id" || continue
  kind=$(meta_value_once "$meta" kind) || continue
  [ "$kind" = ship ] || continue
  mode=$(meta_value_once "$meta" mode) || continue
  case "$mode" in
    no-mistakes|direct-PR) ;;
    *) continue ;;
  esac
  grep -q '^pr=' "$meta" 2>/dev/null && continue
  wt=$(meta_value_once "$meta" worktree) || continue
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || continue
  top=$(git -C "$wt_real" rev-parse --show-toplevel 2>/dev/null) || continue
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || continue
  [ "$wt_real" = "$top_real" ] || continue
  branch=$(git -C "$wt_real" symbolic-ref --quiet --short HEAD 2>/dev/null) || continue
  [ "$branch" = "fm/$id" ] || continue
  remote=$(git -C "$wt_real" remote get-url origin 2>/dev/null) || continue
  remote_path=$(github_remote_path "$remote") || continue
  eligible=$((eligible + 1))

  if ! out=$(cd "$wt_real" && gh-axi pr list --state open --head "$branch" --limit 10 --fields url 2>/dev/null); then
    failed_ids="$failed_ids $id"
    continue
  fi
  inspected=$((inspected + 1))
  lookup_rows=0
  while IFS= read -r row; do
    if [[ "$row" =~ $row_pattern ]]; then
      lookup_rows=$((lookup_rows + 1))
      number=${BASH_REMATCH[1]}
      draft=${BASH_REMATCH[2]}
      url=${BASH_REMATCH[3]}
      [ "$draft" = no ] || continue
      fm_pr_url_parse "$url" || continue
      [ "$FM_PR_PROVIDER" = github ] || continue
      [ "$FM_PR_NUMBER" = "$number" ] || continue
      remote_path_lower=$(printf '%s' "$remote_path" | tr '[:upper:]' '[:lower:]')
      pr_path_lower=$(printf '%s' "$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')
      [ "$remote_path_lower" = "$pr_path_lower" ] || continue
      reason="check: unreported PR for task $id: $url (open non-draft PR matches $branch; run bin/fm-pr-check.sh $id $url)"
      fm_wake_append check "pr-arrival:$id" "$reason" || {
        echo "error: could not queue PR arrival reconciliation for task $id" >&2
        exit 3
      }
      printf '%s\n' "$reason"
      exit 0
    fi
  done <<EOF
$out
EOF
  if [ "$lookup_rows" -eq 0 ] \
    && ! printf '%s\n' "$out" | grep -qE '^count:[[:space:]]*0($|[[:space:]])'; then
    failed_ids="$failed_ids $id"
  fi
done

if [ -n "$failed_ids" ]; then
  echo "error: PR arrival reconciliation could not inspect task(s):${failed_ids}" >&2
  exit 3
fi
if [ "$eligible" -gt 0 ] && [ "$inspected" -eq 0 ]; then
  echo "error: PR arrival reconciliation could not inspect eligible work" >&2
  exit 3
fi
exit 1

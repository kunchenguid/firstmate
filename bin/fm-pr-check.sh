#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
#        fm-pr-check.sh --expected-head <sha> --prior-head <sha>
#          --expected-repo <owner/repo> --expected-base <branch>
#          --expected-branch <branch> <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "PR check" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Preserve the fork's task/worktree/PR branch identity contract.
# shellcheck source=bin/fm-task-identity-lib.sh
. "$SCRIPT_DIR/fm-task-identity-lib.sh"

fm_scope_ledger_audit() (
  if [ "$PROVIDER" != github ]; then
    printf 'scope-ledger\tunknown\treason=provider-unsupported\n'
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    printf 'scope-ledger\tunknown\treason=gh-unavailable\n'
    return 0
  fi
  if ! "$SCRIPT_DIR/fm-scope-contract.sh" validate-brief "$SCOPE_BRIEF" >/dev/null 2>&1; then
    printf 'scope-ledger\tunknown\treason=local-contract-invalid\n'
    return 0
  fi
  SCOPE_BODY=$(mktemp "${TMPDIR:-/tmp}/fm-pr-body.XXXXXX") || {
    printf 'scope-ledger\tunknown\treason=temp-unavailable\n'
    return 0
  }
  trap 'rm -f -- "$SCOPE_BODY"' EXIT HUP INT TERM
  SCOPE_TIMEOUT=${FM_SCOPE_LEDGER_TIMEOUT_SECONDS:-3}
  case "$SCOPE_TIMEOUT" in *[!0-9]*|'') SCOPE_TIMEOUT=3 ;; esac
  [ "$SCOPE_TIMEOUT" -gt 0 ] || SCOPE_TIMEOUT=3
  if command -v timeout >/dev/null 2>&1; then
    SCOPE_TIMEOUT_RUN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    SCOPE_TIMEOUT_RUN=gtimeout
  elif command -v perl >/dev/null 2>&1; then
    SCOPE_TIMEOUT_RUN=perl
  else
    printf 'scope-ledger\tunknown\treason=timeout-unavailable\n'
    return 0
  fi
  if [ "$SCOPE_TIMEOUT_RUN" = perl ]; then
    if (cd "${WT:-$FM_ROOT}" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$SCOPE_TIMEOUT" gh pr view "$URL" --json body -q .body > "$SCOPE_BODY" 2>/dev/null); then
      SCOPE_FETCHED=1
    else
      SCOPE_FETCHED=0
    fi
  else
    if (cd "${WT:-$FM_ROOT}" && "$SCOPE_TIMEOUT_RUN" --kill-after=1 "$SCOPE_TIMEOUT" gh pr view "$URL" --json body -q .body > "$SCOPE_BODY" 2>/dev/null); then
      SCOPE_FETCHED=1
    else
      SCOPE_FETCHED=0
    fi
  fi
  if [ "$SCOPE_FETCHED" -eq 1 ]; then
    "$SCRIPT_DIR/fm-scope-contract.sh" audit-body "$SCOPE_BRIEF" "$SCOPE_BODY" \
      || printf 'scope-ledger\tunknown\treason=local-contract-invalid\n'
  else
    printf 'scope-ledger\tunknown\treason=body-unavailable\n'
  fi
)

EXPECTED_HEAD=
PRIOR_HEAD=
EXPECTED_REPO=
EXPECTED_BASE=
EXPECTED_BRANCH_ARG=
if [ "${1:-}" = --expected-head ]; then
  if [ "$#" -ne 12 ] || [ "$3" != --prior-head ] || [ "$5" != --expected-repo ] \
    || [ "$7" != --expected-base ] || [ "$9" != --expected-branch ]; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
  EXPECTED_HEAD=$2
  PRIOR_HEAD=$4
  EXPECTED_REPO=$6
  EXPECTED_BASE=$8
  EXPECTED_BRANCH_ARG=${10}
  shift 10
  if ! fm_pr_head_valid "$EXPECTED_HEAD" || ! fm_pr_head_valid "$PRIOR_HEAD" \
    || ! git check-ref-format --branch "$EXPECTED_BASE" >/dev/null 2>&1 \
    || ! git check-ref-format --branch "$EXPECTED_BRANCH_ARG" >/dev/null 2>&1; then
    echo "error: invalid PR check request" >&2
    exit 2
  fi
  case "$EXPECTED_REPO" in
    */*) ;;
    *) echo "error: invalid PR check request" >&2; exit 2 ;;
  esac
fi
if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Retirement receipts are authoritative crash-recovery state. Resolve them
# before classifying a current poll generation, including in guarded
# replacement mode where a valid retirement may have removed only a prefix of
# the three poll artifacts before interruption.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

fm_assert_task_branch_matches_meta "$ID" "$META" "error" || exit 1

# Preserve the fork's explicit remote branch identity check for GitHub PRs.
EXPECTED_BRANCH=$(fm_task_expected_branch "$ID")
if [ "$PROVIDER" = github ] && [ -z "$EXPECTED_HEAD" ]; then
  PR_BRANCH=$(gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null || true)
  [ -n "$PR_BRANCH" ] || { echo "error: could not determine head branch for PR $URL" >&2; exit 1; }
  if [ "$PR_BRANCH" != "$EXPECTED_BRANCH" ]; then
    echo "error: task identity mismatch for $ID: PR $URL head branch is $PR_BRANCH; expected $EXPECTED_BRANCH." >&2
    echo "Use the matching task id or intentionally reconcile the metadata before continuing." >&2
    exit 1
  fi
fi

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
TASK_MODE=$(fm_meta_value "$META" mode)
SCOPE_BRIEF="$DATA/$ID/brief.md"
SCOPE_MARKER="$DATA/$ID/scope-contract-enabled"
SCOPE_LEDGER_STATE=disabled
if [ "$TASK_MODE" != local-only ] && { [ -e "$SCOPE_MARKER" ] || [ -L "$SCOPE_MARKER" ]; }; then
  if "$SCRIPT_DIR/fm-scope-contract.sh" validate-marker "$SCOPE_MARKER" >/dev/null 2>&1; then
    SCOPE_LEDGER_STATE=enabled
  else
    SCOPE_LEDGER_STATE=invalid
    printf 'scope-ledger\tunknown\treason=marker-invalid\n'
  fi
fi
PR_HEAD=
GUARDED_REPLACEMENT_NEEDED=0
GUARDED_REPLACEMENT_ACTIVE=0
if [ -n "$EXPECTED_HEAD" ]; then
  [ "$PROVIDER" = github ] && [ "$PROJECT_PATH" = "$EXPECTED_REPO" ] \
    && [ "$EXPECTED_BRANCH" = "$EXPECTED_BRANCH_ARG" ] \
    && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1 || {
      echo "error: guarded PR identity could not be verified" >&2
      exit 1
    }
  PR_SNAPSHOT=$(cd "$WT" && gh pr view "$URL" \
    --json state,baseRefName,headRefName,headRefOid,headRepository,url \
    --jq '[.state,.baseRefName,.headRefName,.headRefOid,.headRepository.nameWithOwner,.url] | @tsv' \
    2>/dev/null) || {
      echo "error: guarded PR identity could not be verified" >&2
      exit 1
    }
  IFS=$'\t' read -r REMOTE_STATE REMOTE_BASE REMOTE_BRANCH REMOTE_HEAD REMOTE_REPO REMOTE_URL REMOTE_EXTRA \
    <<< "$PR_SNAPSHOT"
  if [ -n "${REMOTE_EXTRA:-}" ] || [ "$REMOTE_STATE" != OPEN ] \
    || [ "$REMOTE_BASE" != "$EXPECTED_BASE" ] \
    || [ "$REMOTE_BRANCH" != "$EXPECTED_BRANCH_ARG" ] \
    || [ "$REMOTE_REPO" != "$EXPECTED_REPO" ] || [ "$REMOTE_URL" != "$URL" ] \
    || ! fm_pr_head_valid "$REMOTE_HEAD" || [ "$REMOTE_HEAD" != "$EXPECTED_HEAD" ]; then
    echo "error: guarded PR identity or head mismatch" >&2
    exit 1
  fi
  PR_HEAD=$REMOTE_HEAD

  fm_pr_poll_replacement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" "$EXPECTED_HEAD" || {
    echo "error: guarded PR replacement receipt could not be validated" >&2
    exit 1
  }
  if [ "$FM_PR_POLL_REPLACEMENT_COMPLETE" -eq 1 ]; then
    [ "$SCOPE_LEDGER_STATE" != enabled ] || fm_scope_ledger_audit
    printf 'armed: state/%s.check.sh\n' "$ID"
    exit 0
  fi
  GUARDED_REPLACEMENT_ACTIVE=$FM_PR_POLL_REPLACEMENT_ACTIVE

  artifact_count=0
  for artifact in "$STATE/$ID.check.sh" "$STATE/$ID.pr-poll" "$STATE/$ID.pr-poll-registration"; do
    [ ! -e "$artifact" ] && [ ! -L "$artifact" ] || artifact_count=$((artifact_count + 1))
  done
  if [ "$artifact_count" -eq 3 ]; then
    fm_pr_poll_artifacts_valid "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
      echo "error: guarded PR artifacts are partial or invalid" >&2
      exit 1
    }
    [ "$FM_PR_DATA_URL" = "$URL" ] || {
      echo "error: guarded PR artifacts have foreign identity" >&2
      exit 1
    }
    recorded_head=
    recorded_head_count=0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        pr_head=*)
          recorded_head_count=$((recorded_head_count + 1))
          recorded_head=${line#pr_head=}
          ;;
      esac
    done < "$META"
    [ "$recorded_head_count" -eq 1 ] && fm_pr_head_valid "$recorded_head" || {
      echo "error: guarded PR artifacts are missing a head binding" >&2
      exit 1
    }
    if [ "$recorded_head" = "$EXPECTED_HEAD" ]; then
      [ "$SCOPE_LEDGER_STATE" != enabled ] || fm_scope_ledger_audit
      printf 'armed: state/%s.check.sh\n' "$ID"
      exit 0
    fi
    [ "$recorded_head" = "$PRIOR_HEAD" ] || {
      echo "error: guarded PR artifacts are not the prior generation" >&2
      exit 1
    }
    fm_pr_poll_snapshot_capture "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
      echo "error: guarded PR prior generation could not be captured" >&2
      exit 1
    }
    GUARDED_REPLACEMENT_NEEDED=1
  elif [ "$artifact_count" -eq 0 ]; then
    if [ "$GUARDED_REPLACEMENT_ACTIVE" -eq 1 ]; then
      grep -qxF "pr=$URL" "$META" \
        && { grep -qxF "pr_head=$PRIOR_HEAD" "$META" \
          || grep -qxF "pr_head=$EXPECTED_HEAD" "$META"; } || {
          echo "error: guarded PR replacement metadata is inconsistent" >&2
          exit 1
        }
    elif grep -qE '^pr(_head)?=' "$META"; then
      echo "error: guarded PR metadata is not an unpublished generation" >&2
      exit 1
    fi
  else
    echo "error: guarded PR artifacts are partial or invalid" >&2
    exit 1
  fi
fi

if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh"

if [ -z "$PR_HEAD" ] && [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

if [ "$GUARDED_REPLACEMENT_NEEDED" -eq 1 ]; then
  fm_pr_poll_replacement_publish "$STATE" "$ID" "$PRIOR_HEAD" "$EXPECTED_HEAD" || {
    echo "error: could not publish guarded PR replacement receipt" >&2
    exit 1
  }
  GUARDED_REPLACEMENT_ACTIVE=1
fi

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
if [ "$GUARDED_REPLACEMENT_ACTIVE" -eq 1 ]; then
  fm_pr_poll_replacement_finish "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" "$EXPECTED_HEAD" || {
    echo "error: could not finalize guarded PR replacement" >&2
    exit 1
  }
fi
[ "$SCOPE_LEDGER_STATE" != enabled ] || fm_scope_ledger_audit
printf 'armed: state/%s.check.sh\n' "$ID"

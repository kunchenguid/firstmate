#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url>, the forge's
# exact pr_head=<sha> when available, and the pull request's destination
# branch as pr_dest=<name> when known, then atomically arm a static merge
# poll. The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and
# PR data live only in a private sidecar and are never interpolated into
# shell source. A GitHub pull request URL, a GitLab merge request URL
# (including on a self-hosted instance), and a Bitbucket Cloud pull request
# URL are all accepted; bin/fm-pr-lib.sh owns the exact URL grammars.
#
# pr_dest is what lets bin/fm-teardown.sh's and bin/fm-pr-poll.sh's git-based
# landed-work test compare against the PULL REQUEST'S destination instead of
# always assuming the repository's default branch - most pull requests target
# the default branch, but one that does not would otherwise be judged against
# the wrong branch forever. It is read from the optional third argument when
# the caller already knows it, else auto-derived from the forge (GitHub's gh
# CLI exposes baseRefName as a selectable field); GitLab records none, for the
# same reason it records no pr_head (below); Bitbucket has no CLI at all, so a
# Bitbucket task needs the third argument to get a destination narrower than
# the default branch. Either source is revalidated with
# `git check-ref-format --branch` before being recorded, and a missing
# destination is not an error: every consumer defaults to the default branch
# when none is recorded, matching prior behavior. The one exception is a
# re-arm of the exact same pr= URL with no destination supplied this call
# (for example bin/fm-pr-merge.sh's internal re-arm before merging): that
# keeps the previously recorded pr_dest instead of wiping it, since nothing
# about the pull request's destination changed. A re-arm for a different URL
# still gets no carried-over destination.
# Usage: fm-pr-check.sh <task-id> <pr-url> [dest-branch]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
RAW_DEST=${3-}
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
if [ -n "$RAW_DEST" ] && ! git check-ref-format --branch "$RAW_DEST" >/dev/null 2>&1; then
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

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# A stale destination-tip cache from a prior arm of this task (bin/fm-pr-poll.sh
# owns its format and lifecycle) must not survive a re-arm: it holds no
# security-sensitive data, so removing it is best-effort, but leaving it behind
# could let the new poll's very first evaluation skip itself on a coincidental
# tip match against the previous PR's destination.
rm -f -- "$STATE/$ID.pr-poll-git-tip" 2>/dev/null || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
# pr_dest is auto-derived here in the same call for the same provider (gh
# exposes baseRefName alongside headRefOid), for the same reason: GitLab would
# need jq to read it out of glab's JSON output, so a GitLab task records none
# and its git-based landed-work test falls back to the default branch.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
PR_DEST=$RAW_DEST
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_VIEW=$(cd "$WT" && gh pr view "$URL" --json headRefOid,baseRefName \
    -q '.headRefOid + "\t" + .baseRefName' 2>/dev/null); then
    REMOTE_HEAD=${REMOTE_VIEW%%$'\t'*}
    REMOTE_DEST=${REMOTE_VIEW#*$'\t'}
    if [ "$REMOTE_HEAD" != "$REMOTE_VIEW" ]; then
      fm_pr_head_valid "$REMOTE_HEAD" && PR_HEAD=$REMOTE_HEAD
      if [ -z "$PR_DEST" ] && git check-ref-format --branch "$REMOTE_DEST" >/dev/null 2>&1; then
        PR_DEST=$REMOTE_DEST
      fi
    fi
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
EXISTING_PR=
EXISTING_DEST=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*) EXISTING_PR=${line#pr=} ;;
    pr_head=*) ;;
    pr_dest=*) EXISTING_DEST=${line#pr_dest=} ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
if [ -z "$PR_DEST" ] && [ -n "$EXISTING_DEST" ] && [ "$EXISTING_PR" = "$URL" ]; then
  PR_DEST=$EXISTING_DEST
fi
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
[ -z "$PR_DEST" ] || printf 'pr_dest=%s\n' "$PR_DEST" >> "$META_TMP" || exit 1
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
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"

#!/usr/bin/env bash
# Record a PR-ready task: first prove that a live push destination advertises a
# branch containing the ship worktree's current HEAD, then store one validated
# canonical pr=<url> and the forge's exact pr_head=<sha> when available and
# atomically arm a static merge poll. Scout and non-pushing modes skip that proof.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-git-live-remote-lib.sh
. "$SCRIPT_DIR/fm-git-live-remote-lib.sh"

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

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_KIND=
PR_RAW_KIND=
PR_MODE=
PR_DELIVERY_MODE=
WT=
META_DEVICE=
STATE_DEVICE=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
pr_check_read_delivery_metadata() {
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || return 1
  META_DEVICE=$(fm_pr_file_device "$META") || return 1
  STATE_DEVICE=$(fm_pr_file_device "$STATE") || return 1
  [ "$META_DEVICE" = "$STATE_DEVICE" ] || return 1
  PR_RAW_KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_KIND=${PR_RAW_KIND:-ship}
  PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_DELIVERY_MODE=$PR_MODE
  if [ "$PR_KIND" = ship ] && [ -z "$PR_DELIVERY_MODE" ]; then
    PR_DELIVERY_MODE=no-mistakes
  fi
}
pr_check_release_meta_lock() {
  fm_lock_release "$META_LOCK"
  META_LOCK_HELD=0
}
pr_check_delivery_proof_error() {  # <status>
  case "$1" in
    "$FM_GIT_LIVE_REMOTE_TIMEOUT")
      echo "error: refusing PR delivery because the live-remote probe timed out; check remote connectivity and authentication, then retry" >&2
      ;;
    "$FM_GIT_LIVE_REMOTE_BUDGET_EXHAUSTED")
      echo "error: refusing PR delivery because the live-remote probe exhausted its overall budget; remove or repair unreachable remotes, then retry" >&2
      ;;
    "$FM_GIT_LIVE_REMOTE_PROBE_FAILED")
      echo "error: refusing PR delivery because the non-interactive live-remote probe failed; authenticate or repair the remote, then retry" >&2
      ;;
    *)
      echo "error: refusing PR delivery because worktree HEAD is not present on any live remote branch" >&2
      ;;
  esac
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
PROBE_DEADLINE=
while :; do
  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  pr_check_read_delivery_metadata \
    || { echo "error: task metadata is unavailable" >&2; exit 1; }
  PROBE_KIND=$PR_KIND
  PROBE_RAW_KIND=$PR_RAW_KIND
  PROBE_MODE=$PR_MODE
  PROBE_DELIVERY_MODE=$PR_DELIVERY_MODE
  PROBE_WT=$WT
  pr_check_release_meta_lock

  PROBE_HEAD=
  case "$PROBE_KIND:$PROBE_DELIVERY_MODE" in
    ship:no-mistakes|ship:direct-PR)
      if [ -z "$PROBE_WT" ] || [ ! -d "$PROBE_WT" ] \
        || ! PROBE_HEAD=$(git -C "$PROBE_WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
        echo "error: refusing PR delivery because task worktree HEAD is unavailable" >&2
        exit 1
      fi
      if [ -z "$PROBE_DEADLINE" ]; then
        PROBE_DEADLINE=$(fm_git_live_remote_deadline) || {
          pr_check_delivery_proof_error "$FM_GIT_LIVE_REMOTE_PROBE_FAILED"
          exit 1
        }
      fi
      PROOF_RC=0
      fm_git_commit_is_on_live_remote "$PROBE_WT" "$PROBE_HEAD" "$PROBE_DEADLINE" || PROOF_RC=$?
      if [ "$PROOF_RC" -ne 0 ]; then
        pr_check_delivery_proof_error "$PROOF_RC"
        exit 1
      fi
      ;;
  esac

  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  pr_check_read_delivery_metadata \
    || { echo "error: task metadata is unavailable" >&2; exit 1; }
  DELIVERY_STATE_STABLE=0
  if [ "$PR_RAW_KIND" = "$PROBE_RAW_KIND" ] && [ "$PR_KIND" = "$PROBE_KIND" ] \
    && [ "$PR_MODE" = "$PROBE_MODE" ] \
    && [ "$PR_DELIVERY_MODE" = "$PROBE_DELIVERY_MODE" ] && [ "$WT" = "$PROBE_WT" ]; then
    case "$PR_KIND:$PR_DELIVERY_MODE" in
      ship:no-mistakes|ship:direct-PR)
        LOCKED_HEAD=$(git -C "$WT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
        [ -n "$LOCKED_HEAD" ] && [ "$LOCKED_HEAD" = "$PROBE_HEAD" ] && DELIVERY_STATE_STABLE=1
        ;;
      *) DELIVERY_STATE_STABLE=1 ;;
    esac
  fi
  [ "$DELIVERY_STATE_STABLE" -eq 0 ] || break
  pr_check_release_meta_lock
done
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi
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
pr_check_release_meta_lock

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"

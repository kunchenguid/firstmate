#!/usr/bin/env bash
# Refresh merge watches after a trusted update of this Firstmate checkout.
# Usage: fm-pr-poll-refresh.sh <previous-full-commit>
# FM_ROOT_OVERRIDE selects the updated code root; FM_HOME / FM_STATE_OVERRIDE
# select only the operational state belonging to that checkout.
# The previous commit must be an ancestor of HEAD or provably redundant.
# Both templates come from Git objects; the installed template must match HEAD.
# Every prior poll must pass the unchanged strict authentication against the old
# template (including registration hashes, file identities and canonical metadata).
# Republishes through fm-pr-lib.sh under control, metadata and publication locks;
# never executes state-file source, queries a forge, or changes task metadata.
# Current polls are left alone, invalid polls are reported and left rejected,
# and pending terminal retirement receipts are left to their existing recovery.
# Returns nonzero on any refused refresh; callers report it without undoing Git.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'usage: fm-pr-poll-refresh.sh <previous-full-commit>' >&2
  exit 2
fi
[ -d "$STATE" ] || exit 0
[ ! -L "$STATE" ] || exit 1
if ! git -C "$FM_ROOT" merge-base --is-ancestor "$1" HEAD; then
  # shellcheck source=bin/fm-ff-lib.sh
  . "$SCRIPT_DIR/fm-ff-lib.sh"
  divergence_is_redundant "$FM_ROOT" "$1" HEAD || exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-poll-refresh.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 1' HUP INT TERM
git -C "$FM_ROOT" show "$1:bin/fm-pr-poll.sh" > "$scratch/old" || exit 1
git -C "$FM_ROOT" show HEAD:bin/fm-pr-poll.sh > "$scratch/current" || exit 1
template="$FM_ROOT/bin/fm-pr-poll.sh"
[ -f "$template" ] && [ ! -L "$template" ] && cmp -s "$scratch/current" "$template" || exit 1
cmp -s "$scratch/old" "$scratch/current" && exit 0

refresh_one() (
  id=$1
  control_lock="$STATE/.control-$id.lock"
  meta_lock=$(fm_meta_lock_path "$STATE/$id.meta") || exit 1
  publish_lock="$STATE/.pr-poll-publish-$id.lock"
  control_held=0 meta_held=0 publish_held=0
  # shellcheck disable=SC2329 # Invoked by the EXIT trap in this subshell.
  cleanup() {
    fm_pr_poll_cleanup
    [ "$publish_held" = 0 ] || fm_lock_release "$publish_lock"
    [ "$meta_held" = 0 ] || fm_lock_release "$meta_lock"
    [ "$control_held" = 0 ] || fm_lock_release "$control_lock"
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  fm_lock_acquire_wait "$control_lock"
  control_held=1
  fm_lock_acquire_wait "$meta_lock"
  meta_held=1
  fm_lock_acquire_wait "$publish_lock"
  publish_held=1
  # Do not resurrect an observed terminal generation, including interrupted
  # retirement, or overwrite a concurrent explicit re-arm onto the new bytes.
  [ ! -e "$STATE/$id.pr-poll-retirement" ] && [ ! -L "$STATE/$id.pr-poll-retirement" ] || exit 0
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$template" && exit 0
  fm_pr_poll_snapshot_capture "$STATE" "$id" "$scratch/old" || exit 1
  fm_pr_poll_prepare "$STATE" "$id" "$FM_PR_POLL_SNAPSHOT_PROVIDER" \
    "$FM_PR_POLL_SNAPSHOT_URL" "$FM_PR_POLL_SNAPSHOT_HOST" \
    "$FM_PR_POLL_SNAPSHOT_PATH" "$FM_PR_POLL_SNAPSHOT_NUMBER" "$template" || exit 1
  fm_pr_poll_snapshot_matches "$STATE" "$id" "$scratch/old" || exit 1
  cmp -s "$scratch/current" "$template" || exit 1
  fm_pr_poll_publish_prepared || exit 1
  printf 'pr-poll-refresh: refreshed %s\n' "$id"
)

failed=0
for check in "$STATE"/*.check.sh; do
  [ -e "$check" ] || [ -L "$check" ] || continue
  id=${check##*/}
  id=${id%.check.sh}
  fm_pr_task_id_valid "$id" || continue
  # Custom checks belong to their own registration mechanism.
  [ -e "$STATE/$id.pr-poll" ] || [ -L "$STATE/$id.pr-poll" ] \
    || [ -e "$STATE/$id.pr-poll-registration" ] || [ -L "$STATE/$id.pr-poll-registration" ] || continue
  if ! refresh_one "$id"; then
    printf 'pr-poll-refresh: rejected %s; prior poll could not be authenticated or republished\n' "$id" >&2
    failed=1
  fi
done
exit "$failed"

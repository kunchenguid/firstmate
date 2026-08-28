#!/usr/bin/env bash
# Register a PR-ready task: atomically replace pr=<url> and GitHub's
# pr_head=<sha> in state/<id>.meta, arm the watcher's merge poll, and
# asynchronously start the independent exact-head Crosscheck review.
# Registration returns after the task-local coordinator is requested; review
# latency never parks the caller. Matching active or CLEAR heads deduplicate,
# failed/dead coordinators remain visible and retryable, and unrelated tasks
# never share a launcher lock. A task-local registration lock orders head
# capture and publication without holding the account metadata lock across the
# remote lookup. The task generation protects a reused task ID from a stale
# lookup result; authorship, branch, account, model, worktree, and launch state
# are deliberately not registration inputs.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-account-routing-lib.sh
. "$SCRIPT_DIR/fm-account-routing-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$STATE/$ID.meta"
LOOKUP_GENERATION=
PR_HEAD=
CROSSCHECK_AUTOSTART="$SCRIPT_DIR/fm-crosscheck-autostart.py"
CROSSCHECK_AUTOSTART_ENABLED=1
case "${FM_CROSSCHECK_AUTOSTART_TEST_DISABLE:-}" in
  '') ;;
  firstmate-pr-check-nonautostart-test-v1)
    [ "${FM_TEST_RUNNER_ACTIVE:-}" = firstmate-test-runner-v1 ] || {
      echo "error: the Crosscheck autostart test bypass is available only inside the sealed behavior-test runner" >&2
      exit 1
    }
    CROSSCHECK_AUTOSTART_ENABLED=0
    ;;
  *)
    echo "error: invalid FM_CROSSCHECK_AUTOSTART_TEST_DISABLE value" >&2
    exit 1
    ;;
esac
REGISTRATION_LOCK=$(fm_account_lock_acquire "$STATE" "$ID" pr-registration \
  "PR registration" "${FM_ACCOUNT_META_LOCK_WAIT_SECONDS:-10}") || exit 1
META_LOCK=
release_meta_lock() {
  if [ -n "$META_LOCK" ]; then
    fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
  fi
  fm_account_meta_lock_release "$REGISTRATION_LOCK" >/dev/null 2>&1 || true
}
trap release_meta_lock EXIT
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
if [ ! -f "$META" ]; then
  fm_account_meta_lock_release "$META_LOCK"
  echo "error: no task metadata for $ID" >&2
  exit 1
fi
LOOKUP_GENERATION=$(fm_account_meta_value "$META" generation_id)
if [ -z "$LOOKUP_GENERATION" ]; then
  LEGACY_ATTEMPT=$(fm_account_attempt_id "$FM_HOME" "$ID") || {
    fm_account_meta_lock_release "$META_LOCK"
    exit 1
  }
  LOOKUP_GENERATION="legacy:$LEGACY_ATTEMPT"
  META_TMP=$(mktemp "$STATE/.$ID.meta.generation.XXXXXX") || {
    fm_account_meta_lock_release "$META_LOCK"
    exit 1
  }
  if ! awk '{ print }' "$META" > "$META_TMP" \
    || ! printf 'generation_id=%s\n' "$LOOKUP_GENERATION" >> "$META_TMP" \
    || ! fm_account_safe_file_destination "$META" \
    || ! mv "$META_TMP" "$META"; then
    rm -f "$META_TMP"
    fm_account_meta_lock_release "$META_LOCK"
    echo "error: could not backfill legacy task generation for $ID" >&2
    exit 1
  fi
fi
# Serialize head capture/publication only against other registrations, not
# account-session updates or task retirement during a remote lookup.
fm_account_meta_lock_release "$META_LOCK"
META_LOCK=
if ! PR_HEAD_LOOKUP=$("$FM_ROOT/bin/fm-github-pr.py" head "$URL" 2>&1); then
  PR_HEAD_DIAGNOSTIC=$(printf '%s' "$PR_HEAD_LOOKUP" | tr '\r\n' '  ')
  printf 'UNREVIEWED: PR head lookup failed: %.500s\n' "$PR_HEAD_DIAGNOSTIC" >&2
  exit 1
fi
PR_HEAD=$PR_HEAD_LOOKUP
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
if [ -f "$META" ]; then
  CURRENT_GENERATION=$(fm_account_meta_value "$META" generation_id)
  if [ "$CURRENT_GENERATION" != "$LOOKUP_GENERATION" ]; then
    echo "error: task generation changed while resolving PR state for $ID" >&2
    exit 1
  fi
  META_TMP=$(mktemp "$STATE/.$ID.meta.pr.XXXXXX") || exit 1
  if ! awk '$0 !~ /^pr(_head)?=/' "$META" > "$META_TMP" \
    || ! printf 'pr=%s\npr_head=%s\n' "$URL" "$PR_HEAD" >> "$META_TMP" \
    || ! fm_account_safe_file_destination "$META" \
    || ! mv "$META_TMP" "$META"; then
    rm -f "$META_TMP"
    echo "error: could not atomically record live PR identity for $ID" >&2
    exit 1
  fi
else
  echo "error: task metadata disappeared while resolving PR state for $ID" >&2
  exit 1
fi
CHECK_TMP=$(mktemp "$STATE/.$ID.check.XXXXXX") || exit 1
printf -v PR_ADAPTER_Q '%q' "$FM_ROOT/bin/fm-github-pr.py"
printf -v CROSSCHECK_AUTOSTART_Q '%q' "$CROSSCHECK_AUTOSTART"
printf -v ID_Q '%q' "$ID"
printf -v URL_Q '%q' "$URL"
printf -v PR_HEAD_Q '%q' "$PR_HEAD"
printf -v GENERATION_Q '%q' "$LOOKUP_GENERATION"
cat > "$CHECK_TMP" <<EOF
if ! state=\$($PR_ADAPTER_Q state $URL_Q 2>&1); then
  diagnostic=\$(printf '%s' "\$state" | tr '\r\n' '  ')
  printf 'UNREVIEWED: PR state lookup failed: %.500s\n' "\$diagnostic"
  exit 0
fi
if [ "\$state" = MERGED ]; then
  echo "merged"
  exit 0
fi
if ! crosscheck_state=\$($CROSSCHECK_AUTOSTART_Q status $ID_Q $URL_Q $PR_HEAD_Q $GENERATION_Q 2>&1); then
  diagnostic=\$(printf '%s' "\$crosscheck_state" | tr '\r\n' '  ')
  printf 'UNREVIEWED: Crosscheck autostart failed: %.500s\n' "\$diagnostic"
  exit 0
fi
case "\$state" in
  OPEN) ;;
  MERGED) echo "merged" ;;
  *) printf 'UNREVIEWED: PR state is %.500s\n' "\$state" ;;
esac
EOF
chmod +x "$CHECK_TMP"
mv "$CHECK_TMP" "$STATE/$ID.check.sh"
echo "armed: state/$ID.check.sh polls $URL"
if [ "$CROSSCHECK_AUTOSTART_ENABLED" = 1 ]; then
  if CROSSCHECK_AUTOSTART_OUT=$("$CROSSCHECK_AUTOSTART" start \
    "$ID" "$URL" "$PR_HEAD" "$LOOKUP_GENERATION" 2>&1); then
    printf '%s\n' "$CROSSCHECK_AUTOSTART_OUT"
  else
    CROSSCHECK_AUTOSTART_DIAGNOSTIC=$(printf '%s' "$CROSSCHECK_AUTOSTART_OUT" | tr '\r\n' '  ')
    printf 'UNREVIEWED: Crosscheck autostart launcher failed: %.500s\n' \
      "$CROSSCHECK_AUTOSTART_DIAGNOSTIC" >&2
  fi
fi
fm_account_meta_lock_release "$META_LOCK"
fm_account_meta_lock_release "$REGISTRATION_LOCK"
trap - EXIT

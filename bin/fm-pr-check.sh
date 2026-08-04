#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line when the PR is merged or its lookup
# fails (the watcher's check contract: output = wake, silence = keep sleeping).
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
LOOKUP_WT=
LOOKUP_GENERATION=
PR_HEAD=
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
if [ ! -f "$META" ]; then
  fm_account_meta_lock_release "$META_LOCK"
  echo "error: no task metadata for $ID" >&2
  exit 1
fi
LOOKUP_WT=$(fm_account_meta_value "$META" worktree)
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
fm_account_meta_lock_release "$META_LOCK"
if ! PR_HEAD_LOOKUP=$("$FM_ROOT/bin/fm-github-pr.py" head "$URL" 2>&1); then
  PR_HEAD_DIAGNOSTIC=$(printf '%s' "$PR_HEAD_LOOKUP" | tr '\r\n' '  ')
  printf 'UNREVIEWED: PR head lookup failed: %.500s\n' "$PR_HEAD_DIAGNOSTIC" >&2
  exit 1
fi
PR_HEAD=$PR_HEAD_LOOKUP
META_LOCK=$(fm_account_meta_lock_acquire "$STATE" "$ID") || exit 1
release_meta_lock() {
  fm_account_meta_lock_release "$META_LOCK" >/dev/null 2>&1 || true
}
trap release_meta_lock EXIT
if [ -f "$META" ]; then
  CURRENT_WT=$(fm_account_meta_value "$META" worktree)
  CURRENT_GENERATION=$(fm_account_meta_value "$META" generation_id)
  if [ "$CURRENT_GENERATION" != "$LOOKUP_GENERATION" ] || [ "$CURRENT_WT" != "$LOOKUP_WT" ]; then
    echo "error: task generation changed while resolving PR state for $ID" >&2
    exit 1
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ "$CURRENT_WT" = "$LOOKUP_WT" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
else
  echo "error: task metadata disappeared while resolving PR state for $ID" >&2
  exit 1
fi
CHECK_TMP=$(mktemp "$STATE/.$ID.check.XXXXXX") || exit 1
printf -v PR_ADAPTER_Q '%q' "$FM_ROOT/bin/fm-github-pr.py"
printf -v URL_Q '%q' "$URL"
cat > "$CHECK_TMP" <<EOF
if ! state=\$($PR_ADAPTER_Q state $URL_Q 2>&1); then
  diagnostic=\$(printf '%s' "\$state" | tr '\r\n' '  ')
  printf 'UNREVIEWED: PR state lookup failed: %.500s\n' "\$diagnostic"
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
fm_account_meta_lock_release "$META_LOCK"
trap - EXIT
echo "armed: state/$ID.check.sh polls $URL"

#!/usr/bin/env bash
# Publish durable completion evidence for one task's current candidate.
# Usage: FM_HOME=<supervising-home> fm-run-receipt.sh <task-id> PASS|FAIL <evidence-file> [candidate-repo]
# candidate-repo defaults to the current directory. PASS requires a clean tree.
# The evidence file must contain the checks/commands, their outcomes and any
# limitations; it is embedded in the receipt, not stored as a temporary pointer.
# bin/fm-dod-lib.sh owns the schema, compatibility and acceptance contract.
# The existing task control lock serializes publication with guarded landing.
set -eu
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
fi
# The fork libraries live in the fork's bin/ (FM_FORK_BIN, else $FM_HOME/bin), not beside this add-on script.
SCRIPT_DIR=${FM_FORK_BIN:-${FM_HOME:?explicit supervising FM_HOME required}/bin}
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ] || ! fm_pr_task_id_valid "$1"; then
  echo "usage: FM_HOME=<home> fm-run-receipt.sh <id> PASS|FAIL <evidence-file> [repo]" >&2
  exit 2
fi
# These adapters do not themselves call Claude; when a pool is configured,
# downstream tools inherit its account rather than an ambient default login.
# shellcheck source=account-pool/bin/fm-pool-claude-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/account-pool/bin/fm-pool-claude-env.sh"
if [ -f "$FM_HOME/config/account-pool" ]; then fm_pool_claude_env || exit 1; fi

ID=$1 VERDICT=$2 EVIDENCE=$3 REPO=${4:-.}
case "$VERDICT" in PASS|FAIL) ;; *) echo 'error: verdict must be PASS or FAIL' >&2; exit 2 ;; esac
: "${FM_HOME:?explicit supervising FM_HOME required}"
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
META="$STATE/$ID.meta"
[ -f "$META" ] && [ -f "$EVIDENCE" ] || { echo 'error: task metadata or evidence missing' >&2; exit 1; }
command -v jq >/dev/null || { echo 'error: jq required for completion receipts' >&2; exit 1; }
LOCK="$STATE/.control-$ID.lock"
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  fm_lock_release "$LOCK" || true
}
fm_lock_acquire_wait "$LOCK"
trap cleanup EXIT
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MODE=$(fm_dod_meta_value "$META" mode)
case "$MODE" in local-only|direct-PR|no-mistakes) ;; *) echo 'error: receipt requires a ship delivery mode' >&2; exit 1 ;; esac
HEAD_SHA=$(git -C "$REPO" rev-parse --verify 'HEAD^{commit}')
if [ "$VERDICT" = PASS ] && [ -n "$(git -C "$REPO" status --porcelain)" ]; then
  echo 'error: PASS requires a clean candidate checkout' >&2
  exit 1
fi
GEN=$FM_BACKLOG_META_SPAWN_GEN
# The receipt names the pull request it covers (the URL carries the repository);
# acceptance compares it with the pr= the merge path recorded. FM_RECEIPT_PR
# overrides the lookup of the candidate branch's open PR.
PR_URL=${FM_RECEIPT_PR:-}
if [ -z "$PR_URL" ] && command -v gh >/dev/null; then
  PR_URL=$(cd "$REPO" && gh pr view --json url --jq .url 2>/dev/null) || PR_URL=
fi
umask 077
TMP=$(mktemp "$STATE/.$ID.run-receipt.XXXXXX")
jq -n --arg task "$ID" --arg mode "$MODE" --arg gen "$GEN" \
  --arg head "$HEAD_SHA" --arg pr "$PR_URL" --arg verdict "$VERDICT" --argjson at "$(date +%s)" \
  --rawfile evidence "$EVIDENCE" '
  if ($evidence | test("[^[:space:]]")) then
    {schema:1, task:$task, mode:$mode, spawn_gen:$gen, head:$head, pr:$pr,
     verdict:$verdict, at:$at, evidence:$evidence}
  else error("nonempty evidence required") end
' > "$TMP"
if ! fm_backlog_atomic_transition publish "$TMP" "$STATE/$ID.run-receipt.json" "completion receipt" "$STATE"; then
  echo "error: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
TMP=
printf 'receipt: %s %s head=%s\n' "$ID" "$VERDICT" "$HEAD_SHA"

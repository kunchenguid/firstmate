#!/usr/bin/env bash
# Attended Decision OS main-steward adapter. Executes one authorized tracker
# mutation request (schema fm-tracker-request.v1) against the registered
# decision-os main clone and persists the authoritative receipt into the
# attempt record. Only the attended Decision OS main steward invokes this
# script. Written against the installed br 0.2.19 and br_worktree_storage.py
# command contracts. Never infers or enlarges authority.
#
# Usage: fm-br-receipt.sh <request-json-file>
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"

REQ_FILE=$1
REQ=$(cat "$REQ_FILE")
attempt=$(echo "$REQ" | jq -r '.attempt_id')
gen=$(echo "$REQ" | jq -r '.generation')
bead=$(echo "$REQ" | jq -r '.bead_id')
transition=$(echo "$REQ" | jq -r '.transition')
expected_state=$(echo "$REQ" | jq -r '.expected_state')
expected_hash=$(echo "$REQ" | jq -r '.expected_source_hash')
authority=$(echo "$REQ" | jq -r '.authority')
agent=$(echo "$REQ" | jq -r '.agent')
repo=$(echo "$REQ" | jq -r '.repo')
BR_BIN="$(command -v br)"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-br-receipt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

run_storage() {  # <args...>
  (cd "$repo" && PYTHONPATH=src .venv/bin/python "$repo/scripts/br_worktree_storage.py" "$@")
}

fail_tracker() {  # <reason>; records a durable pending obligation and refuses
  echo "tracker_pending: $*" >&2
  fm_attempt_effect_pending "$attempt" "$gen" tracker \
    "$(jq -n --arg reason "$*" --arg transition "$transition" \
      '{status:"pending",reason:$reason,transition:$transition,authority:"'"$authority"'"}')" \
    || echo "tracker: failed to record pending obligation for $attempt" >&2
  rm -f "$STATE_DIR/.tracker-pause"
  exit 1
}

[ -n "$authority" ] || fail_tracker "missing current-session authority"
[ -n "$agent" ] || fail_tracker "missing bound agent identity"

# 1. durable pause receipt: stop new decision-os worktree creation and all
#    admitted tracker writers for this attempt.
printf '%s\n' "attempt=$attempt transition=$transition started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$STATE_DIR/.tracker-pause"

# 2. enter the canonical registered main clone, never a linked worktree
cd "$repo" || fail_tracker "not the registered clone: $repo"
[ -d .beads ] || fail_tracker "no .beads in $repo"

# 3. guarded fast-forward refresh: fetch, then verify local main is not behind
git fetch origin >/dev/null 2>&1 || fail_tracker "fetch failed"
if ! git merge-base --is-ancestor origin/main HEAD; then
  if ! git merge --ff-only origin/main >/dev/null 2>&1; then
    fail_tracker "local main diverged from origin/main; refresh refused"
  fi
fi

# 4. verify session, identity, authority, clean preflight, expected commit and
#    pre-mutation source hash
run_storage verify-session --repo "$repo" --agent "$agent" >/dev/null 2>&1 \
  || fail_tracker "verify-session failed"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail_tracker "clone not on main"
actual_hash=$(sha256sum .beads/issues.jsonl | cut -d' ' -f1)
[ "$actual_hash" = "$expected_hash" ] || fail_tracker "source hash mismatch $actual_hash != $expected_hash"

case "$transition" in
  claim)
    run_storage claim "$bead" --repo "$repo" --agent "$agent" --br-bin "$BR_BIN" >/dev/null 2>&1 \
      || fail_tracker "claim refused"
    post_state="claimed" ;;
  close)
    # Closure-Receipt must be operative BEFORE br close; verified via the
    # installed br comments list (array-shaped)
    br comments add "$bead" -m "Closure-Receipt: landed $authority attempt=$attempt" >/dev/null 2>&1 \
      || fail_tracker "closure receipt comment failed"
    br comments list "$bead" --json 2>/dev/null | jq -e --arg s "attempt=$attempt" \
      '.[] | select(.text | contains("Closure-Receipt:")) | select(.text | contains($s))' >/dev/null \
      || fail_tracker "operative Closure-Receipt comment not verified"
    br close "$bead" >/dev/null 2>&1 || fail_tracker "br close failed"
    post_state="closed" ;;
  status)
    br update "$bead" --status "$expected_state" >/dev/null 2>&1 \
      || fail_tracker "status transition refused"
    post_state="$expected_state" ;;
  *) fail_tracker "unknown transition $transition" ;;
esac

# 5. validate staged AND unstaged path sets; commit with an explicit pathspec
run_storage preflight --repo "$repo" --status-out "$TMP/status.json" --br-bin "$BR_BIN" >/dev/null 2>&1 \
  || fail_tracker "post-mutation preflight failed"
outside=$( { git diff --cached --name-only; git diff --name-only; } | grep -v '^\.beads/issues\.jsonl$' || true)
[ -z "$outside" ] || fail_tracker "staged or unstaged path outside .beads/issues.jsonl: $outside"
post_hash=$(sha256sum .beads/issues.jsonl | cut -d' ' -f1)
git add .beads/issues.jsonl
git commit -m "tracker: $transition $bead attempt=$attempt" -- .beads/issues.jsonl >/dev/null 2>&1 \
  || fail_tracker "receipt-only commit failed"

# 6. verify committed blob hash, then guarded fast-forward publish
committed=$(git rev-parse HEAD:.beads/issues.jsonl | xargs -I{} git cat-file blob {} | sha256sum | cut -d' ' -f1)
[ "$committed" = "$post_hash" ] || fail_tracker "committed blob hash mismatch"
git push origin main >/dev/null 2>&1 || fail_tracker "push failed (pending obligation)"

# 7. persist the receipt before releasing the pause
recv=$(jq -n --arg bead "$bead" --arg post "$post_state" --arg commit "$(git rev-parse HEAD)" \
  --arg source_hash "$actual_hash" --arg post_hash "$post_hash" --arg authority "$authority" \
  '{bead:$bead,status:$post,commit:$commit,source_hash:$source_hash,post_hash:$post_hash,authority:$authority,agent:"'"$agent"'"}')
fm_attempt_effect_observe "$attempt" "$gen" tracker "$recv" || fail_tracker "receipt persist failed"
rm -f "$STATE_DIR/.tracker-pause"
echo "tracker_receipt: $attempt $transition $bead $post_state $(git rev-parse HEAD)"

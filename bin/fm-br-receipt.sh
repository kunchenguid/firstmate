#!/usr/bin/env bash
# Attended Decision OS main-steward adapter. Executes one authorized tracker
# mutation request (schema fm-tracker-request.v1) against the registered
# decision-os main clone and persists the authoritative receipt into the
# attempt record. Only the attended Decision OS main steward invokes this
# script. Written against the installed br 0.2.19 and br_worktree_storage.py
# command contracts. Never infers or enlarges authority.
#
# FM_ATTEMPT_LOCK_HELD=1 switches receipt persistence to the lock-held
# primitives because the terminal holds the non-reentrant attempt lock.
#
# Usage: fm-br-receipt.sh <request-json-file>
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
# shellcheck source=bin/fm-attempt-lib.sh
. "$SCRIPT_DIR/fm-attempt-lib.sh"

[ "$#" -eq 1 ] || { echo "usage: fm-br-receipt.sh <request-json-file>" >&2; exit 2; }
REQ_FILE=$1
[ -f "$REQ_FILE" ] && [ ! -L "$REQ_FILE" ] || { echo "tracker: invalid request file" >&2; exit 2; }
REQ=$(jq -c . "$REQ_FILE" 2>/dev/null) || { echo "tracker: invalid request JSON" >&2; exit 2; }
printf '%s' "$REQ" | jq -e '
  type == "object"
  and (.attempt_id | type == "string" and length > 0)
  and (.generation | type == "number" and floor == . and . > 0)
  and (.bead_id | type == "string" and length > 0)
  and (.transition | type == "string")
  and (.expected_state | type == "string" and length > 0)
  and (.expected_source_hash | type == "string" and length == 64)
  and (.authority | type == "string" and length > 0)
  and (.agent | type == "string" and length > 0)
  and (.repo | type == "string" and length > 0)
' >/dev/null 2>&1 || { echo "tracker: invalid request envelope" >&2; exit 2; }

attempt=$(printf '%s' "$REQ" | jq -r '.attempt_id')
gen=$(printf '%s' "$REQ" | jq -r '.generation')
bead=$(printf '%s' "$REQ" | jq -r '.bead_id')
transition=$(printf '%s' "$REQ" | jq -r '.transition')
expected_state=$(printf '%s' "$REQ" | jq -r '.expected_state')
expected_hash=$(printf '%s' "$REQ" | jq -r '.expected_source_hash')
authority=$(printf '%s' "$REQ" | jq -r '.authority')
agent=$(printf '%s' "$REQ" | jq -r '.agent')
repo=$(printf '%s' "$REQ" | jq -r '.repo')
case "$expected_hash" in *[!0-9a-fA-F]*) echo "tracker: invalid source hash" >&2; exit 2 ;; esac
case "$transition" in
  claim) effect=claim ;;
  close|status) effect=tracker ;;
  *) echo "tracker: unknown transition $transition" >&2; exit 2 ;;
esac

attempt_file=$(attempt_path "$attempt")
[ -f "$attempt_file" ] || { echo "tracker: missing attempt $attempt" >&2; exit 2; }
jq -e --arg attempt "$attempt" --arg bead "$bead" --argjson gen "$gen" '
  .schema == "fm-attempt.v1"
  and .envelope.attempt_id == $attempt
  and .envelope.generation == $gen
  and .envelope.task_key == $bead
' "$attempt_file" >/dev/null 2>&1 || { echo "tracker: request does not match attempt envelope" >&2; exit 2; }

BR_BIN=$(command -v br 2>/dev/null) || { echo "tracker: br executable unavailable" >&2; exit 1; }
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE_DIR" || { echo "tracker: state directory unavailable" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-br-receipt.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

run_storage() {
  (cd "$repo" && PYTHONPATH=src .venv/bin/python "$repo/scripts/br_worktree_storage.py" "$@")
}

persist_observed() {
  if [ "${FM_ATTEMPT_LOCK_HELD:-0}" = 1 ]; then
    fm_attempt_effect_observe_held "$attempt" "$gen" "$effect" "$1"
  else
    fm_attempt_effect_observe "$attempt" "$gen" "$effect" "$1"
  fi
}

persist_pending() {
  if [ "${FM_ATTEMPT_LOCK_HELD:-0}" = 1 ]; then
    fm_attempt_effect_pending_held "$attempt" "$gen" "$effect" "$1"
  else
    fm_attempt_effect_pending "$attempt" "$gen" "$effect" "$1"
  fi
}

fail_effect() {
  echo "${effect}_pending: $*" >&2
  persist_pending "$(jq -n --arg reason "$*" --arg transition "$transition" --arg authority "$authority" \
    '{status:"pending",reason:$reason,transition:$transition,authority:$authority}')" \
    || echo "tracker: failed to record pending obligation for $attempt" >&2
  rm -f "$STATE_DIR/.tracker-pause"
  exit 1
}

read_live() {
  "$BR_BIN" show --json --no-auto-flush "$bead" > "$TMP/live.json" 2>/dev/null \
    || return 1
  jq -e --arg bead "$bead" \
    'type == "array" and length == 1 and .[0].id == $bead
     and (.[0].status | type == "string" and length > 0)' \
    "$TMP/live.json" >/dev/null 2>&1
}

live_status() {
  jq -r '.[0].status' "$TMP/live.json"
}

live_owner() {
  jq -r '.[0].assignee // .[0].owner // ""' "$TMP/live.json"
}

closure_comment_exists() {
  "$BR_BIN" comments list "$bead" --json 2>/dev/null \
    | jq -e --arg attempt "$attempt" '
        type == "array" and any(.[];
          ((.text // .comment // "") | startswith("Closure-Receipt:"))
          and ((.text // .comment // "") | endswith("attempt=" + $attempt)))
      ' >/dev/null 2>&1
}

post_state_valid() {
  local status owner
  status=$(live_status)
  owner=$(live_owner)
  case "$transition" in
    claim) [ "$status" = "$expected_state" ] && [ "$owner" = "$agent" ] ;;
    close) { [ "$status" = closed ] || [ "$status" = "done" ]; } && [ "$owner" = "$agent" ] && closure_comment_exists ;;
    status) [ "$status" = "$expected_state" ] && [ "$owner" = "$agent" ] ;;
  esac
}

commit_blob_hash() {
  git show "$1:.beads/issues.jsonl" 2>/dev/null | sha256sum | cut -d' ' -f1
}

existing_receipt_commit() {
  local evidence commit source_hash post_hash changed
  evidence=$(jq -c --arg effect "$effect" --argjson gen "$gen" --arg bead "$bead" '
    [.receipts[$effect][]?
      | select(.state == "observed" and .generation == $gen and .evidence.bead == $bead)]
    | if length == 1 then .[0].evidence else empty end
  ' "$attempt_file")
  [ -n "$evidence" ] || return 1
  commit=$(printf '%s' "$evidence" | jq -r '.commit // empty')
  source_hash=$(printf '%s' "$evidence" | jq -r '.source_hash // empty')
  post_hash=$(printf '%s' "$evidence" | jq -r '.post_hash // empty')
  [ -n "$commit" ] && [ -n "$source_hash" ] && [ -n "$post_hash" ] || return 1
  git merge-base --is-ancestor "$commit" origin/main 2>/dev/null || return 1
  [ "$(git show -s --format=%s "$commit")" = "tracker: $transition $bead attempt=$attempt" ] || return 1
  changed=$(git diff-tree --no-commit-id --name-only -r "$commit" 2>/dev/null)
  [ "$changed" = .beads/issues.jsonl ] || return 1
  [ "$(commit_blob_hash "$commit^")" = "$source_hash" ] || return 1
  [ "$(commit_blob_hash "$commit")" = "$post_hash" ] || return 1
  post_state_valid || return 1
  printf '%s\n' "$commit"
}

find_published_transition_commit() {
  local candidate parent_hash post_hash changed found=
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ "$(git show -s --format=%s "$candidate")" = "tracker: $transition $bead attempt=$attempt" ] || continue
    changed=$(git diff-tree --no-commit-id --name-only -r "$candidate" 2>/dev/null)
    [ "$changed" = .beads/issues.jsonl ] || continue
    parent_hash=$(commit_blob_hash "$candidate^") || continue
    [ "$parent_hash" = "$expected_hash" ] || continue
    post_hash=$(commit_blob_hash "$candidate") || continue
    [ -n "$post_hash" ] || continue
    [ -z "$found" ] || return 1
    found="$candidate"
  done <<EOF
$(git rev-list HEAD origin/main 2>/dev/null | LC_ALL=C sort -u)
EOF
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

publish_receipt() {
  local commit=$1 source_hash=$2 post_hash=$3 status bead_state recv
  bead_state=$(live_status)
  status=$bead_state
  [ "$transition" != claim ] || status=claimed
  recv=$(jq -n --arg bead "$bead" --arg status "$status" --arg bead_state "$bead_state" \
    --arg commit "$commit" --arg source_hash "$source_hash" --arg post_hash "$post_hash" \
    --arg authority "$authority" --arg agent "$agent" \
    '{bead:$bead,status:$status,bead_state:$bead_state,commit:$commit,source_hash:$source_hash,post_hash:$post_hash,authority:$authority,agent:$agent}')
  persist_observed "$recv" || fail_effect "receipt persist failed"
  rm -f "$STATE_DIR/.tracker-pause"
  echo "${effect}_receipt: $attempt $transition $bead $status $commit"
}

cd "$repo" 2>/dev/null || fail_effect "not the registered clone: $repo"
[ -d .beads ] || fail_effect "no .beads in $repo"
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ] || fail_effect "clone not on main"
git fetch origin >/dev/null 2>&1 || fail_effect "fetch failed"
if ! git merge-base --is-ancestor origin/main HEAD; then
  git merge --ff-only origin/main >/dev/null 2>&1 \
    || fail_effect "local main diverged from origin/main; refresh refused"
fi

run_storage verify-session --repo "$repo" --agent "$agent" >/dev/null 2>&1 \
  || fail_effect "verify-session failed"
run_storage preflight --repo "$repo" --status-out "$TMP/status-before.json" --br-bin "$BR_BIN" >/dev/null 2>&1 \
  || fail_effect "pre-mutation storage preflight failed"
pre_paths=$( { git diff --cached --name-only; git diff --name-only; } | LC_ALL=C sort -u)
actual_hash=$(sha256sum .beads/issues.jsonl 2>/dev/null | cut -d' ' -f1)
[ -n "$actual_hash" ] || fail_effect "tracker source unavailable"
read_live || fail_effect "live bead must be one array entry for $bead"
recovery_dirty=0
mutation_already_applied=0
receipt_source_hash=$actual_hash
if [ -n "$pre_paths" ]; then
  { [ "$pre_paths" = .beads/issues.jsonl ] \
      && [ "$(commit_blob_hash HEAD)" = "$expected_hash" ] \
      && { post_state_valid || { [ "$transition" = close ] && closure_comment_exists; }; }; } \
    || fail_effect "staged or unstaged paths present before mutation: $pre_paths"
  recovery_dirty=1
  receipt_source_hash=$expected_hash
  post_state_valid && mutation_already_applied=1
fi

observed_commit=$(existing_receipt_commit 2>/dev/null || true)
if [ -n "$observed_commit" ]; then
  rm -f "$STATE_DIR/.tracker-pause"
  echo "${effect}_receipt: $attempt $transition $bead already-observed $observed_commit"
  exit 0
fi

if [ "$actual_hash" != "$expected_hash" ] && [ "$recovery_dirty" = 0 ]; then
  replay_commit=$(find_published_transition_commit 2>/dev/null || true)
  if [ -n "$replay_commit" ] && post_state_valid; then
    if ! git merge-base --is-ancestor "$replay_commit" origin/main 2>/dev/null; then
      [ "$replay_commit" = "$(git rev-parse HEAD)" ] || fail_effect "local recovery commit is not HEAD"
      git push origin main >/dev/null 2>&1 || fail_effect "recovery push failed"
    fi
    replay_post_hash=$(commit_blob_hash "$replay_commit") || fail_effect "published commit evidence unreadable"
    publish_receipt "$replay_commit" "$expected_hash" "$replay_post_hash"
    exit 0
  fi
  fail_effect "source hash mismatch $actual_hash != $expected_hash"
fi

if [ "$mutation_already_applied" = 0 ]; then
  case "$transition" in
    claim)
      [ "$(live_status)" = "$expected_state" ] || fail_effect "live bead state mismatch before claim"
      [ -z "$(live_owner)" ] || fail_effect "live bead already owned before claim"
      ;;
    close)
      [ "$(live_status)" = "$expected_state" ] || fail_effect "live bead state mismatch before close"
      [ "$(live_owner)" = "$agent" ] || fail_effect "live bead owner mismatch before close"
      ;;
    status)
      [ "$(live_owner)" = "$agent" ] || fail_effect "live bead owner mismatch before status"
      ;;
  esac
fi

printf '%s\n' "attempt=$attempt transition=$transition started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$STATE_DIR/.tracker-pause" || fail_effect "tracker pause publication failed"

if [ "$mutation_already_applied" = 0 ]; then
  case "$transition" in
    claim)
      run_storage claim "$bead" --repo "$repo" --agent "$agent" --br-bin "$BR_BIN" >/dev/null 2>&1 \
        || fail_effect "claim refused"
      ;;
    close)
      if ! closure_comment_exists; then
        "$BR_BIN" comments add "$bead" -m "Closure-Receipt: landed $authority attempt=$attempt" >/dev/null 2>&1 \
          || fail_effect "closure receipt comment failed"
      fi
      closure_comment_exists || fail_effect "operative Closure-Receipt comment not verified"
      "$BR_BIN" close "$bead" >/dev/null 2>&1 || fail_effect "br close failed"
      ;;
    status)
      "$BR_BIN" update "$bead" --status "$expected_state" >/dev/null 2>&1 \
        || fail_effect "status transition refused"
      ;;
  esac
fi

read_live || fail_effect "authoritative bead re-read failed after mutation"
post_state_valid || fail_effect "authoritative bead state or owner mismatch after mutation"
run_storage preflight --repo "$repo" --status-out "$TMP/status-after.json" --br-bin "$BR_BIN" >/dev/null 2>&1 \
  || fail_effect "post-mutation storage preflight failed"
outside=$( { git diff --cached --name-only; git diff --name-only; } | LC_ALL=C sort -u | grep -v '^\.beads/issues\.jsonl$' || true)
[ -z "$outside" ] || fail_effect "staged or unstaged path outside .beads/issues.jsonl: $outside"
post_hash=$(sha256sum .beads/issues.jsonl | cut -d' ' -f1)
git add .beads/issues.jsonl
git commit -m "tracker: $transition $bead attempt=$attempt" -- .beads/issues.jsonl >/dev/null 2>&1 \
  || fail_effect "receipt-only commit failed"
commit=$(git rev-parse HEAD)
committed=$(commit_blob_hash "$commit") || fail_effect "committed blob unavailable"
[ "$committed" = "$post_hash" ] || fail_effect "committed blob hash mismatch"
git push origin main >/dev/null 2>&1 || fail_effect "push failed (pending obligation)"
publish_receipt "$commit" "$receipt_source_hash" "$post_hash"

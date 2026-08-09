#!/usr/bin/env bash
# Public-interface tests for the attended Decision OS tracker steward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-br-receipt)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
ORDER="$TMP_ROOT/order.log"
REMOTE="$TMP_ROOT/remote.git"
LIVE="$TMP_ROOT/live.json"
COMMENTS="$TMP_ROOT/comments.jsonl"
mkdir -p "$STATE" "$FAKEBIN"

export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

git init -q -b main "$PROJECT"
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name Test
git init -q --bare "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
mkdir -p "$PROJECT/.beads" "$PROJECT/scripts" "$PROJECT/.venv/bin"
printf '%s\n' '{"id":"fixture","status":"open"}' > "$PROJECT/.beads/issues.jsonl"
ln -s "$(command -v python3)" "$PROJECT/.venv/bin/python"

cat > "$PROJECT/scripts/br_worktree_storage.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["ORDER_FILE"], "a") as f:
    f.write("storage " + " ".join(args) + "\n")
command = args[0]
if command == "claim":
    if os.environ.get("STORAGE_CLAIM_EXIT", "0") != "0":
        raise SystemExit(int(os.environ["STORAGE_CLAIM_EXIT"]))
    bead = args[1]
    agent = args[args.index("--agent") + 1]
    with open(os.environ["LIVE_FILE"]) as f:
        live = json.load(f)
    live["id"] = bead
    live["assignee"] = agent
    with open(os.environ["LIVE_FILE"], "w") as f:
        json.dump(live, f)
    with open(os.environ["ISSUES_FILE"], "a") as f:
        f.write(json.dumps({"id": bead, "status": live["status"], "assignee": agent}) + "\n")
raise SystemExit(int(os.environ.get("STORAGE_EXIT", "0")))
PY
chmod +x "$PROJECT/scripts/br_worktree_storage.py"
git -C "$PROJECT" add .beads/issues.jsonl scripts/br_worktree_storage.py .venv/bin/python
git -C "$PROJECT" commit -q -m base
git -C "$PROJECT" push -q -u origin main

cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
set -u
printf 'br %s\n' "$*" >> "${ORDER_FILE:?}"
case "$1" in
  show)
    if [ "${BR_SHOW_SHAPE:-array}" = array ]; then
      jq -s '.' "${LIVE_FILE:?}"
    else
      cat "${LIVE_FILE:?}"
    fi
    ;;
  comments)
    case "$2" in
      list) jq -s '.' "${COMMENTS_FILE:?}" ;;
      add)
        message=${5:?}
        jq -n --arg text "$message" '{text:$text}' >> "${COMMENTS_FILE:?}"
        printf '%s\n' "{\"id\":\"$3\",\"comment\":$(jq -Rn --arg s "$message" '$s')}" >> "${ISSUES_FILE:?}"
        ;;
    esac
    ;;
  close)
    jq '.status="closed"' "${LIVE_FILE:?}" > "${LIVE_FILE:?}.tmp" && mv "${LIVE_FILE:?}.tmp" "${LIVE_FILE:?}"
    printf '%s\n' "{\"id\":\"$2\",\"status\":\"closed\"}" >> "${ISSUES_FILE:?}"
    ;;
  update)
    status=${4:?}
    jq --arg status "$status" '.status=$status' "${LIVE_FILE:?}" > "${LIVE_FILE:?}.tmp" && mv "${LIVE_FILE:?}.tmp" "${LIVE_FILE:?}"
    printf '%s\n' "{\"id\":\"$2\",\"status\":\"$status\"}" >> "${ISSUES_FILE:?}"
    ;;
esac
SH
chmod +x "$FAKEBIN/br"

set_live() {
  local bead=$1 status=$2 owner=${3:-}
  jq -n --arg id "$bead" --arg status "$status" --arg owner "$owner" \
    '{id:$id,status:$status,assignee:$owner}' > "$LIVE"
  : > "$COMMENTS"
  : > "$ORDER"
}

make_request() {
  local aid=$1 bead=$2 transition=$3 state=$4 file=$5
  jq -n --arg aid "$aid" --argjson gen "$(fm_attempt_generation "$aid")" \
    --arg bead "$bead" --arg transition "$transition" --arg state "$state" \
    --arg hash "$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)" \
    --arg repo "$PROJECT" \
    '{attempt_id:$aid,generation:$gen,bead_id:$bead,transition:$transition,expected_state:$state,expected_source_hash:$hash,evidence:"test",authority:"captain:test",agent:"pi-primary",repo:$repo}' \
    > "$file"
}

run_receipt() {
  PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" LIVE_FILE="$LIVE" COMMENTS_FILE="$COMMENTS" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" "$ROOT/bin/fm-br-receipt.sh" "$1" 2>&1
}

test_request_must_match_attempt_generation_and_bead() {
  local aid req out rc
  aid=$(fm_attempt_alloc pi receipt-envelope home) || fail "allocation"
  set_live another-bead open
  req="$TMP_ROOT/envelope.json"
  make_request "$aid" another-bead claim open "$req"
  out=$(run_receipt "$req"); rc=$?
  expect_code 2 "$rc" "mismatched request bead should refuse"
  make_request "$aid" receipt-envelope claim open "$req"
  jq '.generation += 1' "$req" > "$req.tmp" && mv "$req.tmp" "$req"
  out=$(run_receipt "$req"); rc=$?
  expect_code 2 "$rc" "mismatched request generation should refuse"
  [ ! -s "$ORDER" ] || fail "request mismatch reached a tracker owner"
  pass "request attempt, generation, and bead must match the immutable envelope"
}

test_claim_and_closure_use_separate_effects() {
  local claim close claim_req close_req out
  claim=$(fm_attempt_alloc pi receipt-claim home) || fail "claim allocation"
  set_live receipt-claim open
  claim_req="$TMP_ROOT/claim.json"
  make_request "$claim" receipt-claim claim open "$claim_req"
  out=$(run_receipt "$claim_req") || fail "claim receipt failed: $out"
  jq -e '.receipts.claim[0].state == "observed" and (.receipts.tracker // [] | length) == 0' \
    "$(attempt_path "$claim")" >/dev/null || fail "claim was not persisted under the claim effect"

  close=$(fm_attempt_alloc pi receipt-close home) || fail "close allocation"
  set_live receipt-close open pi-primary
  close_req="$TMP_ROOT/close.json"
  make_request "$close" receipt-close close open "$close_req"
  out=$(run_receipt "$close_req") || fail "close receipt failed: $out"
  jq -e '.receipts.tracker[0].state == "observed" and (.receipts.claim // [] | length) == 0' \
    "$(attempt_path "$close")" >/dev/null || fail "closure was not persisted under tracker"
  pass "claim and closure transitions persist separate claim and tracker effects"
}

test_preflight_refuses_before_tracker_mutation() {
  local aid req out rc
  aid=$(fm_attempt_alloc pi receipt-dirty home) || fail "allocation"
  set_live receipt-dirty open
  printf '%s\n' unrelated > "$PROJECT/unrelated.txt"
  git -C "$PROJECT" add unrelated.txt
  req="$TMP_ROOT/dirty.json"
  make_request "$aid" receipt-dirty claim open "$req"
  out=$(run_receipt "$req"); rc=$?
  expect_code 1 "$rc" "dirty preflight should refuse"
  assert_contains "$out" "before mutation" "dirty refusal did not name pre-mutation cleanliness"
  assert_no_grep 'storage claim ' "$ORDER" "claim mutation ran before path-set preflight"
  assert_no_grep 'br comments add' "$ORDER" "comment mutation ran before preflight"
  assert_no_grep 'br close' "$ORDER" "close mutation ran before preflight"
  assert_no_grep 'br update' "$ORDER" "status mutation ran before preflight"
  git -C "$PROJECT" reset -q -- unrelated.txt
  rm -f "$PROJECT/unrelated.txt"
  pass "branch, session, storage, and path preflight complete before tracker mutation"
}

test_real_array_show_contract_and_owner_validation() {
  local aid req out rc
  aid=$(fm_attempt_alloc pi receipt-array home) || fail "allocation"
  set_live receipt-array open
  req="$TMP_ROOT/array.json"
  make_request "$aid" receipt-array claim open "$req"
  out=$(run_receipt "$req") || fail "array-shaped show was refused: $out"
  assert_grep 'br show --json --no-auto-flush receipt-array' "$ORDER" \
    "live show did not use the non-flushing array interface"

  aid=$(fm_attempt_alloc pi receipt-object home) || fail "allocation"
  set_live receipt-object open
  req="$TMP_ROOT/object.json"
  make_request "$aid" receipt-object claim open "$req"
  out=$(BR_SHOW_SHAPE=object run_receipt "$req"); rc=$?
  expect_code 1 "$rc" "object-shaped show should refuse"
  assert_no_grep 'storage claim receipt-object ' "$ORDER" "mutation ran after malformed live show"
  pass "the steward accepts one real array entry and rejects malformed live bead identity"
}

test_claim_replay_uses_exact_published_commit() {
  local aid req out rc first_commit claim_count
  aid=$(fm_attempt_alloc pi receipt-replay home) || fail "allocation"
  set_live receipt-replay open
  req="$TMP_ROOT/replay.json"
  make_request "$aid" receipt-replay claim open "$req"
  fm_attempt_lock_acquire "$aid" || fail "attempt lock"
  out=$(run_receipt "$req"); rc=$?
  expect_code 1 "$rc" "receipt persistence crash fixture should fail"
  first_commit=$(git -C "$PROJECT" rev-parse HEAD)
  fm_attempt_lock_release "$aid"
  out=$(run_receipt "$req") || fail "published-commit replay failed: $out"
  claim_count=$(grep -c '^storage claim receipt-replay ' "$ORDER" 2>/dev/null || printf 0)
  [ "$claim_count" -eq 1 ] || fail "claim replay mutated $claim_count times"
  jq -e --arg commit "$first_commit" '
    [.receipts.claim[]? | select(.state == "observed" and .evidence.commit == $commit)] | length == 1
  ' "$(attempt_path "$aid")" >/dev/null || fail "replay did not bind the exact published commit"
  pass "claim replay reconciles live state with the exact already-published transition commit"
}

test_closure_replay_does_not_duplicate_exact_comment() {
  local aid req out rc adds
  aid=$(fm_attempt_alloc pi receipt-close-replay home) || fail "allocation"
  set_live receipt-close-replay open pi-primary
  req="$TMP_ROOT/close-replay.json"
  make_request "$aid" receipt-close-replay close open "$req"
  fm_attempt_lock_acquire "$aid" || fail "attempt lock"
  out=$(run_receipt "$req"); rc=$?
  expect_code 1 "$rc" "closure receipt persistence crash fixture should fail"
  fm_attempt_lock_release "$aid"
  out=$(run_receipt "$req") || fail "closure replay failed: $out"
  adds=$(grep -c '^br comments add receipt-close-replay ' "$ORDER" 2>/dev/null || printf 0)
  [ "$adds" -eq 1 ] || fail "exact Closure-Receipt comment was appended $adds times"
  pass "closure replay recognizes the existing exact attempt comment"
}

test_claim_refusal_is_pending_under_claim() {
  local aid req out rc
  aid=$(fm_attempt_alloc pi receipt-refused home) || fail "allocation"
  set_live receipt-refused open
  req="$TMP_ROOT/refused.json"
  make_request "$aid" receipt-refused claim open "$req"
  out=$(STORAGE_CLAIM_EXIT=1 run_receipt "$req"); rc=$?
  expect_code 1 "$rc" "refused claim should fail"
  jq -e '. as $record
    | ([.receipts.claim[]? | select(.state == "pending")] | length) == 1
      and (($record.receipts.tracker // []) | length) == 0' "$(attempt_path "$aid")" >/dev/null \
    || fail "refused claim pending evidence used the wrong effect"
  pass "claim persistence and pending obligations use the claim effect"
}

test_request_must_match_attempt_generation_and_bead
test_claim_and_closure_use_separate_effects
test_preflight_refuses_before_tracker_mutation
test_real_array_show_contract_and_owner_validation
test_claim_replay_uses_exact_published_commit
test_closure_replay_does_not_duplicate_exact_comment
test_claim_refusal_is_pending_under_claim

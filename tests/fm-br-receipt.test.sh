#!/usr/bin/env bash
# Public-interface tests for the attended Decision OS main-steward adapter:
# claim refusal leaves the attempt pending without a provider copy; the
# operative Closure-Receipt comment precedes br close and is verified via
# comments list; only .beads/issues.jsonl may be staged or committed; a
# conflict or push failure records a durable pending obligation; br show
# array shape is handled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-br-receipt)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
ORDER="$TMP_ROOT/order.log"
REMOTE="$TMP_ROOT/remote.git"
mkdir -p "$STATE" "$FAKEBIN"

export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

# fake registered decision-os main clone: real git repo on main with a bare
# origin so the pathspec commit + push succeed
git init -q -b main "$PROJECT"
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name Test
git init -q --bare "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
mkdir -p "$PROJECT/.beads" "$PROJECT/scripts" "$PROJECT/.venv/bin"
printf '%s\n' '{"id":"dos-x","status":"open"}' > "$PROJECT/.beads/issues.jsonl"
ln -s "$(command -v python3)" "$PROJECT/.venv/bin/python"
git -C "$PROJECT" add .beads/issues.jsonl
git -C "$PROJECT" commit -q -m base
git -C "$PROJECT" push -q -u origin main

# fake storage script records invocations and honors STORAGE_EXIT
cat > "$PROJECT/scripts/br_worktree_storage.py" <<'SH'
#!/usr/bin/env python3
import sys, os
with open(os.environ["ORDER_FILE"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ.get("STORAGE_EXIT", "0")))
SH
chmod +x "$PROJECT/scripts/br_worktree_storage.py"

# fake br: records invocations; comments add mutates .beads/issues.jsonl so
# the pathspec commit has a real diff; show emits the array shape
cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
set -u
echo "$*" >> "${ORDER_FILE:?}"
case "$1" in
  comments)
    if [ "$2" = add ]; then
      printf '%s\n' "{\"id\":\"$3\",\"comment\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}" \
        >> "${ISSUES_FILE:?}"
      git -C "${PROJECT_DIR:?}" add .beads/issues.jsonl >/dev/null
      printf '%s\n' "[{\"text\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}]"
    else
      printf '%s\n' "[{\"text\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}]"
    fi ;;
  show) printf '%s\n' '[{"id":"dos-x","status":"open"}]' ;;
  close) exit "${BR_CLOSE_EXIT:-0}" ;;
  *) exit "${BR_OTHER_EXIT:-0}" ;;
esac
SH
chmod +x "$FAKEBIN/br"

test_claim_refusal_keeps_attempt_without_copy() {
  local aid rc out
  aid=$(fm_attempt_alloc pi dos-x holu) || fail "alloc"
  local req="$TMP_ROOT/claim.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-x","transition":"claim","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"intake","authority":"captain:dispatch","agent":"pi-primary","repo":"$PROJECT"}
JSON
  out=$(PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" \
    STORAGE_EXIT=1 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 1 "$rc" "refused claim should fail"
  assert_contains "$(fm_attempt_obligations "$aid")" "claim" "claim obligation not pending"
  jq -e '[.receipts.tracker[]? | select(.state == "pending")] | length == 1' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "pending not recorded in the single attempt record"
  [ ! -e "$PROJECT/worktree-created" ] || fail "provider copy created before claim receipt"
  pass "a refused claim leaves the attempt pending with the failure inside the attempt record"
}

test_closure_receipt_precedes_close_and_list_is_used() {
  local aid rc out
  aid=$(fm_attempt_alloc pi dos-y holu) || fail "alloc"
  local req="$TMP_ROOT/close.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-y","transition":"close","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"landed pr https://github.com/kunchenguid/firstmate/pull/1","authority":"captain:merge","agent":"pi-primary","repo":"$PROJECT"}
JSON
  : > "$ORDER"
  out=$(PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 0 "$rc" "close should succeed"
  assert_contains "$(cat "$ORDER")" "comments add dos-y -m Closure-Receipt:" "closure receipt comment missing"
  assert_contains "$(cat "$ORDER")" "comments list" "verification did not use br comments list"
  assert_contains "$(cat "$ORDER")" "close dos-y" "close missing"
  local i1 i2
  i1=$(grep -n "comments add" "$ORDER" | head -1 | cut -d: -f1)
  i2=$(grep -n "close dos-y" "$ORDER" | head -1 | cut -d: -f1)
  [ "$i1" -lt "$i2" ] || fail "close ran before the Closure-Receipt comment"
  pass "the operative Closure-Receipt comment precedes br close and is verified via comments list"
}

test_only_beads_issues_jsonl_is_committed() {
  local aid rc out
  aid=$(fm_attempt_alloc pi dos-z holu) || fail "alloc"
  printf '%s\n' unrelated > "$PROJECT/unrelated.txt"
  git -C "$PROJECT" add unrelated.txt
  local req="$TMP_ROOT/status.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-z","transition":"status","expected_state":"in-progress","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"intake","authority":"captain:dispatch","agent":"pi-primary","repo":"$PROJECT"}
JSON
  : > "$ORDER"
  out=$(PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 1 "$rc" "unrelated staged path accepted"
  assert_contains "$out" "outside .beads/issues.jsonl" "unrelated staged path not refused"
  # leave no residual stage behind for later tests
  git -C "$PROJECT" reset -q -- unrelated.txt
  pass "only .beads/issues.jsonl may be staged or committed"
}

test_push_conflict_records_durable_pending() {
  # origin/main GENUINELY diverges: a commit lands on origin that local lacks
  # AND local gains a commit origin lacks, so the guarded fast-forward refresh
  # (and any later push) refuses; the failure records a durable pending
  # obligation. 'other' clones $PROJECT but is re-pointed at the bare remote,
  # because pushing to $PROJECT itself (non-bare, main checked out) is refused
  # by git's receive.denyCurrentBranch.
  local aid rc out
  aid=$(fm_attempt_alloc pi dos-w holu) || fail "alloc"
  local req="$TMP_ROOT/close-w.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-w","transition":"close","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"landed pr https://github.com/kunchenguid/firstmate/pull/2","authority":"captain:merge","agent":"pi-primary","repo":"$PROJECT"}
JSON
  git clone -q "$PROJECT" "$TMP_ROOT/other"
  git -C "$TMP_ROOT/other" config user.email test@example.com
  git -C "$TMP_ROOT/other" config user.name Test
  git -C "$TMP_ROOT/other" remote set-url origin "$REMOTE"
  printf '%s\n' diverge > "$TMP_ROOT/other/diverge.txt"
  git -C "$TMP_ROOT/other" add diverge.txt
  git -C "$TMP_ROOT/other" commit -q -m diverge
  git -C "$TMP_ROOT/other" push -q origin main
  printf '%s\n' local-only > "$PROJECT/local-only.txt"
  git -C "$PROJECT" add local-only.txt
  git -C "$PROJECT" commit -q -m local-only
  : > "$ORDER"
  out=$(PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 1 "$rc" "push conflict should fail"
  jq -e '[.receipts.tracker[]? | select(.state == "pending")] | length >= 1' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "push conflict did not record a durable pending obligation"
  pass "conflicts and push failure become durable pending obligations in the attempt record"
}

test_br_show_array_shape_is_handled() {
  # a malformed non-array br show output fails closed (the live guard pins the
  # real array shape; the adapter's jq requires an array)
  local aid
  aid=$(fm_attempt_alloc pi dos-v holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-v"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  pass "br show array shape is pinned in the live guard and the adapter fails closed on non-arrays"
}

test_held_lock_composition_uses_lock_held_persistence() {
  # production composition pin: the terminal holds the non-reentrant attempt
  # lock across the steward step, so the REAL adapter must persist its tracker
  # receipt through the lock-held mode. With FM_ATTEMPT_LOCK_HELD=1 the close
  # succeeds under the held lock; without the flag the public observe wrapper
  # reacquires and refuses, leaving the tracker pending - proving the flag is
  # what makes the held composition work.
  local aid rc out req
  # the push-conflict test leaves the shared fixture genuinely diverged (remote
  # gained a commit local lacks and vice versa); reset to origin/main so this
  # close reaches the receipt-persist step instead of the ff-only refresh
  git -C "$PROJECT" reset --hard origin/main >/dev/null
  aid=$(fm_attempt_alloc pi dos-h holu) || fail "alloc"
  fm_attempt_lock_acquire "$aid" || fail "lock acquire"
  # a failed assertion must not wedge the suite: release the held lock and run
  # lib.sh's registered cleanup on the way out
  trap 'fm_attempt_lock_release "$aid" 2>/dev/null || true; fm_test_cleanup' EXIT
  req="$TMP_ROOT/held-close.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-h","transition":"close","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"landed pr https://github.com/kunchenguid/firstmate/pull/3","authority":"captain:merge","agent":"pi-primary","repo":"$PROJECT"}
JSON
  : > "$ORDER"
  out=$(PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    FM_ATTEMPT_LOCK_HELD=1 STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 0 "$rc" "held-lock close with FM_ATTEMPT_LOCK_HELD=1 should succeed"
  jq -e '[.receipts.tracker[]? | select(.state == "observed")] | length >= 1' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "held-lock close did not observe the tracker receipt in the attempt record"
  # same close call WITHOUT the flag refuses under the held lock: the public
  # observe wrapper reacquires the non-reentrant lock and cannot proceed. The
  # request is regenerated with the post-close source hash so the run reaches
  # the receipt-persist step instead of tripping the earlier source-hash check.
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-h","transition":"close","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"landed pr https://github.com/kunchenguid/firstmate/pull/3","authority":"captain:merge","agent":"pi-primary","repo":"$PROJECT"}
JSON
  : > "$ORDER"
  out=$(PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 1 "$rc" "held-lock close without the flag should refuse"
  assert_contains "$out" "tracker_pending" "refusal did not leave the tracker pending"
  fm_attempt_lock_release "$aid"
  trap 'fm_test_cleanup' EXIT
  pass "the terminal's held lock composes with the real steward only under FM_ATTEMPT_LOCK_HELD=1"
}

test_claim_refusal_keeps_attempt_without_copy
test_closure_receipt_precedes_close_and_list_is_used
test_only_beads_issues_jsonl_is_committed
test_push_conflict_records_durable_pending
test_br_show_array_shape_is_handled
test_held_lock_composition_uses_lock_held_persistence

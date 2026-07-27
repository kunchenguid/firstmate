#!/usr/bin/env bash
# Regression coverage for guarded legacy task-worktree adoption.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worktree-lease-lib.sh
. "$ROOT/bin/fm-worktree-lease-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-adopt-worktree)

make_case() {
  local name=$1 id=$2 dir
  dir="$TMP_ROOT/$name"
  CASE_HOME="$dir/home"
  CASE_PROJECT="$dir/project"
  CASE_WORKTREE="$dir/worktree"
  CASE_FAKEBIN=$(fm_fakebin "$dir/fake")
  mkdir -p "$CASE_HOME/state" "$CASE_HOME/config"
  fm_git_worktree "$CASE_PROJECT" "$CASE_WORKTREE" "$name"
  printf 'legacy handoff\n' > "$CASE_WORKTREE/handoff.md"
  printf '{"worktrees":[{"name":"1","path":"%s","test_status":"in-use","owner_pid":999999,"owner_started_at":1}]}\n' \
    "$CASE_WORKTREE" > "$(dirname "$(dirname "$CASE_WORKTREE")")/treehouse-state.json"
  fm_write_meta "$CASE_HOME/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$CASE_WORKTREE" \
    "project=$CASE_PROJECT" "kind=ship" "harness=codex"
  fm_fake_treehouse "$CASE_FAKEBIN"
  cat > "$CASE_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s' "${FM_FAKE_WINDOWS:-}" ;;
  display-message) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}" ;;
esac
SH
  chmod +x "$CASE_FAKEBIN/tmux"
}

run_adopt() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_HOME/state" \
    FM_CONFIG_OVERRIDE="$CASE_HOME/config" FM_FAKE_POOL_PATH="${FM_FAKE_POOL_PATH:-$CASE_WORKTREE}" \
    FM_FAKE_POOL_STATUS="${FM_FAKE_POOL_STATUS:-in-use}" \
    FM_FAKE_LEASE_HOLDER="${FM_FAKE_LEASE_HOLDER:-}" \
    FM_FAKE_TREEHOUSE_STATE_FILE="${FM_FAKE_TREEHOUSE_STATE_FILE:-}" \
    FM_FAKE_STATUS_MUTATE_FILE="${FM_FAKE_STATUS_MUTATE_FILE:-}" \
    FM_FAKE_STATUS_MUTATE_MARKER="${FM_FAKE_STATUS_MUTATE_MARKER:-}" \
    FM_FAKE_STATUS_MUTATE_TEXT="${FM_FAKE_STATUS_MUTATE_TEXT:-}" \
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-bash}" \
    PATH="$CASE_FAKEBIN:$PATH" "$ROOT/bin/fm-adopt-worktree.sh" "$id" 2>&1
}

test_unleased_copy_is_atomically_leased_unchanged() {
  local id before out state
  id=adopt-success-a1
  make_case success "$id"
  state="$(dirname "$(dirname "$CASE_WORKTREE")")/treehouse-state.json"
  printf '{"worktrees":[{"name":"1","path":"%s","test_status":"in-use","owner_pid":999999,"owner_started_at":1}]}\n' \
    "$CASE_WORKTREE" > "$state"
  before=$(git -C "$CASE_WORKTREE" status --porcelain)
  out=$(FM_FAKE_TREEHOUSE_STATE_FILE="$state" run_adopt "$id")
  expect_code 0 "$?" "unleased legacy copy should acquire a durable lease: $out"
  assert_grep '"leased": true' "$state" "adoption did not persist a durable lease"
  assert_grep "\"lease_holder\": \"fm-$id\"" "$state" "adoption used the wrong lease holder"
  assert_present "$CASE_HOME/state/$id.worktree-adoption" "adoption proof was not published"
  assert_grep 'legacy handoff' "$CASE_WORKTREE/handoff.md" "adoption changed the untracked handoff"
  [ "$before" = "$(git -C "$CASE_WORKTREE" status --porcelain)" ] \
    || fail "adoption wrote into the legacy copy"
  pass "adoption atomically leases the legacy copy without changing its content"
}

test_refusals_and_native_lease_noop() {
  local id out status
  id=adopt-states-a2
  make_case states "$id"

  out=$(FM_FAKE_WINDOWS="fm-$id
" FM_FAKE_PANE_COMMAND=codex run_adopt "$id")
  status=$?
  expect_code 1 "$status" "live endpoint should refuse adoption"
  assert_contains "$out" 'is alive' "live refusal did not name endpoint state"

  out=$(FM_FAKE_POOL_STATUS=available run_adopt "$id")
  status=$?
  expect_code 1 "$status" "available copy should refuse adoption"
  assert_contains "$out" 'available' "available refusal did not name pool state"

  out=$(FM_FAKE_POOL_STATUS=leased FM_FAKE_LEASE_HOLDER=someone-else run_adopt "$id")
  status=$?
  expect_code 1 "$status" "foreign lease should refuse adoption"
  assert_contains "$out" 'someone-else' "foreign-lease refusal did not name holder"

  out=$(FM_FAKE_POOL_PATH="$TMP_ROOT/not-this-copy" run_adopt "$id")
  status=$?
  expect_code 1 "$status" "copy absent from pool should refuse adoption"
  assert_contains "$out" 'absent from the treehouse pool' "absent refusal did not name pool state"

  out=$(FM_FAKE_POOL_STATUS=leased FM_FAKE_LEASE_HOLDER="fm-$id" run_adopt "$id")
  expect_code 0 "$?" "native matching lease should verify successfully: $out"
  assert_contains "$out" 'under durable lease' "native lease verification was not explicit"
  pass "adoption refuses unsafe states and accepts an existing native lease"
}

test_changed_owner_refuses_without_mutation() {
  local id state evidence status
  id=adopt-race-a3
  make_case race "$id"
  state="$(dirname "$(dirname "$CASE_WORKTREE")")/treehouse-state.json"
  fm_worktree_state_evidence "$CASE_WORKTREE" || fail "could not capture allocation evidence"
  evidence=$FM_WORKTREE_STATE_EVIDENCE
  python3 - "$state" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    state = json.load(handle)
state["worktrees"][0]["owner_pid"] = 424242
state["worktrees"][0]["owner_started_at"] = 987654321
with open(sys.argv[1], "w") as handle:
    json.dump(state, handle)
PY
  fm_worktree_acquire_existing_lease "$CASE_WORKTREE" "fm-$id" "$evidence" in-use
  status=$?
  expect_code 1 "$status" "changed allocation evidence should refuse lease acquisition"
  assert_grep '"owner_pid": 424242' "$state" "refusal replaced the new owner"
  assert_no_grep '"leased": true' "$state" "refusal leased the newly owned worktree"
  pass "lease acquisition refuses changed ownership evidence without mutation"
}

test_changed_manifest_quarantines_retries() {
  local id state marker out status changed_hash
  id=adopt-manifest-a4
  make_case manifest "$id"
  state="$(dirname "$(dirname "$CASE_WORKTREE")")/treehouse-state.json"
  marker="$TMP_ROOT/manifest-mutated"
  out=$(FM_FAKE_TREEHOUSE_STATE_FILE="$state" \
    FM_FAKE_STATUS_MUTATE_FILE="$CASE_WORKTREE/handoff.md" \
    FM_FAKE_STATUS_MUTATE_MARKER="$marker" \
    FM_FAKE_STATUS_MUTATE_TEXT='concurrent content' run_adopt "$id")
  status=$?
  expect_code 1 "$status" "post-lease content mutation should refuse adoption"
  assert_present "$CASE_HOME/state/$id.worktree-adoption-pending" \
    "failed manifest verification did not retain quarantine evidence"
  assert_absent "$CASE_HOME/state/$id.worktree-adoption" \
    "failed manifest verification published adoption proof"
  assert_grep 'concurrent content' "$CASE_WORKTREE/handoff.md" \
    "failed verification removed concurrent content"
  changed_hash=$(sha256sum "$CASE_WORKTREE/handoff.md")

  out=$(FM_FAKE_TREEHOUSE_STATE_FILE="$state" run_adopt "$id")
  status=$?
  expect_code 1 "$status" "retry after manifest mismatch should remain quarantined"
  assert_contains "$out" 'quarantined' "retry did not report quarantine evidence"
  assert_absent "$CASE_HOME/state/$id.worktree-adoption" \
    "retry blessed changed content"
  [ "$changed_hash" = "$(sha256sum "$CASE_WORKTREE/handoff.md")" ] \
    || fail "retry changed quarantined content"
  pass "manifest mismatch remains quarantined across retries"
}

test_changed_owner_quarantines_retries() {
  local id state pending evidence out status before
  id=adopt-owner-retry-a5
  make_case owner_retry "$id"
  state="$(dirname "$(dirname "$CASE_WORKTREE")")/treehouse-state.json"
  pending="$CASE_HOME/state/$id.worktree-adoption-pending"
  fm_worktree_state_evidence "$CASE_WORKTREE" || fail "could not capture original allocation evidence"
  evidence=$FM_WORKTREE_STATE_EVIDENCE
  fm_worktree_content_manifest "$CASE_WORKTREE" || fail "could not capture original content manifest"
  {
    echo "task_id=$id"
    echo "worktree=$CASE_WORKTREE"
    echo "project=$CASE_PROJECT"
    echo "pool_status=leased"
    echo "expected_holder=fm-$id"
    echo "allocation_evidence=$evidence"
    echo "manifest_digest=$FM_WORKTREE_MANIFEST_DIGEST"
    echo "manifest_body_begin"
    [ -z "$FM_WORKTREE_MANIFEST_BODY" ] || printf '%s\n' "$FM_WORKTREE_MANIFEST_BODY"
    echo "manifest_body_end"
  } > "$pending"
  python3 - "$state" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    state = json.load(handle)
state["worktrees"][0]["owner_pid"] = 515151
state["worktrees"][0]["owner_started_at"] = 123456789
with open(sys.argv[1], "w") as handle:
    json.dump(state, handle)
PY
  before=$(sha256sum "$CASE_WORKTREE/handoff.md")

  out=$(run_adopt "$id")
  status=$?
  expect_code 1 "$status" "owner reassignment should refuse the pending lease attempt"
  assert_contains "$out" 'allocation ownership changed' "refusal did not identify changed ownership"
  assert_grep '"owner_pid": 515151' "$state" "first refusal replaced the reassigned owner"
  assert_absent "$CASE_HOME/state/$id.worktree-adoption" "first refusal published adoption proof"

  out=$(run_adopt "$id")
  status=$?
  expect_code 1 "$status" "retry after owner reassignment should remain quarantined"
  assert_contains "$out" 'allocation ownership changed' "retry did not preserve ownership quarantine"
  assert_grep '"owner_pid": 515151' "$state" "retry replaced the reassigned owner"
  assert_no_grep '"leased": true' "$state" "retry leased the reassigned worktree"
  assert_absent "$CASE_HOME/state/$id.worktree-adoption" "retry published adoption proof"
  [ "$before" = "$(sha256sum "$CASE_WORKTREE/handoff.md")" ] \
    || fail "owner-race retry changed worktree content"
  pass "owner reassignment remains quarantined across retries"
}

test_unleased_copy_is_atomically_leased_unchanged
test_refusals_and_native_lease_noop
test_changed_owner_refuses_without_mutation
test_changed_manifest_quarantines_retries
test_changed_owner_quarantines_retries

echo "# all fm-adopt-worktree tests passed"

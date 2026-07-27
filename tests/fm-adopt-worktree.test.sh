#!/usr/bin/env bash
# Regression coverage for guarded legacy task-worktree adoption.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
    FM_FAKE_WINDOWS="${FM_FAKE_WINDOWS:-}" FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-bash}" \
    PATH="$CASE_FAKEBIN:$PATH" "$ROOT/bin/fm-adopt-worktree.sh" "$id" 2>&1
}

test_unleased_copy_refuses_unchanged() {
  local id before out status
  id=adopt-success-a1
  make_case success "$id"
  before=$(git -C "$CASE_WORKTREE" status --porcelain)
  out=$(run_adopt "$id")
  status=$?
  expect_code 1 "$status" "unleased legacy copy should refuse adoption"
  assert_contains "$out" 'not a durable' "unleased refusal did not require a durable task lease"
  assert_grep 'legacy handoff' "$CASE_WORKTREE/handoff.md" "refusal changed the untracked handoff"
  [ "$before" = "$(git -C "$CASE_WORKTREE" status --porcelain)" ] \
    || fail "refusal wrote into the legacy copy"
  pass "unleased adoption refuses without changing the legacy copy"
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
  assert_contains "$out" 'durably leased' "native lease verification was not explicit"
  pass "adoption refuses unsafe states and accepts an existing native lease"
}

test_unleased_copy_refuses_unchanged
test_refusals_and_native_lease_noop

echo "# all fm-adopt-worktree tests passed"

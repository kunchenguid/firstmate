#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get wait budget (bin/fm-spawn.sh,
# the FM_TREEHOUSE_READY_POLLS/FM_TREEHOUSE_POLL_INTERVAL loop after
# `treehouse get`).
#
# Pins three behaviors:
# 1. The wait budget is honored and overridable - a pane that never enters a
#    worktree fails after the configured poll count, not a hard-coded 60.
# 2. A genuinely full worktree pool fails fast - `treehouse get` prints its
#    exhaustion reason verbatim to the pane, and no timeout value can fix that,
#    so the spawn must name that reason instead of burning the whole budget.
# 3. The worktree-isolation assertion still runs and still refuses a spawn whose
#    pane entered something other than a real, distinct isolated worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="/tmp/fm-spawn-base-test.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-budget)

# make_budget_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query always returns FM_FAKE_PANE_PATH, and whose capture-pane prints
# FM_FAKE_PANE_TEXT when set - so a case can hold the pane at the project
# forever while optionally making the pane's visible output say why.
make_budget_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  capture-pane)
    [ -n "${FM_FAKE_PANE_TEXT:-}" ] && printf '%s\n' "$FM_FAKE_PANE_TEXT"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_budget_case <name> <id> builds a home and a primary project the same way
# the settle-loop regression does; the caller chooses what the fake pane reports.
make_budget_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_budget_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_budget_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR _WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_budget_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="${FAKE_PANE_PATH:-$PROJ_DIR}" \
    FM_FAKE_PANE_TEXT="${FAKE_PANE_TEXT:-}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A pane that never leaves the project must fail after the OVERRIDDEN budget,
# not a hard-coded 60 polls: three zero-interval polls fail in seconds, and the
# timeout message names both possible causes and where the real one is printed.
test_budget_override_is_honored_and_message_names_both_causes() {
  local rec id out status start end elapsed
  id=budget-override-z1
  rec=$(make_budget_case budget-override "$id")
  read_budget_record "$rec"

  start=$(date +%s)
  out=$(FM_TREEHOUSE_READY_POLLS=3 FM_TREEHOUSE_POLL_INTERVAL=0 run_budget_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 1 "$status" "a never-settling pane must fail the spawn"
  assert_contains "$out" "wait budget (3 polls at 0s each)" \
    "timeout message did not reflect the overridden poll budget"
  assert_contains "$out" "pool is exhausted or worktree creation is still running" \
    "timeout message did not name both possible causes"
  assert_contains "$out" "read window" \
    "timeout message did not point at the window holding the real cause"
  [ "$elapsed" -le 10 ] || fail "overridden 3-poll budget took ${elapsed}s to exhaust"
  pass "the overridden wait budget is honored and the timeout names both causes"
}

# When the pool is genuinely exhausted, `treehouse get` says so verbatim on the
# pane. The spawn must fail fast naming that reason even with the full default
# budget available - waiting it out would only delay an answer no timeout fixes.
test_pool_exhaustion_fails_fast_naming_the_reason() {
  local rec id out status start end elapsed
  id=budget-pool-full-z2
  rec=$(make_budget_case budget-pool-full "$id")
  read_budget_record "$rec"

  start=$(date +%s)
  out=$(FAKE_PANE_TEXT='all 16 worktrees are in use or dirty (max_trees = 16). Run '"'"'treehouse status'"'"' to see details, or increase max_trees in treehouse.toml' \
    FM_TREEHOUSE_READY_POLLS=300 FM_TREEHOUSE_POLL_INTERVAL=1 \
    run_budget_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 1 "$status" "an exhausted pool must fail the spawn"
  assert_contains "$out" "pool is exhausted" \
    "pool-exhaustion failure did not name the reason treehouse printed"
  assert_not_contains "$out" "did not enter a worktree within its wait budget" \
    "pool exhaustion burned the whole budget instead of failing fast"
  [ "$elapsed" -le 5 ] || fail "pool exhaustion took ${elapsed}s to detect - not a fast fail"
  pass "an exhausted pool fails fast naming treehouse's own reason"
}

# The settle loop accepting a path is necessary but not sufficient: a pane that
# settles into a directory that is NOT a real distinct git worktree must still be
# refused by validate_spawn_worktree before any launch.
test_isolation_assertion_still_refuses_a_non_worktree_path() {
  local rec id out status impostor
  id=budget-isolation-z3
  rec=$(make_budget_case budget-isolation "$id")
  read_budget_record "$rec"
  impostor="$TMP_ROOT/budget-isolation/not-a-worktree"
  mkdir -p "$impostor"

  out=$(FAKE_PANE_PATH="$impostor" \
    FM_TREEHOUSE_READY_POLLS=10 FM_TREEHOUSE_POLL_INTERVAL=0 \
    run_budget_spawn "$id")
  status=$?
  expect_code 1 "$status" "a non-worktree destination must be refused"
  assert_contains "$out" "did not yield an isolated worktree" \
    "isolation assertion did not refuse a spawn into a non-worktree path"
  if [ -f "$HOME_DIR/state/$id.meta" ]; then
    assert_not_contains "$(cat "$HOME_DIR/state/$id.meta")" "worktree=" \
      "meta recorded a worktree despite the isolation refusal"
  fi
  pass "the isolation assertion still refuses a spawn that did not enter a real distinct worktree"
}

test_budget_override_is_honored_and_message_names_both_causes
test_pool_exhaustion_fails_fast_naming_the_reason
test_isolation_assertion_still_refuses_a_non_worktree_path

echo "# all fm-spawn-worktree-budget tests passed"

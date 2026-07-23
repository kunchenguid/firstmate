#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection loop
# (bin/fm-spawn.sh, the `for _ in $(seq 1 "$WT_TIMEOUT")` loop after
# `treehouse get`), covering both how it settles on a worktree and how long it
# is willing to wait for one.
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
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
  # With FM_FAKE_INSTANT_SLEEP=1 this collapses the loop's inter-poll sleep, so a
  # whole wait budget's worth of polls runs in milliseconds. Unset, it defers to
  # the real sleep so the timing assertion below stays honest.
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_INSTANT_SLEEP:-0}" = 1 ] && exit 0
for d in /bin /usr/bin; do
  [ -x "$d/sleep" ] && exec "$d/sleep" "$@"
done
exit 0
SH
  chmod +x "$fakebin/sleep"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# pane_reads echoes how many times the fake tmux was asked for the pane's cwd,
# i.e. how many times the wait loop polled before giving up or settling.
pane_reads() {
  local n=0
  [ -f "$COUNTFILE" ] && n=$(cat "$COUNTFILE")
  printf '%s\n' "$n"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read still only
# costs the loop's existing one-second inter-poll sleep to confirm - not an
# extra full cycle on top of that.
test_already_settled_pane_costs_one_confirm_sleep() {
  local rec id out status start end elapsed
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  start=$(date +%s)
  out=$(run_settle_spawn "$id")
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  [ "$elapsed" -le 5 ] || fail "already-settled pane took ${elapsed}s to confirm - expected close to the single inter-poll sleep"
  pass "an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle"
}

# --- wait budget (FM_SPAWN_WORKTREE_TIMEOUT) --------------------------------
#
# A pane that never leaves the project directory models `treehouse get` still
# provisioning a first-ever worktree: every read equals the project, so the loop
# polls its whole budget and then refuses. Pointing the fake's "stale" path at
# the project itself and asking for effectively unlimited stale reads produces
# exactly that, and the poll counter reports the budget actually in effect.
run_never_settles_spawn() {
  local id=$1
  STALE_DIR=$PROJ_DIR
  STALE_READS=999999
  FM_FAKE_INSTANT_SLEEP=1 run_settle_spawn "$id"
}

# Unset - and, like the fleet's other numeric knobs, blank - the budget must stay
# exactly what it has always been: 60 one-second polls, reported as 60s.
test_default_budget_is_sixty_seconds() {
  local rec id out status
  id=settle-budget-default-z3
  rec=$(make_settle_case settle-budget-default "$id" 0)
  read_settle_record "$rec"

  out=$(run_never_settles_spawn "$id")
  status=$?
  expect_code 1 "$status" "spawn should refuse when the pane never enters a worktree"
  assert_contains "$out" "did not enter a worktree within 60s" \
    "timeout error did not report the default 60s budget"
  [ "$(pane_reads)" = 60 ] || fail "default budget polled $(pane_reads) times, expected 60"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not record task metadata"

  id=settle-budget-blank-z3b
  rec=$(make_settle_case settle-budget-blank "$id" 0)
  read_settle_record "$rec"

  out=$(FM_SPAWN_WORKTREE_TIMEOUT='' run_never_settles_spawn "$id")
  status=$?
  expect_code 1 "$status" "a blank budget should behave like an unset one, not refuse"
  assert_contains "$out" "did not enter a worktree within 60s" \
    "a blank FM_SPAWN_WORKTREE_TIMEOUT did not fall back to the 60s default"
  [ "$(pane_reads)" = 60 ] || fail "blank budget polled $(pane_reads) times, expected 60"
  pass "the wait budget defaults to 60 one-second polls when FM_SPAWN_WORKTREE_TIMEOUT is unset or blank"
}

# Set, the budget replaces the default in both the loop and the message, and the
# message names the override so the operator knows which knob to raise.
test_budget_override_is_honored_and_reported() {
  local rec id out status
  id=settle-budget-short-z4
  rec=$(make_settle_case settle-budget-short "$id" 0)
  read_settle_record "$rec"

  out=$(FM_SPAWN_WORKTREE_TIMEOUT=3 run_never_settles_spawn "$id")
  status=$?
  expect_code 1 "$status" "spawn should still refuse when the shortened budget expires"
  assert_contains "$out" "did not enter a worktree within 3s" \
    "timeout error did not report the budget actually in effect"
  assert_contains "$out" "FM_SPAWN_WORKTREE_TIMEOUT" \
    "timeout error did not name the override that raises the budget"
  [ "$(pane_reads)" = 3 ] || fail "overridden budget polled $(pane_reads) times, expected 3"
  pass "FM_SPAWN_WORKTREE_TIMEOUT replaces the default in both the loop and the timeout message"
}

# The reported incident: a first-ever `treehouse get` that keeps the pane in the
# project past 60s and only then lands in the worktree. A raised budget must
# carry it through to a recorded worktree instead of aborting.
test_raised_budget_survives_a_slow_first_worktree() {
  local rec id out status
  id=settle-budget-slow-z5
  rec=$(make_settle_case settle-budget-slow "$id" 70)
  read_settle_record "$rec"
  STALE_DIR=$PROJ_DIR

  out=$(FM_SPAWN_WORKTREE_TIMEOUT=120 FM_FAKE_INSTANT_SLEEP=1 run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "a raised budget should outlast a slow first-ever treehouse get"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree the slow treehouse get eventually entered"
  [ "$(pane_reads)" -gt 60 ] || \
    fail "spawn settled after only $(pane_reads) polls, so it never passed the old 60-poll ceiling"
  pass "a raised FM_SPAWN_WORKTREE_TIMEOUT carries a slow first-ever treehouse get to a recorded worktree"
}

# An unusable budget is refused by name and by value, before any window exists -
# never silently reset to the default and never left to poll forever.
test_invalid_budget_is_refused_before_spawning() {
  local rec id bad out status n=0
  for bad in abc 0 -5 '3s' 6.5; do
    n=$((n + 1))
    id="settle-budget-invalid-$n-z6"
    rec=$(make_settle_case "settle-budget-invalid-$n" "$id" 0)
    read_settle_record "$rec"

    out=$(FM_SPAWN_WORKTREE_TIMEOUT="$bad" run_settle_spawn "$id")
    status=$?
    expect_code 1 "$status" "spawn should refuse FM_SPAWN_WORKTREE_TIMEOUT='$bad'"
    assert_contains "$out" "FM_SPAWN_WORKTREE_TIMEOUT must be a positive whole number of seconds (got '$bad')" \
      "refusal did not name the offending FM_SPAWN_WORKTREE_TIMEOUT value '$bad'"
    assert_absent "$HOME_DIR/state/$id.meta" \
      "a refused budget must not leave task metadata behind for '$bad'"
    [ "$(pane_reads)" = 0 ] || \
      fail "spawn polled the pane $(pane_reads) times before refusing '$bad', expected 0"
  done
  pass "a non-numeric, fractional, zero, or negative FM_SPAWN_WORKTREE_TIMEOUT is refused by value before any window is created"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_sleep
test_default_budget_is_sixty_seconds
test_budget_override_is_honored_and_reported
test_raised_budget_survives_a_slow_first_worktree
test_invalid_budget_is_refused_before_spawning

echo "# all fm-spawn-worktree-settle tests passed"

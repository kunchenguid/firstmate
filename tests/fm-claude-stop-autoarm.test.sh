#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh, docs/watcher-continuity.md).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it hermetically
# as a child of a fake harness (a bash symlink named "claude") whose pid is
# written into the fixture home's state/.lock for ordinary owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so no
# real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-autoarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. Any extra env assignments must be exported
# before invocation. Captures stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 rc=0
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  case "$kind" in
    actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    failed)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    benign-live)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    slow-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 2
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: slow fixture\n'
exit 0
SH
      ;;
    meta-vanishes)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/.afk"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$dir
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# --- registration contract ----------------------------------------------------

# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # No state/.lock: run the hook directly (no fake harness, no lock file).
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "auto-arm: inert with no session lock"
}

test_reclaims_stale_session_lock_before_arming() {
  local dir out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 2 "$status" "a dead recorded session owner must be reclaimed before the actionable rewake"
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  [ "$actual_owner" = "$expected_owner" ] || fail "stale session lock was not claimed by the current harness: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the stale session lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale-lock recovery must record outcome=rewake"
  pass "auto-arm: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before arming"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other out status owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "hook must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch while another session owned the lock"
  pass "auto-arm: inert without arm, rewake, or lock replacement when another live harness owns the home"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "AFK without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "AFK without positive recovery reset the attended alarm"
  pass "auto-arm: inert while AFK owns supervision"
}

test_stale_lock_recovery_preserves_afk_and_need_gates() {
  local afk_dir idle_dir out status
  afk_dir=$(make_primary_dir "$TMP_ROOT/stale-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  printf '9999999\n' > "$afk_dir/state/.lock"
  write_arm_fixture "$afk_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-afk"}' | FM_HOME="$afk_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the AFK gate"
  [ "$(cat "$afk_dir/state/.lock")" = 9999999 ] || fail "AFK stale lock was reclaimed despite away ownership"
  [ ! -e "$afk_dir/state/arm-ran" ] || fail "stale AFK home armed"

  idle_dir=$(make_primary_dir "$TMP_ROOT/stale-idle")
  printf '9999999\n' > "$idle_dir/state/.lock"
  write_arm_fixture "$idle_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-idle"}' | FM_HOME="$idle_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the supervision-need gate"
  [ "$(cat "$idle_dir/state/.lock")" = 9999999 ] || fail "idle stale lock was reclaimed without supervision need"
  [ ! -e "$idle_dir/state/arm-ran" ] || fail "stale idle home armed"
  pass "auto-arm: stale-owner recovery leaves the AFK and supervision-need gates unchanged"
}

test_resolves_outermost_claude_pid_in_nested_bgspare_chain() {
  local dir out status inner_pid lock_pid
  dir=$(make_primary_dir "$TMP_ROOT/nested-chain")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # A genuine multi-level contiguous claude-named ancestry: the hook fires
  # inside an inner fake-claude process (its recorded pid is distinct from its
  # own parent, a second, outer fake-claude process holding the session lock -
  # the bg-spare shape). Only the outer pid may own the lock; a
  # first-match-wins walk would resolve to the inner pid instead and leave the
  # hook inert. The inner process records its own pid before running the hook
  # so bash cannot tail-exec-collapse it into the outer pid, which would
  # collapse the two-hop chain this test depends on down to one hop.
  out=$(printf '%s\n' '{"session_id":"nested"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FAKE_CLAUDE" -c "
          printf \"%s\n\" \"\$\$\" > \"\$FM_HOME/state/inner-pid\"
          \"\$FM_HOME/bin/fm-claude-stop-autoarm.sh\"
        "
      ' 2>&1); status=$?
  inner_pid=$(cat "$dir/state/inner-pid" 2>/dev/null || true)
  lock_pid=$(cat "$dir/state/.lock" 2>/dev/null || true)
  [ -n "$inner_pid" ] && [ "$inner_pid" != "$lock_pid" ] \
    || fail "test setup did not produce a genuine two-hop claude chain: inner=$inner_pid lock=$lock_pid"
  expect_code 2 "$status" "a nested contiguous claude ancestry must resolve to the outer lock-owning pid and arm"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not resolve past the inner claude-named process to the outer lock owner"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "nested-chain arm must record outcome=rewake"
  pass "auto-arm: resolves the outermost pid of a nested contiguous claude ancestry (bg-spare chain)"
}

test_inert_when_fleet_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "idle state without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "idle state without positive recovery reset the attended alarm"
  pass "auto-arm: inert with nothing in flight and no X-mode need"
}

# --- the armed cycle ----------------------------------------------------------

test_actionable_close_rewakes_with_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable arm close must exit 2 so Claude rewakes"
  assert_contains "$out" "firstmate watcher wake" "rewake must carry the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "rewake must carry the arm's reason line"
  assert_contains "$out" "bin/fm-wake-drain.sh" "rewake must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "rewake must forbid a duplicate model re-arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the cycle"
  [ -e "$dir/state/arm-ran" ] || fail "hook never foregrounded the arm wrapper"
  pass "auto-arm: actionable close translates to exactly one exit-2 rewake with reason"
}

test_actionable_close_with_live_successor_rewakes_once() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/actionable-live-successor")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live successor for actionable close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  write_arm_fixture "$dir" benign-live
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?

  expect_code 2 "$status" "an actionable close must rewake when a live successor already exists"
  expect_code 0 "$status2" "a repeated non-actionable close with the live successor must stay quiet"
  [ "$(printf '%s\n' "$out" | grep -c '^firstmate watcher wake')" -eq 1 ] \
    || fail "actionable close with a live successor did not emit exactly one wake banner: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^stale: fixture-win actionable')" -eq 1 ] \
    || fail "actionable close with a live successor did not surface its reason exactly once: $out"
  [ -z "$out2" ] || fail "repeated hook duplicated the delivered actionable result: $out2"
  kill -0 "$pid" 2>/dev/null || fail "actionable delivery stopped or replaced the live successor"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "the later benign close must record outcome=clean"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "auto-arm: actionable close survives a healthy successor without duplicate delivery"
}

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "automatic supervision mechanism is broken" "failure rewake must describe the automatic mechanism failure"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "failure rewake must not create a manual arm loop"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "failure must exhaust exactly two bounded arm attempts"
  pass "auto-arm: bounded failure verification emits one automatic-mechanism alarm"
}

test_failed_cycles_notify_once_and_keep_retrying() {
  local dir out1 out2 status1 status2
  dir=$(make_primary_dir "$TMP_ROOT/failed-dedup")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out1=$(run_autoarm "$dir" 2>/dev/null); status1=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  expect_code 2 "$status1" "the first exhausted failure must notify"
  expect_code 2 "$status2" "a consecutive exhausted failure must force another Stop-owned retry"
  [ -n "$out1" ] || fail "the first exhausted failure did not notify"
  [ -z "$out2" ] || fail "consecutive exhausted failure repeated an operator notice: $out2"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 4 ] || fail "each cycle must retain bounded automatic retries"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "failure episode marker was not recorded"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "second failure must record failed-suppressed"
  pass "auto-arm: consecutive failures keep Stop-owned retry without repeating notice"
}

test_unverified_clean_close_exhausts_retries() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a non-actionable close without a healthy watcher must fail closed"
  assert_contains "$out" "automatic supervision mechanism is broken" "unverified close must report automatic failure"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "unverified close must exhaust exactly two bounded attempts"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  pass "auto-arm: unverified clean close exhausts retries and fails closed"
}

test_post_alarm_actionable_close_is_suppressed() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/post-alarm-actionable")
  : > "$dir/state/task.meta"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable result after attended fail-open must not continue"
  [ -z "$out" ] || fail "post-alarm actionable result produced continuation output: $out"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "post-alarm actionable result cleared the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "post-alarm actionable result cleared the attended alarm"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "post-alarm actionable result must record failed-suppressed"
  pass "auto-arm: post-alarm actionable outcomes cannot continue or reset failure state"
}

test_benign_cycle_end_with_live_watcher_is_silent() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/benign-live")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for benign close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a failed-looking cycle with a live fresh watcher must be benign"
  expect_code 0 "$status2" "the next Stop-owned cycle must remain benign with the live watcher"
  [ -z "$out" ] || fail "benign live cycle produced an operator notice: $out"
  [ -z "$out2" ] || fail "next benign live cycle produced an operator notice: $out2"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "benign live cycle must record outcome=clean, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "the next Stop-owned cycle must run its own bounded arm"
  [ ! -e "$dir/state/.turnend-claude-blocks" ] || fail "benign live cycle must clear the prior block budget"
  [ ! -e "$dir/state/.claude-autoarm-failure-notified" ] || fail "benign live cycle must not leave a failure-notice marker"
  [ ! -e "$dir/state/.claude-autoarm-failure-alarmed" ] || fail "benign live cycle must not leave an attended-alarm marker"
  pass "auto-arm: benign cycle end with a live watcher and fresh beacon stays silent across the next cycle"
}

test_positive_recovery_budget_contention_preserves_episode() {
  local dir out status pid identity holder
  dir=$(make_primary_dir "$TMP_ROOT/recovery-budget-contention")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for recovery contention"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.turnend-claude-blocks.lock"
  printf '%s\n' "$holder" > "$dir/state/.turnend-claude-blocks.lock/pid"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a healthy auto-arm must continue when the episode reset lock is busy"
  [ -z "$out" ] || fail "recovery contention produced an operator notice: $out"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "recovery contention must not record ordinary clean recovery"
  assert_present "$dir/state/.turnend-claude-blocks" "recovery contention partially cleared the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "recovery contention partially cleared the failure notice"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a later healthy auto-arm must complete the episode reset"
  assert_absent "$dir/state/.turnend-claude-blocks" "successful retry left the block budget"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "successful retry left the failure notice"
  pass "auto-arm: budget contention preserves the episode and forces a reset retry"
}

test_arms_for_x_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/x-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/x-watch.check.sh"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an X-mode relay poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the X-mode poll need"
  pass "auto-arm: X-mode poll need arms the cycle even with no tasks in flight"
}

test_single_flight_admits_exactly_one_owner() {
  local dir rc1 rc2 count
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err1" &
    p1=$!
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    wait "$p1"; echo $? > "$FM_HOME/state/rc1"
    wait "$p2"; echo $? > "$FM_HOME/state/rc2"
  '
  rc1=$(cat "$dir/state/rc1")
  rc2=$(cat "$dir/state/rc2")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent firings must foreground exactly one arm, saw $count"
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "exactly one firing must translate the close (rc 2) and the other must no-op (rc 0), got rc1=$rc1 rc2=$rc2"
  pass "auto-arm: concurrent firings admit one owner and one rewake translation"
}

# --- abandoned single-flight claim recovery -----------------------------------
# The 2026-08-14 lapse: one cycle armed, beat its beacon, delivered a single
# rewake, and exited, leaving its owner lock behind with a live pid. The single
# flight gate then turned every later firing into exit 0, so with two tasks in
# flight and a beacon 40 minutes cold nothing re-armed and both workers' reports
# sat unread until an operator drained the queue by hand. The lock alone is not
# enough to prove that: the ledger naming that same pid with a finished outcome,
# or a recorded pid-identity the live pid no longer matches, is what distinguishes
# an abandoned claim from one still deciding.

# Fabricate a held owner lock: <dir> <pid> <role>. Plain-dir shape on purpose -
# the hook must reclaim whatever a crashed or blocked owner left behind.
record_autoarm_owner() {
  local dir=$1 pid=$2 role=${3:-autoarm}
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$pid" > "$dir/state/.claude-autoarm.lock/pid"
  printf '%s\n' "$role" > "$dir/state/.claude-autoarm.lock/role"
}

# Record the pid-identity a claim leaves inside its own lock: <dir> <pid>. The
# claim writes the identity of the process that took the lock, so passing a pid
# OTHER than the lock's own reproduces pid reuse - the recorded claimant is gone
# and an unrelated live process now answers to its number.
record_autoarm_owner_identity() {
  local dir=$1 pid=$2 identity
  identity=$(fm_test_pid_identity "$pid") || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" > "$dir/state/.claude-autoarm.lock/pid-identity"
}

# <dir> <epoch-seq> <owner-pid> <outcome>, aged well past any freshness window.
record_autoarm_epoch() {
  local dir=$1 seq=$2 owner=$3 outcome=$4
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=1\n' "$seq" "$owner" "$outcome" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
}

epoch_field() {
  local dir=$1 field=$2
  sed -n "s/^.*[[:space:]]\{0,1\}$field=\([A-Za-z0-9_-]*\).*\$/\1/p" \
    "$dir/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_abandoned_owner_claim_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/abandoned-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_epoch "$dir" 464 "$pid" rewake
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a claim whose ledger outcome is already terminal must be reclaimed, not deferred to forever"
  [ -e "$dir/state/arm-ran" ] || fail "abandoned claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "reclaimed cycle did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "reclaimed cycle did not record its own outcome: $(epoch_outcome "$dir")"
  [ "$(epoch_field "$dir" owner_pid)" != "$pid" ] || fail "reclaimed ledger still names the abandoned owner"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "reclaim left its serialization mutex behind"
  pass "auto-arm: an abandoned owner claim is reclaimed so a lapsed cycle re-arms"
}

test_arming_claim_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/arming-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # An owner foregrounds the arm for the whole watcher cycle, so "arming" is in
  # progress no matter how old its ledger entry is.
  record_autoarm_epoch "$dir" 464 "$pid" arming
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a claim still arming must keep the single-flight gate closed"
  [ -z "$out" ] || fail "deferring to an arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an arming claim was stolen and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the arming ledger entry"
  assert_present "$dir/state/.claude-autoarm.lock" "an arming claim lost its owner lock"
  pass "auto-arm: an owner still arming is never reclaimed, however long the cycle runs"
}

test_claim_not_named_by_the_ledger_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/unnamed-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # A fresh claimant holds the lock before it writes "arming", so until it does
  # the ledger still names the PREVIOUS owner. Requiring the two pids to match is
  # what keeps that window from being mistaken for abandonment.
  record_autoarm_epoch "$dir" 464 999 rewake
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a live claim the ledger does not name is unproven and must be left alone"
  [ -z "$out" ] || fail "deferring to an unnamed claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a claim the ledger does not name was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "an unproven claim lost its owner lock"
  pass "auto-arm: a live claim the ledger does not name is never reclaimed"
}

# The same unrecoverable lapse, reached where the ledger cannot prove it: a session
# teardown kills the claim's whole process group before it records any outcome, so
# the entry still reads "arming" (in flight however old, by contract) while the
# recorded pid is later handed to an unrelated live process. Only the identity the
# claim recorded inside its own lock separates that from a real arm in progress.
test_pid_reused_arming_claim_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/reused-pid-arming")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$$" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a claim whose recorded identity no longer matches its live pid must be reclaimed, arming entry or not"
  [ -e "$dir/state/arm-ran" ] || fail "a reused-pid claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "reclaimed cycle did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "reclaim left its serialization mutex behind"
  pass "auto-arm: a claim whose pid was reused is reclaimed even while its ledger entry still reads arming"
}

# The other ledger-blind shape: no ledger at all (a fresh or hand-cleared home)
# plus a reused pid. Without the recorded identity nothing proves abandonment, so
# every later firing exits at the lock and the home never re-arms.
test_pid_reused_claim_with_no_ledger_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/reused-pid-no-ledger")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$$" || fail "could not record a claim pid-identity"
  assert_absent "$dir/state/.claude-autoarm-epoch" "this case must start with no ledger at all"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a reused-pid claim with no ledger to consult must still be reclaimed"
  [ -e "$dir/state/arm-ran" ] || fail "a reused-pid claim with no ledger left the home unarmed"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "reclaimed cycle did not record its own outcome: $(epoch_outcome "$dir")"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  pass "auto-arm: a reused-pid claim is reclaimed even with no ledger entry to prove it"
}

# The negative control for the identity leg: a claim whose recorded identity still
# matches the process holding the lock is genuinely in flight, so an arm that has
# legitimately been running for hours must keep the single-flight gate closed.
test_identity_matched_arming_claim_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/identity-matched-arming")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "an identity-matched claim still arming must keep the single-flight gate closed"
  [ -z "$out" ] || fail "deferring to an identity-matched arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an identity-matched arming claim was stolen and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the arming ledger entry"
  assert_present "$dir/state/.claude-autoarm.lock" "an identity-matched arming claim lost its owner lock"
  pass "auto-arm: an identity-matched owner still arming is never reclaimed"
}

test_terminal_check_claim_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/terminal-check-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  # The synchronous guard takes the same lock under its own role while it decides
  # the attended fail-open. Reclaiming that would race the guard's own decision.
  record_autoarm_owner "$dir" "$pid" terminal-check
  record_autoarm_epoch "$dir" 464 "$pid" failed-suppressed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "the guard's own terminal-check claim must never be reclaimed by the arm hook"
  [ -z "$out" ] || fail "deferring to a terminal-check claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a terminal-check claim was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "a terminal-check claim lost its owner lock"
  pass "auto-arm: the guard's terminal-check claim is never reclaimed"
}

test_need_vanished_mid_cycle_closes_quietly() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/vanished")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" meta-vanishes
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable close after the fleet went idle must not rewake"
  [ -z "$out" ] || fail "vanished-need close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: need vanishing mid-cycle closes without a rewake"
}

test_afk_mid_cycle_suppresses_rewake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK appearing mid-cycle must suppress the primary rewake"
  [ -z "$out" ] || fail "AFK-suppressed close produced output: $out"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "epoch must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "auto-arm: mid-cycle AFK hands triage to the daemon with no rewake"
}

test_active_in_marked_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a marked secondmate home must get the same active auto-arm as the main primary"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a marked secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate epoch must record outcome=rewake"
  pass "auto-arm: active in a marked secondmate home"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

# A `ps` shim that delays every call, so the bounded parent-chain pre-check and
# the identity gate's ancestry walk both take long enough in wall clock for the
# tests below to poll for the claim's presence or absence while they run,
# rather than only after the exit trap has removed it.
install_slow_ps() {
  local dir=$1 real_ps
  real_ps=$(command -v ps) || fail "ps not found for the slow-ps fixture"
  mkdir -p "$dir/slowbin"
  cat > "$dir/slowbin/ps" <<SH
#!/usr/bin/env bash
sleep 0.05
exec $real_ps "\$@"
SH
  chmod +x "$dir/slowbin/ps"
}

# The owning session: state/.lock's pid is the hook's own near ancestor, so the
# bounded pre-check finds it and the claim must appear while the (slowed)
# identity gate is still walking, not merely by the time the hook exits.
test_claim_observable_during_identity_walk_when_owner() {
  local dir hook_pid status claim_seen n
  dir=$(make_primary_dir "$TMP_ROOT/claim-owner-visible")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  install_slow_ps "$dir"
  printf '%s\n' '{"session_id":"sess-owner","stop_hook_active":false}' \
    | PATH="$dir/slowbin:$PATH" FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' > "$dir/hook.out" 2>&1 &
  hook_pid=$!
  claim_seen=0
  n=0
  while kill -0 "$hook_pid" 2>/dev/null; do
    if [ -e "$dir/state/.claude-autoarm-claim" ]; then
      claim_seen=1
      break
    fi
    sleep 0.02
    n=$((n + 1))
    [ "$n" -lt 500 ] || break
  done
  wait "$hook_pid" 2>/dev/null; status=$?
  [ "$claim_seen" -eq 1 ] || fail "the owning session's claim never appeared during its identity walk: $(cat "$dir/hook.out" 2>/dev/null)"
  expect_code 2 "$status" "the ordinary owning firing must still rewake once the pre-check passes"
  [ -e "$dir/state/arm-ran" ] || fail "the owning session's firing did not arm"
  pass "auto-arm: the owning session's claim is observable while its own identity walk runs"
}

# The competing session: state/.lock names a live harness pid that is NOT an
# ancestor of the hook. The bounded pre-check must find no ancestry match and
# decline to publish, so the claim must never appear at any point in the run -
# not even transiently during the (slowed) identity gate - and the hook must
# still stay inert.
test_competing_session_never_publishes_a_claim() {
  local dir other hook_pid status claim_seen n
  dir=$(make_primary_dir "$TMP_ROOT/competing-session")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  install_slow_ps "$dir"
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  printf '%s\n' '{"session_id":"sess-competing","stop_hook_active":false}' \
    | PATH="$dir/slowbin:$PATH" FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' \
    > "$dir/hook.out" 2>&1 &
  hook_pid=$!
  claim_seen=0
  n=0
  while kill -0 "$hook_pid" 2>/dev/null; do
    if [ -e "$dir/state/.claude-autoarm-claim" ]; then
      claim_seen=1
      break
    fi
    sleep 0.02
    n=$((n + 1))
    [ "$n" -lt 500 ] || break
  done
  wait "$hook_pid" 2>/dev/null; status=$?
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  [ "$claim_seen" -eq 0 ] || fail "a competing session's claim appeared before its identity gate could reject it"
  [ ! -e "$dir/state/.claude-autoarm-claim" ] || fail "a competing session left a claim behind: $(cat "$dir/hook.out" 2>/dev/null)"
  expect_code 0 "$status" "a competing session's firing must stay inert"
  [ ! -e "$dir/state/arm-ran" ] || fail "a competing session armed the watcher"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "a competing session wrote an epoch"
  pass "auto-arm: a competing session that does not own state/.lock never publishes a claim"
}

test_inert_in_child_worktree
test_inert_without_session_lock
test_reclaims_stale_session_lock_before_arming
test_inert_when_lock_held_by_other_harness
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_resolves_outermost_claude_pid_in_nested_bgspare_chain
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_actionable_close_with_live_successor_rewakes_once
test_failed_close_rewakes_with_failure_banner
test_failed_cycles_notify_once_and_keep_retrying
test_unverified_clean_close_exhausts_retries
test_post_alarm_actionable_close_is_suppressed
test_benign_cycle_end_with_live_watcher_is_silent
test_positive_recovery_budget_contention_preserves_episode
test_arms_for_x_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_abandoned_owner_claim_is_reclaimed_and_rearms
test_arming_claim_is_never_reclaimed
test_claim_not_named_by_the_ledger_is_never_reclaimed
test_pid_reused_arming_claim_is_reclaimed_and_rearms
test_pid_reused_claim_with_no_ledger_is_reclaimed_and_rearms
test_identity_matched_arming_claim_is_never_reclaimed
test_terminal_check_claim_is_never_reclaimed
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_fm_lock_status_still_works_with_shared_lib
test_claim_observable_during_identity_walk_when_owner
test_competing_session_never_publishes_a_claim

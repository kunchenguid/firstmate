#!/usr/bin/env bash
# Tests for Firstmate dispatch circuit breaker and worktree hygiene guard.
#
# Hermetic failure-injection and behavior tests:
#   1. Pre-spawn reachability: unreachable backend or failed version check refuses
#      dispatch with actionable diagnostic before pane or worktree creation.
#   2. Proof of worker start: pane created but worker never starts (e.g. crashing,
#      hanging, or empty output) refuses dispatch and records failure.
#   3. Worktree hygiene: worktree and changes are preserved on startup failure,
#      never silently discarded or duplicated on retry.
#   4. Dispatch circuit breaker: records bounded per-task attempts, generation,
#      worktree path, outcome, reason, and timestamps.
#   5. Bounded automatic retry: allows at most one automatic retry for
#      transport/empty-result failure, then opens the breaker and refuses subsequent
#      dispatches until explicit captain recovery.
#   6. Duplicate dispatch prevention: concurrent duplicate attempts fail closed
#      under lock/lease model.
#   7. Idempotent recovery / reset: status reporting accurately reflects closed/
#      open/half-open state, and reset transitions to half-open/closed cleanly.
#   8. Restart persistence: state survives session / process restarts.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-dispatch-breaker-lib.sh
. "$ROOT/bin/fm-dispatch-breaker-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BREAKER="$ROOT/bin/fm-dispatch-breaker.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-circuit-breaker)

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" \
    GROK_HOME="$home/grok-home" \
    FM_SKIP_WORKER_VERIFY=0 \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

make_case() {
  local name=$1 harness=$2 id=$3
  local case_dir="$TMP_ROOT/$name"
  local home="$case_dir/home"
  local proj="$case_dir/project"
  local wt="$case_dir/wt"
  local fakebin launchlog

  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  launchlog="$case_dir/launch.log"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$launchlog"
}

# --- Test 1: Pre-spawn backend reachability check --------------------------
test_prespawn_backend_reachability_refusal() {
  local rec id out status case_dir home proj wt fakebin launchlog
  id="task-unreachable-backend"
  rec=$(make_case reachability codex "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF

  # Make tmux unavailable with a failing stub
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tmux"
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness codex 2>&1 || true)
  assert_contains "$out" "backend 'tmux' failed binary check" \
    "unreachable backend should refuse before creating worktree or endpoints"
  [ ! -f "$home/state/$id.meta" ] || fail "metadata was published despite unreachable backend"
  pass "pre-spawn backend reachability refusal"
}

# --- Test 2: Proof of worker start failure (pane created without worker start)
test_pane_created_without_worker_start() {
  local rec id out status case_dir home proj wt fakebin launchlog
  id="task-no-start"
  rec=$(make_case no-start claude "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF

  # Configure fake tmux capture-pane to return empty (simulating worker process failed to start/print)
  out=$(FM_FAKE_CAPTURE_PANE="" FM_FAKE_TMUX_COMM="bash" FM_SPAWN_START_WAIT=1 \
    run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1 || true)
  assert_contains "$out" "worker failed to start processing instructions" \
    "pane creation without worker start should fail dispatch"
  assert_contains "$out" "preserving worktree" \
    "failure must explicitly report worktree preservation"

  # Verify breaker recorded the failure
  fm_dispatch_breaker_read "$home/state" "$id"
  [ "$FM_BREAKER_ATTEMPTS" -eq 1 ] || fail "expected attempt count 1, got $FM_BREAKER_ATTEMPTS"
  [ "$FM_BREAKER_LAST_OUTCOME" = "failure" ] || fail "expected failure outcome, got $FM_BREAKER_LAST_OUTCOME"
  [ -n "$FM_BREAKER_WORKTREE" ] || fail "expected preserved worktree path in breaker record"
  [ ! -f "$home/state/$id.meta" ] || fail "failed start published metadata; retries cannot unwind"
  pass "proof of worker start failure handling"
}

# --- Test 3: Worktree hygiene & preservation across retries ----------------
test_worktree_preservation_on_retry() {
  local rec id out status case_dir home proj wt fakebin launchlog
  id="task-hygiene"
  rec=$(make_case hygiene claude "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF

  # 1. First attempt fails due to no worker start
  out=$(FM_FAKE_CAPTURE_PANE="" FM_FAKE_TMUX_COMM="bash" FM_SPAWN_START_WAIT=1 \
    run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1 || true)

  fm_dispatch_breaker_read "$home/state" "$id"
  local preserved_wt=$FM_BREAKER_WORKTREE
  [ -n "$preserved_wt" ] || fail "first attempt failed to record preserved worktree"

  # Create an unlanded change in the preserved worktree
  echo "unlanded test content" > "$preserved_wt/unlanded.txt"

  # 2. Second attempt (retry) succeeds with active worker
  out=$(FM_SPAWN_START_WAIT=1 \
    run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1)
  expect_code 0 "$?" "spawn retry should succeed: $out"

  # Verify unlanded change was preserved and not wiped
  [ -f "$preserved_wt/unlanded.txt" ] || fail "unlanded change in worktree was lost during retry"
  [ "$(cat "$preserved_wt/unlanded.txt")" = "unlanded test content" ] || fail "unlanded content corrupted"

  fm_dispatch_breaker_read "$home/state" "$id"
  [ "$FM_BREAKER_STATE" = "closed" ] || fail "breaker should be closed after successful start (got $FM_BREAKER_STATE)"
  [ "$FM_BREAKER_LAST_OUTCOME" = "success" ] || fail "breaker last outcome should be success (got $FM_BREAKER_LAST_OUTCOME, reason=$FM_BREAKER_LAST_REASON)"
  pass "worktree hygiene and preservation across retries"
}

# --- Test 4: One automatic retry, then breaker opens -----------------------
test_breaker_trips_after_retry_exhausted() {
  local rec id out status case_dir home proj wt fakebin launchlog
  id="task-circuit-trip"
  rec=$(make_case circuit-trip claude "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF

  # Attempt 1: fails (empty result / no start)
  out=$(FM_FAKE_CAPTURE_PANE="" FM_FAKE_TMUX_COMM="bash" FM_SPAWN_START_WAIT=1 \
    run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1 || true)
  fm_dispatch_breaker_read "$home/state" "$id"
  [ "$FM_BREAKER_ATTEMPTS" -eq 1 ] || fail "attempt 1 count mismatch"
  [ "$FM_BREAKER_STATE" != "open" ] || fail "breaker should allow 1 retry before opening"

  # Attempt 2: second failure trips the breaker open
  out=$(FM_FAKE_CAPTURE_PANE="" FM_FAKE_TMUX_COMM="bash" FM_SPAWN_START_WAIT=1 \
    run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1 || true)
  fm_dispatch_breaker_read "$home/state" "$id"
  [ "$FM_BREAKER_ATTEMPTS" -ge 2 ] || fail "attempt 2 count mismatch"
  [ "$FM_BREAKER_STATE" = "open" ] || fail "breaker should be open after second failure"

  # Attempt 3: immediate refusal without attempting spawn
  out=$(FM_SPAWN_START_WAIT=1 \
    run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1 || true)
  assert_contains "$out" "dispatch circuit breaker is open for task '$id'" \
    "open breaker must immediately refuse dispatch"
  assert_contains "$out" "explicit captain recovery required" \
    "open breaker refusal must name explicit captain recovery"
  pass "breaker trips after retry exhausted and refuses subsequent dispatches"
}

# --- Test 5: Explicit recovery, diagnostic status, and restart persistence --
test_explicit_recovery_status_and_persistence() {
  local rec id out status case_dir home proj wt fakebin launchlog
  id="task-recovery"
  rec=$(make_case recovery claude "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF

  # Force open breaker
  fm_dispatch_breaker_record_attempt "$home/state" "$id" "gen-1" "$wt" "tmux" "claude"
  fm_dispatch_breaker_record_outcome "$home/state" "$id" "gen-1" "failure" "transport-cancel" "$wt" 1

  # Status output check
  out=$(FM_HOME="$home" "$BREAKER" status "$id")
  assert_contains "$out" "breaker: open" "status should report breaker open"
  assert_contains "$out" "last_reason: transport-cancel" "status should report last reason"
  assert_contains "$out" "next_action: Circuit breaker is open" "status should provide actionable next step"

  # Reset breaker to half-open
  out=$(FM_HOME="$home" "$BREAKER" reset "$id" --half-open)
  assert_contains "$out" "reset to 'half-open'" "reset confirmation output missing"

  # Verify persistence and half-open state
  fm_dispatch_breaker_read "$home/state" "$id"
  [ "$FM_BREAKER_STATE" = "half-open" ] || fail "expected half-open breaker state after reset"

  # Re-attempt dispatch under half-open state
  out=$(FM_SPAWN_START_WAIT=1 \
    run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1)
  assert_contains "$out" "spawned $id" "half-open probe dispatch should succeed"

  # Breaker should now be closed
  fm_dispatch_breaker_read "$home/state" "$id"
  [ "$FM_BREAKER_STATE" = "closed" ] || fail "breaker should close upon successful probe dispatch"
  pass "explicit recovery, diagnostic status, and restart persistence"
}

# --- Test 6: Duplicate dispatch concurrency exclusion ----------------------
test_duplicate_dispatch_concurrency_lock() {
  local rec id out status case_dir home proj wt fakebin launchlog
  id="task-concurrent-spawn"
  rec=$(make_case concurrent claude "$id")
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF

  # Hold spawn task lock externally
  local lock_dir="$home/state/.spawn-$id.lock"
  mkdir -p "$home/state"
  fm_lock_try_acquire "$lock_dir" || fail "failed to acquire mock external spawn lock"

  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --mode no-mistakes --yolo off --harness claude 2>&1 || true)
  assert_contains "$out" "another spawn is already creating task $id" \
    "concurrent spawn should be rejected under lock"

  fm_lock_release "$lock_dir"
  pass "duplicate dispatch concurrency exclusion"
}

test_prespawn_backend_reachability_refusal
test_pane_created_without_worker_start
test_worktree_preservation_on_retry
test_breaker_trips_after_retry_exhausted
test_explicit_recovery_status_and_persistence
test_duplicate_dispatch_concurrency_lock

pass "all dispatch circuit breaker and worktree hygiene tests passed"

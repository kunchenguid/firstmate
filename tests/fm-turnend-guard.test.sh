#!/usr/bin/env bash
# Behavior tests for the primary turn-end supervision guard (docs/turnend-guard.md).
#
# Two layers:
#   PREDICATE  - bin/fm-supervision-lib.sh, the shared beacon/status computation
#                used by fm-guard.sh and by the hook's banner details.
#   HOOK       - bin/fm-turnend-guard.sh, the shared primary hook predicate that
#                scopes in-flight work to the PRIMARY checkout only and requires
#                a live, identity-matched watcher lock plus a fresh beacon.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-turnend-guard)
fm_git_identity fmtest fmtest@example.invalid

REQUIRED_REASON='watcher supervision needs Stop-owned automatic recovery; inspect the hook registration and startup status before ending the turn'

# --- PREDICATE: bin/fm-supervision-lib.sh -----------------------------------

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $FM_SUP_IN_FLIGHT"
  pass "fm_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$FM_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $FM_SUP_BEACON_DESC"
  pass "fm_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "fm_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$FM_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "fm_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

test_predicate_queue_pending_flag() {
  local state="$TMP_ROOT/pred-queue/state"
  mkdir -p "$state"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = false ] || fail "empty/absent wake queue must not read as pending"
  printf 'record\n' > "$state/.wake-queue"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = true ] || fail "a non-empty wake queue must read as pending"
  pass "fm_supervision_status: FM_SUP_QUEUE_PENDING tracks state/.wake-queue"
}

test_predicate_x_mode_needs_supervision() {
  local state="$TMP_ROOT/pred-x-mode/state"
  mkdir -p "$state"
  : > "$state/x-watch.check.sh"
  fm_supervision_needed "$state" 300 || fail "X-mode relay poll did not register as supervision need"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "X-mode relay poll must not count as an in-flight task"
  [ "$FM_SUP_NEEDED" = true ] || fail "X-mode relay poll must set FM_SUP_NEEDED"
  fm_supervision_unhealthy "$state" 300 || fail "X-mode relay poll with no beacon must be unhealthy"
  pass "fm_supervision_needed: X-mode relay poll needs supervision"
}

test_predicate_source_needs_supervision() {
  local state="$TMP_ROOT/pred-source/state"
  mkdir -p "$state/procevent"
  : > "$state/procevent/source-only.source"
  fm_supervision_unhealthy "$state" 300 || fail "registered source with no beacon must be unhealthy"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "a process-event source must not count as a task"
  [ "$FM_SUP_SOURCES" -eq 1 ] || fail "expected one registered process-event source"
  pass "fm_supervision_unhealthy: source-only home needs supervision"
}

# --- HOOK: bin/fm-turnend-guard.sh ------------------------------------------
#
# Each scenario gets its own directory carrying a copy of the two guard scripts
# under bin/, so the hook (invoked by absolute path) resolves its own FM_ROOT to
# that scenario dir regardless of the test's cwd.

install_guard_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  cp "$ROOT/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-turnend-guard-grok.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-slack-lib.sh" "$dir/bin/fm-slack-lib.sh"
  cp "$ROOT/bin/fm-x-lib.sh" "$dir/bin/fm-x-lib.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  mkdir -p "$dir/docs"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard-grok.sh" "$dir/bin/fm-operational-input.sh" "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

mark_codex_hook_root() {
  local dir=$1
  mkdir -p "$dir/.codex"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$dir/.codex/hooks.json"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the hook's scoping check requires to treat it as primary.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary, plus the .fm-secondmate-home marker bin/fm-home-seed.sh
# writes at seed time (regardless of treehouse-lease or git-clone acquisition).
make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked `git worktree` of a base repo - the shape bin/fm-spawn.sh
# always hands crewmate/scout tasks working on firstmate itself. git-dir and
# git-common-dir differ here, unlike a plain checkout.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-guard-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A secondmate home's OWN child crew/scout worktree: a genuine linked git
# worktree of the secondmate home, so git-dir != git-common-dir exactly as for a
# main-home child worktree. A child worktree never carries the gitignored
# .fm-secondmate-home marker, so the marker force-include never fires for it and
# it stays exempt through the linked-worktree git-dir test.
make_secondmate_child_worktree_dir() {
  local home=$1 dir=$2
  git -C "$home" worktree add --quiet -b fm/turnend-secondmate-child "$dir"
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf '%s\n' "$dir"
}

# A treehouse-leased secondmate HOME: a genuine linked `git worktree` (git-dir !=
# git-common-dir, exactly like a default treehouse-leased home) that DOES carry a
# valid .fm-secondmate-home marker. This is the production topology the plain
# git-init secondmate fixture cannot represent; the guard must force-INCLUDE it
# as a guarded primary via the marker, not exempt it as a linked worktree.
make_secondmate_linked_home_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/turnend-secondmate-linked-home
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_guard_scripts "$dir"
  printf 'sm-linked-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

run_hook() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s}' "$stop_active" | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1
}

nonexistent_pid() {
  local pid=999999
  while kill -0 "$pid" 2>/dev/null; do
    pid=$((pid + 1))
  done
  printf '%s\n' "$pid"
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$(cd "$dir" && pwd)
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

test_hook_silent_when_no_work_in_flight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must exit 0 with no in-flight work"
  [ -z "$out" ] || fail "hook produced output with no in-flight work: $out"
  pass "fm-turnend-guard: silent no-op with nothing in flight"
}

test_hook_blocks_when_fresh_beacon_has_no_live_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fresh-no-lock")
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when a fresh beacon has no live watcher lock"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks when a fresh beacon has no live watcher lock"
}

test_hook_blocks_source_only_home() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-source-only")
  mkdir -p "$dir/state/procevent"
  : > "$dir/state/procevent/source-only.source"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "non-Claude hook must block when a source-only home has no watcher"
  assert_contains "$out" "1 process-event source(s) registered" "block reason must identify the source-only supervision need"
  pass "fm-turnend-guard: non-Claude path blocks a source-only home"
}

test_hook_blocks_when_dead_lock_has_fresh_beacon() {
  local dir dead out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-dead-lock-fresh")
  dead=$(nonexistent_pid)
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$dead" "dead watcher identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when the watcher lock pid is dead despite a fresh beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a dead watcher lock even when the beacon is fresh"
}

test_hook_silent_with_live_lock_and_fresh_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-fresh")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "hook must exit 0 with a live identity-matched watcher lock and fresh beacon"
  [ -z "$out" ] || fail "hook produced output despite a live fresh watcher lock: $out"
  pass "fm-turnend-guard: silent no-op with a live watcher lock and fresh beacon"
}

test_hook_non_claude_health_ignores_claude_budget_contention() {
  local dir home pid identity holder harness payload out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-non-claude-budget-contention")
  home=$(cd "$dir" && pwd)
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify non-Claude contention watcher"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=claude-episode\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  printf 'notice-state\n' > "$dir/state/.claude-autoarm-failure-notified"
  printf 'alarm-state\n' > "$dir/state/.claude-autoarm-failure-alarmed"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.turnend-claude-blocks.lock"
  printf '%s\n' "$holder" > "$dir/state/.turnend-claude-blocks.lock/pid"
  while IFS='|' read -r harness payload; do
    out=$(printf '%s' "$payload" | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
    expect_code 0 "$status" "$harness healthy path must ignore Claude budget-lock contention"
    [ -z "$out" ] || fail "$harness healthy path produced output: $out"
    [ "$(cat "$dir/state/.turnend-claude-blocks")" = $'session=claude-episode\ncount=3\nepoch=9' ] \
      || fail "$harness healthy path mutated the Claude block budget"
    [ "$(cat "$dir/state/.claude-autoarm-failure-notified")" = notice-state ] \
      || fail "$harness healthy path mutated the Claude failure notice"
    [ "$(cat "$dir/state/.claude-autoarm-failure-alarmed")" = alarm-state ] \
      || fail "$harness healthy path mutated the Claude attended alarm"
    [ "$(cat "$dir/state/.turnend-claude-blocks.lock/pid")" = "$holder" ] \
      || fail "$harness healthy path replaced the Claude budget-lock owner"
  done <<EOF
default|{"stop_hook_active":false}
Codex|{"cwd":"$dir","stop_hook_active":false}
OpenCode|{"stop_hook_active":false}
Pi|{"stop_hook_active":false}
pi-signed|{"stop_hook_active":false}
Grok|{"sessionId":"grok-session","stopHookActive":false}
Kimi|{"stop_hook_active":false}
EOF
  kill "$holder" "$pid" 2>/dev/null || true
  wait "$holder" "$pid" 2>/dev/null || true
  pass "fm-turnend-guard: healthy non-Claude harness paths ignore Claude episode contention"
}

test_hook_blocks_with_live_lock_and_stale_beacon() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-live-lock-stale")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "hook must block when a live watcher lock has an ancient beacon"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks on a live watcher lock with an ancient beacon"
}

test_hook_blocks_when_unhealthy_in_primary() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-block")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block (exit 2) when in-flight work has no live watcher"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks with the exact required reason in the primary when unhealthy"
}

test_hook_blocks_from_fm_home_state() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home")
  home="$TMP_ROOT/hook-fm-home-op"
  mkdir -p "$home/state"
  : > "$home/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must inspect the active FM_HOME state dir"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: blocks from active FM_HOME state, not only repo-root state"
}

test_hook_x_mode_reason_sources_cadence() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-x-mode")
  home=$(cd "$dir" && pwd)
  mkdir -p "$dir/config"
  : > "$dir/config/x-mode.env"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must block when in-flight X-mode work has no live watcher"
  assert_contains "$out" "source '$home/config/x-mode.env' first" "block reason must source the effective X-mode cadence"
  pass "fm-turnend-guard: X-mode repair reason sources the cadence config"
}

test_hook_x_mode_only_blocks_in_default_mode() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-x-mode-only")
  : > "$dir/state/x-watch.check.sh"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "default hook mode must block an X-mode-only blind turn"
  assert_contains "$out" "X-mode relay polling needs supervision" "X-mode-only blind stop must identify its supervision need"
  pass "fm-turnend-guard: X-mode-only supervision remains guarded in default mode"
}

test_hook_ignores_repo_state_when_fm_home_set() {
  local dir home out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-fm-home-ignore-root")
  home="$TMP_ROOT/hook-fm-home-quiet"
  mkdir -p "$home/state"
  : > "$dir/state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must ignore repo-root state when FM_HOME selects another state dir"
  [ -z "$out" ] || fail "hook produced output from stale repo-root state despite FM_HOME: $out"
  pass "fm-turnend-guard: ignores stale repo-root state when FM_HOME is set"
}

test_hook_uses_state_override() {
  local dir home state out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-state-override")
  home="$TMP_ROOT/hook-state-override-home"
  state="$TMP_ROOT/hook-state-override-active"
  mkdir -p "$home/state" "$state"
  : > "$state/task1.meta"
  out=$(printf '{"stop_hook_active":false}' | CLAUDECODE=1 FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 2 "$status" "hook must let FM_STATE_OVERRIDE win over FM_HOME/state"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: uses FM_STATE_OVERRIDE ahead of FM_HOME/state"
}

test_hook_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop when stop_hook_active is already true"
  [ -z "$out" ] || fail "hook produced output on the loop-guarded retry: $out"
  pass "fm-turnend-guard: stop_hook_active=true always allows the stop (never blocks twice in one turn)"
}

# A secondmate's OWN home runs a primary firstmate session and must be guarded
# exactly like the main primary. This was the guard's proven blind spot: the
# .fm-secondmate-home marker used to early-exit here, so an overnight secondmate
# could end a turn with an unsupervised child and sit blind. Removing that marker
# check makes the guard fire, mirroring the cd-guard.
test_hook_blocks_in_secondmate_own_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must guard a secondmate's own home like the main primary when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a secondmate's own home (.fm-secondmate-home no longer excludes it)"
}

# Idle-by-default: an empty-queue secondmate has no in-flight meta, so the guard
# exits at the in-flight gate - never forcing a busy continuation loop.
test_hook_silent_in_idle_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-idle")
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay silent in an idle, empty-queue secondmate home"
  [ -z "$out" ] || fail "idle secondmate home produced guard output: $out"
  pass "fm-turnend-guard: idle-by-default - silent in a secondmate home with nothing in flight"
}

# The stop_hook_active loop guard bounds the secondmate to one forced
# continuation per turn, exactly as it does for the main primary - no wedged,
# un-endable session.
test_hook_secondmate_loop_guard_allows_retry() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-loopguard")
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" true); status=$?
  expect_code 0 "$status" "hook must allow the stop in a secondmate home when stop_hook_active is already true"
  [ -z "$out" ] || fail "secondmate loop-guarded retry produced output: $out"
  pass "fm-turnend-guard: stop_hook_active=true allows the stop in a secondmate home (never blocks twice in one turn)"
}

# The guard's half of the deferred-death recovery loop in a secondmate home,
# proven deterministically without a live model or any daemon: silent while the
# watcher is live (the secondmate ends its turn and relies on the background
# re-invoke), then blocks to force the re-arm once the watcher has exited and a
# second child event lands. The live half - that Claude Code autonomously
# re-invokes the model when the background watcher exits (Mechanism A) - is a
# harness property recorded empirically in docs/turnend-guard.md; it needs a live
# session and cannot be a hermetic CI assertion.
test_hook_secondmate_reinvoke_recovery_loop() {
  local dir pid identity out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-secondmate-reinvoke")
  : > "$dir/state/child1.meta"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "secondmate turn must end silently while its watcher is live (Stop #1)"
  [ -z "$out" ] || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "guard nagged a healthy secondmate at Stop #1: $out"
  }
  # The watcher exits on the wake (its normal lifecycle) and a SECOND child event
  # lands. On the re-invoked recovery turn the secondmate must re-arm; if it did
  # not, the guard blocks that turn's end and forces the re-arm (Stop #2).
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir/state/.watch.lock"
  : > "$dir/state/child2.meta"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "secondmate recovery turn must not end blind after the watcher exits (Stop #2)"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  pass "fm-turnend-guard: secondmate deferred-death recovery - silent while watched, forces re-arm once the watcher exits"
}

# The marker force-include must guard only the secondmate's OWN home, never its
# children: a secondmate's linked crew/scout worktree carries no marker, so it
# stays exempt by the same git-dir/git-common-dir test that exempts the main
# home's children.
test_hook_silent_in_secondmate_child_worktree() {
  local home dir out status
  home=$(make_secondmate_dir "$TMP_ROOT/hook-sm-child-home")
  dir="$TMP_ROOT/hook-sm-child-wt"
  make_secondmate_child_worktree_dir "$home" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must stay exempt in a secondmate's own child crew/scout worktree"
  [ -z "$out" ] || fail "hook produced output inside a secondmate's child worktree: $out"
  pass "fm-turnend-guard: inert in a secondmate's own child worktree (linked git worktree) even when unhealthy"
}

# THE regression the plain git-init fixtures masked: a treehouse-leased secondmate
# home is a genuine LINKED worktree (git-dir != git-common-dir), which the
# remove-only form wrongly exempted. With the marker force-include, its own
# primary session is GUARDED. The test asserts the fixture really is a linked
# worktree so it can never silently regress back into a plain-checkout shape.
test_hook_blocks_in_treehouse_leased_secondmate_home() {
  local base dir gd gcd out status
  base="$TMP_ROOT/hook-sm-leased-base"
  dir="$TMP_ROOT/hook-sm-leased-home"
  make_secondmate_linked_home_dir "$base" "$dir" >/dev/null
  gd=$(git -C "$dir" rev-parse --git-dir)
  gcd=$(git -C "$dir" rev-parse --git-common-dir)
  [ "$gd" != "$gcd" ] || fail "leased-home fixture must be a linked worktree (git-dir != git-common-dir), got equal: $gd"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "hook must GUARD a treehouse-leased (linked) secondmate home via its marker when unhealthy"
  assert_contains "$out" "$REQUIRED_REASON" "block reason must contain the exact required instruction"
  assert_contains "$out" "TURN WOULD END BLIND" "block banner must read as an alarm"
  pass "fm-turnend-guard: blocks a blind turn end in a treehouse-leased LINKED secondmate home (marker force-include)"
}

# Anti-spoof: a linked worktree with an INVALID (empty) marker must NOT be
# force-included. Marker validation rejects it, so it falls through to the
# linked-worktree exemption and stays exempt - a stray/empty marker file can
# never spoof a child worktree into being guarded.
test_hook_exempts_linked_worktree_with_stray_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-stray-marker-base"
  dir="$TMP_ROOT/hook-stray-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "an empty/invalid marker must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "stray empty marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: an invalid (empty) marker cannot spoof inclusion; linked worktree stays exempt"
}

# Anti-spoof under any locale: a NON-ASCII marker id must be REJECTED by the
# ASCII-only (C-collation) allowlist, so it can never force-include a linked
# worktree even where the ambient locale's collation would treat it as a letter.
# Rejection -> git-dir exemption -> the linked worktree stays exempt.
test_hook_exempts_linked_worktree_with_non_ascii_marker() {
  local base dir out status
  base="$TMP_ROOT/hook-nonascii-marker-base"
  dir="$TMP_ROOT/hook-nonascii-marker-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  printf 'caf\xc3\xa9\n' > "$dir/.fm-secondmate-home"
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "a non-ASCII marker id must not spoof force-inclusion in a linked worktree"
  [ -z "$out" ] || fail "non-ASCII marker wrongly force-included a linked worktree: $out"
  pass "fm-turnend-guard: a non-ASCII marker cannot spoof inclusion; linked worktree stays exempt"
}

test_hook_silent_in_crewmate_worktree() {
  local base dir out status
  base="$TMP_ROOT/hook-crew-base"
  dir="$TMP_ROOT/hook-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task1.meta"
  out=$(run_hook "$dir" false); status=$?
  expect_code 0 "$status" "hook must never block inside a crewmate task worktree"
  [ -z "$out" ] || fail "hook produced output inside a crewmate task worktree: $out"
  pass "fm-turnend-guard: inert in a crewmate/scout task worktree (linked git worktree) even when unhealthy"
}

test_hook_silent_without_jq() {
  local dir out status fakebin tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/hook-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/hook-nojq-fake")
  for tool in bash sh git cat printf date uname stat mkdir dirname; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  out=$(printf '{"stop_hook_active":false}' | PATH="$fakebin" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "hook must fail open (exit 0) when jq is unavailable"
  [ -z "$out" ] || fail "hook produced output without jq: $out"
  pass "fm-turnend-guard: fails open (never blocks) when jq is missing"
}

test_hook_silent_without_stdin() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-nostdin")
  : > "$dir/state/task1.meta"
  out=$(bash "$dir/bin/fm-turnend-guard.sh" < /dev/null 2>&1); status=$?
  expect_code 0 "$status" "hook must exit 0 on empty/absent stdin"
  [ -z "$out" ] || fail "hook produced output on empty stdin: $out"
  pass "fm-turnend-guard: silent no-op on empty stdin"
}

test_hook_runs_fast() {
  local dir start elapsed_s
  dir=$(make_primary_dir "$TMP_ROOT/hook-timing")
  : > "$dir/state/task1.meta"
  start=$SECONDS
  run_hook "$dir" false >/dev/null
  elapsed_s=$((SECONDS - start))
  [ "$elapsed_s" -lt 3 ] || fail "hook took ${elapsed_s}s, expected well under a second (generous 3s CI margin)"
  pass "fm-turnend-guard: runs well under the generous timing margin (${elapsed_s}s)"
}

test_grok_adapter_forces_one_resume_when_unhealthy() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-block")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-fakebin")
  log="$TMP_ROOT/grok-adapter-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
{
  printf 'active=%s\n' "\${GROK_TURNEND_GUARD_ACTIVE:-}"
  printf 'home=%s\n' "\${GROK_HOME:-}"
  printf 'args:'
  for arg in "\$@"; do
    printf ' <%s>' "\$arg"
  done
  printf '\n'
} >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must fail open after queuing a forced resume"
  [ -z "$out" ] || fail "grok adapter printed output: $out"
  assert_contains "$(cat "$log")" 'active=1' "grok adapter must mark its forced resume as loop-guarded"
  assert_contains "$(cat "$log")" '<--resume>' "grok adapter must resume the current session"
  assert_contains "$(cat "$log")" '<session-test>' "grok adapter must pass the hook session id"
  assert_not_contains "$(cat "$log")" '<--permission-mode>' "grok adapter must not add a stronger permission mode"
  assert_not_contains "$(cat "$log")" '<bypassPermissions>' "grok adapter must not bypass permissions on forced resume"
  assert_contains "$(cat "$log")" 'FIRSTMATE_OP: v1 turn-end-guard: TURN WOULD END BLIND' "grok adapter must retain the typed guard kind"
  pass "fm-turnend-guard-grok: forces one explicitly marked same-session resume when the shared predicate blocks"
}

test_grok_adapter_loop_guard_skips_resume() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-adapter-loop")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-adapter-loop-fakebin")
  log="$TMP_ROOT/grok-adapter-loop-call.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  out=$(printf '{"sessionId":"session-test","hookEventName":"stop"}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" GROK_TURNEND_GUARD_ACTIVE=1 bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "grok adapter must allow its own forced resume turn to end"
  [ -z "$out" ] || fail "grok adapter printed output while loop-guarded: $out"
  [ ! -e "$log" ] || fail "grok adapter spawned another resume while loop-guarded: $(cat "$log")"
  pass "fm-turnend-guard-grok: legacy environment loop guard prevents a nested resume loop"
}

test_grok_adapter_native_false_blocks_without_resume() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-native-false")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-native-false-bin")
  log="$TMP_ROOT/grok-native-false.log"
  printf '#!/usr/bin/env bash\nprintf called >> %q\n' "$log" > "$fakebin/grok"
  chmod +x "$fakebin/grok"
  out=$(printf '%s' '{"sessionId":"native","stopHookActive":false}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 2 "$status" "native stopHookActive=false must return the shared blocking status"
  assert_contains "$out" 'TURN WOULD END BLIND' "native block must pass shared guard feedback to Grok"
  [ ! -e "$log" ] || fail "native path started grok --resume"
  pass "fm-turnend-guard-grok: native false delegates blocking feedback with zero resume processes"
}

test_grok_adapter_native_true_allows_without_resume() {
  local dir fakebin log out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-native-true")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-native-true-bin")
  log="$TMP_ROOT/grok-native-true.log"
  printf '#!/usr/bin/env bash\nprintf called >> %q\n' "$log" > "$fakebin/grok"
  chmod +x "$fakebin/grok"
  out=$(printf '%s' '{"sessionId":"native","stopHookActive":true}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "native stopHookActive=true must allow the bounded continuation to stop"
  [ -z "$out" ] || fail "native true produced output: $out"
  [ ! -e "$log" ] || fail "native true started grok --resume"
  pass "fm-turnend-guard-grok: native true remains bounded and starts no resume process"
}

test_grok_adapter_snake_case_native_and_camel_precedence() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-native-spellings")
  : > "$dir/state/task1.meta"
  out=$(printf '%s' '{"sessionId":"native","stop_hook_active":false}' | GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 2 "$status" "typed snake_case false must select native blocking"
  assert_contains "$out" 'TURN WOULD END BLIND' "snake_case native block lost feedback"
  out=$(printf '%s' '{"sessionId":"native","stopHookActive":true,"stop_hook_active":false}' | GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "camelCase true must win over snake_case false"
  out=$(printf '%s' '{"sessionId":"native","stopHookActive":false,"stop_hook_active":true}' | GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 2 "$status" "camelCase false must win over snake_case true"
  pass "fm-turnend-guard-grok: both spellings are typed and camelCase has deterministic precedence"
}

test_grok_adapter_invalid_inputs_start_neither_path() {
  local dir fakebin log payload out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-invalid-inputs")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-invalid-bin")
  log="$TMP_ROOT/grok-invalid.log"
  printf '#!/usr/bin/env bash\nprintf called >> %q\n' "$log" > "$fakebin/grok"
  chmod +x "$fakebin/grok"
  for payload in \
    ' ' \
    '{' \
    '{"sessionId":"x","stopHookActive":"false"}' \
    '{"sessionId":"x","stop_hook_active":1}' \
    '{"sessionId":"x"}{"sessionId":"y"}' \
    '{"sessionId":"x","stopHookActive":false}{"sessionId":"y","stopHookActive":false}' \
    '{"sessionId":"x","stopHookActive":"bad","stopHookActive":false}' \
    '{"sessionId":"x","stop_hook_active":false,"stop_hook_active":false}' \
    '{"sessionId":"x","sessionId":"y"}'
  do
    out=$(printf '%s' "$payload" | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
    expect_code 0 "$status" "invalid Grok payload must conservatively allow without choosing a path"
    [ -z "$out" ] || fail "invalid Grok payload produced output: $out"
  done
  [ ! -e "$log" ] || fail "invalid Grok payload started a resume process"
  out=$(printf '%s' '{"sessionId":"x","stopHookActive":false}' | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$TMP_ROOT/missing-grok-root" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "missing shared-guard prerequisite must conservatively allow"
  [ -z "$out" ] || fail "missing prerequisite produced output: $out"
  [ ! -e "$log" ] || fail "missing prerequisite started a resume process"
  pass "fm-turnend-guard-grok: malformed, invalidly typed, and missing-prerequisite payloads start neither path"
}

test_grok_adapter_missing_jq_and_no_supervision_allow() {
  local dir fakebin log out status tool tool_path
  dir=$(make_primary_dir "$TMP_ROOT/grok-nojq")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-nojq-bin")
  log="$TMP_ROOT/grok-nojq.log"
  for tool in bash cat printf; do
    tool_path=$(command -v "$tool") || fail "test host must provide $tool"
    ln -s "$tool_path" "$fakebin/$tool"
  done
  printf '#!/usr/bin/env bash\nprintf called >> %q\n' "$log" > "$fakebin/grok"
  chmod +x "$fakebin/grok"
  out=$(printf '%s' '{"sessionId":"x","stopHookActive":false}' | PATH="$fakebin" GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "missing jq must conservatively allow"
  [ -z "$out" ] || fail "missing jq produced output: $out"
  [ ! -e "$log" ] || fail "missing jq started a resume process"

  dir=$(make_primary_dir "$TMP_ROOT/grok-native-no-work")
  out=$(printf '%s' '{"sessionId":"x","stopHookActive":false}' | GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "healthy no-supervision-needed native stop must allow"
  [ -z "$out" ] || fail "no-supervision-needed native stop produced output: $out"
  pass "fm-turnend-guard-grok: missing jq and no-supervision-needed stops stay silent and bounded"
}

test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root() {
  local settings command dir expected_root outside payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-root")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  outside="$TMP_ROOT/codex-hook-outside"
  mkdir -p "$outside"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  payload=$(jq -cn --arg cwd "$outside" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must execute successfully when payload cwd is outside the firstmate root"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must use the hook process root"
  assert_contains "$out" "$payload" "codex hook must pass the original payload to the guard"
  pass ".codex/hooks.json: Stop hook uses hook process root when payload cwd is outside"
}

test_codex_hook_ignores_nested_git_root_guard() {
  local settings command dir nested subdir expected_root payload out status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-hook-outer")
  mark_codex_hook_root "$dir"
  expected_root=$(cd "$dir" && pwd -P)
  nested="$dir/projects/other"
  mkdir -p "$nested"
  git init -q "$nested"
  git -C "$nested" commit -q --allow-empty -m init
  mkdir -p "$nested/bin" "$nested/.codex"
  : > "$nested/AGENTS.md"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"fm-turnend-guard.sh"}]}]}}\n' > "$nested/.codex/hooks.json"
  cat > "$nested/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'nested guard executed\n'
exit 99
EOF
  chmod +x "$nested/bin/fm-turnend-guard.sh"
  cat > "$dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
printf 'guard=%s\n' "$0"
cat
EOF
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  subdir="$nested/deep/path"
  mkdir -p "$subdir"
  payload=$(jq -cn --arg cwd "$subdir" '{cwd:$cwd,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | (cd "$dir" && bash -c "$command") 2>&1); status=$?
  expect_code 0 "$status" "codex hook must not execute a nested project guard"
  assert_contains "$out" "guard=$expected_root/bin/fm-turnend-guard.sh" "codex hook must keep using the outer firstmate guard"
  assert_not_contains "$out" "nested guard executed" "codex hook must not execute nested project code"
  pass ".codex/hooks.json: Stop hook ignores nested git root guard scripts"
}

test_opencode_plugin_anchors_guard_to_worktree() {
  local plugin parent worktree_dir wrong_dir out status
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  [ -f "$plugin" ] || fail "tracked OpenCode primary plugin is missing"
  parent="$TMP_ROOT/opencode-plugin-parent"
  git init -q "$parent"
  worktree_dir="$parent/nested/opencode-plugin-worktree"
  wrong_dir="$TMP_ROOT/opencode-plugin-cwd/subdir"
  mkdir -p "$worktree_dir/bin" "$wrong_dir"
  cat > "$worktree_dir/bin/fm-turnend-guard.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '●  guard-fired\n' >&2
exit 2
EOF
  chmod +x "$worktree_dir/bin/fm-turnend-guard.sh"
  # Runtime module-format warnings are host noise; this assertion owns plugin output only.
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$plugin" DIRECTORY="$wrong_dir" WORKTREE="$worktree_dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.DIRECTORY,
  worktree: process.env.WORKTREE,
});
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!promptBody.startsWith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")) {
  console.error(`untyped operational prompt: ${promptBody}`);
  process.exit(1);
}
if (!promptBody.includes("guard-fired")) {
  console.error(`missing prompt body: ${promptBody}`);
  process.exit(1);
}
if (!promptBody.includes("watcher cycle is missing, failed, or unhealthy")) {
  console.error(`missing recovery-only preamble: ${promptBody}`);
  process.exit(1);
}
if (promptBody.includes("Resume supervision according to the session-start operating block")) {
  console.error(`ordinary continuity leaked into guard follow-up: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must run the guard from worktree even when directory is elsewhere"
  [ -z "$out" ] || fail "OpenCode plugin worktree-root test printed output: $out"
  pass ".opencode primary plugin: guard path is anchored to worktree, not directory"
}

test_opencode_plugin_scopes_supervision_skip_to_session() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/opencode-session-scoped-skip")
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '●  TURN WOULD END BLIND - SUPERVISION IS OFF' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" \
    WORKTREE="$dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-a" } } });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-b" } } });
if (prompts !== 2) throw new Error(`session B did not receive supervision recovery: ${prompts} prompts`);
EOF
  ); status=$?
  expect_code 0 "$status" "OpenCode supervision skip markers must be session-scoped"
  [ -z "$out" ] || fail "OpenCode session-scoped skip test printed output: $out"
  pass ".opencode primary plugin: session A cannot suppress session B supervision"
}

test_pi_extension_injects_once_per_logical_agent_run() {
  local repo home ext log out status
  repo="$TMP_ROOT/pi-logical-run-root"
  home="$TMP_ROOT/pi-logical-run-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  log="$TMP_ROOT/pi-logical-run-guard.log"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf '●  logical-run guard fired\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_GUARD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts += 1;
    if (!message.startsWith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`untyped operational prompt: ${message}`);
    if (!message.includes("TURN WOULD END BLIND")) throw new Error(`unexpected prompt: ${message}`);
    if (!message.includes("watcher cycle is missing, failed, or unhealthy")) throw new Error(`guard prompt omitted recovery-only state: ${message}`);
    if (message.includes("Resume supervision according to the session-start operating block")) throw new Error(`guard prompt used ordinary continuity: ${message}`);
    if (options?.deliverAs !== "followUp") throw new Error("guard prompt was not a follow-up");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("agent_settled handler was not registered");

await settled({ type: "agent_settled" }, {});
if (prompts !== 1) throw new Error(`no-tool run injected ${prompts} follow-ups`);

for (let i = 0; i < 3; i += 1) {
  await handlers.get("turn_end")?.({ type: "turn_end", turnIndex: i }, {});
}
await settled({ type: "agent_settled" }, {});
if (prompts !== 2) throw new Error(`multi-tool run produced ${prompts - 1} follow-ups`);

const guardRuns = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n").length;
if (guardRuns !== 2) throw new Error(`guard predicate ran ${guardRuns} times for two logical runs`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must inject once for no-tool and multi-tool logical runs"
  [ -z "$out" ] || fail "Pi logical-run guard test printed output: $out"
  pass ".pi primary extension: no-tool and multi-tool runs each inject exactly one guard follow-up"
}

test_pi_extension_retries_after_followup_delivery_failure() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-delivery-failure-root"
  home="$TMP_ROOT/pi-delivery-failure-home"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin" "$home/state"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '●  delivery failure guard\n' >&2
exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let attempts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    attempts += 1;
    if (attempts === 1) throw new Error("synthetic delivery failure");
    await handlers.get("agent_settled")?.({ type: "agent_settled" }, {});
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");
await settled({ type: "agent_settled" }, {});
await settled({ type: "agent_settled" }, {});
if (attempts !== 2) throw new Error(`expected delivery retry, saw ${attempts} attempts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard latch must reset after follow-up delivery failure"
  [ -z "$out" ] || fail "Pi delivery-failure guard test printed output: $out"
  pass ".pi primary extension: delivery failure resets the logical-run latch"
}

# --- Captain-facing reply length warning -------------------------------------

reply_with_lines() {
  local count=$1 i=1
  while [ "$i" -le "$count" ]; do
    printf 'line %s' "$i"
    [ "$i" -eq "$count" ] || printf '\n'
    i=$((i + 1))
  done
}

append_transcript_exchange() {
  local transcript=$1 user_id=$2 user_text=$3 assistant_id=$4 assistant_text=$5
  jq -cn --arg id "$user_id" --arg text "$user_text" \
    '{type:"user",uuid:$id,message:{role:"user",content:$text}}' >> "$transcript"
  jq -cn --arg id "$assistant_id" --arg text "$assistant_text" \
    '{type:"assistant",uuid:$id,message:{role:"assistant",content:[{type:"text",text:$text}]}}' >> "$transcript"
}

captain_reply_payload() {
  local transcript=$1 reply=$2 session=${3:-captain-session}
  jq -cn --arg transcript "$transcript" --arg reply "$reply" --arg session "$session" \
    '{hook_event_name:"Stop",session_id:$session,transcript_path:$transcript,last_assistant_message:$reply,stop_hook_active:false}'
}

test_captain_reply_warning_boundary_and_lifetime() {
  local dir transcript at_cap oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-boundary")
  transcript="$dir/transcript.jsonl"
  at_cap=$(reply_with_lines 12)
  oversized=$(reply_with_lines 13)

  append_transcript_exchange "$transcript" captain-1 'Please report the result.' assistant-1 "$at_cap"
  payload=$(captain_reply_payload "$transcript" "$at_cap")
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "reply exactly at the captain line cap must remain non-blocking"
  [ -z "$out" ] || fail "reply exactly at the cap warned: $out"

  append_transcript_exchange "$transcript" captain-2 'Please report the next result.' assistant-2 "$oversized"
  payload=$(captain_reply_payload "$transcript" "$oversized")
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "oversized captain reply warning must never block"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' "oversized captain reply did not warn"
  assert_contains "$out" '13 lines' "warning did not report the measured line count"
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "repeat stop for one reply must remain non-blocking"
  [ -z "$out" ] || fail "same oversized reply warned twice: $out"

  append_transcript_exchange "$transcript" captain-3 'Please report one more result.' assistant-3 "$oversized"
  payload=$(captain_reply_payload "$transcript" "$oversized")
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "later oversized captain reply warning must remain non-blocking"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' "later distinct oversized reply did not warn"
  pass "fm-turnend-guard: captain reply line cap is inclusive and warning lifetime is one reply"
}

test_captain_reply_warning_operational_and_failure_fail_open() {
  local dir oversized operational configured_at_cap configured_over payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-fail-open")
  mkdir -p "$dir/config"
  oversized=$(reply_with_lines 13)
  operational=$'\xE2\x81\xA3FIRSTMATE_OP: v1 watcher: internal machinery message'
  payload=$(jq -cn --arg reply "$oversized" --arg trigger "$operational" \
    '{stop_hook_active:false,fm_reply_text:$reply,fm_reply_id:"operational-1",fm_trigger_text:$trigger}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "operational reply payload must not block"
  [ -z "$out" ] || fail "operational reply payload warned: $out"

  payload=$(jq -cn --arg reply "$oversized" \
    '{stop_hook_active:false,fm_reply_text:$reply,fm_reply_id:"non-captain-1",fm_captain_facing:false}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "explicit non-captain reply payload must not block"
  [ -z "$out" ] || fail "explicit non-captain reply payload warned: $out"

  configured_at_cap=$(reply_with_lines 2)
  configured_over=$(reply_with_lines 3)
  printf '2\n' > "$dir/config/slack-captain-comms-lines"
  payload=$(jq -cn --arg reply "$configured_at_cap" \
    '{stop_hook_active:false,fm_reply_text:$reply,fm_reply_id:"configured-at-cap",fm_captain_facing:true}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "operator-configured captain line cap must remain non-blocking"
  [ -z "$out" ] || fail "reply at the operator-configured cap warned: $out"
  payload=$(jq -cn --arg reply "$configured_over" \
    '{stop_hook_active:false,fm_reply_text:$reply,fm_reply_id:"configured-over",fm_captain_facing:true}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "operator-configured captain line warning must remain non-blocking"
  assert_contains "$out" '2-line captain comms cap' "warning ignored the operator-owned shared line cap"
  rm -f "$dir/config/slack-captain-comms-lines"

  ln -s "$dir/config/missing-cap" "$dir/config/slack-captain-comms-lines"
  payload=$(jq -cn --arg reply "$oversized" \
    '{stop_hook_active:false,fm_reply_text:$reply,fm_reply_id:"config-failure-1",fm_captain_facing:true}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "captain line-cap configuration failure must fail open"
  assert_contains "$out" 'captain-comms warning stood down' "configuration failure omitted bounded diagnostic evidence"
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' "configuration failure emitted a wording warning"
  rm -f "$dir/config/slack-captain-comms-lines"

  out=$(printf '%s' "$payload" | FM_HOME="$dir" FMS_CAPTAIN_COMMS_MEASURE_AWK=missing-measurer \
    bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "captain reply measurement failure must fail open"
  assert_contains "$out" 'captain-comms warning stood down' "measurement failure omitted bounded diagnostic evidence"
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' "measurement failure emitted a wording warning"
  pass "fm-turnend-guard: operational payloads are exempt and configuration or measurement failure steps aside"
}

test_codex_shaped_payload_reaches_the_shared_warning_predicate() {
  local dir transcript oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/codex-captain-reply-warning")
  transcript="$dir/rollout.jsonl"
  oversized=$(reply_with_lines 13)
  jq -cn '{type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:"Report the result."}]}}' > "$transcript"
  jq -cn --arg reply "$oversized" \
    '{type:"response_item",payload:{id:"codex-assistant-1",type:"message",role:"assistant",content:[{type:"output_text",text:$reply}]}}' >> "$transcript"
  payload=$(jq -cn --arg transcript "$transcript" --arg reply "$oversized" \
    '{hook_event_name:"Stop",session_id:"codex-session",turn_id:"codex-turn-1",stop_hook_active:false,transcript_path:$transcript,last_assistant_message:$reply}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "Codex captain reply warning must preserve non-blocking Stop status"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' "Codex Stop payload did not reach the shared warning predicate"
  pass "fm-turnend-guard: a Codex-shaped Stop payload reaches the shared warning predicate"
}

test_codex_registration_keeps_stop_hook_stdout_empty() {
  local settings command dir transcript oversized payload stdout_file stderr_file status
  settings="$ROOT/.codex/hooks.json"
  [ -f "$settings" ] || fail "tracked .codex/hooks.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .codex/hooks.json"
  dir=$(make_primary_dir "$TMP_ROOT/codex-registration-sink")
  mark_codex_hook_root "$dir"
  transcript="$dir/rollout.jsonl"
  oversized=$(reply_with_lines 13)
  append_transcript_exchange "$transcript" codex-user 'Report the result.' codex-assistant "$oversized"
  payload=$(jq -cn --arg cwd "$dir" --arg transcript "$transcript" --arg reply "$oversized" \
    '{cwd:$cwd,hook_event_name:"Stop",session_id:"codex-session",turn_id:"codex-turn-1",stop_hook_active:false,transcript_path:$transcript,last_assistant_message:$reply}')
  stdout_file="$dir/stdout.txt"
  stderr_file="$dir/stderr.txt"
  # Drive the tracked registration itself: Codex validates Stop hook stdout and
  # reports a failed hook for an envelope it does not recognise.
  printf '%s' "$payload" | (cd "$dir" && FM_HOME="$dir" bash -c "$command") \
    > "$stdout_file" 2> "$stderr_file"
  status=$?
  expect_code 0 "$status" "the tracked Codex Stop registration must stay non-blocking"
  [ ! -s "$stdout_file" ] \
    || fail "the Codex Stop registration wrote to a stdout channel Codex rejects: $(cat "$stdout_file")"
  assert_absent "$dir/state/.turnend-captain-comms-warning" \
    "the Codex registration spent the reply's one warning on a channel with no reader"
  pass ".codex/hooks.json: the tracked Stop registration keeps hook stdout empty"
}

test_grok_native_delegation_keeps_stop_hook_stdout_empty() {
  local dir transcript oversized payload stdout_file stderr_file status out
  dir=$(make_primary_dir "$TMP_ROOT/grok-captain-reply-warning")
  transcript="$dir/transcript.jsonl"
  oversized=$(reply_with_lines 13)
  append_transcript_exchange "$transcript" captain-grok 'Report the result.' assistant-grok "$oversized"
  payload=$(jq -cn --arg transcript "$transcript" --arg reply "$oversized" \
    '{sessionId:"grok-captain",hookEventName:"stop",stopHookActive:false,transcriptPath:$transcript,lastAssistantMessage:$reply}')
  stdout_file="$dir/stdout.txt"
  stderr_file="$dir/stderr.txt"
  # Grok's Stop stdout schema is unmeasured and a sibling harness was measured
  # rejecting this envelope, so the native delegation must stay silent there.
  printf '%s' "$payload" | GROK_WORKSPACE_ROOT="$dir" bash "$dir/bin/fm-turnend-guard-grok.sh" \
    > "$stdout_file" 2> "$stderr_file"
  status=$?
  expect_code 0 "$status" "the native Grok delegation must preserve its non-blocking status"
  [ ! -s "$stdout_file" ] \
    || fail "the native Grok delegation wrote an unverified envelope to Stop hook stdout: $(cat "$stdout_file")"
  assert_absent "$dir/state/.turnend-captain-comms-warning" \
    "the native Grok delegation spent the reply's one warning on a channel with no established reader"

  # The same reply must still warn on a harness whose stdout is read.
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "a reply the Grok delegation could not warn about lost its warning everywhere"
  pass "fm-turnend-guard-grok: the native delegation keeps Stop hook stdout empty and the warning eligible"
}

test_opencode_plugin_warns_without_continuation() {
  local dir plugin oversized out status
  dir=$(make_primary_dir "$TMP_ROOT/opencode-captain-reply-warning")
  plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  oversized=$(reply_with_lines 13)
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$plugin" WORKTREE="$dir" OVERSIZED="$oversized" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
let warnings = 0;
const client = {
  session: { promptAsync: async () => { prompts += 1; } },
  tui: {
    showToast: async ({ body }) => {
      if (!body.message.includes("CAPTAIN COMMS WARNING")) throw new Error(`unexpected toast: ${body.message}`);
      warnings += 1;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const emit = (event) => hooks.event({ event });
await emit({ type: "message.updated", properties: { info: { id: "user-1", sessionID: "session-1", role: "user" } } });
await emit({ type: "message.part.updated", properties: { part: { messageID: "user-1", sessionID: "session-1", type: "text", text: "Report the result." } } });
await emit({ type: "message.updated", properties: { info: { id: "assistant-1", sessionID: "session-1", role: "assistant" } } });
await emit({ type: "message.part.updated", properties: { part: { messageID: "assistant-1", sessionID: "session-1", type: "text", text: process.env.OVERSIZED } } });
await emit({ type: "message.updated", properties: { info: { id: "assistant-1", sessionID: "session-1", role: "assistant" } } });
await emit({ type: "session.idle", properties: { sessionID: "session-1" } });
await emit({ type: "session.idle", properties: { sessionID: "session-1" } });
if (warnings !== 1) throw new Error(`expected one warning toast, saw ${warnings}`);
if (prompts !== 0) throw new Error(`wording warning started ${prompts} continuation turns`);
EOF
); status=$?
  expect_code 0 "$status" "OpenCode adapter must warn once without prompting a continuation"
  [ -z "$out" ] || fail "OpenCode captain warning test printed output: $out"
  pass ".opencode primary plugin: captain reply warning uses no continuation loop"
}

test_pi_extension_warns_without_followup() {
  local repo home ext oversized out status
  repo=$(make_primary_dir "$TMP_ROOT/pi-captain-reply-warning")
  home="$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  oversized=$(reply_with_lines 13)
  out=$(PLUGIN="$ext" FM_HOME="$home" OVERSIZED="$oversized" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let warningMessages = 0;
let followups = 0;
let modelMessages = 0;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  async sendUserMessage() { followups += 1; },
  sendMessage() { modelMessages += 1; },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const ctx = {
  sessionManager: { getSessionId: () => "pi-session" },
  ui: {
    notify(message, type) {
      if (!message.includes("CAPTAIN COMMS WARNING")) throw new Error(`unexpected warning: ${message}`);
      if (type !== "warning") throw new Error(`unexpected warning type: ${type}`);
      warningMessages += 1;
    },
  },
};
await handlers.get("input")?.({ type: "input", text: "Report the result.", source: "interactive" }, ctx);
await handlers.get("turn_end")?.({ type: "turn_end", message: { role: "assistant", timestamp: 100, content: [{ type: "text", text: process.env.OVERSIZED }] } }, ctx);
await handlers.get("agent_settled")?.({ type: "agent_settled" }, ctx);
await handlers.get("agent_settled")?.({ type: "agent_settled" }, ctx);
if (warningMessages !== 1) throw new Error(`expected one UI warning, saw ${warningMessages}`);
if (modelMessages !== 0) throw new Error(`captain warning entered model context through sendMessage (${modelMessages})`);
if (followups !== 0) throw new Error(`wording warning started ${followups} follow-up turns`);
EOF
); status=$?
  expect_code 0 "$status" "Pi adapter must warn once without sending a follow-up"
  [ -z "$out" ] || fail "Pi captain warning test printed output: $out"
  pass ".pi primary extension: captain reply warning uses no continuation loop"
}

test_captain_reply_warning_survives_a_blocking_supervision_verdict() {
  local dir transcript oversized payload out status stdout_file stderr_file
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-with-block")
  transcript="$dir/transcript.jsonl"
  oversized=$(reply_with_lines 13)
  append_transcript_exchange "$transcript" captain-blk 'Please report the result.' assistant-blk "$oversized"
  # A task in flight with no live watcher makes the same invocation block.
  : > "$dir/state/task1.meta"
  touch "$dir/state/.last-watcher-beat"
  payload=$(captain_reply_payload "$transcript" "$oversized" blocking-session)
  stdout_file="$dir/stdout.txt"
  stderr_file="$dir/stderr.txt"
  printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" \
    > "$stdout_file" 2> "$stderr_file"
  status=$?
  expect_code 2 "$status" "a coincident warning must not weaken the blocking supervision verdict"
  out=$(cat "$stderr_file")
  assert_contains "$out" 'TURN WOULD END BLIND - SUPERVISION IS OFF' \
    "the harness-neutral supervision banner must survive a coincident warning"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "a warning claimed on a blocking invocation must still reach the direct harness stderr channel"
  out=$(cat "$stdout_file")
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "the stdout envelope must still carry the warning for adapters that read it regardless of exit status"
  pass "fm-turnend-guard: a warning coincident with a block is delivered on both consumers' channels"
}

test_captain_reply_warning_envelope_declares_its_kind() {
  local dir oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-envelope-kind")
  oversized=$(reply_with_lines 13)
  payload=$(jq -cn --arg reply "$oversized" \
    '{stop_hook_active:false,fm_reply_text:$reply,fm_reply_id:"kind-1",fm_captain_facing:true}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null); status=$?
  expect_code 0 "$status" "the warning envelope must remain non-blocking"
  out=$(printf '%s' "$out" | jq -r '.kind // empty') \
    || fail "the warning envelope is not a single JSON object"
  [ "$out" = captain-comms-warning ] \
    || fail "the warning envelope must declare kind=captain-comms-warning, got: $out"
  pass "fm-turnend-guard: the warning envelope carries an explicit routing discriminator"
}

test_captain_reply_falls_back_to_the_transcript_reply() {
  local dir transcript oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-transcript-fallback")
  transcript="$dir/transcript.jsonl"
  oversized=$(reply_with_lines 13)
  append_transcript_exchange "$transcript" captain-tf 'Please report the result.' assistant-tf "$oversized"
  # A direct-harness Stop payload that carries no completed-reply field at all.
  payload=$(jq -cn --arg transcript "$transcript" \
    '{hook_event_name:"Stop",session_id:"transcript-session",transcript_path:$transcript,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "the transcript reply fallback must remain non-blocking"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "a Stop payload without a reply field must measure the transcript's completed reply"
  assert_contains "$out" '13 lines' "the transcript fallback must measure the whole completed reply"

  # Nothing to measure and no transcript is silence, not a diagnostic.
  payload=$(jq -cn '{hook_event_name:"Stop",session_id:"empty-session",stop_hook_active:false}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "a payload with nothing to measure must not block"
  [ -z "$out" ] || fail "a payload with nothing to measure produced output: $out"
  pass "fm-turnend-guard: the transcript supplies the direct-harness completed reply"
}

test_opencode_plugin_measures_the_whole_multipart_reply() {
  local dir oversized_head oversized_tail out status
  dir=$(make_primary_dir "$TMP_ROOT/opencode-multipart-reply")
  # Split so no single part exceeds the cap: only the joined reply does.
  oversized_head=$(reply_with_lines 8)
  oversized_tail=$(reply_with_lines 6)
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" \
    WORKTREE="$dir" HEAD_TEXT="$oversized_head" TAIL_TEXT="$oversized_tail" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let warnings = 0;
let warningText = "";
const client = {
  session: { promptAsync: async () => {} },
  tui: {
    showToast: async ({ body }) => {
      warnings += 1;
      warningText = body.message;
    },
  },
};
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
const emit = (event) => hooks.event({ event });
await emit({ type: "message.updated", properties: { info: { id: "user-1", sessionID: "s1", role: "user" } } });
await emit({ type: "message.part.updated", properties: { part: { id: "up-1", messageID: "user-1", sessionID: "s1", type: "text", text: "Report " } } });
await emit({ type: "message.part.updated", properties: { part: { id: "up-2", messageID: "user-1", sessionID: "s1", type: "text", text: "the result." } } });
await emit({ type: "message.updated", properties: { info: { id: "assistant-1", sessionID: "s1", role: "assistant" } } });
await emit({ type: "message.part.updated", properties: { part: { id: "ap-1", messageID: "assistant-1", sessionID: "s1", type: "text", text: `${process.env.HEAD_TEXT}\n` } } });
await emit({ type: "message.part.updated", properties: { part: { id: "tool-1", messageID: "assistant-1", sessionID: "s1", type: "tool", text: "ignored" } } });
await emit({ type: "message.part.updated", properties: { part: { id: "ap-2", messageID: "assistant-1", sessionID: "s1", type: "text", text: process.env.TAIL_TEXT } } });
await emit({ type: "session.idle", properties: { sessionID: "s1" } });
if (warnings !== 1) throw new Error(`expected one warning for the joined reply, saw ${warnings}`);
if (!warningText.includes("14 lines")) throw new Error(`reply was measured on one fragment only: ${warningText}`);
EOF
); status=$?
  expect_code 0 "$status" "OpenCode must measure every ordered text part of a split reply"
  [ -z "$out" ] || fail "OpenCode multipart reply test printed output: $out"
  pass ".opencode primary plugin: a reply split around a tool part is measured whole"
}

test_opencode_plugin_keeps_advisory_diagnostics_out_of_the_continuation() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/opencode-banner-only")
  # A stub guard puts both stderr line kinds on the wire deliberately, so the
  # filter is measured against a marked banner line that must survive and an
  # unmarked advisory line that must not, rather than against whatever the real
  # guard happens to emit on this path today.
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
{
  printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
  printf '●  marked recovery instruction\n'
  printf 'fm-turnend-guard: captain-comms warning stood down: unmarked advisory line\n'
} >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" \
    WORKTREE="$dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptText = "";
const client = {
  session: { promptAsync: async (request) => { promptText = request.body.parts[0].text; } },
  tui: { showToast: async () => {} },
};
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s1" } } });
if (!promptText) throw new Error("the supervision block produced no continuation");
if (!promptText.includes("TURN WOULD END BLIND")) throw new Error(`continuation lost the supervision banner: ${promptText}`);
if (!promptText.includes("marked recovery instruction")) {
  throw new Error(`continuation dropped a marked banner line: ${promptText}`);
}
if (promptText.includes("unmarked advisory line")) {
  throw new Error(`an unmarked advisory line leaked into the continuation: ${promptText}`);
}
EOF
); status=$?
  expect_code 0 "$status" "OpenCode continuation must keep every marked banner line and no unmarked line"
  [ -z "$out" ] || fail "OpenCode banner-only test printed output: $out"
  pass ".opencode primary plugin: the forced continuation carries every banner line and nothing else"
}

test_captain_reply_warning_and_terminal_fail_open_share_one_envelope() {
  local dir oversized payload out status objects message
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-terminal-failopen")
  : > "$dir/state/task1.meta"
  seed_claude_failure "$dir"
  seed_claude_budget "$dir" 3
  oversized=$(reply_with_lines 13)
  payload=$(jq -cn --arg reply "$oversized" \
    '{stop_hook_active:true,session_id:"sess-claude-mode",fm_reply_text:$reply,fm_reply_id:"failopen-1",fm_captain_facing:true}')
  out=$(printf '%s' "$payload" | CLAUDECODE=1 FM_HOME="$dir" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
    bash "$dir/bin/fm-turnend-guard.sh" --claude 2>/dev/null); status=$?
  expect_code 0 "$status" "the bounded attended fail-open must still exit 0 with a coincident warning"
  objects=$(printf '%s\n' "$out" | grep -c '^{') \
    || fail "the fail-open path emitted no stdout envelope"
  [ "$objects" -eq 1 ] || fail "stdout carried $objects JSON objects; a direct harness parses it as one document"
  message=$(printf '%s' "$out" | jq -er '.systemMessage') \
    || fail "stdout is not a single valid JSON envelope: $out"
  assert_contains "$message" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' \
    "the combined envelope dropped the safety-critical attended fail-open notice"
  assert_contains "$message" 'CAPTAIN COMMS WARNING' \
    "the combined envelope dropped the coincident captain reply warning"
  pass "fm-turnend-guard: a warning coincident with the attended fail-open shares one stdout envelope"
}

test_captain_reply_warning_survives_an_undeliverable_banner_less_block() {
  local dir oversized payload stderr_file stdout_file status out
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-bannerless-block")
  : > "$dir/state/task1.meta"
  record_watcher_lock "$dir" "$$" "$(watcher_identity "$dir" "$$")"
  touch "$dir/state/.last-watcher-beat"
  # The Stop-owned auto-arm holds the same budget lock on this Stop event, so
  # the healthy-watcher reset loses it and the guard exits 2 with no banner.
  mkdir -p "$dir/state/.turnend-claude-blocks.lock"
  printf '%s\n' "$$" > "$dir/state/.turnend-claude-blocks.lock/pid"
  printf 'autoarm\n' > "$dir/state/.turnend-claude-blocks.lock/role"
  oversized=$(reply_with_lines 13)
  payload=$(jq -cn --arg reply "$oversized" \
    '{stop_hook_active:false,session_id:"sess-claude-mode",fm_reply_text:$reply,fm_reply_id:"contended-1",fm_captain_facing:true}')
  stdout_file="$dir/stdout.txt"
  stderr_file="$dir/stderr.txt"
  printf '%s' "$payload" | CLAUDECODE=1 FM_HOME="$dir" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
    bash "$dir/bin/fm-turnend-guard.sh" --claude > "$stdout_file" 2> "$stderr_file"
  status=$?
  expect_code 2 "$status" "budget-lock contention on a healthy watcher must still block"
  assert_not_contains "$(cat "$stderr_file")" 'CAPTAIN COMMS WARNING' \
    "an advisory warning became the stated reason for a block that emitted no supervision banner"
  assert_not_contains "$(cat "$stdout_file")" 'CAPTAIN COMMS WARNING' \
    "a blocked direct harness discards stdout, so the warning must not be emitted into it there"
  assert_absent "$dir/state/.turnend-captain-comms-warning" \
    "an undeliverable warning recorded its identity and spent the reply's one warning"

  # The same reply must still warn once a turn end can reach a channel.
  rm -rf "$dir/state/.turnend-claude-blocks.lock"
  out=$(printf '%s' "$payload" | CLAUDECODE=1 FM_HOME="$dir" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
    bash "$dir/bin/fm-turnend-guard.sh" --claude 2>/dev/null); status=$?
  expect_code 0 "$status" "an uncontended healthy watcher must allow the stop"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "the reply that could not be warned about earlier never warned at all"
  out=$(printf '%s' "$payload" | CLAUDECODE=1 FM_HOME="$dir" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 \
    bash "$dir/bin/fm-turnend-guard.sh" --claude 2>/dev/null)
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' "a delivered warning repeated for the same reply"
  pass "fm-turnend-guard: an undeliverable warning is neither shown as a block reason nor spent"
}

test_grok_legacy_healthy_turn_keeps_the_warning_eligible() {
  local dir fakebin log oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/grok-legacy-healthy-warning")
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-legacy-healthy-fakebin")
  log="$TMP_ROOT/grok-legacy-healthy.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf 'called\n' >> "$log"
EOF
  chmod +x "$fakebin/grok"
  oversized=$(reply_with_lines 13)
  payload=$(jq -cn --arg reply "$oversized" \
    '{sessionId:"grok-healthy-session",hookEventName:"stop",fm_reply_text:$reply,fm_reply_id:"grok-healthy-1",fm_captain_facing:true}')
  # No work in flight: the shared predicate allows, so this path never builds
  # the bounded resume prompt that is its only display surface.
  out=$(printf '%s' "$payload" | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" \
    bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "a healthy pre-native Grok turn must end normally"
  [ -z "$out" ] || fail "grok legacy adapter printed output on a healthy turn: $out"
  [ ! -e "$log" ] || fail "grok legacy adapter started a resume on a healthy turn"
  assert_absent "$dir/state/.turnend-captain-comms-warning" \
    "the pre-native Grok path spent the reply's one warning on a stream it discards"

  # The identical reply must still warn on a harness whose stdout is read.
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "a reply the pre-native Grok path could not warn about lost its warning everywhere"
  pass "fm-turnend-guard-grok: a pre-native turn with no display surface leaves the warning eligible"
}

test_captain_reply_warning_fails_open_on_a_broken_hasher() {
  local dir fakebin oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-broken-hasher")
  # Only the hashers are replaced: an installed-but-failing hasher (a broken
  # perl install behind shasum) is the case a missing binary does not cover.
  fakebin=$(fm_fakebin "$TMP_ROOT/captain-reply-hasher-fakebin")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/shasum"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/sha256sum"
  chmod +x "$fakebin/shasum" "$fakebin/sha256sum"
  oversized=$(reply_with_lines 13)
  payload=$(jq -cn --arg reply "$oversized" \
    '{stop_hook_active:false,fm_reply_text:$reply,fm_reply_id:"broken-hasher-1",fm_captain_facing:true}')
  out=$(printf '%s' "$payload" | PATH="$fakebin:$PATH" FM_HOME="$dir" \
    bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "an unavailable identity hasher must fail open"
  assert_contains "$out" 'cannot hash the warning identity' \
    "a failing hasher was silently swallowed instead of leaving bounded evidence"
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' "a warning was emitted without a usable identity"
  assert_absent "$dir/state/.turnend-captain-comms-warning" \
    "a failed identity hash still wrote a warning record"
  pass "fm-turnend-guard: a failing identity hasher steps aside with bounded evidence"
}

test_block_banner_marks_every_reason_line() {
  local dir out status marked total
  dir=$(make_primary_dir "$TMP_ROOT/banner-multiline-reason")
  : > "$dir/state/task1.meta"
  cat > "$dir/bin/fm-supervision-instructions.sh" <<'SH'
#!/usr/bin/env bash
printf 'first repair line\nsecond repair line\n'
SH
  chmod +x "$dir/bin/fm-supervision-instructions.sh"
  out=$(run_hook "$dir" false); status=$?
  expect_code 2 "$status" "a multi-line repair reason must still block"
  assert_contains "$out" 'first repair line' "banner dropped the first repair line"
  assert_contains "$out" 'second repair line' "banner dropped the continuation repair line"
  total=$(printf '%s\n' "$out" | grep -c 'repair line')
  marked=$(printf '%s\n' "$out" | grep -c '^●  .*repair line')
  [ "$marked" -eq "$total" ] \
    || fail "only $marked of $total repair lines carry the banner mark a passive adapter keeps"
  pass "fm-turnend-guard: every supervision reason line survives passive-adapter banner filtering"
}

test_grok_legacy_resume_carries_the_coincident_warning() {
  local dir fakebin log oversized payload out status prompt
  dir=$(make_primary_dir "$TMP_ROOT/grok-legacy-warning")
  : > "$dir/state/task1.meta"
  fakebin=$(fm_fakebin "$TMP_ROOT/grok-legacy-warning-fakebin")
  log="$TMP_ROOT/grok-legacy-warning.log"
  cat > "$fakebin/grok" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
EOF
  chmod +x "$fakebin/grok"
  oversized=$(reply_with_lines 13)
  payload=$(jq -cn --arg reply "$oversized" \
    '{sessionId:"grok-legacy-session",hookEventName:"stop",fm_reply_text:$reply,fm_reply_id:"grok-legacy-1",fm_captain_facing:true}')
  out=$(printf '%s' "$payload" | PATH="$fakebin:$PATH" GROK_WORKSPACE_ROOT="$dir" \
    bash "$dir/bin/fm-turnend-guard-grok.sh" 2>&1); status=$?
  expect_code 0 "$status" "the pre-native Grok adapter must fail open after queuing its one resume"
  [ -z "$out" ] || fail "grok legacy adapter printed output: $out"
  prompt=$(cat "$log")
  assert_contains "$prompt" 'TURN WOULD END BLIND' "the bounded resume lost the supervision banner"
  assert_contains "$prompt" 'CAPTAIN COMMS WARNING' \
    "the pre-native resume is the only surface this warning can reach, and it was dropped"
  assert_not_contains "$prompt" 'captain-comms warning stood down' \
    "a stand-down diagnostic leaked into the bounded resume prompt"
  pass "fm-turnend-guard-grok: the pre-native resume carries a warning coincident with a block"
}

test_captain_reply_identity_uses_the_payload_turn_id() {
  local dir transcript oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-prompt-id")
  transcript="$dir/transcript.jsonl"
  oversized=$(reply_with_lines 13)
  # A real Claude Stop payload names the turn with prompt_id, and at Stop time
  # the transcript holds the triggering user record but no assistant record.
  jq -cn --arg text 'Please report the result.' \
    '{type:"user",uuid:"claude-user-1",message:{role:"user",content:$text}}' > "$transcript"
  payload=$(jq -cn --arg transcript "$transcript" --arg reply "$oversized" \
    '{hook_event_name:"Stop",session_id:"claude-session",prompt_id:"prompt-1",transcript_path:$transcript,last_assistant_message:$reply,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "a payload-identified reply must remain non-blocking"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "a turn whose transcript has no assistant record yet must still resolve a reply identity"
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' "the payload turn id did not dedup a repeated stop"

  # A later distinct reply on the same turn identity still warns.
  payload=$(jq -cn --arg transcript "$transcript" --arg reply "$(reply_with_lines 14)" \
    '{hook_event_name:"Stop",session_id:"claude-session",prompt_id:"prompt-1",transcript_path:$transcript,last_assistant_message:$reply,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  assert_contains "$out" 'CAPTAIN COMMS WARNING' "a later distinct oversized reply did not warn"
  pass "fm-turnend-guard: the payload turn id identifies a reply the transcript has not flushed"
}

test_declared_stdout_sink_none_keeps_the_turn_end_silent() {
  local dir transcript oversized payload stdout_file stderr_file status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-sink-none")
  transcript="$dir/transcript.jsonl"
  oversized=$(reply_with_lines 13)
  append_transcript_exchange "$transcript" sink-user 'Please report the result.' sink-assistant "$oversized"
  payload=$(jq -cn --arg transcript "$transcript" --arg reply "$oversized" \
    '{hook_event_name:"Stop",session_id:"codex-session",turn_id:"codex-turn-1",transcript_path:$transcript,last_assistant_message:$reply,stop_hook_active:false}')
  stdout_file="$dir/stdout.txt"
  stderr_file="$dir/stderr.txt"
  printf '%s' "$payload" | FM_HOME="$dir" FM_TURNEND_STDOUT_SINK=none \
    bash "$dir/bin/fm-turnend-guard.sh" > "$stdout_file" 2> "$stderr_file"
  status=$?
  expect_code 0 "$status" "a declared stdout sink must not change the turn-end verdict"
  [ ! -s "$stdout_file" ] \
    || fail "a harness that rejects hook stdout still received output: $(cat "$stdout_file")"
  assert_absent "$dir/state/.turnend-captain-comms-warning" \
    "a warning with no accepting channel still spent the reply's one warning"

  # The same reply must still warn on a harness whose stdout is read.
  stdout_file=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_contains "$stdout_file" 'CAPTAIN COMMS WARNING' \
    "a reply the sink-less harness could not warn about lost its warning everywhere"
  pass "fm-turnend-guard: a declared stdout sink stays silent and leaves the warning eligible"
}

test_captain_reply_warning_survives_an_interleaved_session() {
  local dir reply_a reply_b payload_a payload_b out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-interleaved")
  reply_a=$(reply_with_lines 13)
  reply_b=$(reply_with_lines 14)
  payload_a=$(jq -cn --arg reply "$reply_a" \
    '{stop_hook_active:false,session_id:"session-a",fm_reply_text:$reply,fm_reply_id:"A1",fm_captain_facing:true}')
  payload_b=$(jq -cn --arg reply "$reply_b" \
    '{stop_hook_active:false,session_id:"session-b",fm_reply_text:$reply,fm_reply_id:"B1",fm_captain_facing:true}')

  out=$(printf '%s' "$payload_a" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null); status=$?
  expect_code 0 "$status" "the first oversized reply must remain non-blocking"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' "the first oversized reply did not warn"
  out=$(printf '%s' "$payload_a" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' "an immediately repeated reply warned twice"

  # A different session's oversized reply must not evict the first identity.
  out=$(printf '%s' "$payload_b" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_contains "$out" 'CAPTAIN COMMS WARNING' "a later distinct oversized reply did not warn"
  out=$(printf '%s' "$payload_a" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' \
    "an interleaved session evicted the first identity and warned about that reply a second time"
  out=$(printf '%s' "$payload_b" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' "the interleaved session's own reply warned twice"
  pass "fm-turnend-guard: interleaved sessions each keep their own warned identity"
}

test_captain_reply_warning_fails_open_on_malformed_dedup_state() {
  local dir oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-malformed-state")
  oversized=$(reply_with_lines 13)
  payload=$(jq -cn --arg reply "$oversized" \
    '{stop_hook_active:false,session_id:"session-m",fm_reply_text:$reply,fm_reply_id:"M1",fm_captain_facing:true}')
  # The record is guard-owned persisted state; a truncated or garbled file must
  # not suppress every future warning.
  printf 'not-a-record\nsession-m\n\n   \n' > "$dir/state/.turnend-captain-comms-warning"
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null); status=$?
  expect_code 0 "$status" "malformed warning state must remain non-blocking"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' "malformed warning state suppressed a warning"
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>/dev/null)
  assert_not_contains "$out" 'CAPTAIN COMMS WARNING' \
    "the rewritten record did not dedup the reply it had just warned about"
  pass "fm-turnend-guard: malformed warning state fails open and is repaired in place"
}

test_captain_reply_under_cap_skips_the_transcript() {
  local dir short_reply payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-under-cap-fast")
  short_reply=$(reply_with_lines 2)
  # An unreadable transcript would stand the warning down if it were parsed; a
  # reply under the cap can never warn, so it must not consult one at all.
  payload=$(jq -cn --arg reply "$short_reply" \
    '{hook_event_name:"Stop",session_id:"fast-session",prompt_id:"fast-1",transcript_path:"/nonexistent/transcript.jsonl",last_assistant_message:$reply,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "an under-cap reply must remain non-blocking"
  [ -z "$out" ] || fail "an under-cap reply consulted the transcript and produced output: $out"
  pass "fm-turnend-guard: an under-cap reply never consults the turn transcript"
}

test_captain_reply_warning_survives_a_torn_transcript_record() {
  local dir transcript oversized payload out status
  dir=$(make_primary_dir "$TMP_ROOT/captain-reply-torn-record")
  transcript="$dir/transcript.jsonl"
  oversized=$(reply_with_lines 13)
  jq -cn --arg text 'Please report the result.' \
    '{type:"user",uuid:"torn-user-1",message:{role:"user",content:$text}}' > "$transcript"
  # The live session appends to this file while the hook reads it, so a torn
  # trailing record must not discard every valid record beside it.
  printf '%s\n' '{"type":"assistant","uuid":"a1","message":{"role":"assist' >> "$transcript"
  payload=$(jq -cn --arg transcript "$transcript" --arg reply "$oversized" \
    '{hook_event_name:"Stop",session_id:"torn-session",prompt_id:"torn-1",transcript_path:$transcript,last_assistant_message:$reply,stop_hook_active:false}')
  out=$(printf '%s' "$payload" | FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "a torn transcript record must remain non-blocking"
  assert_contains "$out" 'CAPTAIN COMMS WARNING' \
    "one unreadable transcript record discarded every valid record beside it"
  pass "fm-turnend-guard: a torn transcript record does not discard the readable ones"
}

test_opencode_plugin_recovers_supervision_despite_a_hung_toast() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/opencode-hung-toast")
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"systemMessage":"FIRSTMATE CAPTAIN COMMS WARNING: synthetic oversized reply","kind":"captain-comms-warning"}'
printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n' >&2
exit 2
SH
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  # The toast is a TUI surface with no headless equivalent, so a request that
  # never settles must not be able to swallow the supervision recovery prompt.
  out=$(NODE_NO_WARNINGS=1 PLUGIN="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" \
    WORKTREE="$dir" node 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let promptText = "";
const client = {
  session: { promptAsync: async (request) => { promptText = request.body.parts[0].text; } },
  tui: { showToast: () => new Promise(() => {}) },
};
const hooks = await mod.FmPrimaryTurnendGuard({ client, directory: process.env.WORKTREE, worktree: process.env.WORKTREE });
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "s1" } } });
if (!promptText.includes("TURN WOULD END BLIND")) {
  throw new Error(`a hung advisory display swallowed the supervision recovery prompt: ${promptText}`);
}
EOF
); status=$?
  expect_code 0 "$status" "a hung advisory display must not block supervision recovery"
  [ -z "$out" ] || fail "OpenCode hung-toast test printed output: $out"
  pass ".opencode primary plugin: supervision recovery never waits on the advisory display"
}

# --- --claude cooperative mode -----------------------------------------------
# In --claude mode the guard ignores stop_hook_active (Claude marks every stop
# after ANY stop-hook continuation true, including asyncRewake rewake turns) and
# cooperates with the Stop-owned auto-arm instead: allow on health, live owner
# claim, or a fresh rewake epoch; bounded re-block only when none materialize.

run_hook_claude() {
  local dir=$1 stop_active=$2 home
  home=$(cd "$dir" && pwd)
  printf '{"stop_hook_active":%s,"session_id":"sess-claude-mode"}' "$stop_active" | CLAUDECODE=1 FM_HOME="$home" bash "$dir/bin/fm-turnend-guard.sh" --claude 2>&1
}

seed_claude_failure() {
  local dir=$1 outcome=${2:-failed-suppressed}
  : > "$dir/state/.claude-autoarm-failure-notified"
  printf 'epoch=3 owner_pid=999 outcome=%s updated_at=1\n' "$outcome" > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
}

seed_claude_budget() {
  local dir=$1 count=$2 epoch=${3:-2}
  printf 'session=sess-claude-mode\ncount=%s\nepoch=%s\n' "$count" "$epoch" > "$dir/state/.turnend-claude-blocks"
}

record_autoarm_owner() {
  local dir=$1 pid=$2
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$pid" > "$dir/state/.claude-autoarm.lock/pid"
  printf 'autoarm\n' > "$dir/state/.claude-autoarm.lock/role"
}

install_integrated_autoarm() {
  local dir=$1
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  ln -s /bin/bash "$dir/fake-claude"
}

run_integrated_autoarm() {
  local dir=$1 home
  home=$(cd "$dir" && pwd)
  # shellcheck disable=SC2016 # the fake harness expands FM_HOME inside its child shell.
  printf '{"session_id":"sess-claude-mode","stop_hook_active":false}\n' \
    | FM_HOME="$home" "$dir/fake-claude" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1
}

write_integrated_failed_arm() {
  local dir=$1
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: FAILED - persistent fixture failure\n'
exit 1
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# The 2026-07-21 incident regression: after a spent forced continuation the old
# one-shot loop guard ALLOWED a blind stop (stop_hook_active=true) while the
# watcher was already dead. In --claude mode the guard must re-block instead.
test_hook_claude_mode_reblocks_stop_hook_active_when_unhealthy() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-reblock")
  : > "$dir/state/task1.meta"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  expect_code 2 "$status" "--claude mode must re-block a stop_hook_active=true stop while unhealthy with no auto-arm claim"
  assert_contains "$out" "TURN WOULD END BLIND" "--claude re-block must carry the blind-turn banner"
  assert_contains "$out" "Stop-owned auto-arm did not claim" "--claude re-block must explain the missing auto-arm claim"
  pass "fm-turnend-guard --claude: re-blocks a loop-guarded stop while unhealthy and unclaimed (incident regression)"
}

test_hook_claude_mode_reblocks_x_mode_without_tasks() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-x-mode")
  : > "$dir/state/x-watch.check.sh"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  expect_code 2 "$status" "--claude mode must re-block an X-mode-only stop when no auto-arm claims recovery"
  assert_contains "$out" "X-mode relay polling needs supervision" "--claude X-mode re-block must name the active supervision need"
  [ -f "$dir/state/.turnend-claude-blocks" ] || fail "--claude X-mode re-block must consume the shared block budget"
  pass "fm-turnend-guard --claude: X-mode-only homes re-block when auto-arm recovery is absent"
}

test_hook_claude_mode_allows_when_autoarm_owner_alive() {
  local dir pid out out2 status status2 count count2
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-owner")
  : > "$dir/state/task1.meta"
  seed_claude_failure "$dir"
  seed_claude_budget "$dir" 3
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  out=$(run_hook_claude "$dir" false); status=$?
  count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")
  out2=$(run_hook_claude "$dir" false); status2=$?
  count2=$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "--claude mode must allow when the auto-arm owner process is alive"
  expect_code 0 "$status2" "--claude mode must keep allowing the same live auto-arm epoch"
  [ -z "$out" ] || fail "--claude owner-claimed allow produced output: $out"
  [ -z "$out2" ] || fail "repeated same-owner allow produced output: $out2"
  [ "$count" = 4 ] || fail "new live auto-arm epoch did not advance failure progression from 3 to 4: $count"
  [ "$count2" = 4 ] || fail "repeated observation advanced the same auto-arm epoch twice: $count2"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "live auto-arm owner cleared the failure episode"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "live automatic continuation emitted the attended fail-open alarm"
  pass "fm-turnend-guard --claude: a live arming epoch advances once and repeated observation is idempotent"
}

test_hook_claude_mode_repeated_failed_to_arming_interleavings_reach_fail_open() {
  local dir out status pid i count epoch
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-arming-interleavings")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.claude-autoarm-failure-notified"
  printf 'epoch=3 owner_pid=999 outcome=failed updated_at=%s\n' "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  out=$(run_hook_claude "$dir" true); status=$?
  expect_code 0 "$status" "the first verified failed epoch must own its automatic handoff"

  epoch=3
  for i in 1 2 3 4; do
    epoch=$((epoch + 1))
    sleep 60 &
    pid=$!
    record_autoarm_owner "$dir" "$pid"
    printf 'epoch=%s owner_pid=%s outcome=arming updated_at=%s\n' "$epoch" "$pid" "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
    out=$(run_hook_claude "$dir" true); status=$?
    expect_code 0 "$status" "active arming epoch $i must own its Stop while advancing the failure budget"
    count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")
    [ "$count" = "$i" ] || fail "arming epoch $i produced non-monotonic count $count"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf "$dir/state/.claude-autoarm.lock"
    epoch=$((epoch + 1))
    printf 'epoch=%s owner_pid=999 outcome=failed-suppressed updated_at=%s\n' "$epoch" "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  done

  out=$(run_hook_claude "$dir" true); status=$?
  expect_code 0 "$status" "repeated failed-to-arming interleavings must reach terminal fail-open"
  assert_contains "$out" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "arming interleavings stalled before the bounded fail-open"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "arming interleavings did not consume the one-time alarm"
  pass "fm-turnend-guard --claude: repeated failed-to-arming races make bounded monotonic progress"
}

test_hook_claude_mode_terminal_boundary_excludes_starting_owner() {
  local dir fakebin ready release once guard_out guard_status auto_out auto_status guard_pid
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-terminal-boundary")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.claude-autoarm-failure-notified"
  printf 'epoch=3 owner_pid=999 outcome=failed-suppressed updated_at=%s\n' "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  seed_claude_budget "$dir" 4 3
  install_integrated_autoarm "$dir"
  write_integrated_failed_arm "$dir"
  fakebin="$dir/fakebin"
  ready="$dir/terminal-ready"
  release="$dir/terminal-release"
  once="$dir/terminal-once"
  guard_out="$dir/guard.out"
  guard_status="$dir/guard.status"
  mkdir -p "$fakebin"
  mkfifo "$ready" "$release"
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "$FM_TERMINAL_ROLE_PATH" ] \
  && [ "$(/bin/cat "$1" 2>/dev/null || true)" = terminal-check ] \
  && (set -C; : > "$FM_TERMINAL_ONCE") 2>/dev/null; then
  printf 'ready\n' > "$FM_TERMINAL_READY"
  IFS= read -r _ < "$FM_TERMINAL_RELEASE"
fi
exec /bin/cat "$@"
SH
  chmod +x "$fakebin/cat"
  (
    printf '{"stop_hook_active":true,"session_id":"sess-claude-mode"}' \
      | PATH="$fakebin:$PATH" \
        FM_TERMINAL_ROLE_PATH="$dir/state/.claude-autoarm.lock/role" \
        FM_TERMINAL_READY="$ready" \
        FM_TERMINAL_RELEASE="$release" \
        FM_TERMINAL_ONCE="$once" \
        CLAUDECODE=1 FM_HOME="$dir" bash "$dir/bin/fm-turnend-guard.sh" --claude \
          > "$guard_out" 2>&1
    printf '%s\n' "$?" > "$guard_status"
  ) &
  guard_pid=$!
  IFS= read -r _ < "$ready"
  auto_out=$(run_integrated_autoarm "$dir"); auto_status=$?
  printf 'release\n' > "$release"
  wait "$guard_pid"
  expect_code 0 "$auto_status" "an owner starting inside the terminal window must lose the existing owner boundary"
  [ -z "$auto_out" ] || fail "excluded terminal-window owner produced output: $auto_out"
  assert_absent "$dir/state/arm-ran" "excluded terminal-window owner started an arm cycle"
  expect_code 0 "$(cat "$guard_status")" "terminal boundary guard must complete without deadlock"
  assert_contains "$(cat "$guard_out")" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "terminal boundary did not produce the one-time alarm"
  assert_absent "$dir/state/.claude-autoarm.lock" "terminal boundary left its owner lock behind"
  pass "fm-turnend-guard --claude: terminal owner boundary excludes a concurrent start without deadlock"
}

test_hook_claude_mode_allows_on_fresh_rewake_epoch() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-epoch")
  : > "$dir/state/task1.meta"
  printf 'epoch=3 owner_pid=999 outcome=rewake updated_at=%s\n' "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  out=$(run_hook_claude "$dir" true); status=$?
  expect_code 0 "$status" "--claude mode must allow the stop whose rewake the auto-arm already owns"
  [ -z "$out" ] || fail "--claude rewake-epoch allow produced output: $out"
  pass "fm-turnend-guard --claude: fresh rewake epoch prevents a duplicate continuation for the same event"
}

test_hook_claude_mode_preserves_fresh_failed_progression() {
  local dir out status count
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-failed-epoch")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.claude-autoarm-failure-notified"
  printf 'epoch=3 owner_pid=999 outcome=failed updated_at=%s\n' "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  out=$(run_hook_claude "$dir" true); status=$?
  expect_code 0 "$status" "the first fresh failed epoch must count as its automatic continuation"
  [ -z "$out" ] || fail "fresh failed-epoch allow produced output: $out"
  assert_present "$dir/state/.turnend-claude-blocks" "fresh failed epoch did not preserve bounded progression"
  count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")
  [ "$count" = 0 ] || fail "the owned first failed epoch must not consume a blocked-stop count, got $count"
  printf 'epoch=4 owner_pid=999 outcome=failed-suppressed updated_at=%s\n' "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  out=$(run_hook_claude "$dir" true); status=$?
  expect_code 2 "$status" "a later fresh failed epoch must consume the bounded progression"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "fresh failure progression emitted the attended fail-open alarm too early"
  count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")
  [ "$count" = 1 ] || fail "the later failed epoch must advance the blocked-stop count, got $count"
  pass "fm-turnend-guard --claude: fresh failed epochs preserve and advance monotonic fail-open progression"
}

test_hook_claude_mode_integrated_monotonic_fail_open() {
  local dir out status guard_out guard_status i pid identity count
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-integrated-fail-open")
  : > "$dir/state/task1.meta"
  install_integrated_autoarm "$dir"
  write_integrated_failed_arm "$dir"

  out=$(run_integrated_autoarm "$dir"); status=$?
  expect_code 2 "$status" "the first exhausted auto-arm cycle must emit its one failure notice"
  assert_contains "$out" "automatic supervision mechanism is broken" "the first integrated failure notice is missing"
  guard_out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" true); guard_status=$?
  expect_code 0 "$guard_status" "the first failed epoch must own its Stop handoff"
  count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")
  [ "$count" = 0 ] || fail "the first owned failure epoch must preserve a zero blocked-stop count, got $count"

  for i in 1 2 3 4; do
    out=$(run_integrated_autoarm "$dir"); status=$?
    expect_code 2 "$status" "failed epoch $i must retain the automatic retry handoff"
    [ -z "$out" ] || fail "failed epoch $i repeated the operator notice: $out"
    guard_out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" true); guard_status=$?
    if [ "$i" -lt 4 ]; then
      expect_code 2 "$guard_status" "failed epoch $i must consume a bounded blind-stop block"
      assert_not_contains "$guard_out" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "fail-open fired before the bounded progression ended"
    else
      expect_code 0 "$guard_status" "the bounded failure progression must reach the attended fail-open"
      assert_contains "$guard_out" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "the integrated fail-open alarm is missing"
      assert_present "$dir/state/.claude-autoarm-failure-alarmed" "the integrated fail-open did not consume its episode alarm"
    fi
  done

  out=$(run_integrated_autoarm "$dir"); status=$?
  expect_code 0 "$status" "the auto-arm must not re-trigger continuation after the final fail-open"
  [ -z "$out" ] || fail "post-fail-open auto-arm produced continuation output: $out"
  guard_out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" true); guard_status=$?
  expect_code 2 "$guard_status" "a later unhealthy stop in the same episode must remain attended"
  assert_not_contains "$guard_out" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "the attended alarm repeated in the same episode"

  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify the positive recovery watcher"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_integrated_autoarm "$dir"); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir/state/.watch.lock"
  expect_code 0 "$status" "positive watcher recovery must make the auto-arm silent"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "positive recovery left the failure notice marker"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "positive recovery left the attended alarm marker"
  assert_absent "$dir/state/.turnend-claude-blocks" "positive recovery left the bounded block budget"
  guard_out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" false); guard_status=$?
  expect_code 2 "$guard_status" "a guard after one-shot recovery must start a fresh failure budget"
  count=$(sed -n '2s/^count=//p' "$dir/state/.turnend-claude-blocks")
  [ "$count" = 1 ] || fail "the independent post-recovery failure must start at count 1, got $count"

  out=$(run_integrated_autoarm "$dir"); status=$?
  expect_code 2 "$status" "a later failure after positive recovery must start a new episode"
  assert_contains "$out" "automatic supervision mechanism is broken" "the new failure episode notice was suppressed"
  pass "fm-turnend-guard --claude: integrated fresh failures reach one bounded fail-open, stop continuation, and reset on recovery"
}

test_hook_claude_mode_recovery_contention_is_not_ordinary_allow() {
  local dir pid identity holder out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-recovery-contention")
  : > "$dir/state/task1.meta"
  seed_claude_budget "$dir" 3
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify recovery-contention watcher"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.turnend-claude-blocks.lock"
  printf '%s\n' "$holder" > "$dir/state/.turnend-claude-blocks.lock/pid"
  out=$(run_hook_claude "$dir" false); status=$?
  expect_code 2 "$status" "a healthy guard must continue when the episode reset lock is busy"
  [ -z "$out" ] || fail "guard recovery contention produced output: $out"
  assert_present "$dir/state/.turnend-claude-blocks" "guard contention partially cleared the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "guard contention partially cleared the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "guard contention partially cleared the attended alarm"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(run_hook_claude "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "the healthy guard must allow after completing the episode reset"
  assert_absent "$dir/state/.turnend-claude-blocks" "successful guard reset left the block budget"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "successful guard reset left the failure notice"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "successful guard reset left the attended alarm"
  pass "fm-turnend-guard --claude: reset contention preserves all episode state until retry"
}

test_hook_claude_mode_concurrent_recovery_resets_are_idempotent() {
  local dir pid identity auto_pid guard_pid auto_status guard_status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-concurrent-recovery")
  : > "$dir/state/task1.meta"
  install_integrated_autoarm "$dir"
  write_integrated_failed_arm "$dir"
  seed_claude_budget "$dir" 3
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify concurrent recovery watcher"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  (run_integrated_autoarm "$dir" > "$dir/auto.out"; printf '%s\n' "$?" > "$dir/auto.status") &
  auto_pid=$!
  (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" false > "$dir/guard.out"; printf '%s\n' "$?" > "$dir/guard.status") &
  guard_pid=$!
  wait "$auto_pid"
  wait "$guard_pid"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  auto_status=$(cat "$dir/auto.status")
  guard_status=$(cat "$dir/guard.status")
  case "$auto_status:$guard_status" in
    0:0|0:2|2:0) : ;;
    *) fail "concurrent reset callers returned unsafe statuses auto=$auto_status guard=$guard_status" ;;
  esac
  assert_absent "$dir/state/.turnend-claude-blocks" "concurrent recovery left the block budget"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "concurrent recovery left the failure notice"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "concurrent recovery left the attended alarm"
  assert_absent "$dir/state/.claude-autoarm.lock" "concurrent recovery left the owner lock"
  assert_absent "$dir/state/.turnend-claude-blocks.lock" "concurrent recovery left the budget lock"
  pass "fm-turnend-guard --claude: concurrent auto-arm and guard resets are idempotent and deadlock-free"
}

test_hook_claude_mode_stale_rewake_epoch_blocks() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-stale-epoch")
  : > "$dir/state/task1.meta"
  printf 'epoch=3 owner_pid=999 outcome=rewake updated_at=1\n' > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  expect_code 2 "$status" "--claude mode must not treat an ancient rewake epoch as this event's recovery"
  pass "fm-turnend-guard --claude: stale rewake epoch does not allow a blind stop"
}

test_hook_claude_mode_budget_without_verified_failure_keeps_blocking() {
  local dir out status i
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-budget")
  : > "$dir/state/task1.meta"
  for i in 1 2 3 4; do
    out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" false); status=$?
    expect_code 2 "$status" "--claude block $i must exit 2 within the budget"
  done
  assert_not_contains "$out" 'systemMessage' "budget exhaustion without verified auto-arm failure must not fail open"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "unverified budget exhaustion recorded an attended alarm"
  pass "fm-turnend-guard --claude: budget exhaustion alone cannot permit a blind stop"
}

test_hook_claude_mode_verified_failure_alarm_is_loud_and_once() {
  local dir out out2 status status2
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-verified-alarm")
  : > "$dir/state/task1.meta"
  seed_claude_failure "$dir"
  seed_claude_budget "$dir" 3
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" true); status=$?
  expect_code 0 "$status" "verified failure with exhausted budget must take the bounded attended fail-open"
  assert_contains "$out" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "bounded fail-open alarm was not unmistakable"
  assert_contains "$out" 'Keep this session attended' "bounded fail-open alarm omitted the attended-session action"
  assert_contains "$out" 'diagnose the automatic Stop-hook and watcher startup' "bounded fail-open alarm omitted automatic-mechanism diagnosis"
  assert_not_contains "$out" 'fm-watch-arm.sh' "bounded fail-open alarm assigned a manual watcher launch"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "bounded fail-open did not consume the episode alarm"
  out2=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" true); status2=$?
  expect_code 2 "$status2" "a consumed attended alarm must make later unhealthy stops block again"
  assert_not_contains "$out2" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "attended failure alarm repeated in one episode"
  pass "fm-turnend-guard --claude: verified fail-open is loud, bounded, attended, and non-repeating"
}

test_hook_claude_mode_fail_open_requires_notice_and_failure_epoch() {
  local no_notice notice_only out status
  no_notice=$(make_primary_dir "$TMP_ROOT/hook-claude-alarm-no-notice")
  : > "$no_notice/state/task1.meta"
  printf 'epoch=3 owner_pid=999 outcome=failed-suppressed updated_at=1\n' > "$no_notice/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$no_notice/state/.claude-autoarm-epoch"
  seed_claude_budget "$no_notice" 3
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$no_notice" true); status=$?
  expect_code 2 "$status" "an exhausted failure epoch without the consumed notice must remain blocking"

  notice_only=$(make_primary_dir "$TMP_ROOT/hook-claude-alarm-no-epoch")
  : > "$notice_only/state/task1.meta"
  : > "$notice_only/state/.claude-autoarm-failure-notified"
  seed_claude_budget "$notice_only" 3
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$notice_only" true); status=$?
  expect_code 2 "$status" "a consumed notice without an exhausted failure epoch must remain blocking"
  pass "fm-turnend-guard --claude: fail-open requires both exhausted retries and consumed notice"
}

test_hook_claude_mode_away_mode_never_uses_stop_autoarm_fail_open() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-alarm-afk")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.afk"
  seed_claude_failure "$dir"
  seed_claude_budget "$dir" 3
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" true); status=$?
  expect_code 2 "$status" "away mode must not use a stale Stop-autoarm failure to fail open"
  assert_contains "$out" 'Away mode owns watcher supervision' "away-mode block lost its daemon ownership guidance"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "away mode consumed the Stop-autoarm attended alarm"
  pass "fm-turnend-guard --claude: away ownership excludes the Stop-autoarm fail-open"
}

test_hook_claude_mode_allow_resets_budget() {
  local dir pid identity out status
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-reset")
  : > "$dir/state/task1.meta"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" false); status=$?
  expect_code 2 "$status" "first --claude block must exit 2"
  [ -f "$dir/state/.turnend-claude-blocks" ] || fail "--claude block must record the consecutive-block budget"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "could not identify live watcher holder"
  }
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_hook_claude "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$dir/state/.watch.lock"
  expect_code 0 "$status" "--claude must allow once the watcher is healthy again"
  [ ! -f "$dir/state/.turnend-claude-blocks" ] || fail "--claude allow must reset the consecutive-block budget"
  [ ! -f "$dir/state/.claude-autoarm-failure-notified" ] || fail "positive watcher recovery must reset the failure notice"
  [ ! -f "$dir/state/.claude-autoarm-failure-alarmed" ] || fail "positive watcher recovery must reset the attended alarm"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_hook_claude "$dir" false); status=$?
  expect_code 2 "$status" "a later unhealthy chain must re-block from a fresh budget"
  pass "fm-turnend-guard --claude: positive watcher recovery resets failure episode state"
}

test_hook_claude_mode_waits_for_late_claim() {
  local dir helper out status holder
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-wait")
  : > "$dir/state/task1.meta"
  (
    sleep 0.4
    sleep 60 &
    record_autoarm_owner "$dir" $!
    printf '%s\n' $! > "$dir/holder.pid"
    wait
  ) &
  helper=$!
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=3000 run_hook_claude "$dir" false); status=$?
  holder=$(cat "$dir/holder.pid" 2>/dev/null || true)
  kill "$holder" 2>/dev/null || true
  kill "$helper" 2>/dev/null || true
  wait "$helper" 2>/dev/null || true
  expect_code 0 "$status" "--claude must wait briefly for a late auto-arm claim instead of forcing a continuation"
  [ -z "$out" ] || fail "--claude late-claim wait produced output: $out"
  pass "fm-turnend-guard --claude: bounded claim wait avoids a token-consuming forced continuation"
}

test_hook_claude_mode_secondmate_reblocks_like_primary() {
  local dir pid out status
  dir=$(make_secondmate_dir "$TMP_ROOT/hook-claude-sm-reblock")
  : > "$dir/state/task1.meta"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  expect_code 2 "$status" "--claude mode must re-block in a marked secondmate home exactly like the main primary"
  assert_contains "$out" "TURN WOULD END BLIND" "--claude secondmate re-block must carry the blind-turn banner"
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  out=$(run_hook_claude "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "--claude mode must allow a claimed secondmate home"
  pass "fm-turnend-guard --claude: secondmate home re-blocks unclaimed and allows auto-arm-claimed stops"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_predicate_queue_pending_flag
test_predicate_x_mode_needs_supervision
test_predicate_source_needs_supervision
test_hook_silent_when_no_work_in_flight
test_hook_blocks_when_fresh_beacon_has_no_live_lock
test_hook_blocks_source_only_home
test_hook_blocks_when_dead_lock_has_fresh_beacon
test_hook_silent_with_live_lock_and_fresh_beacon
test_hook_non_claude_health_ignores_claude_budget_contention
test_hook_blocks_with_live_lock_and_stale_beacon
test_hook_blocks_when_unhealthy_in_primary
test_hook_blocks_from_fm_home_state
test_hook_x_mode_reason_sources_cadence
test_hook_x_mode_only_blocks_in_default_mode
test_hook_ignores_repo_state_when_fm_home_set
test_hook_uses_state_override
test_hook_loop_guard_allows_retry
test_hook_blocks_in_secondmate_own_home
test_hook_silent_in_idle_secondmate_home
test_hook_secondmate_loop_guard_allows_retry
test_hook_secondmate_reinvoke_recovery_loop
test_hook_silent_in_secondmate_child_worktree
test_hook_blocks_in_treehouse_leased_secondmate_home
test_hook_exempts_linked_worktree_with_stray_marker
test_hook_exempts_linked_worktree_with_non_ascii_marker
test_hook_silent_in_crewmate_worktree
test_hook_silent_without_jq
test_hook_silent_without_stdin
test_hook_runs_fast
test_grok_adapter_forces_one_resume_when_unhealthy
test_grok_adapter_loop_guard_skips_resume
test_grok_adapter_native_false_blocks_without_resume
test_grok_adapter_native_true_allows_without_resume
test_grok_adapter_snake_case_native_and_camel_precedence
test_grok_adapter_invalid_inputs_start_neither_path
test_grok_adapter_missing_jq_and_no_supervision_allow
test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root
test_codex_hook_ignores_nested_git_root_guard
test_opencode_plugin_anchors_guard_to_worktree
test_opencode_plugin_scopes_supervision_skip_to_session
test_pi_extension_injects_once_per_logical_agent_run
test_pi_extension_retries_after_followup_delivery_failure
test_captain_reply_warning_boundary_and_lifetime
test_captain_reply_warning_operational_and_failure_fail_open
test_codex_shaped_payload_reaches_the_shared_warning_predicate
test_codex_registration_keeps_stop_hook_stdout_empty
test_grok_native_delegation_keeps_stop_hook_stdout_empty
test_opencode_plugin_warns_without_continuation
test_pi_extension_warns_without_followup
test_captain_reply_warning_survives_a_blocking_supervision_verdict
test_captain_reply_warning_envelope_declares_its_kind
test_captain_reply_falls_back_to_the_transcript_reply
test_opencode_plugin_measures_the_whole_multipart_reply
test_opencode_plugin_keeps_advisory_diagnostics_out_of_the_continuation
test_captain_reply_warning_and_terminal_fail_open_share_one_envelope
test_captain_reply_warning_survives_an_undeliverable_banner_less_block
test_grok_legacy_healthy_turn_keeps_the_warning_eligible
test_captain_reply_warning_fails_open_on_a_broken_hasher
test_captain_reply_warning_survives_an_interleaved_session
test_captain_reply_warning_fails_open_on_malformed_dedup_state
test_captain_reply_under_cap_skips_the_transcript
test_captain_reply_warning_survives_a_torn_transcript_record
test_opencode_plugin_recovers_supervision_despite_a_hung_toast
test_captain_reply_identity_uses_the_payload_turn_id
test_declared_stdout_sink_none_keeps_the_turn_end_silent
test_block_banner_marks_every_reason_line
test_grok_legacy_resume_carries_the_coincident_warning
test_hook_claude_mode_reblocks_stop_hook_active_when_unhealthy
test_hook_claude_mode_reblocks_x_mode_without_tasks
test_hook_claude_mode_allows_when_autoarm_owner_alive
test_hook_claude_mode_repeated_failed_to_arming_interleavings_reach_fail_open
test_hook_claude_mode_terminal_boundary_excludes_starting_owner
test_hook_claude_mode_allows_on_fresh_rewake_epoch
test_hook_claude_mode_preserves_fresh_failed_progression
test_hook_claude_mode_integrated_monotonic_fail_open
test_hook_claude_mode_recovery_contention_is_not_ordinary_allow
test_hook_claude_mode_concurrent_recovery_resets_are_idempotent
test_hook_claude_mode_stale_rewake_epoch_blocks
test_hook_claude_mode_budget_without_verified_failure_keeps_blocking
test_hook_claude_mode_verified_failure_alarm_is_loud_and_once
test_hook_claude_mode_fail_open_requires_notice_and_failure_epoch
test_hook_claude_mode_away_mode_never_uses_stop_autoarm_fail_open
test_hook_claude_mode_allow_resets_budget
test_hook_claude_mode_waits_for_late_claim
test_hook_claude_mode_secondmate_reblocks_like_primary

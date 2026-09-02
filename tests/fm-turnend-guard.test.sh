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
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
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

# Grok loads Claude-compatible settings, so a TRACKED .claude/settings.json entry
# that also has a .grok/hooks/ counterpart must refuse to run under Grok, or the
# home gets a duplicate path. The regression this pins: the guard once tested
# GROK_AGENT alone, which a grok 1.0.0 HOOK process does not carry, so the
# Claude-only Stop auto-arm ran synchronously under Grok, foregrounded the
# watcher, and wedged the Grok turn for its declared 28800-second timeout.
#
# bin/fm-subagent-pretool-check.sh is the deliberate exception: Grok has no
# counterpart registration, so guarding it would REMOVE the guard from Grok
# rather than deduplicate it (docs/subagent-guard.md "Known residual gap").
# It is asserted to stay unguarded so the exception cannot be closed silently.
test_tracked_claude_entries_inert_under_grok() {
  local dir cmd script target guarded=0 unguarded=0
  command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
  dir="$TMP_ROOT/claude-entries-grok-inert"
  mkdir -p "$dir/bin"
  for script in fm-turnend-guard.sh fm-claude-stop-autoarm.sh fm-sessionstart-run.sh \
    fm-arm-pretool-check.sh fm-cd-pretool-check.sh fm-subagent-pretool-check.sh; do
    printf '#!/usr/bin/env bash\nprintf ran >> %q\n' "$dir/invoked" > "$dir/bin/$script"
    chmod +x "$dir/bin/$script"
  done

  # Runs one tracked command string and reports whether it reached its script.
  ran_under() {
    rm -f "$dir/invoked"
    env "$@" CLAUDE_PROJECT_DIR="$dir" bash -c "$cmd" </dev/null >/dev/null 2>&1
    [ -e "$dir/invoked" ]
  }

  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    target=$(printf '%s\n' "$cmd" | sed -n 's|.*/bin/\([a-z0-9-]*\.sh\).*|\1|p')
    [ -n "$target" ] || fail "could not identify the target script of tracked entry: $cmd"

    # Native Claude: EVERY tracked entry must still reach its script, or a guard
    # has silently disarmed Claude's own protection.
    ran_under -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
      -u GROK_WORKSPACE_ROOT \
      || fail "tracked entry for $target did not run under a native Claude environment"

    if [ "$target" = fm-subagent-pretool-check.sh ]; then
      unguarded=$((unguarded + 1))
      ran_under -u GROK_AGENT GROK_HOOK_EVENT=pre_tool_use GROK_SESSION_ID=grok-test-session \
        || fail "the documented $target exception must stay unguarded; Grok has no counterpart to fall back to"
      continue
    fi

    guarded=$((guarded + 1))
    # grok 1.0.0 hook process: hook markers present, GROK_AGENT absent.
    ! ran_under -u GROK_AGENT GROK_HOOK_EVENT=stop \
      GROK_HOOK_NAME='project/settings:stop[0].hooks[0]' \
      GROK_SESSION_ID=grok-test-session GROK_WORKSPACE_ROOT="$dir" \
      || fail "tracked entry for $target ran under a grok 1.0.0 hook environment"
    # grok 0.2.73 child/tool process: GROK_AGENT present, hook markers absent.
    ! ran_under -u GROK_HOOK_EVENT -u GROK_HOOK_NAME GROK_AGENT=1 \
      || fail "tracked entry for $target ran under a legacy GROK_AGENT environment"
  done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/.claude/settings.json")

  [ "$guarded" -eq 5 ] || fail "expected 5 grok-guarded tracked entries, saw $guarded"
  [ "$unguarded" -eq 1 ] || fail "expected 1 documented unguarded tracked entry, saw $unguarded"
  pass "tracked .claude/settings.json entries: $guarded inert under grok, the documented subagent exception still armed, all live under Claude"
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
printf 'guard-fired\n' >&2
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
printf 'logical-run guard fired\n' >&2
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
if (handlers.has("turn_end")) throw new Error("guard still treats internal Pi turns as logical runs");
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
printf 'delivery failure guard\n' >&2
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

# --- reply recovery: detect + recover from a turn that settled without ever
# producing a synthesized reply (Pi's own prompt() has no atomic check-and-set
# between reading isStreaming and committing to a new run, so a watcher wake
# delivered through pi.sendUserMessage can race a concurrently-submitted
# captain message; docs/watcher-continuity.md "Turn-settle input and reply
# recovery").
# Fixtures give bin/fm-turnend-guard.sh a healthy (exit 0) verdict so every
# case here exercises the reply-recovery branch, never the supervision one.

install_pi_reply_recovery_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[ -z "${FM_GUARD_LOG:-}" ] || printf 'run\n' >> "$FM_GUARD_LOG"
delay="${FM_HOME:-}/state/.test-guard-delay"
[ -f "$delay" ] && sleep "$(cat "$delay")"
# Healthy by default; a test that needs the supervision branch writes the
# desired exit code into state/.test-guard-verdict beforehand.
verdict="${FM_HOME:-}/state/.test-guard-verdict"
[ -f "$verdict" ] || exit 0
printf 'supervision is unhealthy\n' >&2
exit "$(cat "$verdict")"
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-arm-pretool-check.sh"
}

test_pi_reply_recovery_nudges_once_for_a_dangling_tool_call() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-dangling-root"
  home="$TMP_ROOT/pi-reply-dangling-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts.push({ message, options });
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");
if (!settled) throw new Error("agent_settled handler was not registered");

// Last conversational entry is an assistant message with a tool call and no
// text: the visible signature of the raced turn (a dangling tool call, e.g.
// bin/fm-wake-drain.sh, left as the final transcript entry).
const ctx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], timestamp: 0 } },
    ],
  },
};
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`expected exactly one recovery follow-up, got ${prompts.length}`);
const [{ message, options }] = prompts;
if (!message.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`untyped operational prompt: ${message}`);
if (!message.includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`unexpected prompt: ${message}`);
if (options?.deliverAs !== "followUp") throw new Error("recovery prompt was not a follow-up");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must nudge once for a dangling tool call with no reply"
  [ -z "$out" ] || fail "Pi reply-recovery dangling-tool-call test printed output: $out"
  pass ".pi primary extension: reply recovery nudges once for a dangling tool call"
}

test_pi_reply_recovery_stays_silent_for_a_healthy_reply() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-healthy-root"
  home="$TMP_ROOT/pi-reply-healthy-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    prompts += 1;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

const ctx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "here is the answer" }], timestamp: 0 } },
    ],
  },
};
await settled({ type: "agent_settled" }, ctx);
if (prompts !== 0) throw new Error(`expected no recovery follow-up for a healthy reply, got ${prompts}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must stay silent when the last turn produced a genuine reply"
  [ -z "$out" ] || fail "Pi reply-recovery healthy-reply test printed output: $out"
  pass ".pi primary extension: reply recovery stays silent for a healthy reply"
}

test_pi_reply_recovery_is_idempotent_and_bounded() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-idempotent-root"
  home="$TMP_ROOT/pi-reply-idempotent-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

const stuckCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], timestamp: 0 } },
    ],
  },
};

// Settle 1: unanswered -> one recovery follow-up (attempt 1/3).
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 1) throw new Error(`settle 1: expected 1 prompt, got ${prompts.length}`);

// Settle 2: the latch absorbs the settle produced by that same follow-up
// turn itself - repetition of the identical stuck state must not create a
// second turn here, even though the trailing entries are unchanged.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 1) throw new Error(`settle 2 (latch-absorbed): expected still 1 prompt, got ${prompts.length}`);

// Settle 3: still stuck, latch already consumed -> attempt 2/3.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 2) throw new Error(`settle 3: expected 2 prompts, got ${prompts.length}`);

// Settle 4: latch-absorbed again.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 2) throw new Error(`settle 4 (latch-absorbed): expected still 2 prompts, got ${prompts.length}`);

// Settle 5: still stuck -> attempt 3/3 (the configured limit).
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 3) throw new Error(`settle 5: expected 3 prompts, got ${prompts.length}`);

// Settle 6: latch-absorbed.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 3) throw new Error(`settle 6 (latch-absorbed): expected still 3 prompts, got ${prompts.length}`);

// Settle 7: attempts exhausted -> exactly one loud "gave up" notice, never a
// silent retry loop.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 4) throw new Error(`settle 7: expected the exhaustion notice (4 total), got ${prompts.length}`);
if (!prompts[3].includes("automatic recovery gave up after 3 attempts")) {
  throw new Error(`settle 7: missing exhaustion wording: ${prompts[3]}`);
}

// Settle 8: latch-absorbed (the notice was itself a follow-up turn).
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 4) throw new Error(`settle 8 (latch-absorbed): expected still 4 prompts, got ${prompts.length}`);

// Settle 9: still exhausted and still stuck -> the notice must not repeat.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 4) throw new Error(`settle 9: exhaustion notice repeated, got ${prompts.length} total`);

// A healthy settle clears both the attempt budget and the notice dedup, so a
// later, independent unanswered episode gets a fresh recovery attempt.
const healthyCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u2", parentId: null, timestamp: "t", message: { role: "user", content: "next captain input", timestamp: 0 } },
      { type: "message", id: "a2", parentId: "u2", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "answered" }], timestamp: 0 } },
    ],
  },
};
await settled({ type: "agent_settled" }, healthyCtx);
if (prompts.length !== 4) throw new Error(`healthy settle unexpectedly prompted, total ${prompts.length}`);

await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 5) throw new Error(`fresh episode after a healthy settle did not get a new attempt, total ${prompts.length}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard reply recovery must be idempotent and bounded, resetting after a healthy settle"
  [ -z "$out" ] || fail "Pi reply-recovery idempotency test printed output: $out"
  pass ".pi primary extension: reply recovery is idempotent, bounded, and resets after a healthy settle"
}

test_pi_reply_recovery_flags_an_unanswered_user_message() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-unanswered-user-root"
  home="$TMP_ROOT/pi-reply-unanswered-user-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    prompts += 1;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

// The last conversational transcript entry is a user message (a delivered
// watcher wake or a captain message) with no assistant reply at all - not
// even a dangling tool call. This is the fully-dropped case.
const ctx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", timestamp: 0 } },
    ],
  },
};
await settled({ type: "agent_settled" }, ctx);
if (prompts !== 1) throw new Error(`expected one recovery follow-up for a fully unanswered message, got ${prompts}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must nudge once when the last message got no reply at all"
  [ -z "$out" ] || fail "Pi reply-recovery unanswered-user test printed output: $out"
  pass ".pi primary extension: reply recovery flags a fully unanswered message"
}

test_pi_reply_recovery_ignores_the_session_start_digest() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-sessionstart-root"
  home="$TMP_ROOT/pi-reply-sessionstart-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    prompts += 1;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

// The session-start digest arrives as a custom_message entry (pi.sendMessage
// with a customType), not a "message" entry, and carries no reply
// expectation of its own. Nothing conversational has happened yet.
const ctx = {
  sessionManager: {
    getEntries: () => [
      { type: "custom_message", id: "c1", parentId: null, timestamp: "t", customType: "firstmate-sessionstart-nudge", content: "digest", details: {}, display: false },
    ],
  },
};
await settled({ type: "agent_settled" }, ctx);
if (prompts !== 0) throw new Error(`expected no recovery follow-up before any conversational message, got ${prompts}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must not treat the session-start digest as an unanswered message"
  [ -z "$out" ] || fail "Pi reply-recovery session-start test printed output: $out"
  pass ".pi primary extension: reply recovery ignores the session-start digest with no conversational history"
}

test_pi_reply_recovery_ignores_a_flushed_inline_bash_message() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-bash-root"
  home="$TMP_ROOT/pi-reply-bash-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    prompts += 1;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

// Pi flushes an inline `!cmd` bashExecution message into the session right
// before it emits agent_settled, so it lands after an otherwise healthy
// assistant reply. It carries no reply expectation of its own.
const ctx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "here is the answer" }], stopReason: "stop", timestamp: 0 } },
      { type: "message", id: "b1", parentId: "a1", timestamp: "t", message: { role: "bashExecution", command: "ls", output: "x", exitCode: 0, cancelled: false, truncated: false, timestamp: 0 } },
    ],
  },
};
await settled({ type: "agent_settled" }, ctx);
if (prompts !== 0) throw new Error(`a flushed inline bash message must not look unanswered, got ${prompts} prompts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must not treat a flushed inline bash message as an unanswered turn"
  [ -z "$out" ] || fail "Pi reply-recovery bash-flush test printed output: $out"
  pass ".pi primary extension: reply recovery ignores a flushed inline bash message after a healthy reply"
}

test_pi_reply_recovery_flags_a_tool_call_beside_a_text_preamble() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-preamble-root"
  home="$TMP_ROOT/pi-reply-preamble-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

// The real shape of the reproduced race: one assistant message with a short
// text preamble AND the tool call that never resolved. The preamble must not
// pass as a finished reply.
const ctx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      {
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: "t",
        message: {
          role: "assistant",
          content: [
            { type: "text", text: "Ich starte fm-wake-drain.sh." },
            { type: "toolCall", id: "tc1", name: "bash" },
          ],
          stopReason: "toolUse",
          timestamp: 0,
        },
      },
    ],
  },
};
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`expected one recovery follow-up for a preamble plus dangling tool call, got ${prompts.length}`);
if (!prompts[0].includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must flag a dangling tool call even when the same message carries a text preamble"
  [ -z "$out" ] || fail "Pi reply-recovery preamble test printed output: $out"
  pass ".pi primary extension: reply recovery flags a dangling tool call beside a text preamble"
}

test_pi_reply_recovery_never_restarts_an_aborted_turn() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-aborted-root"
  home="$TMP_ROOT/pi-reply-aborted-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    prompts += 1;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

// The captain pressed Esc mid tool call: Pi terminates the run with an empty
// assistant message carrying stopReason "aborted". That is a deliberate human
// stop and must never be auto-restarted.
const abortedCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], stopReason: "toolUse", timestamp: 0 } },
      { type: "message", id: "r1", parentId: "a1", timestamp: "t", message: { role: "toolResult", toolCallId: "tc1", toolName: "bash", content: "Operation aborted", isError: true, timestamp: 0 } },
      { type: "message", id: "a2", parentId: "r1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "" }], stopReason: "aborted", errorMessage: "Request aborted by user", timestamp: 0 } },
    ],
  },
};
await settled({ type: "agent_settled" }, abortedCtx);
await settled({ type: "agent_settled" }, abortedCtx);
if (prompts !== 0) throw new Error(`an aborted turn must never be auto-restarted, got ${prompts} prompts`);

// An error stop is not a human decision and still earns its one nudge.
const erroredCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u2", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a3", parentId: "u2", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "" }], stopReason: "error", errorMessage: "boom", timestamp: 0 } },
    ],
  },
};
await settled({ type: "agent_settled" }, erroredCtx);
if (prompts !== 1) throw new Error(`an errored turn must still get one recovery nudge, got ${prompts} prompts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must leave a captain-aborted turn alone while still nudging an errored one"
  [ -z "$out" ] || fail "Pi reply-recovery aborted-turn test printed output: $out"
  pass ".pi primary extension: reply recovery never restarts a captain-aborted turn"
}

test_pi_reply_recovery_latch_never_swallows_a_later_episode() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-latch-root"
  home="$TMP_ROOT/pi-reply-latch-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const verdict = `${process.env.FM_HOME}/state/.test-guard-verdict`;
const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const settled = handlers.get("agent_settled");

const stuckCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], stopReason: "toolUse", timestamp: 0 } },
    ],
  },
};

// Settle A: supervision clean, turn unanswered -> recovery fires, reply latch set.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 1) throw new Error(`settle A: expected the recovery follow-up, got ${prompts.length}`);
if (!prompts[0].includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`settle A: wrong prompt: ${prompts[0]}`);

// Settle B: the settle of the recovery turn itself, but supervision went
// unhealthy in the meantime, so the supervision guard claims this settle.
writeFileSync(verdict, "2\n");
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 2) throw new Error(`settle B: expected the supervision follow-up, got ${prompts.length}`);
if (!prompts[1].includes("TURN WOULD END BLIND")) throw new Error(`settle B: wrong prompt: ${prompts[1]}`);

// Settle C: absorbed by the latch of the supervision guard itself.
rmSync(verdict);
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 2) throw new Error(`settle C (guard-latch-absorbed): expected still 2, got ${prompts.length}`);

// Settle D: a genuinely unanswered turn again. A reply latch left over from
// settle A must not silently swallow it.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 3) throw new Error(`settle D: a stale reply latch swallowed a real episode, got ${prompts.length}`);
if (!prompts[2].includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`settle D: wrong prompt: ${prompts[2]}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard reply latch must not survive a settle claimed by the supervision guard"
  [ -z "$out" ] || fail "Pi reply-recovery latch-interleaving test printed output: $out"
  pass ".pi primary extension: reply latch never swallows a later unanswered episode"
}

test_pi_reply_recovery_skips_a_spurious_mid_turn_settle() {
  local repo home log ext out status
  repo="$TMP_ROOT/pi-reply-spurious-root"
  home="$TMP_ROOT/pi-reply-spurious-home"
  log="$TMP_ROOT/pi-reply-spurious-guard.log"
  mkdir -p "$home/state"
  : > "$log"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" FM_GUARD_LOG="$log" node --input-type=module 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");
if (!started) throw new Error("before_agent_start handler was not registered");

// The reproduced race: the captain prompt and the watcher wake both observe an
// idle session and both open a logical run. The losing inner agent.prompt()
// rejects at once, but its finally block still emits agent_settled while the
// winner is mid-turn - so the transcript tail is a not-yet-resolved tool call
// that is going to be answered by the still-running winner.
const midFlightCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], stopReason: "toolUse", timestamp: 0 } },
    ],
  },
};

await started({ type: "before_agent_start" }, {});
await started({ type: "before_agent_start" }, {});

// The losing spurious settle must be left entirely unevaluated: no recovery
// follow-up, and not even a supervision-guard run.
await settled({ type: "agent_settled" }, midFlightCtx);
if (prompts.length !== 0) throw new Error(`spurious mid-turn settle produced ${prompts.length} follow-ups`);
if (readFileSync(process.env.FM_GUARD_LOG, "utf8").trim() !== "") {
  throw new Error("spurious mid-turn settle still ran the supervision guard");
}

// The settle of the winner itself is terminal and is judged normally.
await settled({ type: "agent_settled" }, midFlightCtx);
if (prompts.length !== 1) throw new Error(`genuine settle produced ${prompts.length} follow-ups, expected exactly 1`);
if (!prompts[0].includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must ignore a settle emitted while another logical run is still in flight"
  [ -z "$out" ] || fail "Pi reply-recovery spurious-settle test printed output: $out"
  pass ".pi primary extension: a spurious mid-turn settle is skipped and only the terminal settle is judged"
}

test_pi_reply_recovery_spurious_settle_never_doubles_a_healthy_answer() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-spurious-healthy-root"
  home="$TMP_ROOT/pi-reply-spurious-healthy-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
let prompts = 0;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage() {
    prompts += 1;
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// Same interleaving, but the winner goes on to answer properly. Nudging on the
// losing spurious settle would start an extra turn on top of an answer that
// was already on its way - the duplicate answer the contract forbids.
const midFlight = [
  { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
  { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], stopReason: "toolUse", timestamp: 0 } },
];
let entries = midFlight;
const ctx = { sessionManager: { getEntries: () => entries } };

await started({ type: "before_agent_start" }, {});
await started({ type: "before_agent_start" }, {});
await settled({ type: "agent_settled" }, ctx);
if (prompts !== 0) throw new Error(`spurious mid-turn settle produced ${prompts} follow-ups`);

entries = [
  ...midFlight,
  { type: "message", id: "r1", parentId: "a1", timestamp: "t", message: { role: "toolResult", toolCallId: "tc1", toolName: "bash", content: "drained", isError: false, timestamp: 0 } },
  { type: "message", id: "a2", parentId: "r1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts !== 0) throw new Error(`the winner answered, yet ${prompts} follow-ups were sent`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must not nudge when the still-running winner goes on to answer"
  [ -z "$out" ] || fail "Pi reply-recovery spurious-healthy test printed output: $out"
  pass ".pi primary extension: a spurious mid-turn settle never doubles an answer the winner still delivers"
}

test_pi_input_recovery_resubmits_a_captain_message_lost_to_the_race() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-lost-root"
  home="$TMP_ROOT/pi-input-lost-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts.push({ message, options });
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");
if (!input) throw new Error("input handler was not registered");

// The watcher wake wins the race and answers normally. The captain side
// prompt() call loses: pi-agent-core rejects it before normalizePromptInput,
// so its message never becomes a transcript entry at all - the tail is
// perfectly healthy and no tail inspection could ever see the loss.
const entries = [
  { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", timestamp: 0 } },
  { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop", timestamp: 0 } },
];
const ctx = { sessionManager: { getEntries: () => entries } };

await input({ type: "input", text: "bitte den Stand zusammenfassen", source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "\u2063FIRSTMATE_OP: v1 watcher: stale: ..." }, ctx);
await started({ type: "before_agent_start", prompt: "bitte den Stand zusammenfassen" }, ctx);
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) throw new Error(`spurious settle acted: ${prompts.length} prompts`);

await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`expected exactly one recovery resubmission, got ${prompts.length}`);
const [{ message, options }] = prompts;
if (!message.startsWith("\u2063FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`untyped operational prompt: ${message}`);
if (!message.includes("CAPTAIN INPUT WAS LOST")) throw new Error(`not an input-recovery prompt: ${message}`);
if (message.includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`input recovery and reply recovery both fired: ${message}`);
if (!message.includes("bitte den Stand zusammenfassen")) throw new Error(`the lost captain text was not carried: ${message}`);
if (options?.deliverAs !== "followUp") throw new Error("recovery prompt was not a follow-up");

// Idempotent: the same unchanged state must never resubmit it a second time.
await settled({ type: "agent_settled" }, ctx);
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`lost input was resubmitted again, total ${prompts.length}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must resubmit a captain message the race dropped before it reached the transcript"
  [ -z "$out" ] || fail "Pi input-recovery loss test printed output: $out"
  pass ".pi primary extension: a captain message lost to the race is resubmitted exactly once"
}

test_pi_input_recovery_stays_silent_for_a_delivered_captain_message() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-delivered-root"
  home="$TMP_ROOT/pi-input-delivered-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// Negative control: the ordinary, unraced case. The captain message reaches
// the transcript and is answered, so nothing may be resubmitted.
let entries = [];
const ctx = { sessionManager: { getEntries: () => entries } };

await input({ type: "input", text: "bitte den Stand zusammenfassen", source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "bitte den Stand zusammenfassen" }, ctx);
entries = [
  { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: [{ type: "text", text: "bitte den Stand zusammenfassen" }], timestamp: 0 } },
  { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Hier der Stand." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) throw new Error(`a delivered captain message triggered ${prompts.length} prompts`);

// A watcher wake is extension-sourced and is never tracked as captain input,
// so it can never be resubmitted even when it is missing from the transcript.
await input({ type: "input", text: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", source: "extension" }, ctx);
await started({ type: "before_agent_start" }, ctx);
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) throw new Error(`an extension-sourced input was treated as captain input, ${prompts.length} prompts`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must not resubmit a captain message that reached the transcript"
  [ -z "$out" ] || fail "Pi input-recovery negative-control test printed output: $out"
  pass ".pi primary extension: a delivered captain message and an extension wake are never resubmitted"
}

test_pi_input_recovery_never_replays_a_withdrawn_queued_message() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-withdrawn-root"
  home="$TMP_ROOT/pi-input-withdrawn-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// A turn is already streaming, so the captain message is queued rather than
// starting a run: Pi reports that by setting streamingBehavior on the input
// event. A queued message is only appended when the run consumes it, and
// Escape clears the queue back into the editor instead - so its absence from
// the transcript is a withdrawal, never a loss.
let entries = [
  { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "erster auftrag", timestamp: 0 } },
];
const ctx = { sessionManager: { getEntries: () => entries } };

await started({ type: "before_agent_start", prompt: "erster auftrag" }, ctx);
await input({ type: "input", text: "loesch den branch", source: "interactive", streamingBehavior: "steer" }, ctx);

// Escape: the queue is cleared, the run aborts, and the queued text is back in
// the editor without ever reaching the transcript.
entries = [
  ...entries,
  { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "" }], stopReason: "aborted", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);

// A later, unrelated turn must not replay the withdrawn instruction.
await started({ type: "before_agent_start", prompt: "was steht an?" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "u2", parentId: "a1", timestamp: "t", message: { role: "user", content: [{ type: "text", text: "was steht an?" }], timestamp: 0 } },
  { type: "message", id: "a2", parentId: "u2", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Nichts offen." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) {
  throw new Error(`a withdrawn queued message was replayed: ${JSON.stringify(prompts)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must never resubmit a queued captain message the captain withdrew"
  [ -z "$out" ] || fail "Pi input-recovery withdrawal test printed output: $out"
  pass ".pi primary extension: a queued captain message withdrawn with Escape is never replayed"
}

test_pi_input_recovery_never_replays_a_failed_submission_the_captain_resent() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-resend-root"
  home="$TMP_ROOT/pi-input-resend-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// The Pi prompt() emits the input event and only then validates the model and
// auth, throwing before it ever reaches before_agent_start. Nothing is
// appended, the captain sees the error, and resends from history.
let entries = [
  { type: "message", id: "e5", parentId: null, timestamp: "t", message: { role: "user", content: [{ type: "text", text: "vorher" }], timestamp: 0 } },
];
const ctx = { sessionManager: { getEntries: () => entries } };

await input({ type: "input", text: "loesch den branch", source: "interactive" }, ctx);
// prompt() throws here: no before_agent_start, no transcript entry.

await input({ type: "input", text: "loesch den branch", source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "loesch den branch" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "e6", parentId: "e5", timestamp: "t", message: { role: "user", content: [{ type: "text", text: "loesch den branch" }], timestamp: 0 } },
  { type: "message", id: "e7", parentId: "e6", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Branch geloescht." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) {
  throw new Error(`the resent instruction was replayed: ${JSON.stringify(prompts)}`);
}

// A later, unrelated run must not resurrect the failed submission either.
await started({ type: "before_agent_start" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "e8", parentId: "e7", timestamp: "t", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", timestamp: 0 } },
  { type: "message", id: "e9", parentId: "e8", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) {
  throw new Error(`a later run resurrected the failed submission: ${JSON.stringify(prompts)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must never replay a submission that failed before it started a run and was resent by hand"
  [ -z "$out" ] || fail "Pi input-recovery resend test printed output: $out"
  pass ".pi primary extension: a failed submission the captain resent is never replayed"
}

test_pi_input_recovery_ignores_an_unrelated_runs_turn_start() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-unrelated-root"
  home="$TMP_ROOT/pi-input-unrelated-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// The captain prompt() emitted its input event and then threw before it
// could start a run, so nothing was appended. The next run is a watcher wake,
// entirely unrelated: its turn start quotes the wake text, not the captain
// text, and must not adopt the phantom captain recording.
let entries = [];
const ctx = { sessionManager: { getEntries: () => entries } };

await input({ type: "input", text: "loesch den branch", source: "interactive" }, ctx);

await started({ type: "before_agent_start", prompt: "\u2063FIRSTMATE_OP: v1 watcher: stale: ..." }, ctx);
entries = [
  { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", timestamp: 0 } },
  { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) {
  throw new Error(`an unrelated run adopted the phantom recording: ${JSON.stringify(prompts)}`);
}

// And it stays dropped: a later run must not resurrect it either.
await started({ type: "before_agent_start", prompt: "was steht an?" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "u2", parentId: "a1", timestamp: "t", message: { role: "user", content: [{ type: "text", text: "was steht an?" }], timestamp: 0 } },
  { type: "message", id: "a2", parentId: "u2", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Nichts offen." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) {
  throw new Error(`a later run resurrected the phantom recording: ${JSON.stringify(prompts)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must not let an unrelated run's turn start adopt a captain recording"
  [ -z "$out" ] || fail "Pi input-recovery unrelated-start test printed output: $out"
  pass ".pi primary extension: an unrelated run's turn start never adopts a captain recording"
}

test_pi_input_recovery_never_doubles_a_manual_resend_after_the_race() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-resend-race-root"
  home="$TMP_ROOT/pi-input-resend-race-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// Losing the race is not silent for the captain: the losing rejection escapes
// prompt() into the interactive loop, which prints "Agent is already
// processing a prompt..." as a chat error. The captain reacts by resending the
// same instruction from history - so replaying the lost recording as well
// would delete the branch twice.
let entries = [
  { type: "message", id: "e1", parentId: null, timestamp: "t", message: { role: "user", content: "vorher", timestamp: 0 } },
];
const ctx = { sessionManager: { getEntries: () => entries } };

// The captain message and a watcher wake both start from idle.
await input({ type: "input", text: "loesch den branch", source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "\u2063FIRSTMATE_OP: v1 watcher: stale: ..." }, ctx);
await started({ type: "before_agent_start", prompt: "loesch den branch" }, ctx);

// The captain call loses and appends nothing; its settle is the spurious one
// the wake is still running behind.
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) throw new Error(`the losing settle acted: ${prompts.length} prompts`);

// The captain sees the error and resends by hand. That resubmission runs and
// is answered normally.
await input({ type: "input", text: "loesch den branch", source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "loesch den branch" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "e2", parentId: "e1", timestamp: "t", message: { role: "user", content: [{ type: "text", text: "loesch den branch" }], timestamp: 0 } },
  { type: "message", id: "e3", parentId: "e2", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Branch geloescht." }], stopReason: "stop", timestamp: 0 } },
];

// The wake settle, then the resend settle. Neither may replay the
// instruction the manual resend already carried out.
await settled({ type: "agent_settled" }, ctx);
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) {
  throw new Error(`the manually resent instruction was replayed: ${JSON.stringify(prompts)}`);
}

// And it stays dropped for good.
await started({ type: "before_agent_start", prompt: "was steht an?" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "e4", parentId: "e3", timestamp: "t", message: { role: "user", content: [{ type: "text", text: "was steht an?" }], timestamp: 0 } },
  { type: "message", id: "e5", parentId: "e4", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Nichts offen." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) {
  throw new Error(`a later settle replayed the superseded recording: ${JSON.stringify(prompts)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must never replay a captain instruction the captain already resent by hand"
  [ -z "$out" ] || fail "Pi input-recovery manual-resend test printed output: $out"
  pass ".pi primary extension: a manual resend after the race never doubles the instruction"
}

test_pi_input_recovery_suppresses_a_resend_that_races_its_own_recovery() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-resend-window-root"
  home="$TMP_ROOT/pi-input-resend-window-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message, options) {
    prompts.push({ message, options });
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// The chat error the losing prompt() prints is the captain reason to resend by
// hand, and that reaction is not bound to arrive before the settle picks the
// lost recording up. Here recovery goes first and the resend lands while the
// recovered copy is still being carried out.
const captainText = "loesch den branch";
let entries = [
  { type: "message", id: "e1", parentId: null, timestamp: "t", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", timestamp: 0 } },
  { type: "message", id: "e2", parentId: "e1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop", timestamp: 0 } },
];
const notices = [];
const ctx = {
  sessionManager: { getEntries: () => entries },
  ui: { notify: (message, type) => notices.push({ message, type }) },
};

await input({ type: "input", text: captainText, source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "\u2063FIRSTMATE_OP: v1 watcher: stale: ..." }, ctx);
await started({ type: "before_agent_start", prompt: captainText }, ctx);
await settled({ type: "agent_settled" }, ctx);
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`expected exactly one recovery resubmission, got ${prompts.length}`);
const recoveryEnvelope = prompts[0].message;

// The captain retypes the same instruction before the recovery turn is done.
// A second executable copy of a destructive instruction must never reach the
// model, and no prose in front of it can enforce that, so the resend is not
// delivered at all.
const resend = await input({ type: "input", text: captainText, source: "interactive" }, ctx);
if (resend?.action !== "handled") {
  throw new Error(`the resend was delivered as a second executable copy: ${JSON.stringify(resend)}`);
}
if (Object.prototype.hasOwnProperty.call(resend, "text")) {
  throw new Error(`the resend still carried delivery text: ${JSON.stringify(resend)}`);
}

// Swallowing it without a word would be the lost captain input this whole
// mechanism exists to prevent, so the captain is told in the chat.
if (notices.length !== 1) throw new Error(`expected exactly one captain notice, got ${JSON.stringify(notices)}`);
if (notices[0].type !== "warning") throw new Error(`the notice was not raised to the captain: ${JSON.stringify(notices[0])}`);
if (!/already delivered it/.test(notices[0].message)) {
  throw new Error(`the notice did not explain the suppression: ${notices[0].message}`);
}

// Only the recovery turn runs. The suppressed resend never reaches the
// transcript, and must not be judged lost and resubmitted because of that.
await started({ type: "before_agent_start", prompt: recoveryEnvelope }, ctx);
entries = [
  ...entries,
  { type: "message", id: "e3", parentId: "e2", timestamp: "t", message: { role: "user", content: [{ type: "text", text: recoveryEnvelope }], timestamp: 0 } },
  { type: "message", id: "e4", parentId: "e3", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Branch geloescht." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) {
  throw new Error(`the suppressed resend was recovered anyway: ${JSON.stringify(prompts)}`);
}

// Once an answer to the recovered instruction exists, the same text is a
// deliberate repeat and must reach the model untouched.
const later = await input({ type: "input", text: captainText, source: "interactive" }, ctx);
if (later !== undefined) throw new Error(`a deliberate repeat was suppressed: ${JSON.stringify(later)}`);
if (notices.length !== 1) throw new Error(`a deliberate repeat produced a notice: ${JSON.stringify(notices)}`);
await started({ type: "before_agent_start", prompt: captainText }, ctx);
entries = [
  ...entries,
  { type: "message", id: "e5", parentId: "e4", timestamp: "t", message: { role: "user", content: [{ type: "text", text: captainText }], timestamp: 0 } },
  { type: "message", id: "e6", parentId: "e5", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Erneut geprueft." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) {
  throw new Error(`the deliberate repeat produced a recovery: ${JSON.stringify(prompts)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must suppress a captain resend that races the recovery it already sent"
  [ -z "$out" ] || fail "Pi input-recovery resend-window test printed output: $out"
  pass ".pi primary extension: a resend racing its own recovery is suppressed and reported, not doubled"
}

test_pi_input_recovery_carries_attached_images() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-images-root"
  home="$TMP_ROOT/pi-input-images-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(content, options) {
    prompts.push({ content, options });
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// The captain pasted a screenshot with the question. Recovering the sentence
// without the attachment would make the model answer about something it
// cannot see.
const screenshot = { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" };
const entries = [
  { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", timestamp: 0 } },
  { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop", timestamp: 0 } },
];
const ctx = { sessionManager: { getEntries: () => entries } };

await input({ type: "input", text: "was ist das im Log?", source: "interactive", images: [screenshot] }, ctx);
await started({ type: "before_agent_start", prompt: "\u2063FIRSTMATE_OP: v1 watcher: stale: ..." }, ctx);
await started({ type: "before_agent_start", prompt: "was ist das im Log?" }, ctx);
await settled({ type: "agent_settled" }, ctx);
await settled({ type: "agent_settled" }, ctx);

if (prompts.length !== 1) throw new Error(`expected one recovery resubmission, got ${prompts.length}`);
const [{ content, options }] = prompts;
if (!Array.isArray(content)) throw new Error(`the attachment was dropped, content was a bare string: ${content}`);
const textParts = content.filter((part) => part.type === "text");
const imageParts = content.filter((part) => part.type === "image");
if (textParts.length !== 1) throw new Error(`expected exactly one text part, got ${textParts.length}`);
if (!textParts[0].text.includes("CAPTAIN INPUT WAS LOST")) throw new Error(`not an input-recovery prompt: ${textParts[0].text}`);
if (!textParts[0].text.includes("was ist das im Log?")) throw new Error(`the lost text was not carried: ${textParts[0].text}`);
if (imageParts.length !== 1) throw new Error(`expected the screenshot to be carried, got ${imageParts.length} image parts`);
if (imageParts[0].data !== screenshot.data) throw new Error("the carried image was not the captain attachment");
if (options?.deliverAs !== "followUp") throw new Error("recovery prompt was not a follow-up");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must resubmit a lost captain message together with its attachments"
  [ -z "$out" ] || fail "Pi input-recovery image test printed output: $out"
  pass ".pi primary extension: a lost captain message keeps its attached images"
}

test_pi_input_recovery_detects_a_short_message_a_longer_one_contains() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-input-short-root"
  home="$TMP_ROOT/pi-input-short-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const input = handlers.get("input");
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// "weiter" is lost to the race and never appended. Its judgement is deferred
// because the next settle is claimed by the supervision guard, and by the time
// it is judged the captain has sent "weiter mit dem PR", which was appended
// normally. A containment match would pair the lost short message with that
// longer entry and then declare the delivered longer message lost instead.
const verdict = `${process.env.FM_HOME}/state/.test-guard-verdict`;
let entries = [];
const ctx = { sessionManager: { getEntries: () => entries } };

await input({ type: "input", text: "weiter", source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "\u2063FIRSTMATE_OP: v1 watcher: stale: ..." }, ctx);
await started({ type: "before_agent_start", prompt: "weiter" }, ctx);
entries = [
  { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "\u2063FIRSTMATE_OP: v1 watcher: stale: ...", timestamp: 0 } },
  { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "Wake abgearbeitet." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 0) throw new Error(`the losing settle acted: ${prompts.length} prompts`);

writeFileSync(verdict, "2");
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`expected the supervision follow-up, got ${prompts.length}`);
rmSync(verdict);
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`guard-latch-absorbed settle acted, total ${prompts.length}`);

await input({ type: "input", text: "weiter mit dem PR", source: "interactive" }, ctx);
await started({ type: "before_agent_start", prompt: "weiter mit dem PR" }, ctx);
entries = [
  ...entries,
  { type: "message", id: "u2", parentId: "a1", timestamp: "t", message: { role: "user", content: [{ type: "text", text: "weiter mit dem PR" }], timestamp: 0 } },
  { type: "message", id: "a2", parentId: "u2", timestamp: "t", message: { role: "assistant", content: [{ type: "text", text: "PR laeuft." }], stopReason: "stop", timestamp: 0 } },
];
await settled({ type: "agent_settled" }, ctx);

if (prompts.length !== 2) {
  throw new Error(`expected the lost short message to be recovered exactly once, got ${prompts.length - 1}`);
}
if (!prompts[1].includes("CAPTAIN INPUT WAS LOST")) throw new Error(`not an input-recovery prompt: ${prompts[1]}`);
if (prompts[1].includes("weiter mit dem PR")) {
  throw new Error(`the delivered longer message was resubmitted instead of the lost short one: ${prompts[1]}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must not let a longer later message absorb a genuinely lost short one"
  [ -z "$out" ] || fail "Pi input-recovery short-message test printed output: $out"
  pass ".pi primary extension: a lost short message is not absorbed by a longer later message"
}

test_pi_reply_recovery_never_doubles_on_overlapping_settles() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-overlap-root"
  home="$TMP_ROOT/pi-reply-overlap-home"
  mkdir -p "$home/state"
  printf '0.5\n' > "$home/state/.test-guard-delay"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

const stuckCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], stopReason: "toolUse", timestamp: 0 } },
    ],
  },
};

// The Pi extension runner does not serialize separate settle emissions, so a
// second run can start and settle while the first settle is still awaiting the
// supervision guard child process. Both would otherwise judge the same stuck
// state with their own stale latch snapshot and send two recovery turns.
await started({ type: "before_agent_start" }, stuckCtx);
const first = settled({ type: "agent_settled" }, stuckCtx);
setTimeout(async () => {
  await started({ type: "before_agent_start" }, stuckCtx);
  await settled({ type: "agent_settled" }, stuckCtx);
}, 0);
await first;
await new Promise((r) => setTimeout(r, 900));
if (prompts.length !== 1) {
  throw new Error(`overlapping settles produced ${prompts.length} recovery turns, expected exactly 1`);
}
if (!prompts[0].includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`unexpected prompt: ${prompts[0]}`);

// The latch must still absorb the own settle of the recovery turn afterwards.
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 1) throw new Error(`the settle of the recovery turn was not absorbed, total ${prompts.length}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must judge one settle at a time so overlapping settles cannot double a recovery turn"
  [ -z "$out" ] || fail "Pi reply-recovery overlap test printed output: $out"
  pass ".pi primary extension: overlapping settles never produce two recovery turns for one episode"
}

test_pi_reply_recovery_skips_a_run_that_started_during_the_guard_check() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-late-run-root"
  home="$TMP_ROOT/pi-reply-late-run-home"
  mkdir -p "$home/state"
  printf '0.5\n' > "$home/state/.test-guard-delay"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const started = handlers.get("before_agent_start");
const settled = handlers.get("agent_settled");

// Pi clears its own run flag before emitting the settle, so a fresh prompt can
// open a new logical run while the handler is still awaiting the supervision
// guard child process - and the transcript is only read after that await.
// The timer below lands inside exactly that window.
const ctx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "weiter", timestamp: 0 } },
    ],
  },
};

await started({ type: "before_agent_start" }, ctx);
const settlePromise = settled({ type: "agent_settled" }, ctx);
// The fixture guard sleeps, so this timer lands while the handler is still
// awaiting that child process - the window the re-check has to cover.
setTimeout(() => void started({ type: "before_agent_start" }, ctx), 0);
await settlePromise;
if (prompts.length !== 0) throw new Error(`nudged a healthy in-flight turn, got ${prompts.length} prompts`);

// The own settle of the new run is terminal and is judged normally.
await settled({ type: "agent_settled" }, ctx);
if (prompts.length !== 1) throw new Error(`the genuine settle of the new run produced ${prompts.length} prompts, expected 1`);
if (!prompts[0].includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`unexpected prompt: ${prompts[0]}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must not judge a transcript a new run started appending to during the guard check"
  [ -z "$out" ] || fail "Pi reply-recovery late-run test printed output: $out"
  pass ".pi primary extension: a run opened during the supervision check suppresses that settle's judgement"
}

test_pi_reply_recovery_budget_resets_for_a_new_session_generation() {
  local repo home ext out status
  repo="$TMP_ROOT/pi-reply-generation-root"
  home="$TMP_ROOT/pi-reply-generation-home"
  mkdir -p "$home/state"
  install_pi_reply_recovery_fixture "$repo"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  out=$(PLUGIN="$ext" FM_HOME="$home" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const prompts = [];
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  async sendUserMessage(message) {
    prompts.push(message);
  },
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const sessionStart = handlers.get("session_start");
const settled = handlers.get("agent_settled");
if (!sessionStart) throw new Error("session_start handler was not registered");

const stuckCtx = {
  sessionManager: {
    getEntries: () => [
      { type: "message", id: "u1", parentId: null, timestamp: "t", message: { role: "user", content: "captain input", timestamp: 0 } },
      { type: "message", id: "a1", parentId: "u1", timestamp: "t", message: { role: "assistant", content: [{ type: "toolCall", id: "tc1", name: "bash" }], stopReason: "toolUse", timestamp: 0 } },
    ],
  },
};

// Burn the whole budget in generation A: three attempts, then the one loud
// "gave up" notice, then silence.
for (let i = 0; i < 9; i += 1) await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 4) throw new Error(`generation A produced ${prompts.length} prompts, expected 3 attempts + 1 notice`);
if (!prompts[3].includes("automatic recovery gave up")) throw new Error(`missing exhaustion notice: ${prompts[3]}`);
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 4) throw new Error(`generation A kept prompting, total ${prompts.length}`);

// /new starts a fresh generation, which must not inherit the exhausted budget.
await sessionStart({ type: "session_start", reason: "new" }, stuckCtx);
await settled({ type: "agent_settled" }, stuckCtx);
if (prompts.length !== 5) throw new Error(`a new generation did not get a fresh attempt, total ${prompts.length}`);
if (!prompts[4].includes("TURN ENDED WITHOUT A REPLY")) throw new Error(`unexpected prompt: ${prompts[4]}`);
if (prompts[4].includes("automatic recovery gave up")) throw new Error("a new generation reused the exhaustion notice");
EOF
)
  status=$?
  expect_code 0 "$status" "Pi guard must give each session generation its own recovery attempt budget"
  [ -z "$out" ] || fail "Pi reply-recovery generation-reset test printed output: $out"
  pass ".pi primary extension: a new session generation gets a fresh recovery attempt budget"
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
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
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

# The 2026-08-14 lapse: a cycle armed, delivered one rewake, exited, and left its
# owner lock behind holding a live pid. Both Stop participants read that lock as
# "recovery is already under way", so with work in flight and a beacon 40 minutes
# cold every turn ended blind and nothing re-armed. A stale ledger outcome for
# the lock's own pid is the proof that no decision is in flight any more.
test_hook_claude_mode_blocks_on_abandoned_autoarm_claim() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-abandoned-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  printf 'epoch=464 owner_pid=%s outcome=rewake updated_at=1\n' "$pid" > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "an owner lock left behind by a finished claim must not pass for recovery under way"
  assert_contains "$out" "TURN WOULD END BLIND" "abandoned-claim block must carry the blind-turn banner"
  assert_contains "$out" "2 task(s) in flight" "abandoned-claim block must name the unsupervised work"
  pass "fm-turnend-guard --claude: an abandoned auto-arm claim no longer allows a blind stop (incident regression)"
}

# The ledger-blind variant of the same lapse: a session teardown killed the claim's
# process group before it could record any outcome, so its entry still reads
# "arming" - in flight however old, by contract - while the recorded pid now belongs
# to an unrelated live process. The identity the claim wrote into its own lock is
# the only thing that separates that from a real arm still running.
test_hook_claude_mode_blocks_on_pid_reused_arming_claim() {
  local dir out status pid identity
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-reused-pid-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # The claim recorded ITS OWN identity; this test shell now stands in for the
  # unrelated process that inherited the number.
  identity=$(fm_test_pid_identity "$$") || fail "could not compute a claim pid-identity"
  printf '%s\n' "$identity" > "$dir/state/.claude-autoarm.lock/pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=1\n' "$pid" > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a claim whose recorded identity no longer matches its live pid must not pass for recovery under way"
  assert_contains "$out" "TURN WOULD END BLIND" "reused-pid claim block must carry the blind-turn banner"
  assert_contains "$out" "2 task(s) in flight" "reused-pid claim block must name the unsupervised work"
  pass "fm-turnend-guard --claude: a claim whose pid was reused stops counting as recovery even while its entry reads arming"
}

# The legacy stuck-arming shape (the 2026-08-26 flap): a live identity-matched
# lock-holding owner frozen at arming past grace with a beacon just as stale
# must not count as recovery under way.
test_hook_claude_mode_blocks_on_stuck_arming_claim() {
  local dir out status pid identity
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-stuck-arming-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  identity=$(fm_test_pid_identity "$pid") || fail "could not compute a claim pid-identity"
  printf '%s\n' "$identity" > "$dir/state/.claude-autoarm.lock/pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=1\n' "$pid" > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a live owner stuck arming past grace with a stale beacon must not pass for recovery under way"
  assert_contains "$out" "TURN WOULD END BLIND" "stuck-arming claim block must carry the blind-turn banner"
  assert_contains "$out" "2 task(s) in flight" "stuck-arming claim block must name the unsupervised work"
  pass "fm-turnend-guard --claude: a hung owner frozen at arming with no watcher beat no longer allows a blind stop"
}

# The generation model's ownership proof: a live open ledger claim (two-line
# entry, identity-matched owner, watcher still beating) owns recovery with no
# lock held at all.
test_hook_claude_mode_allows_on_open_generation_claim() {
  local dir out status pid identity
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-open-generation")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") || fail "could not compute a claim pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=1\n%s\n' "$pid" "$identity" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "this case must start with no owner lock at all"
  out=$(run_hook_claude "$dir" false); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "--claude mode must allow when a live open generation claim owns recovery"
  [ -z "$out" ] || fail "open-generation-claim allow produced output: $out"
  pass "fm-turnend-guard --claude: a live open generation claim owns recovery with no lock held"
}

# The same claim gone stuck (entry and beacon both past grace) stops counting
# as recovery even though its owner is alive and identity-matched.
test_hook_claude_mode_blocks_on_stuck_generation_claim() {
  local dir out status pid identity
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-stuck-generation")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  sleep 60 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") || fail "could not compute a claim pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=1\n%s\n' "$pid" "$identity" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a stuck generation claim must not pass for recovery under way"
  assert_contains "$out" "TURN WOULD END BLIND" "stuck-generation-claim block must carry the blind-turn banner"
  assert_contains "$out" "2 task(s) in flight" "stuck-generation-claim block must name the unsupervised work"
  pass "fm-turnend-guard --claude: a stuck generation claim no longer allows a blind stop"
}

# The same abandoned claim on the terminal path: stepping aside for it allowed the
# stop silently AND spent no attended alarm, so a genuinely broken automatic
# mechanism stayed invisible. The guard must clear the claim and finish instead.
test_hook_claude_mode_terminal_fail_open_clears_abandoned_claim() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/hook-claude-abandoned-terminal")
  : > "$dir/state/task1.meta"
  : > "$dir/state/.claude-autoarm-failure-notified"
  seed_claude_budget "$dir" 4 3
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  printf 'epoch=3 owner_pid=%s outcome=failed-suppressed updated_at=1\n' "$pid" > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  out=$(FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=200 run_hook_claude "$dir" true); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "the verified attended fail-open still ends the turn once it is spent"
  assert_contains "$out" 'FIRSTMATE SUPERVISION IS GENUINELY DOWN' "an abandoned claim suppressed the episode's attended alarm"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "abandoned-claim terminal path did not consume the one-time alarm"
  assert_absent "$dir/state/.claude-autoarm.lock" "abandoned-claim terminal path left the stale claim in place"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "abandoned-claim reclaim left its serialization mutex behind"
  pass "fm-turnend-guard --claude: the terminal path clears an abandoned claim instead of stepping aside silently"
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
test_tracked_claude_entries_inert_under_grok
test_codex_hook_uses_process_pwd_when_payload_cwd_is_outside_root
test_codex_hook_ignores_nested_git_root_guard
test_opencode_plugin_anchors_guard_to_worktree
test_pi_extension_injects_once_per_logical_agent_run
test_pi_extension_retries_after_followup_delivery_failure
test_pi_reply_recovery_nudges_once_for_a_dangling_tool_call
test_pi_reply_recovery_stays_silent_for_a_healthy_reply
test_pi_reply_recovery_is_idempotent_and_bounded
test_pi_reply_recovery_flags_an_unanswered_user_message
test_pi_reply_recovery_ignores_the_session_start_digest
test_pi_reply_recovery_ignores_a_flushed_inline_bash_message
test_pi_reply_recovery_flags_a_tool_call_beside_a_text_preamble
test_pi_reply_recovery_never_restarts_an_aborted_turn
test_pi_reply_recovery_latch_never_swallows_a_later_episode
test_pi_reply_recovery_skips_a_spurious_mid_turn_settle
test_pi_reply_recovery_spurious_settle_never_doubles_a_healthy_answer
test_pi_input_recovery_resubmits_a_captain_message_lost_to_the_race
test_pi_input_recovery_stays_silent_for_a_delivered_captain_message
test_pi_input_recovery_never_replays_a_withdrawn_queued_message
test_pi_input_recovery_never_replays_a_failed_submission_the_captain_resent
test_pi_input_recovery_ignores_an_unrelated_runs_turn_start
test_pi_input_recovery_never_doubles_a_manual_resend_after_the_race
test_pi_input_recovery_suppresses_a_resend_that_races_its_own_recovery
test_pi_input_recovery_carries_attached_images
test_pi_input_recovery_detects_a_short_message_a_longer_one_contains
test_pi_reply_recovery_never_doubles_on_overlapping_settles
test_pi_reply_recovery_skips_a_run_that_started_during_the_guard_check
test_pi_reply_recovery_budget_resets_for_a_new_session_generation
test_hook_claude_mode_reblocks_stop_hook_active_when_unhealthy
test_hook_claude_mode_reblocks_x_mode_without_tasks
test_hook_claude_mode_allows_when_autoarm_owner_alive
test_hook_claude_mode_repeated_failed_to_arming_interleavings_reach_fail_open
test_hook_claude_mode_terminal_boundary_excludes_starting_owner
test_hook_claude_mode_allows_on_fresh_rewake_epoch
test_hook_claude_mode_blocks_on_abandoned_autoarm_claim
test_hook_claude_mode_blocks_on_pid_reused_arming_claim
test_hook_claude_mode_blocks_on_stuck_arming_claim
test_hook_claude_mode_allows_on_open_generation_claim
test_hook_claude_mode_blocks_on_stuck_generation_claim
test_hook_claude_mode_terminal_fail_open_clears_abandoned_claim
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

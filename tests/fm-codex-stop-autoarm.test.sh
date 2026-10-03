#!/usr/bin/env bash
# Behavior tests for the Codex Stop-owned watcher auto-arm
# (bin/fm-codex-stop-autoarm.sh, docs/supervision-protocols/codex.md).
#
# The hook fires as a Codex async Stop hook. These tests run it hermetically
# as a child of a fake harness (a bash symlink named "codex") whose pid is
# written into the fixture home's state/.lock for ordinary owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so
# no real watcher, model, fleet state, or shared Codex daemon is touched, and
# FM_CODEX_QUEUE_BIN points the delivery at a recording stub.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/codex"
FAKE_CODEX="$FAKEBIN/codex"
export FAKE_CODEX

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-codex-stop-autoarm.sh" "$dir/bin/fm-codex-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-afk-contract.sh" "$dir/bin/fm-afk-contract.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  chmod +x "$dir/bin/fm-codex-stop-autoarm.sh" "$dir/bin/fm-lock.sh" "$dir/bin/fm-afk-contract.sh"
}

# A Codex home does not run the supervision host unless config/supervision-host
# opts in, so the fixture home opts nothing in: most cases exercise the plain
# arm, and the host case below writes the opt-in file.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
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
  fm_git_worktree "$base" "$dir" fm/codex-autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Recording queue stub: FM_CODEX_QUEUE_BIN receives <thread-id> <envelope>.
install_queue_stub() {
  local dir=$1
  cat > "$dir/bin/stub-queue" <<'SH'
#!/usr/bin/env bash
printf 'thread=%s\n' "$1" >> "$FM_HOME/state/queue-ran"
printf '%s' "$2" > "$FM_HOME/state/queue-msg-last.txt"
[ -e "$FM_HOME/state/queue-fail" ] && exit 1
printf 'Queued message stub for thread %s.\n' "$1"
exit 0
SH
  chmod +x "$dir/bin/stub-queue"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. $2 = session id for the payload.
# Any extra env assignments must be exported before invocation. Captures
# stdout+stderr; exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 sid=${2:-sess-codex-autoarm} rc=0
  printf '%s\n' "{\"session_id\":\"$sid\",\"stop_hook_active\":false}" \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Run the hook as a child of a harness-named process that does NOT hold the
# lock (the lock belongs to nobody or to another live owner).
run_autoarm_unowned() {
  local dir=$1 sid=${2:-sess-codex-autoarm} rc=0
  printf '%s\n' "{\"session_id\":\"$sid\",\"stop_hook_active\":false}" \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '"$FM_HOME/bin/fm-codex-stop-autoarm.sh"' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  # Every fixture records the hook's foreground arms in state/arm-ran. A handling
  # successor (FM_WATCH_PREDECESSOR_ARM_PID set) is recorded apart in
  # state/successor-ran so attempt counts stay about the foreground; it confirms
  # a started watcher and exits, or fails while state/successor-fail exists.
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'arm=%s predecessor=%s\n' "$$" "$FM_WATCH_PREDECESSOR_ARM_PID" >> "$FM_HOME/state/successor-ran"
  if [ -e "$FM_HOME/state/successor-fail" ]; then
    printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
    exit 1
  fi
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
echo "$$" >> "$FM_HOME/state/arm-ran"
SH
  case "$kind" in
    actionable)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    failed)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    slow)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
: > "$FM_HOME/state/arm-waiting"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.02; done
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
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
  sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

queue_deliveries() {
  [ -f "$1/state/queue-ran" ] && wc -l < "$1/state/queue-ran" | tr -d ' ' || printf 0
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

first_delivery_thread() {
  sed -n '1s/^thread=//p' "$1/state/queue-ran" 2>/dev/null || true
}

# --- cases --------------------------------------------------------------------

test_actionable_close_delivers_queued_wake() {
  local dir out status body
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" "sess-thread-abc" 2>/dev/null); status=$?
  expect_code 0 "$status" "the hook always exits 0; delivery is the queued turn"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not run the foreground arm"
  [ -e "$dir/state/successor-ran" ] || fail "actionable close did not start a handling successor"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "actionable close did not commit outcome=rewake"
  [ "$(queue_deliveries "$dir")" = 1 ] || fail "actionable close delivered $(queue_deliveries "$dir") queued wakes, expected 1"
  [ "$(first_delivery_thread "$dir")" = "sess-thread-abc" ] || fail "delivery targeted $(first_delivery_thread "$dir"), expected the payload session id"
  body=$(cat "$dir/state/queue-msg-last.txt" 2>/dev/null || true)
  assert_contains "$body" "$(printf '\xE2\x81\xA3')FIRSTMATE_OP: v1 watcher:" "delivery must carry the operational watcher envelope"
  assert_contains "$body" "stale: fixture-win actionable" "delivery must carry the actionable close line"
  assert_contains "$body" "bin/fm-wake-drain.sh" "delivery must carry the drain instruction"
  pass "codex auto-arm: actionable close starts a successor, commits rewake, and queues one envelope to the payload session"
}

test_delivery_without_gnu_timeout() {
  local dir out status shim
  dir=$(make_primary_dir "$TMP_ROOT/no-gnu-timeout")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  shim="$TMP_ROOT/no-gnu-timeout-shim"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nexit 127\n' > "$shim/timeout"
  chmod +x "$shim/timeout"
  out=$(PATH="$shim:$PATH" FM_TIMEOUT_MECHANISM_OVERRIDE=bash run_autoarm "$dir" "sess-thread-mac" 2>/dev/null); status=$?
  expect_code 0 "$status" "the hook always exits 0"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "a host without GNU timeout lost the rewake outcome: $(epoch_outcome "$dir")"
  [ "$(queue_deliveries "$dir")" = 1 ] || fail "a host without GNU timeout delivered $(queue_deliveries "$dir") queued wakes, expected 1"
  pass "codex auto-arm: delivery uses the portable bounded runner on a host without GNU timeout"
}

test_quiet_close_stays_silent() {
  local dir out status pid identity
  dir=$(make_primary_dir "$TMP_ROOT/quiet")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" clean
  # The quiet close is only benign when another verified watcher owns the
  # home; record that live holder exactly as the Claude suite does.
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a quiet close exits 0"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "quiet close did not record outcome=clean"
  [ "$(queue_deliveries "$dir")" = 0 ] || fail "quiet close delivered a queued wake"
  pass "codex auto-arm: quiet close records clean and delivers nothing"
}

test_failed_startup_delivers_one_notice_then_suppressed() {
  local dir out status body count count2
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a failed arm still exits 0"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "failed arm did not commit outcome=failed"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "first failure must create the episode notice marker"
  [ "$(queue_deliveries "$dir")" = 1 ] || fail "first failure delivered $(queue_deliveries "$dir") notices, expected 1"
  body=$(cat "$dir/state/queue-msg-last.txt" 2>/dev/null || true)
  assert_contains "$body" "auto-arm FAILED" "the notice must name the broken automatic mechanism"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a later failure still exits 0"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "later failure did not advance to failed-suppressed"
  [ -s "$dir/state/.claude-autoarm-failure-notified" ] && fail "the episode notice marker changed on a later failure"
  count2=$(queue_deliveries "$dir")
  [ "$count2" = 2 ] || fail "later failure did not deliver its retry notice: $count2"
  pass "codex auto-arm: one failure notice per episode, later failures still deliver their retry"
}

test_delivery_failure_is_nonfatal() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/delivery-fail")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  : > "$dir/state/queue-fail"
  write_arm_fixture "$dir" actionable
  run_autoarm "$dir" 2>/dev/null >/dev/null; status=$?
  expect_code 0 "$status" "a failed queue call must not fail the hook"
  # A committed rewake whose delivery failed would claim a handling turn that
  # is not under way; the same owner must rewrite the epoch to plain failed.
  [ "$(epoch_outcome "$dir")" = failed ] || fail "a failed delivery must rewrite the epoch outcome to failed, got $(epoch_outcome "$dir")"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "a delivery miss is transient, not a broken mechanism, so no notice marker may appear"
  [ -e "$dir/state/successor-ran" ] || fail "a failed queue call must still have started the handling successor"
  pass "codex auto-arm: queue failure rewrites the epoch to failed, keeps the successor, and exits 0"
}

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "codex auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" bash "$dir/bin/fm-codex-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "codex auto-arm: inert with no session lock"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other out status owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CODEX" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(run_autoarm_unowned "$dir" 2>&1); status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "hook must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ "$(queue_deliveries "$dir")" = 0 ] || fail "hook delivered while another session owned the lock"
  pass "codex auto-arm: inert without arm or delivery when another live harness owns the home"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert under an away record"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed under away mode"
  [ "$(queue_deliveries "$dir")" = 0 ] || fail "hook delivered under away mode"
  pass "codex auto-arm: the away daemon owns supervision, so the hook never arms or delivers"
}

test_repeated_stop_single_flight() {
  local dir p1 p2 status1 status2 arms
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" slow
  # Two Stop firings race; the epoch claim must let exactly one arm.
  printf '%s\n' '{"session_id":"sess-race","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
     ' > "$TMP_ROOT/race1.out" 2>&1 &
  p1=$!
  printf '%s\n' '{"session_id":"sess-race","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
     ' > "$TMP_ROOT/race2.out" 2>&1 &
  p2=$!
  # Wait for the arm fixture to signal it is parked, then release both.
  for _ in $(seq 1 100); do [ -e "$dir/state/arm-waiting" ] && break; sleep 0.05; done
  : > "$dir/state/arm-release"
  wait "$p1" || status1=$?
  wait "$p2" || status2=$?
  expect_code 0 "${status1:-0}" "first firing exits 0"
  expect_code 0 "${status2:-0}" "second firing exits 0"
  arms=$(wc -l < "$dir/state/arm-ran" 2>/dev/null | tr -d ' ') || arms=0
  [ "$arms" = 1 ] || fail "$arms foreground arms started for one event epoch, expected exactly 1"
  pass "codex auto-arm: repeated Stop firings produce exactly one generation owner and one arm"
}

test_rapid_sequential_stops_single_flight() {
  # The rapid-reply shape: the second Stop fires while the first arm is still
  # parked, launched strictly after the first. The open claim must defer it.
  local dir p1 p2 status2 arms
  dir=$(make_primary_dir "$TMP_ROOT/rapid-sequential")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" slow
  printf '%s\n' '{"session_id":"sess-rapid","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
     ' > "$TMP_ROOT/rapid1.out" 2>&1 &
  p1=$!
  for _ in $(seq 1 100); do [ -e "$dir/state/arm-waiting" ] && break; sleep 0.05; done
  printf '%s\n' '{"session_id":"sess-rapid","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
     ' > "$TMP_ROOT/rapid2.out" 2>&1 &
  p2=$!
  sleep 0.5
  : > "$dir/state/arm-release"
  wait "$p1" || true
  wait "$p2" || status2=$?
  expect_code 0 "${status2:-0}" "deferred second firing exits 0"
  arms=$(wc -l < "$dir/state/arm-ran" 2>/dev/null | tr -d ' ') || arms=0
  [ "$arms" = 1 ] || fail "rapid sequential stops started $arms arms, expected exactly 1"
  pass "codex auto-arm: a rapid second Stop while the first arm parks defers to the open claim"
}

test_repeated_idle_to_wake_cycles_deliver_each_close() {
  # Repeated idle-to-wake cycles: every actionable close delivers exactly one
  # envelope, advances the epoch, and starts its own handling successor.
  local dir status i deliveries successors
  dir=$(make_primary_dir "$TMP_ROOT/idle-wake-cycles")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  for i in 1 2 3; do
    run_autoarm "$dir" 2>/dev/null >/dev/null || status=$?
    expect_code 0 "${status:-0}" "cycle $i exits 0"
  done
  deliveries=$(queue_deliveries "$dir")
  [ "$deliveries" = 3 ] || fail "$deliveries deliveries for 3 actionable closes, expected 3"
  successors=$(wc -l < "$dir/state/successor-ran" 2>/dev/null | tr -d ' ') || successors=0
  [ "$successors" = 3 ] || fail "$successors successors for 3 actionable closes, expected 3"
  pass "codex auto-arm: repeated idle-to-wake cycles deliver and re-cover exactly once per close"
}

test_term_mid_arm_commits_failure_without_delivery() {
  # Session exit reaps the hook tree (verified live on codex-cli 0.159.0); a
  # signal mid-arm must record the durable failure episode and never deliver.
  local dir pid status
  dir=$(make_primary_dir "$TMP_ROOT/term-mid-arm")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" slow
  printf '%s\n' '{"session_id":"sess-term","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh" &
        hook=$!
        for _ in $(seq 1 100); do [ -e "$FM_HOME/state/arm-waiting" ] && break; sleep 0.02; done
        kill -TERM "$hook" 2>/dev/null
        wait "$hook"
     ' 2>/dev/null; status=$?
  expect_code 0 "$status" "the interrupted hook exits 0 without delivering"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "TERM mid-arm did not commit outcome=failed, got $(epoch_outcome "$dir")"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "TERM mid-arm must create the once-per-episode notice"
  [ "$(queue_deliveries "$dir")" = 0 ] || fail "interrupted hook delivered a queued wake"
  pass "codex auto-arm: a mid-arm signal records the failure episode durably and never delivers"
}

test_exec_ancestry_stands_down() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/exec-standdown")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  # The fake harness's -c code carries a standalone `exec` token in a comment,
  # so the fake codex launcher argv names codex and carries `exec`, the shape
  # `codex exec ...` produces. The hook must stand down before arming.
  out=$(printf '%s\n' '{"session_id":"s"}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        # exec detector fixture: the launcher argv carries the exec token
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 0 "$status" "the headless stand-down exits 0"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a codex exec session"
  [ "$(queue_deliveries "$dir")" = 0 ] || fail "hook delivered inside a codex exec session"
  pass "codex auto-arm: a codex launcher carrying the exec token never parks a headless run"
}

test_interactive_launcher_without_exec_arms() {
  local dir out status inner
  dir=$(make_primary_dir "$TMP_ROOT/interactive-launcher")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  # The hook runs as a child of the fake codex launcher, which runs below a
  # wrapper whose argv carries the standalone word exec. The launcher itself
  # carries no exec token, so wrapper text must NOT stand the session down.
  inner='printf "%s\n" "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-codex-stop-autoarm.sh"'
  out=$(printf '%s\n' '{"session_id":"s","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" FAKE_CODEX="$FAKE_CODEX" INNER="$inner" \
      bash -c '
        # exec wrapper-above-launcher fixture: above the launcher, never inspected
        "$FAKE_CODEX" -c "$INNER"
      ' 2>&1); status=$?
  expect_code 0 "$status" "the interactive path exits 0"
  [ -e "$dir/state/arm-ran" ] || fail "wrapper exec text above the launcher stood the session down"
  pass "codex auto-arm: exec text above the codex launcher never stands an interactive session down"
}

test_secondmate_home_arms() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must arm in a validly marked secondmate home"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate home did not commit outcome=rewake"
  pass "codex auto-arm: a validly marked secondmate home is guarded like a main primary"
}

test_payload_without_session_id_still_arms() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/no-session")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  printf '%s\n' '{"stop_hook_active":false}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>/dev/null; status=$?
  expect_code 0 "$status" "a payload without session_id still arms and exits 0"
  # The arm runs and the successor starts, but with no session id the delivery
  # cannot target a turn, so the epoch must record failed, never a rewake that
  # claims a handling turn nothing started.
  [ "$(epoch_outcome "$dir")" = failed ] || fail "session-id-less close recorded $(epoch_outcome "$dir"), expected failed"
  [ -e "$dir/state/successor-ran" ] || fail "session-id-less close did not start the handling successor"
  [ "$(queue_deliveries "$dir")" = 0 ] || fail "delivery without a session id attempted a queue call"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "a missing session id is a delivery miss, not a broken mechanism"
  pass "codex auto-arm: a session-id-less payload arms, starts the successor, and records failed instead of a phantom rewake"
}

test_refuses_arguments() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/refuse-args")
  out=$(printf '{}' | FM_HOME="$dir" bash "$dir/bin/fm-codex-stop-autoarm.sh" --manual 2>&1); status=$?
  expect_code 2 "$status" "an argument must be refused as a manual run"
  assert_contains "$out" "unknown argument" "the refusal must name the argument problem"
  pass "codex auto-arm: any argument is refused before anything is sourced or armed"
}

test_inert_when_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an idle home exits 0"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  pass "codex auto-arm: an idle home with no supervision need stays inert"
}

test_inert_in_crew_checkout_via_payload() {
  # A Cursor-delivered payload carries cursor_version; the hook must stand down
  # even inside an otherwise-arming primary fixture.
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/cursor-payload")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"s","cursor_version":"2026.08.11-e8db854"}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 0 "$status" "a foreign-host payload stands down with exit 0"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed on a Cursor-delivered payload"
  pass "codex auto-arm: a Cursor-delivered payload stands the hook down"
}

test_inert_when_pi_code_payload() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/pi-code-payload")
  : > "$dir/state/task.meta"
  install_queue_stub "$dir"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"s","transcript_path":"/home/x/.pi/sessions/rollout.jsonl"}' \
    | FM_HOME="$dir" FM_CODEX_QUEUE_BIN="$dir/bin/stub-queue" "$FAKE_CODEX" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-codex-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 0 "$status" "a pi-code-delivered payload stands down with exit 0"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed on a pi-code-delivered payload"
  pass "codex auto-arm: a pi-code-delivered payload stands the hook down"
}

test_actionable_close_delivers_queued_wake
test_delivery_without_gnu_timeout
test_quiet_close_stays_silent
test_failed_startup_delivers_one_notice_then_suppressed
test_delivery_failure_is_nonfatal
test_inert_in_child_worktree
test_inert_without_session_lock
test_inert_when_lock_held_by_other_harness
test_inert_when_afk
test_repeated_stop_single_flight
test_rapid_sequential_stops_single_flight
test_repeated_idle_to_wake_cycles_deliver_each_close
test_term_mid_arm_commits_failure_without_delivery
test_exec_ancestry_stands_down
test_interactive_launcher_without_exec_arms
test_secondmate_home_arms
test_payload_without_session_id_still_arms
test_refuses_arguments
test_inert_when_idle
test_inert_in_crew_checkout_via_payload
test_inert_when_pi_code_payload

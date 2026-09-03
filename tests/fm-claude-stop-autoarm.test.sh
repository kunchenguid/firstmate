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
    reset-boundary)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/arm-waiting"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.02; done
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    session-transfer-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
: > "$FM_HOME/state/arm-waiting"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.02; done
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: transferred session\n'
exit 0
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
    blocking-actionable)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
sleep 6
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    supersede-then-fail)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'epoch=999 owner_pid=1 outcome=arming updated_at=%s\nfixture-superseder-identity\n' "$(date +%s)" \
  > "$FM_HOME/state/.claude-autoarm-epoch"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
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
  sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

failure_epoch_path() {  # <dir> [baseline]
  local dir=$1 baseline=${2:-} path base epoch best='' best_epoch=0
  if [ -n "$baseline" ]; then
    base="$dir/state/.claude-autoarm-failure-epochs/${baseline//:/.}"
    for path in "$base" "$base".*; do
      [ -f "$path" ] && [ ! -L "$path" ] || continue
      epoch=$(sed -n '1s/^epoch=\([0-9][0-9]*\) .*/\1/p' "$path" 2>/dev/null || true)
      case "$epoch" in ''|*[!0-9]*) continue ;; esac
      if [ "$epoch" -gt "$best_epoch" ]; then
        best=$path
        best_epoch=$epoch
      fi
    done
    if [ -z "$best" ]; then
      printf '%s\n' "$base"
      return 0
    fi
    printf '%s\n' "$best"
    return 0
  fi
  for path in "$dir/state/.claude-autoarm-failure-epochs"/* "$dir/state/.claude-autoarm-failure-epoch"; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    case "${path##*/}" in .failure.tmp.*) continue ;; esac
    epoch=$(sed -n '1s/^epoch=\([0-9][0-9]*\) .*/\1/p' "$path" 2>/dev/null || true)
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    if [ "$epoch" -gt "$best_epoch" ]; then
      best=$path
      best_epoch=$epoch
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

failure_epoch_outcome() {
  local path
  path=$(failure_epoch_path "$@") || return 0
  sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$path" 2>/dev/null || true
}

failure_epoch_field() {
  local dir=$1 field=$2 baseline=${3:-} path
  path=$(failure_epoch_path "$dir" "$baseline") || return 0
  sed -n "s/^.*[[:space:]]\{0,1\}$field=\([^[:space:]]*\).*$/\1/p" \
    "$path" 2>/dev/null || true
}

# Run the hook in the background under the fake harness, output captured to a
# file. Sets RUN_AUTOARM_BG_PID (a direct child of the calling shell, so the
# caller can `wait` on it for the hook's exit status).
RUN_AUTOARM_BG_PID=
run_autoarm_bg() {
  local dir=$1 out=$2
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' > "$out" 2>&1 &
  RUN_AUTOARM_BG_PID=$!
}

run_autoarm_from_claude_daemon_bridge() {  # <dir> <foreground-lock-owner-pid>
  local dir=$1 lock_owner=$2 rc=0
  mkdir -p "$dir/fake-argv"
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" FM_TEST_LOCK_OWNER="$lock_owner" /bin/bash -c '
        exec -a "$FM_HOME/fake-argv/claude" /bin/bash -c '"'"'
          mkdir -p "$FM_HOME/proc/$$"
          printf "%s\0" "$FM_HOME/fake-argv/claude" "$0" "$1" "$2" "$3" \
            > "$FM_HOME/proc/$$/cmdline"
          export FM_PROC_ROOT="$FM_HOME/proc"
          "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
          rc=$?
          exit "$rc"
        '"'"' daemon run --spawned-by "{\"label\":\"claude\",\"cwd\":\"$FM_HOME\",\"pid\":$FM_TEST_LOCK_OWNER}"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

pause_terminal_transition_acquire() {
  cat >> "$1/bin/fm-wake-lib.sh" <<'SH'
fm_autoarm_transition_acquire() {
  local state=$1
  : > "$state/terminal-lock-waiting"
  while [ ! -e "$state/terminal-lock-release" ]; do sleep 0.01; done
  fm_lock_try_acquire "$state/.claude-autoarm-transition.lock"
}
SH
}

pause_terminal_epoch_publish() {
  cat >> "$1/bin/fm-wake-lib.sh" <<'SH'
mv() {
  local arg target='' count=0 rc
  for arg in "$@"; do target=$arg; done
  if [ "$target" = "$STATE/.claude-autoarm-epoch" ]; then
    count=$(cat "$STATE/epoch-publish-count" 2>/dev/null || true)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE/epoch-publish-count"
    if [ "$count" -eq 2 ]; then
      : > "$STATE/terminal-publish-waiting"
      while [ ! -e "$STATE/terminal-publish-release" ]; do sleep 0.01; done
    fi
  fi
  command mv "$@"
  rc=$?
  if [ "$target" = "$STATE/.claude-autoarm-epoch" ] && [ "$count" -eq 2 ]; then
    cat "$STATE/.lock" > "$STATE/session-owner-at-terminal-publish"
  fi
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  if [ "${FM_TEST_SESSION_ACQUIRER:-0}" -eq 1 ] \
    && [ "$lockdir" = "$STATE/.lock.acquire" ]; then
    if fm_lock_try_acquire "$lockdir"; then
      : > "$STATE/session-acquirer-won"
      return 0
    fi
    : > "$STATE/session-acquirer-blocked"
  fi
  while ! fm_lock_try_acquire "$lockdir"; do sleep 0.01; done
}
SH
}

pause_claim_epoch_publish() {
  cat >> "$1/bin/fm-wake-lib.sh" <<'SH'
mv() {
  local arg target=''
  for arg in "$@"; do target=$arg; done
  if [ "$target" = "$STATE/.claude-autoarm-epoch" ]; then
    : > "$STATE/claim-publish-waiting"
    while [ ! -e "$STATE/claim-publish-release" ]; do sleep 0.01; done
  fi
  command mv "$@"
}
SH
}

run_bound_claim_from_claude_daemon_bridge() {  # <dir> <foreground-lock-owner-pid>
  local dir=$1 lock_owner=$2
  mkdir -p "$dir/fake-argv"
  FM_HOME="$dir" FM_TEST_LOCK_OWNER="$lock_owner" /bin/bash -c '
    exec -a "$FM_HOME/fake-argv/claude" /bin/bash -c '"'"'
      mkdir -p "$FM_HOME/proc/$$"
      printf "%s\0" "$FM_HOME/fake-argv/claude" "$0" "$1" "$2" "$3" \
        > "$FM_HOME/proc/$$/cmdline"
      export FM_PROC_ROOT="$FM_HOME/proc"
      . "$FM_HOME/bin/fm-wake-lib.sh"
      . "$FM_HOME/bin/fm-session-lock-lib.sh"
      fm_autoarm_claim_next "$FM_HOME/state" 300 "$FM_HOME" "$FM_TEST_LOCK_OWNER"
      printf "%s\n" "$?" > "$FM_HOME/state/bound-claim-rc"
    '"'"' daemon run --spawned-by "{\"label\":\"claude\",\"cwd\":\"$FM_HOME\",\"pid\":$FM_TEST_LOCK_OWNER}"
  '
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

test_claude_daemon_spawned_by_foreground_lock_owner_arms() {
  local dir out status owner lock_after tool
  dir=$(make_primary_dir "$TMP_ROOT/daemon-spawned-by")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"
  mkdir -p "$dir/no-interpreters"
  for tool in python3 jq; do
    cat > "$dir/no-interpreters/$tool" <<'SH'
#!/usr/bin/env bash
exit 127
SH
    chmod +x "$dir/no-interpreters/$tool"
  done

  out=$(PATH="$dir/no-interpreters:$PATH" run_autoarm_from_claude_daemon_bridge "$dir" "$owner" 2>/dev/null); status=$?
  lock_after=$(cat "$dir/state/.lock" 2>/dev/null || true)
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true

  expect_code 2 "$status" "a Claude daemon spawned by the foreground session must arm without python3 or jq"
  [ "$lock_after" = "$owner" ] || fail "daemon bridge rewrote the foreground session lock: expected $owner, got $lock_after"
  [ -e "$dir/state/arm-ran" ] || fail "daemon-delivered Stop hook did not arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "daemon-delivered Stop hook did not record outcome=rewake"
  assert_contains "$out" "firstmate watcher wake" "daemon-delivered Stop hook did not translate the wake"
  pass "auto-arm: Claude daemon spawned-by metadata lets the foreground-owned home arm"
}

test_generation_claim_is_bound_to_serialized_session_owner() {
  local dir owner claimant successor claim_rc open_rc i
  dir=$(make_primary_dir "$TMP_ROOT/daemon-bound-generation")
  pause_claim_epoch_publish "$dir"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_bound_claim_from_claude_daemon_bridge "$dir" "$owner" &
  claimant=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/claim-publish-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/claim-publish-waiting" ]; then
    kill "$claimant" "$owner" 2>/dev/null || true
    wait "$claimant" "$owner" 2>/dev/null || true
    fail "daemon claim did not reach its publication boundary"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    "$FM_HOME/bin/fm-lock.sh" >/dev/null 2>&1
    printf "%s\n" "$?" > "$FM_HOME/state/successor-lock-rc"
    sleep 60
  ' &
  successor=$!
  sleep 0.1
  [ "$(cat "$dir/state/.lock")" = "$owner" ] \
    || fail "successor replaced the session owner during generation publication"
  : > "$dir/state/claim-publish-release"
  wait "$claimant" || fail "bound daemon claim fixture exited unexpectedly"
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/successor-lock-rc" ]; do sleep 0.01; i=$((i + 1)); done
  claim_rc=$(cat "$dir/state/bound-claim-rc" 2>/dev/null || true)
  expect_code 0 "$claim_rc" "daemon generation claim did not publish under its session lease"
  expect_code 0 "$(cat "$dir/state/successor-lock-rc" 2>/dev/null || true)" "successor did not acquire after claim publication"
  [ "$(epoch_field "$dir" session_owner_pid)" = "$owner" ] \
    || fail "generation did not retain its authenticated foreground session owner"
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_autoarm_claim_open "$1/state" 300' _ "$dir"
  open_rc=$?
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  expect_code 1 "$open_rc" "a generation must close after its bound session owner loses the home"
  pass "auto-arm: generation claims serialize and remain bound to their session owner"
}

test_claude_daemon_losing_session_owner_cannot_commit() {
  local dir out owner successor hook status i
  dir=$(make_primary_dir "$TMP_ROOT/daemon-owner-transfer-commit")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" session-transfer-actionable
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_autoarm_from_claude_daemon_bridge "$dir" "$owner" > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/arm-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/arm-waiting" ]; then
    kill "$hook" "$owner" 2>/dev/null || true
    wait "$hook" "$owner" 2>/dev/null || true
    fail "daemon bridge did not reach the terminal authority boundary"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  successor=$!
  printf '%s\n' "$successor" > "$dir/state/.lock"
  : > "$dir/state/arm-release"
  wait "$hook"; status=$?
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  expect_code 0 "$status" "a detached daemon must stand down after its foreground owner exits"
  [ "$(epoch_outcome "$dir")" = arming ] || fail "former session daemon committed after ownership transferred"
  assert_absent "$dir/state/.claude-autoarm-failure-epochs" "former session daemon published a terminal failure"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "former session daemon elected a terminal notice"
  assert_not_contains "$(cat "$out")" "firstmate watcher wake" "former session daemon delivered terminal output"
  pass "auto-arm: daemon bridge revalidates session authority before terminal commit"
}

test_claude_daemon_losing_owner_during_terminal_lock_wait_cannot_commit() {
  local dir out owner successor hook status i
  dir=$(make_primary_dir "$TMP_ROOT/daemon-owner-terminal-lock-wait")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  pause_terminal_transition_acquire "$dir"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_autoarm_from_claude_daemon_bridge "$dir" "$owner" > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/terminal-lock-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/terminal-lock-waiting" ]; then
    kill "$hook" "$owner" 2>/dev/null || true
    wait "$hook" "$owner" 2>/dev/null || true
    fail "daemon bridge did not block inside terminal lock acquisition"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  successor=$!
  printf '%s\n' "$successor" > "$dir/state/.lock"
  : > "$dir/state/terminal-lock-release"
  wait "$hook"; status=$?
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  expect_code 0 "$status" "a detached daemon must stand down when authority changes during terminal lock acquisition"
  [ "$(epoch_outcome "$dir")" = arming ] || fail "former session daemon committed after losing authority inside terminal lock acquisition"
  assert_absent "$dir/state/.claude-autoarm-failure-epochs" "former session daemon published a terminal failure after lock wait"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "former session daemon elected a terminal notice after lock wait"
  pass "auto-arm: locked terminal commits revalidate daemon session authority"
}

test_terminal_publish_holds_session_acquisition_lease() {
  local dir out owner successor hook acquirer status acquire_status i owner_at_publish
  dir=$(make_primary_dir "$TMP_ROOT/daemon-terminal-session-lease")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  pause_terminal_epoch_publish "$dir"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_autoarm_from_claude_daemon_bridge "$dir" "$owner" > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/terminal-publish-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/terminal-publish-waiting" ]; then
    kill "$hook" "$owner" 2>/dev/null || true
    wait "$hook" "$owner" 2>/dev/null || true
    fail "daemon bridge did not pause after terminal authority validation"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  FM_TEST_SESSION_ACQUIRER=1 FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    "$FM_HOME/bin/fm-lock.sh" >/dev/null 2>&1
    printf "%s\n" "$?" > "$FM_HOME/state/session-acquirer-rc"
    sleep 60
  ' &
  acquirer=$!
  i=0
  while [ "$i" -lt 200 ] \
    && [ ! -e "$dir/state/session-acquirer-blocked" ] \
    && [ ! -e "$dir/state/session-acquirer-won" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  assert_present "$dir/state/session-acquirer-blocked" "successor session was not blocked by the terminal mutation lease"
  assert_absent "$dir/state/session-acquirer-won" "successor session acquired the home during terminal mutation"
  : > "$dir/state/terminal-publish-release"
  wait "$hook"; status=$?
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/session-acquirer-rc" ]; do sleep 0.01; i=$((i + 1)); done
  acquire_status=$(cat "$dir/state/session-acquirer-rc" 2>/dev/null || true)
  successor=$(cat "$dir/state/.lock" 2>/dev/null || true)
  owner_at_publish=$(cat "$dir/state/session-owner-at-terminal-publish" 2>/dev/null || true)
  kill "$acquirer" 2>/dev/null || true
  wait "$acquirer" 2>/dev/null || true

  expect_code 0 "$status" "the prior daemon must suppress output after its foreground owner exits"
  expect_code 0 "$acquire_status" "the successor session did not acquire after terminal mutation released its lease"
  [ "$owner_at_publish" = "$owner" ] || fail "session ownership transferred before terminal publication: expected $owner, got $owner_at_publish"
  [ "$successor" != "$owner" ] || fail "successor session did not replace the dead foreground owner"
  pass "auto-arm: terminal publication serializes against session ownership transfer"
}

test_claude_daemon_losing_owner_during_record_lock_wait_cannot_mutate() {
  local dir out owner successor hook status i
  dir=$(make_primary_dir "$TMP_ROOT/daemon-owner-record-lock-wait")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  pause_terminal_transition_acquire "$dir"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_autoarm_from_claude_daemon_bridge "$dir" "$owner" > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/terminal-lock-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/terminal-lock-waiting" ]; then
    kill "$hook" "$owner" 2>/dev/null || true
    wait "$hook" "$owner" 2>/dev/null || true
    fail "daemon bridge did not block inside quiet-record lock acquisition"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  successor=$!
  printf '%s\n' "$successor" > "$dir/state/.lock"
  : > "$dir/state/terminal-lock-release"
  wait "$hook"; status=$?
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  expect_code 0 "$status" "a detached daemon quiet record must stand down after authority changes"
  [ "$(epoch_outcome "$dir")" = arming ] || fail "former session daemon recorded quiet terminal state after losing authority"
  assert_absent "$dir/state/.claude-autoarm-failure-epochs" "former session daemon published failure state from a quiet record"
  pass "auto-arm: locked quiet records revalidate daemon session authority"
}

test_claude_daemon_losing_owner_during_reset_lock_wait_cannot_reset() {
  local dir out owner successor hook watcher identity status i
  dir=$(make_primary_dir "$TMP_ROOT/daemon-owner-reset-lock-wait")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  write_arm_fixture "$dir" benign-live
  pause_terminal_transition_acquire "$dir"
  sleep 60 &
  watcher=$!
  identity=$(watcher_identity "$dir" "$watcher") || fail "could not identify live watcher for reset authority transfer"
  record_watcher_lock "$dir" "$watcher" "$identity"
  touch "$dir/state/.last-watcher-beat"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_autoarm_from_claude_daemon_bridge "$dir" "$owner" > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/terminal-lock-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/terminal-lock-waiting" ]; then
    kill "$hook" "$owner" "$watcher" 2>/dev/null || true
    wait "$hook" "$owner" "$watcher" 2>/dev/null || true
    fail "daemon bridge did not block inside recovery-reset lock acquisition"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  successor=$!
  printf '%s\n' "$successor" > "$dir/state/.lock"
  : > "$dir/state/terminal-lock-release"
  wait "$hook"; status=$?
  kill "$successor" "$watcher" 2>/dev/null || true
  wait "$successor" "$watcher" 2>/dev/null || true

  expect_code 0 "$status" "a detached daemon reset must stand down after authority changes"
  [ "$(epoch_outcome "$dir")" = arming ] || fail "former session daemon recorded clean state after losing reset authority"
  assert_present "$dir/state/.turnend-claude-blocks" "former session daemon reset the failure episode after losing authority"
  assert_absent "$dir/state/.claude-autoarm-failure-reset" "former session daemon advanced the reset fence after losing authority"
  pass "auto-arm: locked recovery resets revalidate daemon session authority"
}

test_claude_daemon_losing_session_owner_cannot_rearm() {
  local dir out owner successor hook status i arms
  dir=$(make_primary_dir "$TMP_ROOT/daemon-owner-transfer-rearm")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" reset-boundary
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_autoarm_from_claude_daemon_bridge "$dir" "$owner" > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/arm-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/arm-waiting" ]; then
    kill "$hook" "$owner" 2>/dev/null || true
    wait "$hook" "$owner" 2>/dev/null || true
    fail "daemon bridge did not reach the retry authority boundary"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  successor=$!
  printf '%s\n' "$successor" > "$dir/state/.lock"
  : > "$dir/state/arm-release"
  wait "$hook"; status=$?
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  expect_code 0 "$status" "a detached daemon must not retry after session ownership transfers"
  arms=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$arms" -eq 1 ] || fail "former session daemon invoked $arms watcher arms after ownership transferred"
  [ "$(epoch_outcome "$dir")" = arming ] || fail "former session daemon recorded a terminal retry outcome"
  assert_absent "$dir/state/.claude-autoarm-failure-epochs" "former session daemon published retry failure state"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "former session daemon published a retry notice"
  pass "auto-arm: daemon bridge revalidates session authority before every arm"
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

test_claim_path_failure_records_failed_epoch_and_marker() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/claim-path-failure")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  cat > "$dir/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/bin/fm-lock.sh"

  out=$(printf '%s\n' '{"session_id":"stale-claim-failure"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?

  expect_code 2 "$status" "an eligible hook that cannot recover the session lock must report a failed claim"
  assert_contains "$out" "could not claim recovery" "claim failure did not describe the failed claim path"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "claim failure did not write the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "claim failure did not record outcome=failed"
  [ "$(epoch_field "$dir" owner_pid)" != 9999999 ] || fail "claim failure left the dead session owner as the auto-arm owner"
  assert_absent "$dir/state/arm-ran" "claim failure armed after the recovery claim failed"
  pass "auto-arm: failed claim paths leave a durable failed epoch and marker"
}

test_stale_recovery_loser_cannot_publish_failure_into_successor_session() {
  local dir out hook successor status i
  dir=$(make_primary_dir "$TMP_ROOT/stale-recovery-successor-race")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  cp "$dir/bin/fm-lock.sh" "$dir/bin/fm-lock-real.sh"
  cat > "$dir/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/recovery-waiting"
while [ ! -e "$FM_HOME/state/recovery-release" ]; do sleep 0.01; done
exit 1
SH
  chmod +x "$dir/bin/fm-lock.sh" "$dir/bin/fm-lock-real.sh"

  printf '%s\n' '{"session_id":"stale-recovery-race"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' \
      > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/recovery-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$dir/state/recovery-waiting" ] || fail "stale recovery did not reach its failure boundary"
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    "$FM_HOME/bin/fm-lock-real.sh" >/dev/null 2>&1
    printf "%s\n" "$?" > "$FM_HOME/state/successor-lock-rc"
    sleep 60
  ' &
  successor=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/successor-lock-rc" ]; do sleep 0.01; i=$((i + 1)); done
  expect_code 0 "$(cat "$dir/state/successor-lock-rc" 2>/dev/null || true)" "successor did not win stale-lock recovery"
  : > "$dir/state/recovery-release"
  wait "$hook"; status=$?
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  expect_code 0 "$status" "obsolete stale-recovery hook must stand down after a successor acquires"
  assert_absent "$dir/state/.claude-autoarm-failure-epochs" "obsolete stale-recovery hook published a failure epoch"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "obsolete stale-recovery hook published a failure marker"
  assert_absent "$dir/state/arm-ran" "obsolete stale-recovery hook armed in the successor session"
  pass "auto-arm: stale recovery failures are fenced from successor sessions"
}

test_live_claim_mutex_holder_cannot_hide_failure() {
  local dir out status holder lock_after
  dir=$(make_primary_dir "$TMP_ROOT/live-claim-mutex-failure")
  : > "$dir/state/task.meta"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-autoarm.lock/pid"

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  lock_after=$(cat "$dir/state/.claude-autoarm.lock/pid" 2>/dev/null || true)
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 2 "$status" "a live claim-mutex holder must not hide an eligible claim failure"
  assert_contains "$out" "could not claim recovery" "claim-mutex failure did not report the failed claim"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "live claim-mutex contention did not write the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "live claim-mutex contention did not record outcome=failed"
  [ "$lock_after" = "$holder" ] || fail "failure reporting replaced the live claim-mutex holder"
  assert_absent "$dir/state/arm-ran" "claim-mutex failure reached the arm"
  pass "auto-arm: live claim-mutex contention records a durable failure independently"
}

test_identity_unavailable_failure_publication_does_not_self_wedge() {
  local dir state marker rc
  dir=$(make_primary_dir "$TMP_ROOT/identity-unavailable-failure")
  state="$dir/state"
  marker="$state/.claude-autoarm-failure-notified"

  bash -c '
    . "$1"
    fm_pid_identity() { return 1; }
    fm_autoarm_claim_failure_commit "$2" absent failed "$3"
  ' _ "$dir/bin/fm-wake-lib.sh" "$state" "$marker"
  rc=$?

  expect_code 0 "$rc" "failure publication must not repeat an unavailable identity dependency"
  assert_present "$marker" "identity-unavailable failure did not write the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "identity-unavailable failure did not record outcome=failed"
  pass "auto-arm: failure publication does not depend on process identity"
}

test_stalled_transition_holder_cannot_hide_failure() {
  local dir state ready holder out status i
  dir=$(make_primary_dir "$TMP_ROOT/stalled-transition-failure")
  state="$dir/state"
  ready="$state/transition-holder-ready"
  : > "$state/task.meta"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_transition_acquire "$1/state" || exit
    : > "$2"
    pid=${BASHPID:-$$}
    kill -STOP "$pid"
  ' _ "$dir" "$ready" &
  holder=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$ready" ] || fail "transition holder did not acquire its boundary"

  out=$(FM_AUTOARM_TRANSITION_GRACE=1 run_autoarm "$dir" 2>/dev/null); status=$?
  kill -CONT "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 2 "$status" "a stalled transition holder must not hide an eligible claim failure"
  assert_contains "$out" "could not claim recovery" "transition-stall failure did not report the failed claim"
  assert_present "$state/.claude-autoarm-failure-notified" "transition-stall failure did not write the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "transition-stall failure did not record outcome=failed"
  assert_absent "$state/arm-ran" "transition-stall failure reached the arm"
  pass "auto-arm: stalled transition holders are fenced before durable failure publication"
}

test_stalled_transition_steal_holder_falls_back_to_durable_failure() {
  local dir state ready holder out status i
  dir=$(make_primary_dir "$TMP_ROOT/stalled-transition-steal")
  state="$dir/state"
  ready="$state/transition-steal-ready"
  : > "$state/task.meta"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    FM_LOCK_REQUIRE_IDENTITY=1 \
      fm_lock_try_acquire "$1/state/.claude-autoarm-transition.lock.steal" || exit
    : > "$2"
    kill -STOP "${BASHPID:-$$}"
  ' _ "$dir" "$ready" &
  holder=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$ready" ] || fail "transition steal holder did not acquire its boundary"

  out=$(FM_AUTOARM_FAILURE_TRANSITION_ATTEMPTS=5 run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$holder" 2>/dev/null || fail "identity-recorded transition steal holder was signalled"
  kill -CONT "$holder" 2>/dev/null || true
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 2 "$status" "a stalled transition steal holder must publish and continue without wedging the Stop hook"
  assert_contains "$out" "could not claim recovery" "current fallback failure did not request another Stop-owned turn"
  assert_present "$state/.claude-autoarm-failure-notified" "transition-steal fallback did not write the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "transition-steal fallback did not record outcome=failed"
  pass "auto-arm: stalled transition steal owners fall back to durable failure state"
}

test_pid_reused_transition_holder_cannot_hide_failure() {
  local dir state ready holder out status i
  dir=$(make_primary_dir "$TMP_ROOT/pid-reused-transition-failure")
  state="$dir/state"
  ready="$state/pid-reused-transition-ready"
  : > "$state/task.meta"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_transition_acquire "$1/state" || exit
    : > "$2"
    while :; do sleep 1; done
  ' _ "$dir" "$ready" &
  holder=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$ready" ] || fail "transition holder did not acquire its boundary"
  printf 'reused-pid-identity\n' > "$state/.claude-autoarm-transition.lock/pid-identity"

  out=$(FM_AUTOARM_TRANSITION_GRACE=1 run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$holder" 2>/dev/null || fail "identity-mismatched transition holder was signalled"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 2 "$status" "a pid-reused transition lock must not hide an eligible claim failure"
  assert_contains "$out" "could not claim recovery" "pid-reused transition failure did not report the failed claim"
  assert_present "$state/.claude-autoarm-failure-notified" "pid-reused transition failure did not write the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "pid-reused transition failure did not record outcome=failed"
  pass "auto-arm: pid-reused transition locks are reclaimed without signalling"
}

test_zombie_transition_holder_cannot_hide_failure() {
  local dir state ready holder fakeproc marker rc i
  dir=$(make_primary_dir "$TMP_ROOT/zombie-transition-failure")
  state="$dir/state"
  ready="$state/zombie-transition-ready"
  fakeproc="$dir/proc"
  marker="$state/.claude-autoarm-failure-notified"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_transition_acquire "$1/state" || exit
    : > "$2"
    while :; do sleep 1; done
  ' _ "$dir" "$ready" &
  holder=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$ready" ] || fail "transition holder did not acquire its boundary"
  mkdir -p "$fakeproc/$holder"
  printf '%s (zombie fixture) Z 1\n' "$holder" > "$fakeproc/$holder/stat"
  : > "$fakeproc/$holder/cmdline"

  FM_PROC_ROOT_OVERRIDE="$fakeproc" FM_AUTOARM_TRANSITION_GRACE=1 bash -c '
    . "$1"
    fm_autoarm_claim_failure_commit "$2" absent failed "$3"
  ' _ "$dir/bin/fm-wake-lib.sh" "$state" "$marker"
  rc=$?
  kill -0 "$holder" 2>/dev/null || fail "zombie-shaped transition holder was signalled"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 0 "$rc" "a zombie transition owner must be reclaimed for failure publication"
  assert_present "$marker" "zombie transition failure did not write the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "zombie transition failure did not record outcome=failed"
  pass "auto-arm: zombie transition owners cannot wedge failure publication"
}

test_fenced_arming_transition_rebases_failure() {
  local dir state ready marker holder baseline rc i
  dir=$(make_primary_dir "$TMP_ROOT/fenced-arming-transition")
  state="$dir/state"
  ready="$state/fenced-arming-ready"
  marker="$state/.claude-autoarm-failure-notified"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    fm_autoarm_transition_acquire "$state" || exit
    pid=${BASHPID:-$$}
    identity=$(fm_pid_identity "$pid") || exit
    printf "epoch=1 owner_pid=%s outcome=arming updated_at=%s\n%s\n" \
      "$pid" "$(date +%s)" "$identity" > "$state/.claude-autoarm-epoch"
    : > "$2"
    kill -STOP "$pid"
  ' _ "$dir" "$ready" &
  holder=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$ready" ] || fail "arming transition holder did not publish its claim"
  baseline="1:$holder:arming"

  FM_AUTOARM_TRANSITION_GRACE=1 bash -c '
    . "$1"
    fm_autoarm_claim_failure_commit "$2" absent failed "$3"
  ' _ "$dir/bin/fm-wake-lib.sh" "$state" "$marker"
  rc=$?
  kill -CONT "$holder" 2>/dev/null || true
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 0 "$rc" "a fenced nonterminal claim must be rebased into a durable failure"
  assert_present "$marker" "the fenced nonterminal claim did not leave a failure marker"
  [ "$(failure_epoch_outcome "$dir" "$baseline")" = failed ] \
    || fail "the fenced nonterminal claim did not leave a failed epoch"
  [ "$(failure_epoch_field "$dir" baseline "$baseline")" = "$baseline" ] \
    || fail "the failed epoch did not rebase onto the fenced arming claim"
  pass "auto-arm: fenced nonterminal claims are rebased into durable failures"
}

test_revoked_pid_reuse_defers_to_replacement_claim() {
  local dir state marker owner old_identity rc
  dir=$(make_primary_dir "$TMP_ROOT/revoked-pid-reuse")
  state="$dir/state"
  marker="$state/.claude-autoarm-failure-notified"
  sleep 60 &
  owner=$!
  record_autoarm_v2_claim "$dir" 2 "$owner" arming "$owner" \
    || fail "could not record the replacement claim"
  old_identity="revoked-owner-identity"

  FM_TEST_OWNER="$owner" FM_TEST_OLD_IDENTITY="$old_identity" bash -c '
    . "$1"
    fm_autoarm_failure_transition_acquire() {
      fm_autoarm_transition_try_acquire "$1" || return 1
      FM_AUTOARM_TRANSITION_REVOKED_PID=$FM_TEST_OWNER
      FM_AUTOARM_TRANSITION_REVOKED_SIGNATURE="1:$FM_TEST_OWNER:arming"
      FM_AUTOARM_TRANSITION_REVOKED_IDENTITY=$FM_TEST_OLD_IDENTITY
    }
    fm_autoarm_claim_failure_commit "$2" absent failed "$3"
  ' _ "$dir/bin/fm-wake-lib.sh" "$state" "$marker"
  rc=$?
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true

  expect_code 2 "$rc" "revoking an old claim must not authorize failure against its pid-reused replacement"
  assert_absent "$marker" "pid-reused replacement claim was falsely marked failed"
  assert_absent "$state/.claude-autoarm-failure-epochs" "pid-reused replacement claim received a false failure epoch"
  [ "$(epoch_field "$dir" epoch)" = 2 ] || fail "failure publisher rewrote the replacement claim"
  pass "auto-arm: revocation is fenced by the exact ledger claim"
}

test_fresh_prior_terminal_epoch_cannot_hide_current_failure() {
  local dir out status holder prior_gen
  dir=$(make_primary_dir "$TMP_ROOT/fresh-prior-terminal-failure")
  : > "$dir/state/task.meta"
  prior_gen=17
  printf 'epoch=%s owner_pid=9999999 outcome=rewake updated_at=%s\n' \
    "$prior_gen" "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-autoarm.lock/pid"

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 2 "$status" "a fresh prior terminal epoch must not hide the current claim failure"
  assert_contains "$out" "could not claim recovery" "fresh-epoch claim failure did not report the failed claim"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "fresh prior terminal epoch suppressed the current failure marker"
  [ "$(epoch_field "$dir" epoch)" -eq "$prior_gen" ] || fail "current failure rewrote the prior main generation"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "fresh prior terminal epoch still masks outcome=failed"
  [ "$(failure_epoch_field "$dir" baseline)" = "$prior_gen:9999999:rewake" ] \
    || fail "claim failure did not preserve the exact pre-attempt ledger snapshot"
  assert_absent "$dir/state/arm-ran" "fresh-epoch claim failure reached the arm"
  pass "auto-arm: prior terminal freshness cannot suppress a current claim failure"
}

test_concurrent_claim_failures_publish_one_notice_atomically() {
  local dir holder rc1 rc2 notices
  dir=$(make_primary_dir "$TMP_ROOT/concurrent-claim-failures")
  : > "$dir/state/task.meta"
  printf 'epoch=17 owner_pid=9999999 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-autoarm.lock/pid"

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
  notices=$(grep -h -c 'could not claim recovery' "$dir/state/err1" "$dir/state/err2" | awk '{ total += $1 } END { print total + 0 }')
  printf 'epoch=18 owner_pid=%s outcome=arming updated_at=%s\n' \
    "$holder" "$(date +%s)" > "$dir/state/.claude-autoarm-epoch"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  expect_code 2 "$rc1" "the first concurrent claim failure must request another Stop-owned retry"
  expect_code 2 "$rc2" "the second concurrent claim failure must request another Stop-owned retry"
  [ "$notices" -eq 1 ] || fail "concurrent claim failures emitted $notices notices instead of one"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "concurrent claim failures did not publish the failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "concurrent claim failures did not publish a valid independent failure epoch"
  [ "$(epoch_outcome "$dir")" = arming ] || fail "fixture did not reproduce the stalled claimant's later main-ledger write"
  pass "auto-arm: concurrent claim failures atomically elect one notice and retain independent failure state"
}

test_stale_failure_publisher_cannot_emit_after_success() {
  local dir state ready release stale_pid i rc stale_path err
  dir=$(make_primary_dir "$TMP_ROOT/stale-failure-publisher")
  state="$dir/state"
  ready="$state/stale-publisher-ready"
  release="$state/stale-publisher-release"
  : > "$state/task.meta"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    stalled=0
    ln() {
      local target= arg
      for arg in "$@"; do target=$arg; done
      if [ "$target" = "$state/.claude-autoarm-transition.lock" ] \
        && [ "$stalled" -eq 0 ]; then
        stalled=1
        : > "$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
      fi
      command ln "$@"
    }
    fm_autoarm_claim_failure_commit "$state" 17:700:rewake failed \
      "$state/.claude-autoarm-failure-notified"
    printf "%s\n" "$?" > "$state/stale-publisher-rc"
  ' _ "$dir" "$ready" "$release" 2> "$state/stale-publisher-err" &
  stale_pid=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$ready" ]; then
    kill "$stale_pid" 2>/dev/null || true
    wait "$stale_pid" 2>/dev/null || true
    fail "stale failure publisher did not reach its publication boundary"
  fi

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_claim_next "$1/state" || exit
    fm_autoarm_write_owned "$1/state" "$FM_AUTOARM_MY_GEN" rewake
  ' _ "$dir" || fail "later successful ledger transition could not commit"
  : > "$release"
  wait "$stale_pid" || fail "stale failure publisher fixture exited unexpectedly"

  rc=$(cat "$state/stale-publisher-rc")
  expect_code 2 "$rc" "stale publisher must stand down after the later successful transition"
  stale_path=$(failure_epoch_path "$dir" 17:700:rewake)
  assert_absent "$stale_path" "stale publisher committed a failure after the successful transition"
  assert_absent "$state/.claude-autoarm-failure-notified" "stale publisher elected a failure notice after success"
  err=$(cat "$state/stale-publisher-err")
  [ -z "$err" ] || fail "stale publisher emitted failure output after success: $err"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale publisher disturbed the successful terminal ledger"
  pass "auto-arm: a later successful ledger transition silences a stalled failure publisher"
}

test_recovery_reset_cannot_be_followed_by_stalled_failure_publication() {
  local dir state ready release publisher resetter i
  dir=$(make_primary_dir "$TMP_ROOT/reset-failure-publication")
  state="$dir/state"
  ready="$state/failure-publisher-ready"
  release="$state/failure-publisher-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    stalled=0
    mkdir() {
      if [ "${1:-}" = "$state/.claude-autoarm-failure-epochs" ] \
        && [ "$stalled" -eq 0 ]; then
        stalled=1
        : > "$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
      fi
      command mkdir "$@"
    }
    fm_autoarm_claim_failure_commit "$state" 17:700:rewake failed \
      "$state/.claude-autoarm-failure-notified"
  ' _ "$dir" "$ready" "$release" &
  publisher=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$ready" ] || fail "failure publisher did not reach its serialized boundary"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    : > "$1/state/reset-started"
    fm_failure_episode_reset "$1/state"
  ' _ "$dir" &
  resetter=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$state/reset-started" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$state/reset-started" ] || fail "recovery reset did not start"
  : > "$release"
  wait "$publisher" || fail "stalled failure publisher could not commit before reset"
  wait "$resetter" || fail "serialized recovery reset could not complete"

  assert_absent "$state/.claude-autoarm-failure-notified" "failure publication recreated the notice after recovery reset"
  assert_absent "$state/.claude-autoarm-failure-epochs" "failure publication recreated an epoch after recovery reset"
  pass "auto-arm: recovery reset serializes after in-flight failure publication"
}

test_lockless_failure_publication_cannot_cross_recovery_reset() {
  local dir state ready release publisher rc reset current_rc notice_rc retry_rc i
  dir=$(make_primary_dir "$TMP_ROOT/lockless-reset-failure-publication")
  state="$dir/state"
  ready="$state/lockless-publisher-ready"
  release="$state/lockless-publisher-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    marker="$state/.claude-autoarm-failure-notified"
    stalled=0
    fm_autoarm_failure_transition_acquire() { return 1; }
    mkdir() {
      if [ "${1:-}" = "$marker" ] && [ "$stalled" -eq 0 ]; then
        stalled=1
        : > "$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
      fi
      command mkdir "$@"
    }
    fm_autoarm_claim_failure_commit "$state" 17:700:rewake failed "$marker"
    printf "%s\n" "$?" > "$state/lockless-publisher-rc"
  ' _ "$dir" "$ready" "$release" &
  publisher=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$ready" ]; then
    kill "$publisher" 2>/dev/null || true
    wait "$publisher" 2>/dev/null || true
    fail "lockless publisher did not reach its notice boundary"
  fi

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_failure_episode_reset "$1/state"
  ' _ "$dir" || fail "recovery reset could not advance its failure fence"
  reset=$(cat "$state/.claude-autoarm-failure-reset")
  : > "$release"
  wait "$publisher" || fail "lockless failure publisher fixture exited unexpectedly"
  rc=$(cat "$state/lockless-publisher-rc")
  expect_code 4 "$rc" "a lockless publisher crossing recovery reset must stand down"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_ledger_current "$1/state"
  ' _ "$dir"
  current_rc=$?
  expect_code 1 "$current_rc" "a pre-reset failure record must not become current after reset"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_notice_current "$1/state" \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir"
  notice_rc=$?
  expect_code 1 "$notice_rc" "a pre-reset publisher must not recreate the current notice"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_transition_acquire() { return 1; }
    fm_autoarm_claim_failure_commit "$1/state" 17:700:rewake failed \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir"
  retry_rc=$?
  expect_code 0 "$retry_rc" "a post-reset failure must elect a fresh notice"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_ledger_current "$1/state" \
      && [ "$FM_AUTOARM_FAILURE_RESET" = "$2" ] \
      && fm_autoarm_failure_notice_current "$1/state" \
        "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir" "$reset" || fail "post-reset failure state did not bind to the new fence"
  pass "auto-arm: lockless failure publication cannot cross a recovery reset"
}

test_failure_allocation_cannot_adopt_later_reset_fence() {
  local dir state ready release publisher rc i
  dir=$(make_primary_dir "$TMP_ROOT/failure-allocation-reset-fence")
  state="$dir/state"
  ready="$state/failure-allocation-ready"
  release="$state/failure-allocation-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    fm_autoarm_failure_sequence_next() {
      local sequence epoch=123456
      sequence="$state/.claude-autoarm-failure-sequence"
      mkdir -p "$sequence" || return
      mkdir "$sequence/$epoch" || return
      : > "$ready"
      while [ ! -e "$release" ]; do sleep 0.01; done
      printf "%s\n" "$epoch"
    }
    fm_autoarm_failure_transition_acquire() { return 1; }
    fm_autoarm_claim_failure_commit "$state" 17:700:rewake failed \
      "$state/.claude-autoarm-failure-notified"
    printf "%s\n" "$?" > "$state/failure-allocation-rc"
  ' _ "$dir" "$ready" "$release" &
  publisher=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$ready" ]; then
    kill "$publisher" 2>/dev/null || true
    wait "$publisher" 2>/dev/null || true
    fail "failure publisher did not pause during epoch allocation"
  fi

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_failure_episode_reset "$1/state"
  ' _ "$dir" || fail "recovery reset could not advance during failure allocation"
  : > "$release"
  wait "$publisher" || fail "failure allocation fixture exited unexpectedly"
  rc=$(cat "$state/failure-allocation-rc")

  expect_code 4 "$rc" "a pre-reset failure allocation must retain its sampled fence"
  assert_absent "$state/.claude-autoarm-failure-epochs" "pre-reset allocation recreated failure state after recovery"
  assert_absent "$state/.claude-autoarm-failure-notified" "pre-reset allocation recreated the failure notice after recovery"
  pass "auto-arm: failure allocation cannot adopt a later recovery fence"
}

test_reset_transaction_blocks_new_fence_publication() {
  local dir state ready release resetter publisher reset_rc publish_rc before after i
  dir=$(make_primary_dir "$TMP_ROOT/reset-transaction-publication")
  state="$dir/state"
  ready="$state/reset-fence-visible"
  release="$state/reset-clear-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_claim_failure_commit "$1/state" 17:700:rewake failed \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir" || fail "could not seed failure state for reset transaction"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    stalled=0
    mv() {
      local arg target= rc
      for arg in "$@"; do target=$arg; done
      command mv "$@"
      rc=$?
      if [ "$rc" -eq 0 ] && [ "$target" = "$state/.claude-autoarm-failure-reset" ] \
        && [ "$stalled" -eq 0 ]; then
        stalled=1
        : > "$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
      fi
      return "$rc"
    }
    fm_failure_episode_reset "$state"
    printf "%s\n" "$?" > "$state/reset-transaction-rc"
  ' _ "$dir" "$ready" "$release" &
  resetter=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$ready" ]; then
    kill "$resetter" 2>/dev/null || true
    wait "$resetter" 2>/dev/null || true
    fail "reset transaction did not expose its fenced cleanup window"
  fi
  assert_present "$state/.claude-autoarm-failure-resetting" "reset exposed its next fence without an in-progress marker"
  before=$(find "$state/.claude-autoarm-failure-epochs" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_transition_acquire() { return 1; }
    fm_autoarm_claim_failure_commit "$1/state" 17:700:rewake failed \
      "$1/state/.claude-autoarm-failure-notified"
    printf "%s\n" "$?" > "$1/state/reset-window-publisher-rc"
  ' _ "$dir" &
  publisher=$!
  wait "$publisher" || fail "reset-window publisher fixture exited unexpectedly"
  publish_rc=$(cat "$state/reset-window-publisher-rc")
  after=$(find "$state/.claude-autoarm-failure-epochs" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')
  expect_code 4 "$publish_rc" "failure publication must stand down while reset cleanup is in progress"
  [ "$after" -eq "$before" ] || fail "reset-window publisher added a new-fence failure record"

  : > "$release"
  wait "$resetter" || fail "reset transaction could not complete cleanup"
  reset_rc=$(cat "$state/reset-transaction-rc")
  expect_code 0 "$reset_rc" "reset transaction did not complete after its cleanup window"
  assert_absent "$state/.claude-autoarm-failure-resetting" "completed reset left its transaction marker"
  assert_absent "$state/.claude-autoarm-failure-epochs" "completed reset left failure records"
  assert_absent "$state/.claude-autoarm-failure-notified" "completed reset left the failure notice"
  pass "auto-arm: reset transactions reject publication until cleanup completes"
}

test_stale_reset_transaction_is_completed_before_publication() {
  local dir state ready release resetter rc retry_rc i
  dir=$(make_primary_dir "$TMP_ROOT/stale-reset-transaction")
  state="$dir/state"
  ready="$state/stale-reset-ready"
  release="$state/stale-reset-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_claim_failure_commit "$1/state" 17:700:rewake failed \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir" || fail "could not seed failure state for stale reset recovery"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    stalled=0
    mv() {
      local arg target= rc
      for arg in "$@"; do target=$arg; done
      command mv "$@"
      rc=$?
      if [ "$rc" -eq 0 ] && [ "$target" = "$state/.claude-autoarm-failure-reset" ] \
        && [ "$stalled" -eq 0 ]; then
        stalled=1
        : > "$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
      fi
      return "$rc"
    }
    fm_failure_episode_reset "$state"
  ' _ "$dir" "$ready" "$release" &
  resetter=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$ready" ]; then
    kill "$resetter" 2>/dev/null || true
    wait "$resetter" 2>/dev/null || true
    fail "stale reset fixture did not reach its cleanup window"
  fi
  kill "$resetter" 2>/dev/null || true
  wait "$resetter" 2>/dev/null || true

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_claim_failure_commit "$1/state" 17:700:rewake failed \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir"
  rc=$?
  expect_code 4 "$rc" "the first publisher after a stale reset must complete recovery and stand down"
  assert_absent "$state/.claude-autoarm-failure-resetting" "stale reset transaction was not completed"
  assert_absent "$state/.claude-autoarm-failure-epochs" "stale reset recovery left old failure records"
  assert_absent "$state/.claude-autoarm-failure-notified" "stale reset recovery left the old notice"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_claim_failure_commit "$1/state" 17:700:rewake failed \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir"
  retry_rc=$?
  expect_code 0 "$retry_rc" "publication after stale reset recovery must create current durable state"
  assert_present "$state/.claude-autoarm-failure-epochs" "post-recovery publication did not persist a failure record"
  assert_present "$state/.claude-autoarm-failure-notified" "post-recovery publication did not persist its notice"
  pass "auto-arm: stale reset transactions complete before later publication"
}

test_lockless_failure_notice_is_released_after_ledger_advance() {
  local dir state ready release publisher rc notice_rc i
  dir=$(make_primary_dir "$TMP_ROOT/lockless-ledger-advance")
  state="$dir/state"
  ready="$state/lockless-final-check-ready"
  release="$state/lockless-final-check-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    fm_autoarm_failure_transition_acquire() { return 1; }
    fm_autoarm_claim_signature() {
      : > "$ready"
      while [ ! -e "$release" ]; do sleep 0.01; done
      if fm_autoarm_ledger_read "$state"; then
        printf "%s:%s:%s\n" "$FM_AUTOARM_GEN" "$FM_AUTOARM_OWNER" "$FM_AUTOARM_OUTCOME"
      else
        printf "absent\n"
      fi
    }
    fm_autoarm_claim_failure_commit "$state" 17:700:rewake failed \
      "$state/.claude-autoarm-failure-notified"
    printf "%s\n" "$?" > "$state/lockless-ledger-publisher-rc"
  ' _ "$dir" "$ready" "$release" &
  publisher=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$ready" ]; then
    kill "$publisher" 2>/dev/null || true
    wait "$publisher" 2>/dev/null || true
    fail "lockless publisher did not reach its final ledger check"
  fi
  printf 'epoch=18 owner_pid=800 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"
  : > "$release"
  wait "$publisher" || fail "lockless ledger publisher fixture exited unexpectedly"
  rc=$(cat "$state/lockless-ledger-publisher-rc")
  expect_code 4 "$rc" "a lockless publisher superseded by ledger advance must stand down"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_notice_current "$1/state" \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir"
  notice_rc=$?
  expect_code 1 "$notice_rc" "a superseded lockless publisher must release its notice election"
  assert_absent "$state/.claude-autoarm-failure-notified" "ledger supersession left a stale failure marker"
  pass "auto-arm: ledger supersession releases lockless failure notices"
}

test_lockless_failure_notice_is_released_when_reset_starts() {
  local dir state publisher resetter ready release reset_ready reset_release rc notice_rc i
  dir=$(make_primary_dir "$TMP_ROOT/lockless-reset-start")
  state="$dir/state"
  ready="$state/lockless-final-check-ready"
  release="$state/lockless-final-check-release"
  reset_ready="$state/reset-start-ready"
  reset_release="$state/reset-start-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    fm_autoarm_failure_transition_acquire() { return 1; }
    fm_autoarm_claim_signature() {
      : > "$ready"
      while [ ! -e "$release" ]; do sleep 0.01; done
      if fm_autoarm_ledger_read "$state"; then
        printf "%s:%s:%s\n" "$FM_AUTOARM_GEN" "$FM_AUTOARM_OWNER" "$FM_AUTOARM_OUTCOME"
      else
        printf "absent\n"
      fi
    }
    fm_autoarm_claim_failure_commit "$state" 17:700:rewake failed \
      "$state/.claude-autoarm-failure-notified"
    printf "%s\n" "$?" > "$state/lockless-reset-start-rc"
  ' _ "$dir" "$ready" "$release" &
  publisher=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$ready" ]; then
    kill "$publisher" 2>/dev/null || true
    wait "$publisher" 2>/dev/null || true
    fail "lockless publisher did not reach its final reset check"
  fi

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    stalled=0
    mv() {
      local arg target= rc
      for arg in "$@"; do target=$arg; done
      command mv "$@"
      rc=$?
      if [ "$rc" -eq 0 ] && [ "$target" = "$state/.claude-autoarm-failure-resetting" ] \
        && [ "$stalled" -eq 0 ]; then
        stalled=1
        : > "$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
      fi
      return "$rc"
    }
    fm_failure_episode_reset "$state"
  ' _ "$dir" "$reset_ready" "$reset_release" &
  resetter=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$reset_ready" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$reset_ready" ]; then
    kill "$publisher" "$resetter" 2>/dev/null || true
    wait "$publisher" "$resetter" 2>/dev/null || true
    fail "reset did not reach its pre-fence transaction boundary"
  fi
  : > "$release"
  wait "$publisher" || fail "lockless reset-start publisher fixture exited unexpectedly"
  rc=$(cat "$state/lockless-reset-start-rc")
  expect_code 4 "$rc" "a lockless publisher must stand down when reset starts before fence advance"
  assert_absent "$state/.claude-autoarm-failure-notified" "reset-start supersession left a stale notice election"
  : > "$reset_release"
  wait "$resetter" || fail "reset-start fixture could not complete cleanup"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_failure_notice_current "$1/state" \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir"
  notice_rc=$?
  expect_code 1 "$notice_rc" "reset-start supersession left a current failure notice"
  pass "auto-arm: reset start supersedes lockless publication before fence advance"
}

test_failure_reader_rejects_record_superseded_during_selection() {
  local dir state ready release reader rc i
  dir=$(make_primary_dir "$TMP_ROOT/failure-reader-superseded")
  state="$dir/state"
  ready="$state/failure-reader-ready"
  release="$state/failure-reader-release"
  printf 'epoch=17 owner_pid=700 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"
  mkdir -p "$state/.claude-autoarm-failure-epochs"
  printf 'epoch=123 owner_pid=701 outcome=failed baseline=17:700:rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-failure-epochs/17.700.rewake"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    state=$1/state
    ready=$2
    release=$3
    stalled=0
    fm_autoarm_failure_ledger_read() {
      if [ "${2:-}" = "$state/.claude-autoarm-failure-epochs/17.700.rewake" ]; then
        FM_AUTOARM_FAILURE_EPOCH=123
        FM_AUTOARM_FAILURE_OWNER=701
        FM_AUTOARM_FAILURE_OUTCOME=failed
        FM_AUTOARM_FAILURE_BASELINE=17:700:rewake
        FM_AUTOARM_FAILURE_RESET=legacy
        FM_AUTOARM_FAILURE_PATH=$2
      else
        return 1
      fi
      if [ "$stalled" -eq 0 ]; then
        stalled=1
        : > "$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
      fi
      return 0
    }
    fm_autoarm_failure_ledger_current "$state"
    printf "%s\n" "$?" > "$state/failure-reader-rc"
  ' _ "$dir" "$ready" "$release" &
  reader=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$ready" ] || fail "failure reader did not reach its selection boundary"
  printf 'epoch=18 owner_pid=800 outcome=rewake updated_at=%s\n' \
    "$(date +%s)" > "$state/.claude-autoarm-epoch"
  : > "$release"
  wait "$reader" || fail "failure reader fixture exited unexpectedly"

  rc=$(cat "$state/failure-reader-rc")
  expect_code 1 "$rc" "failure reader must reject a record superseded during selection"
  pass "auto-arm: current-failure selection rejects a concurrently superseded record"
}

test_terminal_commit_failure_publishes_independent_failure() {
  local dir out status baseline failure
  dir=$(make_primary_dir "$TMP_ROOT/terminal-commit-failure")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  cat >> "$dir/bin/fm-wake-lib.sh" <<'SH'
fm_autoarm_write_owned() {
  return 1
}
SH

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?

  expect_code 2 "$status" "an unavailable terminal commit must request a visible recovery turn"
  assert_contains "$out" "could not commit its terminal outcome" "terminal commit failure did not report its fallback"
  [ "$(epoch_outcome "$dir")" = arming ] || fail "fixture did not leave the claimed generation open"
  baseline="$(epoch_field "$dir" epoch):$(epoch_field "$dir" owner_pid):arming"
  failure=$(failure_epoch_path "$dir" "$baseline")
  assert_present "$failure" "terminal commit failure did not publish an independent failed epoch"
  [ "$(failure_epoch_field "$dir" baseline)" = "$baseline" ] \
    || fail "terminal commit failure did not retain the exact arming signature"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "terminal commit failure did not publish its notice marker"
  pass "auto-arm: unavailable terminal commits publish durable independent failure state"
}

test_terminal_failure_fallback_cannot_publish_after_session_transfer() {
  local dir out owner hook successor status i
  dir=$(make_primary_dir "$TMP_ROOT/terminal-fallback-session-transfer")
  out="$dir/hook.out"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  cat >> "$dir/bin/fm-wake-lib.sh" <<'SH'
fm_autoarm_write_owned() {
  return 1
}

fm_lock_acquire_wait() {
  local lockdir=$1 count
  if [ "$lockdir" = "$STATE/.lock.acquire" ]; then
    count=$(cat "$STATE/session-lease-count" 2>/dev/null || true)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE/session-lease-count"
    if [ "$count" -eq 2 ]; then
      : > "$STATE/terminal-fallback-waiting"
      while [ ! -e "$STATE/terminal-fallback-release" ]; do sleep 0.01; done
    fi
  fi
  while ! fm_lock_try_acquire "$lockdir"; do sleep 0.01; done
}
SH
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  owner=$!
  printf '%s\n' "$owner" > "$dir/state/.lock"

  run_autoarm_from_claude_daemon_bridge "$dir" "$owner" > "$out" 2>&1 &
  hook=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/terminal-fallback-waiting" ]; do sleep 0.01; i=$((i + 1)); done
  if [ ! -e "$dir/state/terminal-fallback-waiting" ]; then
    kill "$hook" "$owner" 2>/dev/null || true
    wait "$hook" "$owner" 2>/dev/null || true
    fail "terminal fallback did not reach its session authorization boundary"
  fi
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    "$FM_HOME/bin/fm-lock.sh" >/dev/null 2>&1
    printf "%s\n" "$?" > "$FM_HOME/state/successor-lock-rc"
    sleep 60
  ' &
  successor=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -e "$dir/state/successor-lock-rc" ]; do sleep 0.01; i=$((i + 1)); done
  expect_code 0 "$(cat "$dir/state/successor-lock-rc" 2>/dev/null || true)" "successor did not acquire before terminal fallback publication"
  : > "$dir/state/terminal-fallback-release"
  wait "$hook"; status=$?
  kill "$successor" 2>/dev/null || true
  wait "$successor" 2>/dev/null || true

  expect_code 0 "$status" "obsolete terminal fallback must stand down after session transfer"
  assert_absent "$dir/state/.claude-autoarm-failure-epochs" "obsolete terminal fallback published a failure epoch"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "obsolete terminal fallback published a failure marker"
  pass "auto-arm: terminal failure fallback is fenced from successor sessions"
}

test_terminal_commit_supersession_stays_silent() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/terminal-commit-superseded")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  cat >> "$dir/bin/fm-wake-lib.sh" <<'SH'
fm_autoarm_write_owned() {
  return 2
}
SH

  run_autoarm "$dir" >/dev/null 2>&1; status=$?

  expect_code 0 "$status" "verified terminal supersession must remain silent"
  assert_absent "$dir/state/.claude-autoarm-failure-epochs" "verified supersession published a false independent failure"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "verified supersession consumed a failure notice"
  pass "auto-arm: verified terminal supersession remains silent"
}

test_failure_sequence_compacts_at_recovery_reset() {
  local dir state first stalled reset next count stale_rc
  dir=$(make_primary_dir "$TMP_ROOT/failure-sequence-compaction")
  state="$dir/state"
  first=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_autoarm_failure_sequence_next "$1/state"' _ "$dir") \
    || fail "could not allocate the first failure sequence"
  stalled=$first
  for _ in 1 2 3 4 5 6 7 8 9; do
    stalled=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_autoarm_failure_sequence_next "$1/state"' _ "$dir") \
      || fail "could not allocate a historical failure sequence"
  done

  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_failure_episode_reset "$1/state"' _ "$dir" \
    || fail "recovery reset could not compact the failure sequence"
  reset=$(cat "$state/.claude-autoarm-failure-reset")
  [ "$reset" -gt "$stalled" ] || fail "recovery reset did not advance past historical allocations"
  [ "$(cat "$state/.claude-autoarm-failure-sequence/high-water")" = "$reset" ] \
    || fail "sequence compaction did not preserve the reset high-water value"
  count=$(find "$state/.claude-autoarm-failure-sequence" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$count" -eq 0 ] || fail "sequence compaction retained $count obsolete token directories"

  next=$(bash -c '. "$1/bin/fm-wake-lib.sh"; fm_autoarm_failure_sequence_next "$1/state"' _ "$dir") \
    || fail "could not allocate after sequence compaction"
  [ "$next" -gt "$reset" ] || fail "post-reset failure sequence did not remain monotonic"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    _fm_autoarm_claim_failure_publish "$1/state" absent failed "$2" 0 \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir" "$stalled"
  stale_rc=$?
  expect_code 4 "$stale_rc" "a pre-reset stalled publisher must remain fenced after compaction"
  assert_absent "$state/.claude-autoarm-failure-epochs" "pre-reset stalled publisher recreated failure state"
  pass "auto-arm: recovery reset compacts sequence history without weakening fences"
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

test_post_alarm_claim_failures_do_not_grow_episode_state() {
  local dir state marker alarm holder status sequence_before sequence_after
  local failures_before failures_after i
  dir=$(make_primary_dir "$TMP_ROOT/post-alarm-claim-failures")
  state="$dir/state"
  marker="$state/.claude-autoarm-failure-notified"
  alarm="$state/.claude-autoarm-failure-alarmed"
  : > "$state/task.meta"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_autoarm_claim_failure_commit "$1/state" absent failed \
      "$1/state/.claude-autoarm-failure-notified"
  ' _ "$dir" || fail "could not seed the attended failure episode"
  : > "$alarm"
  sleep 60 &
  holder=$!
  mkdir -p "$state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$state/.claude-autoarm.lock/pid"
  sequence_before=$(find "$state/.claude-autoarm-failure-sequence" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  failures_before=$(find "$state/.claude-autoarm-failure-epochs" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')

  i=0
  while [ "$i" -lt 6 ]; do
    run_autoarm "$dir" >/dev/null 2>&1
    status=$?
    expect_code 0 "$status" "a current attended alarm must suppress later claim failures"
    i=$((i + 1))
  done
  sequence_after=$(find "$state/.claude-autoarm-failure-sequence" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  failures_after=$(find "$state/.claude-autoarm-failure-epochs" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$sequence_after" -eq "$sequence_before" ] \
    || fail "post-alarm claim failures grew sequence state from $sequence_before to $sequence_after"
  [ "$failures_after" -eq "$failures_before" ] \
    || fail "post-alarm claim failures grew immutable records from $failures_before to $failures_after"
  assert_present "$alarm" "post-alarm claim failures cleared the attended alarm"
  assert_present "$marker" "post-alarm claim failures cleared the episode notice"
  pass "auto-arm: attended alarms bound continuing claim-failure state growth"
}

test_failure_notice_marker_write_refuses_delivery_and_retries() {
  local dir marker out1 out2 out3 status1 status2 status3 gen1 delivered
  dir=$(make_primary_dir "$TMP_ROOT/failed-marker-refusal")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  marker="$dir/state/.claude-autoarm-failure-notified"
  ln -s "$dir/state/missing/notice" "$marker"

  out1=$(run_autoarm "$dir" 2>/dev/null); status1=$?
  expect_code 0 "$status1" "an unrecordable failure notice must refuse delivery"
  [ -L "$marker" ] || fail "the failed marker write unexpectedly replaced its dangling symlink"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "the refused generation must leave its terminal ledger outcome"
  gen1=$(epoch_field "$dir" epoch)

  rm -f "$marker"
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  out3=$(run_autoarm "$dir" 2>/dev/null); status3=$?
  expect_code 2 "$status2" "a successor must retry and deliver after the marker path is restored"
  expect_code 2 "$status3" "a later failure must retain the Stop-owned retry"
  [ "$(epoch_field "$dir" epoch)" -gt "$gen1" ] || fail "the successor did not supersede the refused terminal entry"
  assert_present "$marker" "the successful successor did not record the failure notice"
  assert_contains "$out2" "automatic supervision mechanism is broken" "the successful successor did not deliver the failure notice"
  [ -z "$out3" ] || fail "the firing after the successful marker commit repeated the notice: $out3"
  delivered=$(printf '%s\n%s\n' "$out2" "$out3" | grep -c 'automatic supervision mechanism is broken' || true)
  [ "$delivered" -eq 1 ] || fail "the restored episode delivered $delivered failure notices instead of one"
  pass "auto-arm: marker-write refusal defers delivery until one successor commits the notice"
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

test_owner_mutex_contention_preserves_failure_episode_reset() {
  local dir out hook_pid status watcher watcher_id holder i
  dir=$(make_primary_dir "$TMP_ROOT/reset-owner-contention")
  : > "$dir/state/task.meta"
  : > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" reset-boundary
  sleep 60 &
  watcher=$!
  watcher_id=$(watcher_identity "$dir" "$watcher") || fail "could not identify reset-contention watcher"
  record_watcher_lock "$dir" "$watcher" "$watcher_id"
  touch "$dir/state/.last-watcher-beat"
  out="$dir/state/hook.out"
  run_autoarm_bg "$dir" "$out"
  hook_pid=$RUN_AUTOARM_BG_PID
  i=0
  while [ ! -e "$dir/state/arm-waiting" ]; do
    [ "$i" -lt 50 ] || fail "healthy owner never reached the reset boundary"
    sleep 0.05
    i=$((i + 1))
  done
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-autoarm.lock/pid"
  : > "$dir/state/arm-release"
  wait "$hook_pid"; status=$?
  expect_code 0 "$status" "owner-mutex contention at reset must close quietly"
  [ ! -s "$out" ] || fail "owner-mutex contention at reset produced output: $(cat "$out")"
  assert_present "$dir/state/.turnend-claude-blocks" "contended reset deleted the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "contended reset deleted the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "contended reset deleted the attended alarm"
  kill "$holder" "$watcher" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  rm -rf "$dir/state/.claude-autoarm.lock"
  pass "auto-arm: owner-mutex contention preserves successor episode state"
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

# --- abandoned single-flight claim recovery (legacy shim) ----------------------
# The 2026-08-14 lapse: one cycle armed, beat its beacon, delivered a single
# rewake, and exited, leaving its owner lock behind with a live pid. The single
# flight gate then turned every later firing into exit 0, so with two tasks in
# flight and a beacon 40 minutes cold nothing re-armed and both workers' reports
# sat unread until an operator drained the queue by hand. The lock alone is not
# enough to prove that: the ledger naming that same pid with a finished outcome,
# or a recorded pid-identity the live pid no longer matches, is what distinguishes
# an abandoned claim from one still deciding.
#
# These fixtures fabricate the LOCK-HOLDING claim shape a pre-generation build
# leaves behind, so this section pins the legacy shim: a live legacy owner
# still defers the gate, and an abandoned one is reclaimed once so the home
# re-arms - with an identity-verified live owner retired via TERM first, and
# an identityless one reclaimed without any signalling. The generation-claim
# section below pins the current contract.

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
  awk -v field="$field" '
    NR == 1 {
      for (i = 1; i <= NF; i += 1) {
        split($i, pair, "=")
        if (pair[1] == field) { print pair[2]; exit }
      }
    }
  ' "$dir/state/.claude-autoarm-epoch" 2>/dev/null || true
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
  kill -0 "$pid" 2>/dev/null || fail "an identityless abandoned owner must be reclaimed without being signalled"
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

test_stale_terminal_epoch_dead_owner_does_not_prevent_next_claim() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/dead-terminal-epoch")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  record_autoarm_epoch "$dir" 8121 9999999 rewake

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?

  expect_code 2 "$status" "a stale terminal epoch naming a dead owner must not block the next claim"
  [ -e "$dir/state/arm-ran" ] || fail "dead-owner terminal epoch left the home unarmed"
  assert_contains "$out" "firstmate watcher wake" "dead-owner terminal epoch did not allow wake translation"
  [ "$(epoch_field "$dir" epoch)" -gt 8121 ] || fail "dead-owner terminal epoch was not superseded"
  [ "$(epoch_field "$dir" owner_pid)" != 9999999 ] || fail "new claim still names the dead owner"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "new claim did not record outcome=rewake"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "dead-owner terminal epoch should not create a failure marker"
  pass "auto-arm: stale terminal epochs naming dead owners are superseded by the next claim"
}

test_arming_claim_with_fresh_beacon_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/arming-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # An owner foregrounds the arm for the whole watcher cycle, so an old "arming"
  # entry is still in progress while its watcher keeps beating the beacon.
  record_autoarm_epoch "$dir" 464 "$pid" arming
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a legacy claim still arming under a fresh beacon must keep the single-flight gate closed"
  [ -z "$out" ] || fail "deferring to an arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an arming claim was stolen and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the arming ledger entry"
  assert_present "$dir/state/.claude-autoarm.lock" "an arming claim lost its owner lock"
  pass "auto-arm: a legacy owner still arming is never reclaimed while its watcher keeps beating"
}

# The other legitimate legacy arming shape: a claim that JUST started arming
# after a real lapse, so the beacon is long stale but the entry is fresh. The
# arm's bounded startup window must never be stolen out from under it.
test_fresh_arming_claim_with_stale_beacon_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/fresh-arming-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=%s\n' "$pid" "$(date +%s)" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a freshly arming legacy claim must keep the single-flight gate closed even after a long lapse"
  [ -z "$out" ] || fail "deferring to a fresh arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a fresh arming claim was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "a fresh arming claim lost its owner lock"
  pass "auto-arm: a fresh legacy arming claim is never reclaimed while its startup window is still open"
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

test_stale_unmatched_legacy_claim_reports_without_signalling() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/stale-unmatched-legacy")
  : > "$dir/state/task1.meta"
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_epoch "$dir" 464 999 rewake
  touch -t 202001010000 "$dir/state/.claude-autoarm.lock"

  out=$(FM_GUARD_GRACE=1 run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "an unmatched legacy holder must not be signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  expect_code 2 "$status" "a stale unmatched legacy claim must report a durable failure"
  assert_contains "$out" "did not publish a matching ledger" "the unmatched legacy claim failure was not identified"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "the unmatched legacy claim did not publish its failure marker"
  [ "$(failure_epoch_outcome "$dir")" = failed ] || fail "the unmatched legacy claim did not publish a failed epoch"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "failure reporting rewrote the prior main epoch"
  pass "auto-arm: stale unmatched legacy claims report without signalling unverified owners"
}

# The same unrecoverable lapse, reached where the ledger cannot prove it: a session
# teardown kills the claim's whole process group before it records any outcome, so
# the entry still reads "arming" while the recorded pid is later handed to an
# unrelated live process. Only the identity the claim recorded inside its own lock
# separates that from a real arm in progress, so keep the beacon fresh here: this
# case must reclaim on the identity leg alone, not the stuck-arming leg. The
# reclaim must not signal the unrelated live process that inherited the number.
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
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "the unrelated live process inheriting the number must never be signalled"
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
# legitimately been running for hours - its watcher beating the whole time - must
# keep the single-flight gate closed.
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
  : > "$dir/state/.last-watcher-beat"
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

# A proven-stuck legacy owner that is still ALIVE and identity-verified is
# retired with TERM before its lock is removed, because old-build code cannot
# re-check generations and would otherwise resume and act after supersession.
test_stuck_live_legacy_owner_is_retired_and_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/legacy-term")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a proven-stuck identity-verified live legacy owner must be retired and reclaimed"
  kill -0 "$pid" 2>/dev/null && fail "the stuck legacy owner was reclaimed without being retired"
  wait "$pid" 2>/dev/null || true
  [ -e "$dir/state/arm-ran" ] || fail "the reclaimed home did not re-arm"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaim left the legacy owner lock behind"
  pass "auto-arm: a stuck live legacy owner is retired via TERM and its lock reclaimed"
}

# The SIGSTOP counterfactual: a stopped legacy owner survives the bounded
# retirement wait with TERM queued, and the reclaim must proceed anyway - a
# pending TERM on the verified owner is retirement-safe because delivery
# precedes any further user code when the process continues.
test_stopped_legacy_owner_is_reclaimed_with_term_pending() {
  local dir out status pid i
  dir=$(make_primary_dir "$TMP_ROOT/legacy-term-stopped")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  kill -STOP "$pid" 2>/dev/null || fail "could not stop the legacy owner fixture"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a stopped legacy owner with TERM queued must not block the reclaim forever"
  [ -e "$dir/state/arm-ran" ] || fail "the reclaimed home did not re-arm past the stopped owner"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaim left the stopped owner's lock behind"
  kill -CONT "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 40 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && fail "the queued TERM did not retire the owner on continue"
  wait "$pid" 2>/dev/null || true
  pass "auto-arm: a SIGSTOPped legacy owner is reclaimed with TERM pending and dies on continue"
}

# --- generation claims: optimistic single-flight and supersession --------------
# The current claim is the two-line ledger entry itself (line 1 the classic
# epoch record, line 2 the owner's MANDATORY pid-identity); no lock is held
# across arming or output. A live open claim defers every firing; a stuck,
# dead, identity-mismatched, identityless, or finished claim is superseded by
# taking the next generation; a superseded owner goes completely silent.

# Fabricate a v2 generation claim: <dir> <gen> <owner-pid> <outcome>
# <identity-pid>. The identity of <identity-pid> is recorded as line 2 (the
# claim's own pid for a matched claim, another pid to reproduce pid reuse).
record_autoarm_v2_claim() {
  local dir=$1 gen=$2 owner=$3 outcome=$4 identity_pid=$5 identity
  identity=$(fm_test_pid_identity "$identity_pid") || return 1
  [ -n "$identity" ] || return 1
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=1\n%s\n' \
    "$gen" "$owner" "$outcome" "$identity" > "$dir/state/.claude-autoarm-epoch"
}

# A live open generation claim needs no lock to keep the gate closed: the
# ledger alone defers a concurrent firing, however old the entry, while the
# watcher keeps beating the beacon.
test_open_generation_claim_defers_without_any_lock() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-open-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_v2_claim "$dir" 464 "$pid" arming "$pid" || fail "could not record a v2 claim"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  assert_absent "$dir/state/.claude-autoarm.lock" "this case must start with no owner lock at all"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a live open generation claim must keep the single-flight gate closed with no lock held"
  [ -z "$out" ] || fail "deferring to an open generation claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an open generation claim was superseded and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the open claim's ledger entry"
  pass "auto-arm: a live open generation claim defers concurrent firings with no lock held"
}

# The 2026-08-26 watcher flap in the generation model: a live, identity-matched
# owner whose ledger entry and watcher beacon are both older than grace is
# stuck, and the next firing supersedes it by taking the next generation.
test_stuck_generation_claim_is_superseded_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-stuck-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_v2_claim "$dir" 464 "$pid" arming "$pid" || fail "could not record a v2 claim"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a live owner stuck arming past grace with a beacon just as stale must be superseded, not deferred to forever"
  [ -e "$dir/state/arm-ran" ] || fail "a stuck generation claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the superseding generation must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "superseding claim did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  [ "$(epoch_field "$dir" owner_pid)" != "$pid" ] || fail "superseding claim left the stuck owner on the ledger"
  assert_absent "$dir/state/.claude-autoarm.lock" "the generation claim left a lock held after finishing"
  pass "auto-arm: a hung generation owner with no watcher beat is superseded so re-arming self-heals"
}

# Identity is mandatory at read time: a bare identityless one-line arming
# ledger naming an unrelated live pid is NOT an open claim - it must neither
# defer the hook nor survive as the current entry, whatever the beacon says.
test_identityless_ledger_never_defers() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-identityless-ledger")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=1\n' "$pid" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "the unrelated live pid on an identityless ledger must never be signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "an identityless arming ledger must be superseded, never deferred to"
  [ -e "$dir/state/arm-ran" ] || fail "an identityless ledger left the home unarmed"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "the identityless entry was not superseded: $(epoch_field "$dir" epoch)"
  pass "auto-arm: an identityless arming ledger never defers the gate (reused-pid loophole closed)"
}

# A superseded owner must not start or attach another watcher: when its claim
# is superseded between arm attempts, the retry boundary goes silent instead
# of invoking the arm again.
test_superseded_owner_never_reinvokes_the_arm() {
  local dir out status count
  dir=$(make_primary_dir "$TMP_ROOT/v2-superseded-arm-boundary")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" supersede-then-fail
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an owner superseded between arm attempts must exit 0 silently"
  [ -z "$out" ] || fail "a superseded owner produced output at the arm boundary: $out"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "a superseded owner re-invoked the arm, saw $count arms"
  [ "$(epoch_field "$dir" epoch)" = 999 ] || fail "a superseded owner rewrote its successor's ledger entry: $(epoch_field "$dir" epoch)"
  pass "auto-arm: a superseded owner never re-invokes the arm and leaves its successor's claim untouched"
}

# End-to-end regression for all three concurrency edge classes at once, with a
# REAL hook process hung mid-arm:
#   1. no mutex across blocking steps - while owner A is mid-arm, a concurrent
#      firing B defers promptly instead of queueing on any lock;
#   2. stuck-owner supersession - once A's claim and the beacon age past grace
#      while A is still alive arming, firing C takes the next generation and
#      translates its own close (exit 2);
#   3. no double-translation - when A's arm finally returns, A finds itself
#      superseded and goes completely silent (exit 0, no banner, no ledger
#      write), so one supersession episode produces exactly one translation.
test_superseded_owner_goes_silent_and_never_double_translates() {
  local dir a_out a_pid b_out b_status c_out c_status a_status i count session_owner
  dir=$(make_primary_dir "$TMP_ROOT/v2-superseded-silence")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" blocking-actionable
  a_out="$dir/state/a.out"
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  session_owner=$!
  printf '%s\n' "$session_owner" > "$dir/state/.lock"
  run_autoarm_from_claude_daemon_bridge "$dir" "$session_owner" > "$a_out" 2>&1 &
  a_pid=$!
  i=0
  while [ "$(epoch_outcome "$dir")" != arming ] || [ ! -e "$dir/state/arm-ran" ]; do
    [ "$i" -lt 50 ] || fail "owner A never published its arming claim"
    sleep 0.1
    i=$((i + 1))
  done
  b_out=$(run_autoarm_from_claude_daemon_bridge "$dir" "$session_owner" 2>/dev/null); b_status=$?
  expect_code 0 "$b_status" "a firing during a live open claim must defer promptly (no mutex is held across arming)"
  [ -z "$b_out" ] || fail "deferring firing produced output: $b_out"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "deferring firing must not arm, saw $count arms"
  # A is still alive mid-arm; make its claim stuck-shaped.
  kill -0 "$a_pid" 2>/dev/null || fail "owner A finished before the supersession could be exercised"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  c_out=$(run_autoarm_from_claude_daemon_bridge "$dir" "$session_owner" 2>/dev/null); c_status=$?
  expect_code 2 "$c_status" "the superseding generation must translate its own close"
  assert_contains "$c_out" "firstmate watcher wake" "the superseding generation must carry the rewake banner"
  wait "$a_pid"
  a_status=$?
  expect_code 0 "$a_status" "the superseded owner must exit 0 instead of double-translating"
  [ -z "$(sed '/^RC=0$/d' "$a_out")" ] \
    || fail "the superseded owner emitted output after losing its generation: $(cat "$a_out")"
  [ "$(epoch_field "$dir" epoch)" = 2 ] || fail "the superseded owner advanced the ledger past its successor: $(epoch_field "$dir" epoch)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the superseding generation's outcome was overwritten: $(epoch_outcome "$dir")"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "expected exactly the owner and superseder arms, saw $count"
  kill "$session_owner" 2>/dev/null || true
  wait "$session_owner" 2>/dev/null || true
  pass "auto-arm: a superseded owner goes silent - one supersession episode, one translation, no held mutex"
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

test_inert_in_child_worktree
test_inert_without_session_lock
test_reclaims_stale_session_lock_before_arming
test_inert_when_lock_held_by_other_harness
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_resolves_outermost_claude_pid_in_nested_bgspare_chain
test_claude_daemon_spawned_by_foreground_lock_owner_arms
test_generation_claim_is_bound_to_serialized_session_owner
test_claude_daemon_losing_session_owner_cannot_commit
test_claude_daemon_losing_owner_during_terminal_lock_wait_cannot_commit
test_terminal_publish_holds_session_acquisition_lease
test_claude_daemon_losing_owner_during_record_lock_wait_cannot_mutate
test_claude_daemon_losing_owner_during_reset_lock_wait_cannot_reset
test_claude_daemon_losing_session_owner_cannot_rearm
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_actionable_close_with_live_successor_rewakes_once
test_failed_close_rewakes_with_failure_banner
test_claim_path_failure_records_failed_epoch_and_marker
test_stale_recovery_loser_cannot_publish_failure_into_successor_session
test_live_claim_mutex_holder_cannot_hide_failure
test_identity_unavailable_failure_publication_does_not_self_wedge
test_stalled_transition_holder_cannot_hide_failure
test_stalled_transition_steal_holder_falls_back_to_durable_failure
test_pid_reused_transition_holder_cannot_hide_failure
test_zombie_transition_holder_cannot_hide_failure
test_fenced_arming_transition_rebases_failure
test_revoked_pid_reuse_defers_to_replacement_claim
test_fresh_prior_terminal_epoch_cannot_hide_current_failure
test_concurrent_claim_failures_publish_one_notice_atomically
test_stale_failure_publisher_cannot_emit_after_success
test_recovery_reset_cannot_be_followed_by_stalled_failure_publication
test_lockless_failure_publication_cannot_cross_recovery_reset
test_failure_allocation_cannot_adopt_later_reset_fence
test_reset_transaction_blocks_new_fence_publication
test_stale_reset_transaction_is_completed_before_publication
test_lockless_failure_notice_is_released_after_ledger_advance
test_lockless_failure_notice_is_released_when_reset_starts
test_failure_reader_rejects_record_superseded_during_selection
test_terminal_commit_failure_publishes_independent_failure
test_terminal_failure_fallback_cannot_publish_after_session_transfer
test_terminal_commit_supersession_stays_silent
test_failure_sequence_compacts_at_recovery_reset
test_failed_cycles_notify_once_and_keep_retrying
test_post_alarm_claim_failures_do_not_grow_episode_state
test_failure_notice_marker_write_refuses_delivery_and_retries
test_unverified_clean_close_exhausts_retries
test_post_alarm_actionable_close_is_suppressed
test_benign_cycle_end_with_live_watcher_is_silent
test_positive_recovery_budget_contention_preserves_episode
test_owner_mutex_contention_preserves_failure_episode_reset
test_arms_for_x_mode_poll_need_without_inflight
test_single_flight_admits_exactly_one_owner
test_abandoned_owner_claim_is_reclaimed_and_rearms
test_stale_terminal_epoch_dead_owner_does_not_prevent_next_claim
test_arming_claim_with_fresh_beacon_is_never_reclaimed
test_fresh_arming_claim_with_stale_beacon_is_never_reclaimed
test_claim_not_named_by_the_ledger_is_never_reclaimed
test_stale_unmatched_legacy_claim_reports_without_signalling
test_pid_reused_arming_claim_is_reclaimed_and_rearms
test_pid_reused_claim_with_no_ledger_is_reclaimed_and_rearms
test_identity_matched_arming_claim_is_never_reclaimed
test_terminal_check_claim_is_never_reclaimed
test_stuck_live_legacy_owner_is_retired_and_reclaimed
test_stopped_legacy_owner_is_reclaimed_with_term_pending
test_open_generation_claim_defers_without_any_lock
test_stuck_generation_claim_is_superseded_and_rearms
test_identityless_ledger_never_defers
test_superseded_owner_never_reinvokes_the_arm
test_superseded_owner_goes_silent_and_never_double_translates
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_fm_lock_status_still_works_with_shared_lib

#!/usr/bin/env bash
# tests/fm-hygiene.test.sh - workspace hygiene, doctor, repair, and lock GC.
# Repair/prune must never delete Treehouse, Hermes, or agent worktree pools.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hygiene)
HOME_DIR="$TMP_ROOT/home"
# Isolate every $HOME-relative scan (Treehouse, Hermes, Desktop projects).
export HOME="$HOME_DIR"
mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-hygiene.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-hygiene.sh must parse cleanly"
  [ -z "$out" ] || fail "bash -n bin/fm-hygiene.sh emitted unexpected output: $out"
  pass "fm-hygiene.sh: bash -n succeeds"
}

test_help_output() {
  local out rc
  out=$(bash "$ROOT/bin/fm-hygiene.sh" --help 2>&1); rc=$?
  expect_code 0 "$rc" "fm-hygiene.sh --help must succeed"
  echo "$out" | grep -q -- "--doctor" || fail "fm-hygiene.sh --help must list --doctor"
  echo "$out" | grep -q -- "--repair" || fail "fm-hygiene.sh --help must list --repair"
  echo "$out" | grep -q -- "--prune" || fail "fm-hygiene.sh --help must list --prune"
  echo "$out" | grep -q "never deletes worktrees" || fail "help must state prune never deletes worktrees"
  pass "fm-hygiene.sh: --help renders doctor, repair, and prune options"
}

test_dynamic_projects_scan() {
  local proj_dir="$HOME_DIR/projects/sample-repo"
  mkdir -p "$proj_dir"
  git -C "$proj_dir" init -q -b main
  git -C "$proj_dir" config user.email "test@example.com"
  git -C "$proj_dir" config user.name "Test User"
  echo "hello" > "$proj_dir/README.md"
  git -C "$proj_dir" add README.md
  git -C "$proj_dir" commit -q -m "Initial commit"

  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-hygiene.sh" --check 2>&1); rc=$?
  expect_code 0 "$rc" "fm-hygiene.sh --check must succeed on decoupled workspace"
  echo "$out" | grep -q "sample-repo" || fail "fm-hygiene.sh scan must find sample-repo"
  pass "fm-hygiene.sh: registered projects scan stays inside firstmate/projects"
}

test_does_not_adopt_unregistered_desktop_projects() {
  mkdir -p "$HOME_DIR/Desktop/projects/secret-zoo"
  git -C "$HOME_DIR/Desktop/projects/secret-zoo" init -q -b main
  git -C "$HOME_DIR/Desktop/projects/secret-zoo" config user.email "test@example.com"
  git -C "$HOME_DIR/Desktop/projects/secret-zoo" config user.name "Test User"
  echo "x" > "$HOME_DIR/Desktop/projects/secret-zoo/README.md"
  git -C "$HOME_DIR/Desktop/projects/secret-zoo" add README.md
  git -C "$HOME_DIR/Desktop/projects/secret-zoo" commit -q -m "init"

  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-hygiene.sh" --check 2>&1); rc=$?
  expect_code 0 "$rc" "check must succeed when an unregistered Desktop project exists"
  echo "$out" | grep -q "secret-zoo" && fail "hygiene must not adopt unregistered Desktop/projects repos"
  pass "fm-hygiene.sh: does not scan the Desktop/projects zoo by default"
}

test_dead_pid_lock_gc_and_repair() {
  local dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done

  echo "$dead_pid" > "$HOME_DIR/state/.lock"
  echo "lease_holder" > "$HOME_DIR/state/.lease-task-old-99"
  touch "$HOME_DIR/state/.watch-arm-output.12345"
  mkdir -p "$HOME_DIR/state/task-old-99.inbox"
  echo "keep-me" > "$HOME_DIR/state/task-old-99.inbox/note"
  echo "busy" > "$HOME_DIR/state/task-old-99.busy-now"

  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-hygiene.sh" --repair 2>&1); rc=$?
  expect_code 0 "$rc" "fm-hygiene.sh --repair must succeed"

  if [ -f "$HOME_DIR/state/.lock" ]; then
    fail "fm-hygiene.sh --repair must remove dead-PID session lock"
  fi
  if [ -f "$HOME_DIR/state/.lease-task-old-99" ]; then
    fail "fm-hygiene.sh --repair must remove stale lease for inactive task"
  fi
  if [ -f "$HOME_DIR/state/.watch-arm-output.12345" ]; then
    fail "fm-hygiene.sh --repair must remove stale watcher output"
  fi
  if [ ! -d "$HOME_DIR/state/task-old-99.inbox" ]; then
    fail "fm-hygiene.sh --repair must preserve task inboxes"
  fi
  if [ ! -f "$HOME_DIR/state/task-old-99.busy-now" ]; then
    fail "fm-hygiene.sh --repair must preserve busy markers"
  fi
  echo "$out" | grep -q "Stale task inbox (preserved)" || fail "repair must report preserved inbox"
  pass "fm-hygiene.sh: --repair cleans dead locks and temp files, preserves inboxes"
}

test_repair_keeps_live_task_lease() {
  echo "holder" > "$HOME_DIR/state/.lease-live-task"
  printf 'id=live-task\n' > "$HOME_DIR/state/live-task.meta"
  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-hygiene.sh" --repair 2>&1); rc=$?
  expect_code 0 "$rc" "repair must succeed with a live-task lease"
  [ -f "$HOME_DIR/state/.lease-live-task" ] || fail "repair must keep lease when meta exists"
  rm -f "$HOME_DIR/state/.lease-live-task" "$HOME_DIR/state/live-task.meta"
  pass "fm-hygiene.sh: --repair keeps leases for tasks with meta"
}

test_never_deletes_treehouse_or_hermes() {
  mkdir -p "$HOME_DIR/.treehouse/firstmate-deadbeef/1/firstmate"
  echo "unlanded" > "$HOME_DIR/.treehouse/firstmate-deadbeef/1/firstmate/WIP.md"
  mkdir -p "$HOME_DIR/.hermes/company-os-manager/worktrees/slot-a"
  echo "keep" > "$HOME_DIR/.hermes/company-os-manager/worktrees/slot-a/file"
  mkdir -p "$HOME_DIR/Desktop/projects/.agent-worktrees/company-os/wt-1"
  echo "keep" > "$HOME_DIR/Desktop/projects/.agent-worktrees/company-os/wt-1/file"

  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-hygiene.sh" --prune 2>&1); rc=$?
  expect_code 0 "$rc" "prune must succeed"
  echo "$out" | grep -q "Treehouse slot (preserved)" || fail "prune must report Treehouse as preserved"
  echo "$out" | grep -q "never deleted" || fail "summary must say external pools are never deleted"
  [ -f "$HOME_DIR/.treehouse/firstmate-deadbeef/1/firstmate/WIP.md" ] || fail "prune must not delete Treehouse slots"
  [ -f "$HOME_DIR/.hermes/company-os-manager/worktrees/slot-a/file" ] || fail "prune must not delete Hermes worktrees"
  [ -f "$HOME_DIR/Desktop/projects/.agent-worktrees/company-os/wt-1/file" ] || fail "prune must not delete agent worktrees"
  pass "fm-hygiene.sh: prune/repair never delete Treehouse, Hermes, or agent pools"
}

test_doctor_diagnostics() {
  local out rc
  out=$(FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-hygiene.sh" --doctor 2>&1); rc=$?
  expect_code 0 "$rc" "fm-hygiene.sh --doctor must run diagnostics without crashing"
  echo "$out" | grep -q "System & subsystem doctor" || fail "doctor output missing header"
  echo "$out" | grep -q "Watcher" || fail "doctor must inspect watcher liveness"
  echo "$out" | grep -q "Wake drain" || fail "doctor must inspect wake-drain processes"
  pass "fm-hygiene.sh: --doctor runs diagnostics including watcher and drain"
}

test_session_lock_gc_lib() {
  local dead_pid=999998
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done

  echo "$dead_pid" > "$HOME_DIR/state/.lock"

  bash -c '
    . "'"$ROOT"'/bin/fm-session-lock-lib.sh"
    fm_session_lock_gc "'"$HOME_DIR"'/state"
  '
  local rc=$?
  expect_code 0 "$rc" "fm_session_lock_gc must succeed"
  if [ -f "$HOME_DIR/state/.lock" ]; then
    fail "fm_session_lock_gc must have removed dead-PID lock"
  fi

  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-harness-bin")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  700:comm=) printf '%s\n' opencode ;;
  700:args=) printf '%s\n' opencode ;;
  700:ppid=) printf '%s\n' 1 ;;
  *:comm=*) printf '%s\n' bash ;;
  *:args=*) printf '%s\n' bash ;;
  *:ppid=*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  echo "700" > "$HOME_DIR/state/.lock"

  PATH="$fakebin:$PATH" bash -c '
    . "'"$ROOT"'/bin/fm-session-lock-lib.sh"
    kill() { return 0; }
    fm_session_lock_gc "'"$HOME_DIR"'/state"
  '
  if [ ! -f "$HOME_DIR/state/.lock" ]; then
    fail "fm_session_lock_gc must NOT remove active harness lock (PID 700)"
  fi
  rm -f "$HOME_DIR/state/.lock"

  pass "fm-session-lock-lib.sh: fm_session_lock_gc cleans only dead/unrecognized locks"
}

test_script_parses
test_help_output
test_dynamic_projects_scan
test_does_not_adopt_unregistered_desktop_projects
test_dead_pid_lock_gc_and_repair
test_repair_keeps_live_task_lease
test_never_deletes_treehouse_or_hermes
test_doctor_diagnostics
test_session_lock_gc_lib

#!/usr/bin/env bash
# tests/fm-lock.test.sh - fm-lock.sh harness-process detection. The session lock
# walks a task shell's process ancestry (harness_pid) and re-reads a recorded
# holder (holder_alive), matching each process against HARNESS_RE by command
# basename OR argument vector. The regressions here pin the Claude 2.1.x process
# shape seen on WSL, where comm is a bare version number ("2.1.206") rather than
# "claude": without args-based matching such a session falsely fails safe to
# read-only. A genuinely-unrelated tree must still NOT be detected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

# make_fake_ps <fakebin> <tree-file>: a `ps` shim that answers -o comm=/args=/ppid=
# from a "pid|comm|args|ppid" fixture. Any pid not listed (the real starting $$
# of harness_pid) resolves to the FIRST row, so that row is the ancestry entry
# and its ppid points at the next fixture row - letting a test model a multi-level
# process tree the walk climbs.
make_fake_ps() {
  local fakebin=$1 tree=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
tree="$tree"
field=comm
case "\$*" in
  *args=*) field=args ;;
  *ppid=*) field=ppid ;;
esac
pid=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$a"
  prev="\$a"
done
line=\$(awk -F'|' -v p="\$pid" '\$1==p{print;found=1;exit} END{}' "\$tree")
[ -n "\$line" ] || line=\$(head -1 "\$tree")
IFS='|' read -r f_pid f_comm f_args f_ppid <<<"\$line"
case "\$field" in
  comm) printf '%s\n' "\$f_comm" ;;
  args) printf '%s\n' "\$f_args" ;;
  ppid) printf '%s\n' "\$f_ppid" ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
}

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  printf '%s\n' "$dir"
}

# The WSL Claude 2.1.x session process: comm is the version number, args are the
# versioned executable path carrying the "claude" token, with a "claude
# bg-pty-host" parent. Detected as a harness -> lock acquired.
test_wsl_session_shape_detected() {
  local dir fakebin out status
  dir=$(make_case wsl-session)
  fakebin=$(fm_fakebin "$dir")
  cat > "$dir/tree" <<'TREE'
7001|2.1.206|/home/mikeadam/.local/share/claude/versions/2.1.206 --session-id 0d1e2f --bg-pty-host|7000
7000|2.1.206|claude bg-pty-host --bg-pty-host /tmp/cc-daemon-xyz/pty/0d1e2f.sock|1
TREE
  make_fake_ps "$fakebin" "$dir/tree"
  out=$(FM_HOME="$dir" PATH="$fakebin:$PATH" "$LOCK" 2>&1)
  status=$?
  expect_code 0 "$status" "WSL session shape should acquire the lock, not fail read-only"
  assert_contains "$out" "lock acquired: harness pid" "WSL Claude 2.1.x session process was not recognized as a harness"
  pass "harness_pid detects the WSL Claude 2.1.x session-process shape"
}

# Isolate the parent branch that the old node/python-only args gate skipped: a
# session process whose own args carry no harness token, whose comm is a version
# number, and whose parent is "claude bg-pty-host" (comm also a version number).
# The walk must climb and match the parent's args.
test_wsl_parent_bg_pty_host_shape_detected() {
  local dir fakebin out status
  dir=$(make_case wsl-parent)
  fakebin=$(fm_fakebin "$dir")
  cat > "$dir/tree" <<'TREE'
8001|2.1.206|/opt/local/versions/2.1.206 --session-id aa11bb --bg-pty-host|8000
8000|2.1.206|claude bg-pty-host --bg-pty-host /tmp/cc-daemon-abc/pty/aa11bb.sock|1
TREE
  make_fake_ps "$fakebin" "$dir/tree"
  out=$(FM_HOME="$dir" PATH="$fakebin:$PATH" "$LOCK" 2>&1)
  status=$?
  expect_code 0 "$status" "parent 'claude bg-pty-host' shape should acquire the lock"
  assert_contains "$out" "lock acquired: harness pid 8000" "walk did not climb to the 'claude bg-pty-host' parent"
  pass "harness_pid climbs to and matches the 'claude bg-pty-host' parent despite a version-number comm"
}

# A genuinely-unrelated ancestry (no harness token in any comm or args) must NOT
# be detected: the session must fail closed rather than grab the lock.
test_unrelated_tree_not_detected() {
  local dir fakebin out status
  dir=$(make_case unrelated)
  fakebin=$(fm_fakebin "$dir")
  cat > "$dir/tree" <<'TREE'
9002|bash|/bin/bash|9001
9001|sshd|/usr/sbin/sshd -D|9000
9000|systemd|/lib/systemd/systemd --user|1
TREE
  make_fake_ps "$fakebin" "$dir/tree"
  out=$(FM_HOME="$dir" PATH="$fakebin:$PATH" "$LOCK" 2>&1)
  status=$?
  expect_code 1 "$status" "unrelated ancestry must not acquire the lock"
  assert_contains "$out" "cannot locate harness process in ancestry" "unrelated tree was wrongly accepted as a harness"
  assert_absent "$dir/state/.lock" "no lock file should be written for an unrelated ancestry"
  pass "harness_pid rejects a genuinely-unrelated process tree"
}

# holder_alive re-reads a recorded holder pid. A lock written by a WSL session
# (version-number comm, claude-path args) must be seen as a live harness in
# status. Uses the test's own live pid ($$) so kill -0 succeeds.
test_status_recognizes_wsl_holder() {
  local dir fakebin out
  dir=$(make_case wsl-holder)
  fakebin=$(fm_fakebin "$dir")
  printf '%s\n' "$$" > "$dir/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *comm=*) printf '%s\n' '2.1.206' ;;
  *args=*) printf '%s\n' '/home/mikeadam/.local/share/claude/versions/2.1.206 --session-id 0d1e2f' ;;
  *ppid=*) printf '%s\n' '1' ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$dir" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" "holder_alive did not recognize the WSL Claude 2.1.x holder as live"
  pass "holder_alive recognizes a WSL Claude 2.1.x lock holder"
}

# Regression guard for the pre-existing native comm=claude shape: a shell entry
# whose parent is a "claude" command must still be detected by comm basename.
test_native_comm_shape_still_detected() {
  local dir fakebin out status
  dir=$(make_case native-comm)
  fakebin=$(fm_fakebin "$dir")
  cat > "$dir/tree" <<'TREE'
6002|bash|-bash|6001
6001|claude|/usr/local/bin/claude --session-id ff00|1
TREE
  make_fake_ps "$fakebin" "$dir/tree"
  out=$(FM_HOME="$dir" PATH="$fakebin:$PATH" "$LOCK" 2>&1)
  status=$?
  expect_code 0 "$status" "native comm=claude shape should still acquire the lock"
  assert_contains "$out" "lock acquired: harness pid 6001" "native comm=claude shape regressed"
  pass "harness_pid still detects the native comm=claude shape"
}

# Regression guard for the interpreter-hosted shape: comm=node with a claude
# script path in its args must still be detected via args matching.
test_native_interpreter_shape_still_detected() {
  local dir fakebin out status
  dir=$(make_case native-node)
  fakebin=$(fm_fakebin "$dir")
  cat > "$dir/tree" <<'TREE'
5002|bash|-bash|5001
5001|node|node /usr/local/lib/claude/cli.js --session-id ff00|1
TREE
  make_fake_ps "$fakebin" "$dir/tree"
  out=$(FM_HOME="$dir" PATH="$fakebin:$PATH" "$LOCK" 2>&1)
  status=$?
  expect_code 0 "$status" "interpreter-hosted claude shape should still acquire the lock"
  assert_contains "$out" "lock acquired: harness pid 5001" "interpreter-hosted (node) claude shape regressed"
  pass "harness_pid still detects the interpreter-hosted (node) claude shape"
}

test_wsl_session_shape_detected
test_wsl_parent_bg_pty_host_shape_detected
test_unrelated_tree_not_detected
test_status_recognizes_wsl_holder
test_native_comm_shape_still_detected
test_native_interpreter_shape_still_detected

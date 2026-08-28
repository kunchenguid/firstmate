#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$LIB"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
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
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
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
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
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
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
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
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

test_harness_detection_preserves_kimi_and_cursor_identity() {
  local dir fakebin proc_root cursor_bin shape got
  dir="$TMP_ROOT/harness-detection"
  fakebin=$(fm_fakebin "$dir")
  proc_root="$dir/proc"
  cursor_bin="$dir/Cursor Agent/cursor-agent/versions/2026.08.11/cursor-agent"
  mkdir -p "$proc_root/850" "$(dirname -- "$cursor_bin")"
  ln -s /bin/bash "$cursor_bin"
  printf '%s\0--resume\0' "$cursor_bin" > "$proc_root/850/cmdline"
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
case "$pid:$field:${FM_TEST_HARNESS_SHAPE:-kimi}" in
  850:comm=:kimi) printf '%s\n' kimi ;;
  850:args=:kimi) printf '%s\n' kimi ;;
  850:comm=:kimi-exe) printf '%s\n' 'C:\Tools\kimi.exe' ;;
  850:args=:kimi-exe) printf '%s\n' 'C:\Tools\kimi.exe' ;;
  850:comm=:kimi-helper) printf '%s\n' kimi-helper ;;
  850:args=:kimi-helper) printf '%s\n' kimi-helper ;;
  850:comm=:codex-path) printf '%s\n' runner ;;
  850:args=:codex-path) printf '%s\n' "$FM_TEST_CODEX_RUNNER" ;;
  850:comm=:cursor) printf '%s\n' MainThread ;;
  850:args=:cursor) printf '%s\n' "$FM_TEST_CURSOR_BIN --resume" ;;
  850:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' bash ;;
  *:ppid=:*) printf '%s\n' 850 ;;
esac
SH
  chmod +x "$fakebin/ps"

  mkdir -p "$dir/codex"
  : > "$dir/codex/runner"
  for shape in kimi kimi-exe kimi-helper codex-path cursor; do
    case "$shape" in
      codex-path) printf '%s\0' "$dir/codex/runner" > "$proc_root/850/cmdline" ;;
      cursor) printf '%s\0--resume\0' "$cursor_bin" > "$proc_root/850/cmdline" ;;
      *) rm -f "$proc_root/850/cmdline" ;;
    esac
    got=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u PI_CODING_AGENT -u GROK_AGENT \
      PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$proc_root" \
      FM_TEST_HARNESS_SHAPE="$shape" FM_TEST_CURSOR_BIN="$cursor_bin" \
      FM_TEST_CODEX_RUNNER="$dir/codex/runner" \
      "$ROOT/bin/fm-harness.sh")
    case "$shape:$got" in
      kimi:kimi|kimi-exe:kimi|kimi-helper:unknown|codex-path:unknown|cursor:cursor) ;;
      *) fail "$shape ancestry classified as '$got'" ;;
    esac
  done
  pass "harness detection: prior name evidence survives shared structured process rows"
}

test_real_windows_process_helper_contract() {
  local winpid row pid ppid comm argv0 args
  case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
      pass "session-lock: real Windows process helper skipped on a non-Windows host"
      return
      ;;
  esac
  command -v powershell.exe >/dev/null 2>&1 \
    || fail "native Windows process helper requires powershell.exe"
  winpid=$(fm_windows_current_pid) \
    || fail "native Windows pid could not be resolved"
  row=$(fm_windows_process_rows "$winpid" 1) \
    || fail "real native Windows process helper failed"
  [ "$(printf '%s\n' "$row" | wc -l | tr -d ' ')" = 1 ] \
    || fail "real native Windows process helper ignored its one-row limit"
  printf '%s\n' "$row" | awk -F '\t' 'NF == 5 { valid = 1 } END { exit valid ? 0 : 1 }' \
    || fail "real native Windows process helper did not emit five fields"
  IFS=$'\t' read -r pid ppid comm argv0 args <<EOF
$row
EOF
  [ "$pid" = "$winpid" ] || fail "real native Windows helper returned pid '$pid', expected '$winpid'"
  case "$ppid" in ''|*[!0-9]*) fail "real native Windows helper returned invalid parent pid '$ppid'" ;; esac
  [ -n "$comm" ] && [ -n "$argv0" ] && [ -n "$args" ] \
    || fail "real native Windows helper returned an empty process identity field"
  pass "session-lock: real Windows process helper emits its ancestry-row contract"
}

test_native_windows_process_table_identifies_codex() {
  local dir fakebin got
  dir="$TMP_ROOT/native-windows"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -l)
    printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
    printf '%s\n' '      100       1     100        410  ?        197609 00:00:00 /usr/bin/bash'
    ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != ancestry ]; do shift; done
[ "${1:-}" = ancestry ] || exit 1
case "${2:-}" in
  410)
    printf '410\t510\tC:\\Program Files\\Git\\bin\\bash.exe\tC:\\Program Files\\Git\\bin\\bash.exe\tbash bin/fm-codex-hook.sh sessionstart\n'
    if [ "${FM_TEST_BRIDGE_LOST:-}" != 1 ]; then
      printf '510\t610\tC:\\Windows\\System32\\cmd.exe\tC:\\Windows\\System32\\cmd.exe\tcmd.exe /C bin\\fm-codex-hook.cmd sessionstart\n'
      printf '610\t710\tC:\\Users\\u\\AppData\\Roaming\\npm\\codex.exe\tC:\\Users\\u\\AppData\\Roaming\\npm\\codex.exe\tcodex.exe\n'
    fi
    ;;
  610)
    printf '610\t710\tC:\\Users\\u\\AppData\\Roaming\\npm\\codex.exe\tC:\\Users\\u\\AppData\\Roaming\\npm\\codex.exe\tcodex.exe\n'
    ;;
  620)
    printf '620\t710\tC:\\tmp\\codex\\runner.exe\tC:\\tmp\\codex\\runner.exe\tC:\\tmp\\codex\\runner.exe\n'
    ;;
  999)
    printf '999\t710\tC:\\Windows\\System32\\notepad.exe\tC:\\Windows\\System32\\notepad.exe\tnotepad.exe\n'
    ;;
esac
SH
  chmod +x "$fakebin/ps" "$fakebin/powershell.exe"

  got=$(PATH="$fakebin:$PATH" bash -c '
    uname() { printf "%s\n" MINGW64_NT; }
    . "$0"
    fm_harness_ancestry_pid
  ' "$LIB") || fail "native Windows Codex was not found through the Windows process table"
  [ "$got" = 610 ] || fail "native Windows ancestry resolved '$got', expected Codex pid 610"

  got=$(PATH="$fakebin:$PATH" FM_SESSION_HARNESS_PID=610 bash -c '
    uname() { printf "%s\n" MINGW64_NT; }
    . "$0"
    fm_process_ancestry_rows() { return 1; }
    fm_harness_ancestry_pid
  ' "$LIB") || fail "captured native Windows Codex identity was not reusable after the parent chain disappeared"
  [ "$got" = 610 ] || fail "captured native Windows ancestry resolved '$got', expected Codex pid 610"

  got=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_TEST_BRIDGE_LOST=1 FM_SESSION_HARNESS_PID=610 \
    "$ROOT/bin/fm-harness.sh") \
    || fail "captured native Windows Codex identity was not detected after bridge loss"
  [ "$got" = codex ] \
    || fail "captured native Windows Codex identity resolved '$got', expected codex"

  got=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" \
    FM_TEST_BRIDGE_LOST=1 FM_SESSION_HARNESS_PID=620 \
    "$ROOT/bin/fm-harness.sh")
  [ "$got" = unknown ] \
    || fail "captured path-only Codex evidence resolved '$got', expected unknown"

  printf '610\n' > "$dir/state/.lock"
  PATH="$fakebin:$PATH" bash -c '
    uname() { printf "%s\n" MINGW64_NT; }
    . "$0"
    fm_harness_pid_alive 610 && fm_session_lock_owned_by_self "$1"
  ' "$LIB" "$dir/state" || fail "native Windows Codex did not retain its live owned lock"
  if PATH="$fakebin:$PATH" bash -c '
    uname() { printf "%s\n" MINGW64_NT; }
    . "$0"
    fm_harness_pid_alive 999
  ' "$LIB"; then
    fail "an ordinary native Windows process was accepted as a live harness"
  fi
  pass "session-lock: captured native Windows Codex identity survives bridge loss"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

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
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_harness_detection_preserves_kimi_and_cursor_identity
test_real_windows_process_helper_contract
test_native_windows_process_table_identifies_codex
if ps -o comm= -p "$$" >/dev/null 2>&1; then
  test_e2e_version_named_session_claims_the_home
  test_e2e_daemon_parented_session_claims_the_home
  test_e2e_daemon_parented_version_named_session_keeps_its_lock
else
  pass "session-lock e2e: procps-only executable-alias fixtures skipped on native Windows"
fi

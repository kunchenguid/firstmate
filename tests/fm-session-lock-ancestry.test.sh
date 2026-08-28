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
# liveness questions are decided by the process table alone. The fixtures below
# model the `ps -o comm=/args=/ppid=` world, so the unix inspection path is
# pinned explicitly - otherwise a Windows (MSYS) test host would select the
# native-tree path and never touch the faked ps at all.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  FM_LOCK_PLATFORM=unix PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

# Run one library expression on the Windows inspection path. The native data
# seams are shadowed from fixtures (as lib_eval shadows kill): this shell's MSYS
# pid, the MSYS logical process table, the Win32_Process ancestry walk, the
# `ps -W` native table, and the /proc winpid fallback. WIN_MSYSSELF, WIN_MSYSPS,
# WIN_CHAIN, WIN_PSW, and WIN_SELF are read from the environment.
win_eval() {  # <expression>
  local expr=$1
  FM_LOCK_PLATFORM=windows bash -c "
    . \"\$0\"
    _fm_win_self_msyspid() { printf '%s\n' \"\$WIN_MSYSSELF\"; }
    _fm_win_ps() { cat \"\$WIN_MSYSPS\"; }
    _fm_win_walk_rows() { [ \"\$1\" = \"\${WIN_EXPECT_START:-100}\" ] && cat \"\$WIN_CHAIN\"; }
    _fm_win_ps_w() { cat \"\$WIN_PSW\"; }
    _fm_win_self_winpid() { printf '%s\n' \"\$WIN_SELF\"; }
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

# --- unit layer: the Windows native-tree inspection path ---------------------

# Build the Windows fixtures for one scenario under <dir> and export the seams
# win_eval reads. The chain is the real Git Bash shape: two bash.exe hops - whose
# command lines mention ~/.claude, which must NOT be read as a harness - below the
# claude.exe session, then cmd.exe and the terminal. Paths carry literal
# backslashes, so every field is passed as a %s argument rather than baked into
# the printf format.
win_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  {
    printf '%s\t%s\t%s\n' 100 bash.exe '"C:\Program Files\Git\bin\..\usr\bin\bash.exe" -c "source /c/Users/u/.claude/shell-snapshots/snap.sh && eval cmd"'
    printf '%s\t%s\t%s\n' 101 bash.exe '"C:\Program Files\Git\bin\bash.exe" -c "source /c/Users/u/.claude/shell-snapshots/snap.sh"'
    printf '%s\t%s\t%s\n' 200 claude.exe claude
    printf '%s\t%s\t%s\n' 300 cmd.exe 'C:\WINDOWS\system32\cmd.exe'
    printf '%s\t%s\t%s\n' 400 wezterm-gui.exe '"C:\Program Files\WezTerm\wezterm-gui.exe" start'
  } > "$dir/chain"
  # ps -W table. STIME is two tokens ("Jul 30") on the claude row to prove the
  # COMMAND parser anchors on the drive-letter path, not a fixed column offset;
  # System has a bare COMMAND (no path) and must never resolve as a harness.
  {
    printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
    printf '%s\n' '  4217716       0       0        200   ?              0 Jul 30 C:\Users\u\AppData\Local\claude.exe'
    printf '%s\n' '  4194308       0       0          4   ?              0 Jul 30 System'
    printf '%s\n' '  4207384       0       0        101   ?              0 10:02:04 C:\Program Files\Git\usr\bin\bash.exe'
  } > "$dir/psw"
  # MSYS logical process table: this subprocess (msys 50, winpid 3856 - orphaned,
  # never a valid Win32 walk start) under the topmost MSYS shell (msys 51, winpid
  # 100), which was spawned directly by the harness and whose winpid IS the valid
  # Win32 walk entry point. The chain above is keyed to start at winpid 100.
  {
    printf '%s\n' '      PID    PPID    PGID     WINPID   TTY   UID STIME COMMAND'
    printf '%s\n' '   50 51 50 3856 ? 197609 17:31 /usr/bin/bash'
    printf '%s\n' '   51 1 51 100 ? 197609 17:31 /usr/bin/bash'
  } > "$dir/msysps"
  export WIN_MSYSSELF=50 WIN_MSYSPS="$dir/msysps" WIN_CHAIN="$dir/chain" WIN_PSW="$dir/psw" WIN_SELF=999
}

test_windows_harness_is_found_beyond_the_bash_hops() {
  local dir got
  dir="$TMP_ROOT/win-found"
  win_fixture "$dir"
  # This is the whole bug: the MSYS ps saw only the bash hops and reported no
  # harness, so every session refused the lock. The native-tree walk climbs past
  # the two bash.exe hops - whose ~/.claude command lines are not harness
  # evidence - to the claude.exe session.
  got=$(win_eval 'fm_harness_ancestry_pid') \
    || fail "windows: the claude.exe session was not found in the native ancestry at all"
  [ "$got" = 200 ] || fail "windows: ancestry resolved '$got', expected the claude.exe pid 200"
  printf '200\n' > "$dir/state/.lock"
  win_eval "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "windows: the session holding the lock did not recognize itself as the owner"
  pass "session-lock: on Windows the claude.exe session is found above the Git Bash hops"
}

test_windows_liveness_reads_the_native_process_table() {
  local dir
  dir="$TMP_ROOT/win-live"
  win_fixture "$dir"
  win_eval 'fm_harness_pid_alive 200' \
    || fail "windows: a live claude.exe was not recognized as a harness (COMMAND parse under a two-token STIME)"
  if win_eval 'fm_harness_pid_alive 101'; then
    fail "windows: a live bash.exe passed the harness-liveness predicate"
  fi
  if win_eval 'fm_harness_pid_alive 4'; then
    fail "windows: a bare-name native process (System) was treated as a harness"
  fi
  if win_eval 'fm_harness_pid_alive 999999'; then
    fail "windows: a pid absent from the native-process table was reported alive"
  fi
  pass "session-lock: on Windows liveness and identity come from the native-process table"
}

test_windows_lock_above_the_harness_is_not_owned() {
  local dir
  dir="$TMP_ROOT/win-gap"
  win_fixture "$dir"
  # cmd.exe (300) sits above the contiguous harness run; a lock naming it is not
  # this session's, exactly as on Unix ownership stops at the first non-harness.
  printf '300\n' > "$dir/state/.lock"
  if win_eval "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "windows: a lock held by a process above the harness was claimed as this session's own"
  fi
  pass "session-lock: on Windows ownership stops at the first non-harness above the session"
}

test_windows_ancestry_start_bridges_msys_to_windows() {
  local dir got
  dir="$TMP_ROOT/win-bridge"
  win_fixture "$dir"
  # A Git Bash subprocess is fork-orphaned: its own winpid (WIN_SELF=999) has no
  # valid Win32 parent. The start pid must instead be the topmost MSYS shell's
  # winpid (100), resolved by climbing the MSYS logical table.
  got=$(win_eval '_fm_win_ancestry_start_winpid') \
    || fail "windows: could not resolve an ancestry start winpid"
  [ "$got" = 100 ] \
    || fail "windows: start winpid resolved '$got', expected the top MSYS shell's winpid 100 (not the orphaned self)"
  pass "session-lock: on Windows the ancestry start bridges the MSYS chain to the top shell's winpid"
}

test_windows_ancestry_start_falls_back_when_msys_table_lacks_self() {
  local dir got
  dir="$TMP_ROOT/win-fallback"
  win_fixture "$dir"
  # If the MSYS table cannot place this shell, fall back to its own winpid.
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY   UID STIME COMMAND' > "$dir/msysps"
  got=$(WIN_SELF=4242 win_eval '_fm_win_ancestry_start_winpid') \
    || fail "windows: fallback did not produce a start winpid"
  [ "$got" = 4242 ] \
    || fail "windows: fallback resolved '$got', expected this shell's own winpid 4242"
  pass "session-lock: on Windows the ancestry start falls back to the own winpid when the MSYS table lacks self"
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
test_windows_harness_is_found_beyond_the_bash_hops
test_windows_liveness_reads_the_native_process_table
test_windows_lock_above_the_harness_is_not_owned
test_windows_ancestry_start_bridges_msys_to_windows
test_windows_ancestry_start_falls_back_when_msys_table_lacks_self
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock

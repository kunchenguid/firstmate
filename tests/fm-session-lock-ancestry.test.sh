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

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
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
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
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

# --- Cygwin / Git-for-Windows layer ------------------------------------------
#
# Both of this platform's departures are reproduced here rather than assumed, so
# these run identically on Linux and macOS CI: its ps rejects -o outright, and
# every shell it reports has its parent link severed at 1 because the real parent
# is a Windows process Cygwin cannot see. The fakebin itself is shared as
# fm_cygwin_fakebin (tests/lib.sh) with tests/fm-claude-stop-autoarm.test.sh,
# which drives the same Windows bridge end to end through the real Stop hook.

# WINPID 7204 is the session harness. 4321 is an ordinary desktop process, and
# 5150 is the path-shaped lookalike that must never read as a harness.
WIN_TABLE='  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe
  4198625       0       0       4321  ?              0 22:24:48 C:\Windows\explorer.exe
  4199454       0       0       5150  ?              0 22:24:48 C:\tools\claude-notes\helper.exe'

# The same table with a process started more than 24 hours ago, where the real
# ps prints STIME as a two-field date ("Sep  6") instead of one clock field.
WIN_TABLE_DATE_STIME='  4201508       0       0       7204  ?              0 Sep  6 C:\Users\u\.local\bin\claude.exe
  4198625       0       0       4321  ?              0 Sep  6 C:\Windows\explorer.exe'

test_windows_session_is_identified_from_its_published_pid() {
  local dir fakebin got
  dir="$TMP_ROOT/win-published"
  fakebin=$(fm_cygwin_fakebin "$dir")
  mkdir -p "$dir/state"
  printf 'win:7204\n' > "$dir/state/.lock"

  got=$(FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the session was not identified at all on a severed Cygwin parent link"
  [ "$got" = 'win:7204' ] || fail "expected the tagged Windows session pid win:7204, got '$got'"
  FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_pid_alive win:7204' \
    || fail "a live Windows-side session was classified as a dead lock owner"
  FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID=7204 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock did not recognize itself as the owner"
  pass "session-lock: a Windows session is identified from its published pid across the severed parent link"
}

test_windows_published_pid_is_confirmed_before_it_is_trusted() {
  local dir fakebin
  dir="$TMP_ROOT/win-unconfirmed"
  fakebin=$(fm_cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # A published pid is a claim. Each of these shapes must be discarded rather
  # than bound: a process that is gone, one that is not a harness at all, and a
  # path that merely contains the harness name inside a longer component.
  for claimed in 9999 4321 5150; do
    if FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID="$claimed" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "published pid $claimed was bound as this session's harness without confirmation"
    fi
    if FM_TEST_WIN_TABLE="$WIN_TABLE" lib_eval "$fakebin" "fm_harness_pid_alive win:$claimed"; then
      fail "published pid $claimed passed the harness-liveness predicate"
    fi
  done
  pass "session-lock: a published Windows pid is confirmed against the process table before it is trusted"
}

test_windows_pid_is_never_resolved_as_a_cygwin_pid() {
  local dir fakebin
  dir="$TMP_ROOT/win-namespace"
  fakebin=$(fm_cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # 700 is a harness in the CYGWIN table and absent from the Windows one. The
  # two namespaces overlap numerically, so resolving a tagged pid through the
  # local table would bind a home to whatever unrelated process holds that
  # number - which is exactly what the tag exists to prevent.
  FM_TEST_WIN_TABLE="$WIN_TABLE" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
    || fail "fixture is vacuous: pid 700 must be a live harness in the Cygwin table"
  if FM_TEST_WIN_TABLE="$WIN_TABLE" lib_eval "$fakebin" 'fm_harness_pid_alive win:700'; then
    fail "a tagged Windows pid was resolved against the Cygwin process table"
  fi
  pass "session-lock: a tagged Windows pid is never resolved against the Cygwin process table"
}

test_a_published_identity_is_accepted_by_the_gates_that_read_the_lock() {
  local dir fakebin identity
  dir="$TMP_ROOT/win-identity-gates"
  fakebin=$(fm_cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # The identity a session writes into the lock is read back by gates spread
  # across several scripts - startup-completion recording and its clear/compact
  # validation, the deferred network sweeps, and the Stop auto-arm. Each one
  # asks only "is this value a usable identity", and each answered that with its
  # own numeric test, so introducing a second identity shape made every one of
  # them silently read a valid holder as malformed. The visible cost was a
  # completion record that was never written, which reads as "startup never
  # finished" and repeats the whole sequence on every clear or compact. One
  # predicate owns the question so a third shape can never split them again.
  identity=$(FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "fixture is vacuous: no identity was published to gate on"
  lib_eval "$fakebin" "fm_session_pid_valid '$identity'" \
    || fail "the identity '$identity' this session publishes is rejected by the gates that read it back"

  # A local pid stays equally valid: the Windows shape is additional, not a
  # replacement, and the same predicate serves both platforms.
  lib_eval "$fakebin" 'fm_session_pid_valid 700' \
    || fail "an ordinary local pid was rejected as an invalid lock identity"

  # Still fail closed on the shapes a torn or hand-edited lock produces, and on
  # a bare tag carrying no pid at all.
  for bad in '' 'win:' 'win:abc' 'abc' '70 0' '-1' 'win:12abc' 'win:1234x' 'win:12 3'; do
    if lib_eval "$fakebin" "fm_session_pid_valid '$bad'"; then
      fail "the malformed lock value '$bad' was accepted as a usable identity"
    fi
  done
  pass "session-lock: a published identity is accepted by every gate that reads the lock"
}

test_cygwin_ps_without_o_still_resolves_a_local_harness() {
  local dir fakebin got
  dir="$TMP_ROOT/cygwin-local"
  fakebin=$(fm_cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # An MSYS-native harness lives in the same process table as this shell, so it
  # must resolve through the ordinary walk and stay an untagged pid. This is
  # what proves the walk survives a ps with no -o option at all.
  got=$(FM_TEST_CYG_PPID=700 FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID=7204 \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a harness in the local process table was not resolved when ps rejected -o"
  [ "$got" = 700 ] || fail "expected the untagged local harness pid 700, got '$got'"
  pass "session-lock: a harness in the local process table resolves untagged when ps has no -o option"
}

test_cygwin_date_form_stime_does_not_truncate_the_command() {
  local dir fakebin got
  dir="$TMP_ROOT/cygwin-long-running"
  fakebin=$(fm_cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # A process started more than 24 hours ago gets a two-field date STIME, which
  # moves COMMAND one whitespace field to the right in every Cygwin row. The
  # command must still come back whole: reading it from the field number that
  # only holds while STIME is a single clock field returns the tail of the date
  # glued to the front of the command instead, and on the Windows side that
  # truncated path is what decides whether the row names a verified harness.
  got=$(FM_TEST_CYG_STIME='Sep  6' lib_eval "$fakebin" 'fm_ps_comm 700') \
    || fail "fm_ps_comm failed on a two-field date STIME"
  [ "$got" = '/opt/claude/versions/2.1.220' ] \
    || fail "fm_ps_comm misread a date-form STIME row as '$got'"
  got=$(FM_TEST_CYG_STIME='Sep  6' lib_eval "$fakebin" 'fm_ps_args 700') \
    || fail "fm_ps_args failed on a two-field date STIME"
  [ "$got" = '/opt/claude/versions/2.1.220' ] \
    || fail "fm_ps_args misread a date-form STIME row as '$got'"
  got=$(FM_TEST_CYG_STIME='Sep  6' lib_eval "$fakebin" 'fm_ps_ppid 700') \
    || fail "fm_ps_ppid failed on a two-field date STIME"
  [ "$got" = 1 ] || fail "fm_ps_ppid misread a date-form STIME row as '$got'"

  # The Windows-side table is read through the same column logic.
  got=$(FM_TEST_WIN_TABLE="$WIN_TABLE_DATE_STIME" lib_eval "$fakebin" 'fm_win_command 7204') \
    || fail "fm_win_command failed on a two-field date STIME row"
  [ "$got" = 'C:/Users/u/.local/bin/claude' ] \
    || fail "fm_win_command misread a date-form STIME row as '$got'"
  got=$(FM_TEST_WIN_TABLE="$WIN_TABLE_DATE_STIME" CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the Windows session was not identified behind a date-form STIME"
  [ "$got" = 'win:7204' ] || fail "expected win:7204 behind a date-form STIME, got '$got'"
  pass "session-lock: a two-field date STIME does not truncate the command a ps row reports"
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
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
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
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_windows_session_is_identified_from_its_published_pid
test_windows_published_pid_is_confirmed_before_it_is_trusted
test_windows_pid_is_never_resolved_as_a_cygwin_pid
test_a_published_identity_is_accepted_by_the_gates_that_read_the_lock
test_cygwin_ps_without_o_still_resolves_a_local_harness
test_cygwin_date_form_stime_does_not_truncate_the_command
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock

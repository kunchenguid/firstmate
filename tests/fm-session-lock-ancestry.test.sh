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
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
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
# is a Windows process Cygwin cannot see.

# A fakebin whose ps behaves like Cygwin's and whose uname reports MINGW.
# The Windows-side table is supplied per case through FM_TEST_WIN_TABLE, in the
# same column order the real `ps -W` prints.
cygwin_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'MINGW64_NT-10.0-26200'
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  # Cygwin's ps has no -o option at all; it fails the whole invocation.
  [ "$a" = "-o" ] && { echo "ps: unknown option -- o" >&2; exit 1; }
done
mode=p full=0 pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -W) mode=W; shift ;;
    -f) full=1; shift ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$mode" = W ]; then
  [ "${FM_TEST_WIN_QUERY_EXIT:-0}" = 0 ] || exit "$FM_TEST_WIN_QUERY_EXIT"
  if [ -n "${FM_TEST_WIN_FAIL_ONCE_COUNTER:-}" ]; then
    count=$(cat "$FM_TEST_WIN_FAIL_ONCE_COUNTER" 2>/dev/null || true)
    count=${count:-0}
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_TEST_WIN_FAIL_ONCE_COUNTER"
    [ "$count" -ne 1 ] || exit 7
  fi
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  [ -n "${FM_TEST_WIN_TABLE:-}" ] && printf '%s\n' "$FM_TEST_WIN_TABLE"
  exit 0
fi
# The Cygwin-side table. 700 is an MSYS-native harness; everything else is an
# ordinary shell whose parent link is severed exactly as the real ps reports it.
case "$pid" in
  700) comm='/opt/claude/versions/2.1.220'; ppid=1 ;;
  *)   comm='/usr/bin/bash'; ppid=${FM_TEST_CYG_PPID:-1} ;;
esac
if [ "$full" = 1 ]; then
  printf '%s\n' '     UID     PID    PPID  TTY        STIME COMMAND'
  printf 'u %s %s ? 00:00:00 %s\n' "$pid" "$ppid" "$comm"
else
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  printf '%s %s %s 9999 ? 0 00:00:00 %s\n' "$pid" "$ppid" "$pid" "$comm"
fi
SH
  chmod +x "$fakebin/uname" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# WINPID 7204 is the session harness. 4321 is an ordinary desktop process, and
# 5150 is the path-shaped lookalike that must never read as a harness.
WIN_TABLE='  4201508       0       0       7204  ?              0 22:24:48 C:\Users\u\.local\bin\claude.exe
  4198625       0       0       4321  ?              0 22:24:48 C:\Windows\explorer.exe
  4199454       0       0       5150  ?              0 22:24:48 C:\tools\claude-notes\helper.exe'

test_windows_session_is_identified_from_its_published_pid() {
  local dir fakebin got
  dir="$TMP_ROOT/win-published"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"
  printf 'win:7204\n' > "$dir/state/.lock"

  got=$(FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the session was not identified at all on a severed Cygwin parent link"
  [ "$got" = 'win:7204' ] || fail "expected the tagged Windows session pid win:7204, got '$got'"
  FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_pid_alive win:7204' \
    || fail "a live Windows-side session was classified as a dead lock owner"
  FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock did not recognize itself as the owner"
  pass "session-lock: a Windows session is identified from its published pid across the severed parent link"
}

test_windows_query_outcomes_reach_every_owner_gate() {
  local dir fakebin case_dir counter out rc
  dir="$TMP_ROOT/win-query-outcomes"
  fakebin=$(cygwin_fakebin "$dir")

  case_dir="$dir/present"
  mkdir -p "$case_dir/state"
  printf '%s\n' 'win:7204' > "$case_dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = 'lock: held by live harness pid win:7204' ] || fail "present Windows owner was not live: $out"
  if PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" "$ROOT/bin/fm-lock.sh" native-admission-predicate >/dev/null 2>&1; then
    fail "native admission accepted a present Windows owner"
  fi
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_CYG_PPID=700 FM_TEST_WIN_TABLE="$WIN_TABLE" "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ordinary acquisition replaced a present Windows owner"
  [ "$(cat "$case_dir/state/.lock")" = 'win:7204' ] || fail "present Windows owner changed during acquisition"

  case_dir="$dir/absent"
  mkdir -p "$case_dir/state"
  printf '%s\n' 'win:7204' > "$case_dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_TABLE='' "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = 'lock: stale (pid win:7204 dead or not a harness)' ] || fail "absent Windows owner was not stale: $out"
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_TABLE='' "$ROOT/bin/fm-lock.sh" native-admission-predicate >/dev/null \
    || fail "native admission did not accept a proven-absent Windows owner"
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_CYG_PPID=700 FM_TEST_WIN_TABLE='' "$ROOT/bin/fm-lock.sh" >/dev/null \
    || fail "ordinary acquisition did not replace a proven-absent Windows owner"
  [ "$(cat "$case_dir/state/.lock")" = 700 ] || fail "proven-absent Windows owner was not replaced by the current harness"

  case_dir="$dir/failed"
  mkdir -p "$case_dir/state"
  printf '%s\n' 'win:7204' > "$case_dir/state/.lock"
  rc=0
  FM_TEST_WIN_QUERY_EXIT=7 lib_eval "$fakebin" 'fm_harness_pid_alive win:7204' >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "failed Windows query did not remain unknown: $rc"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_QUERY_EXIT=7 "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = 'lock: held by owner with unconfirmed health (pid win:7204)' ] || fail "failed Windows query was not reported as unknown: $out"
  if PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_QUERY_EXIT=7 "$ROOT/bin/fm-lock.sh" native-admission-predicate >/dev/null 2>&1; then
    fail "native admission accepted an owner after a failed Windows query"
  fi
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_CYG_PPID=700 FM_TEST_WIN_QUERY_EXIT=7 "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ordinary acquisition replaced an owner after a failed Windows query"
  [ "$(cat "$case_dir/state/.lock")" = 'win:7204' ] || fail "failed Windows query changed the recorded owner"

  case_dir="$dir/fail-once"
  counter="$case_dir/query-count"
  mkdir -p "$case_dir/state"
  printf '%s\n' 'win:7204' > "$case_dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_FAIL_ONCE_COUNTER="$counter" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = 'lock: held by owner with unconfirmed health (pid win:7204)' ] \
    || fail "transient Windows query failure was reclassified by status: $out"
  [ "$(cat "$counter")" = 1 ] || fail "status queried one owner decision more than once"

  rm -f "$counter"
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_FAIL_ONCE_COUNTER="$counter" "$ROOT/bin/fm-lock.sh" native-admission-predicate >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "native admission accepted an owner after a transient Windows query failure"
  [ "$(cat "$counter")" = 1 ] || fail "native admission queried one owner decision more than once"

  rm -f "$counter"
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_CYG_PPID=700 FM_TEST_WIN_FAIL_ONCE_COUNTER="$counter" "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ordinary acquisition replaced an owner after a transient Windows query failure"
  [ "$(cat "$case_dir/state/.lock")" = 'win:7204' ] || fail "transient Windows query failure changed the recorded owner"
  [ "$(cat "$counter")" = 1 ] || fail "ordinary acquisition queried one owner decision more than once"
  pass "session-lock: Windows query presence, absence, and failure remain distinct through status and acquisition"
}

test_harness_detection_uses_shared_native_selection() {
  local dir bindir fakebin home out shape
  dir="$TMP_ROOT/native-harness-selection"
  bindir="$dir/bin"
  home="$dir/home"
  mkdir -p "$bindir" "$home/state" "$home/config"
  cp "$ROOT/bin/fm-harness.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-gemini-lib.sh" "$bindir/"
  fakebin=$(cygwin_fakebin "$dir/fake")
  cat > "$fakebin/cygpath" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
SH
  cat > "$bindir/fm-native-owner.exe" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = owner ] && [ "${2:-}" = harness ] || exit 2
case "${FM_TEST_NATIVE_VERDICT:-}" in codex) printf '%s\n' codex ;; *) exit 2 ;; esac
SH
  chmod +x "$bindir/fm-harness.sh" "$bindir/fm-native-owner.exe" "$fakebin/cygpath"

  out=$(env -u CLAUDECODE -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
    -u FM_PI_HARNESS -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" FM_HOME="$home" \
    PI_CODING_AGENT=true FM_TEST_NATIVE_VERDICT=codex "$bindir/fm-harness.sh")
  [ "$out" = pi ] || fail "ordinary marker routing changed without a native record: $out"

  printf '%s\n' 'native:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$home/state/.lock"
  out=$(env -u CLAUDECODE -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
    -u FM_PI_HARNESS -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" FM_HOME="$home" \
    PI_CODING_AGENT=true "$bindir/fm-harness.sh")
  [ "$out" = unknown ] || fail "native lock without authenticated proof fell through to a marker: $out"

  rm "$home/state/.lock"
  for shape in regular directory broken-link; do
    case "$shape" in
      regular) printf '%s\n' '{}' > "$home/owner-probe.json" ;;
      directory) mkdir "$home/owner-probe.json" ;;
      broken-link) ln -s "$home/missing-owner-probe" "$home/owner-probe.json" ;;
    esac
    out=$(env -u CLAUDECODE -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
      -u FM_PI_HARNESS -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" FM_HOME="$home" \
      PI_CODING_AGENT=true "$bindir/fm-harness.sh")
    [ "$out" = unknown ] || fail "$shape native probe fell through to a marker: $out"
    case "$shape" in directory) rmdir "$home/owner-probe.json" ;; *) rm "$home/owner-probe.json" ;; esac
  done
  printf '%s\n' '{}' > "$home/owner-probe.json"
  out=$(env -u CLAUDECODE -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    -u GEMINI_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u FM_OMP_HARNESS \
    -u FM_PI_HARNESS -u FM_STATE_OVERRIDE PATH="$fakebin:$PATH" FM_HOME="$home" \
    PI_CODING_AGENT=true FM_TEST_NATIVE_VERDICT=codex "$bindir/fm-harness.sh")
  [ "$out" = codex ] || fail "authenticated native probe did not select Codex: $out"
  pass "harness detection delegates durable native selection without marker fallback"
}

test_windows_published_pid_is_confirmed_before_it_is_trusted() {
  local dir fakebin
  dir="$TMP_ROOT/win-unconfirmed"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # A published pid is a claim. Each of these shapes must be discarded rather
  # than bound: a process that is gone, one that is not a harness at all, and a
  # path that merely contains the harness name inside a longer component.
  for claimed in 9999 4321 5150; do
    if FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID="$claimed" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
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
  fakebin=$(cygwin_fakebin "$dir")
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
  fakebin=$(cygwin_fakebin "$dir")
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
  identity=$(FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "fixture is vacuous: no identity was published to gate on"
  lib_eval "$fakebin" "fm_session_pid_valid '$identity'" \
    || fail "the identity '$identity' this session publishes is rejected by the gates that read it back"

  # A local pid stays equally valid: the Windows shape is additional, not a
  # replacement, and the same predicate serves both platforms.
  lib_eval "$fakebin" 'fm_session_pid_valid 700' \
    || fail "an ordinary local pid was rejected as an invalid lock identity"

  # Still fail closed on the shapes a torn or hand-edited lock produces, and on
  # a bare tag carrying no pid at all.
  for bad in '' 'win:' 'win:abc' 'win:123oops' 'win:1:2' 'abc' '70 0' '-1'; do
    if lib_eval "$fakebin" "fm_session_pid_valid '$bad'"; then
      fail "the malformed lock value '$bad' was accepted as a usable identity"
    fi
    case "$bad" in
      win:*)
        if lib_eval "$fakebin" "fm_win_untag_pid '$bad'"; then
          fail "the malformed lock value '$bad' was reduced to a Windows pid"
        fi
        ;;
    esac
  done
  pass "session-lock: a published identity is accepted by every gate that reads the lock"
}

test_native_admission_preserves_a_partially_numeric_windows_identity() {
  local dir out rc
  dir="$TMP_ROOT/win-partial-identity"
  mkdir -p "$dir/state"
  printf '%s\n' 'win:123oops' > "$dir/state/.lock"

  set +e
  out=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-lock.sh" native-admission-predicate 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "native admission accepted a partially numeric Windows identity"
  [ "$(cat "$dir/state/.lock")" = 'win:123oops' ] || fail "native admission changed an ambiguous Windows identity"
  case "$out" in
    *'session lock owner is unrecognized; native launch refused'*) ;;
    *) fail "native admission did not identify the malformed owner: $out" ;;
  esac
  pass "session-lock: native admission preserves a partially numeric Windows identity"
}

test_ordinary_acquisition_preserves_malformed_windows_identities() {
  local dir fakebin bad case_dir out rc index real_ln
  dir="$TMP_ROOT/win-malformed-acquisition"
  fakebin=$(cygwin_fakebin "$dir")
  index=0

  for bad in 'win:' 'win:abc' 'win:123oops' 'win:1:2'; do
    index=$((index + 1))
    case_dir="$dir/preclaim-$index"
    mkdir -p "$case_dir/state"
    printf '%s\n' "$bad" > "$case_dir/state/.lock"

    set +e
    out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
      FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID=7204 "$ROOT/bin/fm-lock.sh" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "ordinary acquisition accepted malformed Windows identity '$bad'"
    [ "$(cat "$case_dir/state/.lock")" = "$bad" ] \
      || fail "ordinary acquisition changed malformed Windows identity '$bad'"
    case "$out" in
      *'session lock owner is unrecognized; operate read-only until resolved'*) ;;
      *) fail "ordinary acquisition did not identify malformed owner '$bad': $out" ;;
    esac
  done

  case_dir="$dir/locked-recheck"
  mkdir -p "$case_dir/state"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
target=
for target in "$@"; do
  :
done
if [ "$target" = "$FM_TEST_LOCK_STATE/.lock.acquire" ]; then
  printf '%s\n' 'win:123oops' > "$FM_TEST_LOCK_STATE/.lock"
fi
exec "$FM_TEST_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"

  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" CLAUDE_PID=7204 FM_TEST_REAL_LN="$real_ln" \
    FM_TEST_LOCK_STATE="$case_dir/state" "$ROOT/bin/fm-lock.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "locked acquisition recheck accepted a malformed Windows identity"
  [ "$(cat "$case_dir/state/.lock")" = 'win:123oops' ] \
    || fail "locked acquisition recheck changed a malformed Windows identity"
  case "$out" in
    *'session lock owner is unrecognized; operate read-only until resolved'*) ;;
    *) fail "locked acquisition recheck did not identify the malformed owner: $out" ;;
  esac
  pass "session-lock: ordinary acquisition preserves malformed Windows identities at both checks"
}

test_status_distinguishes_malformed_windows_identities() {
  local dir fakebin bad case_dir out index
  dir="$TMP_ROOT/win-malformed-status"
  fakebin=$(cygwin_fakebin "$dir")
  index=0

  for bad in 'win:' 'win:abc' 'win:123oops' 'win:1:2'; do
    index=$((index + 1))
    case_dir="$dir/malformed-$index"
    mkdir -p "$case_dir/state"
    printf '%s\n' "$bad" > "$case_dir/state/.lock"

    out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
      FM_TEST_WIN_TABLE="$WIN_TABLE" "$ROOT/bin/fm-lock.sh" status)
    [ "$out" = 'lock: held by unrecognized owner with unknown health' ] \
      || fail "status classified malformed Windows identity '$bad' as known: $out"
    [ "$(cat "$case_dir/state/.lock")" = "$bad" ] \
      || fail "status changed malformed Windows identity '$bad'"
  done

  case_dir="$dir/live"
  mkdir -p "$case_dir/state"
  printf '%s\n' 'win:7204' > "$case_dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = 'lock: held by live harness pid win:7204' ] \
    || fail "status lost a valid live Windows owner: $out"

  case_dir="$dir/dead"
  mkdir -p "$case_dir/state"
  printf '%s\n' 'win:9999' > "$case_dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_WIN_TABLE="$WIN_TABLE" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = 'lock: stale (pid win:9999 dead or not a harness)' ] \
    || fail "status lost a valid dead Windows owner: $out"
  pass "session-lock: status preserves malformed Windows identities without confusing them with valid owners"
}

test_cygwin_ps_without_o_still_resolves_a_local_harness() {
  local dir fakebin got
  dir="$TMP_ROOT/cygwin-local"
  fakebin=$(cygwin_fakebin "$dir")
  mkdir -p "$dir/state"

  # An MSYS-native harness lives in the same process table as this shell, so it
  # must resolve through the ordinary walk and stay an untagged pid. This is
  # what proves the walk survives a ps with no -o option at all.
  got=$(FM_TEST_CYG_PPID=700 FM_TEST_WIN_TABLE="$WIN_TABLE" FM_TEST_CLAUDE_PID=7204 \
    lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a harness in the local process table was not resolved when ps rejected -o"
  [ "$got" = 700 ] || fail "expected the untagged local harness pid 700, got '$got'"
  pass "session-lock: a harness in the local process table resolves untagged when ps has no -o option"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
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
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got
  dir="$TMP_ROOT/background-session"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\n' > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\n' > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\n' > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a symlinked sidecar was trusted"
  fi
  rm -f "$state/.lock-session"
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(fm_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
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
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
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

test_native_state_contract() (
  # shellcheck source=/dev/null
  . "$LIB"
  local answer rc identity=native:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa FM_HOME FM_STATE_OVERRIDE
  # shellcheck disable=SC2329 # Mock invoked indirectly by fm_native_owner_state.
  fm_native_owner_call() { return "$answer"; }
  fm_session_pid_valid "$identity" || fail "valid native identity rejected"
  if fm_session_pid_valid native:123; then fail "malformed native identity accepted"; fi
  for answer in 0 1 2; do
    rc=0; fm_native_owner_state "$identity" || rc=$?
    [ "$rc" -eq "$answer" ] || fail "native three-state result collapsed"
    rc=0; fm_harness_pid_alive "$identity" || rc=$?
    if [ "$answer" -eq 0 ]; then
      [ "$rc" -eq 0 ] || fail "proven-live native owner lost positive health"
    else
      [ "$rc" -ne 0 ] || fail "dead or unknown native owner reported positive health"
    fi
    rc=0; fm_harness_pid_excludes "$identity" || rc=$?
    if [ "$answer" -eq 1 ]; then
      [ "$rc" -ne 0 ] || fail "proven-dead owner retained occupancy"
    else
      [ "$rc" -eq 0 ] || fail "live or unknown owner lost exclusion"
    fi
  done
  FM_HOME="$TMP_ROOT/native-selection"
  FM_STATE_OVERRIDE="$FM_HOME/state"
  mkdir -p "$FM_STATE_OVERRIDE"
  if fm_native_owner_selected; then fail "ordinary home opted in without records"; fi
  printf '%s\n' "$identity" > "$FM_STATE_OVERRIDE/.lock"
  fm_native_owner_selected || fail "native lock lost routing without its binding"
  pass "native identity routing preserves unknown exclusion without certifying health"
)

test_native_owns_uses_shared_dispatch() (
  local dir fakebin state ambient args rc expected
  dir="$TMP_ROOT/native-owns-dispatch"
  fakebin="$dir/fakebin"
  state="$dir/selected/state"
  ambient="$dir/ambient/state"
  mkdir -p "$fakebin" "$state" "$ambient"
  printf '%s\n' '{}' > "$dir/selected/owner-probe.json"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' MINGW64_NT-fixture
SH
  cat > "$fakebin/cygpath" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
SH
  cat > "$dir/fm-native-owner.exe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_TEST_NATIVE_ARGS"
exit "$FM_TEST_NATIVE_EXIT"
SH
  chmod +x "$fakebin/uname" "$fakebin/cygpath" "$dir/fm-native-owner.exe"
  # shellcheck source=/dev/null
  . "$LIB"
  # shellcheck disable=SC2034 # Test input consumed by fm_native_owner_call.
  FM_NATIVE_OWNER_BIN="$dir/fm-native-owner.exe"
  FM_HOME="$dir/ambient"
  FM_STATE_OVERRIDE="$ambient"
  args="$dir/arguments"
  for expected in 0 2; do
    rc=0
    PATH="$fakebin:$PATH" FM_TEST_NATIVE_ARGS="$args" FM_TEST_NATIVE_EXIT="$expected" \
      fm_session_lock_owned_by_self "$state" || rc=$?
    [ "$rc" -eq "$expected" ] || fail "native owns changed verifier exit $expected to $rc"
    [ "$(wc -l < "$args" | tr -d ' ')" -eq 3 ] && [ "$(sed -n '1p' "$args")" = owner ] \
      && [ "$(sed -n '2p' "$args")" = owns ] && [ "$(sed -n '3p' "$args")" = "$state" ] \
      || fail "native owns did not preserve the selected state override"
  done
  pass "native self-ownership delegates through the shared owner command"
)

test_native_status_and_acquisition_behavior() {
  local dir bindir fakebin identity out rc
  dir="$TMP_ROOT/native-status"
  bindir="$dir/bin"
  fakebin="$dir/fakebin"
  identity=native:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$bindir" "$fakebin" "$dir/state"
  cp "$ROOT/bin/fm-lock.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$bindir/"
  cat > "$bindir/fm-native-owner.exe" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  alive) exit "${FM_TEST_NATIVE_STATE:?}" ;;
  identity) printf '%s\n' 'native:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; exit 0 ;;
  *) exit 2 ;;
esac
SH
  cat > "$fakebin/cygpath" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}"
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *comm=*) printf '%s\n' codex ;;
  *args=*) printf '%s\n' codex ;;
  *ppid=*) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' MINGW64_NT-fixture
SH
  chmod +x "$bindir/fm-native-owner.exe" "$bindir/fm-lock.sh" "$fakebin/cygpath" "$fakebin/ps" "$fakebin/uname"
  printf '%s\n' "$identity" > "$dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_TEST_NATIVE_STATE=2 "$bindir/fm-lock.sh" status)
  case "$out" in
    *'held by native owner with unconfirmed health'*) ;;
    *) fail "unknown native owner status was not distinguished: $out" ;;
  esac
  case "$out" in *'held by live harness'*) fail "unknown native owner status reported positive health" ;; esac
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_TEST_NATIVE_STATE=1 "$bindir/fm-lock.sh" status)
  case "$out" in *"stale (native owner identity $identity dead or not a harness)"*) ;; *) fail "dead native owner status mislabeled its identity: $out" ;; esac
  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_TEST_NATIVE_STATE=2 "$bindir/fm-lock.sh" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unknown native owner did not exclude acquisition"
  [ "$(cat "$dir/state/.lock")" = "$identity" ] || fail "unknown native owner was overwritten during acquisition"
  case "$out" in *"native owner identity $identity"*) ;; *) fail "native exclusion mislabeled its owner identity: $out" ;; esac
  case "$out" in *"pid $identity"*) fail "native exclusion labeled an opaque identity as a pid: $out" ;; esac
  printf '%s\n' 'native:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > "$dir/state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_TEST_NATIVE_STATE=0 "$bindir/fm-lock.sh")
  case "$out" in *'lock acquired: native owner identity native:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'*) ;; *) fail "native acquisition mislabeled its owner identity: $out" ;; esac
  pass "native lock status distinguishes unknown health while acquisition remains excluded"
}

test_numeric_ancestry_interfaces_reject_native_identity() {
  local identity=native:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa out rc
  set +e
  out=$("$ROOT/bin/fm-harness.sh" ancestry "$identity" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "ancestry accepted a native lock identity as a process id: $out"
  case "$out" in *'ancestry takes a numeric pid'*) ;; *) fail "ancestry refusal did not preserve its numeric contract: $out" ;; esac

  set +e
  out=$("$ROOT/bin/fm-harness.sh" ancestry-descent 700 "$identity" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "ancestry-descent accepted a native lock identity as a process id: $out"
  case "$out" in *'ancestry-descent takes numeric pids'*) ;; *) fail "ancestry-descent refusal did not preserve its numeric contract: $out" ;; esac
  pass "numeric ancestry interfaces reject native lock identities"
}

test_native_state_contract
test_native_owns_uses_shared_dispatch
test_native_status_and_acquisition_behavior
test_numeric_ancestry_interfaces_reject_native_identity
# --- end-to-end layer: a background session whose helper chain is recycled ---
#
# The topology the four issue reports (#3902, #2314, #3398, #4066) recorded with
# real process listings: a front-end that acquired the lock, a transient daemon
# under it, the pty-host the daemon spawned, and the bg-spare inside the pty-host
# that runs the model loop and therefore fires every hook. Every fixture process
# is the fake claude, so the ancestry walk sees a contiguous claude-named run
# exactly as in production, and the tree is orphaned before use. The daemon is
# then ended while the front-end stays alive - the recycling that breaks the run
# above the pty-host - and the spare fires the real Stop auto-arm, the real
# turn-end guard, and the real lock script once per phase under a chosen hook
# environment, recording every verdict for the assertions below.

BG_FIXTURE_PIDS=()
reap_background_fixture() {
  local pid
  for pid in ${BG_FIXTURE_PIDS[@]+"${BG_FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_background_fixture; fm_test_cleanup' EXIT

make_background_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  # The whole bin, because the real turn-end guard composes far more of it than
  # the auto-arm alone; only the arm is replaced by the recording stub above.
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  # Every fixture script ends in an explicit exit so bash can never tail-exec the
  # script under test in place of the fake claude, which would collapse the
  # chain the assertions depend on.
  cat > "$dir/frontend.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/frontend-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/frontend-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/frontend-lock.rc"
"$FM_FIXTURE_CLAUDE" "$FM_HOME/daemon.sh" &
disown
while [ ! -e "$FM_HOME/state/stop-frontend" ]; do sleep 0.05; done
exit 0
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
exec -a 'claude bg-pty-host' "$FM_FIXTURE_CLAUDE" "$FM_HOME/ptyhost.sh" &
while :; do sleep 0.1; done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
exec -a 'claude bg-spare' "$FM_FIXTURE_CLAUDE" "$FM_HOME/spare.sh" &
while [ ! -e "$FM_HOME/state/stop-spare" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/spare.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-spare" ]; do
  req="$FM_HOME/state/fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    # shellcheck disable=SC1090
    . "$req"
    ( . "$FM_HOME/bin/fm-session-lock-lib.sh" && fm_harness_ancestry_pids ) > "$out/ancestry" 2>/dev/null
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
    printf '%s\n' "$?" > "$out/hook.rc"
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
    printf '%s\n' "$?" > "$out/guard.rc"
    "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
    printf '%s\n' "$?" > "$out/lock.rc"
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/frontend.sh" "$dir/daemon.sh" "$dir/ptyhost.sh" "$dir/spare.sh"
}

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "background-session fixture never produced $2"
}

fire_phase() {  # <dir> <n> <hook-environment-script>
  local dir=$1 n=$2
  printf '%s\n' "$3" > "$dir/state/fire-$n.tmp"
  mv "$dir/state/fire-$n.tmp" "$dir/state/fire-$n"
  wait_for_file "$dir/state/phase-$n/hook.rc" "phase $n"
  local i=0
  while [ "$i" -lt 400 ] && [ ! -e "$dir/state/phase-$n/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/phase-$n/done" ] || fail "background-session fixture never finished phase $n"
}

phase_value() {  # <dir> <n> <file>
  tr -d '[:space:]' < "$1/state/phase-$2/$3"
}

arm_count() {  # <dir>
  [ -e "$1/state/arm-ran" ] || { printf '0'; return; }
  wc -l < "$1/state/arm-ran" | tr -d ' '
}

# The recycled chain must still be treated as the owner: arm, no diagnostic,
# lock accepted, line 1 untouched while the recorded pid lives, sidecar bytes
# untouched.
expect_phase_owned() {  # <dir> <n> <expected-arms> <expected-lock-pid> <label>
  local dir=$1 n=$2 arms=$3 lock_pid=$4 label=$5
  expect_code 2 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not rewake"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: expected $arms arm(s), got $(arm_count "$dir")"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "$label: no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: the turn-end guard did not allow the stop"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/phase-$n/guard.out"; then
    fail "$label: the turn-end guard took the foreign-owner exit: $(cat "$dir/state/phase-$n/guard.out")"
  fi
  expect_code 0 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh refused the session's own lock: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$lock_pid" ] \
    || fail "$label: lock line 1 is $(phase_value "$dir" "$n" lock-after), expected $lock_pid"
  cmp -s "$dir/state/phase-$n/session-after" "$dir/sidecar-initial" \
    || fail "$label: the session sidecar is not byte-identical to the one the owner wrote"
}

# Not the owner: no arm, the guard's foreign-owner diagnostic naming the live
# owner, and the lock refusal naming both the owner pid and its recorded id.
expect_phase_foreign() {  # <dir> <n> <expected-arms> <owner-pid> <label>
  local dir=$1 n=$2 arms=$3 owner=$4 label=$5
  expect_code 0 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not stand down"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: a non-owner armed: $(arm_count "$dir") arm(s), expected $arms"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: a non-owner Stop did not end safely"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $owner" "$dir/state/phase-$n/guard.out" \
    || fail "$label: the guard did not report the live owner $owner: $(cat "$dir/state/phase-$n/guard.out")"
  expect_code 1 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh accepted a lock this session does not own"
  grep -q "another live firstmate session holds the lock (pid $owner, session S1)" "$dir/state/phase-$n/lock.out" \
    || fail "$label: the refusal did not name the owner pid and recorded session: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$owner" ] || fail "$label: a non-owner rewrote the lock"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain() {
  local dir frontend daemon ptyhost spare i
  dir="$TMP_ROOT/e2e-background-session"
  make_background_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/frontend.sh"
  wait_for_file "$dir/state/frontend-lock.rc" "the front-end's lock result"
  wait_for_file "$dir/state/spare-pid" "the bg-spare"
  frontend=$(tr -d '[:space:]' < "$dir/state/frontend-pid")
  daemon=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  spare=$(tr -d '[:space:]' < "$dir/state/spare-pid")
  BG_FIXTURE_PIDS+=("$frontend" "$daemon" "$ptyhost" "$spare")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/frontend-lock.rc")" "the front-end could not acquire the lock: $(cat "$dir/state/frontend-lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$frontend" ] \
    || fail "the front-end's lock names $(cat "$dir/state/.lock"), expected its own pid $frontend"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the front-end did not record its trusted session id beside the lock"
  cp "$dir/state/.lock-session" "$dir/sidecar-initial"

  # Phase 1: the healthy contiguous chain, the session's own id.
  fire_phase "$dir" 1 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  grep -qx "$frontend" "$dir/state/phase-1/ancestry" || fail "the healthy chain did not reach the front-end"
  expect_phase_owned "$dir" 1 1 "$frontend" "healthy chain"

  # Recycle the bridge: the daemon ends, the pty-host is reparented to init, and
  # the front-end that holds the lock stays alive.
  kill -TERM "$daemon"
  i=0
  while [ "$i" -lt 200 ] && { kill -0 "$daemon" 2>/dev/null || [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" != 1 ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" = 1 ] || fail "the pty-host was not reparented to init after the daemon ended"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end died with the daemon, so the recycled case cannot be exercised"

  # Phase 2: the same session id over the broken chain - the reported drift.
  fire_phase "$dir" 2 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  if grep -qx "$frontend" "$dir/state/phase-2/ancestry"; then
    fail "the recycled chain still reached the front-end, so this phase proves nothing"
  fi
  grep -qx "$spare" "$dir/state/phase-2/ancestry" || fail "the hook's ancestry lost its own spare"
  expect_phase_owned "$dir" 2 2 "$frontend" "recycled chain, same session"

  # Phases 3-5: a different id, the right id from a CLAUDE_PID outside the run,
  # and no id at all are each a non-owner over the same broken chain.
  fire_phase "$dir" 3 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  expect_phase_foreign "$dir" 3 2 "$frontend" "recycled chain, different session"
  fire_phase "$dir" 4 "export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$frontend"
  expect_phase_foreign "$dir" 4 2 "$frontend" "recycled chain, untrusted id"
  fire_phase "$dir" 5 ''
  expect_phase_foreign "$dir" 5 2 "$frontend" "recycled chain, no id"

  # Phase 6: the front-end exits; the same session reclaims its dead anchor
  # onto the spare - the model-loop process - not onto the outermost pty-host.
  : > "$dir/state/stop-frontend"
  i=0
  while [ "$i" -lt 200 ] && kill -0 "$frontend" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$frontend" 2>/dev/null && fail "the front-end did not exit"
  fire_phase "$dir" 6 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 6 3 "$spare" "dead front-end, same session"
  [ "$spare" != "$ptyhost" ] || fail "fixture collapsed the spare into the pty-host"

  : > "$dir/state/stop-spare"
  pass "session-lock e2e: a background session keeps its lock and its supervision across a recycled helper chain"
}

# A same-session confirmation must refresh a /clear re-key even while another
# process holds .lock.acquire. The prior-session-sweep-is-finishing refusal is
# a takeover rule and does not apply here; the confirmation waits, then writes
# the new id.
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock() {
  local dir session_pid holder_pid confirm_pid
  dir="$TMP_ROOT/confirm-under-claim"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/sidecar-after-acquire")" = S1 ] \
    || fail "the initial acquire did not record S1"
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same-session confirmation failed while the claim lock was held: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the sidecar still names $(cat "$dir/state/.lock-session"), expected the re-keyed id S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the confirmation rewrote lock line 1"
  grep -q 'lock acquired: harness pid' "$dir/state/confirm.out" \
    || fail "the confirmation did not report acquisition: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a same-session confirmation waits for the claim lock and refreshes a re-keyed id"
}

# If another live session publishes while a confirmation is waiting on the claim
# lock, the waiter must not overwrite that session's sidecar or report success.
test_same_session_confirmation_does_not_steal_after_wait() {
  local dir session_pid holder_pid confirm_pid other_pid
  dir="$TMP_ROOT/confirm-no-steal"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

"$FM_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/other-pid"
  while [ ! -e "$FM_HOME/state/stop-other" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
' &
printf '%s\n' "$!" > "$FM_HOME/state/other-bash-pid"
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_HOME/state/other-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$FM_HOME/state/other-pid" ] || {
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
}

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

cp "$FM_HOME/state/other-pid" "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
: > "$FM_HOME/state/stop-other"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/other-bash-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    FM_CLAUDE="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  wait_for_file "$dir/state/other-pid" "the other live harness pid"
  other_pid=$(tr -d '[:space:]' < "$dir/state/other-pid")
  BG_FIXTURE_PIDS+=("$other_pid")
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  [ "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" != 0 ] \
    || fail "the waiter reported success after another live session published: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = OTHER ] \
    || fail "the waiter overwrote the other session's sidecar to $(cat "$dir/state/.lock-session")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$other_pid" ] \
    || fail "the waiter rewrote lock line 1 off the other live session"
  grep -q "another live firstmate session holds the lock (pid $other_pid, session OTHER)" "$dir/state/confirm.out" \
    || fail "the waiter did not refuse the other live owner: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a waiting confirmation does not steal another session's lock"
}

# A failed line-1 write after publishing a new id must restore the previous
# sidecar, not leave the new id beside the unclaimed pid.
test_failed_lock_write_restores_previous_sidecar() {
  local dir stale_pid
  dir="$TMP_ROOT/restore-sidecar"
  mkdir -p "$dir/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/acquire.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/stale-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the first session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the first session did not record S1"
  stale_pid=$(tr -d '[:space:]' < "$dir/state/stale-pid")
  cp "$dir/state/.lock" "$dir/state/lock-before-reclaim"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected the previous id S1"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$stale_pid" ] \
    || fail "the failed reclaim rewrote lock line 1"
  cmp -s "$dir/state/lock-before-reclaim" "$dir/state/.lock" \
    || fail "the failed reclaim changed lock bytes when line 1 was unwritable"
  pass "session-lock: a failed lock write restores the previous sidecar"
}

# A failed line-1 write that had no previous sidecar must not leave the new id
# behind; the lock stays ancestry-only.
test_failed_lock_write_removes_new_sidecar_when_none_existed() {
  local dir
  dir="$TMP_ROOT/restore-absent-sidecar"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected none"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = 1 ] \
    || fail "the failed reclaim rewrote lock line 1"
  pass "session-lock: a failed lock write removes a newly created sidecar"
}

# A completed reclaim must keep the new id beside the new pid after the writer
# exits, so a late signal cannot unwind a verified publication.
test_verified_reclaim_keeps_new_sidecar() {
  local dir
  dir="$TMP_ROOT/verified-reclaim"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/new-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the reclaim failed: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the verified reclaim left sidecar $(cat "$dir/state/.lock-session"), expected S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/new-pid")" ] \
    || fail "the verified reclaim did not record the new anchor pid"
  pass "session-lock: a verified reclaim keeps the new sidecar beside the new pid"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_windows_session_is_identified_from_its_published_pid
test_windows_query_outcomes_reach_every_owner_gate
test_harness_detection_uses_shared_native_selection
test_windows_published_pid_is_confirmed_before_it_is_trusted
test_windows_pid_is_never_resolved_as_a_cygwin_pid
test_a_published_identity_is_accepted_by_the_gates_that_read_the_lock
test_native_admission_preserves_a_partially_numeric_windows_identity
test_ordinary_acquisition_preserves_malformed_windows_identities
test_status_distinguishes_malformed_windows_identities
test_cygwin_ps_without_o_still_resolves_a_local_harness
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_background_session_keeps_its_lock_across_a_recycled_chain
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock
test_same_session_confirmation_does_not_steal_after_wait
test_failed_lock_write_restores_previous_sidecar
test_failed_lock_write_removes_new_sidecar_when_none_existed
test_verified_reclaim_keeps_new_sidecar

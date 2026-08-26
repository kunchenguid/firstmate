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
#
# The harness declaration is cleared unless the case sets FM_TEST_DECLARED_PID,
# so no assertion here depends on the ambient CLAUDE_PID of whatever session runs
# this suite - a real one colliding with a fixture pid would otherwise decide the
# outcome silently.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a declaration=(-u CLAUDE_PID)
  [ -z "${FM_TEST_DECLARED_PID+x}" ] || declaration=("CLAUDE_PID=$FM_TEST_DECLARED_PID")
  env "${declaration[@]}" PATH="$fakebin:$PATH" bash -c "
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

test_declaration_is_trusted_only_inside_this_live_ancestry() {
  local dir fakebin got bogus
  dir="$TMP_ROOT/declaration-guards"
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
# Nothing runs under 410: real ps reports nothing and fails for a dead pid.
[ "$pid" != 410 ] || exit 1
case "$pid:$field" in
  300:comm=) printf '%s\n' claude ;;
  300:args=) printf '%s\n' claude ;;
  300:ppid=) printf '%s\n' 310 ;;
  310:comm=) printf '%s\n' claude ;;
  310:args=) printf '%s\n' claude ;;
  310:ppid=) printf '%s\n' 320 ;;
  320:comm=) printf '%s\n' claude ;;
  320:args=) printf '%s\n' claude ;;
  320:ppid=) printf '%s\n' 1 ;;
  400:comm=) printf '%s\n' claude ;;
  400:args=) printf '%s\n' claude ;;
  400:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=) printf '%s\n' 300 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # The contiguous run is session 300 -> daemon 310 -> launching session 320, so
  # the ancestry fallback always answers 320 while every declaration below names
  # something else. Which branch decided the identity is therefore readable off
  # the answer, and no assertion here can pass for both branches at once.
  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the contiguous harness run was not resolved without a declaration"
  [ "$got" = 320 ] \
    || fail "with nothing declared the identity must be the outermost pid 320, got '$got'"

  got=$(FM_TEST_DECLARED_PID=300 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a session pid declared inside the ancestry left identity unresolved"
  [ "$got" = 300 ] \
    || fail "a live declaration inside the ancestry must beat the fallback 320, got '$got'"

  # Alive, harness-named, and not in this ancestry: the shape an inherited value
  # from an unrelated session takes. Membership alone must reject it.
  lib_eval "$fakebin" 'fm_harness_pid_alive 400' \
    || fail "fixture is wrong: 400 must be a live harness for the membership guard to be what rejects it"
  got=$(FM_TEST_DECLARED_PID=400 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a declaration outside the ancestry left identity unresolved instead of falling back"
  [ "$got" != 400 ] \
    || fail "a live harness pid outside this ancestry was recorded as this session's identity"
  [ "$got" = 320 ] \
    || fail "a declaration outside the ancestry must fall back to 320, got '$got'"

  # Dead: recording it would name an owner no liveness check can ever confirm.
  if lib_eval "$fakebin" 'fm_harness_pid_alive 410'; then
    fail "fixture is wrong: 410 must be dead for the liveness guard to be what rejects it"
  fi
  got=$(FM_TEST_DECLARED_PID=410 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a dead declaration left identity unresolved instead of falling back"
  [ "$got" != 410 ] \
    || fail "a dead declared pid was recorded as this session's live identity"
  [ "$got" = 320 ] \
    || fail "a dead declaration must fall back to 320, got '$got'"

  for bogus in '' claude-300 '30 0' -300; do
    got=$(FM_TEST_DECLARED_PID="$bogus" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "a non-numeric declaration '$bogus' left identity unresolved instead of falling back"
    [ "$got" = 320 ] \
      || fail "a non-numeric declaration '$bogus' must fall back to 320, got '$got'"
  done
  pass "session-lock: a declared session pid is used only while it is live and inside this ancestry"
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

# --- background-session layer: which pid the WRITER records -------------------
#
# A daemon-hosted background session sits several harness-named hops below the
# session that launched it: session -> pty host -> daemon -> launching session,
# with no non-harness process anywhere in between. The whole chain therefore
# reads as one contiguous harness run, so resolving "this session" as the
# outermost pid of that run reaches past this session's own processes and lands
# on the launching session. The fixtures below build that real shape and drive
# the real bin/fm-lock.sh and the real Stop auto-arm through it.

install_guard_scripts() {  # <dir>
  local dir=$1
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  chmod +x "$dir/bin/fm-turnend-guard.sh"
  # The guard shells out for its repair line and matches watcher identity by
  # this path; neither decides anything these cases assert.
  cat > "$dir/bin/fm-supervision-instructions.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm supervision\n'
SH
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-watch.sh"
}

# A primary home plus the three-level launcher/daemon/session fixture. Each
# level runs through a real executable named "claude" so the ancestry walk sees
# a genuine contiguous harness run, and each records its own pid before doing
# anything else so bash cannot tail-exec-collapse two levels into one.
make_bg_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  install_guard_scripts "$dir"

  # The session a background job is launched FROM. It stays alive for the whole
  # case, so its pid is always a live harness pid.
  cat > "$dir/launcher.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 400 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/launcher-pid"
if [ "${FM_FIXTURE_LAUNCHER_TAKES_LOCK:-0}" = 1 ]; then
  CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/launcher-lock.out" 2>&1
  printf '%s\n' "$?" > "$FM_HOME/state/launcher-lock.rc"
fi
"$FM_CLAUDE_BIN" "$FM_HOME/daemon.sh" &
i=0
while [ "$i" -lt 600 ] && [ ! -e "$FM_HOME/state/lock-done" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ "${FM_FIXTURE_LAUNCHER_EXITS:-0}" = 1 ]; then
  : > "$FM_HOME/state/launcher-gone"
  exit 0
fi
i=0
while [ "$i" -lt 900 ] && [ ! -e "$FM_HOME/state/finished" ]; do
  sleep 0.05
  i=$((i + 1))
done
SH

  # The shared daemon that hosts background sessions. It exits once the session
  # has taken the lock, which is what severs the chain above the session and
  # leaves the session's own recorded identity unreachable from its ancestry.
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_CLAUDE_BIN" "$FM_HOME/session.sh" &
i=0
while [ "$i" -lt 600 ] && [ ! -e "$FM_HOME/state/lock-done" ]; do
  sleep 0.05
  i=$((i + 1))
done
exit 0
SH

  # The background session itself: session start first, then the Stop hooks
  # after the daemon above it has gone.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
# The harness names the session process to everything it spawns; the fixture
# stands in for that. FM_FIXTURE_DECLARED_PID_FILE overrides it with whatever
# the case planted there, which is how an inherited value from somewhere else
# is modelled.
if [ -n "${FM_FIXTURE_DECLARED_PID_FILE:-}" ]; then
  export CLAUDE_PID=$(cat "$FM_FIXTURE_DECLARED_PID_FILE")
else
  export CLAUDE_PID=$$
fi
"$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/session-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/session-lock.rc"
cp "$FM_HOME/state/.lock" "$FM_HOME/state/lock-after-start" 2>/dev/null
: > "$FM_HOME/state/lock-done"
i=0
while [ "$i" -lt 600 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ "${FM_FIXTURE_LAUNCHER_EXITS:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 600 ] && [ ! -e "$FM_HOME/state/launcher-gone" ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
printf '%s' '{"session_id":"fixture","stop_hook_active":false}' \
  | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$FM_HOME/state/guard.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/guard.rc"
: > "$FM_HOME/state/finished"
SH
  chmod +x "$dir/launcher.sh" "$dir/daemon.sh" "$dir/session.sh"
}

# Start the fixture detached, so the launcher itself is orphaned and the walk
# can never climb out of the fixture into the session running this suite.
run_bg_session_tree() {  # <dir> [<env assignment>...]
  local dir=$1 i
  shift
  env FM_HOME="$dir" FM_CLAUDE_BIN="$NAMED_CLAUDE" "$@" \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/launcher.sh"
  i=0
  while [ "$i" -lt 900 ] && [ ! -e "$dir/state/finished" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/finished" ] || fail "the background-session fixture never finished"
}

fixture_pid() {  # <dir> <name>
  tr -d '[:space:]' < "$1/state/$2"
}

assert_distinct_chain() {  # <dir>
  local dir=$1 launcher daemon session
  launcher=$(fixture_pid "$dir" launcher-pid)
  daemon=$(fixture_pid "$dir" daemon-pid)
  session=$(fixture_pid "$dir" session-pid)
  [ -n "$launcher" ] && [ -n "$daemon" ] && [ -n "$session" ] \
    && [ "$launcher" != "$daemon" ] && [ "$daemon" != "$session" ] && [ "$launcher" != "$session" ] \
    || fail "fixture did not produce three distinct harness levels: launcher=$launcher daemon=$daemon session=$session"
}

test_bg_session_records_its_own_identity_and_keeps_arming() {
  local dir launcher session recorded
  dir="$TMP_ROOT/bg-session-sole"
  make_bg_session_home "$dir"
  run_bg_session_tree "$dir"
  assert_distinct_chain "$dir"
  launcher=$(fixture_pid "$dir" launcher-pid)
  session=$(fixture_pid "$dir" session-pid)
  recorded=$(fixture_pid "$dir" lock-after-start)

  [ "$recorded" != "$launcher" ] \
    || fail "session start recorded the LAUNCHING session's pid $launcher as this session's identity"
  [ "$recorded" = "$session" ] \
    || fail "session start recorded '$recorded' as this session's identity, expected the session pid $session"
  expect_code 2 "$(hook_rc "$dir")" \
    "a background session that owns its home must claim it and rewake after the daemon above it has gone"
  [ -e "$dir/state/arm-ran" ] \
    || fail "supervision never armed for a background session that owns its home"
  [ "$(epoch_outcome "$dir")" = rewake ] \
    || fail "no claim was recorded for a background session, got: $(epoch_outcome "$dir")"
  pass "session-lock: a background session records its own identity and keeps claiming its home"
}

test_bg_session_never_claims_a_home_a_live_session_owns() {
  local dir launcher recorded
  dir="$TMP_ROOT/bg-session-competing"
  make_bg_session_home "$dir"
  run_bg_session_tree "$dir" FM_FIXTURE_LAUNCHER_TAKES_LOCK=1
  assert_distinct_chain "$dir"
  launcher=$(fixture_pid "$dir" launcher-pid)
  recorded=$(fixture_pid "$dir" lock-after-start)

  expect_code 1 "$(fixture_pid "$dir" session-lock.rc)" \
    "a background session must be refused the lock a live launching session already holds"
  grep -q 'another live firstmate session holds the lock' "$dir/state/session-lock.out" \
    || fail "the refusal did not name the competing live session: $(cat "$dir/state/session-lock.out")"
  [ "$recorded" = "$launcher" ] \
    || fail "the live owner's lock was overwritten: expected $launcher, got $recorded"
  expect_code 0 "$(hook_rc "$dir")" "a session that does not own the home must stay inert"
  [ ! -e "$dir/state/arm-ran" ] || fail "a session that does not own the home armed supervision"
  [ -z "$(epoch_outcome "$dir")" ] || fail "a non-owning session wrote an auto-arm claim"
  pass "session-lock: a background session never claims a home a live launching session owns"
}

test_bg_session_recovers_a_genuinely_dead_owner() {
  local dir session recorded
  dir="$TMP_ROOT/bg-session-stale"
  make_bg_session_home "$dir"
  run_bg_session_tree "$dir" FM_FIXTURE_LAUNCHER_TAKES_LOCK=1 FM_FIXTURE_LAUNCHER_EXITS=1
  assert_distinct_chain "$dir"
  session=$(fixture_pid "$dir" session-pid)
  recorded=$(tr -d '[:space:]' < "$dir/state/.lock")

  expect_code 2 "$(hook_rc "$dir")" "a demonstrably dead owner must be reclaimed and the home claimed"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed after reclaiming a dead owner"
  [ "$recorded" = "$session" ] \
    || fail "the reclaimed lock does not name the recovering session: expected $session, got $recorded"
  pass "session-lock: a background session still reclaims a genuinely dead owner"
}

test_bg_session_stays_inert_while_away_mode_owns_supervision() {
  local dir
  dir="$TMP_ROOT/bg-session-afk"
  make_bg_session_home "$dir"
  : > "$dir/state/.afk"
  run_bg_session_tree "$dir"
  expect_code 0 "$(hook_rc "$dir")" "away mode must keep the auto-arm inert"
  [ ! -e "$dir/state/arm-ran" ] || fail "the auto-arm armed supervision while away mode owned it"
  [ -z "$(epoch_outcome "$dir")" ] || fail "the auto-arm claimed the home while away mode owned it"
  pass "session-lock: away mode still owns supervision for a background session"
}

test_bg_session_ignores_a_declaration_outside_its_own_ancestry() {
  local dir launcher session recorded outsider
  dir="$TMP_ROOT/bg-session-stale-declaration"
  make_bg_session_home "$dir"

  # A live harness process the fixture's session does not descend from: the shape
  # a genuinely stale inherited declaration takes, such as a tmux server started
  # from another session and every pane below it. It outlives the lock write so
  # liveness cannot be what rejects it - only ancestry membership can.
  "$NAMED_CLAUDE" -c '
i=0
while [ "$i" -lt 900 ] && [ ! -e "$0" ]; do
  sleep 0.05
  i=$((i + 1))
done
' "$dir/state/outsider-stop" &
  outsider=$!
  printf '%s\n' "$outsider" > "$dir/state/declared-pid"

  run_bg_session_tree "$dir" FM_FIXTURE_DECLARED_PID_FILE="$dir/state/declared-pid"
  assert_distinct_chain "$dir"
  launcher=$(fixture_pid "$dir" launcher-pid)
  session=$(fixture_pid "$dir" session-pid)
  recorded=$(fixture_pid "$dir" lock-after-start)
  ( . "$LIB" && fm_harness_pid_alive "$outsider" ) \
    || fail "fixture is wrong: the declared pid $outsider was not a live harness across the lock write"
  : > "$dir/state/outsider-stop"
  wait "$outsider" 2>/dev/null || true

  # The three candidate answers are deliberately three different pids, so the
  # recorded owner names which rule decided. Trusting the declaration would
  # record the outsider; the guard rejects it and the ancestry fallback answers
  # the launching session instead, exactly as before this branch. The auto-arm
  # consequently stays inert rather than arming blind.
  [ "$outsider" != "$launcher" ] && [ "$outsider" != "$session" ] && [ "$launcher" != "$session" ] \
    || fail "fixture did not diverge: outsider=$outsider launcher=$launcher session=$session"
  [ "$recorded" != "$outsider" ] \
    || fail "a live harness outside this session's ancestry was recorded as its identity: $outsider"
  [ "$recorded" = "$launcher" ] \
    || fail "an inherited declaration did not fall back to prior behavior: got '$recorded', expected $launcher"
  expect_code 0 "$(hook_rc "$dir")" "the documented fallback keeps the hook inert, not arming blind"
  pass "session-lock: a declaration outside this session's ancestry is ignored for the prior identity"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_declaration_is_trusted_only_inside_this_live_ancestry
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_bg_session_records_its_own_identity_and_keeps_arming
test_bg_session_never_claims_a_home_a_live_session_owns
test_bg_session_recovers_a_genuinely_dead_owner
test_bg_session_stays_inert_while_away_mode_owns_supervision
test_bg_session_ignores_a_declaration_outside_its_own_ancestry

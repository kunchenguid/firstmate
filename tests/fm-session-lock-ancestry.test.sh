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

test_election_skips_daemon_infrastructure() {
  local dir fakebin got
  dir="$TMP_ROOT/daemon-election"
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
  90:comm=) printf '%s\n' claude ;;
  90:args=) printf '%s\n' claude ;;
  90:ppid=) printf '%s\n' 1 ;;
  100:comm=) printf '%s\n' claude ;;
  100:args=) printf '%s\n' 'claude daemon run --port 1234' ;;
  100:ppid=) printf '%s\n' 90 ;;
  110:comm=) printf '%s\n' claude ;;
  110:args=) printf '%s\n' 'claude --bg-pty-host' ;;
  110:ppid=) printf '%s\n' 100 ;;
  120:comm=) printf '%s\n' claude ;;
  120:args=) printf '%s\n' 'claude --bg-spare' ;;
  120:ppid=) printf '%s\n' 110 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash hook.sh' ;;
  *:ppid=) printf '%s\n' 120 ;;
esac
SH
  chmod +x "$fakebin/ps"
  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "election failed to find a real session below the daemon chain"
  [ "$got" = 90 ] || fail "election picked '$got', expected the topmost real session pid 90"
  pass "session-lock: election skips daemon-infrastructure pids and returns the topmost real session"
}

test_election_fails_when_only_daemon_infrastructure_matches() {
  local dir fakebin
  dir="$TMP_ROOT/daemon-only"
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
  100:comm=) printf '%s\n' claude ;;
  100:args=) printf '%s\n' 'claude daemon run' ;;
  100:ppid=) printf '%s\n' 1 ;;
  110:comm=) printf '%s\n' claude ;;
  110:args=) printf '%s\n' 'claude --bg-pty-host' ;;
  110:ppid=) printf '%s\n' 100 ;;
  120:comm=) printf '%s\n' claude ;;
  120:args=) printf '%s\n' 'claude --bg-spare' ;;
  120:ppid=) printf '%s\n' 110 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash hook.sh' ;;
  *:ppid=) printf '%s\n' 120 ;;
esac
SH
  chmod +x "$fakebin/ps"
  if lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
    fail "election elected a pid from a run that is entirely daemon infrastructure"
  fi
  pass "session-lock: election fails when only daemon infrastructure matches"
}

test_daemon_pid_is_never_a_live_holder() {
  local dir fakebin
  dir="$TMP_ROOT/daemon-liveness"
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
  90:comm=) printf '%s\n' claude ;;
  90:args=) printf '%s\n' claude ;;
  90:ppid=) printf '%s\n' 1 ;;
  100:comm=) printf '%s\n' claude ;;
  100:args=) printf '%s\n' 'claude daemon run' ;;
  100:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 90 ;;
esac
SH
  chmod +x "$fakebin/ps"
  if lib_eval "$fakebin" 'fm_harness_pid_alive 100'; then
    fail "a live claude daemon run pid was accepted as a live session holder"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 90' \
    || fail "a live real session pid was rejected as a live holder"
  pass "session-lock: a live daemon pid is never a live session holder"
}

test_free_text_daemon_phrases_do_not_mark_a_real_session() {
  local dir fakebin got
  dir="$TMP_ROOT/daemon-free-text"
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
  80:comm=) printf '%s\n' claude ;;
  80:args=) printf '%s\n' 'claude daemon run' ;;
  80:ppid=) printf '%s\n' 1 ;;
  90:comm=) printf '%s\n' claude ;;
  90:args=) printf '%s\n' 'claude --model opus -cFIRSTMATE_OP: v1 launch-brief: restart claude daemon run and its --bg-pty-host / --bg-spare workers' ;;
  90:ppid=) printf '%s\n' 80 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash hook.sh' ;;
  *:ppid=) printf '%s\n' 90 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # The daemon markers appear only inside the session's prompt free text, so
  # pid 90 is a real session: it must win the election and count as live,
  # while the daemon above it still must not.
  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "a real session with daemon phrases in its prompt text lost the election entirely"
  [ "$got" = 90 ] || fail "election picked '$got', expected the real session pid 90"
  lib_eval "$fakebin" 'fm_harness_pid_alive 90' \
    || fail "a live session with daemon phrases in its prompt text was rejected as a live holder"
  if lib_eval "$fakebin" 'fm_harness_pid_alive 80'; then
    fail "the daemon above the free-text session was accepted as a live holder"
  fi
  pass "session-lock: daemon phrases in prompt free text never mark a real session as infrastructure"
}

test_node_wrapped_daemon_is_infrastructure() {
  local dir fakebin got
  dir="$TMP_ROOT/daemon-node-wrapped"
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
  60:comm=) printf '%s\n' node ;;
  60:args=) printf '%s\n' 'node /opt/node_modules/@anthropic-ai/claude-code/cli.js daemon run' ;;
  60:ppid=) printf '%s\n' 1 ;;
  70:comm=) printf '%s\n' node ;;
  70:args=) printf '%s\n' 'node /opt/node_modules/@anthropic-ai/claude-code/cli.js --resume' ;;
  70:ppid=) printf '%s\n' 60 ;;
  75:comm=) printf '%s\n' node ;;
  75:args=) printf '%s\n' 'node /opt/node_modules/@anthropic-ai/claude-code/cli.js -cFIRSTMATE_OP: v1 launch-brief: restart claude daemon run workers' ;;
  75:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash hook.sh' ;;
  *:ppid=) printf '%s\n' 70 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # An npm-installed Claude Code runs interpreter-wrapped, so the daemon
  # markers sit after the interpreter and script-path preamble; free text in a
  # wrapped session's argv still never matches.
  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "election found no real session below the node-wrapped daemon"
  [ "$got" = 70 ] || fail "election picked '$got', expected the wrapped session pid 70"
  if lib_eval "$fakebin" 'fm_harness_pid_alive 60'; then
    fail "a live node-wrapped daemon was accepted as a live session holder"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 70' \
    || fail "a live node-wrapped session was rejected as a live holder"
  lib_eval "$fakebin" 'fm_harness_pid_alive 75' \
    || fail "a live node-wrapped session with daemon phrases in its prompt was rejected"
  pass "session-lock: an interpreter-wrapped daemon is infrastructure, wrapped sessions stay real"
}

test_membership_walks_through_daemon_parented_chain() {
  local dir fakebin
  dir="$TMP_ROOT/daemon-membership"
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
  90:comm=) printf '%s\n' claude ;;
  90:args=) printf '%s\n' claude ;;
  90:ppid=) printf '%s\n' 1 ;;
  100:comm=) printf '%s\n' claude ;;
  100:args=) printf '%s\n' 'claude daemon run' ;;
  100:ppid=) printf '%s\n' 90 ;;
  110:comm=) printf '%s\n' claude ;;
  110:args=) printf '%s\n' 'claude --bg-pty-host' ;;
  110:ppid=) printf '%s\n' 100 ;;
  120:comm=) printf '%s\n' claude ;;
  120:args=) printf '%s\n' 'claude --bg-spare' ;;
  120:ppid=) printf '%s\n' 110 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash hook.sh' ;;
  *:ppid=) printf '%s\n' 120 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # A hook under the daemon worker chain must still match an inner session pid
  # recorded in the lock, walking through the daemon-infrastructure pids.
  printf '100\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "membership did not walk through the daemon chain to match the lock pid"
  printf '90\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "membership did not match the topmost real session pid"
  pass "session-lock: membership still walks through a daemon-parented chain"
}

test_non_claude_harnesses_are_untouched() {
  local dir fakebin got name
  for name in codex pi; do
    dir="$TMP_ROOT/nonclaude-$name"
    fakebin=$(fm_fakebin "$dir")
    mkdir -p "$dir/state"
    cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  500:comm=) printf '%s\n' $name ;;
  500:args=) printf '%s\n' '$name daemon run --bg-spare' ;;
  500:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash hook.sh' ;;
  *:ppid=) printf '%s\n' 500 ;;
esac
SH
    chmod +x "$fakebin/ps"
    # The argv deliberately leads with the daemon tokens: only Claude processes
    # may ever classify as daemon infrastructure.
    got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$name: the harness was not found in the ancestry"
    [ "$got" = 500 ] || fail "$name: election resolved '$got', expected 500"
    lib_eval "$fakebin" 'fm_harness_pid_alive 500' \
      || fail "$name: a live harness pid was rejected as a live holder"
  done
  pass "session-lock: non-Claude harnesses are untouched by the daemon logic"
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
test_election_skips_daemon_infrastructure
test_election_fails_when_only_daemon_infrastructure_matches
test_daemon_pid_is_never_a_live_holder
test_free_text_daemon_phrases_do_not_mark_a_real_session
test_node_wrapped_daemon_is_infrastructure
test_membership_walks_through_daemon_parented_chain
test_non_claude_harnesses_are_untouched
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock

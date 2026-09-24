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
# CLAUDE_PID and CLAUDE_CODE_SESSION_ID are read by the library as the harness's
# own declarations about THIS session, so every case states them explicitly
# through FM_TEST_CLAUDE_PID/FM_TEST_CLAUDE_SESSION instead of inheriting
# whatever session happens to be running this suite.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" \
  CLAUDE_PID="${FM_TEST_CLAUDE_PID:-}" \
  CLAUDE_CODE_SESSION_ID="${FM_TEST_CLAUDE_SESSION:-}" \
  bash -c "
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

test_daemon_hosted_session_ancestry() {
  local dir fakebin got
  dir="$TMP_ROOT/daemon-ancestry"
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
  800:comm=) printf '%s\n' claude ;;
  800:args=) printf '%s\n' 'claude daemon run' ;;
  800:ppid=) printf '%s\n' 1 ;;
  801:comm=) printf '%s\n' claude ;;
  801:args=) printf '%s\n' 'claude --bg-pty-host' ;;
  801:ppid=) printf '%s\n' 800 ;;
  802:comm=) printf '%s\n' bash ;;
  802:args=) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  802:ppid=) printf '%s\n' 801 ;;
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 901 ;;
  901:comm=) printf '%s\n' bash ;;
  901:args=) printf '%s\n' 'bash' ;;
  901:ppid=) printf '%s\n' 1 ;;
  902:comm=) printf '%s\n' bash ;;
  902:args=) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  902:ppid=) printf '%s\n' 900 ;;
  700:comm=) printf '%s\n' pi ;;
  700:args=) printf '%s\n' 'pi' ;;
  700:ppid=) printf '%s\n' 701 ;;
  701:comm=) printf '%s\n' bash ;;
  701:args=) printf '%s\n' 'bash' ;;
  701:ppid=) printf '%s\n' 1 ;;
  702:comm=) printf '%s\n' bash ;;
  702:args=) printf '%s\n' 'bash /repo/bin/some-hook.sh' ;;
  702:ppid=) printf '%s\n' 700 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash' ;;
  *:ppid=)
    if [ -n "${FM_TEST_HOOK_PARENT:-}" ]; then
      printf '%s\n' "$FM_TEST_HOOK_PARENT"
    else
      printf '%s\n' 802
    fi
    ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(FM_TEST_HOOK_PARENT=802 lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "daemon-hosted session was not resolved"
  [ "$got" = 801 ] || fail "daemon-hosted resolved '$got', expected per-session 801"

  got=$(FM_TEST_HOOK_PARENT=902 lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "interactive session was not resolved"
  [ "$got" = 900 ] || fail "interactive session resolved '$got', expected 900"

  if lib_eval "$fakebin" 'fm_harness_pid_alive 800'; then
    fail "legacy daemon lock was treated as a valid live owner"
  fi

  printf '801\n' > "$dir/state/.lock"
  FM_TEST_HOOK_PARENT=802 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "daemon-hosted session did not recognize its own lock"

  got=$(FM_TEST_HOOK_PARENT=702 lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "non-Claude harness was not resolved"
  [ "$got" = 700 ] || fail "non-Claude harness resolved '$got', expected 700"

  pass "session-lock: daemon-hosted ancestry stops before the daemon, non-Claude unchanged, legacy lock treated as stale"
}

# 2026-09-22 live evidence (Claude Code 2.1.280): a second pass-through layer,
# "bg-spare", now sits BELOW "bg-pty-host" in the chain and can be the very
# first harness match the walk reaches - hook shell -> claude bg-spare ->
# claude bg-pty-host -> claude daemon run --origin transient -> the outermost
# interactive claude. The walk must pass through every daemon/spare layer
# instead of stopping at the first one, so it still reaches and reports the
# outermost interactive session above them.
test_daemon_hosted_session_ancestry_with_bg_spare_layer() {
  local dir fakebin got
  dir="$TMP_ROOT/daemon-ancestry-bg-spare"
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
  16182:comm=) printf '%s\n' claude ;;
  16182:args=) printf '%s\n' 'claude' ;;
  16182:ppid=) printf '%s\n' 1 ;;
  65263:comm=) printf '%s\n' claude ;;
  65263:args=) printf '%s\n' 'claude daemon run --origin transient' ;;
  65263:ppid=) printf '%s\n' 16182 ;;
  65300:comm=) printf '%s\n' claude ;;
  65300:args=) printf '%s\n' 'claude bg-pty-host' ;;
  65300:ppid=) printf '%s\n' 65263 ;;
  65310:comm=) printf '%s\n' claude ;;
  65310:args=) printf '%s\n' 'claude bg-spare --bg-spare /tmp/cc-daemon/spare.claim.sock' ;;
  65310:ppid=) printf '%s\n' 65300 ;;
  65320:comm=) printf '%s\n' zsh ;;
  65320:args=) printf '%s\n' zsh ;;
  65320:ppid=) printf '%s\n' 65310 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=) printf '%s\n' 65320 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the walk did not reach the outermost interactive session past bg-spare and bg-pty-host"
  [ "$got" = 16182 ] || fail "ancestry resolved '$got', expected the outermost interactive session 16182"

  printf '16182\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the outermost interactive session did not recognize its own lock past two pass-through layers"

  if lib_eval "$fakebin" 'fm_harness_pid_alive 65263'; then
    fail "the transient daemon-run pid was treated as a valid standalone lock owner"
  fi
  pass "session-lock: the walk passes through a bg-spare layer below bg-pty-host to reach the outermost session"
}

# 2026-09-23 live evidence (Claude Code 2.1.280, pid 65360): a background
# session is hosted by a CLAIMED spare, and there is no interactive claude above
# it at all - the chain is hook shell -> claude bg-spare -> claude bg-pty-host ->
# launchd. bg-pty-host carries the spare's own --bg-spare argument through in its
# argv, so an argv-only reading skips BOTH layers, reaches a host-shaped pid 1,
# and reports no session at all. The harness's own CLAUDE_PID is what says which
# of those layers is the live session.
test_claimed_bg_spare_session_with_no_outer_claude() {
  local dir fakebin got
  dir="$TMP_ROOT/claimed-bg-spare"
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
  1:comm=) printf '%s\n' /sbin/launchd ;;
  1:args=) printf '%s\n' /sbin/launchd ;;
  1:ppid=) printf '%s\n' 0 ;;
  65350:comm=) printf '%s\n' 'claude bg-pty-host' ;;
  65350:args=) printf '%s\n' 'claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/2034be02/spare/456eecb8.pty.sock 200 50 -- /Users/u/.local/share/claude/versions/2.1.280 --bg-spare /tmp/cc-daemon-501/2034be02/spare/456eecb8.claim.sock' ;;
  65350:ppid=) printf '%s\n' 1 ;;
  65360:comm=) printf '%s\n' 'claude bg-spare' ;;
  65360:args=) printf '%s\n' 'claude bg-spare --bg-spare /tmp/cc-daemon-501/2034be02/spare/456eecb8.claim.sock' ;;
  65360:ppid=) printf '%s\n' 65350 ;;
  *:comm=) printf '%s\n' /bin/zsh ;;
  *:args=) printf '%s\n' '/bin/zsh' ;;
  *:ppid=) printf '%s\n' 65360 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '65360\n' > "$dir/state/.lock"

  # The failure as measured: with no harness declaration the walk reports
  # nothing, so the session cannot locate itself or claim its own home.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "the argv-only walk resolved a session in a chain where every claude layer reads as a shared spare"
  fi
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "the session recognized its own lock with no identity evidence at all"
  fi

  # The claim: the harness names the claimed spare as this session.
  got=$(FM_TEST_CLAUDE_PID=65360 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the claimed background session was not found in its own ancestry"
  [ "$got" = 65360 ] || fail "ancestry resolved '$got', expected the claimed background session 65360"
  FM_TEST_CLAUDE_PID=65360 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the claimed background session did not recognize its own lock"

  # Non-vacuity: the declaration is honored only for a pid this process actually
  # reached by walking its OWN ancestry, so a stale or foreign CLAUDE_PID adds
  # nothing, and the hosting pty layer is still a shared layer.
  if FM_TEST_CLAUDE_PID=99999 lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a CLAUDE_PID outside this ancestry was accepted as this session"
  fi
  got=$(FM_TEST_CLAUDE_PID=65350 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "declaring the pty host as the session resolved nothing"
  [ "$got" = 65350 ] || fail "declaring the pty host resolved '$got', expected 65350"

  # A claimed spare still holding the lock is a LIVE owner, but only because the
  # lock carries a session identity proving the recorded pid was a real session.
  if lib_eval "$fakebin" 'fm_harness_pid_alive 65360'; then
    fail "a spare-shaped pid passed the strict harness-liveness predicate"
  fi
  if lib_eval "$fakebin" "fm_session_lock_owner_alive '$dir/state'"; then
    fail "a spare-shaped lock owner was called live with no session identity recorded"
  fi
  printf 'sess-a\n' > "$dir/state/.lock-session"
  lib_eval "$fakebin" "fm_session_lock_owner_alive '$dir/state'" \
    || fail "a live background-hosted lock owner was reported dead, inviting a competing session to take the home"
  pass "session-lock: a claimed bg-spare session with no outer claude identifies itself and holds its home"
}

# The move itself: one session, two pids. A session that recorded the lock under
# the pid it was launched as must still own that lock after the harness re-hosts
# it, and must not be able to claim a lock recorded by a different session.
test_rehosted_session_owns_its_lock_by_session_identity() {
  local dir fakebin
  dir="$TMP_ROOT/rehosted-session"
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
  1:comm=) printf '%s\n' /sbin/launchd ;;
  1:args=) printf '%s\n' /sbin/launchd ;;
  1:ppid=) printf '%s\n' 0 ;;
  16182:comm=) printf '%s\n' claude ;;
  16182:args=) printf '%s\n' claude ;;
  16182:ppid=) printf '%s\n' 1 ;;
  65350:comm=) printf '%s\n' 'claude bg-pty-host' ;;
  65350:args=) printf '%s\n' 'claude bg-pty-host --bg-pty-host /tmp/s.pty.sock -- /opt/claude/2.1.280 --bg-spare /tmp/s.claim.sock' ;;
  65350:ppid=) printf '%s\n' 1 ;;
  65360:comm=) printf '%s\n' 'claude bg-spare' ;;
  65360:args=) printf '%s\n' 'claude bg-spare --bg-spare /tmp/s.claim.sock' ;;
  65360:ppid=) printf '%s\n' 65350 ;;
  *:comm=) printf '%s\n' /bin/zsh ;;
  *:args=) printf '%s\n' '/bin/zsh' ;;
  *:ppid=) printf '%s\n' 65360 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # The lock was recorded before the move, under the launching pid 16182, which
  # is still alive. No process link survives the move, so pid evidence alone
  # leaves this session locked out of its own home forever - the measured defect.
  printf '16182\n' > "$dir/state/.lock"
  if FM_TEST_CLAUDE_PID=65360 FM_TEST_CLAUDE_SESSION=sess-a \
    lib_eval "$fakebin" "fm_session_lock_pid_is_self '$dir/state'"; then
    fail "the re-hosted session was found in the pre-move pid's ancestry, so this case proves nothing"
  fi

  printf 'sess-a\n' > "$dir/state/.lock-session"
  FM_TEST_CLAUDE_PID=65360 FM_TEST_CLAUDE_SESSION=sess-a \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "a re-hosted session did not recognize the lock its own session start recorded"

  # A genuinely different concurrent session is still refused, and so is a
  # session that publishes no identity at all.
  if FM_TEST_CLAUDE_PID=65360 FM_TEST_CLAUDE_SESSION=sess-b \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a different concurrent session claimed a home held by sess-a"
  fi
  if FM_TEST_CLAUDE_PID=65360 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a session with no published identity claimed a home held by sess-a"
  fi

  # A malformed or oversized identity record is rejected, never compared.
  printf 'sess a; rm -rf /\n' > "$dir/state/.lock-session"
  if FM_TEST_CLAUDE_PID=65360 FM_TEST_CLAUDE_SESSION=sess-a \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a malformed identity record was compared instead of rejected"
  fi

  # The identity never overrides the pid gate: a missing or malformed lock pid
  # still fails closed even when the identity matches.
  printf 'sess-a\n' > "$dir/state/.lock-session"
  printf 'not-a-pid\n' > "$dir/state/.lock"
  if FM_TEST_CLAUDE_PID=65360 FM_TEST_CLAUDE_SESSION=sess-a \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a malformed lock pid was owned on the strength of the identity record alone"
  fi
  pass "session-lock: a re-hosted session owns its own lock by session identity, and no other session does"
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
# Publish exactly what the harness under test publishes, and nothing the suite's
# own session happens to be carrying.
if [ "${FM_FIXTURE_DECLARE_SESSION:-0}" = 1 ]; then
  export CLAUDE_PID=$$
else
  unset CLAUDE_PID
fi
unset CLAUDE_CODE_SESSION_ID
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
# shellcheck disable=SC2086 # deliberate: the fixture's argv shape is the subject
"$FM_SESSION_BIN" "$FM_HOME/session.sh" ${FM_FIXTURE_SESSION_ARGS:-}
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
# FM_FIXTURE_SESSION_ARGS and FM_FIXTURE_DAEMON_ARGS append real arguments to the
# fixture processes, so a tree can carry the argv shape under test; the caller
# exports them. FM_FIXTURE_DECLARE_SESSION decides whether the session publishes
# CLAUDE_PID, which is the whole counterfactual for a claimed-spare chain.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    # shellcheck disable=SC2086 # deliberate: the fixture's argv shape is the subject
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" "${@:2}" &' "$daemon_bin" "$dir/daemon.sh" ${FM_FIXTURE_DAEMON_ARGS:-}
  else
    # shellcheck disable=SC2086 # deliberate: the fixture's argv shape is the subject
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" "${@:2}" &' "$session_bin" "$dir/session.sh" ${FM_FIXTURE_SESSION_ARGS:-}
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

# The measured 2026-09-23 shape, in real processes: an orphaned pty-host layer
# that passes --bg-spare through, hosting a claimed spare that IS the session,
# with no interactive claude anywhere above them. The two runs differ in one
# condition only - whether the session publishes CLAUDE_PID - so the inert
# outcome and the claim are the same tree read two ways.
test_e2e_claimed_bg_spare_session_claims_the_home() {
  local dir before after session_pid
  dir="$TMP_ROOT/e2e-claimed-bg-spare"
  make_primary_home "$dir"
  SPARE_SOCK="/tmp/fm-fixture-spare.claim.sock"

  FM_FIXTURE_DECLARE_SESSION=0 \
  FM_FIXTURE_SESSION_ARGS="--bg-spare $SPARE_SOCK" \
  FM_FIXTURE_DAEMON_ARGS="--bg-pty-host /tmp/fm-fixture.pty.sock -- /opt/claude/2.1.280 --bg-spare $SPARE_SOCK" \
    run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  before=$(hook_rc "$dir")
  expect_code 0 "$before" "with no harness declaration every claude layer reads as a shared spare, so the hook must stay inert"
  [ ! -e "$dir/state/arm-ran" ] \
    || fail "supervision armed although the session could not be located at all"

  rm -f "$dir/state/hook.rc" "$dir/state/hook.out" "$dir/state/.claude-autoarm-epoch"
  FM_FIXTURE_DECLARE_SESSION=1 \
  FM_FIXTURE_SESSION_ARGS="--bg-spare $SPARE_SOCK" \
  FM_FIXTURE_DAEMON_ARGS="--bg-pty-host /tmp/fm-fixture.pty.sock -- /opt/claude/2.1.280 --bg-spare $SPARE_SOCK" \
    run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  after=$(hook_rc "$dir")
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  expect_code 2 "$after" "a claimed background session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a claimed background session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session_pid" ] \
    || fail "the session lock moved off the claimed background session"
  pass "session-lock e2e: a claimed bg-spare session under an orphaned pty host claims the home and arms supervision"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_daemon_hosted_session_ancestry
test_daemon_hosted_session_ancestry_with_bg_spare_layer
test_claimed_bg_spare_session_with_no_outer_claude
test_rehosted_session_owns_its_lock_by_session_identity
test_e2e_claimed_bg_spare_session_claims_the_home

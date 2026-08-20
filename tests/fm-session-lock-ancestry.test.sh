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
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
mkdir -p "$TMP_ROOT/lib-state"

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
  FM_STATE_OVERRIDE="$TMP_ROOT/lib-state" PATH="$fakebin:$PATH" bash -c "
    . \"\$1\"
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB" "$WAKE_LIB"
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

test_structured_identity_owns_and_refreshes_after_reparenting() {
  local dir fakebin first
  dir="$TMP_ROOT/identity-reparent"
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
  600:comm=) printf '%s\n' claude ;;
  600:args=) printf '%s\n' claude ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"

  printf '650\nharness=claude\nsession=stable-session\n' > "$dir/state/.lock"
  FM_SESSION_HARNESS=claude FM_SESSION_ID=stable-session FM_SESSION_PUBLISHER_PID=650 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "matching structured identity did not own with the recorded pid unchanged"

  printf '600\nharness=claude\nsession=stable-session\n' > "$dir/state/.lock"
  FM_SESSION_HARNESS=claude FM_SESSION_ID=stable-session FM_SESSION_PUBLISHER_PID=650 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "matching structured identity did not own after reparenting"
  first=$(sed -n '1p' "$dir/state/.lock")
  [ "$first" = 650 ] || fail "reparented identity did not refresh pid 600 to 650: $first"
  [ "$(sed -n '2p' "$dir/state/.lock")" = harness=claude ] \
    || fail "reparent refresh lost the recorded harness"
  [ "$(sed -n '3p' "$dir/state/.lock")" = session=stable-session ] \
    || fail "reparent refresh lost the stable identity"
  pass "session-lock identity: a matching session owns and atomically refreshes its reparented pid"
}

test_structured_identity_difference_preserves_competitor_and_missing_side_falls_back() {
  local dir fakebin
  dir="$TMP_ROOT/identity-branches"
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
  600:comm=) printf '%s\n' claude ;;
  600:args=) printf '%s\n' claude ;;
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

  printf '600\nharness=claude\nsession=recorded-session\n' > "$dir/state/.lock"
  if FM_SESSION_HARNESS=claude FM_SESSION_ID=current-session FM_SESSION_PUBLISHER_PID=650 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "different live structured identities were treated as one session"
  fi
  [ "$(sed -n '1p' "$dir/state/.lock")" = 600 ] \
    || fail "different identity rewrote the competing owner's pid"

  # An identity with no publisher provenance cannot be proven to be this
  # session's own, so it fails closed to ancestry rather than being trusted.
  if FM_SESSION_HARNESS=claude FM_SESSION_ID=recorded-session \
    lib_eval "$fakebin" 'fm_current_session_identity claude'; then
    fail "an identity with no publisher provenance was published as this session's"
  fi
  if FM_SESSION_HARNESS=claude FM_SESSION_ID=recorded-session \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an identity with no publisher provenance owned a lock outside this ancestry"
  fi

  # Identity missing on the current side: preserve the exact ancestry fallback.
  printf '650\nharness=claude\nsession=recorded-session\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "record-only identity did not fall back to ancestry membership"

  # Identity missing on the recorded side: the same fallback still applies.
  printf '650\nharness=claude\n' > "$dir/state/.lock"
  FM_SESSION_HARNESS=claude FM_SESSION_ID=current-session FM_SESSION_PUBLISHER_PID=650 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "current-only identity did not fall back to ancestry membership"

  # A missing side never widens that fallback to a live harness outside the
  # current ancestry.
  printf '600\nharness=claude\nsession=recorded-session\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "record-only identity bypassed the unchanged ancestry refusal"
  fi
  pass "session-lock identity: differing live sessions refuse and either missing identity uses only ancestry"
}

test_in_process_reidentification_keeps_its_owner_without_writing() {
  local dir fakebin before
  dir="$TMP_ROOT/identity-reset"
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
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Claude routes /clear and /compact through their own SessionStart, which
  # re-publishes an identity for the SAME live process. That owner must keep its
  # own lock rather than become its own competitor - and the predicate itself,
  # which fm-lock status, the Stop auto-arm, the Cursor guard, and the startup
  # sweep all call, must not rewrite the record on that weaker proof.
  printf '650\nharness=claude\nsession=before-reset\n' > "$dir/state/.lock"
  before=$(cat "$dir/state/.lock")
  FM_SESSION_HARNESS=claude FM_SESSION_ID=after-reset FM_SESSION_PUBLISHER_PID=650 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "an in-process re-identification locked the live owner out of its own lock"
  [ "$(cat "$dir/state/.lock")" = "$before" ] \
    || fail "the ancestry fallback rewrote the record from run membership alone"
  pass "session-lock identity: an in-process re-identification keeps its own lock without rewriting it"
}

# The nested cases share one process table: a session that owns the lock (800)
# runs an ordinary command (880) that launches a second session of the same
# harness (900). SHAPE=harness-gap puts a DIFFERENT verified harness in that gap,
# which must not hide the host.
nested_session_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
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
case "$pid:$field:${FM_TEST_NESTED_SHAPE:-plain}" in
  800:comm=:*) printf '%s\n' claude ;;
  800:args=:*) printf '%s\n' claude ;;
  800:ppid=:*) printf '%s\n' 1 ;;
  880:comm=:plain) printf '%s\n' bash ;;
  880:args=:plain) printf '%s\n' 'bash -c claude' ;;
  880:comm=:harness-gap) printf '%s\n' codex ;;
  880:args=:harness-gap) printf '%s\n' codex ;;
  880:ppid=:*) printf '%s\n' 800 ;;
  900:comm=:*) printf '%s\n' claude ;;
  900:args=:*) printf '%s\n' claude ;;
  900:ppid=:*) printf '%s\n' 880 ;;
  910:comm=:*) printf '%s\n' claude ;;
  910:args=:*) printf '%s\n' claude ;;
  910:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:*) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_inherited_identity_never_takes_the_hosting_sessions_lock() {
  local dir fakebin shape
  dir="$TMP_ROOT/identity-nested-inherited"
  fakebin=$(nested_session_fakebin "$dir")
  mkdir -p "$dir/state"

  # The nested session's own SessionStart bridge never ran, so it presents the
  # host's exported identity AND the host's publisher pid.
  for shape in plain harness-gap; do
    printf '800\nharness=claude\nsession=host-session\n' > "$dir/state/.lock"
    if FM_TEST_NESTED_SHAPE="$shape" FM_SESSION_HARNESS=claude FM_SESSION_ID=host-session \
      FM_SESSION_PUBLISHER_PID=800 \
      lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: a nested session took the lock using the identity it inherited from its host"
    fi
    [ "$(sed -n '1p' "$dir/state/.lock")" = 800 ] \
      || fail "$shape: a nested session refreshed the hosting session's recorded pid to itself"
    if FM_TEST_NESTED_SHAPE="$shape" FM_SESSION_HARNESS=claude FM_SESSION_ID=host-session \
      FM_SESSION_PUBLISHER_PID=800 \
      lib_eval "$fakebin" 'fm_current_session_identity claude'; then
      fail "$shape: an identity published by a hosting session was presented as this session's"
    fi
  done
  pass "session-lock identity: an identity inherited from a hosting session never owns its lock"
}

test_nested_session_with_its_own_bridge_keeps_full_identity() {
  local dir fakebin
  dir="$TMP_ROOT/identity-nested-own-bridge"
  fakebin=$(nested_session_fakebin "$dir")
  mkdir -p "$dir/state"

  # This nested session DID run its own SessionStart bridge, so it published its
  # own identity and its own publisher pid. Being hosted must not cost it the
  # reparenting fix: its own reparented record still refreshes to its live pid.
  printf '910\nharness=claude\nsession=nested-session\n' > "$dir/state/.lock"
  FM_SESSION_HARNESS=claude FM_SESSION_ID=nested-session FM_SESSION_PUBLISHER_PID=900 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "a nested session with its own bridge lost identity ownership of its own lock"
  [ "$(sed -n '1p' "$dir/state/.lock")" = 900 ] \
    || fail "a nested session with its own bridge did not refresh its reparented pid"
  [ "$(sed -n '3p' "$dir/state/.lock")" = session=nested-session ] \
    || fail "the reparent refresh lost the nested session's own identity"

  # It is still a competitor for a lock a different live session owns.
  printf '800\nharness=claude\nsession=host-session\n' > "$dir/state/.lock"
  if FM_SESSION_HARNESS=claude FM_SESSION_ID=nested-session FM_SESSION_PUBLISHER_PID=900 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a nested session with its own identity took a live host session's lock"
  fi
  [ "$(sed -n '1p' "$dir/state/.lock")" = 800 ] \
    || fail "a competing nested session rewrote the live host's recorded pid"
  pass "session-lock identity: a nested session that ran its own bridge keeps identity and still cannot compete"
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
test_structured_identity_owns_and_refreshes_after_reparenting
test_structured_identity_difference_preserves_competitor_and_missing_side_falls_back
test_in_process_reidentification_keeps_its_owner_without_writing
test_inherited_identity_never_takes_the_hosting_sessions_lock
test_nested_session_with_its_own_bridge_keeps_full_identity
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock

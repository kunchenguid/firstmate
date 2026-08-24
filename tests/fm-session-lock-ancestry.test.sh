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

test_omp_is_claude_identified_only_with_claudecode_marker() {
  local dir fakebin got
  dir="$TMP_ROOT/omp-marker"
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
  500:comm=) printf '%s\n' omp ;;
  500:args=) printf '%s\n' omp ;;
  500:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 500 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '500\n' > "$dir/state/.lock"

  # Positive: an omp process carrying the CLAUDECODE=1 marker is Claude-identified,
  # and the omp process's own pid is what the ancestry resolves to.
  got=$(CLAUDECODE=1 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "an omp process with CLAUDECODE=1 was not recognized as a harness process"
  [ "$got" = 500 ] || fail "ancestry resolved '$got', expected the omp process's own pid 500"
  CLAUDECODE=1 lib_eval "$fakebin" 'fm_harness_pid_alive 500' \
    || fail "a live omp process with CLAUDECODE=1 was not recognized as a harness"
  CLAUDECODE=1 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "an omp session with CLAUDECODE=1 did not recognize itself as the lock owner"

  # Negative: the identical omp-named process WITHOUT the marker must be rejected,
  # proving this is marker-gated rather than a bare name match. CLAUDECODE is
  # explicitly overridden to empty here rather than merely left unset, because
  # this suite may itself be running inside a Claude Code session that already
  # exports CLAUDECODE=1 into the ambient environment.
  if CLAUDECODE='' lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
    fail "an omp process without CLAUDECODE=1 was treated as a harness process"
  fi
  if CLAUDECODE='' lib_eval "$fakebin" 'fm_harness_pid_alive 500'; then
    fail "an omp process without CLAUDECODE=1 passed the harness-liveness predicate"
  fi
  if CLAUDECODE='' lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an omp process without CLAUDECODE=1 claimed the home's session lock"
  fi
  pass "session-lock: omp is Claude-identified for lock ownership only when CLAUDECODE=1 is set, never on bare name"
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

test_foreign_omp_pid_does_not_borrow_the_checkers_own_claudecode_marker() {
  local dir fakebin
  dir="$TMP_ROOT/foreign-omp"
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
  500:comm=) printf '%s\n' omp ;;
  500:args=) printf '%s\n' omp ;;
  500:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 500 is an omp process outside this ancestry entirely - this checking
  # process descends from the unrelated harness 650 instead. $CLAUDECODE=1
  # here describes THIS session's own backend, not pid 500's: trusting it
  # would let any Claude-marked checker treat an unrelated omp process (which
  # may not even be Claude-backed - omp is also the name of an unrelated
  # popular shell-prompt tool) as a live competing session forever, and
  # trusting its absence would let an unmarked checker declare a genuinely
  # live Claude-backed omp session stale and steal its lock.
  printf '500\n' > "$dir/state/.lock"
  if CLAUDECODE=1 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a foreign omp pid outside this ancestry was claimed as this session's own"
  fi
  if CLAUDECODE=1 lib_eval "$fakebin" 'fm_harness_pid_alive 500'; then
    fail "a foreign omp pid was classified as alive using the checker's own CLAUDECODE marker instead of its own"
  fi
  pass "session-lock: a foreign omp pid outside this ancestry is never classified as alive from the checker's own CLAUDECODE marker"
}

test_omp_ancestry_stops_at_omp_and_does_not_extend_into_a_claude_parent() {
  local dir fakebin got
  dir="$TMP_ROOT/omp-no-extend"
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
  500:comm=) printf '%s\n' omp ;;
  500:args=) printf '%s\n' omp ;;
  500:ppid=) printf '%s\n' 600 ;;
  600:comm=) printf '%s\n' claude ;;
  600:args=) printf '%s\n' claude ;;
  600:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 500 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # omp (pid 500) is directly parented by an unrelated claude-named launcher
  # (pid 600). omp's own comment states it has no nested worker chain to
  # climb the way native Claude Code does, so the walk must stop at 500 and
  # never report the launcher's pid - reporting 600 would make the lock look
  # held for as long as the launcher lives, even after omp itself exits.
  got=$(CLAUDECODE=1 lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "an omp session parented by a claude-named launcher was not recognized as a harness process"
  [ "$got" = 500 ] || fail "ancestry resolved '$got', expected omp to be its own session boundary at pid 500, not its claude-named parent"
  pass "session-lock: the ancestry walk stops at omp and never extends into a claude-named parent"
}

test_persisted_omp_claude_marker_lets_a_foreign_checker_see_a_live_omp_session() {
  local dir fakebin marker
  dir="$TMP_ROOT/omp-persisted-marker"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  marker="$dir/state/.lock.omp-claude"
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
  500:comm=) printf '%s\n' omp ;;
  500:args=) printf '%s\n' omp ;;
  500:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 500 is a genuinely live, CLAUDECODE-verified omp session in an
  # entirely different session tree - this checker descends from the
  # unrelated harness 650 instead, and carries no CLAUDECODE of its own. No
  # amount of local evidence can prove pid 500's own environment from here,
  # so fm-lock.sh must have persisted that verification when it wrote pid 500
  # into the lock; only that persisted record can make this checker trust it.
  printf '500\n' > "$dir/state/.lock"

  # fm_harness_record_omp_claude, called from the writer's own context where
  # CLAUDECODE=1 is sound evidence about pid 500, is what produces that record.
  CLAUDECODE=1 lib_eval "$fakebin" "fm_harness_record_omp_claude '$dir/state' 500"
  [ "$(cat "$marker" 2>/dev/null || true)" = 500 ] \
    || fail "fm_harness_record_omp_claude did not persist the verified omp pid"

  # Without the marker, this foreign checker correctly still cannot confirm
  # pid 500 - this is the pre-existing fail-closed behavior and must not
  # regress.
  rm -f "$marker"
  if lib_eval "$fakebin" "fm_harness_pid_alive 500 '$dir/state'"; then
    fail "a foreign omp pid was seen as alive with no persisted marker present"
  fi

  # With the persisted marker in place, this foreign checker now correctly
  # sees the live omp session as alive, without needing its own CLAUDECODE.
  printf '500\n' > "$marker"
  lib_eval "$fakebin" "fm_harness_pid_alive 500 '$dir/state'" \
    || fail "a live, marker-verified omp session held by a different session tree was classified as stale"

  # A marker naming a different pid than the one being checked - the
  # signature of a reused pid number after the verified session exited -
  # must never be trusted for this pid.
  printf '999\n' > "$marker"
  if lib_eval "$fakebin" "fm_harness_pid_alive 500 '$dir/state'"; then
    fail "a marker naming a different pid was accepted as evidence for pid 500"
  fi

  # fm_harness_record_omp_claude must also clear a stale marker when the pid
  # it is now given is not omp, so a later non-omp acquisition never leaves a
  # foreign checker trusting a leftover record for a reused pid number.
  printf '500\n' > "$marker"
  lib_eval "$fakebin" "fm_harness_record_omp_claude '$dir/state' 650"
  [ -e "$marker" ] && fail "fm_harness_record_omp_claude left a stale marker after a non-omp pid was recorded"

  pass "session-lock: a foreign checker trusts the lock writer's persisted omp+CLAUDECODE record, never its own ambient marker"
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

# A directory in place of the marker file makes fm_harness_record_omp_claude's
# write fail deterministically and cross-platform, without relying on chmod
# (which root - a common CI container user - ignores).
test_e2e_omp_marker_write_failure_fails_the_whole_acquisition() {
  local dir fakebin out rc lock_after
  dir="$TMP_ROOT/e2e-omp-marker-write-failure"
  mkdir -p "$dir/state"
  install_autoarm_scripts "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) printf '%s\n' omp ;;
  args=) printf '%s\n' omp ;;
  ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  mkdir -p "$dir/state/.lock.omp-claude"

  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" FM_HOME="$dir" "$dir/bin/fm-lock.sh" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "fm-lock.sh reported success despite a failed omp-identity marker write: $out"
  case "$out" in
    *"lock acquired"*) fail "fm-lock.sh printed lock-acquired despite a failed marker write: $out" ;;
  esac
  lock_after=$(cat "$dir/state/.lock" 2>/dev/null || true)
  [ -z "$lock_after" ] \
    || fail "the session lock was left claiming pid $lock_after with no persisted omp-identity marker for a foreign session to verify"
  pass "session-lock e2e: a failed omp-identity marker write fails the whole acquisition instead of leaving an unverifiable lock"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_omp_is_claude_identified_only_with_claudecode_marker
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_foreign_omp_pid_does_not_borrow_the_checkers_own_claudecode_marker
test_omp_ancestry_stops_at_omp_and_does_not_extend_into_a_claude_parent
test_persisted_omp_claude_marker_lets_a_foreign_checker_see_a_live_omp_session
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_omp_marker_write_failure_fails_the_whole_acquisition

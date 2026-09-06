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
printf '%s\n' "${FM_FIXTURE_LOCK_PID:-$$}" > "$FM_HOME/state/.lock"
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
      FM_FIXTURE_LOCK_PID="${FM_FIXTURE_LOCK_PID:-}" \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      FM_FIXTURE_LOCK_PID="${FM_FIXTURE_LOCK_PID:-}" \
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
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock

# --- owner-record layer: which harness process actually holds THIS home ------

# A process table where one live pid is an unrelated background daemon that
# merely carries a verified harness command name (the ChatGPT desktop app ships
# its Codex app-server exactly this way), a second live pid is this session's own
# harness, and everything else is an ordinary shell descending from that session.
#
# FM_PROC_ROOT_OVERRIDE is pointed at an empty directory by the callers so both
# platforms resolve process identity through this table instead of a real /proc.
write_owner_record_ps() {  # <fakebin> <foreign-pid> <session-pid>
  local fakebin=$1 foreign=$2 session=$3
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
fields= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) fields="\$fields \$2"; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
# FM_TEST_IDENTITY_BLIND names a pid whose identity cannot be read at all - a
# permission-denied /proc entry, a process exiting inside the race, a ps that
# answers nothing.
case "\$fields" in
  *lstart*) [ "\${FM_TEST_IDENTITY_BLIND:-}" != "\$pid" ] || exit 0 ;;
esac
foreign_path='/Applications/ChatGPT.app/Contents/Resources/codex'
case "\$pid" in
  $foreign)
    case "\$fields" in
      *lstart*) printf '%s\n' "\${FM_TEST_FOREIGN_START:-Mon Jan  1 00:00:00 2020} \$foreign_path app-server" ;;
      *comm*) printf '%s\n' "\$foreign_path" ;;
      *args*|*command*) printf '%s\n' "\$foreign_path app-server" ;;
      *ppid*) printf '%s\n' 1 ;;
    esac ;;
  $session)
    case "\$fields" in
      *lstart*) printf '%s\n' 'Tue Feb  2 00:00:00 2021 claude --resume' ;;
      *comm*) printf '%s\n' claude ;;
      *args*|*command*) printf '%s\n' 'claude --resume' ;;
      *ppid*) printf '%s\n' 1 ;;
    esac ;;
  *)
    case "\$fields" in
      *lstart*) printf '%s\n' 'Tue Feb  2 00:00:00 2021 bash' ;;
      *comm*) printf '%s\n' bash ;;
      *args*|*command*) printf '%s\n' 'bash bin/fm-lock.sh' ;;
      *ppid*) printf '%s\n' $session ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
}

# Start one real live process per fixture pid so kill -0 answers honestly, and
# reap them when the case ends. The pid is returned through a named variable
# rather than command substitution, whose subshell would wait on the background
# process's inherited stdout instead of returning.
OWNER_FIXTURE_PIDS=""
start_fixture_process() {  # <output-variable>
  sleep 300 >/dev/null 2>&1 &
  OWNER_FIXTURE_PIDS="$OWNER_FIXTURE_PIDS $!"
  printf -v "$1" '%s' "$!"
}
stop_fixture_processes() {
  local p
  for p in $OWNER_FIXTURE_PIDS; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  OWNER_FIXTURE_PIDS=""
}

# A bare pid with no owner record beside it is what a session that acquired its
# lock before owner records existed looks like while it is still running. That is
# missing evidence, not evidence that the process is unrelated, so it is held
# rather than evicted - the alternative puts two live sessions in one home.
test_legacy_bare_pid_lock_is_held_not_reclaimed() {
  local dir fakebin foreign session out reported status
  dir="$TMP_ROOT/legacy-bare-pid"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  write_owner_record_ps "$fakebin" "$foreign" "$session"
  printf '%s\n' "$foreign" > "$dir/state/.lock"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  # The status subcommand answers the same question and must be as actionable,
  # so read it while the holder is still the live process the refusal named.
  reported=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  stop_fixture_processes

  expect_code 1 "$status" "an unrecorded live lock owner was taken over anyway: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$foreign" ] \
    || fail "a second session took a lock it could not disprove: $(cat "$dir/state/.lock")"
  assert_absent "$dir/state/.lock-owner" "a refused session recorded itself as the owner"
  assert_contains "$out" "ChatGPT.app" \
    "the refusal did not name the real process an operator has to go find"
  assert_contains "$out" "cannot prove is dead" \
    "the refusal did not say why firstmate declines to take the home"
  assert_contains "$out" "quit that process" "the refusal did not offer the first way out"
  assert_contains "$out" "$dir/state/.lock" \
    "the refusal did not name the exact lock file to remove"
  assert_not_contains "$out" "reclaimed" "an untouched lock was reported as reclaimed"
  assert_not_contains "$out" "not a firstmate session" \
    "the refusal asserted something it cannot know about a live process"

  assert_contains "$reported" "ChatGPT.app" "status did not name the process holding the home"
  assert_contains "$reported" "cannot prove is dead" \
    "status did not say why firstmate declines to take the home"
  assert_contains "$reported" "quit that process" "status did not offer the first way out"
  assert_contains "$reported" "$dir/state/.lock" "status did not name the exact lock file to remove"
  pass "session-lock: a legacy bare-pid lock on a live harness is held, not reclaimed"
}

# The other half of the same rule: the session that WROTE that legacy lock must
# not be stranded by it, so its own next touch repairs the missing record in
# place instead of needing a fresh acquire cycle.
test_original_holder_repairs_its_own_missing_owner_record() {
  local dir fakebin foreign session out status
  dir="$TMP_ROOT/legacy-self-heal"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  write_owner_record_ps "$fakebin" "$foreign" "$session"
  printf '%s\n' "$session" > "$dir/state/.lock"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  expect_code 0 "$status" "the legacy lock's own holder was stranded by it: $out"
  assert_contains "$out" "lock acquired: harness pid $session" \
    "the original holder did not keep its own lock"

  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  stop_fixture_processes
  assert_contains "$out" "lock: held by live harness pid $session" \
    "the repaired record did not verify: $out"
  pass "session-lock: the original holder repairs its own missing owner record in place"
}

# Being unable to describe a process is a reason to be careful about taking a
# home away from someone, never a reason to refuse a session its own home: an
# unreadable identity still acquires and records what it can, because failing
# here would put the session read-only with nothing else holding the lock.
test_acquire_still_succeeds_when_identity_cannot_be_read() {
  local dir fakebin foreign session out status
  dir="$TMP_ROOT/identity-blind"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  write_owner_record_ps "$fakebin" "$foreign" "$session"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    FM_TEST_IDENTITY_BLIND="$session" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?

  expect_code 0 "$status" "an unreadable process identity refused a free home: $out"
  assert_contains "$out" "lock acquired: harness pid $session" \
    "the session did not get its own home"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session" ] \
    || fail "the lock was not published: $(cat "$dir/state/.lock")"

  # The record it could write still holds the home, but no comparison was ever
  # made against it, so the report says unconfirmed rather than claiming a match.
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  stop_fixture_processes
  assert_contains "$out" "lock: unconfirmed" \
    "a record no identity comparison ever touched was reported as confirmed: $out"
  assert_contains "$out" "$session" "the report did not name the pid holding the home"
  assert_not_contains "$out" "held by live harness pid" \
    "the report claimed a confirmation nobody made"
  pass "session-lock: an unreadable process identity still acquires and holds the home"
}

# A record naming some OTHER pid is stale data about a process that is not in
# the lock file, so it neither confirms nor disproves the pid that is. Reachable
# by rolling the checkout back to a version that writes state/.lock without a
# record and starting a session there, which leaves the record pointing at the
# older pid while a genuinely live session holds the lock.
test_owner_record_for_a_different_pid_is_not_evidence() {
  local dir fakebin foreign session out status
  dir="$TMP_ROOT/record-other-pid"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  write_owner_record_ps "$fakebin" "$foreign" "$session"
  FM_PROC_ROOT_OVERRIDE="$dir/noproc" PATH="$fakebin:$PATH" \
    fm_record_session_lock_owner "$dir/state" "$session"
  printf '%s\n' "$foreign" > "$dir/state/.lock"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  stop_fixture_processes

  expect_code 1 "$status" "a record about another pid was treated as proof about this one: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$foreign" ] \
    || fail "a live session was evicted on evidence about a different pid: $(cat "$dir/state/.lock")"
  assert_contains "$out" "cannot confirm is a firstmate session here" \
    "the refusal did not say why the holder could not be confirmed"
  assert_contains "$out" "ChatGPT.app" \
    "the refusal did not name the process an operator has to go find"
  assert_not_contains "$out" "reclaimed" "an untouched lock was reported as reclaimed"
  pass "session-lock: an owner record for a different pid never justifies a takeover"
}

# The record names this exact pid, but no identity comparison is possible, so
# nothing disproves the process holding the lock and it keeps the home - and
# nothing confirms it either, so the refusal must not claim a verified owner.
test_unreadable_recorded_identity_is_not_reclaimable() {
  local dir fakebin foreign session out status
  dir="$TMP_ROOT/blind-record"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  write_owner_record_ps "$fakebin" "$foreign" "$session"
  FM_TEST_IDENTITY_BLIND="$foreign" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" fm_record_session_lock_owner "$dir/state" "$foreign"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  stop_fixture_processes

  expect_code 1 "$status" "an owner that could not be compared was evicted anyway: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$foreign" ] \
    || fail "a live owner lost its home to an impossible comparison"
  assert_contains "$out" "cannot confirm is a firstmate session here" \
    "an owner nothing was compared against was reported as a confirmed live session"
  assert_contains "$out" "ChatGPT.app" "the refusal did not name the process holding the home"
  assert_contains "$out" "$dir/state/.lock" "the refusal did not name the lock file to remove"
  assert_not_contains "$out" "another live firstmate session" \
    "the refusal claimed a confirmation nobody made"
  assert_not_contains "$out" "reclaimed" "an untouched lock was reported as reclaimed"
  pass "session-lock: an owner whose recorded identity cannot be compared keeps the home"
}

# The other side of the invariant: a lock pid that is alive but is NOT a verified
# harness process is proof of absence, and must still be reclaimed.
test_live_non_harness_pid_is_still_reclaimed() {
  local dir fakebin foreign session stale out status
  dir="$TMP_ROOT/live-non-harness"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  start_fixture_process stale
  write_owner_record_ps "$fakebin" "$foreign" "$session"
  printf '%s\n' "$stale" > "$dir/state/.lock"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  stop_fixture_processes

  expect_code 0 "$status" "a live pid that is not a harness kept the home: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session" ] \
    || fail "the lock was not reclaimed from a non-harness pid: $(cat "$dir/state/.lock")"
  pass "session-lock: a live pid that is not a verified harness is still reclaimed"
}

test_owner_record_still_refuses_a_genuine_second_session() {
  local dir fakebin foreign session out status
  dir="$TMP_ROOT/genuine-second"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  write_owner_record_ps "$fakebin" "$foreign" "$session"
  # The competing pid is recorded as this home's owner exactly as its own
  # acquire would have recorded it, so it IS a live firstmate session here.
  FM_PROC_ROOT_OVERRIDE="$dir/noproc" PATH="$fakebin:$PATH" \
    fm_record_session_lock_owner "$dir/state" "$foreign"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  stop_fixture_processes

  expect_code 1 "$status" "a genuine second live session in this home was not refused: $out"
  assert_contains "$out" "another live firstmate session holds the lock" \
    "the refusal lost its established wording"
  assert_contains "$out" "$foreign" "the refusal did not name the holding pid"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$foreign" ] \
    || fail "a refused session rewrote the live owner's lock"
  pass "session-lock: a genuine second live session in the same home is still refused"
}

test_recycled_pid_never_inherits_the_previous_owners_lock() {
  local dir fakebin foreign session out status
  dir="$TMP_ROOT/recycled-pid"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/noproc"
  start_fixture_process foreign
  start_fixture_process session
  write_owner_record_ps "$fakebin" "$foreign" "$session"
  # Record the owner while that pid still belongs to the session that acquired
  # the lock, then let the pid come back as a different process - the reboot
  # case, where no harness-named app is involved at all.
  FM_TEST_FOREIGN_START='Sun Dec 31 23:00:00 2019' FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" fm_record_session_lock_owner "$dir/state" "$foreign"

  status=0
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" FM_PROC_ROOT_OVERRIDE="$dir/noproc" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1) || status=$?
  stop_fixture_processes

  expect_code 0 "$status" "a recycled pid kept holding a dead session's lock: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session" ] \
    || fail "the lock was not reclaimed from the recycled pid: $(cat "$dir/state/.lock")"
  assert_contains "$out" "$foreign" "the reclaim did not name the recycled pid"
  assert_contains "$out" "ChatGPT.app" \
    "the reclaim did not name the real process an operator has to go find"
  pass "session-lock: a recycled pid does not inherit the previous owner's lock"
}

test_legacy_bare_pid_lock_is_held_not_reclaimed
test_original_holder_repairs_its_own_missing_owner_record
test_acquire_still_succeeds_when_identity_cannot_be_read
test_owner_record_for_a_different_pid_is_not_evidence
test_unreadable_recorded_identity_is_not_reclaimable
test_live_non_harness_pid_is_still_reclaimed
test_owner_record_still_refuses_a_genuine_second_session
test_recycled_pid_never_inherits_the_previous_owners_lock

# The Stop auto-arm reads the same ownership decision, so the reported lockout
# reaches supervision continuity too: a home whose lock names an unrelated
# harness-named process would keep every hook firing inert forever. These run the
# REAL hook against a REAL unrelated process with no fake process table at all.
start_unrelated_harness_process() {  # <output-variable>
  "$NAMED_CLAUDE" -c 'sleep 60; :' >/dev/null 2>&1 &
  OWNER_FIXTURE_PIDS="$OWNER_FIXTURE_PIDS $!"
  printf -v "$1" '%s' "$!"
}

# state/.lock-owner is this code's own persisted record, so a fixture may age it
# deliberately: the pid still matches, but the record no longer pins the process
# now at it - exactly what a reboot's pid reuse leaves behind.
age_recorded_identity() {  # <state>
  local state=$1
  sed 's/^identity=.*/identity=aged-fixture-identity/' "$state/.lock-owner" \
    > "$state/.lock-owner.aged"
  mv -f "$state/.lock-owner.aged" "$state/.lock-owner"
}

test_e2e_unrelated_harness_process_does_not_freeze_supervision() {
  local dir foreign
  dir="$TMP_ROOT/e2e-unrelated-holder"
  make_primary_home "$dir"
  start_unrelated_harness_process foreign
  fm_record_session_lock_owner "$dir/state" "$foreign"
  age_recorded_identity "$dir/state"
  FM_FIXTURE_LOCK_PID="$foreign" run_fixture_tree "$dir" "$NAMED_CLAUDE"
  stop_fixture_processes

  expect_code 2 "$(hook_rc "$dir")" \
    "an unrelated harness-named process holding the lock left supervision inert"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed once the unowned lock was reclaimed"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the hook did not reclaim the home from the unrelated process"
  pass "session-lock e2e: an unrelated harness-named lock holder does not freeze supervision"
}

test_e2e_legacy_bare_pid_lock_keeps_a_competing_hook_inert() {
  local dir foreign
  dir="$TMP_ROOT/e2e-legacy-holder"
  make_primary_home "$dir"
  start_unrelated_harness_process foreign
  # No owner record at all: a session that took this lock before owner records
  # existed looks exactly like this while it is still running.
  FM_FIXTURE_LOCK_PID="$foreign" run_fixture_tree "$dir" "$NAMED_CLAUDE"
  stop_fixture_processes

  expect_code 0 "$(hook_rc "$dir")" \
    "a competing hook did not stand down for a live owner it could not disprove"
  assert_absent "$dir/state/arm-ran" \
    "a competing session armed supervision over a live unrecorded owner"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$foreign" ] \
    || fail "a competing session took a lock it could not disprove"
  pass "session-lock e2e: a legacy bare-pid lock keeps a competing session's hook inert"
}

test_e2e_verified_live_owner_still_keeps_a_competing_hook_inert() {
  local dir foreign
  dir="$TMP_ROOT/e2e-verified-holder"
  make_primary_home "$dir"
  start_unrelated_harness_process foreign
  # Same process, but now recorded as this home's owner exactly as its own
  # acquire would have recorded it: a real competing session, still untouchable.
  fm_record_session_lock_owner "$dir/state" "$foreign"
  FM_FIXTURE_LOCK_PID="$foreign" run_fixture_tree "$dir" "$NAMED_CLAUDE"

  expect_code 0 "$(hook_rc "$dir")" "a competing hook did not stand down for a verified live owner"
  assert_absent "$dir/state/arm-ran" "a competing session armed supervision over a verified live owner"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$foreign" ] \
    || fail "a competing session took the lock from a verified live owner"
  stop_fixture_processes
  pass "session-lock e2e: a verified live owner still keeps a competing session's hook inert"
}

test_e2e_unrelated_harness_process_does_not_freeze_supervision
test_e2e_legacy_bare_pid_lock_keeps_a_competing_hook_inert
test_e2e_verified_live_owner_still_keeps_a_competing_hook_inert

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
# Keep a command after each fm-lock.sh invocation below so Bash cannot replace
# this synthetic harness process with the lock script before ancestry inspection.

LOCK_FIXTURE_PIDS=()
cleanup_lock_fixture_processes() {
  local pid
  for pid in "${LOCK_FIXTURE_PIDS[@]:-}"; do
    kill -CONT "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_lock_fixture_processes EXIT
trap 'cleanup_lock_fixture_processes; exit 130' INT
trap 'cleanup_lock_fixture_processes; exit 143' TERM

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c '
    . "$1"
    kill() {
      case "${FM_TEST_KILL_PROBE:-alive}" in
        missing) printf "%s\n" "kill: ($2) - No such process" >&2; return 1 ;;
        denied) printf "%s\n" "kill: ($2) - Operation not permitted" >&2; return 1 ;;
        *) return 0 ;;
      esac
    }
    fm_pid_identity() { printf "fixture-identity-%s\n" "$1"; }
    eval "$2"
  ' _ "$LIB" "$expr"
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
  700:stat=:linux) printf '%s\n' 'S' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:stat=:macos) printf '%s\n' 'S' ;;
  700:pgid=:*) printf '%s\n' 700 ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"
  printf '700\nfixture-identity-700\n700\nfixture-identity-700\n' > "$dir/state/.lock.pid-identity"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  rm -f "$dir/state/.lock.pid-identity"
  FM_TEST_CLAUDE_SHAPE=linux lib_eval "$fakebin" "fm_session_lock_pid_owned_by_self '$dir/state'" \
    || fail "a legacy lock no longer retained its numeric current-session membership"
  if FM_TEST_CLAUDE_SHAPE=linux lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a legacy numeric-only lock was accepted as durable current-session ownership"
  fi
  printf '700\nwrong-identity\n' > "$dir/state/.lock.pid-identity"
  if FM_TEST_CLAUDE_SHAPE=linux lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a mismatched birth identity was accepted as current-session ownership"
  fi
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
  810:stat=:*) printf '%s\n' 'S' ;;
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
  900:stat=) printf '%s\n' S ;;
  900:pgid=) printf '%s\n' 900 ;;
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
  printf '900\nfixture-identity-900\n900\nfixture-identity-900\n' > "$dir/state/.lock.pid-identity"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_legacy_dead_group_leader_with_a_surviving_child_stays_read_only() {
  local dir owner_bin owner child owner_pgid child_pgid monitor_was_on i out status
  dir="$TMP_ROOT/legacy-surviving-group"
  owner_bin="$dir/owner-bin"
  mkdir -p "$dir/home/state" "$owner_bin"
  ln -s /bin/bash "$owner_bin/claude"

  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  "$owner_bin/claude" -c 'trap "" HUP; sleep 60 & printf "%s\n" "$!" > "$1"; wait' _ "$dir/child-pid" &
  owner=$!
  [ "$monitor_was_on" -eq 1 ] || set +m
  LOCK_FIXTURE_PIDS+=("$owner")
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/child-pid" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$dir/child-pid" ] || fail "synthetic legacy owner did not start its child"
  child=$(cat "$dir/child-pid")
  LOCK_FIXTURE_PIDS+=("$child")
  owner_pgid=$(ps -o pgid= -p "$owner" 2>/dev/null | tr -d '[:space:]')
  child_pgid=$(ps -o pgid= -p "$child" 2>/dev/null | tr -d '[:space:]')
  [ "$owner_pgid" = "$owner" ] && [ "$child_pgid" = "$owner" ] \
    || fail "synthetic legacy owner and child did not share a leader-owned process group"

  kill -KILL "$owner"
  wait "$owner" 2>/dev/null || true
  kill -0 "$child" 2>/dev/null || fail "synthetic child did not survive its group leader"
  printf '%s\n' "$owner" > "$dir/home/state/.lock"
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$NAMED_CLAUDE" -c \
    '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; exit $?' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a legacy dead group leader with surviving execution must stay read-only"
  assert_contains "$out" "prior session execution could not be safely excluded" \
    "legacy surviving execution was not reported as the takeover blocker"
  [ "$(cat "$dir/home/state/.lock")" = "$owner" ] \
    || fail "legacy surviving execution allowed lock replacement"
  kill -0 "$child" 2>/dev/null || fail "the non-destructive legacy check signaled the surviving child"

  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  LOCK_FIXTURE_PIDS=()
  pass "session-lock: legacy dead leaders cannot hide surviving process-group execution"
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
  600:stat=) printf '%s\n' 'S' ;;
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

test_supported_process_state_surfaces_are_classified() {
  local dir fakebin process_state status
  dir="$TMP_ROOT/process-states"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) printf '%s\n' claude ;;
  args=) printf '%s\n' 'claude --resume fixture' ;;
  stat=)
    [ "$FM_TEST_OWNER_STATE" != error ] || exit 1
    printf '%s\n' "$FM_TEST_OWNER_STATE"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  # Linux reports D/I/R/S/W as active and T/t/X/Z as stopped or terminal.
  # macOS reports I/R/S/U as active and T/Z as stopped or terminal.
  for process_state in D I R+ S U W; do
    FM_TEST_OWNER_STATE="$process_state" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      && status=0 || status=$?
    expect_code 0 "$status" "active ps state $process_state must retain a live harness owner's lock"
  done
  for process_state in T t; do
    FM_TEST_OWNER_STATE="$process_state" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      && status=0 || status=$?
    expect_code 3 "$status" "stopped ps state $process_state must require fenced recovery"
  done
  for process_state in X Z; do
    FM_TEST_OWNER_STATE="$process_state" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      && status=0 || status=$?
    expect_code 1 "$status" "terminal ps state $process_state must reject harness ownership"
  done
  for process_state in error Q; do
    FM_TEST_OWNER_STATE="$process_state" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      && status=0 || status=$?
    expect_code 2 "$status" "unreadable or unrecognized ps state $process_state must stay unknown"
  done
  FM_TEST_OWNER_STATE=S FM_TEST_KILL_PROBE=missing lib_eval "$fakebin" \
    'fm_harness_pid_alive 700' && status=0 || status=$?
  expect_code 1 "$status" "a no-such-process probe must classify the owner as absent"
  FM_TEST_OWNER_STATE=S FM_TEST_KILL_PROBE=denied lib_eval "$fakebin" \
    'fm_harness_pid_alive 700' && status=0 || status=$?
  expect_code 2 "$status" "a permission-denied process probe must stay unknown"

  pass "session-lock: process probes and Linux and macOS states distinguish absent, active, stopped, terminal, and unknown owners"
}

test_real_lock_interface_classifies_owner_process_state() {
  local dir fakebin identity_fakebin leader_bin owner_bin sleep_owner leader owner owner_pgid leader_pgid monitor_was_on i state leader_state out status owner_after identity
  dir="$TMP_ROOT/owner-process-state"
  fakebin=$(fm_fakebin "$dir")
  leader_bin="$dir/leader-bin/pi-signed"
  owner_bin="$dir/owner-bin/pi"
  sleep_owner="$dir/sleep-owner/claude"
  mkdir -p "$dir/home/state" "${leader_bin%/*}" "${owner_bin%/*}" "${sleep_owner%/*}"
  ln -s /bin/bash "$leader_bin"
  ln -s /bin/sleep "$owner_bin"
  ln -s /bin/sleep "$sleep_owner"

  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  "$leader_bin" -c '"$1" 60 & printf "%s\n" "$!" > "$2"; wait' _ "$owner_bin" "$dir/owner-pid" &
  leader=$!
  [ "$monitor_was_on" -eq 1 ] || set +m
  LOCK_FIXTURE_PIDS+=("$leader")
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$dir/owner-pid" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$dir/owner-pid" ] || fail "synthetic group leader did not start its harness owner"
  owner=$(cat "$dir/owner-pid")
  LOCK_FIXTURE_PIDS+=("$owner")
  owner_pgid=$(ps -o pgid= -p "$owner" 2>/dev/null | tr -d '[:space:]')
  leader_pgid=$(ps -o pgid= -p "$leader" 2>/dev/null | tr -d '[:space:]')
  [ "$leader_pgid" = "$leader" ] && [ "$owner_pgid" = "$leader" ] && [ "$owner" != "$leader" ] \
    || fail "synthetic non-leader owner did not share its harness leader's process group: leader=$leader leader_pgid=$leader_pgid owner=$owner owner_pgid=$owner_pgid"
  printf '%s\n' "$owner" > "$dir/home/state/.lock"

  state=$(ps -o stat= -p "$owner" 2>/dev/null || true)
  case "$state" in
    [RSDIWU]*) : ;;
    *) fail "synthetic live harness owner did not reach an active process state: pid=$owner state=$state" ;;
  esac

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$NAMED_CLAUDE" -c \
    '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; exit $?' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a competing active harness owner must retain the session lock"
  assert_contains "$out" "another live firstmate session holds the lock" \
    "active-owner refusal must identify live contention"
  [ "$(cat "$dir/home/state/.lock")" = "$owner" ] \
    || fail "active-owner refusal replaced the competing harness lock"

  kill -STOP -"$leader"
  i=0
  state=
  while [ "$i" -lt 100 ]; do
    state=$(ps -o stat= -p "$owner" 2>/dev/null || true)
    case "$state" in [Tt]*) break ;; esac
    sleep 0.02
    i=$((i + 1))
  done
  case "$state" in
    [Tt]*) : ;;
    *) fail "synthetic harness owner did not enter a stopped state: pid=$owner state=$state" ;;
  esac
  leader_state=$(ps -o stat= -p "$leader" 2>/dev/null || true)
  case "$leader_state" in
    [Tt]*) ;;
    *) fail "synthetic harness group leader did not enter a stopped state: pid=$leader state=$leader_state" ;;
  esac

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: stopped" "status must disclose a stopped harness owner"
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$NAMED_CLAUDE" -c \
    '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; exit $?' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a legacy stopped-owner lock without completion proof must stay read-only"
  assert_contains "$out" "lacks corroborating completion proof" \
    "missing legacy completion proof was not reported as the takeover blocker"
  [ "$(cat "$dir/home/state/.lock")" = "$owner" ] \
    || fail "missing completion proof allowed stopped-owner lock replacement"

  kill -CONT -"$leader"
  i=0
  state=
  while [ "$i" -lt 100 ]; do
    state=$(ps -o stat= -p "$owner" 2>/dev/null || true)
    case "$state" in [Tt]*) ;; *) break ;; esac
    sleep 0.02
    i=$((i + 1))
  done
  sleep 1.1
  printf '%s\n' "$owner" > "$dir/home/state/.session-start-complete"
  kill -STOP -"$leader"
  i=0
  while [ "$i" -lt 100 ]; do
    state=$(ps -o stat= -p "$owner" 2>/dev/null || true)
    case "$state" in [Tt]*) break ;; esac
    sleep 0.02
    i=$((i + 1))
  done
  case "$state" in [Tt]*) ;; *) fail "synthetic harness owner did not stop after legacy completion" ;; esac

  printf '%s\n%s\n' "$owner" mismatch > "$dir/home/state/.lock.pid-identity"
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$NAMED_CLAUDE" -c \
    '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; exit $?' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "a mismatched stopped-owner birth identity must stay read-only"
  [ "$(cat "$dir/home/state/.lock")" = "$owner" ] \
    || fail "mismatched owner identity allowed stopped-owner lock replacement"

  identity=$(FM_STATE_OVERRIDE="$dir/home/state" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$owner") \
    || fail "could not capture the synthetic owner identity"
  printf '%s\n%s\n' "$owner" "$identity" > "$dir/home/state/.lock.pid-identity"
  identity_fakebin=$(fm_fakebin "$dir/identity-unreadable")
  cat > "$identity_fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid= previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
if [ "$pid" = "$FM_TEST_UNREADABLE_PID" ]; then
  case "$*" in *"lstart="*) exit 1 ;; esac
fi
exec /bin/ps "$@"
SH
  chmod +x "$identity_fakebin/ps"
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_PROC_ROOT_OVERRIDE="$dir/no-proc" \
    FM_TEST_UNREADABLE_PID="$owner" PATH="$identity_fakebin:$PATH" "$NAMED_CLAUDE" -c \
    '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; exit $?' 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "an unclassifiable stopped-owner birth identity must stay read-only"
  [ "$(cat "$dir/home/state/.lock")" = "$owner" ] \
    || fail "unclassifiable owner identity allowed stopped-owner lock replacement"

  rm -f "$dir/home/state/.lock.pid-identity"
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$NAMED_CLAUDE" -c \
    '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; exit $?' 2>&1) && status=0 || status=$?
  wait "$leader" 2>/dev/null || true
  expect_code 0 "$status" "a challenger must reclaim a legacy lock from a stopped non-leader harness owner"
  assert_contains "$out" "lock acquired: harness pid" \
    "stopped-owner reclamation must complete through the real lock interface"
  owner_after=$(cat "$dir/home/state/.lock")
  [ "$owner_after" != "$owner" ] || fail "stopped harness owner retained the session lock"
  [ "$(sed -n '1p' "$dir/home/state/.lock.pid-identity")" = "$owner_after" ] \
    || fail "replacement lock did not publish its PID-bound birth identity"
  [ "$(wc -l < "$dir/home/state/.lock.pid-identity" | tr -d '[:space:]')" = 4 ] \
    || fail "replacement lock did not publish a fixed owner-and-group lease"
  state=$(ps -o stat= -p "$owner" 2>/dev/null || true)
  case "$state" in
    ''|[XZ]*) ;;
    *) fail "a fenced former owner remained resumable after lock takeover: pid=$owner state=$state" ;;
  esac
  leader_state=$(ps -o stat= -p "$leader" 2>/dev/null || true)
  case "$leader_state" in
    ''|[XZ]*) ;;
    *) fail "the stopped owner's group leader survived process-group fencing: pid=$leader state=$leader_state" ;;
  esac
  LOCK_FIXTURE_PIDS=()

  "$sleep_owner" 60 &
  owner=$!
  LOCK_FIXTURE_PIDS+=("$owner")
  printf '%s\n' "$owner" > "$dir/home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$pid" = "$FM_TEST_UNREADABLE_PID" ] && [ "$field" = "stat=" ]; then
  exit 1
fi
exec /bin/ps "${args[@]}"
SH
  chmod +x "$fakebin/ps"

  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_UNREADABLE_PID="$owner" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: unknown" \
    "status must disclose an owner whose process state cannot be classified"
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_UNREADABLE_PID="$owner" \
    PATH="$fakebin:$PATH" "$NAMED_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-lock.sh"; exit $?' 2>&1) \
    && status=0 || status=$?
  expect_code 1 "$status" "an unreadable owner process state must fail closed"
  assert_contains "$out" "cannot classify session lock owner process" \
    "unknown-owner refusal must explain why acquisition stays read-only"
  [ "$(cat "$dir/home/state/.lock")" = "$owner" ] \
    || fail "unknown-owner refusal replaced the unclassifiable lock owner"

  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  LOCK_FIXTURE_PIDS=()

  pass "session-lock: real acquisition excludes active owners, fences stopped owners, and fails closed on unknown state"
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
test_supported_process_state_surfaces_are_classified
test_legacy_dead_group_leader_with_a_surviving_child_stays_read_only
test_real_lock_interface_classifies_owner_process_state
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock

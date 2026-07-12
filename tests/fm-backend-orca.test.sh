#!/usr/bin/env bash
# tests/fm-backend-orca.test.sh - daemon-direct unit tests for the orca
# terminal adapter in bin/backends/orca.sh.
#
# The adapter now talks to the orca daemon through bin/fmod (a small
# firstmate-owned Python client), not through the orca CLI. These tests
# fake fmod on PATH with a logging stub so we can verify the adapter
# issues the right daemon RPCs without touching the real daemon or the
# real git worktree machinery. A few tests that need a real worktree use
# fm_test_git_init to make a tiny throwaway repo; everything else stays
# in fakebin/PATH-shim land.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-tests)

# make_fmod_fakebin: writes a fmod stub that logs every invocation with US
# separators between args, returns canned stdout from $RESP/$N.out, and
# optional exit from $RESP/$N.exit. The subcommand `info` and `ping` are
# stateful response generators (the test controls them via env vars) so
# the suite can flip readiness without writing per-call response files.
make_fmod_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fmod" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FMOD_FAKE_LOG:?}"
RESP="${FMOD_FAKE_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$next" > "$COUNT_FILE"
{
  printf 'fmod'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
case "${1:-}" in
  info)
    if [ "${FMOD_FAKE_INFO:-ready}" = ready ]; then
      printf '{"socket_exists":true,"token_exists":true,"daemon_reachable":true,"daemon_pong":{"pong":true}}\n'
    else
      printf '{"socket_exists":true,"token_exists":true,"daemon_reachable":false,"daemon_error":"unreachable"}\n'
    fi
    exit 0
    ;;
  ping)
    printf '{"pong":true}\n'
    exit 0
    ;;
  list)
    [ -f "$RESP/$next.exit" ] && exit "$(cat "$RESP/$next.exit")"
    cat "$RESP/$next.out" 2>/dev/null || printf '[]\n'
    exit 0
    ;;
  create)
    [ -f "$RESP/$next.exit" ] && exit "$(cat "$RESP/$next.exit")"
    cat "$RESP/$next.out" 2>/dev/null || printf '{"isNew":true,"pid":12345,"shellState":"ready"}\n'
    exit 0
    ;;
  snapshot|get-cwd|get-foreground)
    [ -f "$RESP/$next.exit" ] && exit "$(cat "$RESP/$next.exit")"
    cat "$RESP/$next.out" 2>/dev/null
    exit 0
    ;;
  write|resize)
    exit 0
    ;;
  kill)
    [ -f "$RESP/$next.exit" ] && exit "$(cat "$RESP/$next.exit")"
    exit 0
    ;;
esac
[ -f "$RESP/$next.exit" ] && exit "$(cat "$RESP/$next.exit")"
[ -f "$RESP/$next.out" ] && cat "$RESP/$next.out"
exit 0
SH
  chmod +x "$fb/fmod"
  printf '%s\n' "$fb"
}

fmod_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  rm -f "$RESP/.count"
  FB=$(make_fmod_fakebin "$CASE_DIR")
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local dir=$1 root="$1/root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

# adapter_env: print the env assignments a test needs to source the adapter
# and have its fmod calls hit the fake. Use like:
#   eval "$(adapter_env)"
#   bash -c '. "$ROOT/bin/backends/orca.sh"; ...'
adapter_env() {
  printf 'FMOD_FAKE_LOG=%q FMOD_FAKE_RESPONSES=%q PATH=%q:$PATH ROOT=%q' \
    "$LOG" "$RESP" "$FB" "$ROOT"
}

# ---- runtime check --------------------------------------------------------

test_runtime_check_accepts_ready_daemon() {
  fmod_case runtime-ready
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" FMOD_FAKE_INFO=ready \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" )
  [ -z "$out" ] || fail "runtime_check should be quiet on a ready daemon, got '$out'"
  assert_contains "$(cat "$LOG")" $'fmod\x1f''info' \
    "runtime_check did not call fmod info"
  pass "fm_backend_orca_runtime_check: accepts a daemon whose fmod info says reachable"
}

test_runtime_check_refuses_unready_daemon() {
  fmod_case runtime-unready
  local out status
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" FMOD_FAKE_INFO=down \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should fail when fmod info says unreachable, got rc=$status"
  assert_contains "$out" "not reachable" "runtime_check should explain the readiness failure"
  pass "fm_backend_orca_runtime_check: fails closed when fmod info says daemon unreachable"
}

# ---- capture --------------------------------------------------------------

test_capture_calls_fmod_snapshot_with_strip_and_lines() {
  fmod_case capture-strip
  printf 'jd@torre:/tmp$ echo hi\nhi\n' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture fm-x 25' "$ROOT" )
  [ "$out" = "$(cat "$RESP/1.out")" ] || fail "capture should print the fmod snapshot verbatim, got '$out'"
  assert_contains "$(cat "$LOG")" $'fmod\x1f''snapshot'$'\x1f''fm-x'$'\x1f''--strip-ansi'$'\x1f''--lines'$'\x1f''25' \
    "capture did not call fmod snapshot with --strip-ansi --lines"
  pass "fm_backend_orca_capture: delegates to fmod snapshot --strip-ansi --lines N"
}

test_capture_surfaces_daemon_error() {
  fmod_case capture-error
  # Force the fake to fail on its first call (capture invokes fmod once).
  echo "3" > "$RESP/1.exit"
  local status
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture fm-y 5' "$ROOT" >/dev/null 2>"$CASE_DIR/err"
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when fmod exits non-zero (rc=$status); stderr: $(cat "$CASE_DIR/err")"
  pass "fm_backend_orca_capture: fails closed when fmod exits non-zero (rc=$status)"
}

# ---- send helpers ---------------------------------------------------------

test_send_text_line_appends_real_newline() {
  fmod_case send-line
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_line fm-x "echo hi"' "$ROOT"
  local log_text
  log_text=$(cat "$LOG")
  # Must be a real LF (0x0a), not the literal two-char sequence `\n`.
  if ! printf '%s' "$log_text" | grep -q $'fmod\x1fwrite\x1ffm-x\x1f--data\x1fecho hi\n'; then
    fail "send_text_line should write text + LF; log was: $(cat "$LOG")"
  fi
  if printf '%s' "$log_text" | grep -q $'fmod\x1fwrite\x1ffm-x\x1f--data\x1fecho hi\\n'; then
    fail "send_text_line must not send the literal backslash-n sequence"
  fi
  pass "fm_backend_orca_send_text_line: writes a real LF, not a literal \\n"
}

test_send_literal_writes_text_without_newline() {
  fmod_case send-literal
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal fm-x "abc"' "$ROOT"
  python3 - "$LOG" <<'PY' || fail "send_literal wrote the wrong bytes"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
# The fake's log line is <args>\n. If send_literal wrote "abc", the data
# field is "abc" and the line ends with exactly one \n. If it wrote
# "abc\n", we'd see two \n at the line tail (data LF + log LF).
write_lines = [l for l in log.splitlines() if l.startswith(b"fmod" + US + b"write")]
assert len(write_lines) == 1, f"expected exactly one write call, got: {write_lines}"
line = write_lines[0]
assert line.endswith(b"--data" + US + b"abc"), f"unexpected line tail: {line!r}"
# Distinguish "abc\n" (data LF appended) from "abc" (clean). Strip the log
# line terminator (which the OS-level splitlines already removed) and check
# the data field is exactly b"abc".
data_field = line.split(US)[-1]
assert data_field == b"abc", f"data field should be exactly 'abc', got {data_field!r}"
PY
  pass "fm_backend_orca_send_literal: writes text without a trailing newline"
}

test_send_key_enter_writes_lf() {
  fmod_case send-key-enter
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key fm-x Enter' "$ROOT"
  python3 - "$LOG" <<'PY' || fail "send_key Enter should send a single LF byte"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
expected = b"fmod" + US + b"write" + US + b"fm-x" + US + b"--data" + US + b"\n"
assert expected in log, f"missing expected write call; log bytes: {log!r}"
PY
  pass "fm_backend_orca_send_key: Enter sends a single LF byte"
}

test_send_key_ctrl_c_writes_etx() {
  fmod_case send-key-ctrl-c
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key fm-x C-c' "$ROOT"
  python3 - "$LOG" <<'PY' || fail "send_key C-c should send --data with a single ETX byte"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
expected = b"fmod" + US + b"write" + US + b"fm-x" + US + b"--data" + US + b"\x03"
assert expected in log, f"missing expected write call; log bytes: {log!r}"
PY
  pass "fm_backend_orca_send_key: C-c sends a single ETX byte"
}

test_send_key_refuses_unknown() {
  fmod_case send-key-unknown
  local out status
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key fm-x F12' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse unknown keys"
  assert_contains "$out" "F12" "send_key should mention the rejected key"
  pass "fm_backend_orca_send_key: refuses unsupported keys"
}

# ---- kill / current-path --------------------------------------------------

test_kill_calls_fmod_kill() {
  fmod_case kill
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill fm-x' "$ROOT"
  assert_contains "$(cat "$LOG")" $'fmod\x1f''kill'$'\x1f''fm-x' \
    "kill should call fmod kill with the terminal id"
  pass "fm_backend_orca_kill: delegates to fmod kill"
}

test_current_path_calls_fmod_get_cwd() {
  fmod_case current-path
  printf '/home/jd/Desktop/falkordb-stak\n' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_current_path fm-x' "$ROOT" )
  [ "$out" = "/home/jd/Desktop/falkordb-stak" ] || fail "current_path should print the fmod get-cwd result, got '$out'"
  pass "fm_backend_orca_current_path: delegates to fmod get-cwd"
}

# ---- worktree create / remove (real git, fake fmod) ----------------------

# build_test_repo: make a small throwaway git repo with one commit. The
# repo is initialised with -b main so we always have a default branch, and
# identity is set so the seeded commit does not bail on missing user info.
build_test_repo() {  # <dir> <name> -> echoes repo path
  local dir=$1 name=$2 repo="$1/$2"
  git -C "$dir" init -q -b main "$name" 2>/dev/null
  git -C "$repo" -c user.name=test -c user.email=t@t.local commit -q --allow-empty -m init 2>/dev/null
  printf '%s\n' "$repo"
}

expected_orca_wt() {  # <repo> <name>
  local repo=$1 name=$2 parent project_name home_guess
  parent=$(dirname "$repo")
  project_name=$(basename "$repo")
  if [ "$(basename "$parent")" = projects ]; then
    home_guess=$(dirname "$parent")
  else
    home_guess=$parent
  fi
  printf '%s/state/orca-worktrees/%s/%s' "$home_guess" "$project_name" "$name"
}

test_worktree_create_makes_git_worktree_and_fmod_session() {
  fmod_case wt-create-happy
  local repo expected_wt
  repo=$(build_test_repo "$CASE_DIR" repo)
  expected_wt=$(expected_orca_wt "$repo" fm-test1)
  printf '%s\n' "$expected_wt" > "$RESP/2.out"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test1' "$ROOT" "$repo" > "$CASE_DIR/raw"
  local raw
  raw=$(cat "$CASE_DIR/raw")
  local wt_id wt_path terminal
  wt_id=${raw%%	*}
  rest=${raw#*	}
  wt_path=${rest%%	*}
  terminal=${rest#*	}
  [ -d "$wt_path" ] || fail "worktree path $wt_path was not created"
  [ "$wt_id" = "$wt_path" ] || fail "wt_id should equal wt_path under the daemon-direct adapter, got id=$wt_id path=$wt_path"
  [ "$terminal" = "fm-test1" ] || fail "session id should be the fm-spawn window name verbatim, got '$terminal'"
  [ -f "$wt_path/.fm-orca-session" ] || fail "worktree should carry a .fm-orca-session marker"
  [ "$(cat "$wt_path/.fm-orca-session")" = "fm-test1" ] || fail ".fm-orca-session should hold the session id"
  # The fake logs US-separated args; cat collapses US to whitespace when
  # rendering. Use Python for byte-accurate assertions on US-bearing logs.
  python3 - "$LOG" <<'PY' || fail "worktree_create did not issue the expected fmod create"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
# Check substrings rather than full message to avoid coupling the test to
# the random tmpdir path.
assert b"fmod" + US + b"create" + US + b"fm-test1" + US + b"--cwd" + US in log, "no fmod create --cwd call"
assert b"fmod" + US + b"get-cwd" + US + b"fm-test1" in log, "no fmod get-cwd verification call"
assert b"--shell-ready" in log, "fmod create did not pass --shell-ready"
assert b"--cols" + US + b"200" in log, "fmod create did not pass --cols 200"
PY
  pass "fm_backend_orca_worktree_create: creates git worktree + fmod session; marker file present"
}

test_worktree_create_refuses_existing_path() {
  fmod_case wt-create-exists
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  local expected_wt
  expected_wt=$(expected_orca_wt "$repo" fm-test2)
  mkdir -p "$expected_wt"
  local out status
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test2' "$ROOT" "$repo" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_create should refuse an existing path (got rc=0, out=$out)"
  assert_contains "$out" "already exists" "worktree_create should explain the refusal"
  pass "fm_backend_orca_worktree_create: refuses to clobber an existing worktree path"
}

test_worktree_create_git_failure_uses_private_stderr_file() {
  fmod_case wt-create-git-fail-private-stderr
  local repo out status tmp_files
  repo=$(build_test_repo "$CASE_DIR" repo)
  git -C "$repo" branch fm/fm-test-git-fail HEAD
  mkdir -p "$CASE_DIR/tmp"
  out=$( TMPDIR="$CASE_DIR/tmp" PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test-git-fail' "$ROOT" "$repo" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_create should fail when git worktree add fails"
  assert_contains "$out" "git worktree add failed" "worktree_create should label git worktree add failures"
  assert_contains "$out" "already exists" "worktree_create should surface git worktree stderr"
  assert_not_contains "$(sed -n '1,180p' "$ROOT/bin/backends/orca.sh")" "/tmp/fm-orca-wt.err" \
    "worktree_create should not use a fixed stderr path"
  tmp_files=$(find "$CASE_DIR/tmp" -type f -name 'fm-orca-wt.*' -print)
  [ -z "$tmp_files" ] || fail "worktree_create should clean up private stderr files, left: $tmp_files"
  pass "fm_backend_orca_worktree_create: captures git stderr with a private temp file"
}

test_worktree_create_cleans_up_on_fmod_failure() {
  fmod_case wt-create-fmod-fail
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  # The fake increments $RESP/.count to compute next; if it is unset the
  # first invocation lands on 1. Write a sentinel 1.exit to force the
  # create RPC to fail with exit 3, exercising the adapter's cleanup branch.
  rm -f "$RESP/.count"
  echo "3" > "$RESP/1.exit"
  local status
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test3' "$ROOT" "$repo" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_create should fail when fmod create fails (rc=$status)"
  local expected_wt
  expected_wt=$(expected_orca_wt "$repo" fm-test3)
  [ ! -d "$expected_wt" ] || fail "worktree_create should clean up the git worktree when fmod fails"
  if git -C "$repo" show-ref --verify --quiet refs/heads/fm/fm-test3; then
    fail "worktree_create should delete the just-created task branch when fmod fails"
  fi
  pass "fm_backend_orca_worktree_create: removes the worktree and branch when fmod create fails"
}

test_worktree_create_recreates_stale_attached_session() {
  fmod_case wt-create-stale-session
  local repo expected_wt
  repo=$(build_test_repo "$CASE_DIR" repo)
  expected_wt=$(expected_orca_wt "$repo" fm-test-stale)
  printf '%s\n' "$CASE_DIR/stale-worktree" > "$RESP/2.out"
  printf '%s\n' "$expected_wt" > "$RESP/5.out"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test-stale' "$ROOT" "$repo" > "$CASE_DIR/raw"
  [ -d "$expected_wt" ] || fail "worktree path $expected_wt was not created after stale session recovery"
  [ "$(cat "$expected_wt/.fm-orca-session")" = "fm-test-stale" ] || fail "marker should hold the recreated session id"
  python3 - "$LOG" "$expected_wt" <<'PY' || fail "worktree_create should kill and recreate stale attached sessions"
import sys
log = open(sys.argv[1], "rb").read()
wt = sys.argv[2].encode()
US = b"\x1f"
create = b"fmod" + US + b"create" + US + b"fm-test-stale" + US + b"--cwd" + US + wt
assert log.count(create) == 2, log
assert b"fmod" + US + b"get-cwd" + US + b"fm-test-stale" in log, log
assert b"fmod" + US + b"kill" + US + b"fm-test-stale" in log, log
PY
  pass "fm_backend_orca_worktree_create: kills and recreates stale attached sessions"
}

test_worktree_create_accepts_trailing_slash_cwd() {
  fmod_case wt-create-trailing-slash-cwd
  local repo expected_wt
  repo=$(build_test_repo "$CASE_DIR" repo)
  expected_wt=$(expected_orca_wt "$repo" fm-test-slash)
  printf '%s/\n' "$expected_wt" > "$RESP/2.out"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test-slash' "$ROOT" "$repo" > "$CASE_DIR/raw"
  [ -d "$expected_wt" ] || fail "worktree path $expected_wt was not created"
  python3 - "$LOG" "$expected_wt" <<'PY' || fail "worktree_create should accept fmod get-cwd trailing slash"
import sys
log = open(sys.argv[1], "rb").read()
wt = sys.argv[2].encode()
US = b"\x1f"
create = b"fmod" + US + b"create" + US + b"fm-test-slash" + US + b"--cwd" + US + wt
assert log.count(create) == 1, log
assert b"fmod" + US + b"kill" + US + b"fm-test-slash" not in log, log
PY
  pass "fm_backend_orca_worktree_create: accepts fmod get-cwd trailing slash"
}

test_worktree_create_kills_session_when_initial_cwd_check_fails() {
  fmod_case wt-create-cwd-fail
  local repo expected_wt status
  repo=$(build_test_repo "$CASE_DIR" repo)
  expected_wt=$(expected_orca_wt "$repo" fm-test-cwd-fail)
  echo "7" > "$RESP/2.exit"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test-cwd-fail' "$ROOT" "$repo" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_create should fail when initial fmod get-cwd fails"
  [ ! -d "$expected_wt" ] || fail "worktree_create should remove worktree after initial get-cwd failure"
  python3 - "$LOG" <<'PY' || fail "initial get-cwd failure should kill the created session"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
assert b"fmod" + US + b"kill" + US + b"fm-test-cwd-fail" + US + b"--immediate" in log, log
PY
  pass "fm_backend_orca_worktree_create: kills session after initial get-cwd failure"
}

test_worktree_create_kills_session_when_recreated_cwd_check_fails() {
  fmod_case wt-create-recreate-cwd-fail
  local repo expected_wt status
  repo=$(build_test_repo "$CASE_DIR" repo)
  expected_wt=$(expected_orca_wt "$repo" fm-test-rec-cwd-fail)
  printf '%s\n' "$CASE_DIR/stale-worktree" > "$RESP/2.out"
  echo "7" > "$RESP/5.exit"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test-rec-cwd-fail' "$ROOT" "$repo" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_create should fail when recreated fmod get-cwd fails"
  [ ! -d "$expected_wt" ] || fail "worktree_create should remove worktree after recreated get-cwd failure"
  python3 - "$LOG" <<'PY' || fail "recreated get-cwd failure should kill the recreated session"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
needle = b"fmod" + US + b"kill" + US + b"fm-test-rec-cwd-fail" + US + b"--immediate"
assert log.count(needle) == 2, log
PY
  pass "fm_backend_orca_worktree_create: kills session after recreated get-cwd failure"
}

test_remove_worktree_kills_session_and_removes_dir() {
  fmod_case wt-remove
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  local wt_path
  wt_path=$(expected_orca_wt "$repo" fm-test4)
  # Manually build a real worktree (no need to spin up the daemon session)
  # so remove_worktree's git-remove branch has a target. The marker file
  # is what binds the orca session id to the worktree path.
  git -C "$repo" worktree add --detach "$wt_path" HEAD >/dev/null
  printf '%s\n' "fm-test4" > "$wt_path/.fm-orca-session"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree "$1"' "$ROOT" "$wt_path"
  [ ! -d "$wt_path" ] || fail "remove_worktree should delete $wt_path"
  python3 - "$LOG" <<'PY' || fail "remove_worktree should call fmod kill with the marker session id"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
assert b"fmod" + US + b"kill" + US + b"fm-test4" in log, f"missing fm-test4 kill; log: {log!r}"
PY
  pass "fm_backend_orca_remove_worktree: fmod kill + git worktree remove"
}

test_remove_worktree_deletes_task_branch() {
  fmod_case wt-remove-branch
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  local wt_path
  wt_path=$(expected_orca_wt "$repo" fm-direct)
  git -C "$repo" worktree add -q -b fm/fm-direct "$wt_path" HEAD
  printf '%s\n' "fm-direct" > "$wt_path/.fm-orca-session"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree "$1"' "$ROOT" "$wt_path"
  [ ! -d "$wt_path" ] || fail "remove_worktree should delete $wt_path"
  if git -C "$repo" show-ref --verify --quiet refs/heads/fm/fm-direct; then
    fail "remove_worktree should delete the Orca task branch"
  fi
  pass "fm_backend_orca_remove_worktree: deletes the task branch"
}

test_remove_worktree_falls_back_to_basename_session_id() {
  fmod_case wt-remove-fallback
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  # fm-spawn always names worktrees `fm-<id>`; with the marker file
  # missing, the adapter derives the session id from basename. Mirror that
  # shape here so the test exercises the real fallback path.
  local wt_path
  wt_path=$(expected_orca_wt "$repo" fm-legacy)
  mkdir -p "$wt_path"
  git -C "$repo" worktree add --detach "$wt_path" HEAD >/dev/null
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree "$1"' "$ROOT" "$wt_path"
  python3 - "$LOG" <<'PY' || fail "remove_worktree should fall back to basename session id"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
assert b"fmod" + US + b"kill" + US + b"fm-legacy" in log, f"missing fm-legacy kill; log: {log!r}"
PY
  pass "fm_backend_orca_remove_worktree: derives session id from basename when marker file is absent"
}

test_remove_worktree_surfaces_git_failure_without_killing_session() {
  fmod_case wt-remove-git-fails
  local repo wt_path fake_git
  repo=$(build_test_repo "$CASE_DIR" repo)
  wt_path="$CASE_DIR/fm-fail"
  mkdir -p "$wt_path" "$CASE_DIR/fakegit"
  printf 'gitdir: %s/.git/worktrees/fm-fail\n' "$repo" > "$wt_path/.git"
  printf '%s\n' "fm-fail" > "$wt_path/.fm-orca-session"
  fake_git="$CASE_DIR/fakegit/git"
  cat > "$fake_git" <<'SH'
#!/usr/bin/env bash
printf 'git failed as requested\n' >&2
exit 23
SH
  chmod +x "$fake_git"
  local out status
  out=$( PATH="$CASE_DIR/fakegit:$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree "$1"' "$ROOT" "$wt_path" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when git worktree remove fails"
  assert_contains "$out" "git failed as requested" \
    "remove_worktree should surface git worktree remove stderr"
  [ -f "$wt_path/.fm-orca-session" ] || fail "remove_worktree should leave the session marker when git removal fails"
  if grep -q $'fmod\x1fkill\x1ffm-fail' "$LOG"; then
    fail "remove_worktree should not kill the fmod session when git removal fails"
  fi
  pass "fm_backend_orca_remove_worktree: propagates git removal failure"
}

test_spawn_excludes_orca_session_marker() {
  fmod_case spawn-excludes-session-marker
  local home data state config repo wt_path exclude_file
  home="$CASE_DIR/home"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data/marker" "$state" "$config"
  printf 'brief\n' > "$data/marker/brief.md"
  repo=$(build_test_repo "$home" repo)
  wt_path=$(expected_orca_wt "$repo" fm-marker)
  printf '%s\n' "$wt_path" > "$RESP/3.out"
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-spawn.sh" marker "$repo" --backend orca --harness codex >/dev/null
  exclude_file=$(git -C "$wt_path" rev-parse --git-path info/exclude)
  grep -qxF '.fm-orca-session' "$exclude_file" \
    || fail "fm-spawn should exclude .fm-orca-session from git status"
  git -C "$repo" worktree remove --force "$wt_path" >/dev/null 2>&1 || true
  git -C "$repo" branch -D fm/fm-marker >/dev/null 2>&1 || true
  rm -rf /tmp/fm-marker
  pass "fm-spawn.sh: excludes Orca session marker from worktree status"
}

test_spawn_abort_removes_unmodified_orca_branch() {
  fmod_case spawn-abort-branch-cleanup
  local home data config state_file repo out status wt_path
  home="$CASE_DIR/home"
  data="$home/data"
  config="$home/config"
  state_file="$home/not-a-dir-state"
  mkdir -p "$data/abort" "$config"
  printf 'brief\n' > "$data/abort/brief.md"
  printf 'not a directory\n' > "$state_file"
  repo=$(build_test_repo "$home" repo)
  wt_path=$(expected_orca_wt "$repo" fm-abort)
  printf '%s\n' "$wt_path" > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_STATE_OVERRIDE="$state_file" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-spawn.sh" abort "$repo" --backend orca --harness codex 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn should fail when state path is not a directory"
  assert_contains "$out" "cannot create directory" "spawn failure should come from the post-create state setup"
  if git -C "$repo" show-ref --verify --quiet refs/heads/fm/fm-abort; then
    fail "abort cleanup should delete the unmodified Orca task branch"
  fi
  [ ! -d "$wt_path" ] || fail "abort cleanup should remove the Orca worktree"
  rm -rf /tmp/fm-abort
  pass "fm-spawn.sh: abort cleanup removes unmodified Orca branch"
}

# ---- composer state -------------------------------------------------------

test_worktree_dir_for_project_registry_path_uses_state_bucket() {
  fmod_case wt-dir-projects
  local home="$CASE_DIR/home" repo out
  repo="$home/projects/repo"
  mkdir -p "$repo"
  out=$(bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_dir "$1" fm-test' "$ROOT" "$repo")
  [ "$out" = "$home/state/orca-worktrees/repo/fm-test" ] \
    || fail "project registry worktree dir should use state bucket, got '$out'"
  pass "fm_backend_orca_worktree_dir: keeps registry project worktrees under state"
}

test_composer_state_empty_when_bare_prompt() {
  fmod_case composer-empty
  printf '╭──╮\n│ > │\n╰──╯\n' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "empty" ] || fail "bare bordered prompt should be empty, got '$out'"
  pass "fm_backend_orca_composer_state: empty on a bare bordered prompt"
}

test_composer_state_pending_when_text_inside_borders() {
  fmod_case composer-pending
  printf '╭──────────────╮\n│ > hello cap │\n╰──────────────╯\n' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "pending" ] || fail "text inside borders should be pending, got '$out'"
  pass "fm_backend_orca_composer_state: pending when text remains inside the bordered row"
}

test_composer_state_pending_when_popup_placeholder_inside() {
  fmod_case composer-popup-placeholder
  printf '╭─────────────────────────────────────╮\n│ > /compact compaction instructions  │\n╰───────────────── Composer ──────────╯\n' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "pending" ] || fail "popup placeholder fill must still be pending, got '$out'"
  pass "fm_backend_orca_composer_state: slash-command popup placeholder is still pending"
}

test_composer_state_unknown_when_no_bordered_row() {
  fmod_case composer-unknown
  printf 'jd@torre:/tmp$ echo plain shell prompt\n' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "unknown" ] || fail "plain shell prompt should be unknown (no bordered row), got '$out'"
  pass "fm_backend_orca_composer_state: unknown when the snapshot has no bordered row"
}

# Opencode's TUI uses a left-only ┃ border with a horizontal ▀ underline
# (no matching right ┃). The detector must accept that shape so submit
# retries can see typed text inside the composer.
test_composer_state_pending_when_opencode_left_only_border_with_text() {
  fmod_case composer-opencode-pending
  # opencode TUI snapshot with text typed: a row that is "┃  hello world"
  # with no trailing ┃, sitting above the "╹▀▀▀..." bottom border.
  printf '%s\n' \
    '             ┃' \
    '             ┃  hello world' \
    '             ┃' \
    '             ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "pending" ] || fail "opencode left-only ┃ border with typed text should be pending, got '$out'"
  pass "fm_backend_orca_composer_state: pending for opencode's left-only ┃ border + typed text"
}

test_composer_state_empty_when_opencode_placeholder_only() {
  fmod_case composer-opencode-empty
  # opencode TUI idle snapshot: the bordered row contains only the
  # "Ask anything..." placeholder, no user text yet.
  printf '%s\n' \
    '             ┃' \
    '             ┃  Ask anything... "Fix a TODO in the codebase"' \
    '             ┃' \
    '             ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "empty" ] || fail "opencode idle placeholder should be empty, got '$out'"
  pass "fm_backend_orca_composer_state: empty for opencode's 'Ask anything...' placeholder"
}

test_composer_state_skips_opencode_footer_after_empty_spacer() {
  fmod_case composer-opencode-footer-spacer
  printf '%s\n' \
    '             ┃' \
    '             ┃  Ask anything...' \
    '             ┃' \
    '             ┃  Build · tab agents · ctrl+p commands' \
    '             ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "empty" ] || fail "opencode footer after empty spacer should not mask idle composer, got '$out'"
  pass "fm_backend_orca_composer_state: skips opencode footer after empty spacer"
}

# Bottom-border-shaped rows like the opencode "╹▀▀▀..." underline must NOT
# be mistaken for the composer's content row.
test_composer_state_ignores_horizontal_underline_row() {
  fmod_case composer-opencode-no-bordered-row
  # A snapshot whose only "border-like" rows are the horizontal underline.
  printf '%s\n' \
    '                  ▄' \
    '                  █▀▀█ █▀▀█' \
    '             ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀' \
    '                  tab agents  ctrl+p commands' > "$RESP/1.out"
  local out
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$ROOT" )
  [ "$out" = "unknown" ] || fail "horizontal-only underline row should be unknown (no real composer), got '$out'"
  pass "fm_backend_orca_composer_state: skips the opencode ▀ underline row"
}

test_composer_state_uses_bundled_fmod_fallback() {
  fmod_case composer-bundled-fmod
  local mini_root="$CASE_DIR/mini-root"
  mkdir -p "$mini_root/bin/backends"
  cp "$ROOT/bin/backends/orca.sh" "$mini_root/bin/backends/orca.sh"
  cp "$FB/fmod" "$mini_root/bin/fmod"
  printf '╭──╮\n│ > │\n╰──╯\n' > "$RESP/1.out"
  local out
  out=$( PATH="/usr/bin:/bin:/usr/sbin:/sbin" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state fm-x' "$mini_root" )
  [ "$out" = "empty" ] || fail "composer_state should use bundled fmod fallback, got '$out'"
  pass "fm_backend_orca_composer_state: loads bundled fmod before snapshot"
}

# ---- dispatcher ----------------------------------------------------------

test_dispatcher_sources_orca_and_routes_primitives() {
  fmod_case dispatcher
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '
      . "$0/bin/fm-backend.sh"
      fm_backend_source orca >/dev/null
      fm_backend_capture orca fm-x 5 >/dev/null
      fm_backend_send_key orca fm-x Enter >/dev/null
      fm_backend_send_key orca fm-x C-c >/dev/null
      fm_backend_kill orca fm-x >/dev/null
      fm_backend_send_text_submit orca fm-x "hi" 1 0.01 0.01 >/dev/null
    ' "$ROOT"
  # Byte-level counts. We cannot grep -F for raw control bytes (LF, ETX,
  # US) reliably across grep versions, so read the log with Python and do
  # substring matches on the raw bytes.
  python3 - "$LOG" <<'PY' || fail "dispatcher routing check failed"
import sys
log = open(sys.argv[1], "rb").read()
US = b"\x1f"
assert b"fmod" + US + b"snapshot" + US + b"fm-x" + US + b"--strip-ansi" in log, "no capture call"
assert b"fmod" + US + b"kill" + US + b"fm-x" in log, "no kill call"
# send_key Enter => fmod write fm-x --data <LF>
assert b"write" + US + b"fm-x" + US + b"--data" + US + b"\n" in log, "no Enter write"
# send_key C-c => fmod write fm-x --data <ETX>
assert b"write" + US + b"fm-x" + US + b"--data" + US + b"\x03" in log, "no C-c write"
# send_text_submit => literal "hi" write
assert b"write" + US + b"fm-x" + US + b"--data" + US + b"hi" in log, "no literal 'hi' write"
PY
  pass "fm-backend dispatcher routes orca primitives through fmod"
}

# ---- bootstrap helper file is present and syntactically valid -------------

test_orca_adapter_sources_clean_under_set_e() {
  fmod_case syntax
  if ! bash -n "$ROOT/bin/backends/orca.sh"; then
    fail "bin/backends/orca.sh has a bash syntax error"
  fi
  # And it must source without blowing up under `set -eu`.
  PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c 'set -eu; . "$0/bin/backends/orca.sh"; : >/dev/null' "$ROOT"
  pass "bin/backends/orca.sh: parses cleanly and sources under set -eu"
}

test_fmod_defaults_follow_home_and_xdg_config_home() {
  fmod_case fmod-paths
  local out protocol
  protocol=$(python3 - "$ROOT/bin/fmod" <<'PY'
import runpy
import sys
mod = runpy.run_path(sys.argv[1])
print(mod["PROTOCOL_VERSION"])
PY
)
  out=$(HOME="$CASE_DIR/home" XDG_CONFIG_HOME= python3 - "$ROOT/bin/fmod" <<'PY'
import os
import runpy
import sys

os.environ.pop("XDG_CONFIG_HOME", None)
os.environ.pop("FMOD_SOCKET", None)
os.environ.pop("FMOD_TOKEN", None)
os.environ.pop("FMOD_PIDFILE", None)
mod = runpy.run_path(sys.argv[1])
print("\n".join(mod["daemon_paths"]()))
PY
)
  [ "$out" = "$CASE_DIR/home/.config/orca/daemon/daemon-v$protocol.sock
$CASE_DIR/home/.config/orca/daemon/daemon-v$protocol.token
$CASE_DIR/home/.config/orca/daemon/daemon-v$protocol.pid" ] || fail "fmod defaults should resolve under HOME, got: $out"

  out=$(HOME="$CASE_DIR/home" XDG_CONFIG_HOME="$CASE_DIR/xdg" python3 - "$ROOT/bin/fmod" <<'PY'
import os
import runpy
import sys

os.environ.pop("FMOD_SOCKET", None)
os.environ.pop("FMOD_TOKEN", None)
os.environ.pop("FMOD_PIDFILE", None)
mod = runpy.run_path(sys.argv[1])
print("\n".join(mod["daemon_paths"]()))
PY
)
  [ "$out" = "$CASE_DIR/xdg/orca/daemon/daemon-v$protocol.sock
$CASE_DIR/xdg/orca/daemon/daemon-v$protocol.token
$CASE_DIR/xdg/orca/daemon/daemon-v$protocol.pid" ] || fail "fmod defaults should resolve under XDG_CONFIG_HOME, got: $out"
  pass "fmod daemon_paths: defaults follow HOME and XDG_CONFIG_HOME"
}

test_fmod_write_uses_rpc_not_notify() {
  fmod_case fmod-write-rpc
  python3 - "$ROOT/bin/fmod" <<'PY' || fail "fmod write should use acknowledged RPC"
import argparse
import runpy
import sys

mod = runpy.run_path(sys.argv[1])
calls = []

class FakeClient:
    def __init__(self, sock, token):
        self.sock = sock
        self.token = token

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        pass

    def rpc(self, method, params):
        calls.append(("rpc", method, params))
        return {}

    def notify(self, method, params):
        calls.append(("notify", method, params))

mod["cmd_write"].__globals__["DaemonClient"] = FakeClient
args = argparse.Namespace(sock="sock", token="token", session_id="fm-x", data="hi", hex_data=None, stdin=False)
rc = mod["cmd_write"](args)
assert rc == 0
assert calls == [("rpc", "write", {"sessionId": "fm-x", "data": "hi"})], calls
PY
  pass "fmod write: waits for daemon RPC acknowledgement"
}

test_fmod_info_reports_missing_token_as_unreachable_json() {
  fmod_case fmod-info-missing-token
  python3 - "$ROOT/bin/fmod" <<'PY' || fail "fmod info should report missing token as JSON"
import argparse
import contextlib
import io
import json
import runpy
import sys

mod = runpy.run_path(sys.argv[1])

class MissingTokenClient:
    def __init__(self, sock, token):
        self.sock = sock
        self.token = token

    def __enter__(self):
        raise FileNotFoundError(self.token)

    def __exit__(self, *exc):
        pass

mod["cmd_info"].__globals__["DaemonClient"] = MissingTokenClient
args = argparse.Namespace(sock="sock", token="missing-token")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = mod["cmd_info"](args)
out = json.loads(buf.getvalue())
assert rc == 0
assert out["daemon_reachable"] is False
assert "missing-token" in out["daemon_error"], out
PY
  pass "fmod info: missing token reports daemon_reachable=false JSON"
}

test_fmod_protocol_discovery_sends_candidate_version() {
  fmod_case fmod-discovery-version
  python3 - "$ROOT/bin/fmod" "$CASE_DIR" <<'PY' || fail "fmod discovery should send each candidate protocol version"
import os
import runpy
import sys

mod = runpy.run_path(sys.argv[1])
case_dir = sys.argv[2]
daemon_dir = os.path.join(case_dir, "xdg", "orca", "daemon")
os.makedirs(daemon_dir, exist_ok=True)
protocol = mod["PROTOCOL_VERSION"]
for version in (protocol, 23):
    with open(os.path.join(daemon_dir, f"daemon-v{version}.sock"), "w", encoding="utf-8") as f:
        f.write("")
    with open(os.path.join(daemon_dir, f"daemon-v{version}.token"), "w", encoding="utf-8") as f:
        f.write(f"token-{version}")

sent = []

class FakeSocket:
    def close(self):
        pass

def fake_hello(sock_path, client_id, token, role, timeout, version=None):
    sent.append((os.path.basename(sock_path), client_id, token, role, version))
    if version == 23:
        return FakeSocket()
    raise mod["DaemonHelloError"]("Protocol version mismatch")

os.environ["XDG_CONFIG_HOME"] = os.path.join(case_dir, "xdg")
os.environ.pop("FMOD_PROTOCOL_VERSION", None)
mod["discover_protocol_version"].__globals__["_hello"] = fake_hello
mod["discover_protocol_version"].__globals__["_DISCOVERED_VERSION"] = None

discovered = mod["discover_protocol_version"]()
assert discovered == 23, discovered
assert ("daemon-v23.sock", "token-23", "stream", 23) in [(sock, token, role, version) for sock, client_id, token, role, version in sent], sent
assert ("daemon-v23.sock", "token-23", "control", 23) in [(sock, token, role, version) for sock, client_id, token, role, version in sent], sent
by_version = {}
for sock, client_id, token, role, version in sent:
    by_version.setdefault(version, []).append((sock, client_id, token, role))
assert by_version[23][0][1] == by_version[23][1][1], sent
assert [role for sock, client_id, token, role in by_version[23]] == ["stream", "control"], sent
assert all(sock == f"daemon-v{version}.sock" for sock, client_id, token, role, version in sent), sent
PY
  pass "fmod discovery: sends candidate protocol version in hello"
}

test_fmod_protocol_discovery_skips_stale_socket() {
  fmod_case fmod-discovery-stale
  python3 - "$ROOT/bin/fmod" "$CASE_DIR" <<'PY' || fail "fmod discovery should skip stale socket files"
import os
import runpy
import sys

mod = runpy.run_path(sys.argv[1])
case_dir = sys.argv[2]
daemon_dir = os.path.join(case_dir, "xdg", "orca", "daemon")
os.makedirs(daemon_dir, exist_ok=True)
protocol = mod["PROTOCOL_VERSION"]
for version in (protocol, 23):
    with open(os.path.join(daemon_dir, f"daemon-v{version}.sock"), "w", encoding="utf-8") as f:
        f.write("")
    with open(os.path.join(daemon_dir, f"daemon-v{version}.token"), "w", encoding="utf-8") as f:
        f.write(f"token-{version}")

attempts = []

class FakeSocket:
    def close(self):
        pass

def fake_hello(sock_path, client_id, token, role, timeout, version=None):
    attempts.append((version, role))
    if version == protocol:
        raise mod["DaemonConnError"]("connect failed")
    return FakeSocket()

os.environ["XDG_CONFIG_HOME"] = os.path.join(case_dir, "xdg")
os.environ.pop("FMOD_PROTOCOL_VERSION", None)
mod["discover_protocol_version"].__globals__["_hello"] = fake_hello
mod["discover_protocol_version"].__globals__["_DISCOVERED_VERSION"] = None

discovered = mod["discover_protocol_version"]()
assert discovered == 23, discovered
assert (protocol, "stream") in attempts, attempts
assert (23, "stream") in attempts, attempts
assert (23, "control") in attempts, attempts
PY
  pass "fmod discovery: skips stale socket candidates"
}

# ---- test runner ---------------------------------------------------------

run_test() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep ^test_); do
    "$t"
  done
}

run_test

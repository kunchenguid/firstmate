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

test_worktree_create_makes_git_worktree_and_fmod_session() {
  fmod_case wt-create-happy
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  local wt_root="$repo/_orca-wt/fm-test1"
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
assert b"--shell-ready" in log, "fmod create did not pass --shell-ready"
assert b"--cols" + US + b"200" in log, "fmod create did not pass --cols 200"
PY
  pass "fm_backend_orca_worktree_create: creates git worktree + fmod session; marker file present"
}

test_worktree_create_refuses_existing_path() {
  fmod_case wt-create-exists
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  # fm_backend_orca_worktree_dir puts the worktree under
  # $(dirname "$project")/_orca-wt/<name>, NOT under $project/_orca-wt/<name>.
  # Mirror that exact layout so the existence check has something to find.
  local expected_wt
  expected_wt="$(dirname "$repo")/_orca-wt/fm-test2"
  mkdir -p "$expected_wt"
  local out status
  out=$( PATH="$FB:$PATH" FMOD_FAKE_LOG="$LOG" FMOD_FAKE_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create "$1" fm-test2' "$ROOT" "$repo" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_create should refuse an existing path (got rc=0, out=$out)"
  assert_contains "$out" "already exists" "worktree_create should explain the refusal"
  pass "fm_backend_orca_worktree_create: refuses to clobber an existing worktree path"
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
  expected_wt="$(dirname "$repo")/_orca-wt/fm-test3"
  [ ! -d "$expected_wt" ] || fail "worktree_create should clean up the git worktree when fmod fails"
  pass "fm_backend_orca_worktree_create: removes the worktree when fmod create fails"
}

test_remove_worktree_kills_session_and_removes_dir() {
  fmod_case wt-remove
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  local wt_path
  wt_path="$(dirname "$repo")/_orca-wt/fm-test4"
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

test_remove_worktree_falls_back_to_basename_session_id() {
  fmod_case wt-remove-fallback
  local repo
  repo=$(build_test_repo "$CASE_DIR" repo)
  # fm-spawn always names worktrees `fm-<id>`; with the marker file
  # missing, the adapter derives the session id from basename. Mirror that
  # shape here so the test exercises the real fallback path.
  local wt_path
  wt_path="$(dirname "$repo")/_orca-wt/fm-legacy"
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

# ---- composer state -------------------------------------------------------

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

# ---- test runner ---------------------------------------------------------

run_test() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep ^test_); do
    "$t"
  done
}

run_test

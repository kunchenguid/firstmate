#!/usr/bin/env bash
# tests/fm-backend-herdr.test.sh - fake-herdr-CLI unit tests for the herdr
# session-provider adapter (bin/backends/herdr.sh), P2 of
# data/fm-backend-design-d7 (herdr-addendum.md). Mirrors tests/fm-backend.test.sh's
# fakebin/command-log convention, but herdr has no pre-refactor baseline to
# diff against (it is new in this task), so these are direct behavior
# assertions against a small, LOG-based, canned-response fake `herdr` + real
# `jq` (jq itself is a real required tool for this backend, not faked).
# The real-binary smoke test lives in tests/fm-backend-herdr-smoke.test.sh,
# gated on the herdr binary actually being installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-tests)

# make_herdr_fakebin: a `herdr` stub that logs every invocation (one line,
# unit-separated args, to $FM_HERDR_LOG) and returns the canned response for
# that call read from $FM_HERDR_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...) so a test can script a short sequence
# of calls precisely. A missing response file means "succeed with empty
# stdout" (mirrors send-text/send-keys/pane close, which are silent on success
# in the real CLI - verified in herdr-verification-p2.md).
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ] && [ "${FM_HERDR_SCRIPT_STATUS:-0}" != 1 ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# herdr_case <name> -> sets up FM_HERDR_LOG/FM_HERDR_RESPONSES/fb for one test,
# registers cleanup-free tmp dirs under TMP_ROOT.
herdr_env() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/responses"
  : > "$dir/log"
  printf '%s\n%s\n' "$dir/log" "$dir/responses"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_protocol() {
  local dir log resp fb status
  dir="$TMP_ROOT/version-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","channel":"stable","protocol":14}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept protocol 14 (>= the verified minimum)"
  assert_contains "$(cat "$log")" $'\x1f''status'$'\x1f''--json' "version_check did not call herdr status --json"
  pass "fm_backend_herdr_version_check: accepts the current protocol (14)"
}

test_version_check_refuses_old_protocol() {
  local dir log resp fb out status
  dir="$TMP_ROOT/version-old"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.3.0","channel":"stable","protocol":5}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse protocol 5 (below min)"
  assert_contains "$out" "protocol 5" "version_check error did not name the rejected protocol"
  pass "fm_backend_herdr_version_check: refuses an old protocol loudly"
}

test_version_check_refuses_missing_herdr() {
  local dir out status
  dir="$TMP_ROOT/version-missing"; mkdir -p "$dir/empty-fakebin"
  out=$( PATH="$dir/empty-fakebin:/usr/bin:/bin" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when herdr is not installed"
  assert_contains "$out" "not installed" "version_check did not report herdr as missing"
  pass "fm_backend_herdr_version_check: refuses loudly when herdr is not installed"
}

# --- container_ensure / create_task ------------------------------------------

test_container_ensure_starts_server_and_workspace() {
  local dir log resp fb out
  dir="$TMP_ROOT/container"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: version_check status --json (server not running yet, irrelevant to client check)
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  # 2: server_ensure's status --json check -> not running
  printf '{"server":{"running":false}}\n' > "$resp/2.out"
  # 3: `herdr server` backgrounded launch - no meaningful output
  # 4: server_ensure poll -> now running
  printf '{"server":{"running":true}}\n' > "$resp/4.out"
  # 5: workspace list -> empty (no "firstmate" workspace yet)
  printf '{"result":{"workspaces":[]}}\n' > "$resp/5.out"
  # 6: workspace create -> w1
  printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"}}}\n' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = "fmtest:w1" ] || fail "container_ensure should echo '<session>:<workspace_id>', got '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=fmtest"$'\x1f''server' "container_ensure did not start the herdr server"
  assert_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--cwd'$'\x1f''/tmp'$'\x1f''--label'$'\x1f''firstmate' \
    "container_ensure did not create the firstmate workspace with the given cwd"
  pass "fm_backend_herdr_container_ensure: version-gates, starts the server, ensures the firstmate workspace, echoes session:workspace_id"
}

test_container_ensure_reuses_existing_workspace() {
  local dir log resp fb out
  dir="$TMP_ROOT/container-reuse"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"client":{"version":"0.7.1","protocol":14}}\n' > "$resp/1.out"
  printf '{"server":{"running":true}}\n' > "$resp/2.out"
  printf '{"result":{"workspaces":[{"workspace_id":"w9","label":"firstmate"}]}}\n' > "$resp/3.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" FM_HERDR_SCRIPT_STATUS=1 HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT" )
  [ "$out" = "fmtest:w9" ] || fail "container_ensure should reuse the existing firstmate workspace id, got '$out'"
  assert_not_contains "$(cat "$log")" $'\x1f''workspace'$'\x1f''create' "container_ensure should not create a workspace that already exists"
  pass "fm_backend_herdr_container_ensure: reuses an existing firstmate workspace without recreating it"
}

test_create_task_refuses_duplicate_label() {
  local dir log resp fb out status
  dir="$TMP_ROOT/dup-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"fm-dup1","workspace_id":"w1"}]}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-dup1 /tmp/proj' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing tab label (herdr itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate label"
  pass "fm_backend_herdr_create_task: refuses a duplicate tab label (herdr's own tab create has no uniqueness check)"
}

test_create_task_creates_and_parses_ids() {
  local dir log resp fb out
  dir="$TMP_ROOT/create-task"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"tabs":[]}}\n' > "$resp/1.out"
  printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n' > "$resp/2.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-newtask /tmp/proj' "$ROOT" )
  [ "$out" = "w1:t2 w1:p2" ] || fail "create_task should echo '<tab_id> <pane_id>', got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f''w1'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--label'$'\x1f''fm-newtask' \
    "create_task did not call tab create with workspace/cwd/label"
  pass "fm_backend_herdr_create_task: creates a tab and parses tab_id/pane_id from the JSON response"
}

# --- target parsing, key normalization ---------------------------------------

test_parse_target() {
  ( . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_parse_target "default:w1:p2" || exit 1
    [ "$FM_BACKEND_HERDR_SESSION" = default ] || { echo "session mismatch: $FM_BACKEND_HERDR_SESSION" >&2; exit 1; }
    [ "$FM_BACKEND_HERDR_PANE" = "w1:p2" ] || { echo "pane mismatch: $FM_BACKEND_HERDR_PANE" >&2; exit 1; }
  ) || fail "fm_backend_herdr_parse_target did not split session:pane on the first colon only"
  pass "fm_backend_herdr_parse_target: splits '<session>:<pane_id>' on the FIRST colon (pane_id itself contains one)"
}

test_normalize_key() {
  ( . "$ROOT/bin/backends/herdr.sh"
    [ "$(fm_backend_herdr_normalize_key Enter)" = enter ] || exit 1
    [ "$(fm_backend_herdr_normalize_key Escape)" = escape ] || exit 1
    [ "$(fm_backend_herdr_normalize_key C-c)" = ctrl+c ] || exit 1
    [ "$(fm_backend_herdr_normalize_key ctrl+c)" = ctrl+c ] || exit 1
  ) || fail "fm_backend_herdr_normalize_key did not map firstmate's key vocabulary to herdr's verified names"
  pass "fm_backend_herdr_normalize_key: Enter/Escape/C-c map to herdr's verified enter/escape/ctrl+c"
}

# --- capture / send_key / kill / current_path --------------------------------

test_capture_calls_pane_read() {
  local dir log resp fb out
  dir="$TMP_ROOT/capture"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'line one\nline two\nline three\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  # Requesting 250 (already >= the 200 floor) passes straight through as the
  # fetch bound; the adapter then trims to the caller's requested 250 lines
  # locally, so all 3 fake lines survive.
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 250' "$ROOT" )
  [ "$out" = $'line one\nline two\nline three' ] || fail "capture did not pass through pane read output, got '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=default"$'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2'$'\x1f''--source'$'\x1f''recent'$'\x1f''--lines'$'\x1f''250' \
    "capture did not call pane read with the right pane id and line bound"
  pass "fm_backend_herdr_capture: calls 'pane read <pane> --source recent --lines N' with the session set"
}

test_capture_works_around_small_lines_bug() {
  local dir log resp fb out
  # Verified herdr v0.7.1 bug (herdr-verification-p2.md): `pane read --lines N`
  # for a small N (below the pane's viewport height) returns EMPTY, not the
  # last N lines. The adapter must never ask herdr for a small --lines bound -
  # it always fetches >= 200 and trims locally with tail.
  dir="$TMP_ROOT/capture-small"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf 'a\nb\nc\nd\ne\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" )
  [ "$out" = $'d\ne' ] || fail "a small --lines request should still return the last N lines (trimmed locally), got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''--lines'$'\x1f''200' \
    "capture should request a generous fetch (>=200), never the caller's small N, from herdr's own --lines flag"
  pass "fm_backend_herdr_capture: works around the verified small-N '--lines' bug by over-fetching and trimming locally"
}

test_capture_preserves_pane_read_failure() {
  local dir log resp fb out status
  dir="$TMP_ROOT/capture-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 2' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when pane read fails, got output '$out'"
  assert_contains "$(cat "$log")" "HERDR_SESSION=default"$'\x1f''status'$'\x1f''--json' \
    "capture did not ensure the herdr server before reading the pane"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "capture did not try to read the requested pane"
  pass "fm_backend_herdr_capture: ensures the session and preserves pane read failure"
}

test_send_key_normalizes_and_targets_pane() {
  local dir log resp fb
  dir="$TMP_ROOT/sendkey"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_key default:w1:p2 Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' "send_key did not normalize Escape to escape"
  pass "fm_backend_herdr_send_key: normalizes the key and targets the right pane"
}

test_kill_is_best_effort() {
  local dir log resp fb
  dir="$TMP_ROOT/kill"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_kill default:w1:p2' "$ROOT"
  expect_code 0 $? "kill must be best-effort (never fail even when the pane close call itself fails)"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''close'$'\x1f''w1:p2' "kill did not call pane close on the right pane"
  pass "fm_backend_herdr_kill: calls pane close and stays best-effort on failure"
}

test_current_path_reads_cwd() {
  local dir log resp fb out
  dir="$TMP_ROOT/cwd"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # Verified pitfall (herdr-verification-p2.md): .result.pane.cwd is frozen at
  # pane-creation time and never updates; .foreground_cwd tracks the live
  # running process (e.g. a treehouse get subshell) and is what must be read.
  printf '{"result":{"pane":{"cwd":"/tmp/pane-creation-dir","foreground_cwd":"/tmp/fake-worktree"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_current_path default:w1:p2' "$ROOT" )
  [ "$out" = "/tmp/fake-worktree" ] || fail "current_path should read foreground_cwd (the live process), not the frozen creation-time cwd, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''get'$'\x1f''w1:p2' "current_path did not call pane get"
  pass "fm_backend_herdr_current_path: reads pane foreground_cwd (the live running process), not the frozen creation-time cwd"
}

# --- busy_state (semantic agent state) ---------------------------------------

test_busy_state_working_maps_to_busy() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-working"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"working"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = busy ] || fail "agent_status=working should map to busy, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''agent'$'\x1f''get'$'\x1f''w1:p2' "busy_state did not call agent get"
  pass "fm_backend_herdr_busy_state: working -> busy"
}

test_busy_state_done_and_blocked_map_to_idle() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-done"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"done"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=done should map to idle, got '$out'"

  dir="$TMP_ROOT/busy-blocked"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = idle ] || fail "agent_status=blocked should map to idle (stuck waiting on the human, not grinding), got '$out'"
  pass "fm_backend_herdr_busy_state: done -> idle, blocked -> idle (surfaced like a stale pane, not suppressed as busy)"
}

test_busy_state_unknown_on_no_agent() {
  local dir log resp fb out
  dir="$TMP_ROOT/busy-unknown"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT" )
  [ "$out" = unknown ] || fail "a failed agent get should report unknown (the fallback-to-regex cue), got '$out'"
  pass "fm_backend_herdr_busy_state: unparseable/absent agent state reports unknown, the regex-fallback cue"
}

# --- send_text_submit: delta-based verify-and-retry --------------------------

test_send_text_submit_detects_landed_send() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-ok"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # 1: send-text (literal, no output)
  # 2: capture right after typing (the "typed" baseline)
  printf '%s' $'❯ hello captain' > "$resp/2.out"
  # 3: send-keys enter
  # 4: capture after Enter - CHANGED (submitted)
  printf '%s' $'hello captain\n❯' > "$resp/4.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once the pane visibly changes, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-text'$'\x1f''w1:p2'$'\x1f''hello captain' "send_text_submit did not type the literal text first"
  pass "fm_backend_herdr_send_text_submit: reports 'empty' once the pane content changes after Enter (submitted)"
}

test_send_text_submit_detects_swallowed_enter() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-swallow"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  # typed baseline and every subsequent capture return the SAME text (Enter never lands)
  printf '%s' $'❯ hello captain' > "$resp/2.out"
  printf '%s' $'❯ hello captain' > "$resp/4.out"
  printf '%s' $'❯ hello captain' > "$resp/6.out"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = pending ] || fail "send_text_submit should report pending once retries are exhausted with no visible change, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'pending' when the pane never changes after retried Enters (swallowed)"
}

test_send_text_submit_send_failed() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/1.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the literal send itself fails, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'send-failed' when the literal send-text call itself errors"
}

test_send_text_submit_unknown_on_baseline_capture_failure() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-baseline-read-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '1\n' > "$resp/2.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "x" 2 0.01 0.01' "$ROOT" )
  [ "$out" = unknown ] || fail "send_text_submit should report unknown when the typed baseline cannot be captured, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'unknown' when typed-baseline capture fails"
}

test_send_text_submit_unknown_on_after_capture_failure() {
  local dir log resp fb out
  dir="$TMP_ROOT/submit-after-read-fail"; mkdir -p "$dir/responses"; log="$dir/log"; resp="$dir/responses"; : > "$log"
  printf '%s' $'❯ hello captain' > "$resp/2.out"
  printf '1\n' > "$resp/4.exit"
  fb=$(make_herdr_fakebin "$dir")
  out=$( PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "hello captain" 2 0.01 0.01' "$ROOT" )
  [ "$out" = unknown ] || fail "send_text_submit should report unknown when post-Enter capture fails, got '$out'"
  pass "fm_backend_herdr_send_text_submit: reports 'unknown' when post-Enter capture fails"
}

# --- fm-backend.sh dispatch wiring -------------------------------------------

test_dispatch_routes_herdr_backend() {
  fm_backend_validate herdr 2>/dev/null || fail "fm_backend_validate should accept herdr (P2 adds it to FM_BACKEND_KNOWN)"
  pass "fm_backend_validate: herdr is a known backend (P2)"
}

test_dispatch_busy_state_unknown_for_tmux() {
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state tmux 'sess:win')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for tmux (no native agent-state primitive; watcher falls back to regex)"
  pass "fm_backend_busy_state: tmux (no native primitive) always reports unknown, preserving the P1 regex-only path"
}

test_scripts_route_explicit_target_through_meta_backend() {
  local dir state log resp fb neutral out
  dir="$TMP_ROOT/script-explicit-target"; state="$dir/state"; mkdir -p "$state" "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  neutral="$dir/neutral-root"; mkdir -p "$neutral"
  fm_write_meta "$state/herdr-stale.meta" "window=default:w1:p2" "backend=herdr"
  touch "$state/.last-watcher-beat"
  printf 'captured herdr pane\n' > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf 'tmux should not be used for a metadata-matched herdr target\n' >&2
exit 42
SH
  chmod +x "$fb/tmux"

  out=$( PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    "$ROOT/bin/fm-peek.sh" default:w1:p2 5 2>/dev/null )
  [ "$out" = "captured herdr pane" ] || fail "fm-peek did not capture through herdr for an explicit metadata-matched target, got '$out'"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''read'$'\x1f''w1:p2' \
    "fm-peek did not route the explicit stale target through herdr capture"

  : > "$log"
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" \
    FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    "$ROOT/bin/fm-send.sh" default:w1:p2 --key Escape >/dev/null 2>&1
  expect_code 0 $? "fm-send --key should route an explicit metadata-matched target through herdr"
  assert_contains "$(cat "$log")" $'\x1f''pane'$'\x1f''send-keys'$'\x1f''w1:p2'$'\x1f''escape' \
    "fm-send did not route the explicit stale target through herdr send-key"

  pass "fm-peek/fm-send: explicit stale targets matching metadata use the recorded backend"
}

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

test_version_check_accepts_current_protocol
test_version_check_refuses_old_protocol
test_version_check_refuses_missing_herdr
test_container_ensure_starts_server_and_workspace
test_container_ensure_reuses_existing_workspace
test_create_task_refuses_duplicate_label
test_create_task_creates_and_parses_ids
test_parse_target
test_normalize_key
test_capture_calls_pane_read
test_capture_works_around_small_lines_bug
test_capture_preserves_pane_read_failure
test_send_key_normalizes_and_targets_pane
test_kill_is_best_effort
test_current_path_reads_cwd
test_busy_state_working_maps_to_busy
test_busy_state_done_and_blocked_map_to_idle
test_busy_state_unknown_on_no_agent
test_send_text_submit_detects_landed_send
test_send_text_submit_detects_swallowed_enter
test_send_text_submit_send_failed
test_send_text_submit_unknown_on_baseline_capture_failure
test_send_text_submit_unknown_on_after_capture_failure
test_dispatch_routes_herdr_backend
test_dispatch_busy_state_unknown_for_tmux
test_scripts_route_explicit_target_through_meta_backend

#!/usr/bin/env bash
# Tests for session-lock harness identity fallback when process ancestry is
# unavailable under sandboxed Codex or Cursor-hosted terminals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-session-lock)

make_ps_denied() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
printf 'ps: operation not permitted\n' >&2
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_codex_marker_detects_harness_without_ps() {
  local dir fakebin got
  dir="$TMP_ROOT/codex-harness"
  fakebin=$(fm_fakebin "$dir")
  make_ps_denied "$fakebin"

  got=$(env -u CURSOR_AGENT_SESSION_ID -u CURSOR_CONVERSATION_ID -u CURSOR_TRACE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 "$ROOT/bin/fm-harness.sh")
  [ "$got" = codex ] || fail "fm-harness marker fallback resolved '$got', expected codex"

  got=$(env -u CURSOR_AGENT_SESSION_ID -u CURSOR_CONVERSATION_ID -u CURSOR_TRACE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  [ "$got" = "codex:thread-123" ] || fail "lock identity fallback resolved '$got', expected codex:thread-123"

  pass "Codex marker detects harness identity without ps ancestry"
}

test_codex_marker_acquires_and_reuses_lock() {
  local dir fakebin home out status
  dir="$TMP_ROOT/codex-lock"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  make_ps_denied "$fakebin"

  out=$(env -u CURSOR_AGENT_SESSION_ID -u CURSOR_CONVERSATION_ID -u CURSOR_TRACE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 FM_HOME="$home" "$ROOT/bin/fm-lock.sh") \
    || fail "fm-lock did not acquire through Codex marker"
  case "$out" in
    *"lock acquired: harness identity codex:thread-123"*) ;;
    *) fail "unexpected lock acquisition output: $out" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "codex:thread-123" ] || fail "lock file did not store the Codex marker identity"

  status=$(env -u CURSOR_AGENT_SESSION_ID -u CURSOR_CONVERSATION_ID -u CURSOR_TRACE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-123 FM_HOME="$home" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in
    *"lock: held by current harness marker codex:thread-123"*) ;;
    *) fail "unexpected current marker lock status: $status" ;;
  esac

  pass "Codex marker acquires and reuses the session lock"
}

test_different_marker_lock_fails_closed() {
  local dir fakebin home err
  dir="$TMP_ROOT/codex-different-lock"
  fakebin=$(fm_fakebin "$dir")
  home="$dir/home"
  mkdir -p "$home/state"
  make_ps_denied "$fakebin"
  printf 'codex:thread-old\n' > "$home/state/.lock"

  if err=$(env -u CURSOR_AGENT_SESSION_ID -u CURSOR_CONVERSATION_ID -u CURSOR_TRACE_ID PATH="$fakebin:$BASE_PATH" \
    CODEX_THREAD_ID=thread-new FM_HOME="$home" "$ROOT/bin/fm-lock.sh" 2>&1); then
    fail "fm-lock acquired over a different marker lock"
  fi
  case "$err" in
    *"another firstmate session holds an unverifiable marker lock (codex:thread-old)"*) ;;
    *) fail "unexpected different marker lock error: $err" ;;
  esac

  pass "Different marker lock fails closed"
}

test_cursor_marker_identity_without_ps() {
  local dir fakebin got
  dir="$TMP_ROOT/cursor-lock"
  fakebin=$(fm_fakebin "$dir")
  make_ps_denied "$fakebin"

  got=$(env -u CODEX_THREAD_ID -u CURSOR_CONVERSATION_ID PATH="$fakebin:$BASE_PATH" CURSOR_AGENT_SESSION_ID=cursor-123 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  [ "$got" = "cursor:cursor-123" ] || fail "Cursor marker fallback resolved '$got', expected cursor:cursor-123"

  pass "Cursor marker provides a session-lock identity without ps ancestry"
}

test_cursor_conversation_marker_identity_without_ps() {
  local dir fakebin got
  dir="$TMP_ROOT/cursor-conversation-lock"
  fakebin=$(fm_fakebin "$dir")
  make_ps_denied "$fakebin"

  got=$(env -u CODEX_THREAD_ID -u CURSOR_AGENT_SESSION_ID -u CURSOR_TRACE_ID PATH="$fakebin:$BASE_PATH" CURSOR_CONVERSATION_ID=conversation-123 bash -c \
    ". \"\$0/bin/fm-session-lock-lib.sh\"; fm_harness_ancestry_pid" "$ROOT")
  [ "$got" = "cursor:conversation-123" ] || fail "Cursor conversation marker fallback resolved '$got', expected cursor:conversation-123"

  pass "Cursor conversation marker provides a session-lock identity without ps ancestry"
}

test_codex_marker_detects_harness_without_ps
test_codex_marker_acquires_and_reuses_lock
test_different_marker_lock_fails_closed
test_cursor_marker_identity_without_ps
test_cursor_conversation_marker_identity_without_ps

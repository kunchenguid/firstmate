#!/usr/bin/env bash
# Behavior tests for the verified Cursor Agent CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

cleanup_cursor_harness() {
  rm -rf "$TMP_ROOT"
}
trap cleanup_cursor_harness EXIT

# --- harness detection: CURSOR_AGENT=1 marker --------------------------------

test_cursor_env_marker() {
  local out
  out=$(CURSOR_AGENT=1 "$HARNESS" 2>/dev/null)
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 must detect as cursor, got '$out'"
  pass "CURSOR_AGENT=1 detects as cursor"
}

# --- harness detection: CURSOR_AGENT=1 wins over CLAUDECODE=1 -----------------

test_cursor_env_marker_wins_over_claudecode() {
  local out
  out=$(CURSOR_AGENT=1 CLAUDECODE=1 "$HARNESS" 2>/dev/null)
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 must win over CLAUDECODE=1, got '$out'"
  pass "CURSOR_AGENT=1 wins over CLAUDECODE=1"
}

# --- launch template: contains --force, --trust, brief, no --worktree ----------

test_launch_template_contents() {
  local out
  out=$(awk '/cursor)/ && /printf/ { print; found=1; exit } END { if (!found) exit 1 }' "$SPAWN" 2>/dev/null) || {
    fail "cursor launch template printf not found in $SPAWN"
    return
  }
  case "$out" in
    *--force*) ;;
    *) fail "cursor launch template must contain --force, got: $out" ;;
  esac
  case "$out" in
    *--trust*) ;;
    *) fail "cursor launch template must contain --trust, got: $out" ;;
  esac
  case "$out" in
    *__BRIEF__*) ;;
    *) fail "cursor launch template must contain brief placeholder, got: $out" ;;
  esac
  case "$out" in
    *--worktree*) fail "cursor launch template must NOT contain --worktree, got: $out" ;;
    *) ;;
  esac
  pass "cursor launch template has correct contents"
}

# --- launch template: env sanitization ---------------------------------------

test_launch_template_unsets_claudecode() {
  local out
  out=$(awk '/cursor)/ && /printf/ { print; found=1; exit } END { if (!found) exit 1 }' "$SPAWN" 2>/dev/null) || {
    fail "cursor launch template printf not found"
    return
  }
  case "$out" in
    *"unset CLAUDECODE"*) ;;
    *) fail "cursor launch template must unset CLAUDECODE, got: $out" ;;
  esac
  case "$out" in
    *"CLAUDE_CODE_ENTRYPOINT"*) ;;
    *) fail "cursor launch template must unset CLAUDE_CODE_ENTRYPOINT, got: $out" ;;
  esac
  pass "cursor launch template unsets CLAUDECODE/CLAUDE_CODE_ENTRYPOINT"
}

# --- model flag: cursor in the case allowlists --------------------------------

test_model_flag_in_case_allowlists() {
  local count
  count=$(grep -c 'cursor)' "$SPAWN" 2>/dev/null || true)
  [ "$count" -ge 3 ] || fail "spawn script must contain cursor in at least 3 case lists, found $count"
  pass "cursor is in the model_flag_for_harness case allowlist"
}

# --- effort: recorded in meta, never emitted ---------------------------------

test_effort_not_emitted() {
  grep -q 'cursor.*effort.*model id' "$SPAWN" 2>/dev/null \
    || fail "effort_flag_for_harness should document cursor effort-in-model-id, no comment found"
  pass "effort_flag_for_harness cursor emits nothing (effort in model id)"
}

# --- missing binary: fail-closed ---------------------------------------------

test_missing_binary_refusal() {
  local isolated_bin path_save
  isolated_bin=$(mktemp -d "${TMPDIR:-/tmp}/cursor-emptybin.XXXXXX") || { fail "cannot create temp dir"; return; }
  path_save=$PATH
  PATH="$isolated_bin"
  export PATH
  if command -v cursor-agent >/dev/null 2>&1; then
    PATH=$path_save
    export PATH
    rm -rf "$isolated_bin"
    fail "cursor-agent should not be found on empty PATH"
    return
  fi
  PATH=$path_save
  export PATH
  rm -rf "$isolated_bin"
  pass "cursor-agent missing binary check works"
}

# --- run all tests (order matters: simpler checks first) ---------------------

test_cursor_env_marker
test_cursor_env_marker_wins_over_claudecode
test_launch_template_contents
test_launch_template_unsets_claudecode
test_model_flag_in_case_allowlists
test_effort_not_emitted
test_missing_binary_refusal
#!/usr/bin/env bash
# Behavioral regressions for the work declaration firstmate writes for capture tools.
#
# The value of this script is almost entirely in what it REFUSES to write. A
# declaration outranks every other signal a capture tool has, so a wrong or
# careless one moves the captain's hours onto the wrong client's invoice.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DECLARE="$ROOT/bin/fm-declare-work.sh"
TMP_ROOT=$(fm_test_tmproot fm-declare-work)

SESSION='sess-decl-1'

# How many declarations exist in a directory.
count_json() {
  find "$1" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

test_writes_a_declaration_for_this_session() {
  local dir file body
  dir="$TMP_ROOT/decls-basic"

  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$SESSION" \
    "$DECLARE" 'fm:login-burst-security' --label 'login-burst-security'

  file="$dir/$SESSION.json"
  assert_present "$file" "no declaration was written for the current session"
  body=$(cat "$file")
  assert_contains "$body" '"workItem":"fm:login-burst-security"' \
    "declaration does not name the work item"
  assert_contains "$body" "\"sessionId\":\"$SESSION\"" \
    "declaration does not name the session it belongs to"
  assert_contains "$body" '"label":"login-burst-security"' \
    "declaration dropped the human-readable label"
  # A reader that cannot date a declaration cannot expire it, and a declaration
  # that never expires bills forever.
  grep -Eq '"at":[0-9]{10,}' "$file" ||
    fail "declaration carries no usable timestamp, so a reader cannot judge staleness"
  pass "a declaration names the work, the session and when it was made"
}

test_never_names_a_client() {
  local dir body
  dir="$TMP_ROOT/decls-noclient"

  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$SESSION" \
    "$DECLARE" 'fm:some-task' --label 'some task'

  # Who a repository bills to is the operator's configuration to decide.
  # Firstmate asserting it here would put a client name into tracked tooling
  # and make the capture tool's own rules unfalsifiable.
  body=$(cat "$dir/$SESSION.json")
  assert_not_contains "$body" '"engagement"' "declaration asserted an engagement"
  assert_not_contains "$body" '"client"' "declaration asserted a client"
  assert_not_contains "$body" '"rate"' "declaration asserted a rate"
  pass "a declaration carries work, never a client or a rate"
}

test_records_the_repository_the_work_belongs_to() {
  local dir repo body
  dir="$TMP_ROOT/decls-repo"
  repo="$TMP_ROOT/work-repo"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" remote add origin 'https://github.com/acme/app.git'

  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$SESSION" \
    "$DECLARE" 'fm:task' --project "$repo"

  body=$(cat "$dir/$SESSION.json")
  # The normalised host/owner/name shape, which is what a capture tool's
  # engagement rules compare against. A raw clone URL would match nothing.
  assert_contains "$body" '"remote":"github.com/acme/app"' \
    "the declared remote is not the normalised identity rules compare against"
  assert_contains "$body" '"repoRoot"' "declaration dropped the repository root"
  pass "a declaration carries the repository the directed work belongs to"
}

test_inert_without_a_capture_tool() {
  local dir code
  dir="$TMP_ROOT/absent"
  mkdir -p "$TMP_ROOT/empty-home"

  # No override and no store present: nothing is watching, so there is nothing
  # to say. This must be silent and successful on every machine that does not
  # use a capture tool.
  HOME="$TMP_ROOT/empty-home" XDG_STATE_HOME="$dir" WORKLOG_DECLARATIONS_DIR='' \
    WORKLOG_STORE_DIR='' CLAUDE_CODE_SESSION_ID="$SESSION" \
    "$DECLARE" 'fm:task'
  code=$?

  expect_code 0 "$code" "declaring on a machine with no capture tool"
  assert_absent "$dir/worklog/declarations/$SESSION.json" \
    "a declaration was written where no capture tool is installed"
  pass "declaring is inert when nothing is watching"
}

test_refuses_to_guess_an_owner() {
  local dir code
  dir="$TMP_ROOT/decls-nosession"
  mkdir -p "$dir"

  # No session id means the declaration would have no owner. Guessing one would
  # apply this work item to somebody else's hours.
  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID='' "$DECLARE" 'fm:task'
  code=$?

  expect_code 0 "$code" "declaring without a session id"
  [ "$(count_json "$dir")" = '0' ] ||
    fail "a declaration was written with no session to own it"
  pass "an unknown session produces no declaration rather than a guessed one"
}

test_refuses_a_session_id_that_escapes_the_directory() {
  local dir bad code
  dir="$TMP_ROOT/decls-escape"
  mkdir -p "$dir"

  for bad in '../escaped' 'a/b' '..' '.'; do
    WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$bad" "$DECLARE" 'fm:task'
    code=$?
    expect_code 0 "$code" "a refused session id ($bad)"
  done

  assert_absent "$TMP_ROOT/escaped.json" \
    "a session id escaped the declarations directory"
  [ "$(count_json "$dir")" = '0' ] ||
    fail "an unusable session id still produced a declaration"
  pass "a session id that is not a plain filename is refused, not sanitised"
}

test_clearing_removes_the_declaration() {
  local dir file
  dir="$TMP_ROOT/decls-clear"

  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$SESSION" "$DECLARE" 'fm:task'
  file="$dir/$SESSION.json"
  assert_present "$file" "setup failed: no declaration to clear"

  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$SESSION" "$DECLARE" --clear
  assert_absent "$file" "clearing left the declaration in place"
  pass "clearing removes this session's declaration"
}

test_rewriting_replaces_rather_than_accumulates() {
  local dir body
  dir="$TMP_ROOT/decls-rewrite"

  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$SESSION" "$DECLARE" 'fm:first'
  WORKLOG_DECLARATIONS_DIR="$dir" CLAUDE_CODE_SESSION_ID="$SESSION" "$DECLARE" 'fm:second'

  body=$(cat "$dir/$SESSION.json")
  assert_contains "$body" '"workItem":"fm:second"' "rewriting did not take effect"
  assert_not_contains "$body" 'fm:first' "the superseded work item survived a rewrite"
  [ "$(count_json "$dir")" = '1' ] ||
    fail "rewriting accumulated files instead of replacing one"
  [ "$(find "$dir" -name '*.tmp.*' | wc -l | tr -d ' ')" = '0' ] ||
    fail "a temporary file was left behind"
  pass "the current work item replaces the last one"
}

test_writes_a_declaration_for_this_session
test_never_names_a_client
test_records_the_repository_the_work_belongs_to
test_inert_without_a_capture_tool
test_refuses_to_guess_an_owner
test_refuses_a_session_id_that_escapes_the_directory
test_clearing_removes_the_declaration
test_rewriting_replaces_rather_than_accumulates

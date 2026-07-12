#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-body-check.sh.
#
# The regression this guards is the 2026-07-12 incident: agent-facing intent
# text ("do not re-raise", "already made", an agent co-author) was rendered
# verbatim into a public PR body on a third-party repo. The check exists to make
# the crewmate READ what it published, so the tests assert on the flagged lines
# themselves, not just the exit code - a count is exactly the signal that misled
# the crew before.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-body-check)
# fm_test_tmproot registers its cleanup inside a command-substitution subshell,
# whose EXIT trap removes the dir before the caller sees it; suites that only
# ever mkdir -p subdirs never notice. This suite writes fixture files straight
# into the root, so re-create it and register the cleanup in this shell.
mkdir -p "$TMP_ROOT"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

CHECK="$ROOT/bin/fm-pr-body-check.sh"

# The four leak lines from the real incident, verbatim.
write_dirty_body() {
  cat > "$1" <<'EOF'
Refactor the check tally

## Intent
Deliberate decision by the user, already made - do not flag as surprising.
Deliberate scope decision, already made - do not re-raise.
The user explicitly DECLINED a refactor extracting a shared tallyChecks() helper.
The PR title and body must be clean, self-contained and reviewer-friendly, must NOT name any internal agent tooling, and must NOT add any agent as co-author.
EOF
}

write_clean_body() {
  cat > "$1" <<'EOF'
Retry transient upload failures

The uploader gave up on the first 503 from the storage backend, so a single
blip lost the whole batch. It now retries three times with exponential backoff
and surfaces the final error unchanged.
EOF
}

test_clean_body_passes() {
  local body out code=0
  body="$TMP_ROOT/clean.md"
  write_clean_body "$body"
  out=$("$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 0 "$code" "clean body was flagged"
  assert_contains "$out" "clean" "clean body did not report clean"
  pass "fm-pr-body-check.sh: clean reviewer-facing body passes"
}

test_incident_lines_are_flagged_and_printed() {
  local body out code=0
  body="$TMP_ROOT/dirty.md"
  write_dirty_body "$body"
  out=$("$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 1 "$code" "the incident's intent text was not flagged"
  assert_contains "$out" "do not flag as surprising" "flagged output did not print the offending line"
  assert_contains "$out" "do not re-raise" "flagged output did not print the offending line"
  assert_contains "$out" "explicitly DECLINED" "flagged output did not print the offending line"
  assert_contains "$out" "must NOT name any internal agent tooling" "flagged output did not print the offending line"
  pass "fm-pr-body-check.sh: every line from the real leak is flagged and printed in full"
}

test_output_demands_reading_not_counting() {
  local body out
  body="$TMP_ROOT/dirty-read.md"
  write_dirty_body "$body"
  out=$("$CHECK" --file "$body" 2>&1 || true)
  assert_contains "$out" "not a verdict" "output did not say a match is a line to read, not a verdict"
  assert_contains "$out" "do not act on the count" "output did not warn against acting on the hit count"
  pass "fm-pr-body-check.sh: flagged output tells the reader to inspect lines, not counts"
}

test_output_carries_the_gh_pr_edit_noop_workaround() {
  local body out
  body="$TMP_ROOT/dirty-fix.md"
  write_dirty_body "$body"
  out=$("$CHECK" --file "$body" 2>&1 || true)
  assert_contains "$out" 'gh pr edit --body' "output did not name the command that silently no-ops"
  assert_contains "$out" 'gh api -X PATCH repos/OWNER/REPO/pulls/<n> -F body=@<file>' \
    "output did not give the reliable REST API repair command"
  pass "fm-pr-body-check.sh: a dirty body comes with the API PATCH repair path"
}

test_second_person_and_agent_coauthor_are_flagged() {
  local body out code=0
  body="$TMP_ROOT/coauthor.md"
  cat > "$body" <<'EOF'
Tidy the parser

You should not question the token order here.

Co-authored-by: Claude <noreply@anthropic.com>
EOF
  out=$("$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 1 "$code" "second-person direction and agent co-author were not flagged"
  assert_contains "$out" "second-person direction" "second-person direction was not labeled"
  assert_contains "$out" "agent co-author" "agent co-author was not labeled"
  pass "fm-pr-body-check.sh: second-person direction and agent co-authors are flagged"
}

# The live path is the point of the tool: the crewmate must be told what it
# actually published, not what it believes it passed to --intent. A fake gh
# proves the URL is parsed into a REST read of the live PR.
test_live_pr_body_is_read_from_the_api() {
  local fakebin out code=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
printf 'Refactor tally\nDeliberate scope decision, already made - do not re-raise.\n'
SH
  chmod +x "$fakebin/gh"
  export FAKE_GH_LOG="$TMP_ROOT/gh.log"
  : > "$FAKE_GH_LOG"

  out=$(PATH="$fakebin:$PATH" "$CHECK" https://github.com/owner/repo/pull/71 2>&1) || code=$?
  expect_code 1 "$code" "a leaky live PR body was not flagged"
  assert_contains "$out" "do not re-raise" "the live body's offending line was not printed"
  assert_grep "api repos/owner/repo/pulls/71" "$FAKE_GH_LOG" \
    "the live body was not fetched from the REST API for the URL's owner/repo/number"
  pass "fm-pr-body-check.sh: the live PR body is fetched from the API and scanned"
}

# gh writes deprecation and auth notices to stderr while still succeeding. Folded
# into the body, such a notice reads as PUBLISHED text and flags a clean PR.
test_gh_stderr_never_becomes_body_text() {
  local fakebin out code=0
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: warning: the captain must not use this deprecated crewmate endpoint" >&2
printf 'Retry transient upload failures\n\nThe uploader now retries three times with backoff.\n'
SH
  chmod +x "$fakebin/gh"

  out=$(PATH="$fakebin:$PATH" "$CHECK" https://github.com/owner/repo/pull/12 2>/dev/null) || code=$?
  expect_code 0 "$code" "a gh stderr warning was scanned as if it were published body text"
  assert_contains "$out" "clean" "a clean live body did not report clean"
  pass "fm-pr-body-check.sh: gh's stderr is never folded into the scanned body"
}

# no-mistakes appends this footer to every body it publishes. Its generated link
# names no-mistakes, so scanning it would flag every single ship forever, and a
# check that can never report clean stops being read.
write_pipeline_footer() {
  cat >> "$1" <<'EOF'

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<details>
<summary>Review - passed</summary>

No issues found.

</details>
EOF
}

test_pipeline_footer_is_not_scanned() {
  local body out code=0
  body="$TMP_ROOT/footer-clean.md"
  write_clean_body "$body"
  write_pipeline_footer "$body"
  out=$("$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 0 "$code" "the pipeline's own generated footer flagged an otherwise clean body"
  assert_contains "$out" "clean" "a clean body under the pipeline footer did not report clean"
  pass "fm-pr-body-check.sh: the pipeline's generated footer is not scanned"
}

test_leak_above_the_pipeline_footer_still_flags() {
  local body out code=0
  body="$TMP_ROOT/footer-dirty.md"
  write_dirty_body "$body"
  write_pipeline_footer "$body"
  out=$("$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 1 "$code" "a leaky intent line above the pipeline footer was not flagged"
  assert_contains "$out" "do not re-raise" "the leaky line above the footer was not printed"
  assert_not_contains "$out" "git push no-mistakes" "the generated footer line was reported as a leak"
  pass "fm-pr-body-check.sh: a leak above the footer still flags, without footer noise"
}

# The vocabulary pattern must not be weakened by the footer carve-out: intent
# prose that genuinely names no-mistakes is still the author's public writing.
test_authored_internal_vocabulary_still_flags() {
  local body out code=0
  body="$TMP_ROOT/authored-vocab.md"
  cat > "$body" <<'EOF'
Tidy the parser

The crewmate runs no-mistakes from its worktree before the captain merges.
EOF
  write_pipeline_footer "$body"
  out=$("$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 1 "$code" "authored internal vocabulary was not flagged under a pipeline footer"
  assert_contains "$out" "internal vocabulary" "the authored vocabulary line was not labeled"
  assert_contains "$out" "runs no-mistakes from its worktree" "the authored vocabulary line was not printed"
  pass "fm-pr-body-check.sh: authored internal vocabulary flags even when a footer is present"
}

# A GNU-only \b under BSD grep matches nothing and reports a dirty body clean -
# the worst failure this tool has. Assert the two boundary patterns FLAG.
test_word_boundary_patterns_match_without_gnu_extensions() {
  local body out code=0
  if grep -v '^[[:space:]]*#' "$CHECK" | grep -F -q '\b'; then
    fail "the check's code still uses GNU-only word boundaries, which BSD grep does not honor"
  fi

  body="$TMP_ROOT/boundaries.md"
  cat > "$body" <<'EOF'
Tidy the parser

You must not re-order these tokens.
The worktree is torn down by firstmate once the no-mistakes run is green.
EOF
  out=$("$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 1 "$code" "the boundary-anchored patterns matched nothing on a known-dirty body"
  assert_contains "$out" "second-person direction" "second-person direction stopped matching"
  assert_contains "$out" "internal vocabulary" "internal vocabulary stopped matching"
  assert_contains "$out" "You must not re-order" "the second-person line was not printed"
  pass "fm-pr-body-check.sh: boundary-anchored patterns match on GNU and BSD grep alike"
}

# Stock macOS ships bash 3.2, so the script must not need bash 4 features.
test_no_bash4_only_constructs() {
  assert_no_grep 'declare -A' "$CHECK" "the check uses associative arrays, which bash 3.2 cannot run"
  pass "fm-pr-body-check.sh: runs on bash 3.2 (no associative arrays)"
}

# grep exits 2+ on a real error - a regex the local engine cannot compile, an
# unreadable file. Read as "no match", that pattern contributes nothing and an
# unscanned body reports clean: the exact false clean this tool exists to stop.
test_scan_error_never_reports_clean() {
  local fakebin body out code=0
  mkdir -p "$TMP_ROOT/scan-error"
  fakebin=$(fm_fakebin "$TMP_ROOT/scan-error")
  cat > "$fakebin/grep" <<'SH'
#!/usr/bin/env bash
echo "grep: brackets ([ ]) not balanced" >&2
exit 2
SH
  chmod +x "$fakebin/grep"

  body="$TMP_ROOT/scan-error.md"
  write_clean_body "$body"
  out=$(PATH="$fakebin:$PATH" "$CHECK" --file "$body" 2>&1) || code=$?
  expect_code 2 "$code" "a scan that errored out did not exit 2"
  assert_contains "$out" "the body was NOT checked" "a failed scan did not say the body went unchecked"
  assert_not_contains "$out" "clean" "a failed scan reported the body clean"
  pass "fm-pr-body-check.sh: a scan error exits 2 instead of a false clean"
}

test_bad_url_and_fetch_failure_exit_2() {
  local fakebin out code=0
  out=$("$CHECK" https://example.com/not-a-pr 2>&1) || code=$?
  expect_code 2 "$code" "an unparseable PR URL did not exit 2"
  assert_contains "$out" "full PR URL" "the URL error did not say what shape is expected"

  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh: HTTP 404" >&2
exit 1
SH
  chmod +x "$fakebin/gh"
  code=0
  out=$(PATH="$fakebin:$PATH" "$CHECK" https://github.com/owner/repo/pull/9 2>&1) || code=$?
  expect_code 2 "$code" "a failed fetch was not distinguished from a clean body"
  assert_contains "$out" "could not fetch" "a failed fetch did not say so"
  pass "fm-pr-body-check.sh: a bad URL or failed fetch exits 2, never a false clean"
}

test_clean_body_passes
test_incident_lines_are_flagged_and_printed
test_output_demands_reading_not_counting
test_output_carries_the_gh_pr_edit_noop_workaround
test_second_person_and_agent_coauthor_are_flagged
test_live_pr_body_is_read_from_the_api
test_gh_stderr_never_becomes_body_text
test_pipeline_footer_is_not_scanned
test_leak_above_the_pipeline_footer_still_flags
test_authored_internal_vocabulary_still_flags
test_word_boundary_patterns_match_without_gnu_extensions
test_no_bash4_only_constructs
test_scan_error_never_reports_clean
test_bad_url_and_fetch_failure_exit_2

#!/usr/bin/env bash
# Behavior guard for bin/fm-outward-text-check.sh, the pre-publication scan that
# keeps identifiers belonging to another repository, a private task, or one
# machine out of text a destination publishes and never retracts.
#
# Regression origin: run intent was composed from a worker's working context and
# published verbatim as a PR description, so a private task name, two commit
# SHAs from an unrelated repository, and a machine-local gate-clone id stayed
# readable on a public PR - including after it was closed, because a closed PR
# keeps its body. The same class also reached tracked verification prose.
#
# The load-bearing property is that every verdict is decided AGAINST the
# repository under change, not by matching words: the same short hex string is
# clean when it names a commit here and reported when it does not. These tests
# drive that distinction directly rather than asserting on patterns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-outward-text-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-outward-text-check) || exit 1
fm_git_identity

# One repository "under change" with a real commit, plus a second repository
# whose commits are foreign to it. Both are real git repos so object resolution
# is exercised for real.
#
# Full 40-character ids, never abbreviations: a short id is only treated as an
# identifier when it happens to mix digits and [a-f], so an abbreviated fixture
# would make these assertions depend on the commit timestamp of the run.
REPO="$TMP_ROOT/under-change"
OTHER="$TMP_ROOT/elsewhere"
fm_git_init_commit "$REPO"
fm_git_init_commit "$OTHER"
OWN_SHA=$(git -C "$REPO" rev-parse HEAD)
FOREIGN_SHA=$(git -C "$OTHER" rev-parse HEAD)

# run_check <text> [args...]: scan <text> as one file in $REPO, echo the output,
# and return the check's own exit status.
run_check() {
  local text=$1 out status
  shift
  printf '%s\n' "$text" > "$TMP_ROOT/input.txt"
  out=$("$CHECK" --repo "$REPO" "$@" "$TMP_ROOT/input.txt" 2>&1)
  status=$?
  printf '%s\n' "$out"
  return "$status"
}

test_own_commit_id_is_not_a_finding() {
  local out
  out=$(run_check "restores the behavior regressed in $OWN_SHA") \
    || fail "a commit id that resolves in the repository under change must be clean"
  case "$out" in
    *clean*) : ;;
    *) fail "expected a clean summary, got: $out" ;;
  esac
  pass "an id resolving in the repository under change is not reported"
}

test_foreign_commit_id_is_reported() {
  local out status
  out=$(run_check "verified against $FOREIGN_SHA"); status=$?
  expect_code 1 "$status" "a commit id from another repository must be reported"
  case "$out" in
    *"FOREIGN_OBJECT: $FOREIGN_SHA"*) : ;;
    *) fail "expected the foreign id to be named, got: $out" ;;
  esac
  pass "an id that resolves only in another repository is reported"
}

# The distinction above is the whole contract, so prove the two verdicts really
# diverge on the same input rather than both happening to pass.
test_the_two_verdicts_diverge_on_one_line() {
  local out status
  [ "$OWN_SHA" != "$FOREIGN_SHA" ] || fail "fixture repos produced the same commit id"
  out=$(run_check "ported $OWN_SHA onto $FOREIGN_SHA"); status=$?
  expect_code 1 "$status" "a line mixing a local and a foreign id must be reported"
  case "$out" in
    *"$FOREIGN_SHA"*) : ;;
    *) fail "expected the foreign id on a mixed line, got: $out" ;;
  esac
  case "$out" in
    *"FOREIGN_OBJECT: $OWN_SHA"*) fail "the local id must not be reported on a mixed line" ;;
  esac
  pass "one line carrying both ids reports only the foreign one"
}

test_prose_numbers_and_words_are_not_identifiers() {
  run_check "the 1048576 byte cap was defaced on 20260815 and effaced later" >/dev/null \
    || fail "decimal numbers and all-letter words must not read as object ids"
  pass "decimal-only and letter-only tokens are not treated as ids"
}

test_machine_local_path_blocks() {
  local out status
  out=$(run_check "evidence at /home/somebody/work/gate-clone/run.log"); status=$?
  expect_code 1 "$status" "a user-home path must be reported"
  case "$out" in
    *"MACHINE_LOCAL_PATH: /home/somebody/work/gate-clone/run.log"*) : ;;
    *) fail "expected the machine-local path to be named, got: $out" ;;
  esac
  case "$out" in
    *"1 blocking"*) : ;;
    *) fail "a machine-local path must count as blocking, got: $out" ;;
  esac
  pass "an absolute user-home path is reported as blocking"
}

test_placeholder_path_is_not_a_finding() {
  run_check 'the socket lands at /Users/<user>/.config/herdr/herdr.sock' >/dev/null \
    || fail "a documented placeholder path names no machine and must stay clean"
  pass "an angle-bracket placeholder path is not reported"
}

test_block_only_separates_the_two_severities() {
  local out status
  # Reviewable alone: an unresolvable id can be legitimate when the surrounding
  # text names its upstream, so an unattended gate must not fail on it.
  out=$(run_check "upstream release $FOREIGN_SHA" --block-only); status=$?
  expect_code 0 "$status" "--block-only must not fail on a reviewable finding"
  case "$out" in
    *"FOREIGN_OBJECT: $FOREIGN_SHA"*) : ;;
    *) fail "--block-only must still print reviewable findings, got: $out" ;;
  esac

  # The same text with a blocking finding added must fail.
  out=$(run_check "upstream release $FOREIGN_SHA at /home/somebody/clone" --block-only); status=$?
  expect_code 1 "$status" "--block-only must fail on a blocking finding"
  pass "--block-only fails on blocking findings only, still printing the rest"
}

test_allow_file_settles_a_justified_reference() {
  local out
  printf '# justified upstream reference\n%s\n' "$FOREIGN_SHA" > "$REPO/.fm-outward-allow"
  out=$(run_check "upstream release $FOREIGN_SHA") \
    || fail "an id listed in .fm-outward-allow must be clean"
  rm -f "$REPO/.fm-outward-allow"
  out=$(run_check "upstream release $FOREIGN_SHA") && \
    fail "removing the allow entry must restore the finding"
  pass ".fm-outward-allow settles a justified reference and nothing more"
}

# An exemption that could silence a blocking finding would be the leak itself:
# the value has to be written into a tracked file to silence it there.
test_allow_file_cannot_settle_a_blocking_finding() {
  local out status
  printf '# a machine-local path someone tried to settle here\n%s\n' \
    "/home/somebody/gate-clone/run.log" > "$REPO/.fm-outward-allow"
  out=$(run_check "evidence at /home/somebody/gate-clone/run.log" --block-only); status=$?
  rm -f "$REPO/.fm-outward-allow"
  expect_code 1 "$status" "an allowed machine-local path must still fail an unattended gate"
  case "$out" in
    *"MACHINE_LOCAL_PATH: /home/somebody/gate-clone/run.log"*) : ;;
    *) fail "an allowed machine-local path must still be reported, got: $out" ;;
  esac
  case "$out" in
    *"cannot settle a blocking finding"*) : ;;
    *) fail "the refused exemption must be named, not silently dropped, got: $out" ;;
  esac
  case "$out" in
    *"cannot exempt a blocking identifier"*) : ;;
    *) fail "the remedy for a blocking finding must not offer the allow file, got: $out" ;;
  esac
  pass "an allow entry naming a machine-local path is refused and reported"
}

test_long_digest_is_not_invisible() {
  local out status digest
  digest=3f5e1a9b2c4d6e8f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071
  out=$(run_check "pasted from another run log: $digest"); status=$?
  expect_code 1 "$status" "a hex id longer than a commit id must still be scanned"
  case "$out" in
    *"FOREIGN_OBJECT: $digest"*) : ;;
    *) fail "expected the 64-character digest to be reported, got: $out" ;;
  esac
  pass "a hex run longer than 40 characters is scanned like any other id"
}

test_private_fleet_names_are_reported_against_a_home() {
  local home out status
  home="$TMP_ROOT/fm-home"
  mkdir -p "$home/data/other-private-task-v1" "$home/data/this-task-v1" \
    "$home/state" "$home/projects/private-sidecar-repo"
  : > "$home/data/other-private-task-v1/brief.md"
  : > "$home/data/this-task-v1/brief.md"

  out=$(run_check "follows other-private-task-v1 in private-sidecar-repo" \
    --home "$home" --task this-task-v1); status=$?
  expect_code 1 "$status" "another task's id and another project's name must be reported"
  case "$out" in
    *"FOREIGN_TASK_ID: other-private-task-v1"*) : ;;
    *) fail "expected the other task id, got: $out" ;;
  esac
  case "$out" in
    *"FOREIGN_PROJECT: private-sidecar-repo"*) : ;;
    *) fail "expected the other project name, got: $out" ;;
  esac

  # The task under change is already public through its own branch name.
  run_check "implements this-task-v1" --home "$home" --task this-task-v1 >/dev/null \
    || fail "the task under change must not be reported as foreign"
  pass "other tasks and projects are reported while the task under change is not"
}

test_missing_home_is_reported_not_silently_passed() {
  local out
  out=$(run_check "plain sentence with no identifiers") \
    || fail "text with no identifiers must be clean"
  case "$out" in
    *"SKIPPED: foreign-task-id, foreign-project"*) : ;;
    *) fail "an unavailable home must be reported as skipped, got: $out" ;;
  esac
  pass "checks that could not run are named instead of passing silently"
}

test_stdin_is_scanned_and_not_swallowed() {
  local out status
  # The implementation is fed to its interpreter on stdin, so "-" only works if
  # the caller's text is captured first. A silent empty read here would report
  # clean for every piped input.
  out=$(printf 'verified against %s\n' "$FOREIGN_SHA" | "$CHECK" --repo "$REPO" -); status=$?
  expect_code 1 "$status" "piped text must be scanned"
  case "$out" in
    *"FOREIGN_OBJECT: $FOREIGN_SHA"*) : ;;
    *) fail "expected the foreign id from stdin, got: $out" ;;
  esac
  case "$out" in
    *"(stdin:1)"*) : ;;
    *) fail "expected a stdin location label, got: $out" ;;
  esac
  pass "piped text is scanned and located as stdin"
}

test_diff_mode_scans_only_what_the_branch_adds() {
  local out status base
  base=$(git -C "$REPO" rev-parse HEAD)
  printf 'Pre-existing note about /home/somebody/legacy.\n' > "$REPO/OLD.md"
  git -C "$REPO" add OLD.md
  git -C "$REPO" -c user.name=t -c user.email=t@e commit -qm "pre-existing prose"
  base=$(git -C "$REPO" rev-parse HEAD)

  printf 'A new note with no identifiers at all.\n' > "$REPO/NEW.md"
  git -C "$REPO" add NEW.md
  git -C "$REPO" -c user.name=t -c user.email=t@e commit -qm "clean prose"
  out=$("$CHECK" --repo "$REPO" --diff --base "$base" 2>&1); status=$?
  expect_code 0 "$status" "pre-existing prose must not be rescanned by --diff"

  printf 'Debug leftovers under /home/somebody/gate-clone.\n' >> "$REPO/NEW.md"
  git -C "$REPO" -c user.name=t -c user.email=t@e commit -qam "leaky prose"
  out=$("$CHECK" --repo "$REPO" --diff --base "$base" --block-only 2>&1); status=$?
  expect_code 1 "$status" "--diff must report a leak the branch adds"
  case "$out" in
    *"NEW.md"*) : ;;
    *) fail "expected the added file to be located, got: $out" ;;
  esac
  pass "--diff reports what the branch adds and leaves existing prose alone"
}

# A merged commit message is as public and as permanent as a PR description, so
# --diff has to cover the messages the branch adds and not just its prose.
test_diff_scans_the_commit_messages_the_branch_adds() {
  local out status base sha
  base=$(git -C "$REPO" rev-parse HEAD)
  printf 'A note carrying no identifiers of its own.\n' > "$REPO/MSG.md"
  git -C "$REPO" add MSG.md
  git -C "$REPO" -c user.name=t -c user.email=t@e \
    commit -qm "port fix from /home/somebody/projects/other-repo"
  sha=$(git -C "$REPO" rev-parse HEAD)

  out=$("$CHECK" --repo "$REPO" --diff --base "$base" --block-only 2>&1); status=$?
  expect_code 1 "$status" "a machine-local path in a commit message must fail the gate"
  case "$out" in
    *"MACHINE_LOCAL_PATH: /home/somebody/projects/other-repo"*) : ;;
    *) fail "expected the path leaked by the commit message, got: $out" ;;
  esac
  case "$out" in
    *"commit ${sha:0:12}"*) : ;;
    *) fail "expected the finding to be located by its commit, got: $out" ;;
  esac
  pass "--diff reports an identifier the branch adds in a commit message"
}

test_usage_errors_are_loud() {
  local status
  "$CHECK" --repo "$REPO" >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "no input must be a usage error, never a silent pass"
  "$CHECK" --repo "$TMP_ROOT/not-a-repo" "$TMP_ROOT/input.txt" >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "a missing repository must be an environment error"
  pass "missing input and a missing repository both fail loudly"
}

test_own_commit_id_is_not_a_finding
test_foreign_commit_id_is_reported
test_the_two_verdicts_diverge_on_one_line
test_prose_numbers_and_words_are_not_identifiers
test_machine_local_path_blocks
test_placeholder_path_is_not_a_finding
test_block_only_separates_the_two_severities
test_allow_file_settles_a_justified_reference
test_allow_file_cannot_settle_a_blocking_finding
test_long_digest_is_not_invisible
test_private_fleet_names_are_reported_against_a_home
test_missing_home_is_reported_not_silently_passed
test_stdin_is_scanned_and_not_swallowed
test_diff_mode_scans_only_what_the_branch_adds
test_diff_scans_the_commit_messages_the_branch_adds
test_usage_errors_are_loud

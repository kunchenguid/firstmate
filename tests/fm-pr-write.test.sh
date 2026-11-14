#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-write.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-write.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-write-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
WROTE="$TMP_ROOT/wrote"
PR=https://github.com/o/r/pull/7
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
BODY="$TMP_ROOT/body.md"
printf 'Follow-up to https://github.com/o/r/pull/9\n' > "$BODY"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "api user --jq .login") printf '%s\n' "${GH_HOST:-}" > "$WROTE.read"; [ -z "${FAKE_ACCOUNT:-}" ] || printf '%s\n' "$FAKE_ACCOUNT" ;;
  "api repos/o/r/pulls/7 --jq .user.login") printf '%s\n' "$FAKE_AUTHOR" ;;
  "pr edit"*|"pr comment"*|"pr review"*) printf '%s\n' "$*" > "$WROTE"; printf '%s\n' "${GH_HOST:-}" > "$WROTE.host" ;;
  "api graphql -f query=query"*) printf '%s\n' "${FAKE_THREAD_PR:-}" ;;
  "api graphql -f query=mutation"*) printf '%s\n' "$*" > "$WROTE" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

reset_home() {
  rm -f "$HOME_DIR/config/pr-author-write-guard" "$HOME_DIR/state/"*.meta "$WROTE" "$WROTE".*
}

run_write() {  # <account> <author>
  FM_HOME=$HOME_DIR FAKE_ACCOUNT=$1 FAKE_AUTHOR=$2 PATH="$FAKEBIN:$PATH" WROTE=$WROTE \
    "$SCRIPT" "$PR" edit --body-file "$BODY"
}

test_guard_off_runs_write_on_foreign_pr() {
  local status=0
  reset_home
  run_write owner someone-else 2>/dev/null || status=$?
  expect_code 0 "$status" "write with the guard off"
  assert_present "$WROTE" "with the guard off the write must run on any PR"
  pass "guard off: a write on another author's PR runs unchecked"
}

test_guard_on_refuses_foreign_pr() {
  local status=0 err
  reset_home
  : > "$HOME_DIR/config/pr-author-write-guard"
  err=$(run_write owner someone-else 2>&1) || status=$?
  expect_code 3 "$status" "write on another author's PR"
  assert_absent "$WROTE" "the write must not run on another author's PR"
  assert_contains "$err" "is by someone-else, not owner" "the refusal must name the author and account"
  assert_contains "$err" "owner decision" "the refusal must park the write as an owner decision"
  pass "guard on: a write on another author's PR is refused as an owner decision"
}

test_guard_on_allows_owner_pr() {
  local status=0
  reset_home
  : > "$HOME_DIR/config/pr-author-write-guard"
  run_write owner owner 2>/dev/null || status=$?
  expect_code 0 "$status" "write on the owner's PR"
  assert_present "$WROTE" "the write must run on the owner's own PR"
  pass "guard on: a write on the owner's PR runs"
}

test_guard_on_allows_task_pr() {
  local status=0
  reset_home
  : > "$HOME_DIR/config/pr-author-write-guard"
  printf 'kind=ship\npr=%s\npr_head=abc\n' "$PR" > "$HOME_DIR/state/t1.meta"
  run_write owner bot-account 2>/dev/null || status=$?
  expect_code 0 "$status" "write on a PR a task of this home recorded"
  assert_present "$WROTE" "the write must run on a PR this home's task opened"
  pass "guard on: a write on a PR this home's task recorded runs"
}

test_guard_on_refuses_unreadable_account() {
  local status=0 err
  reset_home
  : > "$HOME_DIR/config/pr-author-write-guard"
  err=$(run_write '' someone-else 2>&1) || status=$?
  expect_code 3 "$status" "write when the signed-in account cannot be read"
  assert_absent "$WROTE" "the write must not run when the account cannot be read"
  assert_contains "$err" "could not read the account" "the refusal must name the unreadable account"
  pass "guard on: an unreadable account refuses the write"
}

test_write_targets_the_checked_url() {
  local status=0
  reset_home
  : > "$HOME_DIR/config/pr-author-write-guard"
  run_write owner owner 2>/dev/null || status=$?
  expect_code 0 "$status" "write on the owner's PR"
  assert_contains "$(cat "$WROTE")" "pr edit $PR --body-file $BODY" "the checked URL must be the write's PR target"
  pass "the write targets exactly the checked URL"
}

run_action() {  # <args...>
  FM_HOME=$HOME_DIR FAKE_ACCOUNT=owner FAKE_AUTHOR=owner FAKE_THREAD_PR=${FAKE_THREAD_PR:-} PATH="$FAKEBIN:$PATH" WROTE=$WROTE \
    "$SCRIPT" "$PR" "$@"
}

test_every_action_targets_only_the_checked_url() {
  local status=0 want
  reset_home
  : > "$HOME_DIR/config/pr-author-write-guard"
  run_action edit --title "Fix 12" --body-file "$BODY" 2>/dev/null || status=$?
  expect_code 0 "$status" "edit"
  want="pr edit $PR --title Fix 12 --body-file $BODY"
  [ "$(cat "$WROTE")" = "$want" ] || fail "edit argv: $(cat "$WROTE")"
  run_action comment --body-file "$BODY" 2>/dev/null || status=$?
  want="pr comment $PR --body-file $BODY"
  [ "$(cat "$WROTE")" = "$want" ] || fail "comment argv: $(cat "$WROTE")"
  run_action review --request-changes --body-file "$BODY" 2>/dev/null || status=$?
  want="pr review $PR --request-changes --body-file $BODY"
  [ "$(cat "$WROTE")" = "$want" ] || fail "review argv: $(cat "$WROTE")"
  pass "every action builds its gh call from the checked URL; PR links in content pass through"
}

test_resolve_thread_checks_the_thread_pr() {
  local status=0
  reset_home
  FAKE_THREAD_PR=https://github.com/o/r/pull/9 run_action resolve-thread PRRT_x 2>/dev/null || status=$?
  expect_code 3 "$status" "resolve-thread on another PR's thread"
  assert_absent "$WROTE" "no mutation may be sent for another PR's thread"
  status=0
  FAKE_THREAD_PR=$PR run_action resolve-thread PRRT_x 2>/dev/null || status=$?
  expect_code 0 "$status" "resolve-thread on this PR's thread"
  assert_contains "$(cat "$WROTE")" "resolveReviewThread" "the mutation must be sent"
  pass "resolve-thread refuses a thread of another PR"
}

test_unknown_action_or_option_is_refused() {
  local status=0
  reset_home
  run_action merge 2>/dev/null || status=$?
  expect_code 2 "$status" "unknown action"
  status=0
  run_action edit --body-file "$BODY" https://github.com/o/r/pull/9 2>/dev/null || status=$?
  expect_code 2 "$status" "edit with a stray PR target"
  assert_absent "$WROTE" "no write may run for a refused usage"
  pass "an unknown action or option is refused"
}

test_author_reads_use_the_url_host() {
  local status=0
  reset_home
  : > "$HOME_DIR/config/pr-author-write-guard"
  FM_HOME=$HOME_DIR FAKE_ACCOUNT=owner FAKE_AUTHOR=owner GH_HOST=ghe.example.com PATH="$FAKEBIN:$PATH" WROTE=$WROTE \
    "$SCRIPT" "$PR" edit --body-file "$BODY" 2>/dev/null || status=$?
  expect_code 0 "$status" "write on a github.com PR with GH_HOST set to another host"
  assert_contains "$(cat "$WROTE.read")" "github.com" "the author read must use the URL host"
  pass "author reads use the URL host, not an inherited GH_HOST"
}

fm_test_run \
  test_guard_off_runs_write_on_foreign_pr \
  test_guard_on_refuses_foreign_pr \
  test_guard_on_allows_owner_pr \
  test_guard_on_allows_task_pr \
  test_guard_on_refuses_unreadable_account \
  test_write_targets_the_checked_url \
  test_every_action_targets_only_the_checked_url \
  test_resolve_thread_checks_the_thread_pr \
  test_unknown_action_or_option_is_refused \
  test_author_reads_use_the_url_host

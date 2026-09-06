#!/usr/bin/env bash
# Tests for bin/fm-pr-campaign.sh: the operator surface for a parallel-PR
# merge campaign (digest, restack, merge-next), which must stay read-only
# except for base retargets and must never merge.
#
# Matrix:
#   (a) digest prints one compact line per open PR with number, base, head,
#       mergeable, check summary, and the full URL, oldest first
#   (b) digest distinguishes pending, fail, all-green, and none check states
#   (c) digest reports a null mergeable as unknown, from bare key: value lines
#   (d) digest reads the PR list from an api_response body envelope
#   (e) digest refuses an invalid repo and a missing --repo without network
#   (f) merge-next prints the first eligible PR in listed order
#   (g) merge-next defaults to all open PRs oldest first
#   (h) merge-next skips unmergeable, dirty, pending-check, and failing PRs
#   (i) merge-next accepts a mergeable PR with no checks as checks:none
#   (j) merge-next prints NONE and exits 1 when nothing is eligible
#   (k) merge-next prints NONE and exits 1 when no PR is open
#   (l) restack retargets each higher PR onto the head below it and prints
#       the resulting stack bottom-first
#   (m) restack leaves an already-correct base alone and the bottom PR untouched
#   (n) restack refuses duplicate and invalid PR numbers without editing
#   (o) --help exits 0 and an unknown subcommand exits 2
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CAMPAIGN="$ROOT/bin/fm-pr-campaign.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-campaign-tests)

REPO=acme/widgets
URL_BASE="https://github.com/$REPO/pull"
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_C=cccccccccccccccccccccccccccccccccccccccc
SHA_D=dddddddddddddddddddddddddddddddddddddddd
SHA_E=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

make_case() {
  local case_dir=$1 fakebin=$1/fakebin
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
# Mock answering canned fixture data per REST path; stdout only.
fail() { echo "mock: unexpected gh-axi call: $*" >&2; exit 1; }
[ "${1-}" = api ] || {
  case "${1:-} ${2:-}" in
    "pr edit")
      printf '%s\n' "$*" >> "$FM_TEST_EDIT_LOG"
      exit 0
      ;;
  esac
  fail "$@"
}
path=$2
case "$path" in
  /repos/acme/widgets/pulls\?state=open*)
    printf 'api_response:\n  body: "11\\n12\\n13\\n14\\n15"\n  truncated: false\n'
    ;;
  /repos/acme/empty/pulls\?state=open*)
    printf 'api_response:\n  body: ""\n  truncated: false\n'
    ;;
  /repos/acme/widgets/pulls/11)
    printf 'number: 11\nbase: main\nhead: feat-a\nsha: %s\nmergeable: true\nmstate: clean\nstate: open\nurl: "%s/11"\n' "$FM_TEST_SHA_A" "$FM_TEST_URL_BASE"
    ;;
  /repos/acme/widgets/pulls/12)
    printf 'number: 12\nbase: feat-a\nhead: feat-b\nsha: %s\nmergeable: true\nmstate: clean\nstate: open\nurl: "%s/12"\n' "$FM_TEST_SHA_B" "$FM_TEST_URL_BASE"
    ;;
  /repos/acme/widgets/pulls/13)
    printf 'number: 13\nbase: main\nhead: feat-c\nsha: %s\nmergeable: false\nmstate: dirty\nstate: open\nurl: "%s/13"\n' "$FM_TEST_SHA_C" "$FM_TEST_URL_BASE"
    ;;
  /repos/acme/widgets/pulls/14)
    printf 'number: 14\nbase: main\nhead: feat-d\nsha: %s\nmergeable: null\nmstate: unknown\nstate: open\nurl: "%s/14"\n' "$FM_TEST_SHA_D" "$FM_TEST_URL_BASE"
    ;;
  /repos/acme/widgets/pulls/15)
    printf 'number: 15\nbase: main\nhead: feat-e\nsha: %s\nmergeable: true\nmstate: clean\nstate: open\nurl: "%s/15"\n' "$FM_TEST_SHA_E" "$FM_TEST_URL_BASE"
    ;;
  /repos/acme/widgets/commits/*/check-runs)
    case "$path" in
      *"$FM_TEST_SHA_A"*) printf 'api_response:\n  body: "completed/success"\n  truncated: false\n' ;;
      *"$FM_TEST_SHA_B"*) printf 'api_response:\n  body: "in_progress/null"\n  truncated: false\n' ;;
      *"$FM_TEST_SHA_C"*) printf 'api_response:\n  body: "completed/failure"\n  truncated: false\n' ;;
      *) printf 'api_response:\n  body: ""\n  truncated: false\n' ;;
    esac
    ;;
  /repos/acme/widgets/commits/*/status)
    case "$path" in
      *"$FM_TEST_SHA_A"*) printf 'success/1\n' ;;
      *"$FM_TEST_SHA_C"*) printf 'failure/1\n' ;;
      *) printf 'pending/0\n' ;;
    esac
    ;;
  *) fail "$@" ;;
esac
SH
  chmod +x "$fakebin/gh-axi"
  : > "$case_dir/edit.log"
  printf '%s\n' "$case_dir"
}

run_campaign() {
  local case_dir=$1; shift
  FM_TEST_SHA_A=$SHA_A FM_TEST_SHA_B=$SHA_B FM_TEST_SHA_C=$SHA_C \
  FM_TEST_SHA_D=$SHA_D FM_TEST_SHA_E=$SHA_E FM_TEST_URL_BASE=$URL_BASE \
  FM_TEST_EDIT_LOG="$case_dir/edit.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$CAMPAIGN" "$@"
}

test_digest_lists_every_pr() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/digest")
  set +e
  run_campaign "$case_dir" digest --repo "$REPO" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "digest: should succeed"
  assert_grep "#11 base:main head:feat-a mergeable:yes checks:all-green $URL_BASE/11" \
    "$case_dir/stdout" "digest: PR 11 line wrong"
  assert_grep "#12 base:feat-a head:feat-b mergeable:yes checks:pending $URL_BASE/12" \
    "$case_dir/stdout" "digest: PR 12 line wrong"
  assert_grep "#13 base:main head:feat-c mergeable:no checks:fail $URL_BASE/13" \
    "$case_dir/stdout" "digest: PR 13 line wrong"
  assert_grep "#14 base:main head:feat-d mergeable:unknown checks:none $URL_BASE/14" \
    "$case_dir/stdout" "digest: PR 14 line wrong"
  [ "$(wc -l < "$case_dir/stdout")" -eq 5 ] \
    || fail "digest: want 5 lines, got $(wc -l < "$case_dir/stdout")"
  [ "$(head -1 "$case_dir/stdout" | cut -c1-3)" = "#11" ] \
    || fail "digest: oldest PR is not first"
  pass "digest prints one compact line per open PR, oldest first"
}

test_digest_rejects_bad_input() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/digest-bad")
  set +e
  run_campaign "$case_dir" digest --repo 'not a repo' > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "digest: invalid repo should exit 2"
  set +e
  run_campaign "$case_dir" digest > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 2 "$rc" "digest: missing --repo should exit 2"
  [ ! -s "$case_dir/edit.log" ] || fail "digest: bad input must not touch the network path"
  pass "digest refuses an invalid repo and a missing --repo"
}

test_merge_next_defaults_to_oldest_eligible() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/next-default")
  set +e
  run_campaign "$case_dir" merge-next --repo "$REPO" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-next: should find PR 11"
  assert_grep "#11 base:main head:feat-a mergeable:yes checks:all-green $URL_BASE/11" \
    "$case_dir/stdout" "merge-next: did not pick the oldest eligible PR"
  pass "merge-next defaults to all open PRs oldest first"
}

test_merge_next_respects_list_order() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/next-order")
  set +e
  run_campaign "$case_dir" merge-next --repo "$REPO" 12 13 11 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-next: should find PR 11 after skipping 12 and 13"
  assert_grep "#11 base:main head:feat-a mergeable:yes checks:all-green $URL_BASE/11" \
    "$case_dir/stdout" "merge-next: list order was not respected"
  pass "merge-next skips ineligible PRs in the given order"
}

test_merge_next_accepts_no_checks() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/next-none")
  set +e
  run_campaign "$case_dir" merge-next --repo "$REPO" 12 15 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "merge-next: should accept PR 15 with no checks"
  assert_grep "#15 base:main head:feat-e mergeable:yes checks:none $URL_BASE/15" \
    "$case_dir/stdout" "merge-next: PR with no checks was not accepted as checks:none"
  pass "merge-next accepts a mergeable clean PR with no checks"
}

test_merge_next_reports_none() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/next-none-found")
  set +e
  run_campaign "$case_dir" merge-next --repo "$REPO" 12 13 14 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-next: no eligible PR should exit 1"
  assert_grep "NONE" "$case_dir/stdout" "merge-next: should print NONE"
  set +e
  run_campaign "$case_dir" merge-next --repo acme/empty > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" "merge-next: empty repo should exit 1"
  assert_grep "NONE" "$case_dir/stdout2" "merge-next: empty repo should print NONE"
  pass "merge-next prints NONE when nothing is eligible"
}

test_restack_retargets_onto_heads() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/restack")
  set +e
  run_campaign "$case_dir" restack --repo "$REPO" 11 13 15 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "restack: should succeed"
  assert_grep "bottom: #11 base:main head:feat-a $URL_BASE/11" \
    "$case_dir/stdout" "restack: bottom line wrong"
  assert_grep "retargeted: #13 base:feat-a head:feat-c $URL_BASE/13" \
    "$case_dir/stdout" "restack: PR 13 should retarget onto feat-a"
  assert_grep "retargeted: #15 base:feat-c head:feat-e $URL_BASE/15" \
    "$case_dir/stdout" "restack: PR 15 should retarget onto feat-c"
  assert_grep "pr edit 13 --repo $REPO --base feat-a" \
    "$case_dir/edit.log" "restack: PR 13 edit not issued"
  assert_grep "pr edit 15 --repo $REPO --base feat-c" \
    "$case_dir/edit.log" "restack: PR 15 edit not issued"
  assert_no_grep "pr edit 11" "$case_dir/edit.log" "restack: bottom PR must never be edited"
  pass "restack retargets each PR onto the head below it"
}

test_restack_keeps_correct_bases() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/restack-keep")
  set +e
  run_campaign "$case_dir" restack --repo "$REPO" 11 12 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "restack: should succeed"
  assert_grep "keep: #12 base:feat-a head:feat-b $URL_BASE/12" \
    "$case_dir/stdout" "restack: already-stacked PR should be kept"
  [ ! -s "$case_dir/edit.log" ] || fail "restack: a correct base must not issue an edit"
  pass "restack leaves an already-correct base alone"
}

test_restack_rejects_bad_numbers() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/restack-bad")
  set +e
  run_campaign "$case_dir" restack --repo "$REPO" 11 11 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "restack: duplicate numbers should exit 2"
  set +e
  run_campaign "$case_dir" restack --repo "$REPO" 11 nope > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 2 "$rc" "restack: invalid numbers should exit 2"
  [ ! -s "$case_dir/edit.log" ] || fail "restack: rejected input must not edit anything"
  pass "restack refuses duplicate and invalid PR numbers"
}

test_help_and_unknown_subcommand() {
  local case_dir rc
  case_dir=$(make_case "$TMP_ROOT/help")
  set +e
  run_campaign "$case_dir" --help > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "--help should exit 0"
  set +e
  run_campaign "$case_dir" frobnicate > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 2 "$rc" "unknown subcommand should exit 2"
  pass "--help succeeds and an unknown subcommand fails"
}

test_digest_lists_every_pr
test_digest_rejects_bad_input
test_merge_next_defaults_to_oldest_eligible
test_merge_next_respects_list_order
test_merge_next_accepts_no_checks
test_merge_next_reports_none
test_restack_retargets_onto_heads
test_restack_keeps_correct_bases
test_restack_rejects_bad_numbers
test_help_and_unknown_subcommand

#!/usr/bin/env bash
# Tests for bin/fm-pr-ready-bucket.sh: a read-only GitHub listing of MemberOS
# (or --repo) open PRs grouped for the next bors rollup.
#
# Matrix:
#   (a) MERGEABLE main PR with required Depot + title/body lint green is ready
#   (b) conflicts, red required CI, review-blocker, and CHANGES_REQUESTED block
#   (c) base other than main is stacked, even when it also has conflicts
#   (d) bors-ci-merge-queue author or queue comment is in-Bors
#   (e) drafts and release-please PRs targeting main are omitted
#   (f) pending required CI is omitted rather than blocked or ready
#   (g) default repo is Chamber-Hero/memberos; --repo overrides
#   (h) the helper is read-only (no merge/comment/review) and does not
#       scrape the Bors host
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUCKET="$ROOT/bin/fm-pr-ready-bucket.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ready-bucket-tests)
BASE_PATH=$PATH
REAL_JQ=$(command -v jq) || fail "jq is required for ready-bucket tests"
REAL_PYTHON3=$(command -v python3) || fail "python3 is required for ready-bucket tests"

assert_present "$BUCKET" "bin/fm-pr-ready-bucket.sh is missing"
[ -x "$BUCKET" ] || fail "bin/fm-pr-ready-bucket.sh must be executable"

GREEN_CHECKS="CI (Depot) / lint=success;CI (Depot) / typecheck=success;CI (Depot) / build=success;CI (Depot) / guardrails=success;CI (Depot) / test=success;CI (Depot) / cli-test=success;CI (Depot) / quality=success;CI (Depot) / edge-test=success;PR Title Lint (Depot) / pr-title-lint=success;PR Body Lint (Depot) / pr-body-lint=success"

# make_case <name>: sandbox with a gh-axi mock that replays a TOON page and
# records every invocation. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$fakebin"
  : > "$case_dir/gh-axi.log"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case " $* " in
  *" merge "*|*" comment "*|*" review "*|*" edit "*|*" close "*|*" create "*)
    echo "error: ready-bucket tests forbid write operations: $*" >&2
    exit 1
    ;;
esac
case "${1:-} ${2:-}" in
  "api POST")
    cat "$FM_TEST_TOON_FILE"
    exit 0
    ;;
esac
echo "error: unexpected gh-axi invocation: $*" >&2
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$case_dir"
}

run_bucket() {
  local case_dir=$1
  shift
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_TOON_FILE="$case_dir/page.toon" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
    "$BUCKET" "$@"
}

# write_page <file> <hasNextPage> <endCursor> [pr json objects...]
# Each PR object supplies the compact record keys the helper classifies.
write_page() {
  local file=$1 has_next=$2 cursor=$3
  shift 3
  if [ "$#" -eq 0 ]; then
    cat > "$file" <<EOF
hasNextPage: $has_next
endCursor: "$cursor"
prs[0]:
EOF
    return 0
  fi
  "$REAL_PYTHON3" - "$file" "$has_next" "$cursor" "$@" <<'PY'
import csv, json, sys
path, has_next, cursor = sys.argv[1], sys.argv[2], sys.argv[3]
prs = [json.loads(arg) for arg in sys.argv[4:]]
keys = [
    "author", "base", "bors_author", "bors_last", "checks", "draft",
    "head", "labels", "mergeable", "number", "review", "title", "url",
]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(f"hasNextPage: {has_next}\n")
    fh.write(f'endCursor: "{cursor}"\n')
    fh.write("prs[%d]{%s}:\n" % (len(prs), ",".join(keys)))
    writer = csv.writer(fh, lineterminator="\n")
    for pr in prs:
        fh.write("  ")
        writer.writerow([
            pr.get("author", "alice"),
            pr.get("base", "main"),
            "true" if pr.get("bors_author") else "false",
            pr.get("bors_last", ""),
            pr.get("checks", ""),
            "true" if pr.get("draft") else "false",
            pr.get("head", "feat/x"),
            pr.get("labels", ""),
            pr.get("mergeable", "MERGEABLE"),
            pr.get("number", 1),
            pr.get("review", "APPROVED"),
            pr.get("title", "feat: x"),
            pr.get("url", "https://github.com/Chamber-Hero/memberos/pull/%s" % pr.get("number", 1)),
        ])
PY
}

pr_json() {
  # shellcheck disable=SC2016 # jq $number/$title and friends are jq variables.
  "$REAL_JQ" -n \
    --argjson number "$1" \
    --arg title "$2" \
    --arg mergeable "${3:-MERGEABLE}" \
    --arg base "${4:-main}" \
    --arg checks "${5:-$GREEN_CHECKS}" \
    --arg labels "${6:-}" \
    --arg review "${7:-APPROVED}" \
    --argjson draft "${8:-false}" \
    --arg author "${9:-alice}" \
    --arg head "${10:-feat/x}" \
    --argjson bors_author "${11:-false}" \
    --arg bors_last "${12:-}" \
    '{
      number:$number, title:$title, mergeable:$mergeable, base:$base,
      checks:$checks, labels:$labels, review:$review, draft:$draft,
      author:$author, head:$head, bors_author:$bors_author, bors_last:$bors_last,
      url:("https://github.com/Chamber-Hero/memberos/pull/" + ($number|tostring))
    }'
}

test_help_and_bad_args() {
  local out
  out=$("$BUCKET" --help)
  assert_contains "$out" "fm-pr-ready-bucket.sh" "help should name the command"
  assert_contains "$out" "Chamber-Hero/memberos" "help should name the default repo"
  assert_contains "$out" "does not scrape a Bors host" "help should say GitHub is the source"
  "$BUCKET" --nope >/dev/null 2>&1
  expect_code 2 $? "--nope should be a usage error"
  "$BUCKET" --repo not-a-repo >/dev/null 2>&1
  expect_code 2 $? "malformed --repo should be a usage error"
  pass "fm-pr-ready-bucket help and usage errors"
}

test_missing_tools_refuse() {
  local case_dir rc=0
  case_dir=$(make_case missing-tools)
  # Keep a system PATH so env can find bash, but do not include the gh-axi mock.
  PATH="/usr/bin:/bin" "$BUCKET" >/dev/null 2>"$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "missing gh-axi should refuse"
  assert_contains "$(cat "$case_dir/stderr")" "gh-axi not found" "missing gh-axi names the tool"
  pass "fm-pr-ready-bucket refuses without gh-axi"
}

test_ready_pr() {
  local case_dir out
  case_dir=$(make_case ready)
  write_page "$case_dir/page.toon" false "" "$(pr_json 101 "feat: ready")"
  out=$(run_bucket "$case_dir" --json)
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.repo')" = "Chamber-Hero/memberos" ] \
    || fail "ready: default repo should be Chamber-Hero/memberos"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.ready | length')" = 1 ] \
    || fail "ready: expected one ready PR, got: $out"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.ready[0].url')" = \
    "https://github.com/Chamber-Hero/memberos/pull/101" ] \
    || fail "ready: full PR URL missing, got: $out"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.blocked | length')" = 0 ] \
    || fail "ready: should not be blocked"
  grep -F "POST /graphql" "$case_dir/gh-axi.log" >/dev/null \
    || fail "ready: should list PRs through gh-axi api POST /graphql"
  grep -E "Chamber-Hero|memberos" "$case_dir/gh-axi.log" >/dev/null \
    || fail "ready: GraphQL variables should name Chamber-Hero/memberos"
  pass "fm-pr-ready-bucket lists a green MERGEABLE main PR as ready"
}

test_blocked_reasons() {
  local case_dir out
  case_dir=$(make_case blocked)
  write_page "$case_dir/page.toon" false "" \
    "$(pr_json 201 "fix: conflicts" CONFLICTING)" \
    "$(pr_json 202 "fix: red ci" MERGEABLE main "${GREEN_CHECKS};PR Body Lint (Depot) / pr-body-lint=failure")" \
    "$(pr_json 203 "fix: blocker" MERGEABLE main "$GREEN_CHECKS" "review-blocker")" \
    "$(pr_json 204 "fix: changes" MERGEABLE main "$GREEN_CHECKS" "" CHANGES_REQUESTED)"
  out=$(run_bucket "$case_dir" --json)
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.ready | length')" = 0 ] \
    || fail "blocked: no PR should be ready, got: $out"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.blocked | length')" = 4 ] \
    || fail "blocked: expected four blocked PRs, got: $out"
  printf '%s\n' "$out" | "$REAL_JQ" -e '
    (.blocked[] | select(.number==201) | .reasons | index("conflicts")) != null
    and (.blocked[] | select(.number==202) | .reasons[] | test("red required CI"))
    and (.blocked[] | select(.number==203) | .reasons | index("review-blocker")) != null
    and (.blocked[] | select(.number==204) | .reasons | index("CHANGES_REQUESTED")) != null
  ' >/dev/null || fail "blocked: missing expected reasons, got: $out"
  out=$(run_bucket "$case_dir")
  assert_contains "$out" "https://github.com/Chamber-Hero/memberos/pull/201" \
    "human output should print the conflicts PR URL"
  assert_contains "$out" "conflicts" "human output should name the conflicts reason"
  pass "fm-pr-ready-bucket classifies conflicts, red required CI, review-blocker, and CHANGES_REQUESTED as blocked"
}

test_stacked_wins_over_conflicts() {
  local case_dir out
  case_dir=$(make_case stacked)
  write_page "$case_dir/page.toon" false "" \
    "$(pr_json 301 "feat: stacked" CONFLICTING feat/parent "$GREEN_CHECKS")"
  out=$(run_bucket "$case_dir" --json)
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.stacked | length')" = 1 ] \
    || fail "stacked: expected one stacked PR, got: $out"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.blocked | length')" = 0 ] \
    || fail "stacked: stacked PRs must not also appear as blocked, got: $out"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.stacked[0].base')" = "feat/parent" ] \
    || fail "stacked: should record the non-main base"
  out=$(run_bucket "$case_dir")
  assert_contains "$out" "https://github.com/Chamber-Hero/memberos/pull/301" \
    "stacked human output should print the full URL"
  assert_contains "$out" "base feat/parent" "stacked human output should name the base"
  pass "fm-pr-ready-bucket lists non-main base PRs as stacked"
}

test_in_bors_author_and_comment() {
  local case_dir out
  case_dir=$(make_case in-bors)
  write_page "$case_dir/page.toon" false "" \
    "$(pr_json 401 "Auto merge of #101" MERGEABLE main "$GREEN_CHECKS" "" APPROVED false "bors-ci-merge-queue" "tmp/bors" true "")" \
    "$(pr_json 402 "feat: queued" MERGEABLE main "$GREEN_CHECKS" "" APPROVED false "alice" "feat/queued" false "Commit abc has been approved by cap. It is now in the [queue] for this repository.")"
  out=$(run_bucket "$case_dir" --json)
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.in_bors | length')" = 2 ] \
    || fail "in-bors: expected two in-Bors PRs, got: $out"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.ready | length')" = 0 ] \
    || fail "in-bors: queued PRs must not also be ready, got: $out"
  out=$(run_bucket "$case_dir")
  assert_contains "$out" "in-Bors (2)" "human output should title the in-Bors group"
  assert_contains "$out" "https://github.com/Chamber-Hero/memberos/pull/401" \
    "in-Bors should print the rollup URL"
  pass "fm-pr-ready-bucket detects in-Bors from bors-ci-merge-queue author and queue comments"
}

test_stale_bors_comment_is_not_in_bors() {
  local case_dir out
  case_dir=$(make_case stale-bors)
  write_page "$case_dir/page.toon" false "" \
    "$(pr_json 403 "feat: unapproved" CONFLICTING main "$GREEN_CHECKS" "" APPROVED false "alice" "feat/x" false "This pull request was unapproved.")" \
    "$(pr_json 404 "feat: unmergeable" CONFLICTING main "$GREEN_CHECKS" "" APPROVED false "alice" "feat/y" false "The latest upstream changes made this pull request unmergeable.")"
  out=$(run_bucket "$case_dir" --json)
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.in_bors | length')" = 0 ] \
    || fail "stale-bors: unapproved/unmergeable last comments must not be in-Bors, got: $out"
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.blocked | length')" = 2 ] \
    || fail "stale-bors: those PRs should be blocked on conflicts, got: $out"
  pass "fm-pr-ready-bucket ignores stale Bors unapproved and unmergeable comments"
}

test_omits_draft_release_and_pending() {
  local case_dir out pending_checks
  case_dir=$(make_case omit)
  pending_checks="CI (Depot) / lint=queued;CI (Depot) / typecheck=success;CI (Depot) / build=success;CI (Depot) / guardrails=success;CI (Depot) / test=success;CI (Depot) / cli-test=success;CI (Depot) / quality=success;CI (Depot) / edge-test=success;PR Title Lint (Depot) / pr-title-lint=success;PR Body Lint (Depot) / pr-body-lint=success"
  write_page "$case_dir/page.toon" false "" \
    "$(pr_json 501 "feat: draft" MERGEABLE main "$GREEN_CHECKS" "" APPROVED true)" \
    "$(pr_json 502 "chore(main): release 1.2.3" MERGEABLE main "$GREEN_CHECKS" "" APPROVED false "release-please[bot]" "release-please--branches--main")" \
    "$(pr_json 503 "feat: still running" MERGEABLE main "$pending_checks")"
  out=$(run_bucket "$case_dir" --json)
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '[.ready,.blocked,.stacked,.in_bors | length] | add')" = 0 ] \
    || fail "omit: drafts, release-please, and pending required CI should be omitted, got: $out"
  pass "fm-pr-ready-bucket omits drafts, release-please, and pending required CI"
}

test_repo_override_and_read_only() {
  local case_dir out
  case_dir=$(make_case repo-override)
  write_page "$case_dir/page.toon" false ""
  out=$(run_bucket "$case_dir" --repo Example-Org/other --json)
  [ "$(printf '%s\n' "$out" | "$REAL_JQ" -r '.repo')" = "Example-Org/other" ] \
    || fail "repo-override: JSON should echo the requested repo, got: $out"
  grep -F "Example-Org" "$case_dir/gh-axi.log" >/dev/null \
    || fail "repo-override: GraphQL variables should name Example-Org"
  grep -F "other" "$case_dir/gh-axi.log" >/dev/null \
    || fail "repo-override: GraphQL variables should name the other repo"
  if grep -Ei " merge | comment | review | edit | close | create " "$case_dir/gh-axi.log"; then
    fail "repo-override: gh-axi write operations were invoked"
  fi
  pass "fm-pr-ready-bucket honors --repo and only reads through gh-axi graphql"
}

test_does_not_fetch_bors_host() {
  local case_dir
  case_dir=$(make_case no-bors-host)
  write_page "$case_dir/page.toon" false ""
  cat > "$case_dir/fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CURL_LOG"
echo "error: curl should not run" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/curl"
  : > "$case_dir/curl.log"
  FM_TEST_CURL_LOG="$case_dir/curl.log" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_TOON_FILE="$case_dir/page.toon" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
    "$BUCKET" --json >/dev/null || fail "no-bors-host: GitHub listing failed"
  if [ -s "$case_dir/curl.log" ]; then
    fail "no-bors-host: curl ran: $(cat "$case_dir/curl.log")"
  fi
  if grep -F "bors.nbost.com" "$case_dir/gh-axi.log"; then
    fail "no-bors-host: gh-axi was pointed at the Bors host"
  fi
  pass "fm-pr-ready-bucket lists from GitHub and does not scrape the Bors host"
}

test_empty_listing_prints_four_groups() {
  local case_dir out
  case_dir=$(make_case empty)
  write_page "$case_dir/page.toon" false ""
  out=$(run_bucket "$case_dir")
  assert_contains "$out" "ready (0)" "empty listing should still print ready"
  assert_contains "$out" "blocked (0)" "empty listing should still print blocked"
  assert_contains "$out" "stacked (0)" "empty listing should still print stacked"
  assert_contains "$out" "in-Bors (0)" "empty listing should still print in-Bors"
  pass "fm-pr-ready-bucket prints all four groups when nothing matches"
}

test_help_and_bad_args
test_missing_tools_refuse
test_ready_pr
test_blocked_reasons
test_stacked_wins_over_conflicts
test_in_bors_author_and_comment
test_stale_bors_comment_is_not_in_bors
test_omits_draft_release_and_pending
test_repo_override_and_read_only
test_does_not_fetch_bors_host
test_empty_listing_prints_four_groups

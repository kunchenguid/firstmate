#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-description-check.sh and its refusal inside
# bin/fm-pr-check.sh: template headings, title shape, internal wording, the
# per-home product deny list, the template-text and code exemptions, scope
# skips, and refusing rather than passing when the PR cannot be read.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-description-check.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-description-check)
URL=https://github.com/acme/widget/pull/7

for tool in jq awk; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for this suite"
done

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# gh, answering from fixture files under $FM_TEST_FX: `pr view` builds the PR
# record from title/body/head, and `api .../contents/<path>` returns the
# template when <path> equals the fixture's template-path, else a 404.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
fx=$FM_TEST_FX
case "${1:-} ${2:-}" in
  "pr view")
    [ ! -e "$fx/pr-fail" ] || { echo "gh: network unreachable" >&2; exit 1; }
    jq -n --rawfile t "$fx/title" --rawfile b "$fx/body" --arg h "$(cat "$fx/head")" \
      '{title: ($t | rtrimstr("\n")), body: $b, headRefName: $h, baseRefName: "main"}'
    ;;
  "api --method")
    [ ! -e "$fx/api-fail" ] || { echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; }
    path=${4#repos/acme/widget/contents/}
    if [ -e "$fx/template" ] && [ "$path" = "$(cat "$fx/template-path")" ]; then
      jq -n --arg c "$(base64 < "$fx/template")" '{type: "file", encoding: "base64", content: $c}'
    else
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

TEMPLATE='## Summary

<!-- Why this change; the briefest possible explanation. -->

## Test plan

- [ ] Reviewed by the captain of the release train

```text
## Not a heading
```

### Notes
'

GOOD_BODY='## Summary

- Fix the widget cache so stale entries expire.

## Test plan

- [x] Reviewed by the captain of the release train
- Ran the unit suite.
'

# new_case <name>: a home with one task on a registered project clone and a
# passing PR fixture; each case then overrides only what it tests.
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/home/projects/widget" "$dir/fx"
  printf '# Projects\n\n- widget [no-mistakes] - Widget service (added 2026-01-01)\n' > "$dir/home/data/projects.md"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" "endpoint_task_id=task-a" "worktree=$dir/wt" \
    "project=$dir/home/projects/widget" "kind=ship" "mode=no-mistakes"
  printf 'fix: expire stale widget cache entries\n' > "$dir/fx/title"
  printf '%s' "$GOOD_BODY" > "$dir/fx/body"
  printf 'fix/widget-cache\n' > "$dir/fx/head"
  printf '%s' "$TEMPLATE" > "$dir/fx/template"
  printf '.github/PULL_REQUEST_TEMPLATE.md\n' > "$dir/fx/template-path"
  printf '%s\n' "$dir"
}

OUT=
RC=0
run_check() {  # <case-dir> [task-id]
  local dir=$1
  RC=0
  OUT=$(FM_HOME="$dir/home" FM_TEST_FX="$dir/fx" PATH="$FAKEBIN:$PATH" \
    bash "$CHECK" "${2:-task-a}" "$URL" 2>&1) || RC=$?
}

# --- passing description ------------------------------------------------------

d=$(new_case clean)
run_check "$d"
expect_code 0 "$RC" "a conforming description passes: $OUT"
assert_contains "$OUT" "passed: $URL" "a pass says so"
pass "a conforming title and template-shaped body pass"

# --- check 1: template headings ---------------------------------------------

d=$(new_case missing-heading)
printf '## Summary\n\nFix the cache.\n' > "$d/fx/body"
run_check "$d"
expect_code 1 "$RC" "a missing template heading fails"
assert_contains "$OUT" 'body: missing template heading: ## Test plan' "the missing heading is named"
assert_not_contains "$OUT" 'Not a heading' "a heading inside a template code fence is not required"
assert_not_contains "$OUT" '### Notes' "a deeper template heading is not top level"
pass "a body missing a top-level template heading fails and names it"

d=$(new_case heading-case)
printf '## summary\n\nFix.\n\n## TEST PLAN\n\nRan it.\n' > "$d/fx/body"
run_check "$d"
expect_code 0 "$RC" "heading text matches case-insensitively: $OUT"
pass "template headings match case-insensitively"

d=$(new_case root-template)
printf 'pull_request_template.md\n' > "$d/fx/template-path"
printf '## Summary\n\nFix.\n' > "$d/fx/body"
run_check "$d"
expect_code 1 "$RC" "a root-level template is found"
assert_contains "$OUT" 'missing template heading: ## Test plan' "the root template is enforced"
pass "a template at another standard location is enforced"

d=$(new_case no-template)
rm "$d/fx/template"
printf 'Free-form description with no headings.\n' > "$d/fx/body"
run_check "$d"
expect_code 0 "$RC" "no template means no heading check: $OUT"
pass "a repository without a PR template skips the heading check"

# --- check 2: title shape ---------------------------------------------------

d=$(new_case title-plain)
printf 'Expire stale widget cache entries\n' > "$d/fx/title"
run_check "$d"
expect_code 1 "$RC" "a title without a type fails"
assert_contains "$OUT" 'title: does not match <type>: <description>' "the expected shape is named"
pass "a title that is not <type>: <description> fails"

d=$(new_case title-key)
printf 'feat/DF-123-widget-cache\n' > "$d/fx/head"
printf 'fix: expire stale widget cache entries\n' > "$d/fx/title"
run_check "$d"
expect_code 1 "$RC" "a ticket branch requires the key in the title"
assert_contains "$OUT" 'title: does not match <type>(DF-123): <description>' "the branch key is named"
printf 'fix(DF-124): expire stale widget cache entries\n' > "$d/fx/title"
run_check "$d"
expect_code 1 "$RC" "a different key fails"
printf 'fix(DF-123): expire stale widget cache entries\n' > "$d/fx/title"
run_check "$d"
expect_code 0 "$RC" "the branch key in the title passes: $OUT"
pass "a ticket-keyed branch requires <type>(<KEY>): <description> with that key"

d=$(new_case title-registered-key)
printf '# Projects\n\n- widget [no-mistakes branch=feat/DF-] - Widget service (added 2026-01-01)\n' > "$d/home/data/projects.md"
run_check "$d"
expect_code 1 "$RC" "a registered key-shaped branch prefix requires a key"
assert_contains "$OUT" '<type>(<TICKET-KEY>): <description>' "the keyed shape is named"
printf 'fix(DF-9): expire stale widget cache entries\n' > "$d/fx/title"
run_check "$d"
expect_code 0 "$RC" "any key passes when the branch carries none: $OUT"
pass "a registered key-shaped branch prefix requires a ticket key in the title"

d=$(new_case title-not-a-key)
printf 'fix/handle-UTF-8-input\n' > "$d/fx/head"
run_check "$d"
expect_code 0 "$RC" "a key-shaped word later in the branch is not a ticket key: $OUT"
pass "only a key leading the branch's last segment counts as a ticket key"

# --- check 3: internal wording ----------------------------------------------

d=$(new_case vocab)
printf '%s\nPer instruction from the Captain, the crewmate kept this narrow.\n' "$GOOD_BODY" > "$d/fx/body"
run_check "$d"
expect_code 1 "$RC" "internal wording fails"
assert_contains "$OUT" 'body line 10: internal wording "captain": Per instruction' "the offending line is named with its number"
pass "internal fleet wording fails and names the line"

d=$(new_case vocab-title)
printf 'fix: address second-mate brief findings\n' > "$d/fx/title"
run_check "$d"
expect_code 1 "$RC" "internal wording in the title fails"
assert_contains "$OUT" 'title: internal wording "second-mate"' "the title is named"
pass "internal wording in the title fails"

d=$(new_case vocab-words)
printf '%s\nWe debriefed the captainship team briefly about the briefcase.\n' "$GOOD_BODY" > "$d/fx/body"
run_check "$d"
expect_code 0 "$RC" "matches are whole words only: $OUT"
pass "internal wording matches whole words only"

d=$(new_case footer)
printf '%s\n## Pipeline\n\nUpdates from [git push no-mistakes](https://example.invalid)\n\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc"} -->\n' "$GOOD_BODY" > "$d/fx/body"
run_check "$d"
expect_code 1 "$RC" "the validation footer fails"
assert_contains "$OUT" 'body line 12: internal wording "no-mistakes": Updates from' "the footer line is named"
assert_contains "$OUT" 'body line 14: internal wording "no-mistakes": <!-- no-mistakes-pipeline-attestation' "the attestation comment is named"
printf '%s\n-\n' "$TEMPLATE" > "$d/fx/template"
run_check "$d"
expect_code 1 "$RC" "a generic template line does not exempt the footer"
assert_contains "$OUT" 'body line 12: internal wording "no-mistakes"' "the footer is still named"
pass "the validation tool's footer and attestation comment fail"

d=$(new_case template-exempt)
run_check "$d"
expect_code 0 "$RC" "template text with a forbidden word is exempt even when checked: $OUT"
printf '%s- [ ] Reviewed by the captain of the release train, and the captain agreed\n' "$GOOD_BODY" > "$d/fx/body"
run_check "$d"
expect_code 1 "$RC" "a forbidden word outside the template text still fails"
assert_contains "$OUT" 'body line 9: internal wording "captain"' "the added wording is caught"
pass "text the template ships is exempt, but wording added beside it is not"

# --- check 4: denied product names ------------------------------------------

d=$(new_case deny)
printf '# product names kept out of PR prose\nApache Kafka\nTrino\n\n' > "$d/home/config/pr-description-deny"
# shellcheck disable=SC2016 # Literal backticks are Markdown code-span test data.
printf '%s\nStreams events through apache   KAFKA into the store.\nCalls `trino.connect()` for queries.\n```sh\ntrino --version\n```\nTrinomial math is unaffected.\n' "$GOOD_BODY" > "$d/fx/body"
run_check "$d"
expect_code 1 "$RC" "a denied product name in prose fails"
assert_contains "$OUT" 'body line 10: denied product name "apache kafka"' "the prose line is named"
assert_not_contains "$OUT" 'body line 11' "an inline code span is exempt"
assert_not_contains "$OUT" 'body line 13' "a fenced code block is exempt"
assert_not_contains "$OUT" 'body line 15' "a longer word containing a denied name is not a match"
pass "a denied product name fails in prose but not in code"

d=$(new_case deny-title)
printf 'Trino\n' > "$d/home/config/pr-description-deny"
printf 'fix: speed up Trino queries\n' > "$d/fx/title"
run_check "$d"
expect_code 1 "$RC" "a denied name in the title fails"
assert_contains "$OUT" 'title: denied product name "trino"' "the title is named"
pass "a denied product name in the title fails"

d=$(new_case deny-template)
printf 'Postgres\n' > "$d/home/config/pr-description-deny"
printf '## Summary\n\n## Test plan\n\n- [ ] Migration tested against Postgres\n' > "$d/fx/template"
printf '## Summary\n\nFix.\n\n## Test plan\n\n- [x] Migration tested against Postgres\n' > "$d/fx/body"
run_check "$d"
expect_code 0 "$RC" "a denied name inside template text is exempt: $OUT"
pass "a denied product name shipped in the template is exempt"

d=$(new_case deny-empty)
printf 'fix: tune the Trino client\n' > "$d/fx/title"
run_check "$d"
expect_code 0 "$RC" "no deny list means no product names are denied: $OUT"
pass "the deny list is empty by default"

# --- scope and failure handling ---------------------------------------------

d=$(new_case not-project)
fm_write_meta "$d/home/state/task-a.meta" "worktree=$d/wt" "project=$d/home" "kind=ship"
printf 'fix: firstmate captain brief wording\n' > "$d/fx/title"
run_check "$d"
expect_code 0 "$RC" "a task outside the projects directory is skipped"
assert_contains "$OUT" 'skipped:' "the skip is reported"
pass "work outside this home's project clones is skipped"

d=$(new_case gitlab)
RC=0
OUT=$(FM_HOME="$d/home" FM_TEST_FX="$d/fx" PATH="$FAKEBIN:$PATH" \
  bash "$CHECK" task-a https://gitlab.com/acme/widget/-/merge_requests/7 2>&1) || RC=$?
expect_code 0 "$RC" "a GitLab merge request is skipped"
assert_contains "$OUT" 'skipped: the PR description guard reads GitHub pull requests only' "the skip names the reason"
pass "a non-GitHub change is skipped with a note"

d=$(new_case pr-unreadable)
: > "$d/fx/pr-fail"
run_check "$d"
expect_code 1 "$RC" "an unreadable PR is not a pass"
assert_contains "$OUT" "error: could not read $URL" "the read failure is reported"
pass "an unreadable PR fails instead of passing"

d=$(new_case template-unreadable)
: > "$d/fx/api-fail"
run_check "$d"
expect_code 1 "$RC" "a template read error other than 404 is not a pass"
assert_contains "$OUT" 'could not read the PR template' "the template read failure is reported"
pass "a template read failure other than absence fails instead of skipping"

RC=0
OUT=$(bash "$CHECK" task-a 2>&1) || RC=$?
expect_code 2 "$RC" "a missing argument is a usage error"
pass "an invalid request exits 2"

# --- refusal inside fm-pr-check ---------------------------------------------

d=$(new_case pr-check-refuses)
printf 'Fix the cache\n' > "$d/fx/title"
RC=0
OUT=$(FM_HOME="$d/home" FM_TEST_FX="$d/fx" PATH="$FAKEBIN:$PATH" \
  bash "$PR_CHECK" task-a "$URL" 2>&1) || RC=$?
expect_code 1 "$RC" "fm-pr-check refuses a failing description"
assert_contains "$OUT" 'title: does not match' "the violation reaches the caller"
assert_contains "$OUT" "error: $URL was not recorded as ready" "the refusal is explicit"
assert_no_grep 'pr=' "$d/home/state/task-a.meta" "nothing is recorded on refusal"
[ ! -e "$d/home/state/task-a.check.sh" ] || fail "no merge poll is armed on refusal"
pass "fm-pr-check records and arms nothing while the description fails"

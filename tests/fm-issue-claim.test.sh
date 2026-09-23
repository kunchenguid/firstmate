#!/usr/bin/env bash
# Behavioral tests for bin/fm-issue-claim.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-issue-claim.sh"
TMP_ROOT=$(fm_test_tmproot fm-issue-claim-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FIX="$TMP_ROOT/forge"
CLONE="$TMP_ROOT/clone"
mkdir -p "$FIX"
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

# The fake gh serves API-shaped JSON from $FIX, one file per endpoint key, and
# logs every call so read-only and per-run corpus behavior can be asserted. An
# endpoint with a .fail file prints that text to stderr and exits non-zero,
# the way gh reports a rate limit or HTTP error.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_FORGE/calls.log"
[ "${1:-}" = api ] || { echo "fake gh: only api is served: $*" >&2; exit 90; }
shift
endpoint= head=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) [ "$2" = GET ] || { echo "fake gh: refusing method $2" >&2; exit 92; }; shift 2 ;;
    --method) echo "fake gh: refusing --method $2" >&2; exit 92 ;;
    --paginate) shift ;;
    -f|-F)
      case "$2" in head=*) head=${2#head=} ;; esac
      shift 2 ;;
    -*) echo "fake gh: unexpected flag $1" >&2; exit 93 ;;
    *) endpoint=$1; shift ;;
  esac
done
[ -z "$head" ] || endpoint="$endpoint?head=$head"
key=$(printf '%s' "$endpoint" | tr '/?=&:+' '______')
if [ -e "$FM_FAKE_FORGE/$key.fail" ]; then
  cat "$FM_FAKE_FORGE/$key.fail" >&2
  exit 1
fi
if [ -e "$FM_FAKE_FORGE/$key.json" ]; then
  cat "$FM_FAKE_FORGE/$key.json"
  exit 0
fi
echo "gh: Not Found (HTTP 404)" >&2
exit 1
SH
chmod +x "$FAKEBIN/gh"
export FM_FAKE_FORGE="$FIX"

key_of() {
  printf '%s' "$1" | tr '/?=&:+' '______'
}

# put <endpoint> <json>: serve <json> for <endpoint>.
put() {
  printf '%s\n' "$2" > "$FIX/$(key_of "$1").json"
}

# fail_on <endpoint> <stderr text>: make <endpoint> fail.
fail_on() {
  printf '%s\n' "$2" > "$FIX/$(key_of "$1").fail"
}

heal() {
  rm -f "$FIX/$(key_of "$1").fail"
}

CREATED=2026-01-01T00:00:00Z

issue_json() {  # <n> <author>
  printf '{"number":%s,"state":"open","title":"issue %s","user":{"login":"%s"},"labels":[{"name":"ready-for-pr"}],"assignees":[],"created_at":"%s"}' \
    "$1" "$1" "$2" "$CREATED"
}

# A plain issue: readable, empty timeline and comments, an author with no fork.
plain_issue() {  # <n> <author>
  put "repos/o/r/issues/$1" "$(issue_json "$1" "$2")"
  put "repos/o/r/issues/$1/timeline?per_page=100" '[]'
  put "repos/o/r/issues/$1/comments?per_page=100" '[]'
}

build_forge() {
  put "repos/o/r" '{"default_branch":"main","name":"r"}'
  put "search/issues?q=repo:o/r+is:pr+is:open&per_page=1" '{"total_count":5,"incomplete_results":false}'
  # Two pages, the way --paginate concatenates them.
  cat > "$FIX/$(key_of 'repos/o/r/pulls?state=open&per_page=100').json" <<'JSON'
[{"number":50,"title":"unrelated","body":"Fixes #40181 and 4018x","head":{"ref":"fix-40181","repo":{"owner":{"login":"eve"}}},"user":{"login":"eve"},"draft":false},
 {"number":51,"title":"other repo","body":"see other/repo#4018 and https://github.com/other/repo/issues/4018","head":{"ref":"misc","repo":{"owner":{"login":"eve"}}},"user":{"login":"eve"},"draft":false}]
[{"number":52,"title":"claim it","body":"Refs #4018.","head":{"ref":"work","repo":{"owner":{"login":"dan"}}},"user":{"login":"dan"},"draft":true},
 {"number":53,"title":"title only fix for 4019","body":"","head":{"ref":"x","repo":{"owner":{"login":"dan"}}},"user":{"login":"dan"},"draft":false},
 {"number":54,"title":"branch only","body":null,"head":{"ref":"fm/4020-thing","repo":{"owner":{"login":"dan"}}},"user":{"login":"dan"},"draft":false}]
JSON

  # 4018: claimed only through a corpus body citation; 40181 and a foreign
  # repository's #4018 must not match.
  plain_issue 4018 alice
  # 4019 and 4020: title-only and branch-only corpus matches.
  plain_issue 4019 alice
  plain_issue 4020 alice
  # 100: nothing anywhere; its author has a real fork whose branch fix-1000
  # must not match 100.
  plain_issue 100 bob
  put "repos/bob/r" '{"fork":true,"parent":{"full_name":"o/r"},"source":{"full_name":"o/r"}}'
  put "repos/bob/r/branches?per_page=100" '[{"name":"main"},{"name":"fix-1000"}]'
  # 200: fixed on main by a commit that cites it.
  plain_issue 200 alice
  # 300: a symbol change without a fixing reference.
  plain_issue 300 alice
  # 400: a maintainer stamp names live PR #60, a non-maintainer "stamp" names
  # #61, and the timeline shows merged PR #70 plus a cross-repo PR.
  plain_issue 400 alice
  put "repos/o/r/issues/400/comments?per_page=100" '[
    {"user":{"login":"maint"},"author_association":"OWNER","created_at":"2026-01-02T00:00:00Z","html_url":"https://github.com/o/r/issues/400#c1",
     "body":"<!-- triage: 2026-01-02T00:00:00Z outcome=existing-pr contract-class=restore -->\nSpeaking as triage: **existing-pr → #60**. Help that PR."},
    {"user":{"login":"rando"},"author_association":"NONE","created_at":"2026-01-03T00:00:00Z","html_url":"https://github.com/o/r/issues/400#c2",
     "body":"<!-- triage: x outcome=existing-pr --> existing-pr -> #61"},
    {"user":{"login":"helper"},"author_association":"CONTRIBUTOR","created_at":"2026-01-04T00:00:00Z","html_url":"https://github.com/o/r/issues/400#c3",
     "body":"I will take this one."}]'
  put "repos/o/r/issues/400/timeline?per_page=100" '[
    {"event":"cross-referenced","source":{"issue":{"number":70,"state":"closed","title":"part one","body":"Fixes #400","user":{"login":"dan"},"repository":{"full_name":"o/r"},"pull_request":{"merged_at":"2026-01-05T00:00:00Z"}}}},
    {"event":"cross-referenced","source":{"issue":{"number":9,"state":"open","title":"fork pr","user":{"login":"dan"},"repository":{"full_name":"dan/r"},"pull_request":{"merged_at":null}}}},
    {"event":"labeled"}]'
  put "repos/o/r/pulls/60" '{"number":60,"state":"open","draft":false,"merged_at":null,"title":"helper","user":{"login":"helper"}}'
  # 800: the author's fork branch heads a PR that already merged.
  plain_issue 800 carol
  put "repos/carol/r" '{"fork":true,"parent":{"full_name":"o/r"},"source":{"full_name":"o/r"}}'
  put "repos/carol/r/branches?per_page=100" '[{"name":"fix-800"}]'
  put "repos/o/r/pulls?head=carol:fix-800" '[{"number":80,"state":"closed","merged_at":"2026-02-02T00:00:00Z","draft":false,"title":"fix 800","user":{"login":"carol"}}]'
  # 900: a pull request number, not an issue.
  put "repos/o/r/issues/900" '{"number":900,"state":"open","title":"a pr","user":{"login":"x"},"pull_request":{"url":"u"},"created_at":"2026-01-01T00:00:00Z"}'
}

build_clone() {
  fm_git_identity
  fm_git_init_commit "$CLONE"
  git -C "$CLONE" remote add origin https://github.com/o/r.git
  git -C "$CLONE" remote add fork https://github.com/someone/r.git
  commit_at() {  # <date> <message> [file content]
    printf '%s\n' "${3:-$2}" > "$CLONE/f.txt"
    git -C "$CLONE" add f.txt
    GIT_COMMITTER_DATE=$1 GIT_AUTHOR_DATE=$1 git -C "$CLONE" commit -qm "$2"
  }
  commit_at 2025-12-01T00:00:00Z "introduce magic" "magic_symbol here"
  commit_at 2026-02-01T00:00:00Z $'fix: the thing\n\nFixes #200' $'magic_symbol here\nfix 200'
  commit_at 2026-02-02T00:00:00Z "bump to 2000 and #2001" $'magic_symbol here\nbump'

  commit_at 2026-02-03T00:00:00Z "fix: remove the bad path" "gone"
  FIX200_SHA=$(git -C "$CLONE" log --format=%h --grep='Fixes #200' -1)
  FIX300_SHA=$(git -C "$CLONE" log --format=%h -1)
  MAGIC_INTRO_SHA=$(git -C "$CLONE" log --format=%h --grep='introduce magic' -1)
  commit_at 2026-02-04T00:00:00Z $'fix: another issue (#70)\n\nFixes #7777\n\nRelated, and not closed by this: #4412, #4482, #4316' "related change"
  RELATED_SHA=$(git -C "$CLONE" log --format=%h -1)
  commit_at 2026-02-05T00:00:00Z $'fix: explicit references (#70)\n\nFixes #201\nCLOSES: o/r#202\nresolved https://github.com/o/r/issues/203' "explicit fixes"
  commit_at 2026-02-06T00:00:00Z $'ref: #204\n\nFixes other/r#204\nCloses https://github.com/other/r/issues/204\nFixes #2040\nunfixes #204' "other fixes"
  git -C "$CLONE" update-ref refs/remotes/origin/main HEAD
}

build_forge
build_clone

run_claim() {
  : > "$FIX/calls.log"
  PATH="$FAKEBIN:$PATH" "$SCRIPT" --repo o/r --git-dir "$CLONE" "$@"
}

block_of() {  # <output> <n>: the evidence block for issue <n>
  printf '%s\n' "$1" | awk -v n="$2" '/^=== #/ { on = ($2 == "#" n) } on'
}

test_number_boundary_and_corpus_body_claim() {
  local out block rc=0
  out=$(run_claim 4018) || rc=$?
  expect_code 0 "$rc" "a claimed issue with full coverage"
  block=$(block_of "$out" 4018)
  assert_contains "$block" "verdict: claimed" "a PR body citing #4018 is a claim"
  assert_contains "$block" "claim: PR #52 open(draft) by dan" "the draft claiming PR must be named"
  assert_contains "$block" "corpus:body" "the claim must say which check found it"
  assert_not_contains "$block" "#50" "#40181 must not match issue 4018"
  assert_not_contains "$block" "#51" "another repository's #4018 must not match"
  assert_contains "$block" "coverage: complete" "every check looked"
  assert_contains "$block" "disclose: no repository alice/r" "a 404 fork is disclosed, not silent"
  pass "whole-number and same-repository boundaries hold; a body citation is a claim"
}

test_title_and_branch_matches_are_claims() {
  local out
  out=$(run_claim 4019 4020)
  assert_contains "$(block_of "$out" 4019)" "claim: PR #53 open by dan" "a title containing the number is a claim"
  assert_contains "$(block_of "$out" 4019)" "[corpus:title]" "the title match is labelled as such"
  assert_contains "$(block_of "$out" 4020)" "[corpus:branch]" "a branch containing the number is a claim"
  pass "title and branch corpus matches are reported with their source"
}

test_nothing_found_with_full_coverage_is_open() {
  local out block rc=0
  out=$(run_claim 100) || rc=$?
  expect_code 0 "$rc" "an open verdict"
  block=$(block_of "$out" 100)
  assert_contains "$block" "verdict: open" "nothing found and every check looked"
  assert_contains "$block" "fork=ok" "the real fork was searched"
  assert_not_contains "$block" "fix-1000" "branch fix-1000 must not match issue 100"
  assert_contains "$block" "corpus=ok(5/5)" "the corpus count is checked against the total"
  pass "an issue with nothing found and full coverage is open"
}

test_history_requires_a_fixing_reference() {
  local out rc=0
  out=$(run_claim --symbol 300:magic_symbol 200 300) || rc=$?
  expect_code 0 "$rc" "fixing and incidental history verdicts"
  assert_contains "$(block_of "$out" 200)" "verdict: fixed-on-main" "a main commit fixing the issue is merged evidence"
  assert_contains "$(block_of "$out" 200)" "merged: commit $FIX200_SHA" "the citing commit is named"
  assert_not_contains "$(block_of "$out" 200)" "2000" "#2001 and 2000 must not match issue 200"
  assert_contains "$(block_of "$out" 300)" "verdict: open" "a --symbol pickaxe hit cannot establish a fix"
  assert_contains "$(block_of "$out" 300)" "hint: commit $FIX300_SHA" "the removing commit is inspectable"
  assert_contains "$(block_of "$out" 300)" "[history:-S magic_symbol]" "the symbol search is labelled"
  assert_not_contains "$(block_of "$out" 300)" "$MAGIC_INTRO_SHA" "commits before the issue opened are out of range"
  assert_equals 1 "$(block_of "$out" 300 | grep -c '^hint: commit ')" "only the commit removing the symbol matches"
  pass "history distinguishes fixing references from symbol hints"
}

test_stamps_timeline_and_hints() {
  local out block
  out=$(run_claim 400)
  block=$(block_of "$out" 400)
  assert_contains "$block" "verdict: partially-covered" "merged #70 plus live stamped #60"
  assert_contains "$block" "claim: PR #60 open by helper" "the maintainer-stamped PR is a claim"
  assert_contains "$block" "[stamp]" "the stamp is the source of the #60 claim"
  assert_contains "$block" "merged: PR #70 merged" "a merged cross-referencing PR is merged evidence"
  assert_not_contains "$block" "PR #61" "a non-maintainer stamp must not name a claim"
  assert_contains "$block" "is not a maintainer stamp" "the non-maintainer stamp is disclosed as a hint"
  assert_contains "$block" "hint: prose claim in a comment by helper" "a prose claim is a hint"
  assert_contains "$block" "hint: PR dan/r#9 (open) in another repository" "a cross-repository PR is only a hint"
  pass "maintainer stamps and timeline PRs decide; other stamps, prose, and foreign PRs are hints"
}

test_fork_branch_heading_a_merged_pr() {
  local out block
  out=$(run_claim 800)
  block=$(block_of "$out" 800)
  assert_contains "$block" "verdict: open" "a matching merged branch does not establish a fix"
  assert_contains "$block" "hint: PR #80 merged" "the branch resolves to an inspectable PR"
  assert_not_contains "$block" "no PR found" "the branch is not a separate unlinked claim"
  out=$(run_claim --sweep 800)
  assert_contains "$out" "sweep: #800 no-action state=open verdict=open coverage=complete link=-" "a branch match cannot close or link"
  put "repos/o/r/pulls?head=carol:fix-800" '[{"number":80,"state":"closed","merged_at":"2026-02-02T00:00:00Z","body":"Fixes #800","title":"fix 800","user":{"login":"carol"}}]'
  out=$(run_claim --sweep 800)
  assert_contains "$out" "sweep: #800 close-candidate state=open verdict=fixed-on-main coverage=complete link=#80" "a fixing reference in the fork PR establishes a fix"
  build_forge
  pass "fork PRs need a fixing reference before close or link recommendations"
}

test_related_commit_after_helper_withdrawal() {
  local n out
  for n in 4412 4482 4316; do
    plain_issue "$n" alice
    put "repos/o/r/issues/$n/timeline?per_page=100" '[{"event":"cross-referenced","source":{"issue":{"number":70,"state":"closed","title":"another issue","body":"Related, and not closed by this: #4412, #4482, #4316","repository":{"full_name":"o/r"},"pull_request":{"merged_at":"2026-02-04T00:00:00Z"}}}}]'
    put "repos/o/r/issues/$n/comments?per_page=100" '[{"user":{"login":"maint"},"author_association":"OWNER","body":"<!-- triage: x outcome=existing-pr --> existing-pr -> #60"}]'
  done
  out=$(run_claim 4412 4482 4316)
  for n in 4412 4482 4316; do
    assert_contains "$(block_of "$out" "$n")" "verdict: claimed" "only the live helper claims issue $n"
    assert_contains "$(block_of "$out" "$n")" "hint: commit $RELATED_SHA" "the incidental commit remains inspectable"
    assert_contains "$(block_of "$out" "$n")" "hint: PR #70 merged" "the merged timeline reference remains inspectable"
    assert_not_contains "$(block_of "$out" "$n")" "merged: " "neither incidental reference establishes a fix"
  done
  put "repos/o/r/pulls/60" '{"number":60,"state":"closed","merged_at":null,"body":"Fixes #4412, fixes #4482, fixes #4316","title":"withdrawn helper"}'
  out=$(run_claim --sweep 4412 4482 4316)
  for n in 4412 4482 4316; do
    assert_contains "$out" "sweep: #$n no-action state=open verdict=open coverage=complete link=-" "withdrawing the helper cannot promote incidental references"
  done
  put "repos/o/r/issues/4412/timeline?per_page=100" '[{"event":"cross-referenced","source":{"issue":{"number":70,"state":"closed","body":"Fixes #4412","repository":{"full_name":"o/r"},"pull_request":{"merged_at":"2026-02-04T00:00:00Z"}}}}]'
  out=$(run_claim --sweep 4412)
  assert_contains "$out" "sweep: #4412 close-candidate state=open verdict=fixed-on-main coverage=complete link=-" "an explicit fixing reference in a merged timeline PR establishes a fix"
  build_forge
  pass "related commits and timeline references remain hints after helper withdrawal"
}

test_fixing_reference_boundaries_and_aggregation() {
  local out n
  for n in 201 202 203 204; do plain_issue "$n" alice; done
  put "repos/o/r/issues/201/timeline?per_page=100" '[{"event":"cross-referenced","source":{"issue":{"number":70,"state":"closed","title":"reference","repository":{"full_name":"o/r"},"pull_request":{"merged_at":"2026-02-04T00:00:00Z"}}}}]'
  out=$(run_claim 201)
  assert_contains "$out" "hint: PR #70 merged" "a commit subject cannot turn a PR reference into fixing evidence"
  assert_contains "$out" "merged: commit " "the actual fixing commit retains its own identity"
  out=$(run_claim --sweep 201 202 203 204)
  for n in 201 202 203; do
    assert_contains "$out" "sweep: #$n close-candidate state=open verdict=fixed-on-main coverage=complete link=" "supported fixing syntax resolves issue $n"
  done
  assert_contains "$out" "sweep: #204 no-action state=open verdict=open coverage=complete link=-" "foreign references, larger numbers, and keyword suffixes cannot fix this issue"
  pass "fixing references respect repository and number boundaries and preserve commit identity"
}

test_stamped_pr_fixing_references() {
  local out
  plain_issue 600 alice
  put "repos/o/r/issues/600/comments?per_page=100" '[{"user":{"login":"maint"},"author_association":"MEMBER","body":"<!-- triage: x outcome=existing-pr --> existing-pr -> #66"}]'
  put "repos/o/r/pulls/66" '{"number":66,"state":"closed","merged_at":"2026-02-02T00:00:00Z","title":"Fixes #600","body":"Refs #600"}'
  out=$(run_claim 600)
  assert_contains "$out" "hint: PR #66 merged" "an existing-pr stamp and title cannot establish a fix"
  out=$(run_claim --sweep 600)
  assert_contains "$out" "sweep: #600 no-action state=open verdict=open coverage=complete link=-" "an incidental stamped PR cannot recommend closure"
  put "repos/o/r/pulls/66" '{"number":66,"state":"closed","merged_at":"2026-02-02T00:00:00Z","body":"RESOLVES: o/r#600"}'
  out=$(run_claim --sweep 600)
  assert_contains "$out" "sweep: #600 close-candidate state=open verdict=fixed-on-main coverage=complete link=-" "a fixing stamped PR may recommend closure without relinking"
  put "repos/o/r/issues/600/timeline?per_page=100" '[{"event":"cross-referenced","source":{"issue":{"number":66,"state":"closed","body":"Fixes #600","repository":{"full_name":"o/r"},"pull_request":{"merged_at":"2026-02-02T00:00:00Z"}}}}]'
  out=$(run_claim 600)
  assert_contains "$out" "merged: PR #66 merged" "reusing a timeline PR for a stamp preserves fixing evidence"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^merged: ')" "one PR remains one evidence item"
  pass "stamps preserve claims but require fixing references for merged verdicts"
}

test_failed_reads_never_yield_open() {
  local out rc

  fail_on "repos/o/r/issues/100/timeline?per_page=100" "gh: API rate limit exceeded (HTTP 403)"
  rc=0; out=$(run_claim 100) || rc=$?
  heal "repos/o/r/issues/100/timeline?per_page=100"
  expect_code 1 "$rc" "a rate-limited timeline"
  assert_contains "$out" "verdict: unknown" "a rate-limited timeline must not read as open"
  assert_contains "$out" "coverage: incomplete (timeline)" "the failed check is named"
  assert_contains "$out" "API rate limit exceeded" "the forge's reason is disclosed"

  fail_on "repos/bob/r" "gh: Server Error (HTTP 502)"
  rc=0; out=$(run_claim 100) || rc=$?
  heal "repos/bob/r"
  expect_code 1 "$rc" "an unreadable fork"
  assert_contains "$out" "verdict: unknown" "a fork read failure other than 404 is not open"
  assert_contains "$out" "fork=failed" "the fork check is marked failed"

  fail_on "repos/o/r/issues/100" "gh: Not Found (HTTP 404)"
  rc=0; out=$(run_claim 100) || rc=$?
  heal "repos/o/r/issues/100"
  expect_code 1 "$rc" "an unreadable issue"
  assert_contains "$out" "checks: issue=failed" "an unreadable issue is unknown"

  rc=0; out=$(run_claim 900) || rc=$?
  expect_code 1 "$rc" "a pull-request number"
  assert_contains "$out" "is a pull request, not an issue" "a PR number is refused as an issue"

  fail_on "repos/o/r/pulls/60" "gh: API rate limit exceeded (HTTP 403)"
  rc=0; out=$(run_claim 400) || rc=$?
  heal "repos/o/r/pulls/60"
  assert_contains "$out" "claim: PR #60 unknown" "an unreadable stamped PR stays a claim"
  assert_contains "$out" "stamps=partial" "the stamp lookup failure is disclosed"
  pass "failed, rate-limited, and misdirected reads produce unknown, never open"
}

test_short_or_unverified_corpus_is_disclosed() {
  local out rc search
  search="search/issues?q=repo:o/r+is:pr+is:open&per_page=1"

  put "$search" '{"total_count":9,"incomplete_results":false}'
  rc=0; out=$(run_claim 100) || rc=$?
  expect_code 1 "$rc" "a truncated corpus"
  assert_contains "$out" "corpus=truncated(5/9)" "a short corpus is reported with its counts"
  assert_contains "$out" "verdict: unknown" "a short corpus must not support open"
  rc=0; out=$(run_claim 4018) || rc=$?
  assert_contains "$out" "verdict: claimed" "positive evidence still stands on a short corpus"
  assert_contains "$out" "coverage: incomplete (corpus)" "but coverage says it is incomplete"

  fail_on "$search" "gh: API rate limit exceeded for search (HTTP 403)"
  rc=0; out=$(run_claim 100) || rc=$?
  heal "$search"
  assert_contains "$out" "corpus=unverified(5/?)" "an unreadable total leaves completeness unverified"
  assert_contains "$out" "verdict: unknown" "an unverified corpus must not support open"

  put "$search" '{"total_count":5,"incomplete_results":false}'
  fail_on "repos/o/r/pulls?state=open&per_page=100" "gh: Bad Gateway (HTTP 502)"
  rc=0; out=$(run_claim 100) || rc=$?
  heal "repos/o/r/pulls?state=open&per_page=100"
  assert_contains "$out" "corpus=failed" "a failed corpus fetch is reported"
  assert_contains "$out" "verdict: unknown" "a failed corpus must not support open"
  pass "a short, unverified, or failed corpus is disclosed and never trusted for open"
}

test_history_that_cannot_look_is_unknown() {
  local out rc=0 bare="$TMP_ROOT/noremote"
  fm_git_init_commit "$bare"
  : > "$FIX/calls.log"
  out=$(PATH="$FAKEBIN:$PATH" "$SCRIPT" --repo o/r --git-dir "$bare" 100) || rc=$?
  expect_code 1 "$rc" "history without a matching remote"
  assert_contains "$out" "history=failed" "a clone of another repository cannot be searched"
  assert_contains "$out" "no remote of" "the reason is disclosed"
  assert_contains "$out" "verdict: unknown" "history that could not look does not support open"
  rc=0
  out=$(run_claim --ref origin/nope 100) || rc=$?
  expect_code 1 "$rc" "an unresolvable ref"
  assert_contains "$out" "ref origin/nope does not resolve" "a missing ref is disclosed"
  pass "a history check that cannot look yields unknown"
}

test_corpus_is_fresh_for_each_run() {
  local out n rc saved="$TMP_ROOT/corpus.json" option
  out=$(run_claim 4018 100 200)
  n=$(grep -c 'pulls?state=open' "$FIX/calls.log" || true)
  assert_equals 1 "$n" "one run over three issues fetches the corpus once"

  put "repos/o/r/pulls?state=open&per_page=100" '[]'
  put "search/issues?q=repo:o/r+is:pr+is:open&per_page=1" '{"total_count":0}'
  out=$(run_claim 100)
  assert_contains "$out" "verdict: open" "an empty fresh corpus allows an open verdict"

  put "repos/o/r/pulls?state=open&per_page=100" '[{"number":55,"title":"helper","body":"Fixes #100","head":{"ref":"fix-100","repo":{"owner":{"login":"bob"}}},"user":{"login":"bob"},"draft":true}]'
  put "search/issues?q=repo:o/r+is:pr+is:open&per_page=1" '{"total_count":1}'
  put "repos/bob/r/branches?per_page=100" '[{"name":"fix-100"}]'
  out=$(run_claim 100)
  assert_contains "$out" "verdict: claimed" "a newly opened unlinked PR must be discovered on the next run"
  assert_contains "$out" "claim: PR #55 open(draft)" "the new claiming PR is named"
  assert_contains "$out" "[corpus:body+branch,fork,fixes]" "corpus and fork evidence share the explicit fixing reference"
  out=$(run_claim --sweep 100)
  assert_contains "$out" "sweep: #100 leave-open state=open verdict=claimed coverage=complete link=#55" "a live fixing PR can be linked"

  put "repos/o/r/pulls?state=open&per_page=100" '[]'
  put "search/issues?q=repo:o/r+is:pr+is:open&per_page=1" '{"total_count":0}'
  put "repos/bob/r/branches?per_page=100" '[]'
  out=$(run_claim 100)
  assert_contains "$out" "verdict: open" "a withdrawn PR must not survive from the previous run"
  assert_not_contains "$out" "PR #55" "the old claim is absent"

  for option in --corpus --save-corpus; do
    rc=0
    out=$(run_claim "$option" "$saved" 100 2>&1) || rc=$?
    expect_code 2 "$rc" "cross-run corpus option $option is refused"
    assert_contains "$out" "unknown option: $option" "persistence is not part of the command interface"
  done
  [ ! -e "$saved" ] || fail "refused corpus export wrote a file"
  build_forge
  pass "each run fetches one fresh corpus and refuses persistence options"
}

test_corpus_links_require_fixing_references() {
  local body out
  for body in 'Fixes #4018' 'CLOSES: o/r#4018' 'resolved https://github.com/o/r/issues/4018' \
    'Refs #4018; Fixes other/r#4018' 'Refs #4018; Fixes #40181' 'Refs #4018; unfixes #4018'; do
    put "repos/o/r/pulls?state=open&per_page=100" "$(jq -nc --arg body "$body" '[{number:52,title:"Fixes #4018",body:$body,head:{ref:"fix-4018"},user:{login:"dan"}}]')"
    put "search/issues?q=repo:o/r+is:pr+is:open&per_page=1" '{"total_count":1}'
    out=$(run_claim --sweep 4018)
    case "$body" in
      Refs*) assert_contains "$out" "coverage=complete link=-" "incidental or foreign body citations cannot link even when the title says Fixes" ;;
      *) assert_contains "$out" "coverage=complete link=#52" "a body fixing reference allows a link recommendation" ;;
    esac
    assert_contains "$out" "sweep: #4018 leave-open state=open verdict=claimed" "every matching live PR remains a claim"
  done
  build_forge
  pass "only same-repository fixing references yield corpus link recommendations"
}

test_every_forge_call_is_a_read() {
  run_claim --symbol 300:magic_symbol 4018 100 200 300 400 800 >/dev/null || true
  [ -s "$FIX/calls.log" ] || fail "no forge calls were recorded"
  assert_no_grep "POST" "$FIX/calls.log" "no forge write may be issued"
  assert_no_grep "PATCH" "$FIX/calls.log" "no forge write may be issued"
  assert_no_grep "DELETE" "$FIX/calls.log" "no forge write may be issued"
  assert_no_grep "--method" "$FIX/calls.log" "no forge write may be issued"
  if grep -v '^api ' "$FIX/calls.log" >/dev/null; then
    fail "every gh call must be a read through gh api"
  fi
  pass "every forge call is a read"
}

test_sweep_dispositions() {
  local out rc=0
  out=$(run_claim --sweep --symbol 300:magic_symbol 4018 100 200 300 400 800) || rc=$?
  expect_code 0 "$rc" "a sweep with every verdict decided"
  assert_contains "$out" "sweep: #4018 leave-open state=open verdict=claimed coverage=complete link=-" \
    "an incidental body citation keeps the issue claimed without recommending a link"
  assert_contains "$out" "sweep: #100 no-action state=open verdict=open" "nothing found needs no action"
  assert_contains "$out" "sweep: #200 close-candidate state=open verdict=fixed-on-main coverage=complete link=$FIX200_SHA" \
    "a fixing commit is a close and link candidate"
  assert_contains "$out" "sweep: #300 no-action state=open verdict=open coverage=complete link=-" \
    "a symbol-only match cannot recommend closure or a link"
  assert_contains "$out" "sweep: #400 leave-open" "a live stamped PR keeps the issue open despite merged work"
  assert_contains "$out" "nothing was written to the forge" "the sweep states it wrote nothing"

  out=$(run_claim --sweep 4019) || true
  assert_contains "$out" "sweep: #4019 leave-open state=open verdict=claimed coverage=complete link=-" \
    "a title-only match is never a link candidate"

  fail_on "repos/o/r/issues/200/timeline?per_page=100" "gh: API rate limit exceeded (HTTP 403)"
  rc=0; out=$(run_claim --sweep 200) || rc=$?
  heal "repos/o/r/issues/200/timeline?per_page=100"
  assert_contains "$out" "sweep: #200 undetermined state=open verdict=fixed-on-main coverage=incomplete" \
    "merged evidence with incomplete coverage is never a close candidate"
  pass "sweep dispositions come only from durable evidence and full coverage"
}

test_sweep_all_open_issues() {
  local out rc=0
  put "search/issues?q=repo:o/r+is:issue+is:open&per_page=1" '{"total_count":2,"incomplete_results":false}'
  put "repos/o/r/issues?state=open&per_page=100" "[$(issue_json 100 bob),$(issue_json 4018 alice),{\"number\":52,\"pull_request\":{\"url\":\"u\"}}]"
  out=$(run_claim --sweep) || rc=$?
  expect_code 0 "$rc" "a whole-repository sweep"
  assert_contains "$out" "sweep: #100 no-action" "listed issue 100 was screened"
  assert_contains "$out" "sweep: #4018 leave-open" "listed issue 4018 was screened"
  assert_not_contains "$out" "sweep: #52 " "a pull request in the issue list is not screened"
  assert_contains "$out" "sweep: 2 issue(s) screened" "the count is reported"

  put "search/issues?q=repo:o/r+is:issue+is:open&per_page=1" '{"total_count":7,"incomplete_results":false}'
  out=$(run_claim --sweep) || true
  assert_contains "$out" "open-issue list is short: listed 2 of 7" "a short issue list is disclosed"
  pass "a sweep with no issue numbers screens every listed open issue"
}

test_usage_refusals() {
  local rc
  for args in "" "--repo o/r" "--repo bad 1" "--repo o/r 01" "--repo o/r x1" \
    "--repo o/r --symbol 5:x 1" "--repo o/r --symbol 1 1" "--repo o/r --nope 1"; do
    rc=0
    # shellcheck disable=SC2086
    PATH="$FAKEBIN:$PATH" "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
    expect_code 2 "$rc" "usage refusal for: $args"
  done
  PATH="$FAKEBIN:$PATH" "$SCRIPT" --help | grep -q 'closes, labels, and comments on nothing' \
    || fail "--help must lead with the limits"
  pass "usage errors exit 2 and --help states the limits"
}

test_number_boundary_and_corpus_body_claim
test_title_and_branch_matches_are_claims
test_nothing_found_with_full_coverage_is_open
test_history_requires_a_fixing_reference
test_stamps_timeline_and_hints
test_fork_branch_heading_a_merged_pr
test_related_commit_after_helper_withdrawal
test_fixing_reference_boundaries_and_aggregation
test_stamped_pr_fixing_references
test_failed_reads_never_yield_open
test_short_or_unverified_corpus_is_disclosed
test_history_that_cannot_look_is_unknown
test_corpus_is_fresh_for_each_run
test_corpus_links_require_fixing_references
test_every_forge_call_is_a_read
test_sweep_dispositions
test_sweep_all_open_issues
test_usage_refusals

#!/usr/bin/env bash
# PR health monitor behavior through its registered check and the watcher.
#
# Cases drive the registered check against a fake forge, with ownership from
# real task records, task copies and durable contributions.
# A barrier at the forge boundary proves reads fan out across owned PRs.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-health)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BASE_1=1111111111111111111111111111111111111111
BASE_2=2222222222222222222222222222222222222222
BASE_3=3333333333333333333333333333333333333333

new_home() { # name -> home with the monitor flag on
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin" "$home/forge" "$home/root/bin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  : > "$home/config/pr-health-monitor"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  # REST serves the PR state and mergeability, GraphQL the base branch
  # commit, review requests, reviews and the head's check rollup; both render
  # from one model file per PR. Every read is logged.
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${GH_HOST:-}" = github.com ] || { echo "wrong GitHub host" >&2; exit 1; }
printf '%s\n' "$*" >> "$FORGE/calls.log"
model() {
  local n=$1 attempt
  if [ -f "$FORGE/barrier-count" ]; then
    : > "$FORGE/arrived-$n"
    for attempt in $(seq 1 100); do
      [ "$(find "$FORGE" -name 'arrived-*' | wc -l)" -ge "$(cat "$FORGE/barrier-count")" ] && break
      sleep 0.02
    done
    [ "$(find "$FORGE" -name 'arrived-*' | wc -l)" -ge "$(cat "$FORGE/barrier-count")" ] || exit 1
  fi
  cat "$FORGE/pr-$n.json"
}
case "$1 $2" in
  'api graphql')
    case "$*" in
      *reviewThreads*) printf '[{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}]\n'; exit 0 ;;
    esac
    n= suite_cursor=
    for arg in "$@"; do case "$arg" in number=*) n=${arg#number=} ;; suiteCursor=*) suite_cursor=${arg#suiteCursor=} ;; esac; done
    case "$*" in *'after:$suiteCursor'*)
      # The check-suite query: page 1 is suites, a later page suites_page2,
      # and every page claims another while suites_truncated.
      model "$n" | jq --arg cursor "$suite_cursor" '(if $cursor == "" then (.suites // []) else (.suites_page2 // []) end) as $page
        | {data:{repository:{pullRequest:{headRefOid:(.graphql_head // .head),
        commits:{nodes:[{commit:{oid:(.graphql_head // .head),checkSuites:{
          pageInfo:{hasNextPage:((.suites_truncated // false) or ($cursor == "" and .suites_page2 != null)),endCursor:"s2"},
          nodes:[$page[] | {conclusion,app:{slug:"github-actions"},workflowRun:{workflow:{name}}}]}}}]}}}}}'
      exit 0 ;;
    esac
    model "$n" | jq '[{data:{repository:{pullRequest:{
      headRefOid:(.graphql_head // .head),isDraft:.draft,baseRef:{target:{oid:.base}},reviewDecision:(if has("reviewDecision") then .reviewDecision else "APPROVED" end),
      reviewRequests:{pageInfo:{hasNextPage:(.requests > 100)},
        nodes:[range([.requests, 100] | min) | {requestedReviewer:{__typename:"User"}}]},
      latestReviews:{nodes:[range(.reviews) | {author:{__typename:"User",login:"reviewer"}}]},
      statusCheckRollup:(if (.checks | length) == 0 then null else {
        contexts:{pageInfo:{hasNextPage:false},nodes:[.checks[] | {__typename:"CheckRun",name,
          status:(if .conclusion == null then "IN_PROGRESS" else "COMPLETED" end),
          conclusion,startedAt:(.at // "2026-10-21T00:00:00Z"),isRequired:.required}]}} end)}}}}]
      | if (.[0].data.repository.pullRequest.statusCheckRollup.contexts.nodes | length) > 100 then
          .[0] as $page | $page.data.repository.pullRequest.statusCheckRollup.contexts.nodes as $nodes
          | [$page | .data.repository.pullRequest.statusCheckRollup.contexts.nodes = $nodes[:100]
                   | .data.repository.pullRequest.statusCheckRollup.contexts.pageInfo = {hasNextPage:true,endCursor:"page2"},
             ($page | .data.repository.pullRequest.statusCheckRollup.contexts.nodes = $nodes[100:])]
        else . end' ;;
  'pr view')
    case "$*" in
      *headRefOid,reviewDecision*) model "${3##*/}" | jq '{headRefOid:.head,reviewDecision:""}' ;;
      *) printf 'https://github.com/o/r/pull/%s\n' "$3" ;;
    esac ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  'api repos/o/r/pulls/'*)
    rest=${2#repos/o/r/pulls/}
    if [ -f "$FORGE/interrupt-$rest" ]; then
      # Stop the whole pass mid-read, as a check timeout would. The case
      # records the pass's PID once it has started it.
      rm -f "$FORGE/interrupt-$rest"
      for attempt in $(seq 1 100); do [ -s "$FORGE/poll-pid" ] && break; sleep 0.05; done
      [ -s "$FORGE/poll-pid" ] && kill -TERM "$(cat "$FORGE/poll-pid")" && : > "$FORGE/interrupted"
      exit 1
    fi
    case "$rest" in
      *[!0-9]*) printf '[[]]\n' ;;
      *) model "$rest" | jq '{state:(if .state == "open" then "open" else "closed" end),
           merged_at:(if .state == "merged" then "2026-10-21T00:00:00Z" else null end),
           user:{login:"author"},draft,mergeable,head:{sha:.head},
           base:{sha:"0000000000000000000000000000000000000000"},labels:[(.labels // [])[] | {name:.}]}' ;;
    esac ;;
  'api -i')
    # The notifications feed, when a case serves one: 304 while unchanged.
    [ -f "$FORGE/notifications.json" ] || exit 1
    lm=$(cat "$FORGE/notifications-lm")
    case "$*" in *"If-Modified-Since: $lm"*) printf 'HTTP/2.0 304 Not Modified\r\n\r\n'; exit 1 ;; esac
    # Like GitHub, a conditional request ignores since= and answers with the
    # newest page; an unconditional one honors it.
    since=$(printf '%s\n' "$@" | sed -n 's/.*[?&]since=\([^&]*\).*/\1/p')
    case "$*" in *If-Modified-Since:*) since= ;; esac
    printf 'HTTP/2.0 200 OK\r\nLast-Modified: %s\r\n\r\n' "$lm"
    jq --arg since "$since" '[.[] | select(.updated_at >= $since)] | sort_by(.updated_at) | reverse | .[:50]' \
      "$FORGE/notifications.json" ;;
  'api repos/o/r/issues/'*) printf '[[]]\n' ;;
  'api repos/o/r/commits/'*)
    case "$2" in *check-runs*) printf '[{"check_runs":[]}]\n' ;; *) printf '[[]]\n' ;; esac ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  # gh-axi resolves the open PR for a branch, as fm-teardown.sh's lookup reads it.
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi %s\n' "$*" >> "$FORGE/calls.log"
branch=
while [ "$#" -gt 0 ]; do [ "$1" = --head ] && branch=$2; shift; done
if [ -f "$FORGE/branch-barrier-count" ]; then
  : > "$FORGE/branch-arrived-$(printf '%s' "$branch" | tr '/' '_')"
  for attempt in $(seq 1 100); do
    [ "$(find "$FORGE" -name 'branch-arrived-*' | wc -l)" -ge "$(cat "$FORGE/branch-barrier-count")" ] && break
    sleep 0.02
  done
  [ "$(find "$FORGE" -name 'branch-arrived-*' | wc -l)" -ge "$(cat "$FORGE/branch-barrier-count")" ] || exit 1
fi
file="$FORGE/branch-$(printf '%s' "$branch" | tr '/' '_')"
if [ -f "$file" ]; then
  printf '%s\n' 'count: 1' 'pull_requests[1]{number,title,state,author,draft,review}:' "  $(cat "$file"),\"t\",open,author,yes,none"
else
  printf '%s\n' 'count: 0' 'pull_requests: []'
fi
SH
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  : > "$home/forge/calls.log"
  printf '%s\n' "$home"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

pr() { # home number head base mergeable(true|false|null) draft(true|false)
  jq -n --arg head "$3" --arg base "$4" --argjson mergeable "$5" --argjson draft "$6" \
    '{state:"open",head:$head,base:$base,mergeable:$mergeable,draft:$draft,requests:1,reviews:0,checks:[]}' \
    > "$1/forge/pr-$2.json"
}

set_pr() { # home number jq-update
  jq "$3" "$1/forge/pr-$2.json" > "$1/forge/update.json" || fail 'fixture update failed'
  mv "$1/forge/update.json" "$1/forge/pr-$2.json"
}

task() { # home id [meta lines...]
  local home=$1 id=$2; shift 2
  { printf 'kind=ship\n'; printf '%s\n' "$@"; } > "$home/state/$id.meta"
  chmod 600 "$home/state/$id.meta"
}

arm() {
  with_home "$1" "$ROOT/bin/fm-pr-health.sh" arm >/dev/null || fail 'could not arm the PR health monitor'
}

pass_once() { # home -> the registered check's output
  with_home "$1" bash "$1/state/pr-health.check.sh" || fail 'the PR health check failed'
}

expect_silent() { # home why
  local out
  out=$(pass_once "$1")
  [ -z "$out" ] || fail "$2: $out"
}

expect_one() { # home pattern why
  local out
  out=$(pass_once "$1")
  if [ "$(printf '%s\n' "$out" | grep -c .)" != 1 ] || ! printf '%s\n' "$out" | grep -E "$2" >/dev/null; then
    fail "$3: $out"
  fi
}

test_unknown_then_dirty_wakes_once() {
  local home
  home=$(new_home unknown-dirty)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" null false
  arm "$home"
  expect_silent "$home" 'UNKNOWN mergeability must not read as a conflict'
  set_pr "$home" 8 '.mergeable = false'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/8 conflicts with its base at latest commit aaaaaaa .*ship1' \
    'UNKNOWN then DIRTY must wake once'
  pass 'UNKNOWN then DIRTY wakes once'
}

test_dirty_again_at_same_commits_is_silent() {
  local home
  home=$(new_home dirty-again)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  arm "$home"
  expect_one "$home" 'conflicts with its base' 'a first DIRTY read must wake'
  expect_silent "$home" 'DIRTY again at the same commits must not wake'
  set_pr "$home" 8 '.mergeable = null'
  expect_silent "$home" 'UNKNOWN after DIRTY must not clear or wake'
  set_pr "$home" 8 '.mergeable = false'
  expect_silent "$home" 'DIRTY after UNKNOWN at the same commits must not wake'
  pass 'DIRTY seen again at the same commits wakes nothing'
}

test_conflict_once_per_latest_commit() {
  local home
  home=$(new_home conflict-returns)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  arm "$home"
  expect_one "$home" 'conflicts with its base' 'the first conflict must wake'
  set_pr "$home" 8 ".mergeable = true | .base = \"$BASE_2\""
  expect_silent "$home" 'a cleared conflict must not wake'
  set_pr "$home" 8 ".mergeable = false | .base = \"$BASE_3\""
  expect_silent "$home" 'a returning conflict at the same latest commit must not repeat'
  set_pr "$home" 8 ".base = \"$BASE_1\""
  expect_silent "$home" 'a base move must not repeat a conflict at the same latest commit'
  set_pr "$home" 8 ".head = \"$HEAD_B\""
  expect_one "$home" 'conflicts with its base at latest commit bbbbbbb' 'a new latest commit must notify again'
  set_pr "$home" 8 ".head = \"$HEAD_A\""
  expect_silent "$home" 'returning to an already notified latest commit must not repeat'
  pass 'a conflict notifies once per latest commit despite recovery or base movement'
}

test_adopted_draft_red_required_check_after_pause_wakes_once() {
  local home wt
  home=$(new_home adopted-draft)
  wt="$home/copy"
  git init -q -b ART-9999-infer-tree-diameter "$wt"
  git -C "$wt" remote add origin git@github.com:o/r.git
  # The recorded branch does not match the adopted branch the PR uses.
  task "$home" slot9999 "worktree=$wt" branch=fm/artemis-slot-art-9999
  printf '5\n' > "$home/forge/branch-ART-9999-infer-tree-diameter"
  pr "$home" 5 "$HEAD_A" "$BASE_1" true true
  set_pr "$home" 5 '.checks = [{name:"CI Status",conclusion:null,required:true},
    {name:"Backend",conclusion:null,required:true},{name:"E2E Tests (independent)",conclusion:null,required:false}]'
  arm "$home"
  printf 'paused [at=1792500000]: Checks are still running on the draft.\n' > "$home/state/slot9999.status"
  expect_silent "$home" 'running checks on a draft must not wake'
  set_pr "$home" 5 '.checks[2].conclusion = "FAILURE" | .checks[1].conclusion = "FAILURE"'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/5 has failing required checks at latest commit aaaaaaa: Backend \(task slot9999\)$' \
    'a failing required check on an adopted draft must wake once'
  expect_silent "$home" 'the same failing required check at the same commit must not wake again'
  # The worker reruns Backend, it passes, and the slow required check then fails at the same commit.
  set_pr "$home" 5 '.checks[1].conclusion = "SUCCESS" | .checks[0].conclusion = "FAILURE"'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/5 has failing required checks at latest commit aaaaaaa: CI Status \(task slot9999\)$' \
    'a required check that newly fails at an already reported commit must wake once'
  set_pr "$home" 5 '.checks[1].conclusion = "FAILURE"'
  expect_silent "$home" 'a check already reported at this commit must not repeat when it fails again'
  pass 'each required check that fails on an adopted draft wakes once per latest commit'
}

test_reported_failure_does_not_hide_a_later_required_failure() {
  local home
  home=$(new_home optional-then-required)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 8 '.checks = [{name:"E2E Tests (independent)",conclusion:"FAILURE",required:false}]'
  arm "$home"
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/8 has failing checks at latest commit aaaaaaa: E2E Tests \(independent\) \(task ship1\)$' \
    'a reported failure must wake when no check is required'
  expect_silent "$home" 'the reported failure must not repeat at the same commit'
  set_pr "$home" 8 '.checks += [{name:"Backend",conclusion:"FAILURE",required:true}]'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/8 has failing required checks at latest commit aaaaaaa: Backend \(task ship1\)$' \
    'a required check that appears and fails at the same commit must wake'
  expect_silent "$home" 'the reported required failure must not repeat'
  set_pr "$home" 8 '.checks += [{name:"optional-later",conclusion:"FAILURE",required:false}]'
  expect_silent "$home" 'a newly failing optional check must not wake once a required check has reported'
  pass 'a fallback notification does not hide a later required failure at the same commit'
}

test_replaced_cancelled_run_is_not_failing() {
  local home
  home=$(new_home rerun)
  task "$home" ship1 pr=https://github.com/o/r/pull/9
  pr "$home" 9 "$HEAD_A" "$BASE_1" true false
  # GitHub keeps the run a base move cancelled beside the rerun that passed.
  set_pr "$home" 9 '.checks = [{name:"CI Status",conclusion:"CANCELLED",required:true,at:"2026-10-21T01:00:00Z"},
    {name:"CI Status",conclusion:"SUCCESS",required:true,at:"2026-10-21T01:05:00Z"}]'
  arm "$home"
  expect_silent "$home" 'a cancelled run that a passing rerun replaced must not read as failing'
  set_pr "$home" 9 '.checks += [{name:"CI Status",conclusion:"FAILURE",required:true,at:"2026-10-21T01:10:00Z"}]'
  expect_one "$home" 'pull/9 has failing required checks at latest commit aaaaaaa: CI Status' \
    'a newer failing run of the same check must wake'
  pass 'each check is judged by its newest run'
}

test_latest_commit_moving_between_reads_waits() {
  local home
  home=$(new_home moving-head)
  task "$home" ship1 pr=https://github.com/o/r/pull/7
  pr "$home" 7 "$HEAD_A" "$BASE_1" false false
  set_pr "$home" 7 ".graphql_head = \"$HEAD_B\""
  arm "$home"
  expect_silent "$home" 'reads that disagree on the latest commit must not wake'
  set_pr "$home" 7 'del(.graphql_head)'
  expect_one "$home" 'pull/7 conflicts with its base at latest commit aaaaaaa' 'reads that agree again must wake'
  pass 'a latest commit that moves between the two reads waits for the next pass'
}

test_other_homes_red_check_is_silent() {
  local home other out
  home=$(new_home this-home)
  other=$(new_home other-home)
  task "$other" theirs pr=https://github.com/o/r/pull/20
  pr "$other" 20 "$HEAD_A" "$BASE_1" true false
  set_pr "$other" 20 '.checks = [{name:"CI Status",conclusion:"FAILURE",required:true}]'
  cp "$other/forge/pr-20.json" "$home/forge/pr-20.json"
  task "$home" mine pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" true false
  # This home's worker mentions the other home's PR in a status line.
  printf 'working [at=1792500000]: Reviewed https://github.com/o/r/pull/20 for a teammate.\n' > "$home/state/mine.status"
  # A secondmate's copy sits on a branch whose PR belongs to the secondmate's own home.
  git init -q -b mate-branch "$home/mate-copy"
  git -C "$home/mate-copy" remote add origin git@github.com:o/r.git
  printf 'kind=secondmate\nworktree=%s\n' "$home/mate-copy" > "$home/state/mate.meta"
  printf '20\n' > "$home/forge/branch-mate-branch"
  arm "$home"
  arm "$other"
  out=$(pass_once "$other")
  printf '%s\n' "$out" | grep -F 'https://github.com/o/r/pull/20 has failing required checks' >/dev/null \
    || fail "the owning home must wake for its own red PR: $out"
  expect_silent "$home" "another home's red PR must wake nothing in this home"
  if grep -E 'pulls/20$|number=20( |$)|--head mate-branch' "$home/forge/calls.log" >/dev/null; then
    fail "this home read another home's PR: $(cat "$home/forge/calls.log")"
  fi
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" owned) || fail 'owned PRs could not be listed'
  printf '%s\n' "$out" | jq -e 'any(.[]; .url == "https://github.com/o/r/pull/20") | not' >/dev/null \
    || fail "a PR named only in a status line became owned: $out"
  pass "a red check on another home's PR wakes nothing in this home"
}

test_enrolled_before_ready_and_after_cleanup_still_wake() {
  local home wt
  home=$(new_home enrolled-early)
  wt="$home/copy"
  git init -q -b feature-12 "$wt"
  git -C "$wt" remote add origin git@github.com:o/r.git
  # The task opened its PR but has recorded no pr= yet.
  task "$home" early "worktree=$wt"
  printf '12\n' > "$home/forge/branch-feature-12"
  pr "$home" 12 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 12 '.checks = [{name:"CI Status",conclusion:null,required:true}]'
  arm "$home"
  expect_silent "$home" 'running checks must not wake'
  set_pr "$home" 12 '.checks[0].conclusion = "FAILURE"'
  expect_one "$home" 'pull/12 has failing required checks' 'a PR enrolled before its ready report must wake'
  # Worker cleanup removes the task record and its copy.
  rm -f "$home/state/early.meta"
  rm -rf "$wt"
  set_pr "$home" 12 ".head = \"$HEAD_B\" | .mergeable = false | .checks[0].conclusion = null"
  expect_one "$home" 'pull/12 conflicts with its base at latest commit bbbbbbb' 'a PR kept after cleanup must wake'
  pass 'a PR enrolled before any ready report, and one kept after cleanup, both still wake'
}

test_open_pr_replacing_a_closed_one_on_the_same_branch_is_discovered() {
  local home wt
  home=$(new_home replaced-pr)
  wt="$home/copy"
  git init -q -b feature-12 "$wt"
  git -C "$wt" remote add origin git@github.com:o/r.git
  task "$home" early "worktree=$wt"
  printf '12\n' > "$home/forge/branch-feature-12"
  pr "$home" 12 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 12 '.checks = [{name:"CI Status",conclusion:null,required:true}]'
  arm "$home"
  expect_silent "$home" 'running checks must not wake'
  # Still before any ready report, the worker closes PR 12 and opens PR 13 from the unchanged branch.
  set_pr "$home" 12 '.state = "closed"'
  printf '13\n' > "$home/forge/branch-feature-12"
  pr "$home" 13 "$HEAD_B" "$BASE_1" true false
  set_pr "$home" 13 '.checks = [{name:"CI Status",conclusion:"FAILURE",required:true}]'
  expect_silent "$home" 'closing the cached PR must not wake'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/13 has failing required checks at latest commit bbbbbbb: CI Status \(task early\)$' \
    'the open PR on the unchanged branch must replace the closed one'
  expect_silent "$home" 'the replacement PR must dedupe like any other'
  pass 'an open PR that replaces a closed one on the same task branch is discovered'
}

test_green_without_reviewer_is_silent() {
  local home
  home=$(new_home no-reviewer)
  task "$home" hotfix pr=https://github.com/o/r/pull/40
  pr "$home" 40 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 40 '.requests = 0 | .checks = [{name:"CI Status",conclusion:null,required:true}]'
  arm "$home"
  expect_silent "$home" 'a PR whose required check is still running is not green yet'
  set_pr "$home" 40 '.checks[0].conclusion = "SUCCESS"'
  expect_silent "$home" 'a green PR without a reviewer is outside the notification scope'
  expect_silent "$home" 'the same green PR must not wake twice at one latest commit'
  set_pr "$home" 40 ".base = \"$BASE_2\""
  expect_silent "$home" 'a base move alone must not repeat the missing-reviewer wake'
  set_pr "$home" 40 ".head = \"$HEAD_B\""
  expect_silent "$home" 'a new green latest commit without a reviewer must stay silent'
  set_pr "$home" 40 ".head = \"$HEAD_A\" | .base = \"$BASE_3\" | .requests = 1"
  expect_silent "$home" 'a PR with a requested reviewer must not wake'
  set_pr "$home" 40 '.requests = 0 | .reviews = 1'
  expect_silent "$home" 'a PR a reviewer already reviewed must not wake'
  set_pr "$home" 40 '.reviews = 0 | .draft = true'
  expect_silent "$home" 'a green draft must not ask for a reviewer'
  pass 'a green PR without a reviewer never notifies'
}

test_base_without_required_checks_counts_any_failing_check() {
  local home
  home=$(new_home no-required)
  task "$home" a pr=https://github.com/o/r/pull/30
  task "$home" b pr=https://github.com/o/r/pull/31
  pr "$home" 30 "$HEAD_A" "$BASE_1" true false
  pr "$home" 31 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 30 '.checks = [{name:"lint",conclusion:"SUCCESS",required:false},{name:"test",conclusion:"FAILURE",required:false}]'
  set_pr "$home" 31 '.checks = [{name:"CI Status",conclusion:"SUCCESS",required:true},{name:"test",conclusion:"FAILURE",required:false}]'
  arm "$home"
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/30 has failing checks at latest commit aaaaaaa: test \(task a\)$' \
    'only the base with no required checks must notify for its reported failure'
  [ "$(grep -c 'pulls/3[01]$' "$home/forge/calls.log")" = 2 ] || fail "both owned PRs must still be read: $(cat "$home/forge/calls.log")"
  expect_silent "$home" 'the fallback must retain once-per-check deduplication'
  pass 'a base with no required checks counts a failing reported check'
}

test_retired_contribution_is_not_reclaimed_from_the_cached_branch() {
  local home wt before
  home=$(new_home retired-cached)
  wt="$home/copy"
  git init -q -b feature-12 "$wt"
  git -C "$wt" remote add origin git@github.com:o/r.git
  task "$home" early "worktree=$wt"
  printf '12\n' > "$home/forge/branch-feature-12"
  pr "$home" 12 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 12 '.checks = [{name:"CI Status",conclusion:null,required:true}]'
  arm "$home"
  expect_silent "$home" 'running checks must not wake'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" retire early https://github.com/o/r/pull/12 captain 'handed to another home' >/dev/null \
    || fail 'could not retire the discovered contribution'
  set_pr "$home" 12 '.checks[0].conclusion = "FAILURE" | .mergeable = false'
  before=$(grep -c 'pulls/12$' "$home/forge/calls.log")
  expect_silent "$home" 'a retired PR must not wake while its branch is still cached'
  expect_silent "$home" 'a retired PR must stay silent on later passes'
  [ "$(grep -c 'pulls/12$' "$home/forge/calls.log")" = "$before" ] || fail "a retired PR was read again: $(cat "$home/forge/calls.log")"
  pass 'a retired contribution is not reclaimed through the cached branch lookup'
}

test_retired_contribution_is_not_reclaimed_by_a_fresh_branch_lookup() {
  local home wt out
  home=$(new_home retired-fresh)
  wt="$home/copy"
  git init -q -b feature-12 "$wt"
  git -C "$wt" remote add origin git@github.com:o/r.git
  task "$home" early "worktree=$wt"
  printf '12\n' > "$home/forge/branch-feature-12"
  pr "$home" 12 "$HEAD_A" "$BASE_1" false false
  set_pr "$home" 12 '.checks = [{name:"CI Status",conclusion:"FAILURE",required:true}]'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" enroll early https://github.com/o/r/pull/12 >/dev/null || fail 'could not enroll the PR'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" retire early https://github.com/o/r/pull/12 captain 'handed to another home' >/dev/null \
    || fail 'could not retire the contribution'
  arm "$home"
  expect_silent "$home" 'a retired PR found afresh on the task branch must not wake'
  if grep -E 'pulls/12$|number=12( |$)' "$home/forge/calls.log" >/dev/null; then
    fail "a retired PR was read: $(cat "$home/forge/calls.log")"
  fi
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" owned) || fail 'owned PRs could not be listed'
  printf '%s\n' "$out" | jq -e 'any(.[]; .url == "https://github.com/o/r/pull/12") | not' >/dev/null \
    || fail "a retired PR became owned again: $out"
  pass 'a retired contribution is not reclaimed by a fresh branch lookup'
}

test_unreadable_contribution_record_pauses_the_monitor_once() {
  local home before
  home=$(new_home unreadable-record)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  arm "$home"
  expect_one "$home" 'conflicts with its base' 'the first conflict must wake'
  rm -f "$home/state/ship1.meta"
  expect_silent "$home" 'the durable record must keep the PR owned after cleanup'
  cp "$home/data/ship1/contributions.json" "$home/contributions.saved"
  printf 'not a record\n' > "$home/data/ship1/contributions.json"
  before=$(grep -c 'pulls/8$' "$home/forge/calls.log")
  expect_one "$home" '^pr-health: owned PRs could not be read: ' 'an unreadable durable record must be reported once'
  expect_silent "$home" 'the same unreadable record must not be reported again'
  [ "$(grep -c 'pulls/8$' "$home/forge/calls.log")" = "$before" ] || fail 'a PR was read while ownership was unverified'
  mv "$home/contributions.saved" "$home/data/ship1/contributions.json"
  expect_silent "$home" 'a conflict already reported must not repeat once the record is readable again'
  set_pr "$home" 8 ".head = \"$HEAD_B\""
  expect_one "$home" 'conflicts with its base at latest commit bbbbbbb' 'the PR must be watched again once the record is readable'
  pass 'an unreadable durable record pauses the monitor once and keeps its fingerprints'
}

test_nothing_prints_while_nothing_changed() {
  local home n
  home=$(new_home quiet)
  task "$home" a pr=https://github.com/o/r/pull/50
  task "$home" b pr=https://github.com/o/r/pull/51
  pr "$home" 50 "$HEAD_A" "$BASE_1" null false
  pr "$home" 51 "$HEAD_A" "$BASE_1" true true
  set_pr "$home" 50 '.checks = [{name:"CI Status",conclusion:null,required:true}]'
  set_pr "$home" 51 '.checks = [{name:"CI Status",conclusion:"SUCCESS",required:true}]'
  arm "$home"
  for n in 1 2 3; do
    expect_silent "$home" "pass $n printed with nothing actionable"
  done
  [ -s "$home/forge/calls.log" ] || fail 'the quiet passes never read the forge'
  pass 'nothing prints while nothing changed'
}

test_merged_pr_is_not_read_again() {
  local home before
  home=$(new_home merged)
  task "$home" done1 pr=https://github.com/o/r/pull/60
  pr "$home" 60 "$HEAD_A" "$BASE_1" false false
  set_pr "$home" 60 '.state = "merged"'
  arm "$home"
  expect_silent "$home" 'a merged PR must not wake'
  before=$(grep -c 'pulls/60$' "$home/forge/calls.log")
  expect_silent "$home" 'a merged PR must stay silent'
  [ "$(grep -c 'pulls/60$' "$home/forge/calls.log")" = "$before" ] || fail 'a merged PR was read again'
  pass 'a merged PR leaves the monitor'
}

test_absent_flag_changes_nothing() {
  local home out before
  home=$(new_home flag-off)
  rm -f "$home/config/pr-health-monitor"
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  before=$(ls -A "$home/state" "$home/data")
  out=$(with_home "$home" "$ROOT/bin/fm-pr-health.sh" poll 2>&1) || fail "poll failed with the flag absent: $out"
  [ -z "$out" ] || fail "poll printed with the flag absent: $out"
  if with_home "$home" "$ROOT/bin/fm-pr-health.sh" arm >/dev/null 2>&1; then
    fail 'arm succeeded with the flag absent'
  fi
  [ "$(ls -A "$home/state" "$home/data")" = "$before" ] \
    || fail "the flag-off monitor wrote records: $(ls -A "$home/state" "$home/data")"
  [ ! -s "$home/forge/calls.log" ] || fail "the flag-off monitor read the forge: $(cat "$home/forge/calls.log")"
  pass 'an absent flag leaves the home untouched'
}

test_watcher_surfaces_one_wake() {
  local home rc rows
  home=$(new_home watcher)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  arm "$home"
  [ -f "$home/state/contributions.check.sh" ] || fail 'arm did not arm the contribution observer for enrolled PRs'
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 > "$home/watcher.out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher did not surface the conflict: $(cat "$home/watcher.err")"
  rows=$(awk -F '\t' -v key="$home/state/pr-health.check.sh" '$3 == "check" && $4 == key && $5 ~ /pull\/8 conflicts with its base/ { n++ } END { print n + 0 }' \
    "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "one conflict queued $rows wakes: $(cat "$home/state/.wake-queue")"
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 > "$home/watcher-repeat.out" 2> "$home/watcher-repeat.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "an unchanged conflict woke the watcher again: $(cat "$home/watcher-repeat.out")"
  pass 'the watcher turns one conflict into one durable wake'
}

test_failure_once_per_latest_commit_after_cleanup() {
  local home
  home=$(new_home durable-dedupe)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 8 '.checks = [{name:"test",conclusion:"FAILURE",required:true}]'
  arm "$home"
  expect_one "$home" 'has failing required checks' 'the first failure must notify'
  rm -f "$home/state/ship1.meta" "$home/state/ship1.status"
  expect_silent "$home" 'worker cleanup must not erase dedupe'
  set_pr "$home" 8 '.checks[0].conclusion = "SUCCESS"'
  expect_silent "$home" 'recovery must not notify'
  set_pr "$home" 8 ".checks[0].conclusion = \"FAILURE\" | .base = \"$BASE_2\""
  expect_silent "$home" 'a failure returning at the same latest commit must not repeat'
  set_pr "$home" 8 ".head = \"$HEAD_B\""
  expect_one "$home" 'has failing required checks at latest commit bbbbbbb' 'a later latest commit must notify'
  pass 'check notifications survive cleanup and repeat only at a new latest commit'
}

test_unsupported_provider_has_no_github_reads() {
  local home
  home=$(new_home unsupported)
  git init -q -b feature "$home/copy"
  git -C "$home/copy" remote add origin git@gitlab.com:o/r.git
  task "$home" ship1 "worktree=$home/copy" pr=https://gitlab.com/o/r/-/merge_requests/8
  arm "$home"
  expect_silent "$home" 'an unsupported provider must not notify'
  [ ! -s "$home/forge/calls.log" ] || fail 'an unsupported provider triggered a GitHub read'
  pass 'GitLab ownership and branch discovery make no GitHub reads'
}

test_checks_on_later_pages() {
  local home
  home=$(new_home paged)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 8 '.checks = ([range(100) | {name:("optional-" + tostring),conclusion:"FAILURE",required:false}]
    + [{name:"required-later",conclusion:"SUCCESS",required:true}])'
  arm "$home"
  expect_silent "$home" 'optional failures must not notify while the required check on a later page passes'
  set_pr "$home" 8 '.checks[100].conclusion = "FAILURE"'
  expect_one "$home" 'has failing required checks.*required-later' 'a required failure after page one must notify'
  pass 'all check pages contribute to required-check classification'
}

test_all_owned_pr_reads_start_in_one_wave() {
  local home n out
  home=$(new_home concurrent)
  for n in $(seq 1 8); do
    if [ "$n" -le 4 ]; then
      task "$home" "ship$n" "pr=https://github.com/o/r/pull/$n"
    else
      git init -q -b "feature$n" "$home/copy$n"
      git -C "$home/copy$n" remote add origin git@github.com:o/r.git
      task "$home" "ship$n" "worktree=$home/copy$n"
      printf '%s\n' "$n" > "$home/forge/branch-feature$n"
    fi
    pr "$home" "$n" "$HEAD_A" "$BASE_1" false false
  done
  printf '4\n' > "$home/forge/branch-barrier-count"
  printf '8\n' > "$home/forge/barrier-count"
  arm "$home"
  out=$(pass_once "$home")
  [ "$(printf '%s\n' "$out" | grep -c 'conflicts with its base')" = 8 ] \
    || fail "every owned PR must start before a slow read completes: $out"
  pass 'all owned PR reads start in one wave without rotating a backlog'
}

feed() { # home : serve an empty notifications feed
  printf '[]\n' > "$1/forge/notifications.json"
  printf 'Sun, 01 Nov 2026 00:00:00 GMT\n' > "$1/forge/notifications-lm"
}

notify() { # home owner/repo number updated-at reason : one new notification
  jq --arg url "https://api.github.com/repos/$2/pulls/$3" --arg at "$4" --arg reason "$5" \
    '. + [{reason:$reason,updated_at:$at,subject:{type:"PullRequest",url:$url}}]' \
    "$1/forge/notifications.json" > "$1/forge/notifications.next"
  mv "$1/forge/notifications.next" "$1/forge/notifications.json"
  printf 'Sun, 01 Nov 2026 00:00:%02d GMT\n' "$(grep -c . "$1/forge/calls.log")" > "$1/forge/notifications-lm"
}

reads() { # home number -> REST reads of that PR so far
  grep -c "pulls/$2\$" "$1/forge/calls.log"
}

test_maintainer_author_and_approval_states_are_distinct() {
  local home
  home=$(new_home approval-states)
  task "$home" ship1 pr=https://github.com/o/r/pull/40
  pr "$home" 40 "$HEAD_A" "$BASE_1" true false
  # A fork PR whose workflows await approval: only an app check ran, so the
  # check rollup is green while the Actions suites have run nothing.
  set_pr "$home" 40 '.checks = [{name:"Review bot",conclusion:"SUCCESS",required:false}]
    | .suites = [{name:"CI",conclusion:"ACTION_REQUIRED"},{name:"Lint",conclusion:"SUCCESS"}]'
  arm "$home"
  expect_silent "$home" 'an ACTION_REQUIRED suite must not wake the task'
  jq -e --arg head "$HEAD_A" '.prs["https://github.com/o/r/pull/40"].maintainer_gated | any(.[]; .head == $head and .name == "CI")' \
    "$home/state/pr-health.json" >/dev/null || fail 'maintainer-gated CI was not recorded for fleet review'
  expect_silent "$home" 'a maintainer-gated suite must not repeat or wake'
  set_pr "$home" 40 '.reviewDecision = "REVIEW_REQUIRED"'
  expect_silent "$home" 'a required review must not wake the task'
  jq -e --arg head "$HEAD_A" '.prs["https://github.com/o/r/pull/40"].needs_approval | index($head) != null' \
    "$home/state/pr-health.json" >/dev/null || fail 'missing required review was not recorded for fleet review'
  expect_silent "$home" 'a required review must not repeat or wake'
  set_pr "$home" 40 '.reviewDecision = "CHANGES_REQUESTED"'
  expect_one "$home" 'author must act at latest commit aaaaaaa: changes requested \(task ship1\)$' \
    'a requested change must ask the author to act'
  expect_silent "$home" 'an unchanged requested change must not repeat'
  set_pr "$home" 40 ".head = \"$HEAD_B\" | .suites = [] | .reviewDecision = \"REVIEW_REQUIRED\" | .draft = true"
  expect_silent "$home" 'a draft awaiting review must not ask for approval'
  set_pr "$home" 40 '.labels = ["wheelhouse:pending-contributor-action"]'
  expect_one "$home" 'author must act at latest commit bbbbbbb: maintainer marked it wheelhouse:pending-contributor-action' \
    'an explicit maintainer waiting-on-author label must ask the author to act'
  set_pr "$home" 40 '.labels = ["needs-triage"]'
  expect_silent "$home" 'an unrelated label is not a maintainer disposition'
  pass 'maintainer-gated CI, required approval and author action notify distinctly once'
}

test_pending_reviewer_without_review_decision_is_recorded() {
  local home
  home=$(new_home pending-reviewer)
  task "$home" ship1 pr=https://github.com/o/r/pull/47
  pr "$home" 47 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 47 '.reviewDecision = null | .requests = 1'
  arm "$home"
  expect_silent "$home" 'a pending reviewer must not wake the task'
  jq -e --arg head "$HEAD_A" '.prs["https://github.com/o/r/pull/47"].needs_approval | index($head) != null' \
    "$home/state/pr-health.json" >/dev/null || fail 'pending reviewer with no review decision was not recorded'
  pass 'pending review requests imply recorded human approval'
}

test_more_than_a_page_of_review_requests_is_recorded() {
  local home
  home=$(new_home many-review-requests)
  task "$home" ship1 pr=https://github.com/o/r/pull/51
  pr "$home" 51 "$HEAD_A" "$BASE_1" true false
  # Like GitHub, the connection returns its first 100 requests and reports more.
  set_pr "$home" 51 '.reviewDecision = null | .requests = 150'
  arm "$home"
  expect_silent "$home" 'a PR awaiting review must not wake the task'
  jq -e --arg head "$HEAD_A" '.prs["https://github.com/o/r/pull/51"].needs_approval | index($head) != null' \
    "$home/state/pr-health.json" >/dev/null || fail 'more than one page of pending review requests was not recorded'
  pass 'a PR with more than a page of pending review requests is recorded as awaiting review'
}

test_check_suites_beyond_the_first_page_are_read() {
  local home
  home=$(new_home paged-check-suites)
  task "$home" ship1 pr=https://github.com/o/r/pull/46
  pr "$home" 46 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 46 '.suites = [{name:"Lint",conclusion:"SUCCESS"}] | .suites_page2 = [{name:"CI",conclusion:"ACTION_REQUIRED"}]'
  arm "$home"
  expect_silent "$home" 'a maintainer-gated suite on a later page must not wake the task'
  jq -e '.prs["https://github.com/o/r/pull/46"].maintainer_gated | any(.[]; .name == "CI")' \
    "$home/state/pr-health.json" >/dev/null || fail 'an ACTION_REQUIRED suite on page 2 was not recorded'
  grep -q 'suiteCursor=s2' "$home/forge/calls.log" || fail "the second suite page was never read: $(cat "$home/forge/calls.log")"
  pass 'check suites beyond the first page are read and classified'
}

test_endless_check_suite_pages_stay_unsettled() {
  local home
  home=$(new_home endless-check-suites)
  task "$home" ship1 pr=https://github.com/o/r/pull/48
  pr "$home" 48 "$HEAD_A" "$BASE_1" false false
  set_pr "$home" 48 '.suites = [{name:"CI",conclusion:"ACTION_REQUIRED"}] | .suites_truncated = true'
  arm "$home"
  expect_silent "$home" 'a suite list beyond the page bound must not emit an incomplete result'
  jq -e '.prs["https://github.com/o/r/pull/48"] == null' "$home/state/pr-health.json" >/dev/null \
    || fail 'a suite list beyond the page bound was accepted as complete'
  set_pr "$home" 48 '.suites_truncated = false'
  expect_one "$home" 'pull/48 conflicts with its base' 'the unsettled read must be retried once the list completes'
  jq -e '.prs["https://github.com/o/r/pull/48"].maintainer_gated | any(.[]; .name == "CI")' \
    "$home/state/pr-health.json" >/dev/null || fail 'the retried ACTION_REQUIRED suite was not recorded'
  pass 'a check-suite list beyond the page bound stays unsettled and is retried'
}

test_notifications_drive_reads_with_the_poll_as_fallback() {
  local home before
  home=$(new_home notification-events)
  task "$home" ship1 pr=https://github.com/o/r/pull/41
  pr "$home" 41 "$HEAD_A" "$BASE_1" true false
  feed "$home"
  arm "$home"
  expect_silent "$home" 'the first pass reads every owned PR and sets the feed cursor'
  [ "$(reads "$home" 41)" = 1 ] || fail "the first pass must read the owned PR: $(cat "$home/forge/calls.log")"
  set_pr "$home" 41 '.reviewDecision = "CHANGES_REQUESTED"'
  expect_silent "$home" 'an unchanged feed must not read the PR before the fallback sweep'
  grep -q 'If-Modified-Since: Sun, 01 Nov 2026 00:00:00 GMT' "$home/forge/calls.log" \
    || fail "the feed must be read conditionally: $(cat "$home/forge/calls.log")"
  [ "$(reads "$home" 41)" = 1 ] || fail 'an unchanged feed read the PR'
  notify "$home" o/r 99 2026-11-01T00:01:00Z author
  expect_silent "$home" "another home's PR notification must not wake this home"
  if grep -E 'pulls/99$|number=99( |$)' "$home/forge/calls.log" >/dev/null; then
    fail "a notification made this home read a PR it does not own: $(cat "$home/forge/calls.log")"
  fi
  [ "$(reads "$home" 41)" = 1 ] || fail 'an unrelated notification read the owned PR'
  notify "$home" o/r 41 2026-11-01T00:02:00Z author
  expect_one "$home" 'pull/41 author must act at latest commit aaaaaaa: changes requested' \
    'a notification on the owned PR must read it at once'
  set_pr "$home" 41 '.reviewDecision = "REVIEW_REQUIRED"'
  expect_silent "$home" 'an already seen notification must not trigger another read'
  jq '.notifications.swept_at = 0' "$home/state/pr-health.json" > "$home/state/pr-health.next" \
    && mv "$home/state/pr-health.next" "$home/state/pr-health.json"
  before=$(reads "$home" 41)
  expect_silent "$home" 'the fallback sweep must not wake for missing approval'
  [ "$(reads "$home" 41)" = $((before + 1)) ] || fail 'the fallback sweep did not read the owned PR'
  jq -e --arg head "$HEAD_A" '.prs["https://github.com/o/r/pull/41"].needs_approval | index($head) != null' \
    "$home/state/pr-health.json" >/dev/null || fail 'fallback sweep did not record missing approval'
  pass 'notifications trigger reads of owned PRs, unchanged feeds read nothing, the poll stays the fallback'
}

test_notifications_keep_events_at_the_saved_timestamp() {
  local home
  home=$(new_home same-timestamp-events)
  task "$home" ship1 pr=https://github.com/o/r/pull/43
  task "$home" ship2 pr=https://github.com/o/r/pull/44
  pr "$home" 43 "$HEAD_A" "$BASE_1" true false
  pr "$home" 44 "$HEAD_A" "$BASE_1" true false
  feed "$home"
  arm "$home"
  expect_silent "$home" 'the first pass reads both owned PRs'
  notify "$home" o/r 43 2026-11-01T00:04:00Z author
  expect_silent "$home" 'a notification without an author disposition stays quiet'
  notify "$home" o/r 44 2026-11-01T00:04:00Z author
  set_pr "$home" 44 '.reviewDecision = "CHANGES_REQUESTED"'
  expect_one "$home" 'pull/44 author must act' \
    'a different notification at the saved timestamp must still be processed'
  [ "$(reads "$home" 44)" = 2 ] || fail 'the same-timestamp notification did not read its owned PR'
  pass 'notifications at the saved timestamp remain eligible'
}

test_full_notification_page_forces_a_sweep_and_advances() {
  local home before
  home=$(new_home full-notification-page)
  task "$home" ship1 pr=https://github.com/o/r/pull/45
  pr "$home" 45 "$HEAD_A" "$BASE_1" true false
  feed "$home"
  # A busy account: the very first read already returns a full page.
  jq -n '[range(50) | {updated_at:"2026-11-01T00:01:00Z",reason:"comment",subject:{type:"PullRequest",url:"https://api.github.com/repos/o/r/pulls/99"}}]' \
    > "$home/forge/notifications.json"
  arm "$home"
  expect_silent "$home" 'the first full page reads every owned PR'
  [ "$(reads "$home" 45)" = 1 ] || fail 'a first full page did not read the owned PR'
  [ "$(jq -r '.notifications.last_modified' "$home/state/pr-health.json")" = 'Sun, 01 Nov 2026 00:00:00 GMT' ] \
    || fail 'a first full page left the feed without a cursor'
  printf 'Sun, 01 Nov 2026 00:02:00 GMT\n' > "$home/forge/notifications-lm"
  jq '[.[] | .updated_at = "2026-11-01T00:02:00Z"]' "$home/forge/notifications.json" > "$home/forge/n" \
    && mv "$home/forge/n" "$home/forge/notifications.json"
  before=$(reads "$home" 45)
  expect_silent "$home" 'a later full page still reads every owned PR'
  [ "$(reads "$home" 45)" = $((before + 1)) ] || fail 'a later full page did not force a full read'
  before=$(reads "$home" 45)
  expect_silent "$home" 'after a full page the unchanged feed answers 304'
  [ "$(reads "$home" 45)" = "$before" ] || fail 'a busy feed pinned the monitor to full sweeps'
  pass 'a full notification page forces a full read and still advances the cursor'
}

test_unknown_mergeability_is_reread_but_a_conflict_is_not() {
  local home before
  home=$(new_home mergeability-retry)
  task "$home" ship1 pr=https://github.com/o/r/pull/43
  pr "$home" 43 "$HEAD_A" "$BASE_1" null false
  feed "$home"
  arm "$home"
  expect_silent "$home" 'the first pass reads the PR with unknown mergeability'
  set_pr "$home" 43 '.mergeable = false'
  expect_one "$home" 'pull/43 conflicts with its base' 'unknown mergeability must be read again on the next pass'
  before=$(reads "$home" 43)
  expect_silent "$home" 'a reported conflict with an unchanged feed must stay quiet'
  [ "$(reads "$home" 43)" = "$before" ] || fail 'a confirmed conflict kept being re-read with an unchanged feed'
  pass 'unknown mergeability is re-read next pass while a confirmed conflict is not'
}

test_interrupted_pass_keeps_events_pending() {
  local home
  home=$(new_home interrupted-pass)
  task "$home" ship1 pr=https://github.com/o/r/pull/44
  pr "$home" 44 "$HEAD_A" "$BASE_1" true false
  feed "$home"
  arm "$home"
  expect_silent "$home" 'the first pass is quiet'
  set_pr "$home" 44 '.reviewDecision = "CHANGES_REQUESTED"'
  notify "$home" o/r 44 2026-11-01T00:04:00Z comment
  : > "$home/forge/interrupt-44"
  # The check execs the poll, so this background job's PID is the pass itself.
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$home/state/pr-health.check.sh" >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$home/forge/poll-pid"
  if wait "$!"; then fail 'the interrupted pass ran to completion'; fi
  [ -e "$home/forge/interrupted" ] || fail 'the interrupting read never stopped the pass'
  # The pass stopped mid-read: the advanced cursor and the event it selected
  # were saved together before any read, so a 304 next pass cannot lose it.
  jq -e --arg lm "$(cat "$home/forge/notifications-lm")" --arg url https://github.com/o/r/pull/44 \
    '.notifications.last_modified == $lm and (.notifications.pending | index($url) != null)' \
    "$home/state/pr-health.json" >/dev/null || fail 'the selected event was not saved with the cursor before the reads'
  expect_one "$home" 'pull/44 author must act' 'an event cut off by an interrupted pass must be read on the next pass'
  pass 'an interrupted pass leaves its notified PRs pending'
}

test_busy_feed_still_reads_only_events() {
  local home before
  home=$(new_home busy-feed)
  task "$home" ship1 pr=https://github.com/o/r/pull/49
  task "$home" ship2 pr=https://github.com/o/r/pull/50
  pr "$home" 49 "$HEAD_A" "$BASE_1" true false
  pr "$home" 50 "$HEAD_A" "$BASE_1" true false
  feed "$home"
  # A busy account: far more than one page of older notifications.
  jq -n '[range(60) | {updated_at:("2026-10-31T00:\(10 + .):00Z"),reason:"subscribed",subject:{type:"PullRequest",url:"https://api.github.com/repos/o/r/pulls/99"}}]' \
    > "$home/forge/notifications.json"
  arm "$home"
  expect_silent "$home" 'the first pass reads every owned PR'
  set_pr "$home" 49 '.reviewDecision = "CHANGES_REQUESTED"'
  notify "$home" o/r 49 2026-11-01T00:05:00Z author
  before=$(reads "$home" 50)
  expect_one "$home" 'pull/49 author must act' 'the new notification must read its PR'
  [ "$(reads "$home" 50)" = "$before" ] || fail 'a full page reaching back past the cursor forced a full sweep'
  pass 'a busy feed whose page reaches back past the cursor reads only the notified PR'
}

test_failed_event_read_is_retried() {
  local home
  home=$(new_home notification-retry)
  task "$home" ship1 pr=https://github.com/o/r/pull/42
  pr "$home" 42 "$HEAD_A" "$BASE_1" true false
  feed "$home"
  arm "$home"
  expect_silent "$home" 'the first pass is quiet'
  set_pr "$home" 42 ".graphql_head = \"$HEAD_B\" | .reviewDecision = \"CHANGES_REQUESTED\""
  notify "$home" o/r 42 2026-11-01T00:03:00Z comment
  expect_silent "$home" 'reads that disagree on the latest commit must wait'
  set_pr "$home" 42 'del(.graphql_head)'
  expect_one "$home" 'pull/42 author must act' 'an unsettled event read must be retried without a new notification'
  pass 'an event read that did not settle is retried on the next pass'
}

test_final_contributions_are_not_enrolled_again() {
  local home n copy
  home=$(new_home final-enroll)
  for n in 1 2 3; do
    task "$home" "done$n" "pr=https://github.com/o/r/pull/$n"
    pr "$home" "$n" "$HEAD_A" "$BASE_1" false false
    set_pr "$home" "$n" '.state = "merged"'
  done
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll || fail "could not make the PRs final"
  copy="$home/bincopy"
  cp -R "$ROOT/bin" "$copy"
  mv "$copy/fm-contributions.sh" "$copy/fm-contributions.real.sh"
  cat > "$copy/fm-contributions.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORGE/contributions.log"
exec "$(dirname "${BASH_SOURCE[0]}")/fm-contributions.real.sh" "$@"
SH
  chmod +x "$copy/fm-contributions.sh"
  with_home "$home" "$copy/fm-pr-health.sh" arm >/dev/null || fail 'could not arm the PR health monitor'
  pass_once "$home" >/dev/null
  pass_once "$home" >/dev/null
  ! grep -q '^enroll' "$home/forge/contributions.log" 2>/dev/null \
    || fail "final PRs were enrolled again: $(grep '^enroll' "$home/forge/contributions.log")"
  pass 'final contributions are not enrolled on a poll'
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit
fi

failures=0
for test_name in test_maintainer_author_and_approval_states_are_distinct \
  test_pending_reviewer_without_review_decision_is_recorded test_more_than_a_page_of_review_requests_is_recorded test_check_suites_beyond_the_first_page_are_read test_endless_check_suite_pages_stay_unsettled test_notifications_drive_reads_with_the_poll_as_fallback test_notifications_keep_events_at_the_saved_timestamp \
  test_failed_event_read_is_retried test_busy_feed_still_reads_only_events test_unknown_mergeability_is_reread_but_a_conflict_is_not test_interrupted_pass_keeps_events_pending test_full_notification_page_forces_a_sweep_and_advances \
  test_unknown_then_dirty_wakes_once test_dirty_again_at_same_commits_is_silent \
  test_conflict_once_per_latest_commit test_adopted_draft_red_required_check_after_pause_wakes_once \
  test_reported_failure_does_not_hide_a_later_required_failure \
  test_replaced_cancelled_run_is_not_failing test_latest_commit_moving_between_reads_waits \
  test_other_homes_red_check_is_silent test_enrolled_before_ready_and_after_cleanup_still_wake \
  test_open_pr_replacing_a_closed_one_on_the_same_branch_is_discovered \
  test_green_without_reviewer_is_silent test_base_without_required_checks_counts_any_failing_check \
  test_retired_contribution_is_not_reclaimed_from_the_cached_branch \
  test_retired_contribution_is_not_reclaimed_by_a_fresh_branch_lookup \
  test_unreadable_contribution_record_pauses_the_monitor_once \
  test_nothing_prints_while_nothing_changed test_merged_pr_is_not_read_again test_absent_flag_changes_nothing \
  test_watcher_surfaces_one_wake test_failure_once_per_latest_commit_after_cleanup \
  test_all_owned_pr_reads_start_in_one_wave test_checks_on_later_pages \
  test_unsupported_provider_has_no_github_reads test_final_contributions_are_not_enrolled_again; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures PR health regressions"

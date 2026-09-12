#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-comment-watch.sh: owner-repo monitoring,
# re-review readiness, explicit defer recording, and counterexample refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-pr-comment-watch.sh"
LIB="$ROOT/bin/fm-pr-comment-watch-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-comment-watch)

make_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  chmod 0700 "$home/state"
  printf '%s\n' "$home"
}

artemis_open_pr='[{"number":12,"url":"https://github.com/monalee-inc/artemis/pull/12"}]'
firstmate_open_pr='[{"number":88,"url":"https://github.com/pedromuller-del/firstmate/pull/88"}]'

threads_open_no_reply='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_open","isResolved":false,"comments":{"nodes":[{"author":{"login":"reviewer-one"}},{"author":{"login":"pedromuller-del"}}]}}]}}}}}'
threads_open_unreplied='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_open","isResolved":false,"comments":{"nodes":[{"author":{"login":"reviewer-one"}}]}}]}}}}}'
threads_resolved='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_done","isResolved":true,"comments":{"nodes":[{"author":{"login":"reviewer-one"}},{"author":{"login":"pedromuller-del"}}]}}]}}}}}'
threads_resolved_unreplied='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_done_unreplied","isResolved":true,"comments":{"nodes":[{"author":{"login":"reviewer-one"}}]}}]}}}}}'
threads_deferred_only='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_defer","isResolved":false,"comments":{"nodes":[{"author":{"login":"reviewer-one"}},{"author":{"login":"pedromuller-del"}}]}}]}}}}}'
threads_defer_without_reply='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_nodefer","isResolved":false,"comments":{"nodes":[{"author":{"login":"reviewer-one"}}]}}]}}}}}'
threads_wrong_author='{"data":{"repository":{"pullRequest":{"author":{"login":"someone-else"},"reviewThreads":{"nodes":[]}}}}}'
threads_malformed='{"data":{"repository":{"pullRequest":null}}}'
threads_missing_nodes='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{}}}}}'
threads_comment_baseline='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_comments","isResolved":false,"comments":{"nodes":[{"id":"C1","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}},{"id":"C2","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"pedromuller-del"}}]}}]}}}}}'
threads_comment_added='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_comments","isResolved":false,"comments":{"nodes":[{"id":"C1","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}},{"id":"C2","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"pedromuller-del"}},{"id":"C3","updatedAt":"2026-08-01T00:02:00Z","author":{"login":"reviewer-one"}}]}}]}}}}}'
threads_comment_edited='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_comments","isResolved":false,"comments":{"nodes":[{"id":"C1","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}},{"id":"C2","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"pedromuller-del"}},{"id":"C3","updatedAt":"2026-08-01T00:03:00Z","author":{"login":"reviewer-one"}}]}}]}}}}}'
threads_ordered='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_a","isResolved":true,"comments":{"nodes":[{"id":"C_a1","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}},{"id":"C_a2","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"pedromuller-del"}}]}},{"id":"RT_b","isResolved":true,"comments":{"nodes":[{"id":"C_b1","updatedAt":"2026-08-01T00:02:00Z","author":{"login":"reviewer-two"}},{"id":"C_b2","updatedAt":"2026-08-01T00:03:00Z","author":{"login":"pedromuller-del"}}]}}]}}}}}'
threads_reordered='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_b","isResolved":true,"comments":{"nodes":[{"id":"C_b2","updatedAt":"2026-08-01T00:03:00Z","author":{"login":"pedromuller-del"}},{"id":"C_b1","updatedAt":"2026-08-01T00:02:00Z","author":{"login":"reviewer-two"}}]}},{"id":"RT_a","isResolved":true,"comments":{"nodes":[{"id":"C_a2","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"pedromuller-del"}},{"id":"C_a1","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}}]}}]}}}}}'

threads_owner_opened_then_reviewer_unanswered='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_owner_opened","isResolved":true,"comments":{"nodes":[{"id":"C_owner_open","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"pedromuller-del"}},{"id":"C_reviewer","createdAt":"2026-08-01T00:01:00Z","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"reviewer-one"}}]}}]}}}}}'
threads_owner_only_resolved='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_owner_only","isResolved":true,"comments":{"nodes":[{"id":"C_owner_only","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"pedromuller-del"}}]}}]}}}}}'
threads_bot_only='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_bot","isResolved":true,"comments":{"nodes":[{"id":"C_bot","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"review-bot[bot]"}}]}}]}}}}}'

install_fake_gh() {
  local bindir=$1
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'SH'
#!/usr/bin/env bash
set -u
repo=''
author=''
owner=''
name=''
number=''
cursor=''
cursor_seen=0
thread_id=''
if [ "${1-}" = api ] && [[ " $* " == *' repos/'*'/requested_reviewers '* ]]; then
  case " $* " in
    *' --method POST '*) printf '%s\n' "$*" >> "$PCW_REQUEST_LOG" ;;
    *) printf '%s\n' '{"users":[]}' ;;
  esac
  exit 0
fi
case "$*" in
  *"pr list"*"monalee-inc/artemis"*)
    if [ "${PCW_OPEN_PR_MODE:-}" = limit ]; then
      case "$*" in
        *"--limit 1000"*) printf '%s\n' '[{"number":31,"url":"https://github.com/monalee-inc/artemis/pull/31"}]' ;;
        *) printf '[]\n' ;;
      esac
      exit 0
    fi
    printf '%s\n' "${ARTEMIS_OPEN_PRS:-[]}"
    exit 0
    ;;
  *"pr list"*"pedromuller-del/firstmate"*)
    printf '%s\n' "${FIRSTMATE_OPEN_PRS:-[]}"
    exit 0
    ;;
  *"pr list"*"other-org/other-repo"*)
    printf '[]\n'
    exit 0
    ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=$2; shift 2 ;;
    -f)
      case "$2" in
        owner=*) owner=${2#owner=} ;;
        name=*) name=${2#name=} ;;
        cursor=*) cursor=${2#cursor=}; cursor_seen=1 ;;
        id=*) thread_id=${2#id=} ;;
        query=*) ;;
      esac
      shift 2
      ;;
    -F)
      number=${2#number=}
      shift 2
      ;;
    *) shift ;;
  esac
done
if [ "${PCW_PAGINATION_MODE:-}" = threads ]; then
  if [ -z "$cursor" ]; then
    [ "$cursor_seen" -eq 0 ] || exit 99
    jq -cn '{data:{repository:{pullRequest:{author:{login:"pedromuller-del"},reviewThreads:{pageInfo:{hasNextPage:true,endCursor:"thread-page-2"},nodes:[range(100) as $n | {id:("RT_done_" + ($n|tostring)),isResolved:true,comments:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{id:("C_"+($n|tostring)+"_1"),createdAt:"2026-08-01T00:00:00Z",updatedAt:"2026-08-01T00:00:00Z",author:{login:"reviewer-one"}},{id:("C_"+($n|tostring)+"_2"),createdAt:"2026-08-01T00:01:00Z",updatedAt:"2026-08-01T00:01:00Z",author:{login:"pedromuller-del"}}]}}]}}}}}'
  else
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":"thread-final"},"nodes":[{"id":"RT_101","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":"comment-final"},"nodes":[{"id":"C_101","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}}]}}]}}}}}'
  fi
  exit 0
fi
if [ "${PCW_PAGINATION_MODE:-}" = comments ]; then
  if [ -n "$thread_id" ]; then
    printf '%s\n' '{"data":{"node":{"id":"RT_comments","comments":{"pageInfo":{"hasNextPage":false,"endCursor":"comment-final"},"nodes":[{"id":"C_101","createdAt":"2026-08-01T00:01:00Z","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"pedromuller-del"}}]}}}}'
  else
    [ "$cursor_seen" -eq 0 ] || exit 99
    jq -cn '{data:{repository:{pullRequest:{author:{login:"pedromuller-del"},reviewThreads:{pageInfo:{hasNextPage:false,endCursor:"thread-final"},nodes:[{id:"RT_comments",isResolved:true,comments:{pageInfo:{hasNextPage:true,endCursor:"comment-page-2"},nodes:[range(100) as $n | {id:("C_"+($n|tostring)),createdAt:"2026-08-01T00:00:00Z",updatedAt:"2026-08-01T00:00:00Z",author:{login:"reviewer-one"}}]}}]}}}}}'
  fi
  exit 0
fi
if [ "${PCW_PAGINATION_MODE:-}" = malformed-thread-pageinfo ]; then
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[]}}}}}'
  exit 0
fi
if [ "${PCW_PAGINATION_MODE:-}" = malformed-comment-pageinfo ]; then
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"RT_comments","isResolved":true,"comments":{"nodes":[{"author":{"login":"reviewer-one"}},{"author":{"login":"pedromuller-del"}}]}}]}}}}}'
  exit 0
fi
if [ "${PCW_PAGINATION_MODE:-}" = malformed-comment-identity ]; then
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"RT_bad_comment","isResolved":true,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}},{"id":"C2","updatedAt":"2026-08-01T00:01:00Z","author":{"login":"pedromuller-del"}}]}}]}}}}}'
  exit 0
fi
if [ "${PCW_PAGINATION_MODE:-}" = repeated-thread-cursor ]; then
  printf 'thread\n' >> "$PCW_CALL_LOG"
  printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"repeated-thread"},"nodes":[]}}}}}'
  exit 0
fi
if [ "${PCW_PAGINATION_MODE:-}" = repeated-comment-cursor ]; then
  printf 'comment\n' >> "$PCW_CALL_LOG"
  if [ -n "$thread_id" ]; then
    printf '%s\n' '{"data":{"node":{"id":"RT_repeat","comments":{"pageInfo":{"hasNextPage":true,"endCursor":"repeated-comment"},"nodes":[]}}}}'
  else
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":"thread-final"},"nodes":[{"id":"RT_repeat","isResolved":true,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"repeated-comment"},"nodes":[{"id":"C_repeat","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","author":{"login":"reviewer-one"}}]}}]}}}}}'
  fi
  exit 0
fi
if [ "${PCW_PAGINATION_MODE:-}" = inconsistent-author ]; then
  if [ -z "$cursor" ]; then
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"someone-else"},"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"author-page-2"},"nodes":[]}}}}}'
  else
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
  fi
  exit 0
fi
key="${owner}/${name}#${number}"
case "$key" in
  monalee-inc/artemis#12) response=${ARTEMIS_THREADS:-\{\}} ;;
  monalee-inc/artemis#31) response=${ARTEMIS_THREADS_31:-\{\}} ;;
  pedromuller-del/firstmate#88) response=${FIRSTMATE_THREADS:-\{\}} ;;
  other-org/other-repo#1) response=${OTHER_THREADS:-\{\}} ;;
  *) response='{"data":{"repository":{"pullRequest":null}}}' ;;
esac
printf '%s\n' "$response" | jq '
  if (.data.repository.pullRequest.reviewThreads? | type) == "object" then
    .data.repository.pullRequest.reviewThreads.pageInfo //= {hasNextPage:false,endCursor:null} |
    if (.data.repository.pullRequest.reviewThreads.nodes? | type) == "array" then
      .data.repository.pullRequest.reviewThreads.nodes |= map(
        if (.comments? | type) == "object" then
          .comments.pageInfo //= {hasNextPage:false,endCursor:null} |
          .comments.nodes |= (to_entries | map(.value + {
            id: (.value.id // ("C" + (.key | tostring))),
            createdAt: (.value.createdAt // .value.updatedAt // "2026-08-01T00:00:00Z"),
            updatedAt: (.value.updatedAt // "2026-08-01T00:00:00Z")
          }))
        else . end)
    else . end
  else . end
'
SH
  chmod +x "$bindir/gh"
}

test_lib_repo_gate() {
  # shellcheck source=bin/fm-pr-comment-watch-lib.sh
  . "$LIB"
  fm_pcw_repo_valid monalee-inc/artemis || fail "artemis must be an owner repo"
  fm_pcw_repo_valid pedromuller-del/firstmate || fail "firstmate fork must be an owner repo"
  fm_pcw_repo_valid other-org/other-repo && fail "unrelated repo must be refused"
  fm_pcw_pr_url_parse https://github.com/pedromuller-del/firstmate/pull/88 \
    || fail "owner fork PR URL must parse"
  fm_pcw_pr_url_parse https://github.com/other-org/other-repo/pull/1 \
    && fail "non-owner repo PR URL must be refused"
  pass "fm-pr-comment-watch-lib: owner repo and URL gates"
}

test_fork_pr_poll_is_silent_without_owner_repo() {
  local home bindir out
  home=$(make_home fork-silent-before)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  ARTEMIS_OPEN_PRS='[]' FIRSTMATE_OPEN_PRS='[]' \
    PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >"$home/out.txt" 2>/dev/null
  out=$(cat "$home/out.txt")
  [ -z "$out" ] || fail "empty fleet should stay silent, got: $out"
  pass "fm-pr-comment-watch: fork repo with no open PRs stays silent"
}

test_fork_pr_new_thread_wakes_after_owner_repo_enabled() {
  local home bindir out current
  home=$(make_home fork-wake)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_OPEN_PRS='[]'
  export FIRSTMATE_OPEN_PRS="$firstmate_open_pr"
  export FIRSTMATE_THREADS="$threads_open_unreplied"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >"$home/first.out" 2>/dev/null
  [ ! -s "$home/first.out" ] || fail "baseline poll should establish snapshot without waking"
  export FIRSTMATE_THREADS="$threads_open_no_reply"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >"$home/second.out" 2>/dev/null
  assert_grep 'owner-pr-review-thread pedromuller-del/firstmate#88' "$home/second.out" \
    "fork PR thread change did not wake"
  pass "fm-pr-comment-watch: fork PR review-thread change wakes after owner-repo coverage"
}

test_artemis_poll_unchanged_after_fork_extension() {
  local home bindir out
  home=$(make_home artemis-stable)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_OPEN_PRS="$artemis_open_pr"
  export FIRSTMATE_OPEN_PRS='[]'
  export ARTEMIS_THREADS="$threads_open_unreplied"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >/dev/null 2>&1
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >"$home/out.txt" 2>/dev/null
  out=$(cat "$home/out.txt")
  [ -z "$out" ] || fail "unchanged artemis snapshot should stay silent, got: $out"
  export ARTEMIS_THREADS="$threads_open_no_reply"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >"$home/changed.out" 2>/dev/null
  assert_grep 'owner-pr-review-thread monalee-inc/artemis#12' "$home/changed.out" \
    "artemis thread change did not wake"
  pass "fm-pr-comment-watch: artemis monitoring still wakes on thread change"
}

test_existing_thread_comment_changes_wake() {
  local home bindir
  home=$(make_home thread-comment-change)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_OPEN_PRS="$artemis_open_pr"
  export FIRSTMATE_OPEN_PRS='[]'
  export ARTEMIS_THREADS="$threads_comment_baseline"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >/dev/null 2>&1
  export ARTEMIS_THREADS="$threads_comment_added"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll > "$home/added.out" 2>/dev/null
  assert_grep 'owner-pr-review-thread monalee-inc/artemis#12' "$home/added.out" \
    "new comment on an existing thread did not wake"
  export ARTEMIS_THREADS="$threads_comment_edited"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll > "$home/edited.out" 2>/dev/null
  assert_grep 'owner-pr-review-thread monalee-inc/artemis#12' "$home/edited.out" \
    "edited comment on an existing thread did not wake"
  pass "fm-pr-comment-watch: existing thread comment changes wake"
}

test_poll_ignores_equivalent_forge_collection_order() {
  local home bindir out
  home=$(make_home collection-order)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_OPEN_PRS='[{"number":12,"url":"https://github.com/monalee-inc/artemis/pull/12"},{"number":31,"url":"https://github.com/monalee-inc/artemis/pull/31"}]'
  export FIRSTMATE_OPEN_PRS='[]'
  export ARTEMIS_THREADS="$threads_ordered"
  export ARTEMIS_THREADS_31="$threads_ordered"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >"$home/first.out" 2>/dev/null
  [ ! -s "$home/first.out" ] || fail "baseline poll should establish snapshot without waking"
  export ARTEMIS_OPEN_PRS='[{"number":31,"url":"https://github.com/monalee-inc/artemis/pull/31"},{"number":12,"url":"https://github.com/monalee-inc/artemis/pull/12"}]'
  export ARTEMIS_THREADS="$threads_reordered"
  export ARTEMIS_THREADS_31="$threads_reordered"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >"$home/out.txt" 2>/dev/null
  out=$(cat "$home/out.txt")
  [ -z "$out" ] || fail "equivalent pull request, thread, and comment reordering woke the owner: $out"
  pass "fm-pr-comment-watch: equivalent forge collection reordering stays silent"
}

test_rerequest_deduplicates_addressed_human_reviewers() {
  local home bindir log requests
  home=$(make_home rerequest-deduplicate)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  log="$home/requests.log"
  : > "$log"
  export ARTEMIS_THREADS="$threads_ordered"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_REQUEST_LOG="$log" \
    "$TOOL" rerequest-reviewers --url https://github.com/monalee-inc/artemis/pull/12 \
    --code-fix --thread-id RT_a --thread-id RT_a --thread-id RT_b >/dev/null 2>&1
  requests=$(wc -l < "$log" | tr -d ' ')
  [ "$requests" = 2 ] || fail "addressed reviewers were not deduplicated: $requests requests"
  assert_grep 'reviewers[]=reviewer-one' "$log" "first human reviewer was not requested"
  assert_grep 'reviewers[]=reviewer-two' "$log" "second human reviewer was not requested"
  pass "fm-pr-comment-watch: addressed human reviewers are deduplicated"
}

test_rerequest_empty_reviewer_array_is_stock_bash_safe() {
  local home bindir log rc
  home=$(make_home rerequest-empty-reviewers)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  log="$home/requests.log"
  : > "$log"
  export ARTEMIS_THREADS="$threads_bot_only"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_REQUEST_LOG="$log" \
    /bin/bash "$TOOL" rerequest-reviewers --url https://github.com/monalee-inc/artemis/pull/12 \
    --code-fix --thread-id RT_bot >"$home/out.txt" 2>"$home/err.txt"
  rc=$?
  set -e
  expect_code 0 "$rc" "stock Bash 3.2 must accept an empty reviewer array"
  [ ! -s "$log" ] || fail "bot-only thread unexpectedly requested a reviewer"
  assert_no_grep 'unbound variable' "$home/err.txt" "stock Bash 3.2 must not expand an empty reviewer array under set -u"
  pass "fm-pr-comment-watch: empty reviewer array is stock Bash 3.2 safe"
}

test_rerequest_human_reviewer_is_stock_bash_safe() {
  local home bindir log rc
  home=$(make_home rerequest-human-reviewer)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  log="$home/requests.log"
  : > "$log"
  export ARTEMIS_THREADS="$threads_ordered"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_REQUEST_LOG="$log" \
    /bin/bash "$TOOL" rerequest-reviewers --url https://github.com/monalee-inc/artemis/pull/12 \
    --code-fix --thread-id RT_a >"$home/out.txt" 2>"$home/err.txt"
  rc=$?
  set -e
  expect_code 0 "$rc" "stock Bash 3.2 must request an eligible human reviewer"
  assert_grep 'reviewers[]=reviewer-one' "$log" "eligible human reviewer was not requested"
  assert_no_grep 'unbound variable' "$home/err.txt" "stock Bash 3.2 must not expand an empty reviewer array under set -u"
  pass "fm-pr-comment-watch: human reviewer request is stock Bash 3.2 safe"
}

test_rereview_empty_cursor_array_is_stock_bash_safe() {
  local home bindir rc
  home=$(make_home rereview-empty-cursors)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_PAGINATION_MODE=comments \
    /bin/bash "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 \
    >"$home/out.txt" 2>"$home/err.txt"
  rc=$?
  set -e
  expect_code 0 "$rc" "stock Bash 3.2 must paginate an empty cursor array"
  assert_no_grep 'unbound variable' "$home/err.txt" "stock Bash 3.2 must not expand an empty cursor array under set -u"
  pass "fm-pr-comment-watch-lib: empty cursor array is stock Bash 3.2 safe"
}

test_rereview_ready_refuses_unreplied_open_thread() {
  local home bindir rc
  home=$(make_home rereview-refuse)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_open_unreplied"
  err_file="$home/err.txt"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 \
    >"$home/out.txt" 2>"$err_file"
  rc=$?
  set -e
  expect_code 1 "$rc" "open unreplied thread must refuse rereview-ready"
  assert_grep 'not ready for re-review' "$err_file" "refusal must name re-review readiness"
  pass "fm-pr-comment-watch: unreplied open thread refuses rereview-ready"
}

test_rereview_ready_accepts_resolved_thread() {
  local home bindir rc
  home=$(make_home rereview-resolved)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_resolved"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "resolved thread must pass rereview-ready"
  pass "fm-pr-comment-watch: resolved thread passes rereview-ready"
}

test_rereview_ready_refuses_resolved_thread_without_reply() {
  local home bindir rc
  home=$(make_home rereview-resolved-unreplied)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_resolved_unreplied"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "resolved thread without an owner reply must refuse readiness"
  pass "fm-pr-comment-watch: resolved unreplied thread refuses readiness"
}

test_rereview_ready_refuses_owner_opened_thread_with_unanswered_reviewer() {
  local home bindir rc
  home=$(make_home rereview-owner-opened-unanswered)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_owner_opened_then_reviewer_unanswered"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "an owner opening comment must not answer a later reviewer comment"
  pass "fm-pr-comment-watch: owner-opened thread with unanswered reviewer refuses readiness"
}

test_rereview_ready_accepts_resolved_owner_only_thread() {
  local home bindir rc
  home=$(make_home rereview-owner-only)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_owner_only_resolved"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a resolved owner-only annotation has no reviewer reply to require"
  pass "fm-pr-comment-watch: resolved owner-only thread passes readiness"
}

test_rereview_ready_accepts_recorded_defer_with_reply() {
  local home bindir rc
  home=$(make_home rereview-defer)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_deferred_only"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_defer >/dev/null 2>&1 \
    || fail "defer recording failed"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "replied-and-recorded-defer thread must pass rereview-ready"
  pass "fm-pr-comment-watch: replied thread with recorded defer passes rereview-ready"
}

test_rereview_refuses_untrusted_defer_file() {
  local home bindir defer_file backing rc
  home=$(make_home rereview-untrusted-defer)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_deferred_only"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_defer >/dev/null 2>&1 \
    || fail "defer recording failed"
  defer_file="$home/state/.pr-review-thread-defers/monalee-inc__artemis__12.tsv"
  backing="$home/defer-backing.tsv"
  mv "$defer_file" "$backing"
  ln -s "$backing" "$defer_file"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "untrusted defer file must not satisfy readiness"
  pass "fm-pr-comment-watch: untrusted defer state fails closed"
}

test_defer_record_refuses_untrusted_existing_state() {
  local home bindir defer_root defer_file backing rc
  home=$(make_home defer-untrusted-existing)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  defer_root="$home/state/.pr-review-thread-defers"
  defer_file="$defer_root/monalee-inc__artemis__12.tsv"
  backing="$home/defer-backing.tsv"
  mkdir -p "$defer_root"
  printf 'RT_injected\t2026-08-01T00:00:00Z\n' > "$backing"
  ln -s "$backing" "$defer_file"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_defer >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "defer recording must reject untrusted existing state"
  [ -L "$defer_file" ] || fail "failed defer recording replaced untrusted existing state"
  pass "fm-pr-comment-watch: defer recording rejects untrusted existing state"
}

test_defer_record_refuses_symlinked_directory() {
  local home bindir defer_root outside rc
  home=$(make_home defer-symlinked-directory)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  defer_root="$home/state/.pr-review-thread-defers"
  outside="$home/outside-defers"
  mkdir -p "$outside"
  ln -s "$outside" "$defer_root"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_defer >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "defer recording must reject a symlinked defer directory"
  [ ! -e "$outside/monalee-inc__artemis__12.tsv" ] \
    || fail "defer recording escaped through the symlinked directory"
  pass "fm-pr-comment-watch: symlinked defer directory fails closed"
}

test_defer_refuses_nonprivate_state_directory() {
  local home bindir rc
  home=$(make_home defer-nonprivate-state)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_deferred_only"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_defer >/dev/null 2>&1 \
    || fail "initial defer recording failed"
  chmod 0777 "$home/state"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "nonprivate state must not satisfy readiness"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_other >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "nonprivate state must refuse defer writes"
  pass "fm-pr-comment-watch: defer state requires a private state directory"
}

test_defer_without_inline_reply_still_refuses() {
  local home bindir rc
  home=$(make_home defer-no-reply)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_defer_without_reply"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_nodefer >/dev/null 2>&1 \
    || fail "defer recording failed"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "defer without inline reply must still refuse"
  pass "fm-pr-comment-watch: defer without inline reply cannot satisfy readiness"
}

test_defer_requires_exact_thread_id() {
  local home bindir rc
  home=$(make_home defer-exact-thread)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_THREADS="$threads_deferred_only"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id XRT_defer >/dev/null 2>&1 \
    || fail "near-match defer recording failed"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "near-match defer ID must not satisfy another thread"
  pass "fm-pr-comment-watch: defer lookup matches exact thread IDs"
}

test_counterexamples_refuse() {
  local home bindir rc
  home=$(make_home counterexamples)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export OTHER_THREADS="$threads_open_unreplied"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/other-org/other-repo/pull/1 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "non-owner repo URL must be refused at parse time" || expect_code 1 "$rc" "non-owner repo URL must be refused"
  export ARTEMIS_THREADS="$threads_wrong_author"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "non-owner author must refuse readiness"
  export ARTEMIS_THREADS="$threads_malformed"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed forge payload must refuse readiness"
  export ARTEMIS_THREADS="$threads_missing_nodes"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "missing review-thread nodes must refuse readiness"
  pass "fm-pr-comment-watch: counterexample repos, authors, and malformed data refuse"
}

test_rereview_paginates_threads_and_comments() {
  local home bindir rc err
  home=$(make_home rereview-pagination)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_PAGINATION_MODE=threads \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>"$home/err.txt"
  rc=$?
  set -e
  expect_code 1 "$rc" "an unreplied thread after the first thread page must block readiness"
  err=$(cat "$home/err.txt")
  case "$err" in
    *'not ready for re-review'*) ;;
    *) fail "thread pagination must reach readiness refusal, got: $err" ;;
  esac
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_PAGINATION_MODE=comments \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1 \
    || fail "an owner reply after the first comment page was not recognized"
  pass "fm-pr-comment-watch: readiness paginates threads and comments"
}

test_rereview_refuses_malformed_pageinfo() {
  local home bindir mode rc
  home=$(make_home rereview-malformed-pageinfo)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  for mode in malformed-thread-pageinfo malformed-comment-pageinfo; do
    set +e
    PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_PAGINATION_MODE="$mode" \
      "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode must fail closed"
  done
  pass "fm-pr-comment-watch: malformed pagination metadata refuses readiness"
}

test_rereview_refuses_malformed_comment_identity() {
  local home bindir rc
  home=$(make_home rereview-malformed-comment)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_PAGINATION_MODE=malformed-comment-identity \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed comment identity must fail closed"
  pass "fm-pr-comment-watch: malformed comment identity refuses readiness"
}

test_rereview_refuses_repeated_pagination_cursors() {
  local home bindir mode rc calls
  home=$(make_home rereview-repeated-cursors)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  for mode in repeated-thread-cursor repeated-comment-cursor; do
    : > "$home/calls"
    set +e
    PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_PAGINATION_MODE="$mode" \
      PCW_CALL_LOG="$home/calls" \
      "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
    rc=$?
    set -e
    expect_code 1 "$rc" "$mode must fail closed"
    calls=$(wc -l < "$home/calls" | tr -d ' ')
    expect_code 2 "$calls" "$mode must stop before requesting a repeated cursor again"
  done
  pass "fm-pr-comment-watch: repeated pagination cursors fail closed"
}

test_rereview_refuses_inconsistent_paginated_author() {
  local home bindir rc
  home=$(make_home rereview-inconsistent-author)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_PAGINATION_MODE=inconsistent-author \
    "$TOOL" rereview-ready --url https://github.com/monalee-inc/artemis/pull/12 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "inconsistent paginated author must fail closed"
  pass "fm-pr-comment-watch: inconsistent paginated author refuses readiness"
}

test_poll_requests_owner_prs_beyond_default_limit() {
  local home bindir
  home=$(make_home poll-pr-limit)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export FIRSTMATE_OPEN_PRS='[]'
  export ARTEMIS_THREADS_31="$threads_open_unreplied"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_OPEN_PR_MODE=limit \
    "$TOOL" poll >/dev/null 2>&1
  export ARTEMIS_THREADS_31="$threads_open_no_reply"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh PCW_OPEN_PR_MODE=limit \
    "$TOOL" poll > "$home/changed.out" 2>/dev/null
  assert_grep 'owner-pr-review-thread monalee-inc/artemis#31' "$home/changed.out" \
    "owner PR beyond the default list limit was not monitored"
  pass "fm-pr-comment-watch: owner PR enumeration raises the list limit"
}

test_poll_preserves_snapshot_across_incomplete_collection() {
  local home bindir
  home=$(make_home poll-incomplete)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_OPEN_PRS="$artemis_open_pr"
  export FIRSTMATE_OPEN_PRS='[]'
  export ARTEMIS_THREADS="$threads_open_unreplied"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >/dev/null 2>&1
  export ARTEMIS_THREADS="$threads_malformed"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll > "$home/failure.out" 2>/dev/null
  [ ! -s "$home/failure.out" ] || fail "incomplete collection emitted a notification"
  export ARTEMIS_THREADS="$threads_open_unreplied"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll > "$home/recovery.out" 2>/dev/null
  [ ! -s "$home/recovery.out" ] || fail "recovery from incomplete collection emitted a false notification"
  pass "fm-pr-comment-watch: incomplete collection preserves the prior snapshot"
}

test_poll_refuses_symlinked_state_and_snapshot() {
  local home bindir outside snapshot target
  home="$TMP_ROOT/poll-symlinked-state"
  outside="$TMP_ROOT/poll-outside-state"
  mkdir -p "$home" "$outside"
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  ln -s "$outside" "$home/state"
  ARTEMIS_OPEN_PRS='[]' FIRSTMATE_OPEN_PRS='[]' \
    PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >/dev/null 2>&1
  [ ! -e "$outside/.pr-comment-watch-snapshot.json" ] \
    || fail "poll wrote through a symlinked state directory"

  home=$(make_home poll-symlinked-snapshot)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  snapshot="$home/state/.pr-comment-watch-snapshot.json"
  target="$home/outside-snapshot.json"
  printf '%s\n' '{"schema":"fm-pr-comment-watch-snapshot-v1","author":"pedromuller-del","pulls":[]}' > "$target"
  chmod 0600 "$target"
  ln -s "$target" "$snapshot"
  ARTEMIS_OPEN_PRS='[]' FIRSTMATE_OPEN_PRS='[]' \
    PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >/dev/null 2>&1
  [ -L "$snapshot" ] || fail "poll replaced an untrusted snapshot instead of failing closed"
  pass "fm-pr-comment-watch: poll rejects symlinked state and snapshots"
}

test_arm_refuses_nonprivate_state_directory() {
  local home rc shim
  home=$(make_home arm-nonprivate-state)
  shim="$home/state/pr-comment-watch.check.sh"
  chmod 0777 "$home/state"
  set +e
  FM_HOME="$home" "$TOOL" arm >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "arm must reject a nonprivate state directory"
  [ ! -e "$shim" ] && [ ! -L "$shim" ] || fail "arm wrote a shim into nonprivate state"
  pass "fm-pr-comment-watch: arm requires a private state directory"
}

test_state_refuses_ancestor_symlink() {
  local home bindir outside state
  home="$TMP_ROOT/ancestor-symlink-home"
  outside="$TMP_ROOT/ancestor-symlink-outside"
  mkdir -p "$home" "$outside/parent/state"
  chmod 0700 "$outside/parent/state"
  ln -s "$outside/parent" "$home/linked-parent"
  state="$home/linked-parent/state"
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  ARTEMIS_OPEN_PRS='[]' FIRSTMATE_OPEN_PRS='[]' \
    PATH="$bindir:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PCW_GH_CMD=gh \
    "$TOOL" poll >/dev/null 2>&1
  PATH="$bindir:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_defer >/dev/null 2>&1 \
    && fail "defer accepted a state path with a symlinked ancestor"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$TOOL" arm >/dev/null 2>&1 \
    && fail "arm accepted a state path with a symlinked ancestor"
  [ ! -e "$outside/parent/state/.pr-comment-watch-snapshot.json" ] \
    || fail "poll escaped through a symlinked state ancestor"
  [ ! -e "$outside/parent/state/.pr-review-thread-defers" ] \
    || fail "defer escaped through a symlinked state ancestor"
  [ ! -e "$outside/parent/state/pr-comment-watch.check.sh" ] \
    || fail "arm escaped through a symlinked state ancestor"
  pass "fm-pr-comment-watch: state rejects symlinked ancestors"
}

test_state_refuses_home_ancestor_symlink() {
  local trusted outside home state bindir
  trusted="$TMP_ROOT/home-ancestor-trusted"
  outside="$TMP_ROOT/home-ancestor-outside"
  mkdir -p "$trusted" "$outside/home/state"
  chmod 0700 "$outside/home/state"
  ln -s "$outside" "$trusted/linked-home-parent"
  home="$trusted/linked-home-parent/home"
  state="$home/state"
  bindir="$outside/home/fakebin"
  install_fake_gh "$bindir"
  ARTEMIS_OPEN_PRS='[]' FIRSTMATE_OPEN_PRS='[]' \
    PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" poll >/dev/null 2>&1
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$TOOL" defer --url https://github.com/monalee-inc/artemis/pull/12 --thread-id RT_defer >/dev/null 2>&1 \
    && fail "defer accepted FM_HOME with a symlinked ancestor"
  FM_HOME="$home" "$TOOL" arm >/dev/null 2>&1 \
    && fail "arm accepted FM_HOME with a symlinked ancestor"
  [ ! -e "$state/.pr-comment-watch-snapshot.json" ] \
    || fail "poll escaped through a symlinked FM_HOME ancestor"
  [ ! -e "$state/.pr-review-thread-defers" ] \
    || fail "defer escaped through a symlinked FM_HOME ancestor"
  [ ! -e "$state/pr-comment-watch.check.sh" ] \
    || fail "arm escaped through a symlinked FM_HOME ancestor"
  pass "fm-pr-comment-watch: state rejects symlinked FM_HOME ancestors"
}

test_fork_pr_invisible_before_owner_repo_extension() {
  local home bindir out
  home=$(make_home fork-invisible)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export ARTEMIS_OPEN_PRS='[]'
  export FIRSTMATE_OPEN_PRS="$firstmate_open_pr"
  export FIRSTMATE_THREADS="$threads_open_unreplied"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    FM_PCW_OWNER_REPOS_OVERRIDE='monalee-inc/artemis' \
    "$TOOL" poll >"$home/first.out" 2>/dev/null
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    FM_PCW_OWNER_REPOS_OVERRIDE='monalee-inc/artemis' \
    "$TOOL" poll >"$home/second.out" 2>/dev/null
  out=$(cat "$home/first.out" "$home/second.out")
  [ -z "$out" ] || fail "pre-extension owner-repo set must not wake on fork PR threads, got: $out"
  pass "fm-pr-comment-watch: fork PR threads stay invisible before firstmate is in the owner-repo set"
}

test_context_monitor_has_exclusive_polling_ownership() {
  local home bindir
  home=$(make_home context-owner)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  ln -s "$ROOT/bin" "$home/bin"
  export ARTEMIS_OPEN_PRS='[]' FIRSTMATE_OPEN_PRS="$firstmate_open_pr"
  export FIRSTMATE_THREADS="$threads_open_unreplied"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-pr-context.sh" write change >/dev/null <<'JSON'
{"pr_url":"https://github.com/pedromuller-del/firstmate/pull/88",
 "repo":"pedromuller-del/firstmate","branch":"fm/change","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
 "oracle":{"name":"acceptance","command":"bin/check"},"tests":[{"command":"bin/check","exit_code":0}],
 "open_review_threads":[],"deferred_items":[],"pre_push_command":"bin/check","merge_authority":"human-merge"}
JSON
  "$ROOT/bin/fm-pr-context-watch.sh" install "$home" change >/dev/null || fail "cannot install context owner"
  export FIRSTMATE_THREADS="$threads_open_no_reply"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll > "$home/covered.out"
  [ ! -s "$home/covered.out" ] || fail "legacy and context monitors both announced the same PR"
  FM_HOME="$home" "$ROOT/bin/fm-check-unregister.sh" pr-fix-change >/dev/null || fail "cannot remove test registration"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh "$TOOL" poll > "$home/uncovered.out"
  assert_grep 'owner-pr-review-thread pedromuller-del/firstmate#88' "$home/uncovered.out" "legacy coverage did not resume without the context registration"
  pass "registered contexts have one polling owner; uncovered PRs keep legacy coverage"
}

test_script_parses() {
  local rc
  bash -n "$TOOL" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "bash -n fm-pr-comment-watch.sh"
  bash -n "$LIB" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "bash -n fm-pr-comment-watch-lib.sh"
  pass "fm-pr-comment-watch: shell parses cleanly"
}

test_context_monitor_has_exclusive_polling_ownership
test_lib_repo_gate
test_script_parses
test_fork_pr_invisible_before_owner_repo_extension
test_fork_pr_poll_is_silent_without_owner_repo
test_fork_pr_new_thread_wakes_after_owner_repo_enabled
test_artemis_poll_unchanged_after_fork_extension
test_existing_thread_comment_changes_wake
test_poll_ignores_equivalent_forge_collection_order
test_rerequest_deduplicates_addressed_human_reviewers
test_rerequest_empty_reviewer_array_is_stock_bash_safe
test_rerequest_human_reviewer_is_stock_bash_safe
test_rereview_empty_cursor_array_is_stock_bash_safe
test_rereview_ready_refuses_unreplied_open_thread
test_rereview_ready_accepts_resolved_thread
test_rereview_ready_refuses_resolved_thread_without_reply
test_rereview_ready_refuses_owner_opened_thread_with_unanswered_reviewer
test_rereview_ready_accepts_resolved_owner_only_thread
test_rereview_ready_accepts_recorded_defer_with_reply
test_rereview_refuses_untrusted_defer_file
test_defer_record_refuses_untrusted_existing_state
test_defer_record_refuses_symlinked_directory
test_defer_refuses_nonprivate_state_directory
test_defer_without_inline_reply_still_refuses
test_defer_requires_exact_thread_id
test_counterexamples_refuse
test_rereview_paginates_threads_and_comments
test_rereview_refuses_malformed_pageinfo
test_rereview_refuses_malformed_comment_identity
test_rereview_refuses_repeated_pagination_cursors
test_rereview_refuses_inconsistent_paginated_author
test_poll_requests_owner_prs_beyond_default_limit
test_poll_preserves_snapshot_across_incomplete_collection
test_poll_refuses_symlinked_state_and_snapshot
test_arm_refuses_nonprivate_state_directory
test_state_refuses_ancestor_symlink
test_state_refuses_home_ancestor_symlink

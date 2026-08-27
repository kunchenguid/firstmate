#!/usr/bin/env bash
# Composition tests across fm-pr-comment-watch poll readiness and fm-pr-body publish.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BODY="$ROOT/bin/fm-pr-body.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-comment-watch-mechanism)

make_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

threads_open_unreplied='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_open","isResolved":false,"comments":{"nodes":[{"author":{"login":"reviewer-one"},"createdAt":"2026-08-01T00:00:00Z"}]}}]}}}}}'
threads_resolved='{"data":{"repository":{"pullRequest":{"author":{"login":"pedromuller-del"},"reviewThreads":{"nodes":[{"id":"RT_done","isResolved":true,"comments":{"nodes":[{"author":{"login":"reviewer-one"},"createdAt":"2026-08-01T00:00:00Z"},{"author":{"login":"pedromuller-del"},"createdAt":"2026-08-01T00:01:00Z"}]}}]}}}}}'

install_fake_gh() {
  local bindir=$1
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1-}" = pr ] && [ "${2-}" = edit ]; then
  printf 'forge-invoked %s\n' "$*"
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = list ]; then
  printf '%s\n' "$OPEN_PRS"
  exit 0
fi
owner='' name='' number=''
while [ $# -gt 0 ]; do
  case "$1" in
    -f)
      case "$2" in
        owner=*) owner=${2#owner=} ;;
        name=*) name=${2#name=} ;;
      esac
      shift 2
      ;;
    -F) number=${2#number=}; shift 2 ;;
    *) shift ;;
  esac
done
payload=$THREAD_PAYLOAD
if [ "$number" = 12 ] && [ -n "${THREAD_PAYLOAD_WRONG_SELECTOR:-}" ]; then
  payload=$THREAD_PAYLOAD_WRONG_SELECTOR
fi
printf '%s\n' "$payload" | jq '
  .data.repository.pullRequest.reviewThreads.pageInfo //= {hasNextPage:false,endCursor:null} |
  .data.repository.pullRequest.reviewThreads.nodes |= map(
    .comments.pageInfo //= {hasNextPage:false,endCursor:null} |
    .comments.nodes |= (to_entries | map(.value + {
      id: (.value.id // ("C" + (.key | tostring))),
      createdAt: (.value.createdAt // "2026-08-01T00:00:00Z"),
      updatedAt: (.value.updatedAt // "2026-08-01T00:00:00Z")
    })))
'
SH
  chmod +x "$bindir/gh"
  cat > "$bindir/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'forge-invoked %s\n' "$*"
SH
  chmod +x "$bindir/gh-axi"
}

test_publish_refuses_pr_ready_when_threads_block() {
  local home bindir body_file rc err_file
  home=$(make_home publish-refuse)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export OPEN_PRS='[]'
  export THREAD_PAYLOAD="$threads_open_unreplied"
  body_file="$home/body.txt"
  printf 'Ready for another look.\n' >"$body_file"
  err_file="$home/err.txt"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$BODY" publish --file "$body_file" -- gh-axi pr ready https://github.com/pedromuller-del/firstmate/pull/88 \
    >"$home/out.txt" 2>"$err_file"
  rc=$?
  set -e
  expect_code 1 "$rc" "publish must refuse gh pr ready when threads block"
  assert_grep 'not ready for re-review' "$err_file" "publish refusal must come from readiness owner"
  pass "composition: fm-pr-body publish refuses pr ready when threads block"
}

test_publish_allows_pr_ready_when_threads_clear() {
  local home bindir body_file rc
  home=$(make_home publish-allow)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export OPEN_PRS='[]'
  export THREAD_PAYLOAD="$threads_resolved"
  body_file="$home/body.txt"
  printf 'Ready for another look.\n' >"$body_file"
  out_file="$home/publish.out"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$BODY" publish --file "$body_file" -- gh-axi pr ready https://github.com/pedromuller-del/firstmate/pull/88 \
    >"$out_file" 2>&1
  rc=$?
  expect_code 0 "$rc" "publish must allow gh pr ready when threads are clear"
  assert_grep 'forge-invoked' "$out_file" "forge command must run after readiness passes"
  pass "composition: fm-pr-body publish allows pr ready when threads are clear"
}

test_publish_does_not_gate_unrelated_pr_comment() {
  local home bindir body_file rc out_file
  home=$(make_home publish-comment)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export OPEN_PRS='[]'
  export THREAD_PAYLOAD="$threads_open_unreplied"
  body_file="$home/body.txt"
  printf 'Ordinary comment.\n' > "$body_file"
  out_file="$home/publish.out"
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$BODY" publish --file "$body_file" -- gh-axi pr comment \
      https://github.com/pedromuller-del/firstmate/pull/88 --body-file ready \
    > "$out_file" 2>&1
  rc=$?
  expect_code 0 "$rc" "ordinary PR comment must not trigger re-review readiness"
  assert_grep 'forge-invoked' "$out_file" "ordinary PR comment did not reach the forge command"
  pass "composition: unrelated PR comment bypasses re-review classification"
}

test_publish_refuses_add_reviewer_when_threads_block() {
  local home bindir body_file forge rc
  home=$(make_home publish-add-reviewer)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export OPEN_PRS='[]'
  export THREAD_PAYLOAD="$threads_open_unreplied"
  body_file="$home/body.txt"
  printf 'Request another review.\n' > "$body_file"
  for forge in gh gh-axi; do
    set +e
    PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
      "$BODY" publish --file "$body_file" -- "$forge" pr edit \
        https://github.com/pedromuller-del/firstmate/pull/88 --add-reviewer reviewer-one \
      > "$home/$forge.out" 2> "$home/$forge.err"
    rc=$?
    set -e
    expect_code 1 "$rc" "$forge pr edit --add-reviewer must obey readiness"
    assert_grep 'not ready for re-review' "$home/$forge.err" \
      "$forge reviewer request refusal did not come from readiness owner"
  done
  pass "composition: reviewer-add operations obey re-review readiness"
}

test_publish_uses_positional_pr_not_numeric_option_value() {
  local home bindir body_file rc
  home=$(make_home publish-positional-pr)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export OPEN_PRS='[]'
  export THREAD_PAYLOAD="$threads_open_unreplied"
  export THREAD_PAYLOAD_WRONG_SELECTOR="$threads_resolved"
  body_file="$home/body.txt"
  printf 'Request another review.\n' > "$body_file"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$BODY" publish --file "$body_file" -- gh-axi pr edit --repo pedromuller-del/firstmate \
      88 --add-label 12 --add-reviewer reviewer-one > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "numeric option value must not replace the positional PR selector"
  assert_grep 'not ready for re-review' "$home/err" \
    "positional PR selector did not reach the readiness owner"
  pass "composition: numeric option values cannot replace the PR selector"
}

test_publish_refuses_ambiguous_unknown_option_value() {
  local home bindir body_file rc
  home=$(make_home publish-ambiguous-option)
  bindir="$home/fakebin"
  install_fake_gh "$bindir"
  export OPEN_PRS='[]'
  export THREAD_PAYLOAD="$threads_open_unreplied"
  export THREAD_PAYLOAD_WRONG_SELECTOR="$threads_resolved"
  body_file="$home/body.txt"
  printf 'Request another review.\n' > "$body_file"
  set +e
  PATH="$bindir:$PATH" FM_HOME="$home" FM_PCW_GH_CMD=gh \
    "$BODY" publish --file "$body_file" -- gh-axi pr edit --repo pedromuller-del/firstmate \
      --add-project 12 88 --add-reviewer reviewer-one > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "ambiguous unknown option value must fail closed"
  assert_grep 'could not resolve the pull request URL' "$home/err" \
    "ambiguous selector did not fail at the shared extraction boundary"
  pass "composition: ambiguous pre-selector options fail closed"
}

test_publish_refuses_pr_ready_when_threads_block
test_publish_allows_pr_ready_when_threads_clear
test_publish_does_not_gate_unrelated_pr_comment
test_publish_refuses_add_reviewer_when_threads_block
test_publish_uses_positional_pr_not_numeric_option_value
test_publish_refuses_ambiguous_unknown_option_value

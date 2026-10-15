#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-comment-poll.sh, the standing Forgejo PR
# captain-comment poll, plus its arming hook inside bin/fm-pr-check.sh.
#
# Every surface is exercised through its executable interface with the Forgejo
# API mocked by a fake tea CLI; no case contacts a real forge. The cases that
# matter are the wake contract: with the feature flag on and the author
# allowlisted, a new "/fm " comment wakes exactly once, a non-allowlisted or
# bare comment never wakes but still advances the seen marker, every error
# path stays silent with the marker untouched so the missed window is re-read,
# the default-off flag silences arming, scanning, and already-armed polls, and
# recording a Forgejo PR arms the comment poll without ever refusing the PR
# recording itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

POLL="$ROOT/bin/fm-pr-comment-poll.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-comment-poll)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
URL=https://forgejo.example/o/r/pulls/7

# make_case <name>: scratch home plus a fake tea whose API answers come from a
# JSON fixture file named by FM_TEST_PR_COMMENTS, mirroring the real CLI's
# contracts (login list as JSON; api exit 0 with the error body on HTTP error).
make_case() {
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$fakebin" "$fake_root/bin"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" update-ref refs/remotes/origin/main "$(git -C "$dir/wt" rev-parse HEAD)"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = "axi status" ] || exit 2
head=$(git rev-parse HEAD 2>/dev/null) || exit 1
printf 'run:\n  id: "RUNFIXTURE"\n  branch: fm/task\n  status: completed\n  head_sha: %s\noutcome: passed\n' "$head"
printf 'branch_sync:\n  state: synchronized\n  local:\n    head: %s\n  pipeline:\n    current_head: %s\n' "$head" "$head"
SH
  cat > "$fakebin/tea" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "main",\n    "url": "https://forgejo.example"\n  }'
  if [ -n "${FM_TEST_TEA_SECOND_LOGIN:-}" ]; then
    printf ',\n  {\n    "name": "other",\n    "url": "https://forgejo.example"\n  }'
  fi
  printf '\n]\n'
  exit 0
fi
[ "${1:-}" = api ] || exit 0
[ -z "${FM_TEST_TEA_FAIL:-}" ] || exit 1
if [ -n "${FM_TEST_PR_COMMENTS:-}" ] && [ -f "$FM_TEST_PR_COMMENTS" ]; then
  cat "$FM_TEST_PR_COMMENTS"
else
  printf '[]\n'
fi
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tea"
  ln -sf "$(command -v jq)" "$fakebin/jq"
  : > "$dir/tea.log"
  printf '%s\n' "$dir"
}

# enable_wake <dir> [login...]: the default-off flag plus an allowlist of the
# given logins (default: the repo owner 'o' and one trusted dev).
enable_wake() {
  local dir=$1
  shift
  [ "$#" -gt 0 ] || set -- o trusted-dev
  : > "$dir/home/config/forgejo-pr-comment-wake"
  printf '%s\n' "$@" > "$dir/home/config/forgejo-pr-comment-wake-users"
}

write_task_meta() {  # <dir> [id] [extra key=val...]
  local dir=$1 id=${2:-task-a}
  shift 2 || shift $#
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@" \
    "pr=$URL"
}

run_poll() {  # <dir> [key=val...]
  local dir=$1
  shift
  env "$@" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$POLL" check
}

run_arm() {  # <dir> <id> [key=val...]
  local dir=$1 id=$2
  shift 2
  env "$@" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$POLL" arm "$id"
}

comments_json() {  # <id> <login> <body-json>
  printf '{"id":%s,"user":{"login":"%s"},"body":%s}\n' "$1" "$2" "$3"
}
write_comments() {  # <dest.json> [<id> <login> <body-json>]...
  local dest=$1 records=()
  shift
  while [ "$#" -ge 3 ]; do
    records+=("$(comments_json "$1" "$2" "$3")")
    shift 3
  done
  if [ "${#records[@]}" -gt 0 ]; then
    printf '%s\n' "${records[@]}" | jq -s . > "$dest"
  else
    printf '[]\n' > "$dest"
  fi
}


test_usage() {
  local out rc=0
  out=$("$POLL" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$POLL" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "an unknown action is a usage error"
  pass "usage and invalid arguments are handled before any side effect"
}

test_arm_baselines_and_binds() {
  local dir out rc=0
  dir=$(make_case arm-baseline)
  enable_wake "$dir"
  write_task_meta "$dir"
  write_comments "$dir/comments.json" \
    11 someone '"lgtm"' \
    12 o '"/fm rework: use a config flag instead"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a) || rc=$?
  expect_code 0 "$rc" "arm must succeed for a Forgejo PR"
  assert_contains "$out" "armed: state/task-a.pr-comment-poll" "arm names the sidecar it wrote"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 12 ] \
    || fail "arm did not baseline the seen marker at the newest comment id"
  [ -f "$dir/home/state/task-a.pr-comment-poll" ] || fail "arm wrote no sidecar"
  [ "$(fm_pr_file_mode "$dir/home/state/pr-comments.check.sh")" = 700 ] \
    || fail "the standing shim is not mode 700"
  fm_custom_check_registered "$dir/home/state" pr-comments \
    || fail "the standing shim is not registered with a trust binding"
  # Arming baselines history: the pre-existing /fm comment never wakes.
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "a comment older than the arm baseline woke"
  pass "arm baselines the seen marker and binds the standing shim"
}

test_arm_refusals() {
  local dir rc=0
  dir=$(make_case arm-refusals)
  enable_wake "$dir"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$dir/wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/o/r/pull/1"
  run_arm "$dir" task-a >/dev/null 2> "$dir/err" && rc=1 || rc=0
  expect_code 0 "$rc" "arm must refuse a non-Forgejo PR"
  assert_contains "$(cat "$dir/err")" "not a Forgejo pull request" "refusal names the provider"
  [ ! -e "$dir/home/state/task-a.pr-comment-poll" ] || fail "refusal still wrote a sidecar"
  run_arm "$dir" missing >/dev/null 2>&1 && rc=1 || rc=0
  expect_code 0 "$rc" "arm must refuse a task with no metadata"
  rc=0
  write_task_meta "$dir" task-b
  run_arm "$dir" task-b FM_TEST_TEA_SECOND_LOGIN=1 >/dev/null 2> "$dir/err2" && rc=1 || rc=0
  expect_code 0 "$rc" "arm must refuse an ambiguous tea login"
  assert_contains "$(cat "$dir/err2")" "exactly one 'tea login'" "refusal names the login requirement"
  pass "arm refuses non-Forgejo URLs, missing metadata, and ambiguous logins"
}

test_rearm_keeps_marker_and_disarm_retires() {
  local dir out
  dir=$(make_case rearm-disarm)
  enable_wake "$dir"
  write_task_meta "$dir"
  printf '%s\n' fm-pr-comment-poll-v1 forgejo \
    "$URL" forgejo.example o/r 7 > "$dir/home/state/task-a.pr-comment-poll"
  chmod 0600 "$dir/home/state/task-a.pr-comment-poll"
  printf '31\n' > "$dir/home/state/task-a.pr-comment-seen"
  run_arm "$dir" task-a >/dev/null || fail "re-arm failed"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 31 ] \
    || fail "a re-arm over an existing sidecar reset the seen marker"
  env FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
    "$POLL" disarm task-a >/dev/null || fail "disarm failed"
  [ ! -e "$dir/home/state/task-a.pr-comment-poll" ] || fail "disarm kept the sidecar"
  [ ! -e "$dir/home/state/pr-comments.check.sh" ] || fail "disarm kept the standing shim"
  [ ! -e "$dir/home/state/pr-comments.check-trust" ] || fail "disarm kept the trust binding"
  pass "re-arm keeps the seen marker; disarm retires sidecar, shim, and trust"
}

test_rearm_replacement_pr_rebaselines_the_marker() {
  local dir url2 out
  dir=$(make_case rearm-replacement-pr)
  enable_wake "$dir"
  url2=https://forgejo.example/o/r/pulls/8
  write_task_meta "$dir"
  write_comments "$dir/first.json" 100 o '"/fm old"'
  FM_TEST_PR_COMMENTS="$dir/first.json" run_arm "$dir" task-a >/dev/null \
    || fail "arm failed"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 100 ] \
    || fail "the first arm did not baseline the marker"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=$url2"
  write_comments "$dir/second.json" 3 o '"/fm rework: narrower scope"'
  FM_TEST_PR_COMMENTS="$dir/second.json" run_arm "$dir" task-a >/dev/null \
    || fail "re-arm failed"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 3 ] \
    || fail "re-arming a replacement PR kept the retired PR's marker"
  grep -q "^$url2$" "$dir/home/state/task-a.pr-comment-poll" \
    || fail "re-arm did not retarget the sidecar at the replacement PR"
  write_comments "$dir/third.json" \
    3 o '"/fm rework: narrower scope"' \
    4 o '"/fm also drop the flag"'
  out=$(FM_TEST_PR_COMMENTS="$dir/third.json" run_poll "$dir")
  [ "$out" = "pr-comment: task task-a has new command comment id(s) 4 on $url2" ] \
    || fail "a captain comment on the replacement PR did not wake: got '$out'"
  out=$(FM_TEST_PR_COMMENTS="$dir/third.json" run_poll "$dir")
  [ -z "$out" ] || fail "the replacement PR's comment woke twice: got '$out'"
  pass "re-arming a replacement PR re-baselines the marker and wakes its new comments"
}
test_retarget_during_fetch_leaves_wake_and_marker_untouched() {
  local dir out
  dir=$(make_case retarget-mid-fetch)
  enable_wake "$dir"
  write_task_meta "$dir"
  write_comments "$dir/base.json" 100 o '"/fm old"'
  FM_TEST_PR_COMMENTS="$dir/base.json" run_arm "$dir" task-a >/dev/null \
    || fail "arm failed"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 100 ] \
    || fail "the first arm did not baseline the marker"
  # The sweep's own fetch performs a concurrent replacement arm's writes: the
  # sidecar is retargeted to pulls/8 with a fresh marker while the in-flight
  # read still returns pulls/7's comments, including one new wake comment.
  cat > "$dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "main",\n    "url": "https://forgejo.example"\n  }\n]\n'
  exit 0
fi
[ "${1:-}" = api ] || exit 0
printf '%s\n' fm-pr-comment-poll-v1 forgejo \
  "https://forgejo.example/o/r/pulls/8" forgejo.example o/r 8 \
  > "$FM_HOME/state/task-a.pr-comment-poll"
chmod 0600 "$FM_HOME/state/task-a.pr-comment-poll"
printf '3\n' > "$FM_HOME/state/task-a.pr-comment-seen"
cat "$FM_TEST_PR_COMMENTS"
SH
  chmod +x "$dir/fakebin/tea"
  write_comments "$dir/retarget.json" \
    100 o '"/fm old"' \
    101 o '"/fm rework: narrower scope"'
  out=$(FM_TEST_PR_COMMENTS="$dir/retarget.json" run_poll "$dir")
  [ -z "$out" ] || fail "a read whose PR was retargeted mid-fetch woke: got '$out'"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 3 ] \
    || fail "a read whose PR was retargeted mid-fetch moved the marker"
  grep -q "^https://forgejo.example/o/r/pulls/8$" \
    "$dir/home/state/task-a.pr-comment-poll" \
    || fail "the test's mid-fetch retarget never happened"
  pass "a PR retargeted by a concurrent arm mid-fetch leaves wake and marker untouched"
}


test_wake_once_on_new_captain_command_comment() {
  local dir out
  dir=$(make_case wake-once)
  enable_wake "$dir"
  write_task_meta "$dir"
  write_comments "$dir/comments.json" \
    11 someone '"lgtm"' \
    12 o '"plain captain note"'
  FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a >/dev/null || fail "arm failed"
  write_comments "$dir/comments.json" \
    11 someone '"lgtm"' \
    12 o '"plain captain note"' \
    13 o '"/fm rework: use a config flag instead"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ "$out" = "pr-comment: task task-a has new command comment id(s) 13 on $URL" ] \
    || fail "a new allowlisted /fm comment did not wake with exactly one line: got '$out'"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 13 ] \
    || fail "a waking poll did not advance the seen marker"
  # Re-poll of the same window must not double-wake.
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "a re-poll of already-seen comments woke again: got '$out'"
  pass "a new captain /fm comment wakes exactly once"
}

test_ignored_commenters_and_bare_comments_advance_the_marker() {
  local dir out
  dir=$(make_case ignored-comments)
  enable_wake "$dir"
  write_task_meta "$dir"
  write_comments "$dir/comments.json"
  FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a >/dev/null || fail "arm failed"
  write_comments "$dir/comments.json" \
    21 other-user '"/fm do something"' \
    22 o '"bare captain comment without the prefix"' \
    23 o '"/fmship not the command prefix"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "a non-captain or bare comment woke: got '$out'"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 23 ] \
    || fail "ignored comments did not advance the seen marker"
  # The ignored window must never wake later.
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "an already-ignored comment woke on a later poll"
  pass "non-captain and bare comments never wake but advance the marker"
}

test_error_paths_stay_silent_and_keep_the_marker() {
  local dir out
  dir=$(make_case error-silent)
  enable_wake "$dir"
  write_task_meta "$dir"
  write_comments "$dir/comments.json" \
    5 o '"/fm old"' \
    6 o '"/fm new"'
  FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a >/dev/null || fail "arm failed"
  printf '5\n' > "$dir/home/state/task-a.pr-comment-seen"
  for variant in fail error-body bad-json; do
    case "$variant" in
      fail) FM_TEST_TEA_FAIL=1 ;;
      error-body) printf '{"message":"not found"}\n' > "$dir/comments.json" ;;
      bad-json) printf 'not json at all\n' > "$dir/comments.json" ;;
    esac
    out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir" ${FM_TEST_TEA_FAIL:+FM_TEST_TEA_FAIL=$FM_TEST_TEA_FAIL})
    unset FM_TEST_TEA_FAIL
    [ -z "$out" ] || fail "an errored poll woke for $variant: got '$out'"
    [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 5 ] \
      || fail "an errored poll advanced the marker for $variant"
  done
  # An ambiguous login is silent with a readable payload too, and the missed
  # window is re-read later.
  write_comments "$dir/comments.json" \
    5 o '"/fm old"' \
    6 o '"/fm new"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" FM_TEST_TEA_SECOND_LOGIN=1 run_poll "$dir")
  [ -z "$out" ] || fail "an ambiguous login woke: got '$out'"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 5 ] \
    || fail "an ambiguous login advanced the marker"
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  assert_contains "$out" "id(s) 6" "the window missed to errors is re-read and wakes"
  pass "tea failures, error bodies, bad payloads, and ambiguous logins stay silent without advancing the marker"
}

test_doctored_sidecar_and_retired_task() {
  local dir out
  dir=$(make_case doctored-retired)
  enable_wake "$dir"
  write_task_meta "$dir" task-a
  write_task_meta "$dir" task-b
  write_comments "$dir/comments.json" 5 someone '"lgtm"'
  FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a >/dev/null || fail "arm failed"
  FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-b >/dev/null || fail "arm failed"
  # A sidecar whose parts do not reconstruct its URL is ignored - the path
  # says o/evil while the URL says o/r - even with a captain command waiting
  # that a valid sidecar would wake on.
  printf '%s\n' fm-pr-comment-poll-v1 forgejo \
    "https://forgejo.example/o/r/pulls/7" forgejo.example o/evil 7 \
    > "$dir/home/state/task-a.pr-comment-poll"
  chmod 0600 "$dir/home/state/task-a.pr-comment-poll"
  # A task whose metadata record is gone retires its sidecar silently.
  rm -f "$dir/home/state/task-b.meta"
  write_comments "$dir/comments.json" \
    5 someone '"lgtm"' \
    9 o '"/fm rework: narrower scope"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "a doctored sidecar or retired task woke: got '$out'"
  [ ! -e "$dir/home/state/task-b.pr-comment-poll" ] || fail "a retired task kept its sidecar"
  [ ! -e "$dir/home/state/task-b.pr-comment-seen" ] || fail "a retired task kept its marker"
  [ -e "$dir/home/state/task-a.pr-comment-poll" ] || fail "a live task lost its sidecar"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 5 ] \
    || fail "a doctored sidecar advanced the seen marker"
  pass "a doctored sidecar is ignored and a cleaned-up task retires its poll"
}

test_arm_refuses_missing_or_invalid_allowlist() {
  local dir rc=0
  dir=$(make_case arm-allowlist)
  write_task_meta "$dir"
  : > "$dir/home/config/forgejo-pr-comment-wake"
  run_arm "$dir" task-a >/dev/null 2> "$dir/err" && rc=1 || rc=0
  expect_code 0 "$rc" "arm must refuse with no allowlist"
  assert_contains "$(cat "$dir/err")" "forgejo-pr-comment-wake-users" \
    "refusal names the allowlist"
  [ ! -e "$dir/home/state/task-a.pr-comment-poll" ] \
    || fail "arm with no allowlist still wrote a sidecar"
  : > "$dir/home/config/forgejo-pr-comment-wake-users"
  rc=0
  run_arm "$dir" task-a >/dev/null 2> "$dir/err2" && rc=1 || rc=0
  expect_code 0 "$rc" "arm must refuse an empty allowlist"
  printf 'good-login\nnot a login\n' \
    > "$dir/home/config/forgejo-pr-comment-wake-users"
  rc=0
  run_arm "$dir" task-a >/dev/null 2> "$dir/err3" && rc=1 || rc=0
  expect_code 0 "$rc" "arm must refuse an allowlist line no login can hold"
  [ ! -e "$dir/home/state/task-a.pr-comment-poll" ] \
    || fail "arm over an invalid allowlist still wrote a sidecar"
  pass "arm refuses missing, empty, and invalid allowlists without arming"
}

test_flag_gates_the_whole_feature() {
  local dir out rc=0
  dir=$(make_case flag-off)
  write_task_meta "$dir"
  write_comments "$dir/comments.json" 1 o '"/fm would wake if enabled"'
  # With no flag, arm and check are silent no-ops that write nothing.
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a) || rc=$?
  expect_code 0 "$rc" "arm without the flag must exit 0"
  [ -z "$out" ] || fail "arm without the flag printed: '$out'"
  [ ! -e "$dir/home/state/task-a.pr-comment-poll" ] \
    || fail "arm without the flag wrote a sidecar"
  [ ! -e "$dir/home/state/pr-comments.check.sh" ] \
    || fail "arm without the flag wrote the standing shim"
  # An armed poll whose flag was later removed stays silent, marker untouched.
  enable_wake "$dir"
  FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a >/dev/null \
    || fail "arm with the flag failed"
  write_comments "$dir/comments.json" \
    1 o '"/fm would wake if enabled"' \
    2 o '"/fm newer"'
  rm -f "$dir/home/config/forgejo-pr-comment-wake"
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "a check with the flag removed woke: '$out'"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 1 ] \
    || fail "a check with the flag removed advanced the marker"
  pass "the default-off flag gates arming, scanning, and already-armed polls"
}

test_allowlist_decides_who_wakes_the_crew() {
  local dir out
  dir=$(make_case allowlist)
  enable_wake "$dir" trusted-dev
  write_task_meta "$dir"
  write_comments "$dir/comments.json"
  FM_TEST_PR_COMMENTS="$dir/comments.json" run_arm "$dir" task-a >/dev/null \
    || fail "arm failed"
  # The repository owner is not the captain identity by inference: not being
  # in the allowlist, even their command comment never wakes.
  write_comments "$dir/comments.json" \
    30 o '"/fm owner is not allowlisted"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "a non-allowlisted owner command comment woke: '$out'"
  [ "$(cat "$dir/home/state/task-a.pr-comment-seen")" = 30 ] \
    || fail "the non-allowlisted comment did not advance the marker"
  # An allowlisted trusted dev's command comment wakes exactly once, and a
  # later allowlist edit admitting the owner applies without re-arming.
  write_comments "$dir/comments.json" \
    30 o '"/fm owner is not allowlisted"' \
    31 trusted-dev '"/fm rework: narrower scope"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ "$out" = "pr-comment: task task-a has new command comment id(s) 31 on $URL" ] \
    || fail "an allowlisted dev command comment did not wake: got '$out'"
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ -z "$out" ] || fail "the dev command comment woke twice: '$out'"
  printf 'o\ntrusted-dev\n' > "$dir/home/config/forgejo-pr-comment-wake-users"
  write_comments "$dir/comments.json" \
    30 o '"/fm owner is not allowlisted"' \
    31 trusted-dev '"/fm rework: narrower scope"' \
    32 o '"/fm now allowlisted"'
  out=$(FM_TEST_PR_COMMENTS="$dir/comments.json" run_poll "$dir")
  [ "$out" = "pr-comment: task task-a has new command comment id(s) 32 on $URL" ] \
    || fail "a newly allowlisted login's command comment did not wake: '$out'"
  pass "the allowlist alone decides who wakes, and edits apply without re-arming"
}

test_pr_check_arms_comment_poll_without_refusing() {
  local dir rc=0
  dir=$(make_case pr-check-hook)
  write_task_meta "$dir" task-a
  write_comments "$dir/comments.json"
  # Without the flag, recording a Forgejo PR neither arms the comment poll
  # nor warns: an unconfigured home behaves exactly as before the feature.
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_PR_COMMENTS="$dir/comments.json" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a "$URL" > "$dir/out0" 2> "$dir/err0" || rc=$?
  expect_code 0 "$rc" "recording a Forgejo PR must succeed with the flag off"
  [ ! -e "$dir/home/state/task-a.pr-comment-poll" ] \
    || fail "the flag-off recording armed the comment poll"
  if grep -q "comment poll not armed" "$dir/err0"; then
    fail "the flag-off recording warned about the comment poll"
  fi
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "the merge poll was not armed"
  enable_wake "$dir"
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_PR_COMMENTS="$dir/comments.json" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a "$URL" > "$dir/out" 2> "$dir/err" || rc=$?
  expect_code 0 "$rc" "recording a Forgejo PR must succeed"
  [ -f "$dir/home/state/task-a.pr-comment-poll" ] \
    || fail "recording a Forgejo PR did not arm the comment poll"
  fm_custom_check_registered "$dir/home/state" pr-comments \
    || fail "recording a Forgejo PR did not register the standing comment check"
  # A comment-arm failure is a warning, never a refusal.
  rm -f "$dir/home/state/task-a.pr-comment-poll" \
    "$dir/home/state/pr-comments.check.sh" "$dir/home/state/pr-comments.check-trust"
  # An unreadable comments payload fails only the comment arm; the merge poll's
  # own preconditions (one tea login, jq) still hold, so only the warning fires.
  printf 'not json at all\n' > "$dir/comments-bad.json"
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_PR_COMMENTS="$dir/comments-bad.json" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a "$URL" > "$dir/out2" 2> "$dir/err2" || rc=$?
  expect_code 0 "$rc" "a comment-arm failure must not refuse the PR recording"
  assert_grep "comment poll not armed" "$dir/err2" "the warning names the un-armed comment poll"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "the merge poll was not armed"
  pass "fm-pr-check arms the flagged comment poll, stays silent without the flag, and only warns when arming fails"
}

test_usage
test_arm_baselines_and_binds
test_arm_refusals
test_rearm_keeps_marker_and_disarm_retires
test_rearm_replacement_pr_rebaselines_the_marker
test_retarget_during_fetch_leaves_wake_and_marker_untouched
test_wake_once_on_new_captain_command_comment
test_ignored_commenters_and_bare_comments_advance_the_marker
test_error_paths_stay_silent_and_keep_the_marker
test_doctored_sidecar_and_retired_task
test_pr_check_arms_comment_poll_without_refusing
test_arm_refuses_missing_or_invalid_allowlist
test_flag_gates_the_whole_feature
test_allowlist_decides_who_wakes_the_crew


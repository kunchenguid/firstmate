#!/usr/bin/env bash
# Behavioral tests for the Bitbucket Cloud PR provider: URL parsing, the
# static watcher poll, arming, and the merge path in bin/fm-pr-lib.sh,
# bin/fm-pr-poll.sh, bin/fm-pr-check.sh, and bin/fm-pr-merge.sh.
# twg carries the operator's own saved Atlassian credentials, the same way
# gh owns GitHub's authentication and glab owns GitLab's, so every case here
# exercises that same contract through a fake twg rather than a real one.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-bitbucket)
fm_git_identity fmtest fmtest@example.invalid
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_JQ=$(command -v jq) || fail "these tests read twg's JSON with the real jq, which was not found"

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
printf 'guard\n' >> "$FM_TEST_GUARD_LOG"
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  # A fixture twg, reproducing the real CLI's contract: `-o json` on stdout and
  # exit 0 on success, or a non-zero exit with no stdout on any failure. The
  # merge subcommand accepts and logs whatever extra flags the caller passed,
  # since the merge path forwards the caller's own extra arguments verbatim.
  cat > "$fakebin/twg" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_TWG_LOG"
[ "${FM_TEST_TWG_FAIL:-0}" = 0 ] || exit 1
case "$1 $2 $3" in
  "bb pull-requests get")
    statuses=$FM_TEST_TWG_STATUSES
    [ -n "$statuses" ] || statuses='[{"state":"SUCCESSFUL"}]'
    jq -n \
      --arg state "${FM_TEST_TWG_STATE:-OPEN}" \
      --arg head "${FM_TEST_TWG_HEAD:-abc123def456}" \
      --argjson tasks "${FM_TEST_TWG_TASKS:-0}" \
      --argjson statuses "$statuses" \
      '{state: $state, source: {commit: {hash: $head}}, task_count: $tasks, statuses: $statuses}'
    exit 0
    ;;
  "bb pull-requests merge")
    exit "${FM_TEST_TWG_MERGE_RC:-0}"
    ;;
esac
exit 2
SH
  chmod +x "$fakebin/twg"
  ln -sf "$REAL_JQ" "$fakebin/jq"
  : > "$dir/twg.log"
  : > "$dir/guard.log"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

# Extra "field=value" arguments are written before pr=, because
# fm_pr_metadata_identity_parse rejects an unrecognised line after it.
write_poll_meta() {
  local state=$1 id=$2 url=$3 case_dir
  case_dir=$(cd "$state/../.." && pwd)
  shift 3
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" \
    "worktree=$case_dir/wt" \
    "$@" \
    "pr=$url"
}

run_check_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_TWG_LOG="$dir/twg.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

run_merge_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_TWG_LOG="$dir/twg.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_MERGE" "$@"
}

run_poll() {
  local dir=$1
  FM_TEST_TWG_LOG="$dir/twg.log" PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/task-a.check.sh"
}

test_bitbucket_url_parsing() {
  local url host path number
  while IFS='|' read -r url host path number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" \
      || fail "parser refused a valid Bitbucket pull-request URL: $url"
    [ "$FM_PR_PROVIDER" = bitbucket ] \
      || fail "parser did not tag a Bitbucket pull-request URL as bitbucket"
    [ "$FM_PR_HOST" = "$host" ] || fail "parser returned wrong Bitbucket host"
    [ "$FM_PR_PATH" = "$path" ] || fail "parser returned wrong Bitbucket workspace/repo path"
    [ "$FM_PR_NUMBER" = "$number" ] || fail "parser returned wrong Bitbucket pull-request number"
  done <<MATRIX
https://bitbucket.org/myworkspace/my-repo/pull-requests/42|bitbucket.org|myworkspace/my-repo|42
https://bitbucket.org/ws/repo.name_with-punct/pull-requests/1|bitbucket.org|ws/repo.name_with-punct|1
MATRIX

  for url in \
    'https://bitbucket.com/ws/repo/pull-requests/1' \
    'https://BitBucket.org/ws/repo/pull-requests/1' \
    'https://bitbucket.org/ws/repo/pull-requests/0' \
    'https://bitbucket.org/ws/repo/pull-requests/01' \
    'https://bitbucket.org/ws/pull-requests/1' \
    'https://bitbucket.org/ws/repo/sub/pull-requests/1' \
    'https://bitbucket.org//repo/pull-requests/1' \
    'https://bitbucket.org/-ws/repo/pull-requests/1' \
    'https://bitbucket.org/ws/repo.git/pull-requests/1' \
    'https://bitbucket.org/ws/repo/pull-requests/1/' \
    'https://bitbucket.org/ws/repo/pull-requests/1?x=1' \
    'https://bitbucket.org/ws/repo/merge-requests/1' \
    'http://bitbucket.org/ws/repo/pull-requests/1'; do
    ! fm_pr_url_parse "$url" \
      || fail "parser accepted an invalid Bitbucket pull-request URL: $url"
  done
  pass "the parser tags valid Bitbucket Cloud pull-request URLs and refuses malformed ones"
}

# The Bitbucket watch must follow a pull request exactly as the GitHub and
# GitLab watches follow theirs, and must never turn an unreadable pull
# request into a merge.
test_bitbucket_merge_watch() {
  local dir state out rc url
  dir=$(make_case bitbucket-merge-watch)
  state="$dir/home/state"
  url=https://bitbucket.org/myworkspace/my-repo/pull-requests/7

  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a bitbucket "$url" bitbucket.org myworkspace/my-repo 7 "$POLL" \
    || fail "could not prepare a Bitbucket poll"
  fm_pr_poll_publish_prepared || fail "could not publish a Bitbucket poll"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "published Bitbucket poll provenance or metadata binding was invalid"
  [ "$(cat "$state/task-a.pr-poll")" = "bitbucket
$url
bitbucket.org
myworkspace/my-repo
7" ] || fail "published Bitbucket sidecar bytes were not exact"

  # Only an exact MERGED state wakes firstmate. Every other reading, including
  # an unreadable pull request, stays silent.
  local value
  for value in OPEN DECLINED SUPERSEDED '' not-a-state merged; do
    out=$(FM_TEST_TWG_STATE="$value" run_poll "$dir")
    [ -z "$out" ] || fail "Bitbucket poll emitted for a non-merged state: $value"
  done
  out=$(FM_TEST_TWG_STATE=MERGED run_poll "$dir")
  [ "$out" = merged ] || fail "Bitbucket poll did not emit exactly one merged line"
  out=$(FM_TEST_TWG_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "Bitbucket poll emitted after a twg failure"

  # twg is addressed by workspace, repository slug, and pull-request number.
  grep -qF -- "bb pull-requests get 7 -w myworkspace -r my-repo" "$dir/twg.log" \
    || fail "Bitbucket poll did not address twg by workspace, repository, and number"

  # An absent CLI must produce no wake rather than a false merge.
  local notwg bindir entry name
  notwg="$dir/notwg"
  mkdir -p "$notwg"
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      [ "$name" = twg ] && continue
      [ -e "$notwg/$name" ] || ln -s "$entry" "$notwg/$name" 2>/dev/null
    done
  done <<EOF
$dir/fakebin
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
  ! PATH="$notwg" command -v twg >/dev/null 2>&1 \
    || fail "the twg-free search path still resolved twg"
  out=$(FM_TEST_TWG_STATE=MERGED PATH="$notwg" bash "$state/task-a.check.sh")
  [ -z "$out" ] || fail "Bitbucket poll emitted with twg absent from PATH"

  # A doctored sidecar cannot redirect the poll: the stored parts must rebuild
  # the stored URL exactly.
  printf '%s\n%s\n%s\n%s\n%s\n' bitbucket "$url" bitbucket.org otherworkspace/my-repo 7 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_TWG_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Bitbucket poll emitted for a sidecar whose workspace was swapped"
  printf '%s\n%s\n%s\n%s\n%s\n' bitbucket "$url" bitbucket.org myworkspace/other-repo 7 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_TWG_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "Bitbucket poll emitted for a sidecar whose repository was swapped"

  # Arming is where a missing CLI can still be reported, so it refuses there.
  write_task_meta "$dir" task-b
  set +e
  out=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" PATH="$notwg" \
    "$PR_CHECK" task-b "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming a Bitbucket watch succeeded with twg absent"
  case "$out" in
    *"requires twg on PATH"*) ;;
    *) fail "arming a Bitbucket watch with twg absent did not report the missing CLI" ;;
  esac
  [ ! -e "$state/task-b.check.sh" ] || fail "refused Bitbucket arming left a poll armed"

  # The merge path refuses rather than merging on a state it could not read.
  write_task_meta "$dir" task-c
  : > "$dir/twg.log"
  set +e
  FM_TEST_TWG_FAIL=1 run_merge_entry "$dir" task-c "$url" >/dev/null 2> "$dir/merge-c.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge wrapper merged a Bitbucket pull request it could not read"
  grep -qF 'could not read the Bitbucket pull request state before merging' "$dir/merge-c.err" \
    || fail "merge wrapper refused for some reason other than the state it could not read"
  ! grep -qF ' merge ' "$dir/twg.log" \
    || fail "merge wrapper merged despite an unreadable pull request state"

  pass "Bitbucket pull requests are followed and never wake falsely"
}

test_bitbucket_verify_mergeable_refusals() {
  local dir url rc out
  dir=$(make_case bitbucket-verify-refusals)
  url=https://bitbucket.org/ws/repo/pull-requests/9
  write_task_meta "$dir"

  set +e
  FM_TEST_TWG_STATE=DECLINED run_merge_entry "$dir" task-a "$url" >/dev/null 2> "$dir/state.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge wrapper merged a declined pull request"
  grep -qF 'not OPEN' "$dir/state.err" || fail "declined-state refusal did not name the state"

  set +e
  FM_TEST_TWG_TASKS=2 run_merge_entry "$dir" task-a "$url" >/dev/null 2> "$dir/tasks.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge wrapper merged a pull request with open tasks"
  grep -qF 'open task' "$dir/tasks.err" || fail "open-task refusal did not name the task count"

  set +e
  FM_TEST_TWG_STATUSES='[{"state":"FAILED"}]' run_merge_entry "$dir" task-a "$url" \
    >/dev/null 2> "$dir/build.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge wrapper merged a pull request with a failing build status"
  grep -qF 'not SUCCESSFUL' "$dir/build.err" || fail "failing-build refusal did not name the status"

  # A pull request with no reported build status at all is not thereby
  # unmergeable, unlike one with a failing status.
  out=$(FM_TEST_TWG_STATUSES='[]' run_merge_entry "$dir" task-a "$url" 2>&1) \
    || fail "merge wrapper refused a pull request with no reported build status: $out"
  grep -qF "bb pull-requests merge --pull-request 9 -w ws -r repo" "$dir/twg.log" \
    || fail "merge wrapper did not call twg's merge command with the derived workspace and repository"

  pass "the Bitbucket merge path refuses an unopen, blocked, or unclean pull request and reports why"
}

test_bitbucket_merge_confirms_and_binds_extra_flags() {
  local dir url out
  dir=$(make_case bitbucket-merge-confirm)
  url=https://bitbucket.org/ws/repo/pull-requests/12
  write_task_meta "$dir"

  out=$(FM_TEST_TWG_STATE=OPEN run_merge_entry "$dir" task-a "$url" -- --merge-strategy squash 2>&1) \
    || fail "valid Bitbucket merge wrapper failed: $out"
  grep -qF "bb pull-requests merge --pull-request 12 -w ws -r repo --merge-strategy squash" "$dir/twg.log" \
    || fail "merge wrapper did not forward the caller's own extra merge arguments"

  # After a merge twg accepted, the pull request is read back and only a
  # confirmed MERGED state is reported as landed.
  set +e
  : > "$dir/twg.log"
  FM_TEST_TWG_STATE=OPEN FM_TEST_TWG_MERGE_RC=0 run_merge_entry "$dir" task-a "$url" >"$dir/unconfirmed.out" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "an accepted merge that reads back as still open should not fail the run: $(cat "$dir/unconfirmed.out")"
  grep -qF 'landed state could not be confirmed' "$dir/unconfirmed.out" \
    && fail "an accepted merge that reads back as open should be silent about confirmation, not report an unreadable state"

  # --allow-red and --allow-missing have no matching per-check waiver here and
  # must be refused rather than silently ignored.
  set +e
  run_merge_entry "$dir" task-a "$url" --allow-red somecheck >/dev/null 2> "$dir/allow-red.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--allow-red was silently accepted for a Bitbucket merge"
  grep -qF 'does not apply to GitLab or Bitbucket' "$dir/allow-red.err" \
    || fail "--allow-red refusal did not name Bitbucket"

  # Branch deletion (--close-source-branch) is refused by default, the same as
  # GitHub's --delete-branch and GitLab's --remove-source-branch.
  set +e
  run_merge_entry "$dir" task-a "$url" -- --close-source-branch >/dev/null 2> "$dir/close-branch.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--close-source-branch was accepted without --attended-override"
  grep -qF 'branch deletion' "$dir/close-branch.err" \
    || fail "--close-source-branch refusal did not name branch deletion"

  pass "a Bitbucket merge confirms the landed state, forwards extra flags, and refuses unwaived protected flags"
}

test_bitbucket_url_parsing
test_bitbucket_merge_watch
test_bitbucket_verify_mergeable_refusals
test_bitbucket_merge_confirms_and_binds_extra_flags

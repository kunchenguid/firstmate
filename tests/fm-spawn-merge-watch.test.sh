#!/usr/bin/env bash
# tests/fm-spawn-merge-watch.test.sh - a fresh spawn on a task id that still
# carries a kept merge watch (state/<id>.merge-watch, bin/fm-pr-lib.sh) retires
# the watch and its poll, names the watched PR for the new worker, and refuses
# with a real remedy whenever the watch cannot be retired cleanly. Drives
# bin/fm-spawn.sh end to end against a fake tmux and a real isolated git
# worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-merge-watch)
URL=https://github.com/o/r/pull/7

make_spawn_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Sets CASE_HOME CASE_PROJ CASE_WT CASE_FAKEBIN CASE_ID for the caller.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  CASE_HOME="$case_dir/home"
  CASE_PROJ="$case_dir/project"
  CASE_WT="$case_dir/wt"
  CASE_ID=$name-z1
  CASE_FAKEBIN=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$CASE_HOME/data/$CASE_ID" "$CASE_HOME/projects" "$CASE_HOME/state" "$CASE_HOME/config"
  printf 'claude\n' > "$CASE_HOME/config/crew-harness"
  printf '%s\n' "$$" > "$CASE_HOME/state/.lock"
  touch "$CASE_HOME/state/.last-watcher-beat"
  fm_git_worktree "$CASE_PROJ" "$CASE_WT" "wt-$name"
  cat > "$CASE_HOME/data/$CASE_ID/brief.md" <<BRIEF
# Task
## Captain's intent
Address review feedback on the open PR for $CASE_ID.

## Firstmate spec
Push the requested changes to the same PR.
BRIEF
}

# The state a ship task's cleanup leaves behind when its PR is still open: the
# armed poll artifacts bound to a merge-watch record, with no task meta.
seed_kept_watch() {
  fm_pr_url_parse "$URL" || fail "merge-watch fixture URL was unparseable"
  fm_pr_merge_watch_publish "$CASE_HOME/state" "$CASE_ID" "$FM_PR_PROVIDER" "$URL" \
    "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    || fail "could not publish the merge-watch fixture"
  [ "${1:-}" = no-poll ] && return 0
  fm_pr_poll_prepare "$CASE_HOME/state" "$CASE_ID" "$FM_PR_PROVIDER" "$URL" \
    "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$POLL" \
    || fail "could not prepare the merge-poll fixture"
  fm_pr_poll_publish_prepared || fail "could not publish the merge-poll fixture"
}

run_spawn() {
  mkdir -p "$CASE_HOME/user-home"
  env FM_TRACE_CONTEXT="${SPAWN_TRACE_CONTEXT:-off}" \
    FM_ROOT_OVERRIDE='' FM_HOME="$CASE_HOME" HOME="$CASE_HOME/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$CASE_HOME/state" FM_DATA_OVERRIDE="$CASE_HOME/data" \
    FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$CASE_WT" TMUX="fake,1,0" \
    PATH="$CASE_FAKEBIN:$PATH" \
    "$SPAWN" "$CASE_ID" "$CASE_PROJ" "$@" 2>&1
}

assert_watch_untouched() {  # <label>
  fm_pr_merge_watch_valid "$CASE_HOME/state" "$CASE_ID" \
    || fail "$1 damaged the merge-watch record"
  [ -e "$CASE_HOME/state/$CASE_ID.check.sh" ] || fail "$1 removed the armed check"
  [ ! -e "$CASE_HOME/state/$CASE_ID.meta" ] || fail "$1 created task metadata"
}

# The re-dispatch this exists for: the captain asks for changes on a PR whose
# worker was already cleaned up, and the home dispatches the same ticket id.
test_spawn_retires_a_kept_merge_watch() {
  local out status meta artifact
  make_case retire
  seed_kept_watch
  fm_pr_url_parse "$URL" || fail "merge-watch fixture URL was unparseable"
  fm_pr_poll_merge_mark_notified "$CASE_HOME/state" "$CASE_ID" "$FM_PR_PROVIDER" \
    "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    || fail "could not seed the merge-notified marker"

  out=$(run_spawn --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn on an id with a kept merge watch should retire it: $out"
  assert_contains "$out" "merge watch retired: $URL" "spawn did not name the retired watch's PR"
  assert_contains "$out" "bin/fm-pr-check.sh $CASE_ID $URL" "spawn did not name the re-arm step"
  assert_contains "$out" "spawned $CASE_ID" "spawn did not report success"
  meta="$CASE_HOME/state/$CASE_ID.meta"
  [ -f "$meta" ] || fail "spawn did not publish the task record"
  ! grep -q '^pr=' "$meta" || fail "the new task record carries pr= at birth"
  for artifact in merge-watch check.sh pr-poll pr-poll-registration pr-poll-retirement \
    pr-poll-merge-notified pr-poll-closed-notified; do
    [ ! -e "$CASE_HOME/state/$CASE_ID.$artifact" ] \
      || fail "retiring the merge watch left state/$CASE_ID.$artifact behind"
  done
  pass "a fresh spawn retires a kept merge watch, names its PR, and never records pr= at birth"
}

# A spawn refused before its task record is published - here by a pending
# backlog close - must leave the kept watch exactly as it was: nothing else
# would notice the PR merging once no worker exists to re-arm the poll.
test_spawn_refused_before_publish_keeps_the_watch() {
  local out status
  make_case refused
  seed_kept_watch
  fm_pr_url_parse "$URL" || fail "merge-watch fixture URL was unparseable"
  fm_pr_poll_merge_mark_notified "$CASE_HOME/state" "$CASE_ID" "$FM_PR_PROVIDER" \
    "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" \
    || fail "could not seed the merge-notified marker"
  : > "$CASE_HOME/state/$CASE_ID.backlog-close"

  out=$(run_spawn --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn with a pending backlog close was not refused: $out"
  assert_contains "$out" "pending authoritative backlog close" "spawn was refused for an unexpected reason"
  assert_not_contains "$out" "merge watch retired" "a refused spawn reported retiring the watch"
  assert_watch_untouched "the spawn refused before publish"
  fm_pr_poll_artifacts_valid "$CASE_HOME/state" "$CASE_ID" "$POLL" \
    || fail "the spawn refused before publish damaged the armed poll"
  [ "$FM_PR_META_URL" = "$URL" ] || fail "the armed poll no longer binds the watched PR"
  [ -e "$CASE_HOME/state/$CASE_ID.pr-poll-merge-notified" ] \
    || fail "the spawn refused before publish removed the merge-notified marker"
  pass "a spawn refused before its record is published leaves the kept watch, poll and markers intact"
}

test_spawn_refuses_a_watch_it_cannot_retire_cleanly() {
  local out status
  make_case unsafe
  seed_kept_watch
  ln "$CASE_HOME/state/$CASE_ID.check.sh" "$CASE_HOME/check-link" \
    || fail "could not hard-link the armed check"

  out=$(run_spawn --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn proceeded past a merge watch it could not retire: $out"
  assert_contains "$out" "$URL" "refusal did not name the watched PR"
  assert_contains "$out" "different task id" "refusal did not name a remedy"
  assert_watch_untouched "the refused spawn"
  pass "a spawn refuses an id whose merge watch cannot be retired cleanly and leaves the watch intact"
}

test_spawn_refuses_an_unreadable_watch_record() {
  local out status
  make_case unreadable
  seed_kept_watch
  printf 'not-a-merge-watch\n' > "$CASE_HOME/state/$CASE_ID.merge-watch"

  out=$(run_spawn --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn proceeded past an unreadable merge-watch record: $out"
  assert_contains "$out" "state/$CASE_ID.merge-watch" "refusal did not name the merge-watch record"
  assert_contains "$out" "different task id" "refusal did not name a remedy"
  [ -e "$CASE_HOME/state/$CASE_ID.merge-watch" ] || fail "the refused spawn removed the record"
  [ -e "$CASE_HOME/state/$CASE_ID.check.sh" ] || fail "the refused spawn removed the armed check"
  [ ! -e "$CASE_HOME/state/$CASE_ID.meta" ] || fail "the refused spawn created task metadata"
  pass "a spawn refuses an id whose merge-watch record is unreadable and touches nothing"
}

test_spawn_retires_a_kept_merge_watch
test_spawn_refused_before_publish_keeps_the_watch
test_spawn_refuses_a_watch_it_cannot_retire_cleanly
test_spawn_refuses_an_unreadable_watch_record

echo "# all fm-spawn-merge-watch tests passed"

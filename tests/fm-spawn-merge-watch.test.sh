#!/usr/bin/env bash
# tests/fm-spawn-merge-watch.test.sh - a fresh spawn on a task id that still
# carries a kept merge watch (state/<id>.merge-watch, bin/fm-pr-lib.sh) adopts
# the watch into the new task, and refuses with a real remedy whenever the
# adoption cannot be proven safe. Drives bin/fm-spawn.sh end to end against a
# fake tmux and a real isolated git worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

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
  [ ! -e "$CASE_HOME/state/$CASE_ID.meta" ] || fail "$1 created task metadata"
}

# The re-dispatch this exists for: the captain asks for changes on a PR whose
# worker was already cleaned up, and the home dispatches the same ticket id.
# Trace context is on so the carrier recorded after publication is covered too:
# it must not land after pr= and break the poll binding.
test_ship_spawn_adopts_a_kept_merge_watch() {
  local out status meta
  make_case adopt
  seed_kept_watch
  : > "$CASE_HOME/config/trace-context"
  FM_TRACE_CONTEXT=on fm_trace_context_session_start \
    "$CASE_HOME/config" "$CASE_HOME/state/.trace-context-effective"

  out=$(SPAWN_TRACE_CONTEXT=on run_spawn --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn on an id with a kept merge watch should adopt it: $out"
  assert_contains "$out" "merge watch adopted: $URL" "spawn did not report the adopted watch"
  assert_contains "$out" "spawned $CASE_ID" "spawn did not report success"
  meta="$CASE_HOME/state/$CASE_ID.meta"
  [ "$(grep -c '^pr=' "$meta")" = 1 ] || fail "adopted task meta does not carry exactly one pr="
  grep -qx "pr=$URL" "$meta" || fail "adopted task meta does not record the watched PR"
  grep -q '^traceparent=' "$meta" || fail "enabled spawn did not record its trace carrier"
  [ ! -e "$CASE_HOME/state/$CASE_ID.merge-watch" ] \
    || fail "adopted spawn left the merge-watch record behind"
  fm_pr_poll_artifacts_valid "$CASE_HOME/state" "$CASE_ID" "$POLL" \
    || fail "the armed poll no longer validates under the adopting task"
  [ "$FM_PR_META_URL" = "$URL" ] || fail "the poll is not bound through the new task meta"
  pass "a fresh ship spawn adopts a kept merge watch and keeps its poll armed and bound"
}

test_scout_spawn_refuses_a_kept_merge_watch() {
  local out status
  make_case scout
  seed_kept_watch

  out=$(run_spawn --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn took over an id with a kept merge watch: $out"
  assert_contains "$out" "state/$CASE_ID.merge-watch" "refusal did not name the merge-watch record"
  assert_contains "$out" "$URL" "refusal did not name the watched PR"
  assert_contains "$out" "different task id" "refusal did not name a remedy"
  assert_watch_untouched "the refused scout spawn"
  fm_pr_poll_artifacts_valid "$CASE_HOME/state" "$CASE_ID" "$POLL" \
    || fail "the refused scout spawn damaged the armed poll"
  pass "a scout spawn refuses an id with a kept merge watch and leaves the watch intact"
}

test_ship_spawn_refuses_a_watch_without_a_valid_poll() {
  local out status
  make_case nopoll
  seed_kept_watch no-poll

  out=$(run_spawn --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn adopted a merge watch with no armed poll: $out"
  assert_contains "$out" "bin/fm-pr-check.sh $CASE_ID $URL" \
    "refusal did not name the re-arm remedy"
  assert_watch_untouched "the refused unarmed adoption"
  pass "a ship spawn refuses to adopt a merge watch whose poll is not validly armed"
}

test_ship_spawn_adopts_a_kept_merge_watch
test_scout_spawn_refuses_a_kept_merge_watch
test_ship_spawn_refuses_a_watch_without_a_valid_poll

echo "# all fm-spawn-merge-watch tests passed"

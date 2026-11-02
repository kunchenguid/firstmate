#!/usr/bin/env bash
# Focused remote-home record-export teardown success and fail-closed coverage.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

. "$ROOT/bin/fm-timeout-lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-record-export-remote-home)
TASK='remote-child'

make_remote_home() {  # <name>
  local name=$1 home="$TMP_ROOT/$1/home" project="$TMP_ROOT/$1/project"
  local origin="$TMP_ROOT/$1/origin.git" worktree="$TMP_ROOT/$1/worktree" fakebin
  mkdir -p "$home/config" "$home/data/$TASK" "$home/state/$TASK.inbox/handled"
  touch "$home/state/.last-watcher-beat"
  printf 'manual\n' > "$home/config/backlog-backend"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name")
  fm_fake_exit0 "$fakebin" treehouse tmux gh gh-axi no-mistakes

  git init -q --bare "$origin"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$project-seed" 2>/dev/null
  git -C "$project-seed" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m baseline
  git -C "$project-seed" push -q origin main
  rm -rf "$project-seed"
  git clone -q "$origin" "$project"
  git -C "$project" worktree add -q -b "fm/$TASK" "$worktree" main

  fm_write_meta "$home/state/$TASK.meta" \
    "window=firstmate:fm-$TASK" \
    "endpoint_task_id=$TASK" \
    "worktree=$worktree" \
    "project=$project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=remote-home-generation"
  printf 'done [at=1]: remote child complete\n' > "$home/state/$TASK.status"
  printf 'pending remote-home steer\n' > "$home/state/$TASK.inbox/001.msg"
  printf 'handled remote-home steer\n' > "$home/state/$TASK.inbox/handled/002.msg"
  printf '# Task\n' > "$home/data/$TASK/brief.md"
  printf '%s\n' "$home"
}

run_remote_teardown() {  # <home> <output-prefix>
  local home=$1 output=$2 base
  base=${home%/home}
  FM_HOME="$home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" \
  PATH="$base/fakebin:$PATH" \
    fm_run_timed 30 "$ROOT/bin/fm-teardown.sh" "$TASK" > "$output.out" 2> "$output.err"
}

test_remote_home_teardown_commits_before_deleting() {
  local home export_root archive rc=0
  home=$(make_remote_home success)
  export_root="$TMP_ROOT/success/export"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  run_remote_teardown "$home" "$TMP_ROOT/success/teardown" || rc=$?
  expect_code 0 "$rc" "configured remote-home teardown: $(cat "$TMP_ROOT/success/teardown.err")"
  archive="$export_root/archive/$TASK/remote-home-generation"
  assert_grep 'pending remote-home steer' "$archive/inbox/001.msg" \
    "remote-home teardown lost its pending inbox record"
  assert_grep 'handled remote-home steer' "$archive/inbox/handled/002.msg" \
    "remote-home teardown lost its handled inbox record"
  assert_present "$archive/manifest.v1.json" "remote-home teardown did not commit its archive"
  assert_absent "$home/state/$TASK.meta" "remote-home teardown kept metadata after commit"
  assert_absent "$home/state/$TASK.status" "remote-home teardown kept status after commit"
  assert_absent "$home/state/$TASK.inbox" "remote-home teardown kept inbox after commit"
  pass "configured remote-home teardown commits its archive before deleting live records"
}

test_remote_home_teardown_preserves_sources_when_archive_fails() {
  local home export_root outside rc=0
  home=$(make_remote_home failure)
  export_root="$TMP_ROOT/failure/export"
  outside="$TMP_ROOT/failure/outside"
  mkdir -p "$outside"
  printf 'outside sentinel\n' > "$outside/sentinel"
  ln -s "$outside" "$export_root"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  run_remote_teardown "$home" "$TMP_ROOT/failure/teardown" || rc=$?
  [ "$rc" -ne 0 ] || fail "remote-home teardown ignored an archive publication failure"
  assert_grep 'record export' "$TMP_ROOT/failure/teardown.err" \
    "remote-home teardown did not report the archive failure"
  assert_present "$home/state/$TASK.meta" "failed remote-home export removed metadata"
  assert_present "$home/state/$TASK.status" "failed remote-home export removed status"
  assert_present "$home/state/$TASK.inbox/001.msg" "failed remote-home export removed a pending message"
  assert_present "$home/state/$TASK.inbox/handled/002.msg" "failed remote-home export removed a handled message"
  assert_grep 'outside sentinel' "$outside/sentinel" "failed remote-home export changed the symlink target"
  pass "configured remote-home teardown preserves every source when archive publication fails"
}

test_remote_home_teardown_commits_before_deleting
test_remote_home_teardown_preserves_sources_when_archive_fails

echo "ALL TESTS PASSED"

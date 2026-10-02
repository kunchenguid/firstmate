#!/usr/bin/env bash
# fm-spawn.sh creates the task's steering inbox (state/<id>.inbox and its
# handled/ directory) at launch, before any message exists, for every harness.
#
# A worker's brief tells it to list the inbox and mv handled messages into
# handled/, so an inbox that only appears with the first steer makes that list
# or mv fail on a quiet task. These tests drive the real fm-spawn.sh with the
# shared fake tmux pane and a non-claude harness, whose launch builds no
# --add-dir grant, so the inbox can only exist because spawn made it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-task-inbox)

make_case() {  # <name> <harness> <id>
  local dir="$TMP_ROOT/$1"
  fm_test_spawn_home "$dir/home" "$2"
  fm_git_worktree "$dir/project" "$dir/wt" "wt-$1"
  fm_test_spawn_brief "$dir/home" "$3"
  fm_test_make_spawn_fakebin "$dir/fake" >/dev/null
  printf '%s\n' "$dir"
}

spawn_in() {  # <case-dir> <fm-spawn args...>
  local dir=$1
  shift
  FM_FAKE_LAUNCH_LOG="$dir/launch.log" GROK_HOME="$dir/home/grok-home" \
    fm_test_run_spawn "$dir/home" "$dir/wt" "$dir/fake/fakebin" "$@"
}

test_ship_spawn_creates_an_empty_inbox_before_any_message() {
  local dir id=inbox-ship-z1 out rc inbox
  dir=$(make_case ship codex "$id")
  inbox="$dir/home/state/$id.inbox"
  [ ! -e "$inbox" ] || fail "precondition: the inbox must not exist before spawn"
  out=$(spawn_in "$dir" "$id" "$dir/project" --mode direct-PR --yolo off)
  rc=$?
  expect_code 0 "$rc" "codex ship spawn should succeed"$'\n'"$out"
  [ -d "$inbox" ] || fail "spawn did not create the steering inbox $inbox"
  [ -d "$inbox/handled" ] || fail "spawn did not create the inbox's handled/ directory"
  [ -z "$(find "$inbox" -name '*.msg' -print -quit)" ] \
    || fail "spawn must create an empty inbox, found a message"
  ls "$inbox"/ >/dev/null || fail "listing the fresh inbox failed"
  pass "a ship spawn creates state/<id>.inbox and handled/ empty, before any message"
}

test_scout_spawn_keeps_an_existing_inbox_message() {
  local dir id=inbox-scout-z2 out rc inbox
  dir=$(make_case scout codex "$id")
  inbox="$dir/home/state/$id.inbox"
  mkdir -p "$inbox/handled"
  printf 'kept\n' > "$inbox/001.msg"
  out=$(spawn_in "$dir" "$id" "$dir/project" --scout)
  rc=$?
  expect_code 0 "$rc" "codex scout spawn should succeed"$'\n'"$out"
  [ -d "$inbox/handled" ] || fail "spawn did not keep the inbox's handled/ directory"
  [ "$(cat "$inbox/001.msg")" = kept ] || fail "spawn must not touch a message already in the inbox"
  pass "spawn over an existing inbox is idempotent and keeps its messages"
}

test_ship_spawn_creates_an_empty_inbox_before_any_message
test_scout_spawn_keeps_an_existing_inbox_message

echo "# all fm-spawn-task-inbox tests passed"

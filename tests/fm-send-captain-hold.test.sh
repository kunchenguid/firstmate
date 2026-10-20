#!/usr/bin/env bash
# tests/fm-send-captain-hold.test.sh - fm-send refuses a text steer to a task
# whose backlog item is held for the captain.
#
# Drives the real fm-send and fm-captain-hold executables over a scratch home
# with a real tasks-axi backlog and a stubbed tmux, and pins:
#   1. A held task refuses a text steer: nonzero exit, nothing recorded or
#      typed, and the message names the task, the reason's first line, and the
#      release command.
#   2. A hold whose --until date has passed still refuses.
#   3. --key lifecycle sends to a held task still go through.
#   4. Once the owner releases the hold, the steer is delivered.
#   5. A --resolve-key send that answers the target's own hold is delivered;
#      one that answers some other task's hold does not lift the target's.
#   6. The supervision branch cannot self-answer the target's own hold with
#      --resolve-key, even under the away-posture record.
#   7. A window target that resolves to a held task's meta is refused.
#   8. A backlog that exists but cannot be read refuses.
#   9. An unheld task, and a home with no backlog, steer as before.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

SEND="$ROOT/bin/fm-send.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-captain-hold)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

make_case() { # <name> [with-backlog: 1|0] -> echoes case dir
  local dir="$TMP_ROOT/$1" fb
  fb="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$fb"
  if [ "${2:-1}" = 1 ]; then
    fm_test_tasks_toml "$dir/home/.tasks.toml"
    printf '## In flight\n\n## Queued\n\n## Done\n' >"$dir/home/data/backlog.md"
  fi
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) printf '%s\n' "$*" >>"$FM_SEND_LOG" ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-t1\nwin\n' ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fb/sleep"
  chmod +x "$fb/tmux" "$fb/sleep"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  : >"$dir/send.log"
  printf '%s\n' "$dir"
}

in_home() { # <case-dir> <command...>
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_SEND_LOG="$dir/send.log" FM_SEND_SETTLE=0 "$@"
}

add_task() { # <case-dir> <id>
  (cd "$1/home" && tasks-axi add "$2" "task $2" --start >/dev/null) || fail "could not add task $2"
}

hold_task() { # <case-dir> <id> <reason> [hold args...]
  local dir=$1 id=$2 reason=$3
  shift 3
  in_home "$dir" "$HOLD" hold "$id" --reason "$reason" "$@" >/dev/null 2>&1 || fail "could not hold $id"
}

send() { # <case-dir> <send args...>; stderr to <case-dir>/send.err
  local dir=$1
  shift
  in_home "$dir" "$SEND" "$@" >/dev/null 2>"$dir/send.err"
}

test_held_task_refuses_steer() {
  local dir rc err
  dir=$(make_case held)
  add_task "$dir" t1
  hold_task "$dir" t1 $'Resume only on his word\nsecond line'
  send "$dir" t1 "resume the work"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a steer to a captain-held task should be refused"
  err=$(cat "$dir/send.err")
  assert_contains "$err" "t1" "the refusal should name the task"
  assert_contains "$err" "held for the captain" "the refusal should say the task is held"
  assert_contains "$err" "Resume only on his word" "the refusal should carry the reason's first line"
  case "$err" in *"second line"*) fail "the refusal should carry only the first reason line: $err" ;; esac
  assert_contains "$err" "fm-captain-hold.sh answer t1" "the refusal should name the release command"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a refused steer still wrote an inbox record"
  [ ! -s "$dir/send.log" ] || fail "a refused steer still rang the terminal"
  pass "fm-send captain hold: a held task refuses a text steer and says how to release it"
}

test_expired_hold_still_refuses() {
  local dir rc
  dir=$(make_case expired)
  add_task "$dir" t1
  hold_task "$dir" t1 "Resume only on his word" --until 2020-01-01
  send "$dir" t1 "resume the work"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a hold past its --until date should still refuse"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "an expired-date hold still let the steer record"
  pass "fm-send captain hold: a hold past its --until date still refuses"
}

test_key_send_passes_while_held() {
  local dir
  dir=$(make_case key)
  add_task "$dir" t1
  hold_task "$dir" t1 "Resume only on his word"
  send "$dir" t1 --key Escape || fail "a --key send to a held task should still succeed: $(cat "$dir/send.err")"
  [ -s "$dir/send.log" ] || fail "the --key send never reached the terminal"
  pass "fm-send captain hold: --key lifecycle sends to a held task still go through"
}

test_release_lets_steer_through() {
  local dir words
  dir=$(make_case release)
  add_task "$dir" t1
  hold_task "$dir" t1 "Resume only on his word"
  send "$dir" t1 "resume the work" && fail "the held task accepted a steer"
  words="$dir/owner-words.txt"
  printf 'Resume it.\n' >"$words"
  in_home "$dir" "$HOLD" answer t1 --decision-file "$words" --release >/dev/null 2>&1 ||
    fail "the owner's release failed"
  send "$dir" t1 "resume the work" || fail "a released task should accept a steer: $(cat "$dir/send.err")"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the released steer was not recorded"
  pass "fm-send captain hold: the owner's release lets steering work as before"
}

test_resolve_key_answering_own_hold_passes() {
  local dir other
  dir=$(make_case resolve-own)
  add_task "$dir" t1
  hold_task "$dir" t1 "Pick a design"
  send "$dir" t1 --resolve-key t1 "use design B" ||
    fail "a --resolve-key answer to the target's own hold should be delivered: $(cat "$dir/send.err")"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the answer was not recorded"

  dir=$(make_case resolve-other)
  add_task "$dir" t1
  add_task "$dir" t2
  hold_task "$dir" t1 "Resume only on his word"
  hold_task "$dir" t2 "Pick a design"
  other=$(send "$dir" t1 --resolve-key t2 "use design B" 2>&1; echo "rc=$?")
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "answering another task's hold lifted t1's hold: $other"
  pass "fm-send captain hold: only an answer to the target's own hold is exempt"
}

test_branch_cannot_self_release_with_resolve_key() {
  local dir rc
  dir=$(make_case branch-resolve)
  add_task "$dir" t1
  hold_task "$dir" t1 "Resume only on his word"
  printf '%s\n' 'version: 1' 'entered: 2026-09-20T01:00:00Z' 'entered_epoch: 1789600000' \
    'expected_return: 2026-09-20T09:00:00Z' 'reach_channels: none' \
    'reach_announced: No phone channel is configured; anything that needs you waits for your return.' \
    'spend_max_concurrent_workers: 3' 'merge_grants:' 'confirmed: 2026-09-20T01:00:05Z' \
    'confirmed_epoch: 1789600005' 'words: |-' '  away' 'clauses:' 'refused:' >"$dir/home/state/.afk-contract"
  in_home "$dir" env FM_SUPERVISION_ACTOR=branch "$SEND" t1 --resolve-key t1 "resume" >/dev/null 2>"$dir/send.err"
  rc=$?
  assert_contains "$(cat "$dir/send.err")" "away-posture record" "the away posture should pass the lease gate"
  case "$(cat "$dir/send.err")" in *"answer t1"* | *"--release"*) fail "the branch refusal names the release command: $(cat "$dir/send.err")" ;; esac
  assert_contains "$(cat "$dir/send.err")" "Only the owner can release" "the branch refusal should say the owner must release"
  [ "$rc" -ne 0 ] || fail "the branch self-released a held task with --resolve-key"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "the branch's own-hold --resolve-key still recorded a steer"
  [ ! -s "$dir/send.log" ] || fail "the branch's own-hold --resolve-key still rang the terminal"
  pass "fm-send captain hold: the branch cannot lift a hold with --resolve-key"
}

test_window_target_refuses() {
  local dir
  dir=$(make_case window)
  add_task "$dir" t1
  hold_task "$dir" t1 "Resume only on his word"
  send "$dir" sess:fm-t1 "resume the work" && fail "a window target bypassed the captain hold"
  assert_contains "$(cat "$dir/send.err")" "held for the captain" "the window-target refusal should say the task is held"
  [ ! -s "$dir/send.log" ] || fail "a refused window-target steer still rang the terminal"
  pass "fm-send captain hold: a window target of a held task is refused"
}

test_unreadable_backlog_refuses() {
  local dir
  dir=$(make_case unreadable)
  add_task "$dir" t1
  printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/fakebin/tasks-axi"
  chmod +x "$dir/fakebin/tasks-axi"
  send "$dir" t1 "resume the work" && fail "an unreadable backlog let a steer through"
  assert_contains "$(cat "$dir/send.err")" "cannot be read" "the refusal should name the cause"
  assert_contains "$(cat "$dir/send.err")" "t1" "the refusal should name the task"
  [ ! -s "$dir/send.log" ] || fail "a steer still rang the terminal with an unreadable backlog"
  pass "fm-send captain hold: an unreadable backlog refuses"
}

test_unheld_and_backlogless_homes_steer() {
  local dir
  dir=$(make_case unheld)
  add_task "$dir" t1
  send "$dir" t1 "carry on" || fail "an unheld task should accept a steer: $(cat "$dir/send.err")"
  dir=$(make_case no-backlog 0)
  send "$dir" t1 "carry on" || fail "a home with no backlog should accept a steer: $(cat "$dir/send.err")"
  pass "fm-send captain hold: unheld tasks and backlog-less homes steer as before"
}

test_held_task_refuses_steer
test_expired_hold_still_refuses
test_key_send_passes_while_held
test_release_lets_steer_through
test_resolve_key_answering_own_hold_passes
test_branch_cannot_self_release_with_resolve_key
test_window_target_refuses
test_unreadable_backlog_refuses
test_unheld_and_backlogless_homes_steer

#!/usr/bin/env bash
# tests/fm-supervision-session-end.test.sh - the Claude SessionEnd hook
# (bin/fm-supervision-session-end.sh) through its tracked .claude/settings.json
# registration, with the opt-in config/supervision-host-session-end on and off,
# against the real host and watcher and the shared stub engine.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u
# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

SESSION_END_CMD=$(jq -r '.hooks.SessionEnd[].hooks[].command' "$ROOT/.claude/settings.json")
[ -n "$SESSION_END_CMD" ] || fail "the tracked settings register no SessionEnd hook"
export FM_SUPERVISION_SESSION_END_RESTART_SECONDS=1 FM_CHECK_INTERVAL=1

# A primary checkout whose tracked tree is this repo's, so the hook passes the
# primary-scope check and the host it starts reads the real branch prompt.
SESSION_ROOT="$TMP_ROOT/session-root"
mkdir -p "$SESSION_ROOT"
git init -q "$SESSION_ROOT"
: > "$SESSION_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$SESSION_ROOT/bin"
ln -s "$ROOT/.agents" "$SESSION_ROOT/.agents"

stop_keepers() {
  local home pid
  while IFS= read -r home; do
    pid=$(cut -f1 "$home/state/.supervision-session-end" 2>/dev/null || true)
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done < <(cat "$HOMES_FILE" 2>/dev/null)
  sleep 1
  suite_cleanup
}
trap stop_keepers EXIT

# A registered check that reports once each time the test touches check.go.
register_daily_check() {  # <home>
  cat > "$1/state/daily.check.sh" <<SH
#!/usr/bin/env bash
[ -e '$1/check.go' ] || exit 0
rm -f '$1/check.go'
echo 'daily runs due: daily-runs, held-item, blocked-item - start each per its backlog note'
SH
  chmod 0700 "$1/state/daily.check.sh"
  FM_HOME="$1" "$ROOT/bin/fm-check-register.sh" daily >/dev/null || fail "fixture: could not register the check"
}

# One Claude main session that holds the lock, ends with <reason>, and exits.
end_session() {  # <home> <reason>
  FM_HOME="$1" FM_CREW_STATE_BIN="$1/fakebin/fm-crew-state.sh" PATH="$1/fakebin:$PATH" \
    CLAUDE_PROJECT_DIR="$SESSION_ROOT" FM_ROOT_OVERRIDE="$SESSION_ROOT" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" > "$FM_HOME/ended-session-pid"
      printf "{\"hook_event_name\":\"SessionEnd\",\"reason\":\"%s\",\"session_id\":\"s-end\",\"transcript_path\":\"/tmp/s-end.jsonl\"}" "$1" \
        | bash -c "$0"
    ' "$SESSION_END_CMD" "$2" 2>> "$1/claude.err"
}

keeper_pid() { cut -f1 "$1/state/.supervision-session-end" 2>/dev/null; }
keeper_live() { local pid; pid=$(keeper_pid "$1") && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
keeper_gone() { ! keeper_live "$1" && ! watcher_live "$1"; }
check_handled() {  # <home> <posture>
  grep -Eq "	handled	.*posture=$2.*check: .*daily runs due" "$1/state/.supervision-host.log" 2>/dev/null
}

assert_inert() {  # <home> <label>
  [ ! -e "$1/state/.afk-contract" ] || fail "$2: the session end entered the away posture"
  [ ! -e "$1/state/.supervision-session-end" ] || fail "$2: the session end started a keeper"
  touch "$1/check.go"
  sleep 3
  [ ! -e "$1/state/.supervision-host.log" ] || fail "$2: a host ran after the session ended"
  watcher_live "$1" && fail "$2: a watcher runs after the session ended"
  return 0
}

test_off_leaves_supervision_down() {
  local home
  home=$(make_home session-end-off attended)
  register_daily_check "$home"
  end_session "$home" prompt_input_exit
  assert_inert "$home" "opt-in off"
  pass "without config/supervision-host-session-end a session end leaves supervision as before"
}

test_on_keeps_supervision_after_exit() {
  local home lock
  home=$(make_home session-end-on attended)
  : > "$home/config/supervision-host-session-end"
  register_daily_check "$home"
  end_session "$home" prompt_input_exit
  [ ! -e "$home/state/.afk-contract" ] || fail "the session end wrote an away record"
  wait_until 100 keeper_live "$home" || fail "no keeper runs after the session ended"
  lock=$(cat "$home/ended-session-pid")
  kill -0 "$lock" 2>/dev/null && fail "fixture: the ended session is still alive"
  wait_until 300 watcher_live "$home" || fail "the keeper's host armed no watcher"
  touch "$home/check.go"
  wait_until_deadline 60 check_handled "$home" attended \
    || { cat "$home/state/.supervision-host.log" >&2 2>/dev/null; fail "the check wake was not handled after the session ended"; }
  [ ! -e "$home/state/.afk-contract" ] || fail "the host entered the away posture"
  printf '%s\n' "$$" > "$home/state/.lock"
  wait_until_deadline 30 keeper_gone "$home" || fail "the keeper or its watcher outlived the next session's start"
  pass "with the opt-in a session end keeps an attended host that takes the check wake with no away record, and the next session ends it"
}

test_later_stop_ends_keeper() {
  local home
  home=$(make_home session-end-stop attended)
  : > "$home/config/supervision-host-session-end"
  printf 'epoch=7 owner_pid=1 outcome=rewake\n' > "$home/state/.claude-autoarm-epoch"
  end_session "$home" other
  wait_until 100 keeper_live "$home" || fail "no keeper runs after a hangup ended the session"
  wait_until 300 watcher_live "$home" || fail "the keeper's host armed no watcher"
  printf 'epoch=8 owner_pid=1 outcome=arming\n' > "$home/state/.claude-autoarm-epoch"
  wait_until_deadline 30 keeper_gone "$home" || fail "the keeper outlived the next session's Stop claim"
  [ ! -e "$home/state/.afk-contract" ] || fail "the keeper wrote an away record"
  pass "the next session's Stop claim ends the keeper"
}

test_clear_is_inert() {
  local home
  home=$(make_home session-end-clear attended)
  : > "$home/config/supervision-host-session-end"
  register_daily_check "$home"
  end_session "$home" clear
  assert_inert "$home" "clear"
  pass "/clear, after which the same Claude process keeps its parked host, starts nothing"
}

test_standing_away_record_is_untouched() {
  local home before
  home=$(make_home session-end-afk away)
  : > "$home/config/supervision-host-session-end"
  register_daily_check "$home"
  before=$(cat "$home/state/.afk-contract")
  end_session "$home" prompt_input_exit
  wait_until 100 keeper_live "$home" || fail "no keeper runs after the session ended under /afk"
  wait_until 300 watcher_live "$home" || fail "the keeper's host armed no watcher under /afk"
  touch "$home/check.go"
  wait_until_deadline 60 check_handled "$home" away \
    || { cat "$home/state/.supervision-host.log" >&2 2>/dev/null; fail "the check wake was not handled under the standing /afk record"; }
  [ "$(cat "$home/state/.afk-contract")" = "$before" ] || fail "the session end changed the /afk record"
  pass "a session ending under /afk keeps the record exactly as /afk wrote it and keeps a host running under it"
}

branch_spawn() {  # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$SPAWN_ROOT" FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-spawn.sh" task-new --mode no-mistakes --yolo off 2>&1
}
branch_merge() {  # <home>
  FM_HOME="$1" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-pr-merge.sh" task-x https://github.com/o/r/pull/1 2>&1
}

last_spawn_done() { sed -n '/== other-item/,$p' "$1/engine-spawn.log" 2>/dev/null | grep -q '^rc='; }

test_daily_check_spawns_named_and_refuses_unnamed_held_or_blocked() {
  local home log daily other
  SPAWN_ROOT="$TMP_ROOT/spawn-root-2"
  mkdir -p "$SPAWN_ROOT"
  git init -q -b main "$SPAWN_ROOT"
  git -C "$SPAWN_ROOT" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$SPAWN_ROOT/bin"
  home=$(make_home session-end-daily attended)
  : > "$home/config/supervision-host-session-end"
  printf 'manual\n' > "$home/config/backlog-backend"
  mkdir -p "$home/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  fm_test_tasks_toml "$home/.tasks.toml"
  for id in daily-runs held-item blocked-item other-item blocker; do
    tasks-axi add "$id" "item $id" --kind ship --file "$home/data/backlog.md" >/dev/null || fail "fixture: could not add $id"
  done
  tasks-axi hold held-item --reason "captain decision pending" --kind captain --file "$home/data/backlog.md" >/dev/null || fail "fixture: could not hold"
  tasks-axi block blocked-item --by blocker --file "$home/data/backlog.md" >/dev/null || fail "fixture: could not block"
  printf '%s\n' daily-runs held-item blocked-item other-item > "$home/stub-spawn-ids"
  echo spawn > "$home/stub-mode"
  register_daily_check "$home"
  end_session "$home" prompt_input_exit
  wait_until 100 keeper_live "$home" || fail "no keeper runs after the session ended"
  wait_until 300 watcher_live "$home" || fail "the keeper's host armed no watcher"
  touch "$home/check.go"
  wait_until_deadline 60 test -s "$home/engine-spawn.log" || fail "the session-end engine ran no spawn"
  wait_until_deadline 60 last_spawn_done "$home" || fail "the engine did not finish its last spawn"
  log=$(cat "$home/engine-spawn.log")
  daily=$(printf '%s\n' "$log" | sed -n '/== daily-runs/,/== held-item/p')
  assert_contains "$daily" "names task daily-runs" "the named daily-runs item did not pass the session-end allowance"
  assert_not_contains "$daily" "refused" "the queued daily-runs item was refused"
  assert_not_contains "$daily" "rc=6" "the role partition refused the queued daily-runs item"
  assert_contains "$(printf '%s\n' "$log" | sed -n '/== held-item/,/== blocked-item/p')" "never a held item" "a held item was dispatched"
  assert_contains "$(printf '%s\n' "$log" | sed -n '/== blocked-item/,/== other-item/p')" "never a held item" "a blocked item was dispatched"
  other=$(printf '%s\n' "$log" | sed -n '/== other-item/,$p')
  assert_contains "$other" "task other-item is not named" "a queued item the check row does not name passed the session-end allowance"
  assert_contains "$other" "rc=6" "a queued item the check row does not name was not refused by the role partition"
  pass "the daily-runs check through the session-end host spawns the queued item it names and refuses an unnamed queued item and a held or blocked one"
}

engine_calls() { find "$1" -maxdepth 1 -name 'engine-call.*' 2>/dev/null | wc -l | tr -d ' '; }
latched() { grep -q '	latch	' "$1/state/.supervision-host.log" 2>/dev/null; }

test_failing_engine_latches_the_window() {
  local home calls
  home=$(make_home session-end-latch attended)
  : > "$home/config/supervision-host-session-end"
  register_daily_check "$home"
  echo fail > "$home/stub-mode"
  end_session "$home" prompt_input_exit
  wait_until 100 keeper_live "$home" || fail "no keeper runs after the session ended"
  wait_until 300 watcher_live "$home" || fail "the keeper's host armed no watcher"
  local i=0
  while ! latched "$home" && [ "$i" -lt 60 ]; do
    [ -e "$home/check.go" ] || touch "$home/check.go"
    sleep 1
    i=$((i + 1))
  done
  latched "$home" || { cat "$home/state/.supervision-host.log" >&2 2>/dev/null; fail "two engine errors did not latch the session-end window"; }
  calls=$(engine_calls "$home")
  touch "$home/check.go"
  sleep 8
  [ "$(engine_calls "$home")" = "$calls" ] || fail "an engine turn started inside the cooldown"
  grep -q 'cooling down after engine errors' "$home/state/.supervision-host.log" || fail "the cooling wake was not passed through"
  pass "repeated engine errors latch the session-end window and no turn starts inside the cooldown"
}

test_session_end_refuses_unnamed_spawn() {
  local home out status
  SPAWN_ROOT="$TMP_ROOT/spawn-root"
  mkdir -p "$SPAWN_ROOT"
  git init -q -b main "$SPAWN_ROOT"
  git -C "$SPAWN_ROOT" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$SPAWN_ROOT/bin"
  home=$(make_home session-end-spawn attended)
  : > "$home/config/supervision-host-session-end"
  register_daily_check "$home"
  out=$(branch_spawn "$home"); status=$?
  [ "$status" -eq 6 ] || fail "before the session ended the branch spawn exited $status, not 6: $out"
  end_session "$home" prompt_input_exit
  wait_until 100 keeper_live "$home" || fail "no keeper runs after the session ended"
  out=$(branch_spawn "$home"); status=$?
  [ "$status" -eq 6 ] || fail "a branch spawn no check row names exited $status, not 6, with a live keeper: $out"
  assert_contains "$out" "task task-new is not named" "the spawn outside a check-row turn was not refused by the session-end allowance"
  out=$(branch_merge "$home"); status=$?
  [ "$status" -eq 6 ] || fail "the branch merge exited $status, not 6, with a live keeper: $out"
  printf '%s\n' "$$" > "$home/state/.lock"
  wait_until_deadline 30 keeper_gone "$home" || fail "the keeper outlived the next session's start"
  out=$(branch_spawn "$home"); status=$?
  [ "$status" -eq 6 ] || fail "after the keeper ended the branch spawn exited $status, not 6: $out"
  pass "a live session-end keeper admits no branch spawn that a check row does not name, never a merge, and ends with the keeper"
}

fm_test_run \
  test_off_leaves_supervision_down \
  test_on_keeps_supervision_after_exit \
  test_later_stop_ends_keeper \
  test_clear_is_inert \
  test_standing_away_record_is_untouched \
  test_session_end_refuses_unnamed_spawn \
  test_daily_check_spawns_named_and_refuses_unnamed_held_or_blocked \
  test_failing_engine_latches_the_window

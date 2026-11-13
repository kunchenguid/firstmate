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
echo 'daily runs due - start each per its backlog note'
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

fm_test_run \
  test_off_leaves_supervision_down \
  test_on_keeps_supervision_after_exit \
  test_later_stop_ends_keeper \
  test_clear_is_inert \
  test_standing_away_record_is_untouched

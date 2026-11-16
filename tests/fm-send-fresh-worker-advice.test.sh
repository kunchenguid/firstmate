#!/usr/bin/env bash
# tests/fm-send-fresh-worker-advice.test.sh - a steer to a worker whose
# conversation is already very long tells firstmate that a fresh worker is
# cheaper, without changing the steer.
#
# Drives the real fm-send executable over a stubbed tmux. The worker's session
# is a synthetic Claude Code transcript or Codex rollout at the path each tool
# keeps it (bin/fm-session-size-lib.sh owns those paths), under a throwaway
# HOME. Pins: no advice without config/context-ceiling; advice at the advise
# lines from either tool; the steer is recorded and exits 0 either way; a
# secondmate, an off line, or an unreadable session prints nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-fresh-worker-advice)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

make_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-t1\nwin\n'; exit 0 ;;
  send-keys) printf 'ring\n' >>"$ORDER_LOG" ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fb/sleep"
  # Record every read of a session store, then run the real tool.
  cat >"$fb/find" <<'SH'
#!/usr/bin/env bash
case "$*" in *.codex/sessions*) printf 'session-read find\n' >>"$ORDER_LOG" ;; esac
exec /usr/bin/find "$@"
SH
  cat >"$fb/ls" <<'SH'
#!/usr/bin/env bash
case "$*" in *.claude/projects*) printf 'session-read ls\n' >>"$ORDER_LOG" ;; esac
exec /bin/ls "$@"
SH
  chmod +x "$fb/tmux" "$fb/sleep" "$fb/find" "$fb/ls"
}

setup_case() {  # <name> <harness> <kind>
  CASE="$TMP_ROOT/$1"
  WT="$CASE/wt"
  USER_HOME="$CASE/user-home"
  mkdir -p "$CASE/home/state" "$CASE/home/config" "$WT" "$USER_HOME"
  make_stubs "$CASE"
  fm_write_meta "$CASE/home/state/t1.meta" "window=sess:fm-t1" "kind=$3" "harness=$2" "worktree=$WT"
}

# A Claude Code transcript with <calls> responses, each split across two lines
# the way Claude Code writes them, the last reading <context> tokens.
write_claude_session() {  # <calls> <context>
  local dir i
  dir="$USER_HOME/.claude/projects/$(printf '%s' "$WT" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  for i in $(seq 1 "$1"); do
    printf '{"type":"assistant","message":{"id":"msg_%s","usage":{"input_tokens":1,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$i" "$(($2 - 1))"
    printf '{"type":"assistant","message":{"id":"msg_%s","usage":{"input_tokens":1,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$i" "$(($2 - 1))"
  done >"$dir/0b1c-session.jsonl"
}

write_codex_session() {  # <calls> <context>
  local dir="$USER_HOME/.codex/sessions/2030/01/01" i
  mkdir -p "$dir"
  {
    printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$WT"
    for i in $(seq 1 "$1"); do
      printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s}}}}\n' "$2"
    done
    printf '{"type":"event_msg","payload":{"type":"token_count","info":null}}\n'
  } >"$dir/rollout-2030-01-01T00-00-00-x.jsonl"
}

send() {  # -> sets ERR to stderr, returns fm-send's status
  ERR="$CASE/send.err"
  : >"$CASE/order.log"
  env PATH="$CASE/fakebin:$PATH" HOME="$USER_HOME" CLAUDE_CONFIG_DIR= CODEX_HOME= ORDER_LOG="$CASE/order.log" \
    FM_ROOT_OVERRIDE="$CASE/home" FM_HOME="$CASE/home" FM_SEND_SETTLE=0 \
    "$SEND" t1 "start the next piece of work" >/dev/null 2>"$ERR"
}

assert_recorded() {  # <label>
  [ -f "$CASE/home/state/t1.inbox/001.msg" ] || fail "$1: the steer was not durably recorded"
}

test_no_setting_no_advice() {
  setup_case no-setting claude ship
  write_claude_session 400 120000
  send
  expect_code 0 "$?" "the steer exits 0"
  assert_recorded "no setting"
  assert_not_contains "$(cat "$ERR")" 'advice:' "without config/context-ceiling there is no advice"
  pass "a home without config/context-ceiling never advises"
}

test_claude_calls_advice() {
  setup_case claude-calls claude ship
  : >"$CASE/home/config/context-ceiling"
  write_claude_session 300 120000
  send
  expect_code 0 "$?" "an advised steer still exits 0"
  assert_recorded "claude calls"
  assert_contains "$(cat "$ERR")" "advice: t1's conversation is already 300 model calls (advise-calls=300)" \
    "a 300-call Claude session reaches the default advise line, counting split responses once"
  setup_case claude-short claude ship
  : >"$CASE/home/config/context-ceiling"
  write_claude_session 299 120000
  send
  assert_not_contains "$(cat "$ERR")" 'advice:' "a 299-call session below both lines gets no advice"
  pass "a Claude worker at the call line is advised; one below it is not"
}

test_codex_context_advice() {
  setup_case codex-ctx codex scout
  printf 'advise-tokens=150000\n' >"$CASE/home/config/context-ceiling"
  write_codex_session 12 160000
  send
  expect_code 0 "$?" "an advised codex steer still exits 0"
  assert_recorded "codex context"
  assert_contains "$(cat "$ERR")" "advice: t1's conversation is already 160000 context tokens (advise-tokens=150000)" \
    "a Codex scout past the context line is advised"
  pass "a Codex scout past the context line is advised"
}

test_quiet_cases() {
  setup_case secondmate claude secondmate
  : >"$CASE/home/config/context-ceiling"
  write_claude_session 500 300000
  send
  assert_not_contains "$(cat "$ERR")" 'advice:' "a secondmate is a persistent home and never advised"
  setup_case off claude ship
  printf 'advise-calls=off\nadvise-tokens=off\n' >"$CASE/home/config/context-ceiling"
  write_claude_session 500 300000
  send
  assert_not_contains "$(cat "$ERR")" 'advice:' "off lines disable the advice"
  setup_case no-session claude ship
  : >"$CASE/home/config/context-ceiling"
  send
  expect_code 0 "$?" "a worker with no readable session still gets its steer"
  assert_recorded "no session"
  assert_not_contains "$(cat "$ERR")" 'advice:' "an unreadable session prints nothing"
  setup_case bad-setting claude ship
  printf 'advise-calls=lots\n' >"$CASE/home/config/context-ceiling"
  write_claude_session 500 300000
  send
  expect_code 0 "$?" "an unreadable setting never blocks a steer"
  assert_not_contains "$(cat "$ERR")" 'advice:' "an unreadable setting prints no advice"
  pass "secondmates, off lines, missing sessions, and unreadable settings stay silent and never block"
}

# The Codex lookup reads the first line of each recent rollout, so its cost
# grows with the machine's session count; time it at fleet sizes.
test_scale_codex_lookup() {
  local n i dir start ms
  for n in 5 100 1000; do
    setup_case "scale-$n" codex ship
    : >"$CASE/home/config/context-ceiling"
    dir="$USER_HOME/.codex/sessions/2030/01/02"
    mkdir -p "$dir"
    for i in $(seq 1 "$n"); do
      printf '{"type":"session_meta","payload":{"cwd":"/elsewhere/wt-%s"}}\n{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":9}}}}\n' "$i" >"$dir/rollout-other-$i.jsonl"
    done
    write_codex_session 300 1000
    start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    send
    ms=$(( $(perl -MTime::HiRes=time -e 'printf "%d", time*1000') - start ))
    assert_recorded "scale $n"
    assert_contains "$(cat "$ERR")" "300 model calls" "the worker's own session is found among $n others"
    printf '# scale: %s other rollouts -> steer with advice in %s ms\n' "$n" "$ms"
  done
  pass "the advice finds the worker's Codex session among 5, 100 and 1000 others (timings above)"
}

# The reviewer's case: an absent or switched-off setting reads no session at
# all, and when advice is on it runs only after the doorbell.
test_no_session_read_unless_on_and_after_the_ring() {
  local harness
  for harness in codex claude; do
    setup_case "absent-$harness" "$harness" ship
    write_codex_session 300 1000
    write_claude_session 300 120000
    send
    assert_recorded "absent $harness"
    assert_grep ring "$CASE/order.log" "the steer still rings"
    assert_no_grep session-read "$CASE/order.log" "without config/context-ceiling a $harness steer reads no session"
    setup_case "off-$harness" "$harness" ship
    printf 'advise-calls=off\nadvise-tokens=off\n' >"$CASE/home/config/context-ceiling"
    write_codex_session 300 1000
    write_claude_session 300 120000
    send
    assert_no_grep session-read "$CASE/order.log" "with both advice lines off a $harness steer reads no session"
    setup_case "on-$harness" "$harness" ship
    : >"$CASE/home/config/context-ceiling"
    write_codex_session 300 1000
    write_claude_session 300 120000
    send
    assert_contains "$(cat "$ERR")" "300 model calls" "$harness advice still fires when on"
    assert_equals ring "$(head -n 1 "$CASE/order.log")" "the doorbell comes before any $harness session read"
    assert_grep session-read "$CASE/order.log" "advice that is on reads the $harness session"
  done
  pass "an absent or switched-off setting reads no session, and advice that is on runs after the doorbell"
}

test_no_setting_no_advice
test_claude_calls_advice
test_codex_context_advice
test_quiet_cases
test_scale_codex_lookup
test_no_session_read_unless_on_and_after_the_ring

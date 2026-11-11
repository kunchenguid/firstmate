#!/usr/bin/env bash
# Behavior tests for the opt-in Claude Stop hook that asks a primary to /stow.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-stow-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-stow-guard)
PRIMARY="$TMP_ROOT/primary"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$PRIMARY/state"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" config user.name fixture
git -C "$PRIMARY" config user.email fixture@example.test
git -C "$PRIMARY" config commit.gpgsign false

# invoke_guard <root> <state> <config> [env assignments...]
# The hook payload is on stdin. Prints nothing. The exit status is the hook's.
invoke_guard() {
  local root=$1 state=$2 config=$3
  shift 3
  : > "$OUT"
  : > "$ERR"
  env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    "$@" \
    "$GUARD" >"$OUT" 2>"$ERR"
}

prepare_case() {
  CASE_STATE="$TMP_ROOT/cases/$1/state"
  CASE_CONFIG="$TMP_ROOT/cases/$1/config"
  CASE_TRANSCRIPT="$TMP_ROOT/cases/$1/transcript.jsonl"
  mkdir -p "$CASE_STATE" "$CASE_CONFIG"
  : > "$CASE_TRANSCRIPT"
}

payload() {
  local active=${1:-false}
  printf '{"session_id":"s1","stop_hook_active":%s,"transcript_path":"%s"}\n' \
    "$active" "$CASE_TRANSCRIPT"
}

write_usage() {
  jq -nc --argjson tokens "$1" \
    '{message:{usage:{input_tokens:$tokens,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    >> "$CASE_TRANSCRIPT"
}

assert_silent() {
  local label=$1
  [ ! -s "$OUT" ] || fail "$label wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

assert_block() {
  local label=$1 needle=$2
  jq -e --arg needle "$needle" \
    '.decision == "block" and (.reason | contains($needle))' "$OUT" >/dev/null 2>&1 \
    || fail "$label did not block with '$needle': $(cat "$OUT") $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

test_absent_config_is_silent() {
  local rc=0
  prepare_case absent
  write_usage 900000
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "absent config must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "absent config"
  [ ! -e "$CASE_STATE/.stow-guard.json" ] || fail "absent config wrote trigger state"
  pass "absent config/stow-guard leaves the stop unchanged and writes no state"
}

test_context_crossing_blocks_once_until_rearm() {
  local rc=0
  prepare_case context
  printf '%s\n' '# note' 'tokens=nope' 'tokens=0' 'tokens=1000' > "$CASE_CONFIG/stow-guard"
  write_usage 100
  write_usage 1000
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "context crossing must exit 0, got $rc"
  assert_block "context crossing" "context is 1000 tokens"
  jq -e '.fired.s1 == true and (.last_stow | not)' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "context crossing did not record the session as asked: $(cat "$CASE_STATE/.stow-guard.json")"

  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "second crossing must exit 0, got $rc"
  assert_silent "second crossing of the same context"

  : > "$CASE_TRANSCRIPT"
  write_usage 100
  rc=0
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "continuation re-arm must exit 0, got $rc"
  assert_silent "continuation below two-thirds"
  jq -e '.fired | has("s1") | not' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "continuation below two-thirds left the session armed: $(cat "$CASE_STATE/.stow-guard.json")"

  : > "$CASE_TRANSCRIPT"
  write_usage 1000
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "re-armed crossing must exit 0, got $rc"
  assert_block "re-armed crossing" "context is 1000 tokens"
  pass "a context crossing blocks once, a continuation below two-thirds re-arms, and the next crossing blocks"
}

test_continuation_stop_blocks_once_per_crossing() {
  local rc=0
  prepare_case continuation
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  write_usage 1200
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "continuation crossing must exit 0, got $rc"
  assert_block "continuation crossing" "context is 1200 tokens"

  write_usage 1300
  rc=0
  payload true | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "second continuation above the line must exit 0, got $rc"
  assert_silent "second continuation above the line"
  pass "a continuation stop at the token line blocks once and the next continuation above it does not"
}

test_age_interval_blocks_once_per_hour() {
  local rc=0 now=1700000000 later soon again
  prepare_case age
  : > "$CASE_CONFIG/stow-guard"
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "first opt-in stop must exit 0, got $rc"
  assert_silent "first opt-in stop"
  jq -e --argjson now "$now" '.last_stow == $now and .asked == 0' \
    "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "first opt-in stop did not start the age clock: $(cat "$CASE_STATE/.stow-guard.json")"

  later=$((now + 86400))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$later" || rc=$?
  [ "$rc" -eq 0 ] || fail "age ask must exit 0, got $rc"
  assert_block "age ask" "older than 24h"

  soon=$((later + 10))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$soon" || rc=$?
  [ "$rc" -eq 0 ] || fail "age cooldown must exit 0, got $rc"
  assert_silent "age ask inside the hour cooldown"

  again=$((later + 3600))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$again" || rc=$?
  [ "$rc" -eq 0 ] || fail "age ask after the cooldown must exit 0, got $rc"
  assert_block "age ask after the cooldown" "older than 24h"
  pass "the age ask starts the clock, blocks once a day, and waits an hour before asking again"
}

test_recorded_stow_sets_the_age_clock() {
  local rc=0 epoch now
  command -v python3 >/dev/null 2>&1 || {
    pass "recorded /stow sets the age clock (skipped, python3 not found)"
    return
  }
  prepare_case stow
  : > "$CASE_CONFIG/stow-guard"
  epoch=$(python3 -c 'import datetime; print(int(datetime.datetime.fromisoformat("2026-01-01T00:00:00+00:00").timestamp()))')
  jq -nc \
    '{timestamp:"2026-01-01T00:00:00Z",message:{content:[{type:"tool_use",name:"Skill",input:{skill:"stow"}}],usage:{input_tokens:10,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    > "$CASE_TRANSCRIPT"
  now=$((epoch + 100))
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "recent /stow stop must exit 0, got $rc"
  assert_silent "recent /stow"
  jq -e --argjson epoch "$epoch" '.last_stow == $epoch' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "recent /stow was not recorded: $(cat "$CASE_STATE/.stow-guard.json")"

  : > "$CASE_TRANSCRIPT"
  now=$((epoch + 200))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "tail without the /stow must exit 0, got $rc"
  assert_silent "tail that no longer contains the /stow"
  jq -e --argjson epoch "$epoch" '.last_stow == $epoch' "$CASE_STATE/.stow-guard.json" >/dev/null \
    || fail "a later tail rewound the /stow clock: $(cat "$CASE_STATE/.stow-guard.json")"

  now=$((epoch + 86400 + 100))
  rc=0
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" || rc=$?
  [ "$rc" -eq 0 ] || fail "aged remembered /stow must exit 0, got $rc"
  assert_block "aged remembered /stow" "older than 24h"
  pass "a Skill /stow sets the age clock and a later tail does not rewind it"
}

test_crew_worktree_is_silent() {
  local child="$TMP_ROOT/child" rc=0
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  prepare_case crew
  mkdir -p "$child/bin" "$child/state" "$child/config"
  printf 'tokens=1000\n' > "$child/config/stow-guard"
  write_usage 900000
  payload | invoke_guard "$child" "$child/state" "$child/config" || rc=$?
  [ "$rc" -eq 0 ] || fail "a crew worktree must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "crew worktree"
  [ ! -e "$child/state/.stow-guard.json" ] || fail "a crew worktree wrote trigger state"
  pass "a linked crew worktree stays silent even when the opt-in file and a high reading are present"
}

test_secondmate_home_is_silent() {
  local second="$TMP_ROOT/second" rc=0
  if ! git -C "$PRIMARY" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$PRIMARY" add AGENTS.md
    git -C "$PRIMARY" commit -qm fixture
  fi
  git -C "$PRIMARY" worktree add -q -b fixture-second "$second"
  mkdir -p "$second/bin" "$second/state" "$second/config"
  printf '# fixture\n' > "$second/AGENTS.md"
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  printf 'tokens=1000\n' > "$second/config/stow-guard"
  prepare_case secondmate
  write_usage 900000
  payload | invoke_guard "$second" "$second/state" "$second/config" || rc=$?
  [ "$rc" -eq 0 ] || fail "a secondmate home must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "secondmate home"
  [ ! -e "$second/state/.stow-guard.json" ] || fail "a secondmate home wrote trigger state"
  pass "a marked secondmate home stays silent even when the opt-in file and a high reading are present"
}

test_missing_python_skips_the_age_ask() {
  local rc=0 fakebin="$TMP_ROOT/no-python-bin" tool bin epoch now
  command -v python3 >/dev/null 2>&1 || {
    pass "missing python3 skips the age ask (skipped, python3 not found)"
    return
  }
  prepare_case nopython
  : > "$CASE_CONFIG/stow-guard"
  epoch=$(python3 -c 'import datetime; print(int(datetime.datetime.fromisoformat("2026-01-01T00:00:00+00:00").timestamp()))')
  jq -nc \
    '{timestamp:"2026-01-01T00:00:00Z",message:{content:[{type:"tool_use",name:"Skill",input:{skill:"stow"}}],usage:{input_tokens:10,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    > "$CASE_TRANSCRIPT"
  jq -n --argjson last_stow "$((epoch - 100000))" --argjson asked 0 --argjson fired '{}' \
    '{last_stow:$last_stow, asked:$asked, fired:$fired}' > "$CASE_STATE/.stow-guard.json"
  mkdir -p "$fakebin"
  for tool in bash cat dirname tail awk git jq date mktemp mv rm; do
    bin=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$bin" ] || fail "test needs $tool on PATH"
    ln -sf "$bin" "$fakebin/$tool"
  done
  PATH="$fakebin" command -v python3 >/dev/null 2>&1 && fail "fixture PATH still finds python3"
  now=$((epoch + 100))
  payload | env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT PATH="$fakebin" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing python3 age stop must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "missing python3 with a recent /stow and a stale clock"

  : > "$CASE_TRANSCRIPT"
  write_usage 400000
  rc=0
  payload | env -u GROK_AGENT -u GROK_HOOK_EVENT -u GROK_HOOK_NAME -u GROK_SESSION_ID \
    -u GROK_WORKSPACE_ROOT PATH="$fakebin" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    FM_STOW_GUARD_NOW="$now" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing python3 context stop must exit 0, got $rc: $(cat "$ERR")"
  assert_block "missing python3 context crossing" "context is 400000 tokens"
  pass "missing python3 skips the age ask and still asks on a context crossing"
}

test_bad_payloads_and_missing_jq_are_silent() {
  local rc=0 fakebin="$TMP_ROOT/no-jq-bin" entry name
  prepare_case bad
  printf 'tokens=1000\n' > "$CASE_CONFIG/stow-guard"
  write_usage 900000

  printf '%s' '{' | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "bad json must exit 0, got $rc"
  assert_silent "bad json"

  rc=0
  printf '%s' '' | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "empty payload must exit 0, got $rc"
  assert_silent "empty payload"

  rc=0
  printf '%s\n' '{"cursor_version":"1.0.0","session_id":"s1","transcript_path":"'"$CASE_TRANSCRIPT"'"}' \
    | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "cursor payload must exit 0, got $rc"
  assert_silent "cursor payload"

  rc=0
  payload | env -u GROK_HOOK_EVENT GROK_AGENT=1 \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "grok environment must exit 0, got $rc"
  assert_silent "grok environment"
  [ ! -e "$CASE_STATE/.stow-guard.json" ] || fail "a refused payload wrote trigger state"

  mkdir -p "$fakebin"
  for entry in /bin/* /usr/bin/*; do
    [ -x "$entry" ] || continue
    name=${entry##*/}
    [ "$name" = jq ] && continue
    ln -s "$entry" "$fakebin/$name" 2>/dev/null || true
  done
  rm -f "$fakebin/jq"
  PATH="$fakebin" command -v dirname >/dev/null 2>&1 || fail "fixture PATH lost dirname"
  PATH="$fakebin" command -v jq >/dev/null 2>&1 && fail "fixture PATH still finds jq"
  rc=0
  payload | env -u GROK_AGENT -u GROK_HOOK_EVENT PATH="$fakebin" \
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_CONFIG_OVERRIDE="$CASE_CONFIG" \
    "$GUARD" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "missing jq"
  [ ! -e "$CASE_STATE/.stow-guard.json" ] || fail "missing jq wrote trigger state"
  pass "bad json, an empty payload, a cursor payload, grok, and a missing jq all stay silent"
}

test_overlong_token_line_keeps_the_default() {
  local rc=0
  prepare_case overlong
  printf 'tokens=999999999999\n' > "$CASE_CONFIG/stow-guard"
  write_usage 300000
  payload | invoke_guard "$PRIMARY" "$CASE_STATE" "$CASE_CONFIG" || rc=$?
  [ "$rc" -eq 0 ] || fail "over-long token line must exit 0, got $rc: $(cat "$ERR")"
  assert_block "over-long token line" "context is 300000 tokens"
  pass "a token line past integer range keeps the 300000 default and still asks"
}

test_tracked_stop_hook_is_synchronous_and_grok_inert() {
  local matches
  matches=$(jq -e '
    [.hooks.Stop[0].hooks[]
      | select(.command | contains("/bin/fm-stow-guard.sh"))
      | select(.timeout == 10)
      | select(.asyncRewake | not)
      | select(.command | contains("${GROK_AGENT:-}${GROK_HOOK_EVENT:-}"))]
    | length' "$ROOT/.claude/settings.json") \
    || fail "tracked Stop hooks could not be read"
  [ "$matches" -eq 1 ] || fail "expected one synchronous grok-inert Stop hook for fm-stow-guard.sh, saw $matches"
  pass "tracked Claude Stop settings run fm-stow-guard.sh once, synchronously, and inert under grok"
}

fm_test_run \
  test_absent_config_is_silent \
  test_context_crossing_blocks_once_until_rearm \
  test_continuation_stop_blocks_once_per_crossing \
  test_age_interval_blocks_once_per_hour \
  test_recorded_stow_sets_the_age_clock \
  test_crew_worktree_is_silent \
  test_secondmate_home_is_silent \
  test_missing_python_skips_the_age_ask \
  test_bad_payloads_and_missing_jq_are_silent \
  test_overlong_token_line_keeps_the_default \
  test_tracked_stop_hook_is_synchronous_and_grok_inert

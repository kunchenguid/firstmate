#!/usr/bin/env bash
# Behavior coverage for Claude turn-boundary context detection, durable crossing
# deduplication, reset-safe handoff, and the automatic primary relaunch wrapper.
# shellcheck disable=SC2016 # Single-quoted fake-harness bodies expand inside their child shells.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-restart)
HOOK="$ROOT/bin/fm-context-restart-claude-hook.sh"
HANDOFF="$ROOT/bin/fm-context-restart.sh"
WRAPPER="$ROOT/bin/fm-primary.sh"
LIB="$ROOT/bin/fm-context-restart-lib.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE HOOK HANDOFF WRAPPER LIB

make_primary() {
  local dir=$1 budget=${2:-100}
  mkdir -p "$dir/state" "$dir/config" "$dir/bin"
  git init -q "$dir"
  git -C "$dir" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  printf '%s\n' "$budget" > "$dir/config/context-restart-budget"
}

write_transcript() {  # <path> <input> <created> <read> <output>
  cat > "$1" <<JSON
{"type":"user","message":{"role":"user","content":"fixture"}}
{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":$2,"cache_creation_input_tokens":$3,"cache_read_input_tokens":$4,"output_tokens":$5}}}
{"type":"last-prompt","sessionId":"fixture"}
JSON
}

run_hook() {  # <home> <session> <transcript>
  local home=$1 session=$2 transcript=$3 rc=0
  printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}\n' \
    "$session" "$transcript" \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$HOOK"
      ' 2>&1 || rc=$?
  return "$rc"
}

record_phase() {
  FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1"
    fm_context_restart_record_read "$2" >/dev/null || exit 1
    printf "%s\n" "$FM_CONTEXT_RESTART_RECORD_PHASE"
  ' _ "$LIB" "$1/state/.context-restart-crossing"
}

test_budget_parser_and_default() {
  local config outside out rc
  config="$TMP_ROOT/config-parser"
  mkdir -p "$config"
  FM_CONFIG="$config" bash -c '
    . "$1"
    fm_context_restart_budget_materialize "$FM_CONFIG"
    fm_context_restart_budget_read "$FM_CONFIG"
  ' _ "$LIB" > "$TMP_ROOT/default.out" || fail "could not materialize the context-restart default"
  [ "$(cat "$TMP_ROOT/default.out")" = 400000 ] || fail "visible context-restart default is not 400000"
  [ "$(cat "$config/context-restart-budget")" = 400000 ] || fail "default was not published as a visible config file"

  printf '0042\n' > "$config/context-restart-budget"
  rc=0
  out=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$config" "$HANDOFF" read-budget 2>&1) || rc=$?
  expect_code 1 "$rc" "a leading-zero context budget must be rejected"
  assert_contains "$out" 'value must be one positive decimal integer' \
    "malformed context budget did not report its exact format error"

  outside="$TMP_ROOT/outside-budget"
  printf '50\n' > "$outside"
  rm -f "$config/context-restart-budget"
  ln -s "$outside" "$config/context-restart-budget"
  rc=0
  out=$(FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$config" "$HANDOFF" read-budget 2>&1) || rc=$?
  expect_code 1 "$rc" "a symlinked context budget must be rejected"
  assert_contains "$out" 'file is symlinked' "symlink rejection was not specific"
  [ "$(cat "$outside")" = 50 ] || fail "symlink rejection changed the external target"
  pass "context restart: visible 400000 default and exact safe budget validation"
}

test_threshold_and_one_directive_per_crossing() {
  local home transcript out rc
  home="$TMP_ROOT/threshold"
  transcript="$home/transcript.jsonl"
  make_primary "$home" 100

  write_transcript "$transcript" 20 20 20 20
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "under-threshold Stop should remain inert"
  [ -z "$out" ] || fail "under-threshold Stop emitted output: $out"
  [ ! -e "$home/state/.context-restart-crossing" ] || fail "under-threshold Stop published a crossing"

  write_transcript "$transcript" 30 30 30 10
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 2 "$rc" "the first threshold crossing must force one Claude continuation"
  assert_contains "$out" $'\u2063FIRSTMATE_OP: v1 context-refresh:' \
    "threshold crossing did not emit a typed context-refresh directive"
  assert_contains "$out" 'invoke /stow' "threshold directive did not require the stow handoff"
  [ "$(record_phase "$home")" = detected ] || fail "threshold crossing was not durably detected"

  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "a repeated above-threshold Stop must not nag"
  [ -z "$out" ] || fail "a repeated above-threshold Stop duplicated the directive: $out"

  write_transcript "$transcript" 20 20 20 20
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "dropping below threshold should rearm silently"
  [ -z "$out" ] || fail "below-threshold rearm emitted output: $out"
  [ ! -e "$home/state/.context-restart-crossing" ] || fail "below-threshold rearm retained the detected crossing"

  write_transcript "$transcript" 40 30 20 10
  rc=0
  out=$(run_hook "$home" threshold-session "$transcript" 2>/dev/null) || rc=$?
  expect_code 2 "$rc" "a later genuine crossing should emit one new directive"
  [ "$(printf '%s\n' "$out" | grep -c 'FIRSTMATE_OP: v1 context-refresh:')" -eq 1 ] \
    || fail "the later crossing did not emit exactly one directive: $out"
  pass "context restart: turn-boundary threshold emits exactly one directive per crossing"
}

test_malformed_transcript_and_usage_are_inert() {
  local home transcript out rc case_name
  for case_name in malformed-json missing-assistant bad-usage negative-usage; do
    home="$TMP_ROOT/$case_name"
    transcript="$home/transcript.jsonl"
    make_primary "$home" 10
    case "$case_name" in
      malformed-json)
        printf '%s\n' '{not json' > "$transcript"
        ;;
      missing-assistant)
        printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "$transcript"
        ;;
      bad-usage)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":"100","output_tokens":1}}}' > "$transcript"
        ;;
      negative-usage)
        printf '%s\n' '{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":100,"cache_read_input_tokens":-1,"output_tokens":1}}}' > "$transcript"
        ;;
    esac
    rc=0
    out=$(run_hook "$home" malformed-session "$transcript" 2>/dev/null) || rc=$?
    expect_code 0 "$rc" "$case_name must not trigger a context handoff"
    [ -z "$out" ] || fail "$case_name emitted a directive or diagnostic: $out"
    [ ! -e "$home/state/.context-restart-crossing" ] || fail "$case_name published a crossing"
  done
  pass "context restart: malformed transcript and latest-usage inputs cannot trigger a handoff"
}

test_concurrent_stop_firings_publish_one_directive() {
  local home transcript rc1 rc2 directives
  home="$TMP_ROOT/concurrent"
  transcript="$home/transcript.jsonl"
  make_primary "$home" 10
  write_transcript "$transcript" 10 10 10 10
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" TRANSCRIPT="$transcript" \
    "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      payload=$(printf "{\"session_id\":\"concurrent-session\",\"transcript_path\":\"%s\"}\n" "$TRANSCRIPT")
      printf "%s" "$payload" | "$HOOK" > "$FM_HOME/state/out1" 2>&1 & p1=$!
      printf "%s" "$payload" | "$HOOK" > "$FM_HOME/state/out2" 2>&1 & p2=$!
      wait "$p1"; printf "%s\n" "$?" > "$FM_HOME/state/rc1"
      wait "$p2"; printf "%s\n" "$?" > "$FM_HOME/state/rc2"
    '
  rc1=$(cat "$home/state/rc1")
  rc2=$(cat "$home/state/rc2")
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "concurrent Stop hooks must return one directive and one no-op, got $rc1/$rc2"
  directives=$(grep -h -c 'FIRSTMATE_OP: v1 context-refresh:' "$home/state/out1" "$home/state/out2" | awk '{n += $1} END {print n + 0}')
  [ "$directives" -eq 1 ] || fail "concurrent Stop hooks emitted $directives directives"
  [ "$(record_phase "$home")" = detected ] || fail "concurrent crossing did not retain one durable record"
  pass "context restart: concurrent Stop firings admit exactly one crossing directive"
}

test_reset_safe_wrapper_restarts_fresh_and_releases_lock() {
  local home fake count
  home="$TMP_ROOT/wrapper-home"
  fake="$TMP_ROOT/wrapper-fakebin"
  make_primary "$home" 10
  mkdir -p "$fake"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_context_restart_record_publish "$2" wrapper-session 40 10 1700000000 detected
  ' _ "$LIB" "$home/state" || fail "could not seed the wrapper crossing"

  cat > "$fake/claude" <<'SH'
#!/usr/bin/env bash
exec -a claude /bin/bash -c '
  count=$(cat "$FM_HOME/state/launch-count" 2>/dev/null || echo 0)
  count=$((count + 1))
  printf "%s\n" "$count" > "$FM_HOME/state/launch-count"
  printf "%s\n" "$*" > "$FM_HOME/state/args-$count"
  if [ "$count" -eq 1 ]; then
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$HANDOFF" handoff --session wrapper-session --reset-safe
    sleep 5
  else
    [ ! -e "$FM_HOME/state/.lock" ] || exit 91
  fi
' claude "$@"
SH
  chmod +x "$fake/claude"

  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_CLAUDE_BIN="$fake/claude" \
    "$WRAPPER" --firstmate-initial-prompt INITIAL_BRIEF -- --effort low \
    > "$home/wrapper.out" 2> "$home/wrapper.err" \
    || fail "reset-safe wrapper did not complete its fresh successor: $(cat "$home/wrapper.err")"
  count=$(cat "$home/state/launch-count")
  [ "$count" = 2 ] || fail "wrapper launched $count Claude generations instead of exactly two"
  assert_contains "$(cat "$home/state/args-1")" 'INITIAL_BRIEF' \
    "first wrapper generation did not receive its initial prompt"
  assert_not_contains "$(cat "$home/state/args-2")" 'INITIAL_BRIEF' \
    "successor replayed the old initial prompt"
  assert_contains "$(cat "$home/state/args-2")" '--effort low' \
    "successor did not retain Claude options"
  assert_contains "$(cat "$home/state/args-2")" 'FIRSTMATE_OP: v1 session-start:' \
    "successor did not receive a typed resume turn"
  assert_contains "$(cat "$home/state/args-2")" 'native SessionStart hook has already run the full digest' \
    "successor resume turn did not make the durable digest authoritative"
  assert_contains "$(cat "$home/wrapper.err")" 'starting a fresh Claude session' \
    "wrapper did not report the intentional fresh-session transition"
  [ ! -e "$home/state/.context-restart-crossing" ] || fail "wrapper retained the completed crossing sentinel"
  [ ! -e "$home/state/.lock" ] || fail "wrapper did not release the exited session's exact lock before successor launch"
  pass "context restart: reset-safe sentinel releases the old lock and starts one fresh successor"
}

test_claude_registers_one_stop_hook() {
  local count
  count=$(jq '[.hooks.Stop[].hooks[] | select(.command | contains("fm-context-restart-claude-hook.sh"))] | length' "$ROOT/.claude/settings.json")
  [ "$count" = 1 ] || fail "Claude must register exactly one context-restart Stop hook, found $count"
  pass "context restart: Claude registers exactly one context-restart Stop hook"
}

test_budget_parser_and_default
test_threshold_and_one_directive_per_crossing
test_malformed_transcript_and_usage_are_inert
test_concurrent_stop_firings_publish_one_directive
test_reset_safe_wrapper_restarts_fresh_and_releases_lock
test_claude_registers_one_stop_hook

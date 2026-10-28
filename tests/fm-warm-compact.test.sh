#!/usr/bin/env bash
# Behavior tests for warm-cache compaction (bin/fm-warm-compact-lib.sh,
# docs/configuration.md "Warm-cache compaction"). The backend primitives are
# stubs that record every call, so each guard is proven by the absence of a
# /compact submit; the engine case runs the real engine-turn argument
# construction against a stub claude.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$ROOT/bin/fm-supervision-engine-lib.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
. "$ROOT/bin/fm-warm-compact-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-warm-compact)
CONFIG="$TMP_ROOT/config"
STATE="$TMP_ROOT/state"
FM_ROOT="$TMP_ROOT/root"
FM_HOME="$TMP_ROOT/home"
mkdir -p "$CONFIG" "$STATE" "$FM_ROOT" "$FM_HOME"

CALLS="$TMP_ROOT/calls"
BUSY=idle
COMPOSER=empty
SUBMIT_VERDICT=empty
fm_backend_busy_state() { printf '%s' "$BUSY"; }
fm_backend_composer_state() { printf '%s' "$COMPOSER"; }
fm_backend_send_text_submit() { printf 'submit %s %s\n' "$1 $2" "$3" >> "$CALLS"; printf '%s' "$SUBMIT_VERDICT"; }

transcript() {  # <file> <input> <cache_read> <cache_creation>
  {
    printf '{"type":"user","message":{"content":"hi"}}\n'
    printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}}}\n'
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}}}\n' "$2" "$3" "$4"
    printf '{"type":"system"}\n'
  } > "$1"
}

reset() {
  : > "$CALLS"
  BUSY=idle
  COMPOSER=empty
  SUBMIT_VERDICT=empty
  printf '' > "$CONFIG/warm-compact"
  transcript "$TMP_ROOT/t.jsonl" 10 90000 5000
}

primary() {  # <idle> <compacted>
  fm_warm_compact_primary "$CONFIG" herdr sess:pane "$1" "$TMP_ROOT/t.jsonl" "$2"
}

submits() { wc -l < "$CALLS" | tr -d ' '; }

test_context_size_is_the_last_request() {
  reset
  assert_equals 95010 "$(fm_warm_compact_context_tokens "$TMP_ROOT/t.jsonl")" 'context is input + cache_read + cache_creation of the last request'
  pass 'context size comes from the last request'
}

test_due_primary_gets_one_compact_through_the_backend_primitive() {
  reset
  assert_equals sent "$(primary 2700 0)" 'a due idle primary is compacted'
  assert_equals 'submit herdr sess:pane /compact' "$(cat "$CALLS")" 'one /compact through the backend submit primitive'
  pass 'due primary is compacted once'
}

test_opt_in_absent_does_nothing() {
  reset
  rm -f "$CONFIG/warm-compact"
  assert_equals off "$(primary 99999 0)" 'no opt-in file means off'
  assert_equals 0 "$(submits)" 'nothing typed without the opt-in'
  pass 'opt-in absent guard'
}

test_busy_agent_is_never_typed_into() {
  reset
  BUSY=busy
  assert_equals busy "$(primary 2700 0)" 'a busy agent is held back'
  BUSY=unknown
  assert_equals busy "$(primary 2700 0)" 'an unproven agent state is held back'
  assert_equals 0 "$(submits)" 'nothing typed into a busy agent'
  pass 'busy agent guard'
}

test_non_empty_composer_is_never_typed_into() {
  reset
  for COMPOSER in pending pending-unproven unknown; do
    assert_equals composer "$(primary 2700 0)" "composer $COMPOSER is held back"
  done
  assert_equals 0 "$(submits)" 'nothing typed over a composer that is not provably empty'
  pass 'composer guard'
}

test_small_context_is_not_compacted() {
  reset
  transcript "$TMP_ROOT/t.jsonl" 10 40000 5000
  assert_equals small "$(primary 2700 0)" 'a context below the threshold is held back'
  assert_equals small "$(fm_warm_compact_verdict "$CONFIG" 2700 '' 0)" 'an unreadable context is held back'
  assert_equals 0 "$(submits)" 'nothing typed below the threshold'
  pass 'threshold guard'
}

test_young_session_is_not_compacted() {
  reset
  assert_equals young "$(primary 2699 0)" 'a session idle for less than the window is held back'
  assert_equals 0 "$(submits)" 'nothing typed before the idle window'
  pass 'idle window guard'
}

test_one_compaction_per_idle_episode() {
  reset
  assert_equals episode "$(primary 99999 1)" 'a session already compacted this episode is held back'
  assert_equals 0 "$(submits)" 'nothing typed twice in one episode'
  pass 'episode guard'
}

test_failed_submit_is_reported() {
  reset
  SUBMIT_VERDICT=send-failed
  assert_equals failed "$(primary 2700 0)" 'an unconfirmed submit is a failure the caller marks'
  pass 'failed submit'
}

test_config_tunables() {
  reset
  printf '# tuned\nidle-seconds=60\nmin-context-tokens=1000\nbad=line\nidle-seconds=abc\n' > "$CONFIG/warm-compact"
  transcript "$TMP_ROOT/t.jsonl" 1 1000 0
  assert_equals sent "$(primary 60 0)" 'the home tunables apply'
  assert_equals young "$(primary 59 0)" 'the tuned window applies'
  pass 'config tunables'
}

STUB="$TMP_ROOT/claude-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_TEST_ENGINE_ARGS"
printf '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"num_turns":0,"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}'
SH
chmod +x "$STUB"

engine() {  # <idle> <compacted>
  FM_SUPERVISION_ENGINE_CLAUDE_BIN=$STUB FM_TEST_ENGINE_ARGS="$TMP_ROOT/engine-args" CLAUDE_CONFIG_DIR="$TMP_ROOT/claude" \
    fm_warm_compact_engine "$CONFIG" "$1" sess-1 claude sonnet "$TMP_ROOT/prompt" "$2"
}

test_engine_conversation_is_compacted_by_resume() {
  reset
  mkdir -p "$TMP_ROOT/claude/projects/p"
  : > "$TMP_ROOT/prompt"
  transcript "$TMP_ROOT/claude/projects/p/sess-1.jsonl" 10 90000 5000
  rm -f "$TMP_ROOT/engine-args"
  assert_equals compacted "$(engine 2700 0)" 'a due engine conversation is compacted'
  assert_contains "$(cat "$TMP_ROOT/engine-args")" '/compact' 'the engine turn carries /compact'
  assert_contains "$(cat "$TMP_ROOT/engine-args")" 'sess-1' 'the engine turn resumes the recorded conversation'
  for verdict in "episode:2700:1" "young:100:0"; do
    rm -f "$TMP_ROOT/engine-args"
    IFS=: read -r want idle was_done <<< "$verdict"
    assert_equals "$want" "$(engine "$idle" "$was_done")" "engine guard $want"
    assert_absent "$TMP_ROOT/engine-args" "no engine turn for guard $want"
  done
  rm -f "$CONFIG/warm-compact" "$TMP_ROOT/engine-args"
  assert_equals off "$(engine 99999 0)" 'engine compaction needs the opt-in'
  assert_absent "$TMP_ROOT/engine-args" 'no engine turn without the opt-in'
  pass 'engine conversation compaction'
}

test_context_size_is_the_last_request
test_due_primary_gets_one_compact_through_the_backend_primitive
test_opt_in_absent_does_nothing
test_busy_agent_is_never_typed_into
test_non_empty_composer_is_never_typed_into
test_small_context_is_not_compacted
test_young_session_is_not_compacted
test_one_compaction_per_idle_episode
test_failed_submit_is_reported
test_config_tunables
test_engine_conversation_is_compacted_by_resume

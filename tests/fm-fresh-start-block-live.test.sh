#!/usr/bin/env bash
# tests/fm-fresh-start-block-live.test.sh - live guard: the installed Claude
# Code honors the block decision the daily fresh start's prompt hook prints for
# a prompt that meets a committed clear (bin/fm-fresh-start-lib.sh THE CLEAR
# BOUNDARY), so that prompt is refused with its reason and never runs.
#
# Token-free and default-on (fm_live_gate): a blocked prompt never reaches the
# model. A scratch project registers one UserPromptSubmit hook that records a
# committed clear for the very session the payload names, runs the real
# fm_fresh_start_hook, and prints its output only on the refusal code, exactly
# as bin/fm-host-mirror.sh hook claude does (tests/fm-host-mirror.test.sh pins
# that half). The guard fails naming the Claude Code version unless the result
# carries the hook's reason, reports no model turn, and spent no tokens.
# Refresh the dated record in docs/verification/runtime-backends.md from it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_FRESH_START_BLOCK claude jq

TMP_ROOT=$(fm_test_tmproot fm-fresh-start-block-live)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)

test_a_prompt_meeting_a_committed_clear_is_refused() {
  local dir="$TMP_ROOT/probe" out result
  mkdir -p "$dir/project/.claude" "$dir/state"
  cat >"$dir/hook.sh" <<SH
#!/usr/bin/env bash
payload=\$(cat)
tp=\$(printf '%s' "\$payload" | jq -r '(.transcript_path // "") | tostring')
printf 'date=%s\nstep=clearing\nat=%s\nnonce=0123456789abcdef\ntranscript=%s\n' "\$(date +%Y-%m-%d)" "\$(date +%s)" "\$tp" >"$dir/state/.daily-fresh-start"
out=\$(bash -c '. "\$1/bin/fm-fresh-start-lib.sh"; fm_fresh_start_hook "\$2" UserPromptSubmit "\$3"' _ "$ROOT" "$dir/state" "\$payload")
[ "\$?" != 3 ] || printf '%s\n' "\$out"
exit 0
SH
  chmod +x "$dir/hook.sh"
  jq -n --arg c "$dir/hook.sh" '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $c, timeout: 10}]}]}}' \
    >"$dir/project/.claude/settings.json"
  out=$(cd "$dir/project" && claude -p "LIVE_BLOCK_PROBE reply with only the word PROCESSED" \
    --setting-sources project --output-format json </dev/null 2>"$dir/claude.err") \
    || fail "claude $CLAUDE_VERSION: print mode exited non-zero: $(head -3 "$dir/claude.err")"
  result=$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)
  case "$result" in
    *"daily fresh start is clearing this conversation"*) ;;
    *) fail "claude $CLAUDE_VERSION: the hook's block decision did not refuse the prompt; result: $(printf '%s' "$result" | head -c 300)" ;;
  esac
  assert_equals 0 "$(printf '%s' "$out" | jq -r '.num_turns // "missing"')" "claude $CLAUDE_VERSION: a refused prompt runs no model turn"
  assert_equals 0 "$(printf '%s' "$out" | jq -r '(.usage.input_tokens // 0) + (.usage.output_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)')" \
    "claude $CLAUDE_VERSION: a refused prompt spends no tokens"
  pass "claude $CLAUDE_VERSION: a prompt that meets a committed clear is refused with the fresh start's reason, with no model turn"
}

test_a_prompt_meeting_a_committed_clear_is_refused

#!/usr/bin/env bash
# Behavior tests for bin/fm-session-digest.sh and its reader.
#
# The digest mines the Claude, Pi, and Codex session logs a day produced, so the
# contract under test is the row it writes per harness, the correction count and
# its 120-character quote cap, the Friction ordering, the quiet-day
# no-candidates line, and the local-only posture: mode 0600, no assistant text,
# and an elapsed line against the 30 s budget.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

DIGEST="$ROOT/bin/fm-session-digest.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-digest)
CLAUDE_ROOT="$TMP_ROOT/claude-projects"
PI_ROOT="$TMP_ROOT/pi-sessions"
CODEX_ROOT="$TMP_ROOT/codex-sessions"
OUT_DIR="$TMP_ROOT/improvements"
DAY=2026-09-11
QUIET_DAY=2026-09-12
WORKTREE="$TMP_ROOT/wt"
mkdir -p "$CLAUDE_ROOT/-Users-x-dev-firstmate" "$PI_ROOT/--tmp-fm--" \
  "$CODEX_ROOT/2026/09/11" "$WORKTREE"

# Claude: one clean session. A tool call, a successful tool result, two charged
# assistant messages, and one plain user turn with no redirect.
cat >"$CLAUDE_ROOT/-Users-x-dev-firstmate/claude-session-cccc3333.jsonl" <<EOF
{"type":"last-prompt","leafUuid":"leaf","sessionId":"claude-session-cccc3333"}
{"parentUuid":null,"type":"user","message":{"role":"user","content":"please summarize the fleet"},"isMeta":false,"uuid":"u1","timestamp":"${DAY}T08:00:00","cwd":"/Users/x/dev/firstmate","sessionId":"claude-session-cccc3333"}
{"type":"assistant","effort":"medium","message":{"role":"assistant","model":"claude-sonnet-4-5","id":"msg_1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":1,"cache_read_input_tokens":2}},"timestamp":"${DAY}T08:00:05","cwd":"/Users/x/dev/firstmate","sessionId":"claude-session-cccc3333"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]},"timestamp":"${DAY}T08:00:06","cwd":"/Users/x/dev/firstmate","sessionId":"claude-session-cccc3333"}
{"type":"assistant","message":{"role":"assistant","model":"claude-sonnet-4-5","id":"msg_2","content":[{"type":"text","text":"ASSISTANT-SECRET-TEXT"}],"usage":{"input_tokens":5,"output_tokens":3}},"timestamp":"${DAY}T08:01:00","cwd":"/Users/x/dev/firstmate","sessionId":"claude-session-cccc3333"}
EOF

# Pi: the friction session. Four identical failing bash calls (three retries),
# an injected launch brief that carries the task id, and two captain redirects,
# the second long enough to prove the quote cap.
PI_LOG="$PI_ROOT/--tmp-fm--/${DAY}T09-00-00-000Z_pi-session-aaaa1111.jsonl"
LONG_REDIRECT="wrong, again: the worktree you used is not the one the brief named, so every path you read came from the wrong home and the whole run has to start over SECRET-TAIL-MARKER"
cat >"$PI_LOG" <<EOF
{"type":"session","version":3,"id":"pi-session-aaaa1111","timestamp":"${DAY}T09:00:00","cwd":"/tmp/fm-firstmate-4718ed1e-scout-leaks-openai/scratch"}
{"type":"model_change","modelId":"gpt-6-astra","timestamp":"${DAY}T09:00:01"}
{"type":"thinking_level_change","thinkingLevel":"high","timestamp":"${DAY}T09:00:02"}
{"type":"message","timestamp":"${DAY}T09:00:03","message":{"role":"user","content":[{"type":"text","text":"FIRSTMATE_OP: v1 launch-brief: report with echo done >> '/Users/x/dev/firstmate/state/scout-leaks-openai.status'"}]}}
{"type":"message","timestamp":"${DAY}T09:00:04","message":{"role":"assistant","model":"gpt-6-astra","content":[{"type":"toolCall","name":"bash","arguments":{"command":"ls"}}],"usage":{"input":100,"output":10,"cacheRead":5,"cacheWrite":2}}}
{"type":"message","timestamp":"${DAY}T09:00:05","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[{"type":"text","text":"TOOL-OUTPUT-SECRET"}]}}
{"type":"message","timestamp":"${DAY}T09:00:06","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"ls"}}]}}
{"type":"message","timestamp":"${DAY}T09:00:07","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[]}}
{"type":"message","timestamp":"${DAY}T09:00:08","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"ls"}}]}}
{"type":"message","timestamp":"${DAY}T09:00:09","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[]}}
{"type":"message","timestamp":"${DAY}T09:00:10","message":{"role":"user","content":[{"type":"text","text":"no, not that directory"}]}}
{"type":"message","timestamp":"${DAY}T09:00:11","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"ls"}}],"usage":{"input":50,"output":5,"cacheRead":0,"cacheWrite":0}}}
{"type":"message","timestamp":"${DAY}T09:00:12","message":{"role":"toolResult","toolName":"bash","isError":true,"content":[]}}
{"type":"message","timestamp":"${DAY}T09:00:13","message":{"role":"user","content":[{"type":"text","text":"$LONG_REDIRECT"}]}}
{"type":"message","timestamp":"${DAY}T09:02:00","message":{"role":"assistant","content":[]}}
EOF

# Codex: medium friction. Two identical failing commands and one redirect.
cat >"$CODEX_ROOT/2026/09/11/rollout-codex-session-bbbb2222.jsonl" <<EOF
{"timestamp":"${DAY}T10:00:00","type":"session_meta","payload":{"id":"codex-session-bbbb2222","timestamp":"${DAY}T10:00:00","cwd":"/Users/x/dev/artemis"}}
{"timestamp":"${DAY}T10:00:01","type":"turn_context","payload":{"model":"gpt-6-astra","effort":"high","cwd":"/Users/x/dev/artemis"}}
{"timestamp":"${DAY}T10:00:02","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"build the roof"}]}}}
{"timestamp":"${DAY}T10:00:03","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":"npm test","status":"failed","exit_code":1}}}
{"timestamp":"${DAY}T10:00:04","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":"npm test","status":"failed","exit_code":1}}}
{"timestamp":"${DAY}T10:00:05","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"wrong, use the other suite"}]}}}
{"timestamp":"${DAY}T10:00:06","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"output_tokens":80,"cached_input_tokens":700,"cache_write_input_tokens":0}}}}
{"timestamp":"${DAY}T10:03:00","type":"event_msg","payload":{"type":"task_complete"}}
EOF

run_digest() {
  FM_IMPROVEMENTS_DIR="$OUT_DIR" \
  FM_CLAUDE_PROJECTS_OVERRIDE="$CLAUDE_ROOT" \
  FM_PI_SESSIONS_OVERRIDE="$PI_ROOT" \
  FM_CODEX_SESSIONS_OVERRIDE="$CODEX_ROOT" \
    bash "$DIGEST" "$@"
}

test_help_and_bad_arguments() {
  bash "$DIGEST" -h | grep -q -- '--date YYYY-MM-DD' \
    || fail "-h did not document --date"
  bash "$DIGEST" --help >/dev/null || fail "--help did not exit 0"
  if bash "$DIGEST" --nope >/dev/null 2>&1; then
    fail "an unknown argument did not fail"
  fi
  pass "help prints and an unknown argument fails"
}

test_rows_carry_the_observed_values() {
  local out digest
  out=$(run_digest --date "$DAY")
  digest=$(printf '%s\n' "$out" | head -n1)
  [ -f "$digest" ] || fail "the reader reported no digest file: $out"
  [ "$digest" = "$OUT_DIR/$DAY.md" ] || fail "the digest landed outside the improvements dir: $digest"

  grep -qF "| cccc3333 | claude | home:firstmate | - | claude-sonnet-4-5 | medium | 15 | 7 | 3 | 60 | 1 | 0 | 0 | 1 | 0 |" "$digest" \
    || fail "the claude row did not report its observed values: $(grep -F 'cccc3333' "$digest")"
  grep -qF "| aaaa1111 | pi | wt:fm-firstmate-4718ed1e-scout-leaks-openai | scout-leaks-openai | gpt-6-astra | high | 150 | 15 | 7 | 120 | 4 | 4 | 3 | 3 | 2 |" "$digest" \
    || fail "the pi row did not report its observed values: $(grep -F 'aaaa1111' "$digest")"
  grep -qF "| bbbb2222 | codex | home:artemis | - | gpt-6-astra | high | 900 | 80 | 700 | 180 | 2 | 2 | 1 | 2 | 1 |" "$digest" \
    || fail "the codex row did not report its observed values: $(grep -F 'bbbb2222' "$digest")"
  pass "each harness row reports place, task, model, effort, tokens, wall time, tools, errors, retries, turns, and corrections"
}

test_corrections_are_counted_quoted_and_capped() {
  local digest="$OUT_DIR/$DAY.md"
  # shellcheck disable=SC2016 # backticks are literal digest Markdown, not command substitution
  [ "$(grep -c '^- `aaaa1111` (pi, task scout-leaks-openai):' "$digest")" = "2" ] \
    || fail "the pi session did not report both redirects as corrections"
  # shellcheck disable=SC2016 # backticks are literal digest Markdown, not command substitution
  grep -qF -- '- `bbbb2222` (codex, task -): "wrong, use the other suite"' "$digest" \
    || fail "the codex redirect was not quoted"
  if grep -q 'SECRET-TAIL-MARKER' "$digest"; then
    fail "a correction quote exceeded the 120-character cap"
  fi
  if grep -qE 'ASSISTANT-SECRET-TEXT|TOOL-OUTPUT-SECRET' "$digest"; then
    fail "the digest stored assistant text or tool output"
  fi
  [ "$(stat -f '%Lp' "$digest" 2>/dev/null || stat -c '%a' "$digest")" = "600" ] \
    || fail "the digest is not mode 0600"
  tail -n1 "$digest" | grep -qE '^elapsed: [0-9]+s \(budget 30s\)' \
    || fail "the elapsed line is not the last line: $(tail -n1 "$digest")"
  grep -q 'schedule-or-kill' "$OUT_DIR/README.md" \
    || fail "the usefulness plan was not written into the improvements folder"
  pass "corrections are counted, quoted under the cap, and the file stays local-only with its elapsed line"
}

test_friction_ranks_the_worst_session_first() {
  local digest="$OUT_DIR/$DAY.md" friction
  friction=$(sed -n '/^## Friction$/,/^## Candidates$/p' "$digest")
  # shellcheck disable=SC2016 # backticks are literal digest Markdown, not command substitution
  printf '%s\n' "$friction" | grep -q '^1\. `aaaa1111` pi task=scout-leaks-openai model=gpt-6-astra errors=4 retries=3 corrections=2 total=9$' \
    || fail "the pi session did not rank first in Friction: $friction"
  # shellcheck disable=SC2016 # backticks are literal digest Markdown, not command substitution
  printf '%s\n' "$friction" | grep -q '^2\. `bbbb2222` codex' \
    || fail "the codex session did not rank second in Friction: $friction"
  if printf '%s\n' "$friction" | grep -q 'cccc3333'; then
    fail "a clean session was listed as friction"
  fi
  [ "$(printf '%s\n' "$friction" | grep -cE '^[0-9]+\.')" = "2" ] \
    || fail "Friction did not list exactly the sessions with friction"
  sed -n '/^## Candidates$/,$p' "$digest" | grep -q 'likely owner: bin script' \
    || fail "three identical retries did not propose a bin script owner"
  pass "Friction ranks by errors plus retries plus corrections and Candidates name an owner"
}

test_quiet_day_says_so_instead_of_inventing_candidates() {
  local out digest
  out=$(run_digest --date "$QUIET_DAY")
  digest=$(printf '%s\n' "$out" | head -n1)
  grep -q '^Nothing notable: no session crossed a friction threshold, so there is no candidate to propose\.$' "$digest" \
    || fail "a day with nothing notable invented candidates: $(cat "$digest")"
  grep -q '^Sessions read: 0' "$digest" \
    || fail "a day with no sessions reported sessions: $(cat "$digest")"
  pass "a quiet day reports nothing notable in one line"
}

test_help_and_bad_arguments
test_rows_carry_the_observed_values
test_corrections_are_counted_quoted_and_capped
test_friction_ranks_the_worst_session_first
test_quiet_day_says_so_instead_of_inventing_candidates
printf 'All fm-session-digest tests passed.\n'

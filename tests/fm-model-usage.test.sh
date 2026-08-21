#!/usr/bin/env bash
# Behavior tests for bin/fm-model-usage.mjs usage-source reporting.
# The usage extractor must distinguish *why* token usage is absent so the
# sealed terminal records unavailable usage explicitly rather than silently
# omitting it: a verified harness with no matching session reports
# "session-not-found", while a harness with no verified durable usage-log
# surface reports "no-verified-source".
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
USAGE="$ROOT/bin/fm-model-usage.mjs"
TMP_ROOT=$(fm_test_tmproot fm-model-usage)
# The absent-session premise belongs to the fixture, not to whatever sessions
# this machine happens to hold, so every case reads an empty session root.
CODEX_SESSIONS="$TMP_ROOT/codex-sessions"
WORKTREE="$TMP_ROOT/absent-worktree"
mkdir -p "$CODEX_SESSIONS"

test_unsupported_harness_reports_no_verified_source() {
  local h out
  for h in grok kimi cursor-agent; do
    out=$(FM_CODEX_SESSIONS_OVERRIDE="$CODEX_SESSIONS" NODE_NO_WARNINGS=1 node "$USAGE" "$h" "$WORKTREE" "2026-08-18T00:00:00Z")
    printf '%s\n' "$out" | jq -e '.usage.inputTokens==null and .usage.outputTokens==null and .usageSource=="no-verified-source"' >/dev/null \
      || fail "$h did not report usageSource=no-verified-source; got: $out"
  done
  pass "unsupported harnesses report usageSource=no-verified-source with null usage"
}

test_verified_harness_missing_session_reports_session_not_found() {
  local out
  out=$(FM_CODEX_SESSIONS_OVERRIDE="$CODEX_SESSIONS" NODE_NO_WARNINGS=1 node "$USAGE" codex "$WORKTREE" "2026-08-18T00:00:00Z")
  printf '%s\n' "$out" | jq -e '.usage.inputTokens==null and .usageSource=="session-not-found"' >/dev/null \
    || fail "codex with no matching session did not report usageSource=session-not-found; got: $out"
  pass "a verified harness with no matching session reports usageSource=session-not-found"
}

# A session whose meta line matches the attempt reports its active duration even
# when the harness never wrote a token total. Calling that "session-not-found"
# would contradict the wallSeconds on the very same row and would blame teardown
# timing for what is a harness-capability gap.
test_matched_session_without_tokens_is_named_apart() {
  local out day="$TMP_ROOT/matched-sessions/2026/08/18" wt="$TMP_ROOT/matched-worktree"
  mkdir -p "$day" "$wt"
  cat > "$day/rollout-no-tokens.jsonl" <<EOF
{"timestamp":"2026-08-18T00:00:05Z","type":"session_meta","payload":{"id":"no-tokens","timestamp":"2026-08-18T00:00:05Z","cwd":"$wt"}}
{"timestamp":"2026-08-18T00:02:05Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}
EOF
  out=$(FM_CODEX_SESSIONS_OVERRIDE="$TMP_ROOT/matched-sessions" NODE_NO_WARNINGS=1 node "$USAGE" codex "$wt" "2026-08-18T00:00:00Z")
  printf '%s\n' "$out" | jq -e '.usage.inputTokens==null and .usage.outputTokens==null' >/dev/null \
    || fail "a session with no token_count reported token totals: $out"
  printf '%s\n' "$out" | jq -e '.wallSeconds!=null' >/dev/null \
    || fail "a matched session did not report the active duration only it can measure: $out"
  printf '%s\n' "$out" | jq -e '.usageSource=="session-matched-no-tokens"' >/dev/null \
    || fail "a matched session with no tokens was not named apart from a missing session: $out"

  # The same session with a token total is still plain recorded usage.
  cat >> "$day/rollout-no-tokens.jsonl" <<'EOF'
{"timestamp":"2026-08-18T00:02:06Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":11,"output_tokens":7}}}}
EOF
  out=$(FM_CODEX_SESSIONS_OVERRIDE="$TMP_ROOT/matched-sessions" NODE_NO_WARNINGS=1 node "$USAGE" codex "$wt" "2026-08-18T00:00:00Z")
  printf '%s\n' "$out" | jq -e '.usage.inputTokens==11 and .usage.outputTokens==7 and .usageSource=="recorded"' >/dev/null \
    || fail "a session that does report tokens stopped reporting recorded usage: $out"
  pass "a matched session with no token totals is named apart from a missing session"
}

test_unsupported_harness_reports_no_verified_source
test_verified_harness_missing_session_reports_session_not_found
test_matched_session_without_tokens_is_named_apart
printf 'All fm-model-usage tests passed.\n'

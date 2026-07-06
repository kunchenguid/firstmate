#!/usr/bin/env bash
# Behavior tests for the fast usage tripwire watcher check.
#
# The script must scan only recent transcript fixtures by mtime, stay silent when
# healthy, and emit exactly one line when either session count or output tokens
# breach the configured thresholds.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRIPWIRE="$ROOT/bin/fm-usage-tripwire.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-tripwire)

make_case_dirs() {
  local dir=$1
  mkdir -p "$dir/claude/projects/project-a" "$dir/codex/sessions/2026/07/06"
}

write_claude_session() {
  local file=$1 tokens=${2:-0}
  mkdir -p "$(dirname "$file")"
  printf '{"type":"assistant","message":{"usage":{"output_tokens":%s}}}\n' "$tokens" > "$file"
}

write_codex_session() {
  local file=$1 tokens=${2:-0}
  mkdir -p "$(dirname "$file")"
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"token_count":{"output_tokens":%s}}}}\n' "$tokens" > "$file"
}

age_file_old() {
  touch -t 202001010000 "$1"
}

run_tripwire() {
  local dir=$1 session_threshold=$2 output_threshold=$3
  FM_USAGE_CLAUDE_DIR="$dir/claude/projects" \
    FM_USAGE_CODEX_DIR="$dir/codex/sessions" \
    FM_USAGE_WINDOW_MINUTES=60 \
    FM_USAGE_SESSION_THRESHOLD="$session_threshold" \
    FM_USAGE_OUTPUT_THRESHOLD="$output_threshold" \
    "$TRIPWIRE"
}

test_healthy_fixture_stays_silent() {
  local dir out
  dir="$TMP_ROOT/healthy"
  make_case_dirs "$dir"
  write_claude_session "$dir/claude/projects/project-a/claude-1.jsonl" 1200
  write_codex_session "$dir/codex/sessions/2026/07/06/codex-1.jsonl" 800
  write_claude_session "$dir/claude/projects/project-a/old-ignored.jsonl" 999999
  age_file_old "$dir/claude/projects/project-a/old-ignored.jsonl"

  out=$(run_tripwire "$dir" 10 10000)
  [ -z "$out" ] || fail "healthy fixture should be silent, got: $out"
  pass "healthy fixture exits silently"
}

test_session_count_breach_alarms_once() {
  local dir out lines i
  dir="$TMP_ROOT/session-burst"
  make_case_dirs "$dir"
  i=1
  while [ "$i" -le 6 ]; do
    write_claude_session "$dir/claude/projects/project-a/burst-$i.jsonl" 0
    i=$((i + 1))
  done

  out=$(run_tripwire "$dir" 5 999999)
  lines=$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')
  [ "$lines" = 1 ] || fail "session breach should print exactly one line, got $lines: $out"
  assert_contains "$out" "breach=sessions" "session breach line did not name the session signal"
  assert_contains "$out" "sessions=6/5" "session breach line did not include count and threshold"
  pass "session-count breach emits one alarm line"
}

test_output_token_breach_alarms_once() {
  local dir out lines
  dir="$TMP_ROOT/token-burst"
  make_case_dirs "$dir"
  write_claude_session "$dir/claude/projects/project-a/claude-hot.jsonl" 4000
  write_codex_session "$dir/codex/sessions/2026/07/06/codex-hot.jsonl" 3500

  out=$(run_tripwire "$dir" 10 7000)
  lines=$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')
  [ "$lines" = 1 ] || fail "token breach should print exactly one line, got $lines: $out"
  assert_contains "$out" "breach=output_tokens" "token breach line did not name the token signal"
  assert_contains "$out" "output_tokens=7500/7000" "token breach line did not include token sum and threshold"
  pass "output-token breach emits one alarm line"
}

test_large_old_fixture_set_is_bounded_by_mtime() {
  local dir out i
  dir="$TMP_ROOT/large-old"
  make_case_dirs "$dir"
  i=1
  while [ "$i" -le 250 ]; do
    write_claude_session "$dir/claude/projects/project-a/old-$i.jsonl" 100000
    age_file_old "$dir/claude/projects/project-a/old-$i.jsonl"
    i=$((i + 1))
  done
  write_codex_session "$dir/codex/sessions/2026/07/06/recent.jsonl" 1

  out=$(run_tripwire "$dir" 10 1000)
  [ -z "$out" ] || fail "old files should be ignored by mtime-bounded scan, got: $out"
  pass "large old fixture set is ignored by the sliding mtime window"
}

test_missing_transcript_dirs_are_empty() {
  local dir out
  dir="$TMP_ROOT/missing"
  mkdir -p "$dir"

  out=$(run_tripwire "$dir" 1 1)
  [ -z "$out" ] || fail "missing transcript dirs should be silent, got: $out"
  pass "missing transcript dirs degrade as empty"
}

test_healthy_fixture_stays_silent
test_session_count_breach_alarms_once
test_output_token_breach_alarms_once
test_large_old_fixture_set_is_bounded_by_mtime
test_missing_transcript_dirs_are_empty

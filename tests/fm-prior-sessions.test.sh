#!/usr/bin/env bash
# tests/fm-prior-sessions.test.sh - bin/fm-prior-sessions.sh names this home's
# newest primary-session transcripts across Pi, Kiro, and Claude, newest first
# and bounded, ignores other homes' sessions, prints paths and never content,
# and prints nothing when no transcript exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRIOR="$ROOT/bin/fm-prior-sessions.sh"
TMP_ROOT=$(fm_test_tmproot fm-prior-sessions-tests)
trap fm_test_cleanup EXIT

sha16() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-16
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
  fi
}

FAKE_HOME="$TMP_ROOT/login"
FMHOME="$TMP_ROOT/fleet.home"
OTHER="$TMP_ROOT/other"
mkdir -p "$FAKE_HOME" "$FMHOME" "$OTHER"

run_prior() {  # <fm-home> [args...]
  local home=$1
  shift
  env -u PI_CODING_AGENT_DIR HOME="$FAKE_HOME" FM_HOME="$home" "$PRIOR" "$@"
}

out=$(run_prior "$FMHOME"); rc=$?
expect_code 0 "$rc" "no transcripts"
assert_equals "" "$out" "no transcripts prints nothing"
pass "a home with no transcripts prints nothing"

enc=${FMHOME#/}
pi_dir="$FAKE_HOME/.pi/agent/sessions/--${enc//\//-}--"
mkdir -p "$pi_dir"
printf '{"secret":"PI-CONTENT"}\n' > "$pi_dir/a.jsonl"
fm_touch_epoch 1000000000 "$pi_dir/a.jsonl"

kiro_dir="$FAKE_HOME/.kiro/sessions/$(sha16 "$FMHOME")"
mkdir -p "$kiro_dir/sess_mine" "$kiro_dir/sess_foreign"
printf '{"workspacePaths":["%s"]}\n' "$FMHOME" > "$kiro_dir/sess_mine/session.json"
printf '{"secret":"KIRO-CONTENT"}\n' > "$kiro_dir/sess_mine/messages.jsonl"
fm_touch_epoch 1000000200 "$kiro_dir/sess_mine/messages.jsonl"
printf '{"workspacePaths":["%s"]}\n' "$OTHER" > "$kiro_dir/sess_foreign/session.json"
printf '{}\n' > "$kiro_dir/sess_foreign/messages.jsonl"
fm_touch_epoch 1000000900 "$kiro_dir/sess_foreign/messages.jsonl"

claude_dir="$FAKE_HOME/.claude/projects/$(printf '%s' "$FMHOME" | tr -c 'A-Za-z0-9' '-')"
mkdir -p "$claude_dir"
printf '{}\n' > "$claude_dir/c.jsonl"
fm_touch_epoch 1000000100 "$claude_dir/c.jsonl"

other_enc=${OTHER#/}
mkdir -p "$FAKE_HOME/.pi/agent/sessions/--${other_enc//\//-}--"
printf '{}\n' > "$FAKE_HOME/.pi/agent/sessions/--${other_enc//\//-}--/x.jsonl"

out=$(run_prior "$FMHOME"); rc=$?
expect_code 0 "$rc" "three harnesses"
expected="kiro    2001-09-09T01:50Z  $kiro_dir/sess_mine/messages.jsonl
claude  2001-09-09T01:48Z  $claude_dir/c.jsonl
pi      2001-09-09T01:46Z  $pi_dir/a.jsonl"
assert_equals "$expected" "$out" "newest first across pi, kiro, and claude"
assert_not_contains "$out" "CONTENT" "transcript content is never printed"
assert_not_contains "$out" "sess_foreign" "a kiro session of another workspace is excluded"
assert_not_contains "$out" "x.jsonl" "another home's pi sessions are excluded"
pass "lists this home's transcripts newest first, paths only"

out=$(run_prior "$FMHOME" --limit 1)
assert_equals "kiro    2001-09-09T01:50Z  $kiro_dir/sess_mine/messages.jsonl" "$out" "--limit bounds the list"
pass "--limit bounds the list"

ln -s "$FMHOME" "$TMP_ROOT/link.home"
out=$(run_prior "$TMP_ROOT/link.home" --limit 1)
assert_contains "$out" "sess_mine" "a symlinked FM_HOME finds sessions recorded under the physical path"
pass "a symlinked FM_HOME also matches the physical path"

rc=0; run_prior "$FMHOME" --limit 0 >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "--limit 0 is a usage error"
rc=0; env -u FM_HOME HOME="$FAKE_HOME" "$PRIOR" >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "missing FM_HOME is a usage error"
pass "usage errors exit 2"

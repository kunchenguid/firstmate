#!/usr/bin/env bash
# Behavioral regressions for the shared owner-rules surface (data/owner-rules.md),
# its audit for quotes trapped in a private note, and the question rule at the
# turn boundary (a captain-facing question must cite an open board card).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RULES="$ROOT/bin/fm-owner-rules.sh"
CARD="$ROOT/bin/fm-question-card.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-owner-rules)

test_add_refuses_an_entry_it_cannot_enforce() {
  local home out rc
  home="$TMP_ROOT/refuse"
  mkdir -p "$home/data"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" add --scope s --enforce bin/fm-pr-merge.sh 2>&1); rc=$?
  assert_equals 2 "$rc" "an entry with no owner words is accepted"
  case "$out" in
    *"needs the owner's own words"*) ;;
    *) fail "no-words refusal did not name the missing owner words: $out" ;;
  esac

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" add --words "always keep the fleet moving" --scope s 2>&1); rc=$?
  assert_equals 2 "$rc" "an entry with no enforcement point is accepted"
  case "$out" in
    *"needs an enforcement point"*) ;;
    *) fail "no-enforcement refusal did not name the enforcement point: $out" ;;
  esac

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" add --words "always keep the fleet moving" --scope s --enforce none 2>&1); rc=$?
  assert_equals 2 "$rc" "an enforcement point of 'none' is accepted"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" add --words "always keep the fleet moving" --scope s --enforce bin/not-a-script.sh 2>&1); rc=$?
  assert_equals 2 "$rc" "an enforcement point naming a missing path is accepted"
  case "$out" in
    *"does not exist in this checkout"*) ;;
    *) fail "missing-path refusal did not name the path: $out" ;;
  esac

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" add --words "always keep the fleet moving" --scope s 2>&1); rc=$?
  assert_equals 2 "$rc" "an entry with no scope is accepted"
  assert_absent "$home/data/owner-rules.md" "a refused entry created a surface"
  pass "an entry with no words, no scope, or no real enforcement point is refused"
}

test_seeded_surface_and_added_entry() {
  local home surface
  home="$TMP_ROOT/surface"
  mkdir -p "$home/data"
  surface="$home/data/owner-rules.md"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" init >/dev/null 2>&1 \
    || fail "init did not write the shared rules surface"
  assert_grep "should be in juggernaut not just in your memory" "$surface" \
    "the seeded surface dropped the owner's correction rule"
  assert_grep "posting questions will be stricter way of working" "$surface" \
    "the seeded surface dropped the owner's question rule"

  local entries scopes enforcers words
  entries=$(grep -c "^- Owner's words:" "$surface" || true)
  scopes=$(grep -c '^- Scope:' "$surface" || true)
  enforcers=$(grep -c '^- Enforced by:' "$surface" || true)
  words=$(grep -c '^- Enforced by: *$' "$surface" || true)
  assert_equals "$entries" "$scopes" "a seeded entry has no scope line"
  assert_equals "$entries" "$enforcers" "a seeded entry has no enforcement line"
  assert_equals 0 "$words" "a seeded entry has an empty enforcement point"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" init >/dev/null 2>&1
  assert_not_equals 0 "$?" "init overwrote an existing surface"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$RULES" add --words "never ship an unproven screen" --scope "every user-visible change" \
    --enforce bin/fm-pr-merge.sh --date 2026-10-25 >/dev/null 2>&1 \
    || fail "a complete entry was refused"
  assert_grep '## 2026-10-25 - never ship an unproven screen' "$surface" \
    "the recorded entry lost its date and title"
  assert_grep 'Enforced by: bin/fm-pr-merge.sh' "$surface" \
    "the recorded entry lost its enforcement point"
  assert_grep 'words: "never ship an unproven screen"' "$surface" \
    "the recorded entry lost the owner's verbatim words"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$RULES" add --words "never ship an unproven screen" --scope x --enforce bin/fm-pr-merge.sh >/dev/null 2>&1
  assert_not_equals 0 "$?" "the same owner words were recorded twice"
  pass "the seeded surface and a recorded entry carry the words, the date, the scope and the enforcer"
}

test_audit_flags_a_correction_left_in_a_private_note() {
  local home out rc
  home="$TMP_ROOT/audit"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" init >/dev/null 2>&1
  printf -- '- from tonight: he said "never use step 5 preview for anything at all" and I noted it here\n' \
    > "$home/data/learnings.md"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" audit 2>&1); rc=$?
  assert_equals 0 "$rc" "a findings report failed the default audit"
  assert_contains "$out" "$home/data/learnings.md" "the audit did not name the private note holding the quote"
  assert_contains "$out" "never use step 5 preview for anything at all" "the audit did not show the trapped words"
  assert_contains "$out" "fm-owner-rules.sh add" "the audit did not name the fix"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" audit --fail >/dev/null 2>&1
  assert_not_equals 0 "$?" "--fail did not fail on a trapped rule"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$RULES" add --words "never use step 5 preview for anything at all" --scope dispatch \
    --enforce bin/fm-dispatch-resolve.sh >/dev/null 2>&1
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$RULES" audit 2>&1)
  assert_contains "$out" "clean:" "recording the rule did not clear the audit"
  pass "a rule quoted only in a private note is flagged until the surface records it"
}

# Build a genuine primary home and a transcript holding one assistant reply.
make_guard_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  printf 'rule-test-home\n' > "$dir/.fm-secondmate-home"
}

reply_payload() {  # <dir> <reply text>
  local text
  text=${2//\\/\\\\}
  text=${text//\"/\\\"}
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$text" > "$1/reply.jsonl"
  printf '{"session_id":"s","transcript_path":"%s/reply.jsonl"}' "$1"
}

test_question_rule_blocks_until_a_card_is_cited() {
  local home payload board rc
  home="$TMP_ROOT/question"
  board="$TMP_ROOT/question-board"
  make_guard_home "$home"
  mkdir -p "$board"

  payload=$(reply_payload "$home" "The blocker cleared and the fix is in. Should I merge it?")
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    SIGN_OFF_HOME="$board" "$GUARD" >/dev/null 2>&1; rc=$?
  assert_equals 2 "$rc" "a reply ending in an unfiled question ended the turn unflagged"

  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    SIGN_OFF_HOME="$board" "$GUARD" >/dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "the same question was charged twice, which can wedge a harness"

  payload=$(reply_payload "$home" "Merged and cleaned up. Nothing outstanding.")
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    SIGN_OFF_HOME="$board" "$GUARD" >/dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "a reply that asks nothing was flagged"

  command -v sign-off-axi >/dev/null 2>&1 || {
    pass "the question rule blocks an unfiled question once, then clears (board half skipped: no sign-off-axi)"
    return 0
  }
  local key
  key=$(SIGN_OFF_HOME="$board" "$CARD" post --ask-ref chat-1 \
    --title "Should the fix merge now?" --why "The fix is green and in scope." \
    --outcome yes="It merges once the captain says so." --outcome no="It waits for his review." \
    --recommend yes --recommend-reason "His word is the merge call." --default no 2>/dev/null)
  [ -n "$key" ] || fail "fm-question-card.sh printed no board key"

  payload=$(reply_payload "$home" "The fix is green. Card $key on the board covers it - your call there.")
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    SIGN_OFF_HOME="$board" "$GUARD" >/dev/null 2>&1; rc=$?
  assert_equals 0 "$rc" "a reply citing an open board card was still flagged"

  local again
  again=$(SIGN_OFF_HOME="$board" "$CARD" post --ask-ref chat-1 \
    --title "Should the fix merge now?" --why "The fix is green and in scope." \
    --outcome yes="It merges once the captain says so." --outcome no="It waits for his review." \
    --recommend yes --recommend-reason "His word is the merge call." --default no 2>/dev/null)
  assert_equals "$key" "$again" "re-posting the same open question did not return the existing key"
  pass "an unfiled question is flagged once, and a cited open card clears it"
}

test_add_refuses_an_entry_it_cannot_enforce
test_seeded_surface_and_added_entry
test_audit_flags_a_correction_left_in_a_private_note
test_question_rule_blocks_until_a_card_is_cited

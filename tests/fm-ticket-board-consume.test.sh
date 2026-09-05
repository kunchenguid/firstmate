#!/usr/bin/env bash
# Behavior tests for bin/fm-ticket-board-consume.sh: extracting freeform
# `message` rows from a captured Lavish result via bin/fm-procevent-lavish.sh,
# ignoring non-message rows, appending tickets to the durable store,
# fail-closed publish-before-rebuild ordering, deduplicating a replayed
# result instead of duplicating a ticket, and distinguishing a provably
# empty result from one whose content could not be turned into a ticket.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSUME="$ROOT/bin/fm-ticket-board-consume.sh"
TMP_ROOT=$(fm_test_tmproot fm-ticket-board-consume)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # A realistic-enough stub of `lavish-axi <artifact> [--reopen]`: any
  # invocation reports a live, opened session, matching the exact `session:`
  # block shape a real open/reopen prints (verified live against lavish-axi
  # 0.1.x). bin/fm-ticket-board.sh's own build now parses this status field
  # rather than trusting exit code alone.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  file: %s\n  status: opened\n' "$1"
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

run_consume() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$CONSUME" "$@"
}

# A realistic captured result: the exact wire shape lavish-axi poll produces
# for a plain typed message, verified live against lavish-axi 0.1.x - field
# order uid,prompt,selector,tag,text, with `prompt` carrying the full sent
# text and `text` carrying only the generic "Freeform message" label.
write_message_result() {  # <path> <text-with-wire-escapes-already-applied>
  local escaped=$2
  escaped=${escaped//\"/\\\"}
  cat > "$1" <<EOF
[lavish-axi] Long-polling for user feedback.
session:
  file: /board.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "","$escaped","",message,Freeform message
next_step: "Apply the requested changes."
EOF
}

test_consume_extracts_a_message_and_appends_a_ticket() {
  local home result out store
  home=$(make_home basic)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" "Fix the login button color on Safari"

  out=$(run_consume "$home" "$result") || fail "consume failed on a well-formed message result"
  assert_contains "$out" "captured: 1" "consume did not report one captured message: $out"
  assert_contains "$out" "ticket: tkt-" "consume did not print the new ticket id: $out"
  assert_contains "$out" "Fix the login button color on Safari" "consume did not print the ticket title: $out"

  jq -e '.tickets | length == 1' "$store" >/dev/null || fail "the store does not have exactly one ticket"
  jq -e '.tickets[0].status == "backlog"' "$store" >/dev/null || fail "the new ticket is not in backlog"
  jq -e '.tickets[0].title == "Fix the login button color on Safari"' "$store" >/dev/null \
    || fail "the new ticket title does not match the sent text"
  jq -e '.tickets[0].body == "Fix the login button color on Safari"' "$store" >/dev/null \
    || fail "the new ticket body does not match the sent text"
  jq -e '.tickets[0].id | test("^tkt-[A-Za-z0-9._-]+$")' "$store" >/dev/null \
    || fail "the new ticket id is not a slug"
  assert_present "$home/.lavish/ticket-board.html" "consume did not rebuild the board"
  pass "consume extracts a freeform message and appends one backlog ticket"
}

test_consume_creates_the_store_when_absent() {
  local home result store
  home=$(make_home create-store)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" "First ticket ever"
  rm -f "$store"

  run_consume "$home" "$result" >/dev/null || fail "consume failed when the store did not exist yet"
  jq -e '.schema == "fm-ticket-board.v1" and (.tickets | length) == 1' "$store" >/dev/null \
    || fail "consume did not create a valid store carrying the new ticket"
  pass "consume creates the store on first use"
}

test_consume_splits_title_from_a_multiline_body() {
  local home result store
  home=$(make_home multiline)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" 'Login is broken\nSteps: open Safari, click login\nExpected: it works'

  run_consume "$home" "$result" >/dev/null || fail "consume failed on a multiline message"
  jq -e '.tickets[0].title == "Login is broken"' "$store" >/dev/null \
    || fail "title is not the first line: $(jq -c '.tickets[0]' "$store")"
  jq -e '.tickets[0].body | contains("Expected: it works")' "$store" >/dev/null \
    || fail "body dropped the later lines of a multiline message"
  jq -e '.tickets[0].body | contains("\n") | not' "$store" >/dev/null \
    || fail "body still carries a raw newline instead of being flattened"
  pass "consume derives the title from the first line and flattens the full body"
}

test_consume_truncates_multibyte_text_on_a_character_boundary() {
  local home result store title_len body_len
  home=$(make_home multibyte-truncation)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  # 4500 repetitions of the 3-byte CJK character U+3042 (あ): long enough to
  # straddle both the 200-char title cap and the 4000-char body cap at a
  # byte offset that falls mid-character, so a byte-based (not
  # character-based) substr would split a multi-byte sequence and corrupt
  # the trailing character.
  write_message_result "$result" "$(printf 'あ%.0s' {1..4500})"

  run_consume "$home" "$result" >/dev/null || fail "consume failed on long multi-byte text"
  title_len=$(jq -r '.tickets[0].title | length' "$store")
  body_len=$(jq -r '.tickets[0].body | length' "$store")
  [ "$title_len" -eq 200 ] || fail "title was not capped at 200 characters: got $title_len"
  [ "$body_len" -eq 4000 ] || fail "body was not capped at 4000 characters: got $body_len"
  jq -e '.tickets[0].title | test("�") | not' "$store" >/dev/null \
    || fail "title contains a replacement character - a multi-byte character was split"
  jq -e '.tickets[0].body | test("�") | not' "$store" >/dev/null \
    || fail "body contains a replacement character - a multi-byte character was split"
  jq -e '.tickets[0].title == ([range(200)] | map("あ") | join(""))' "$store" >/dev/null \
    || fail "title is not exactly 200 intact copies of the multi-byte character"
  pass "consume truncates multi-byte text on a character boundary, not a byte boundary"
}

test_consume_ignores_a_choice_row_alongside_a_message() {
  local home result store out
  home=$(make_home ignore-choice)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  cat > "$result" <<'EOF'
session:
  file: /board.html
  status: feedback
prompts[2]{uid,prompt,selector,tag,text}:
  "","Captain's Call answer","",choice,"Option A"
  "","Fix the header spacing","",message,Freeform message
EOF
  out=$(run_consume "$home" "$result") || fail "consume failed on a mixed choice+message result"
  assert_contains "$out" "captured: 1" "the choice row was not ignored alongside the message: $out"
  jq -e '.tickets | length == 1' "$store" >/dev/null || fail "the store does not have exactly one ticket"
  jq -e '.tickets[0].title == "Fix the header spacing"' "$store" >/dev/null \
    || fail "the ticket title does not match the message row, not the choice row"
  pass "consume ignores a choice row and still captures the message row beside it"
}

test_consume_accepts_a_provably_empty_ended_result() {
  local home result store out
  home=$(make_home provably-empty)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  printf 'session:\n  file: /board.html\n  status: ended\n  ended_by: user\n' > "$result"

  out=$(run_consume "$home" "$result") || fail "consume failed on a genuinely empty ended result"
  assert_contains "$out" "captured: 0" "a provably empty result was not reported as zero captured: $out"
  assert_absent "$store" "consume created a store for a result that carried no content at all"
  pass "consume accepts a provably empty result as the captain saying nothing"
}

test_consume_fails_when_content_present_but_no_message_rows() {
  local home result store rc out
  home=$(make_home content-no-messages)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  cat > "$result" <<'EOF'
session:
  file: /board.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "","Captain's Call answer","",choice,"Option A"
EOF
  set +e; out=$(run_consume "$home" "$result" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "consume silently accepted content-bearing rows with no captured tickets: $out"
  assert_contains "$out" "captured: 0" "consume did not report the zero-message parse before failing: $out"
  assert_contains "$out" "no ticket rows were captured" "the failure did not explain the mismatch: $out"
  assert_absent "$store" "consume created a store despite failing to explain unparsed content"
  pass "consume fails loudly when content is present but no ticket rows were captured, instead of reporting silence"
}

test_consume_fails_when_a_row_is_truncated_alongside_a_valid_message() {
  local home result store rc out
  home=$(make_home truncated-row)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  # The declared count says 2 rows; the second row's write was cut off
  # mid-field (missing selector/tag/text and its closing quote), the shape a
  # capture takes when the underlying write did not finish. A parser that
  # silently drops the row it cannot fully parse would still emit the first,
  # well-formed row, report a nonzero captured count, and bypass the
  # zero-captured content-mismatch check entirely - losing the second
  # captain-typed ticket without any error surfaced anywhere.
  cat > "$result" <<'EOF'
session:
  file: /board.html
  status: feedback
prompts[2]{uid,prompt,selector,tag,text}:
  "","Fix the header spacing","",message,Freeform message
  "","Second ticket text
EOF
  set +e; out=$(run_consume "$home" "$result" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "consume silently accepted a truncated row instead of failing loudly: $out"
  assert_absent "$store" "consume created a store despite an unparseable captured row"
  pass "consume fails loudly on a truncated row instead of silently losing the ticket beside a valid one"
}

test_consume_refuses_a_missing_result_file() {
  local home rc out
  home=$(make_home missing-result)
  set +e; out=$(run_consume "$home" "$home/does-not-exist.txt" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "consume accepted a missing result file"
  assert_contains "$out" "does not exist" "the missing-result refusal did not say why: $out"
  pass "consume refuses a missing result file"
}

test_consume_publishes_the_store_even_when_the_rebuild_fails() {
  local home first second store rc out
  home=$(make_home rebuild-failure)
  # Two distinct result files, matching how two real captured results always
  # land at two distinct sequence-numbered paths - never the same file
  # rewritten in place, which is reserved for a genuine replay (see
  # test_consume_ignores_a_replayed_result_instead_of_duplicating_the_ticket).
  first="$home/result.1.result"
  second="$home/result.2.result"
  store="$home/data/tickets.json"
  write_message_result "$first" "First ticket"
  run_consume "$home" "$first" >/dev/null || fail "the first consume failed"

  write_message_result "$second" "Second ticket, but the board session will fail"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e; out=$(run_consume "$home" "$second" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "consume reported success despite a failed rebuild"
  assert_contains "$out" "the store was published but the board rebuild failed" \
    "the failure did not explain that the store was still published: $out"
  jq -e '.tickets | length == 2' "$store" >/dev/null \
    || fail "consume lost the second ticket instead of publishing the store before the failed rebuild: $(cat "$store")"
  pass "consume publishes a captain-typed ticket to the durable store even when the following board rebuild fails"
}

test_consume_ignores_a_replayed_result_instead_of_duplicating_the_ticket() {
  local home result store out
  home=$(make_home replay)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" "Fix the flaky login test"

  out=$(run_consume "$home" "$result") || fail "the first consume failed"
  assert_contains "$out" "ticket: tkt-" "the first consume did not create a ticket: $out"
  jq -e '.tickets | length == 1' "$store" >/dev/null \
    || fail "the first consume did not leave exactly one ticket"

  # A captured result stays eligible for bounded re-announcement until firstmate
  # durably acknowledges it, so the same result file can be consumed again -
  # this must never mint a second ticket for the same captain message.
  out=$(run_consume "$home" "$result") || fail "replaying the same result failed"
  assert_contains "$out" "skipped: 1 already-recorded row" "the replay was not recognized as already recorded: $out"
  assert_not_contains "$out" "ticket: tkt-" "the replay minted a new ticket instead of skipping the recorded row: $out"
  jq -e '.tickets | length == 1' "$store" >/dev/null \
    || fail "replaying the same result duplicated the ticket: $(jq -c '[.tickets[] | {id,title}]' "$store")"
  pass "consume deduplicates a replayed result instead of duplicating the ticket"
}

test_consume_extracts_a_message_and_appends_a_ticket
test_consume_creates_the_store_when_absent
test_consume_splits_title_from_a_multiline_body
test_consume_truncates_multibyte_text_on_a_character_boundary
test_consume_ignores_a_choice_row_alongside_a_message
test_consume_accepts_a_provably_empty_ended_result
test_consume_fails_when_content_present_but_no_message_rows
test_consume_fails_when_a_row_is_truncated_alongside_a_valid_message
test_consume_refuses_a_missing_result_file
test_consume_publishes_the_store_even_when_the_rebuild_fails
test_consume_ignores_a_replayed_result_instead_of_duplicating_the_ticket

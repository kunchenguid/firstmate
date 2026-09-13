#!/usr/bin/env bash
# Behavior tests for bin/fm-gram.sh, the automatic Gram intake poll.
#
# Everything is driven through the executable interface against a fake `herdr`
# on PATH that answers `gram list` with the documented JSON shape. No case ever
# contacts a real Herdr server, and no case ever writes to a Gram store: the
# machine Gram store is shared with the owner's app, so a live write here would
# reach a real person.
#
# The cases that matter are the ones a silent failure would cost most:
#   * only owner messages ADDRESSED to this home are taken, never shared queue
#     items and never this fleet's own messages;
#   * the store+id cursor publishes a message exactly once across repeat polls;
#   * a missing pane identity is reported rather than read as an empty inbox;
#   * a failing or hanging Herdr is a bounded, actionable line, not a storm;
#   * message bodies never reach stdout.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GRAM="$ROOT/bin/fm-gram.sh"
TMP_ROOT=$(fm_test_tmproot fm-gram)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# make_home <name>: a scratch home wired to the real inbox and wake libraries,
# so a published note takes the same path it takes in a real home.
make_home() {
  local name=$1 home lib
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/bin"
  for lib in fm-inbox.sh fm-wake-lib.sh fm-timeout-lib.sh; do
    [ -e "$home/bin/$lib" ] || ln -s "$ROOT/bin/$lib" "$home/bin/$lib"
  done
  printf '%s\n' "$home"
}

# fake_herdr <json>: a `herdr` whose `gram list` prints <json> and exits 0.
fake_herdr() {
  local json=$1
  cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = gram ] || exit 2
cat <<'JSON'
$json
JSON
SH
  chmod +x "$FAKEBIN/herdr"
}

# fake_herdr_raw <body>: a `herdr` whose `gram list` runs <body> verbatim.
fake_herdr_raw() {
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"
}

msg() {  # <id> <direction> <to> <text> <created>
  printf '{"id":"%s","direction":"%s","from":"owner","to":%s,"text":"%s","created_unix_ms":%s,"read_by_owner":false}' \
    "$1" "$2" "$3" "$4" "$5"
}

store_json() {  # <messages-json...>
  local IFS=,
  printf '{"id":"cli:gram:list","result":{"digest":"d","store_id":"machine_test","messages":[%s],"type":"gram_list"}}' "$*"
}

run_poll() {  # <home> <out> [extra env...]
  local home=$1 out=$2
  shift 2
  local status=0
  env "$@" FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    "$GRAM" poll >"$out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

notes_of() {  # <home>
  local n count=0
  for n in "$1"/state/inbox/*.note; do
    [ -e "$n" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

note_bodies() {  # <home>
  cat "$1"/state/inbox/*.note 2>/dev/null || true
}

captures_of() {  # <home>
  local c count=0
  for c in "$1"/state/gram-inbox/*.json; do
    [ -e "$c" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# Everything this home holds that could still contain the owner's words. Scanning
# the WHOLE home is the point: an earlier version of this helper listed only
# gram-inbox/ and inbox/, so its "no copy survives anywhere" assertion could not
# see the body the wake-queue row carries and could not fail. Any new sink a
# future change adds is caught here without anyone remembering to extend a list.
retained_text() {  # <home>
  find "$1" -type f -exec cat {} + 2>/dev/null || true
}

wake_rows() {  # <home>
  cat "$1/state/.wake-queue" 2>/dev/null || true
}

test_help_and_usage() {
  local out rc=0
  out=$("$GRAM" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "poll" "--help lists the poll action"
  rc=0
  out=$("$GRAM" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-gram: help and usage plumbing"
}

test_only_addressed_owner_messages_are_taken() {
  local home out status
  home=$(make_home eligibility)
  fake_herdr "$(store_json \
    "$(msg gram-addressed owner_to_agent '"firstmate"' 'please look at the deploy' 1000)" \
    "$(msg gram-shared owner_to_agent 'null' 'anyone free to triage' 2000)" \
    "$(msg gram-mine agent_to_owner 'null' 'my own earlier report' 3000)")"
  out="$home/out.txt"
  status=$(run_poll "$home" "$out" HERDR_PANE_ID=w1:p1)
  expect_code 0 "$status" "poll exit"
  assert_equals 1 "$(notes_of "$home")" "exactly the one addressed message becomes a note"
  assert_contains "$(note_bodies "$home")" "please look at the deploy" "the addressed message reaches the inbox"
  assert_not_contains "$(note_bodies "$home")" "anyone free to triage" \
    "a shared queue item is never auto-claimed"
  assert_not_contains "$(note_bodies "$home")" "my own earlier report" \
    "this fleet's own message is never read back in"
  assert_contains "$(cat "$out")" "1 new Gram message" "the poll reports the new message"
  pass "fm-gram: only owner messages addressed to this home are taken"
}

test_message_bodies_never_reach_stdout() {
  local home out
  home=$(make_home confidential)
  fake_herdr "$(store_json "$(msg gram-secret owner_to_agent '"firstmate"' 'the passphrase is hunter2' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_not_contains "$(cat "$out")" "hunter2" "the poll never prints a message body"
  assert_contains "$(note_bodies "$home")" "hunter2" "the body is still delivered privately"
  pass "fm-gram: message bodies stay out of the poll's own output"
}

test_repeat_polls_publish_each_message_once() {
  local home out first second
  home=$(make_home cursor)
  fake_herdr "$(store_json "$(msg gram-1 owner_to_agent '"firstmate"' 'first request' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  first=$(notes_of "$home")
  assert_equals 1 "$first" "the first poll publishes the message"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  second=$(notes_of "$home")
  assert_equals 1 "$second" "a repeat poll over the same store does not publish it again"
  assert_equals "" "$(cat "$out")" "a poll with nothing new is silent"

  # A NEW message in the same store still gets through after the cursor exists.
  fake_herdr "$(store_json \
    "$(msg gram-1 owner_to_agent '"firstmate"' 'first request' 1000)" \
    "$(msg gram-2 owner_to_agent '"firstmate"' 'second request' 2000)")"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 2 "$(notes_of "$home")" "a later message is still published"
  pass "fm-gram: the store+id cursor publishes each message once and does not block later ones"
}

test_same_id_in_a_different_store_is_not_suppressed() {
  local home out
  home=$(make_home store_key)
  fake_herdr "$(store_json "$(msg gram-1 owner_to_agent '"firstmate"' 'from store A' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 1 "$(notes_of "$home")" "store A message published"
  fake_herdr_raw 'cat <<'"'"'JSON'"'"'
{"id":"cli:gram:list","result":{"digest":"d","store_id":"machine_other","messages":[{"id":"gram-1","direction":"owner_to_agent","from":"owner","to":"firstmate","text":"from store B","created_unix_ms":1000}],"type":"gram_list"}}
JSON'
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 2 "$(notes_of "$home")" "the same id in a different store is a different message"
  pass "fm-gram: the cursor is keyed by store as well as id"
}

test_missing_pane_identity_is_reported_not_read_as_empty() {
  local home out status
  home=$(make_home no_identity)
  fake_herdr "$(store_json)"
  out="$home/out.txt"
  # shellcheck disable=SC2016 # $0/$1/$? must expand inside the child sh, not here.
  status=$(env -u HERDR_PANE_ID FM_HOME="$home" PATH="$FAKEBIN:$PATH" \
    sh -c '"$0" poll >"$1" 2>&1; echo $?' "$GRAM" "$out")
  expect_code 1 "$status" "a home with no pane identity must fail loudly"
  assert_contains "$(cat "$out")" "HERDR_PANE_ID" "the missing identity is named"
  assert_contains "$(cat "$out")" "not running" "the report says intake is not running"
  pass "fm-gram: no pane identity is reported, never read as an empty inbox"
}

test_failing_herdr_is_one_bounded_line() {
  local home out status
  home=$(make_home failing)
  fake_herdr_raw 'echo "{\"error\":{\"code\":\"gram_unavailable\"}}"; exit 1'
  out="$home/out.txt"
  status=$(run_poll "$home" "$out" HERDR_PANE_ID=w1:p1)
  expect_code 1 "$status" "a failing herdr must exit non-zero"
  assert_contains "$(cat "$out")" "gram_unavailable" "the reported line names the herdr error code"
  assert_equals 1 "$(grep -c . "$out")" "a failure is exactly one line, never a storm"
  assert_equals 0 "$(notes_of "$home")" "a failed poll publishes nothing"
  pass "fm-gram: an unavailable Gram channel is one bounded actionable line"
}

test_hanging_herdr_is_bounded_by_the_budget() {
  local home out status
  home=$(make_home hanging)
  fake_herdr_raw 'sleep 30'
  out="$home/out.txt"
  status=$(run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 FM_GRAM_BUDGET=2)
  expect_code 1 "$status" "a hanging herdr must not hang the poll"
  assert_contains "$(cat "$out")" "did not finish" "the timeout is reported"
  pass "fm-gram: a hanging Herdr call is bounded by the budget"
}

test_missing_store_id_refuses_rather_than_deduplicating_blind() {
  local home out status
  home=$(make_home no_store)
  fake_herdr_raw 'echo "{\"id\":\"cli:gram:list\",\"result\":{\"messages\":[]}}"'
  out="$home/out.txt"
  status=$(run_poll "$home" "$out" HERDR_PANE_ID=w1:p1)
  expect_code 1 "$status" "a response with no store id must fail loudly"
  assert_contains "$(cat "$out")" "store id" "the missing store id is named"
  pass "fm-gram: no store id means no blind deduplication"
}

test_capture_is_private_and_written_before_publication() {
  local home out capture mode
  home=$(make_home capture)
  fake_herdr "$(store_json "$(msg gram-cap owner_to_agent '"firstmate"' 'captured body' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  capture=$(find "$home/state/gram-inbox" -name '*.json' -print -quit 2>/dev/null)
  [ -n "$capture" ] || fail "the poll must capture the message privately"
  assert_contains "$(cat "$capture")" "captured body" "the capture holds the owner's words"
  mode=$(fm_pr_file_mode_or_stat "$capture" 2>/dev/null || stat -f %Lp "$capture" 2>/dev/null || stat -c %a "$capture")
  assert_equals 600 "$mode" "the capture is owner-only"
  pass "fm-gram: each message is captured privately before it is published"
}

# `herdr gram delete` is documented as the way to purge a short-lived secret, so
# a capture or note that outlived the owner's deletion would quietly break that
# advice. The next poll is what honours it.
test_deleting_a_message_purges_the_local_copy() {
  local home out
  home=$(make_home purge)
  fake_herdr "$(store_json "$(msg gram-secret owner_to_agent '"firstmate"' 'the passphrase is hunter2' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 1 "$(captures_of "$home")" "the message is captured first"
  assert_contains "$(retained_text "$home")" "hunter2" "and its body is held locally"

  # The wake row fm-inbox.sh queued carries the first hundred characters of the
  # body, so it is a third durable copy the purge has to reach.
  assert_contains "$(wake_rows "$home")" "hunter2" "the queued wake row carries the body too"

  # The owner deletes it: the store still exists, the message no longer does.
  fake_herdr "$(store_json)"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 0 "$(captures_of "$home")" "the capture is removed once the message is gone"
  assert_equals 0 "$(notes_of "$home")" "the note it produced is removed too"
  assert_not_contains "$(wake_rows "$home")" "hunter2" "the queued wake row is dropped too"
  assert_not_contains "$(retained_text "$home")" "hunter2" \
    "no copy of a deleted message survives anywhere in the home"
  pass "fm-gram: deleting a Gram message purges this home's capture, note, and wake row"
}

# The wake queue is durable supervision state: dropping the wrong row loses a
# wake permanently, so the purge must take out its own row and leave every other
# row untouched, sequence number included.
test_a_purge_drops_only_its_own_wake_row() {
  local home out before after
  home=$(make_home purge_row_scope)
  # An unrelated wake queued through the real library, exactly as the watcher
  # would queue it, before any Gram message exists.
  FM_HOME="$home" bash -c '
    . "$1"
    fm_wake_append signal "t1.status" "signal: t1.status changed"
  ' _ "$home/bin/fm-wake-lib.sh" >/dev/null 2>&1 \
    || fail "could not queue the unrelated wake"
  before=$(wake_rows "$home")
  assert_contains "$before" "t1.status" "the unrelated wake is queued"

  fake_herdr "$(store_json "$(msg gram-row owner_to_agent '"firstmate"' 'purge my row' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_contains "$(wake_rows "$home")" "purge my row" "the Gram wake row is queued"

  fake_herdr "$(store_json)"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  after=$(wake_rows "$home")
  assert_not_contains "$after" "purge my row" "the purged message's row is gone"
  assert_equals "$before" "$after" \
    "every other queued row survives the purge byte-identically, sequence included"
  pass "fm-gram: a purge drops only its own wake row and leaves the queue otherwise intact"
}

# A drain can present a Gram wake and then race the purge that removes its note.
# Acknowledging a note that is already gone must read as already handled rather
# than failing, or the handling turn cannot complete its own acknowledgement.
test_acking_a_purged_note_degrades_cleanly() {
  local home out note rc=0 ack
  home=$(make_home purge_ack_race)
  fake_herdr "$(store_json "$(msg gram-race owner_to_agent '"firstmate"' 'race me' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  note=$(basename "$(find "$home/state/inbox" -maxdepth 1 -name '*.note' -print -quit)" .note)
  [ -n "$note" ] || fail "the poll must have produced a note to ack"

  fake_herdr "$(store_json)"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  ack=$(FM_HOME="$home" "$ROOT/bin/fm-inbox.sh" drain --ack "$note" 2>&1) || rc=$?
  expect_code 0 "$rc" "acking a purged note must not fail the handling turn"
  assert_contains "$ack" "already-acked $note" "a purged note reads as already handled"
  pass "fm-gram: acknowledging a note the purge already removed degrades cleanly"
}

test_a_purged_message_is_never_republished() {
  local home out
  home=$(make_home purge_cursor)
  fake_herdr "$(store_json "$(msg gram-gone owner_to_agent '"firstmate"' 'delete me later' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  fake_herdr "$(store_json)"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 0 "$(notes_of "$home")" "the purge cleared the note"
  # The store shows it again (a restored backup, a renumbered store): the cursor
  # must still suppress it, because the owner already saw it once.
  fake_herdr "$(store_json "$(msg gram-gone owner_to_agent '"firstmate"' 'delete me later' 1000)")"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 0 "$(notes_of "$home")" "a purged message is never published a second time"
  pass "fm-gram: the seen cursor outlives the purge, so nothing is re-published"
}

# The purge reads absence from one audience's listing, so it must never reach
# past the store that listing describes.
test_a_purge_never_touches_another_stores_capture() {
  local home out
  home=$(make_home purge_scope)
  fake_herdr "$(store_json "$(msg gram-a owner_to_agent '"firstmate"' 'store A body' 1000)")"
  out="$home/out.txt"
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 1 "$(captures_of "$home")" "store A message captured"
  fake_herdr_raw 'cat <<'"'"'JSON'"'"'
{"id":"cli:gram:list","result":{"digest":"d","store_id":"machine_other","messages":[{"id":"gram-b","direction":"owner_to_agent","from":"owner","to":"firstmate","text":"store B body","created_unix_ms":1000}],"type":"gram_list"}}
JSON'
  run_poll "$home" "$out" HERDR_PANE_ID=w1:p1 >/dev/null
  assert_equals 2 "$(captures_of "$home")" "a poll of store B leaves store A's capture alone"
  assert_contains "$(retained_text "$home")" "store A body" "store A's body is untouched"
  pass "fm-gram: a purge is scoped to the store the listing describes"
}

test_help_and_usage
test_only_addressed_owner_messages_are_taken
test_message_bodies_never_reach_stdout
test_repeat_polls_publish_each_message_once
test_same_id_in_a_different_store_is_not_suppressed
test_missing_pane_identity_is_reported_not_read_as_empty
test_failing_herdr_is_one_bounded_line
test_hanging_herdr_is_bounded_by_the_budget
test_missing_store_id_refuses_rather_than_deduplicating_blind
test_capture_is_private_and_written_before_publication
test_deleting_a_message_purges_the_local_copy
test_a_purge_drops_only_its_own_wake_row
test_acking_a_purged_note_degrades_cleanly
test_a_purged_message_is_never_republished
test_a_purge_never_touches_another_stores_capture

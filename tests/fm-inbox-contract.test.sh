#!/usr/bin/env bash
# tests/fm-inbox-contract.test.sh - the generic captain-message ingress contract.
#
# bin/fm-inbox.sh is the surface an external tool (the sheets bridge) uses to
# hand firstmate a message and later read back what became of it. These tests
# drive the real executable against an isolated home and pin:
#   1. `note` prints the id later calls address the note by.
#   2. `outcome <id> <text>` records a durable result summary for that note,
#      from arguments or stdin, and appends NO wake.
#   3. A second outcome for the same note replaces the first (latest wins).
#   4. `list --json` exports every note, pending or handled, newest first,
#      each as {"id","state","outcome","outcome_at"} with nulls when no
#      outcome was recorded, and valid JSON always (verified with python3).
#   5. A note without an outcome stays valid and exports with null fields.
#   6. An outcome for an unknown id is refused, non-zero, and records nothing.
#   7. An empty or whitespace-only outcome body is refused.
#   8. Outcome text survives the JSON round-trip byte-exact (quotes, backslashes,
#      newlines).
#   9. An empty inbox exports [].
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INBOX="$ROOT/bin/fm-inbox.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox-contract)

# An isolated operational home: state/ and data/ resolve through FM_HOME so
# nothing here can reach the operator's real home.
make_home() {  # <name> -> echoes a fresh fixture home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  printf '%s\n' "$home"
}

HOME_FIXTURE=$(make_home home-a)

run_inbox() {  # <args...> -> stdout, exit code preserved in $?
  FM_HOME="$HOME_FIXTURE" FM_STATE_OVERRIDE="$HOME_FIXTURE/state" \
    FM_DATA_OVERRIDE="$HOME_FIXTURE/data" "$INBOX" "$@"
}

queue_note() {  # <text> -> echoes the queued note id
  local out
  out=$(run_inbox note "$1") || fail "note failed: $out"
  sed -n 's/^queued //p' <<<"$out"
}

# ---------------------------------------------------------------- note + outcome

id=$(queue_note "first real note")
[ -n "$id" ] || fail "note did not print a queueable id"
pass "note prints the id later calls address the note by"

out=$(run_inbox outcome "$id" "processed the thing, all good")
assert_contains "$out" "recorded outcome for $id" \
  "outcome should confirm the note it recorded for"
wakes=$(grep -c 'inbox:' "$HOME_FIXTURE/state/.wake-queue" 2>/dev/null || true)
assert_equals 1 "$wakes" "outcome must not append a wake (note's single wake expected)"
pass "outcome records durably and appends no wake"

# ---------------------------------------------------------------- latest wins

run_inbox outcome "$id" "first version of the summary" >/dev/null
run_inbox outcome "$id" "second version wins" >/dev/null
json=$(run_inbox list --json)
assert_not_contains "$json" "first version of the summary" \
  "a second outcome must replace the first, not accumulate"
assert_contains "$json" "second version wins" "latest outcome must be exported"
pass "a re-recorded outcome replaces the earlier one (latest wins)"

# ---------------------------------------------------------------- export schema

id2=$(queue_note "note with no outcome yet")
json=$(run_inbox list --json)
ID1="$id" ID2="$id2" python3 - "$json" <<'PY' || fail "list --json must emit a stable, valid schema"
import json, os, sys
notes = json.loads(sys.argv[1])
assert isinstance(notes, list) and len(notes) == 2, notes
by_id = {n["id"]: n for n in notes}
assert set(by_id) == {os.environ["ID1"], os.environ["ID2"]}, by_id
assert notes[0]["id"] == os.environ["ID2"], "newest note must export first"
first = by_id[os.environ["ID1"]]
assert first["state"] == "pending", first
assert first["outcome"] == "second version wins", first
assert first["outcome_at"], first
second = by_id[os.environ["ID2"]]
assert second["state"] == "pending", second
assert second["outcome"] is None, second
assert second["outcome_at"] is None, second
PY
pass "list --json exports a stable schema with nulls for outcomeless notes"

# ---------------------------------------------------------------- handled notes

run_inbox drain --ack "$id2" >/dev/null
run_inbox outcome "$id2" "closed after handling" >/dev/null
json=$(run_inbox list --json)
assert_contains "$json" "\"state\":\"handled\"" \
  "an acked note must export as handled, not disappear"
assert_contains "$json" "closed after handling" \
  "an outcome for a handled note must still export"
pass "handled notes export with state=handled and their outcome"

# ---------------------------------------------------------------- invalid id

before=$(run_inbox list --json)
out=$(run_inbox outcome "no-such-note" "text" 2>&1)
expect_code 1 "$?" "outcome for an unknown id must exit non-zero"
assert_contains "$out" "no such note" "outcome for an unknown id must name the problem"
assert_equals "$before" "$(run_inbox list --json)" \
  "a rejected outcome must record nothing"
pass "outcome for an unknown id is refused and records nothing"

# ---------------------------------------------------------------- empty body

out=$(run_inbox outcome "$id" "   " 2>&1)
expect_code 1 "$?" "a whitespace-only outcome must exit non-zero"
assert_contains "$out" "empty outcome" "an empty outcome must name the problem"
pass "an empty outcome body is refused"

# ---------------------------------------------------------------- stdin + escaping

printf 'line one\nline two with "quotes" and \\ backslash' \
  | run_inbox outcome "$id" - >/dev/null
json=$(run_inbox list --json)
ID1="$id" python3 - "$json" <<'PY' || fail "outcome text must survive the JSON round-trip byte-exact"
import json, os, sys
notes = json.loads(sys.argv[1])
body = next(n["outcome"] for n in notes if n["id"] == os.environ["ID1"])
assert body == 'line one\nline two with "quotes" and \\ backslash', repr(body)
PY
pass "stdin outcome bodies round-trip byte-exact through list --json"

# ---------------------------------------------------------------- empty export

HOME_FIXTURE=$(make_home home-b)
json=$(run_inbox list --json)
assert_equals "[]" "$json" "an empty inbox must export an empty JSON array"
pass "list --json on an empty inbox emits []"

printf 'fm-inbox-contract: all cases passed\n'
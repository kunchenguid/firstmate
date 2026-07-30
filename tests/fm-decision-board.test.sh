#!/usr/bin/env bash
# Behavior tests for the captain decision board renderer over the canonical
# fleet snapshot. Covers source selection (captain-owned open items only), the
# one-entry-per-id merge of a durable queue entry with a parked worker, the
# ready/gated split including the parked override, longest-waiting ordering,
# bounding with disclosure, all three output formats, HTML escaping of backlog
# text, captain-facing path presentation, and the difference between an empty
# board and an unreadable source.
#
# Every assertion runs through the script's own interface with a fixture
# snapshot supplied via --snapshot, which is the documented public contract
# boundary; no test reads the implementation source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-decision-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-board)
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

export FM_DECISION_BOARD_NOW=2026-07-30T09:00:00Z

# A fixture in the fm-fleet-snapshot.v1 shape, carrying every case the board
# must distinguish:
#   old-ask     captain-owned, unblocked, longest waiting
#   new-ask     captain-owned, unblocked, newest
#   gated-ask   captain-owned but waiting on unfinished work
#   both-ask    captain-owned AND a worker parked on it despite a blocker
#   parked-only a parked worker with no captain-owned queue entry
#   blocker-only a firstmate-owned blocked event, never a captain decision
#   external    a non-captain hold, must never reach the board
#   settled     a captain-owned entry already done, must never reach the board
#   markup      backlog text containing HTML, for escaping
write_snapshot() {  # <path>
  cat > "$1" <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "fm_home": "/home/fixture/firstmate",
  "generated": "2026-07-30T09:00:00Z",
  "backlog": {
    "path": "/home/fixture/firstmate/data/backlog.md",
    "present": true,
    "records": [
      {
        "id": "old-ask", "structured": true, "state": "queued", "kind": "captain",
        "title": "Approve the drive prune", "repo": "machine",
        "hold_kind": "captain", "hold_reason": "the plan is ready and needs your word",
        "since": "2026-07-10", "unresolved_blocker_ids": []
      },
      {
        "id": "new-ask", "structured": true, "state": "queued", "kind": "captain",
        "title": "Pick the booking stack", "repo": "/home/fixture/ventures/phone-assistant",
        "hold_kind": "captain", "hold_reason": "two vendors, one choice",
        "since": "2026-07-29", "unresolved_blocker_ids": []
      },
      {
        "id": "gated-ask", "structured": true, "state": "queued", "kind": "captain",
        "title": "Arm the cadence", "repo": "cartoon-longform",
        "hold_kind": "captain", "hold_reason": "cadence arms after the quality bar clears",
        "since": "2026-07-20", "unresolved_blocker_ids": ["quality-program"]
      },
      {
        "id": "both-ask", "structured": true, "state": "in_flight", "kind": "ship",
        "title": "Rethink the media model", "repo": "x-bookmark-poster",
        "hold_kind": "captain", "hold_reason": "the data model needs a rethink, not another patch",
        "since": "2026-07-22", "unresolved_blocker_ids": ["feed-model"]
      },
      {
        "id": "markup", "structured": true, "state": "queued", "kind": "captain",
        "title": "Publish <script>alert(1)</script> copy", "repo": "portfolio-site",
        "hold_kind": "captain", "hold_reason": "wording uses <b>markup</b> & entities",
        "since": "2026-07-28", "unresolved_blocker_ids": []
      },
      {
        "id": "external", "structured": true, "state": "queued", "kind": "ship",
        "title": "Wait on the upstream release", "repo": "machine",
        "hold_kind": "external", "hold_reason": "upstream has not shipped",
        "since": "2026-07-01", "unresolved_blocker_ids": []
      },
      {
        "id": "settled", "structured": true, "state": "done", "kind": "captain",
        "title": "Already answered", "repo": "machine",
        "hold_kind": "captain", "hold_reason": "he answered this one",
        "since": "2026-07-02", "unresolved_blocker_ids": []
      }
    ]
  },
  "tasks": [
    {
      "id": "both-ask",
      "project": "/home/fixture/ventures/x-bookmark-poster",
      "backlog": {"title": "Rethink the media model", "repo": "x-bookmark-poster", "since": "2026-07-22"},
      "hints": {
        "pending_decision": true,
        "open_decisions": [{"key": "default", "verb": "needs-decision",
                            "summary": "the third review round repeats the same family of findings"},
                           {"key": "upstream", "verb": "blocked",
                            "summary": "firstmate must repair the upstream dependency"}]
      }
    },
    {
      "id": "parked-only",
      "project": "/home/fixture/ventures/polymarket-platform-dev",
      "backlog": null,
      "hints": {
        "pending_decision": true,
        "open_decisions": [{"key": "default", "verb": "needs-decision",
                            "summary": "a lost confirm can leave admission released"}]
      }
    },
    {
      "id": "blocker-only",
      "project": "/home/fixture/ventures/blocked",
      "backlog": null,
      "hints": {
        "pending_decision": false,
        "open_decisions": [{"key": "default", "verb": "blocked",
                            "summary": "firstmate owns this blocked task"}]
      }
    },
    {
      "id": "quiet-worker",
      "project": "/home/fixture/ventures/quiet",
      "backlog": null,
      "hints": {"pending_decision": false, "open_decisions": []}
    }
  ]
}
JSON
}

SNAP="$TMP_ROOT/snapshot.json"
write_snapshot "$SNAP"

# --- source selection -------------------------------------------------------

out=$("$BOARD" --snapshot "$SNAP" --limit 0)
assert_contains "$out" "old-ask" "an open captain-owned entry must reach the board"
assert_not_contains "$out" "external" "a non-captain hold must never reach the board"
assert_not_contains "$out" "settled" "an already-answered entry must never reach the board"
assert_not_contains "$out" "quiet-worker" "a worker with no open decision must not reach the board"
assert_not_contains "$out" "blocker-only" "a firstmate-owned blocker must not reach the board"
assert_not_contains "$out" "firstmate must repair" \
  "a firstmate-owned blocker must not join a captain decision summary"
pass "the board carries only open captain-owned items"

# --- one entry per id -------------------------------------------------------

TICK='`'  # the rendered id delimiter, kept in a variable so patterns stay literal
count=$(printf '%s\n' "$out" | grep -c -F "${TICK}both-ask${TICK}")
[ "$count" = 1 ] || fail "an id in both sources must render exactly one entry (got $count)"
assert_contains "$out" "the data model needs a rethink" "the durable wording must survive the merge"
assert_contains "$out" "the third review round repeats" "the parked worker's note must survive the merge"
pass "an id in both sources becomes one entry carrying both facts"

# --- ready versus waiting-on-other-work -------------------------------------

ready_block=${out%%### Waiting on other work first*}
gated_block=${out#*### Waiting on other work first}
assert_contains "$ready_block" "old-ask" "an unblocked captain-owned entry needs only his answer"
assert_contains "$gated_block" "gated-ask" "an entry waiting on unfinished work must be separated"
assert_not_contains "$ready_block" "gated-ask" "a blocked entry must not claim to need only his answer"
assert_contains "$ready_block" "both-ask" "a parked worker needs his answer even with a dependency"
assert_contains "$ready_block" "parked-only" "a parked worker with no queue entry must still reach him"
assert_contains "$out" "quality-program" "a remaining dependency must still be named"
pass "the ready split honors dependencies and the parked override"

# --- displayed numbering ---------------------------------------------------

numbers=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\)\. \*\*.*/\1/p')
number_count=$(printf '%s\n' "$numbers" | sed '/^$/d' | wc -l | tr -d ' ')
unique_number_count=$(printf '%s\n' "$numbers" | sed '/^$/d' | sort -nu | wc -l | tr -d ' ')
first_gated_number=$(printf '%s\n' "$gated_block" | sed -n 's/^\([0-9][0-9]*\)\. \*\*.*/\1/p' | head -1)
[ "$first_gated_number" = 6 ] \
  || fail "the gated section must continue after the five ready entries (got $first_gated_number)"
[ "$number_count" = "$unique_number_count" ] \
  || fail "displayed numbers must not repeat across the whole board"
pass "markdown numbering continues across both sections"

# --- ordering ---------------------------------------------------------------

order=$(printf '%s\n' "$ready_block" | grep -o -E "${TICK}[a-z-]+${TICK}" | tr -d "$TICK")
first=$(printf '%s\n' "$order" | head -1)
[ "$first" = old-ask ] || fail "the longest-waiting entry must sort first (got $first)"
last=$(printf '%s\n' "$order" | tail -1)
[ "$last" != old-ask ] || fail "ordering must place the newest ask after the longest-waiting one"
assert_contains "$out" "waiting 20 days" "elapsed waiting time must be reported"
pass "entries sort longest-waiting first"

# --- captain-facing presentation --------------------------------------------

assert_not_contains "$out" "/home/fixture/ventures" "a raw path must not reach a captain-facing surface"
assert_contains "$out" "phone-assistant" "the project must still be named"
assert_not_contains "$out" "hold_kind" "internal field names must not reach a captain-facing surface"
pass "presentation stays captain-facing"

# --- bounding with disclosure ----------------------------------------------

bounded=$("$BOARD" --snapshot "$SNAP" --limit 2)
assert_contains "$bounded" "not shown" "a bounded board must disclose what it dropped"
assert_contains "$bounded" "--limit 0" "the disclosure must name how to reveal the rest"
shown=$(printf '%s\n' "$bounded" | grep -c -E '^[0-9]+\. \*\*')
[ "$shown" -le 4 ] || fail "--limit 2 must cap each group at two entries (got $shown)"
assert_contains "$bounded" "Needs your answer (5)" "the true open count must survive bounding"
pass "bounding caps entries while disclosing the remainder"

# --- json format ------------------------------------------------------------

model=$("$BOARD" --snapshot "$SNAP" --format json --limit 0)
schema=$(printf '%s' "$model" | jq -r '.schema')
[ "$schema" = fm-decision-board.v1 ] || fail "json must carry the board schema (got $schema)"
totals=$(printf '%s' "$model" | jq -r '[.counts.total, .counts.ready, .counts.gated, .counts.parked] | join(",")')
[ "$totals" = "6,5,1,2" ] || fail "json counts must match the fixture (got $totals)"
blocked_json=$(printf '%s' "$model" | jq -r '
  [.ready[], .gated[]]
  | map(select(.id == "blocker-only" or (.question // "" | contains("firstmate must repair"))))
  | length
')
[ "$blocked_json" = 0 ] || fail "json must exclude firstmate-owned blockers (got $blocked_json)"
merged_sources=$(printf '%s' "$model" | jq -r '[.ready[] | select(.id == "both-ask") | .sources[]] | sort | join(",")')
[ "$merged_sources" = "parked,queue" ] || fail "a merged entry must record both sources (got $merged_sources)"
pass "the json model exposes the same facts as the rendered board"

# --- html format ------------------------------------------------------------

html=$("$BOARD" --snapshot "$SNAP" --format html --limit 0)
assert_contains "$html" "<!doctype html>" "html must be a standalone page"
assert_contains "$html" "&lt;script&gt;" "backlog markup must be escaped"
assert_not_contains "$html" "<script>alert(1)</script>" "backlog markup must never render as live markup"
assert_not_contains "$html" "http://" "the page must not reference an external host"
assert_not_contains "$html" "https://" "the page must not reference an external host"
assert_not_contains "$html" "blocker-only" "html must exclude a firstmate-owned blocker"
assert_not_contains "$html" "firstmate must repair" \
  "html must exclude a firstmate-owned blocker from captain decision summaries"
html_numbers=$(printf '%s\n' "$html" | sed -n 's/.*<span class="num">\([0-9][0-9]*\)<\/span>.*/\1/p')
html_number_count=$(printf '%s\n' "$html_numbers" | sed '/^$/d' | wc -l | tr -d ' ')
html_unique_number_count=$(printf '%s\n' "$html_numbers" | sed '/^$/d' | sort -nu | wc -l | tr -d ' ')
html_gated=${html#*<h2>Waiting on other work first}
html_first_gated_number=$(printf '%s\n' "$html_gated" \
  | sed -n 's/.*<span class="num">\([0-9][0-9]*\)<\/span>.*/\1/p' | head -1)
[ "$html_first_gated_number" = 6 ] \
  || fail "the HTML gated section must continue after the five ready entries (got $html_first_gated_number)"
[ "$html_number_count" = "$html_unique_number_count" ] \
  || fail "HTML numbers must not repeat across the whole board"
pass "the html surface is standalone and escapes backlog text"

# --- malformed waiting dates -----------------------------------------------

malformed="$TMP_ROOT/malformed-date.json"
jq '
  (.backlog.records[] | select(.id == "old-ask") | .since) = "not-a-date"
  | (.backlog.records[] | select(.id == "gated-ask") | .since) = "2026-02-31"
' "$SNAP" > "$malformed"
set +e
malformed_out=$("$BOARD" --snapshot "$malformed" --limit 0 2>&1)
malformed_rc=$?
set -e
expect_code 0 "$malformed_rc" "malformed waiting dates must not abort the board"
for id in old-ask new-ask gated-ask both-ask parked-only markup; do
  assert_contains "$malformed_out" "$id" "a malformed waiting date must not drop $id"
done
assert_contains "$malformed_out" "Could not read waiting date for old-ask: not-a-date." \
  "a malformed date prefix must surface an error in its section"
assert_contains "$malformed_out" "Could not read waiting date for gated-ask: 2026-02-31." \
  "an impossible calendar date must surface an error in its section"
assert_contains "$malformed_out" "waiting 1 day" \
  "an impossible calendar date must not stop valid waiting ages from rendering"
malformed_model=$("$BOARD" --snapshot "$malformed" --format json --limit 0)
invalid_waiting=$(printf '%s' "$malformed_model" | jq -r '
  .gated[] | select(.id == "gated-ask")
  | [.waiting_days, .waiting_error] | @tsv
')
expected_invalid_waiting=$'\tCould not read waiting date for gated-ask: 2026-02-31.'
[ "$invalid_waiting" = "$expected_invalid_waiting" ] \
  || fail "an impossible calendar date must not fabricate a waiting age"
pass "malformed waiting dates stay visible without disrupting the board"

# --- stdin snapshot ---------------------------------------------------------

piped=$("$BOARD" --snapshot - --limit 0 < "$SNAP")
[ "$piped" = "$out" ] || fail "a snapshot read from standard input must render identically"
pass "the board reads a snapshot from standard input"

# --- empty board versus unreadable source -----------------------------------

empty="$TMP_ROOT/empty.json"
jq '.backlog.records = [] | .tasks = []' "$SNAP" > "$empty"
set +e
empty_out=$("$BOARD" --snapshot "$empty" 2>&1)
empty_rc=$?
set -e
expect_code 0 "$empty_rc" "an empty board is a success"
assert_contains "$empty_out" "Nothing is waiting on you" "an empty board must say so plainly"

missing="$TMP_ROOT/missing.json"
jq '.backlog.present = false | .backlog.records = []' "$SNAP" > "$missing"
set +e
missing_out=$("$BOARD" --snapshot "$missing" 2>&1)
missing_rc=$?
set -e
expect_code 3 "$missing_rc" "an unreadable decision queue must refuse rather than print an empty board"
assert_not_contains "$missing_out" "Nothing is waiting on you" \
  "an unreadable queue must never read as an empty board"
pass "an empty board is distinguishable from an unreadable source"

# --- argument validation ----------------------------------------------------

set +e
"$BOARD" --snapshot "$SNAP" --format toon >/dev/null 2>&1
bad_format=$?
"$BOARD" --snapshot "$SNAP" --limit two >/dev/null 2>&1
bad_limit=$?
"$BOARD" --snapshot "$TMP_ROOT/does-not-exist.json" >/dev/null 2>&1
bad_path=$?
"$BOARD" --help >/dev/null 2>&1
help_rc=$?
set -e
[ "$bad_format" -ne 0 ] || fail "an unsupported format must be refused"
[ "$bad_limit" -ne 0 ] || fail "a non-numeric limit must be refused"
[ "$bad_path" -ne 0 ] || fail "an unreadable snapshot path must be refused"
expect_code 0 "$help_rc" "--help must succeed"
pass "invalid arguments are refused"

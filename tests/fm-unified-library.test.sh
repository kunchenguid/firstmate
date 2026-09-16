#!/usr/bin/env bash
# Behavioral tests for bin/fm-unified-library.sh.
# Drives the public command surface with a mocked OSBAMBAM library CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADAPTER="$ROOT/bin/fm-unified-library.sh"
TMP_ROOT=$(fm_test_tmproot fm-unified-library)
OSBAMBAM="$TMP_ROOT/osbambam"
FAKEBIN="$TMP_ROOT/fakebin"
CALLS="$TMP_ROOT/calls"
LIBRARY_PY="$OSBAMBAM/os/scripts/library.py"
BRAIN_JS="$OSBAMBAM/rubric-second-brain/brain.js"

assert_present "$ADAPTER" "bin/fm-unified-library.sh is missing"
[ -x "$ADAPTER" ] || fail "bin/fm-unified-library.sh must be executable"

mkdir -p "$OSBAMBAM/os/scripts" "$OSBAMBAM/rubric-second-brain" "$FAKEBIN"
: >"$CALLS"

cat >"$LIBRARY_PY" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

calls = os.environ.get("FM_UL_CALLS")
if calls:
    with open(calls, "a", encoding="utf-8") as handle:
        handle.write(" ".join(sys.argv[1:]) + "\n")

command = sys.argv[1] if len(sys.argv) > 1 else ""
if command == "search":
    query = sys.argv[2]
    if "verified-hit" in query:
        cards = [{
            "card_id": "CARD-VERIFIED-1",
            "status": "verified",
            "title": "Verified hit",
        }]
    else:
        cards = [{
            "card_id": "CARD-DRAFT-1",
            "status": "draft",
            "title": "Draft prior art",
        }]
    json.dump({"cards": cards, "query": query, "status": "ok"}, sys.stdout, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)
if command == "open":
    json.dump({"identifier": sys.argv[2], "kind": "card", "status": "ok"}, sys.stdout, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)
if command == "trace":
    json.dump({"identity": {"kind": "card"}, "outcomes": [], "status": "found"}, sys.stdout, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)
if command in {"intake", "record-outcome", "card-status"}:
    sys.stderr.write("write command should not be invoked: %s\n" % command)
    raise SystemExit(9)
sys.stderr.write("unexpected library command: %s\n" % command)
raise SystemExit(9)
PY
chmod +x "$LIBRARY_PY"

cat >"$BRAIN_JS" <<'JS'
const args = process.argv.slice(2);
const calls = process.env.FM_UL_CALLS;
if (calls) {
  require("fs").appendFileSync(calls, args.join(" ") + "\n");
}
process.stdout.write(JSON.stringify({command: args[0], query: args[1]}) + "\n");
JS

cat >"$FAKEBIN/node" <<'SH'
#!/usr/bin/env bash
script=$1
shift
exec python3 - "$script" "$@" <<'PY'
import json
import os
import sys

script = sys.argv[1]
args = sys.argv[2:]
calls = os.environ.get("FM_UL_CALLS")
if calls:
    with open(calls, "a", encoding="utf-8") as handle:
        handle.write(" ".join(args) + "\n")
print(json.dumps({"command": args[0], "query": args[1], "extra": args[2:]}))
PY
SH
chmod +x "$FAKEBIN/node"

run_adapter() {
  PATH="$FAKEBIN:$PATH" \
    FM_OSBAMBAM_ROOT="$OSBAMBAM" \
    FM_UL_CALLS="$CALLS" \
    "$ADAPTER" "$@"
}

test_help_does_not_need_osbambam() {
  local out rc
  set +e
  out=$("$ADAPTER" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "help without OSBAMBAM"
  assert_contains "$out" "fm-unified-library.sh recall" "help omitted recall usage"
  pass "help works without an OSBAMBAM root"
}

test_search_reports_no_verified_card() {
  local out
  : >"$CALLS"
  out=$(run_adapter search "adapter lookup contract")
  assert_contains "$out" '"verified_finding": "no verified relevant card"' \
    "search with only drafts did not report the no-verified-card finding"
  assert_not_contains "$out" '"status": "verified"' \
    "search with only drafts claimed a verified card"
  assert_contains "$out" '"drafts_are_prior_art": true' \
    "search did not mark drafts as prior art"
  assert_contains "$out" "CARD-DRAFT-1" "search dropped the draft card"
  assert_grep "search adapter lookup contract --limit 3" "$CALLS" \
    "search did not call library.py with limit 3"
  pass "search reports no verified relevant card without inventing one"
}

test_search_has_no_limit_override() {
  local out rc
  : >"$CALLS"
  set +e
  out=$(run_adapter search "adapter lookup contract" --limit 10 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "search --limit"
  assert_contains "$out" "unknown search option: --limit" "search accepted a limit override"
  [ ! -s "$CALLS" ] || fail "rejected --limit still invoked library.py"
  run_adapter search "adapter lookup contract" >/dev/null
  [ "$(cat "$CALLS")" = "search adapter lookup contract --limit 3" ] \
    || fail "search did not call library.py with the fixed limit 3: $(cat "$CALLS")"
  pass "search always requests exactly three cards"
}

test_search_rejects_unknown_option() {
  local out rc
  : >"$CALLS"
  set +e
  out=$(run_adapter search "verified-hit adapter" --verified-only 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "search --verified-only"
  assert_contains "$out" "unknown search option: --verified-only" \
    "search accepted a status filter it no longer owns"
  [ ! -s "$CALLS" ] || fail "rejected search option still invoked library.py"
  pass "search has no status filter that could hide draft prior art"
}

test_search_marks_verified_hit() {
  local out
  : >"$CALLS"
  out=$(run_adapter search "verified-hit adapter")
  assert_grep "search verified-hit adapter --limit 3" "$CALLS" \
    "verified hit search passed extra arguments to library.py"
  assert_contains "$out" '"card_id": "CARD-VERIFIED-1"' "verified hit card was dropped"
  assert_contains "$out" '"status": "verified"' "verified hit lost its card status"
  assert_not_contains "$out" "no verified relevant card" \
    "verified hit still reported no verified card"
  pass "search marks a verified hit without a status filter"
}

test_open_and_trace_passthrough() {
  local out rc
  : >"$CALLS"
  out=$(run_adapter open CARD-DRAFT-1)
  assert_contains "$out" '"identifier": "CARD-DRAFT-1"' "open did not pass the card id"
  assert_grep "open CARD-DRAFT-1 --budget 4000" "$CALLS" \
    "open did not use the fixed budget"
  : >"$CALLS"
  set +e
  out=$(run_adapter open CARD-DRAFT-1 --budget 99 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "open --budget"
  assert_contains "$out" "unknown open option: --budget" "open accepted a budget override"
  [ ! -s "$CALLS" ] || fail "rejected --budget still invoked library.py"
  : >"$CALLS"
  out=$(run_adapter trace CARD-DRAFT-1)
  assert_contains "$out" '"kind": "card"' "trace did not return provenance"
  assert_grep "trace CARD-DRAFT-1" "$CALLS" "trace did not call library.py"
  pass "open and trace call the existing library CLI"
}

test_recall_uses_brain_js() {
  local out rc
  : >"$CALLS"
  out=$(run_adapter recall "Bryce decisions preferences")
  assert_contains "$out" '"command": "recall"' "recall did not invoke brain.js recall"
  [ "$(cat "$CALLS")" = "recall Bryce decisions preferences" ] \
    || fail "recall did not pass the query alone to brain.js: $(cat "$CALLS")"
  set +e
  out=$(run_adapter recall "Bryce decisions preferences" --k 5 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "recall --k"
  assert_contains "$out" "unknown recall option: --k" "recall accepted a hit-count override"
  pass "recall queries OSBAMBAM memory through brain.js with its default hit count"
}

test_record_outcome_prints_owner_command() {
  local out rc
  : >"$CALLS"
  out=$(run_adapter record-outcome CARD-DRAFT-1 mixed --evidence "draft prior art used" --run-id run-7)
  assert_contains "$out" "python3 $LIBRARY_PY record-outcome CARD-DRAFT-1 mixed" \
    "record-outcome did not print the library-owner command"
  assert_contains "$out" "mixed --evidence draft\\ prior\\ art\\ used --run-id run-7" \
    "record-outcome dropped or mangled the evidence and run id in the owner command"
  [ ! -s "$CALLS" ] || fail "record-outcome invoked the OSBAMBAM library CLI"
  set +e
  out=$(run_adapter record-outcome CARD-DRAFT-1 partly 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "record-outcome invalid outcome"
  assert_contains "$out" "outcome must be worked, failed, mixed, or unknown" \
    "record-outcome accepted an outcome the owner rejects"
  pass "record-outcome routes the outcome to the library owner without a local store"
}

test_writes_are_refused() {
  local out rc
  : >"$CALLS"
  set +e
  out=$(run_adapter intake /tmp/source 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "intake refusal"
  assert_contains "$out" "unknown command: intake" "intake was not refused"
  assert_contains "$out" "librarian.py research" "refusal omitted Librarian research intake"
  assert_contains "$out" "library.py intake" "refusal omitted library intake"
  assert_contains "$out" "library.py record-outcome" "refusal omitted the outcome owner command"
  [ ! -s "$CALLS" ] || fail "refused write still invoked library.py"
  : >"$CALLS"
  set +e
  out=$(run_adapter purge-ready 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "purge-ready refusal"
  assert_contains "$out" "unknown command: purge-ready" "unlisted owner verb was not refused"
  assert_contains "$out" "library.py intake" "unlisted owner verb refusal omitted owner guidance"
  [ ! -s "$CALLS" ] || fail "refused unlisted verb still invoked library.py"
  pass "library writes stay with the OSBAMBAM owner"
}

test_help_does_not_need_osbambam
test_search_reports_no_verified_card
test_search_has_no_limit_override
test_search_rejects_unknown_option
test_search_marks_verified_hit
test_open_and_trace_passthrough
test_recall_uses_brain_js
test_record_outcome_prints_owner_command
test_writes_are_refused

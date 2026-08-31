#!/usr/bin/env bash
# Q8: the gate classifier is the single, pure, fail-closed owner of "is this
# gate's state acceptable?".
#
# The defect it freezes: the rule had three statements - tests/run-all.sh
# implemented it, bin/fm-verify.sh's verifier prompt contradicted it ("every
# gate must be green"), and fm-brief.sh restated it again. gates/accepted-red.md
# is a deliberate baseline, so a ledger holding declared reds can never be
# absolutely green, and acceptance came down to whether an LLM happened to reason
# about that file on a given run. This gate freezes the classifier's answer so
# there is one authority to cite instead of three to drift.
#
# It asserts, in one place:
#   - the DOUBLE condition: red AND declared is ok; red alone is not; a
#     declaration alone (on a non-red gate) grants nothing.
#   - frozen is acceptable. `ledger verify` DEMOTES frozen to green
#     (CONTRIBUTING.md), so frozen is strictly stronger than green, and 9 of
#     this repo's own gates are frozen today.
#   - all three ABSENCE cases, because the classifier runs on the Quarterdeck
#     path for every project and most have no gates/ at all.
#   - PURITY: it never invokes gates/verify.sh or the `ledger` CLI. `ledger
#     verify` re-runs every gate and rewrites the ledger it is pointed at, so a
#     classifier that called it would mutate the thing it classifies.
#   - FAIL CLOSED: an unparseable ledger yields no rows at all, never a partial
#     answer; an unrecognised status is never ok; a "gates" value that is not a
#     JSON array is BADLEDGER, never coerced into one; and no gate field may
#     carry a tab or newline, because a delimiter in a structural field FORGES
#     A ROW - one crafted gate id turned an all-green ledger with an empty
#     accepted-red.md into a silent skip of an arbitrary failing test; a gate
#     whose id or status is missing or not a JSON string is BADLEDGER too,
#     because str()-ing it produced the literal "None" as a gate id; a PRESENT
#     test_ref of the wrong type is BADLEDGER for the same reason, since
#     stringifying a list or an object yielded no ".test.sh" token and quietly
#     exempted that gate from fm-verify's freshness cross-check, while a MISSING
#     or null test_ref stays legitimate because it genuinely means "no freshness
#     check for this gate"; and an
#     unproven gate is recognised but never acceptable, reported under its own
#     verdict so a caller can route it to the crewmate who can clear it rather
#     than to a human who cannot. That coercion was
#     a live fail-open - {"gates": {}} became an empty list, produced zero rows,
#     and classified OK, so fm-verify announced "gates: acceptable" over a
#     ledger it had read no gates from at all.
#
# Mutation (LEDGER_MUTATE=1): the assertions demand the unsafe classification -
# that an UNDECLARED red is ok, that an object-shaped "gates" is coerced and
# classified OK, and that a forged row is honoured as a real skip. A correct
# classifier calls them bad-red and BADLEDGER and refuses the forgery, so each
# assertion fails.
#
# spec: docs/specs/2026-07-01-agent-os-council.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-gates-lib.sh
. "$ROOT/bin/fm-gates-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q8)

# row <output> <gate-id> -> the classifier's row for that gate, tabs -> spaces
row() { printf '%s\n' "$1" | awk -F'\t' -v g="$2" '$2 == g { print $1 " | " $3 " | " $4 " | " $5 }'; }
header() { printf '%s\n' "$1" | head -1; }

# --- fixture ----------------------------------------------------------------
fixture() {
  local dir=$1
  mkdir -p "$dir/gates" "$dir/tests"
  : > "$dir/tests/aa.test.sh"
  : > "$dir/tests/bb.test.sh"
  : > "$dir/tests/cc.test.sh"
  : > "$dir/tests/dd.test.sh"
  : > "$dir/tests/ee.test.sh"
  cat > "$dir/gates/ledger.json" <<'JSON'
{
  "version": 1,
  "gates": [
    { "id": "fx-green",          "status": "green",  "test_ref": "bash tests/aa.test.sh" },
    { "id": "fx-frozen",         "status": "frozen", "test_ref": "bash tests/bb.test.sh" },
    { "id": "fx-declared-red",   "status": "red",    "test_ref": "bash tests/cc.test.sh" },
    { "id": "fx-undeclared-red", "status": "red",    "test_ref": "bash tests/dd.test.sh" },
    { "id": "fx-declared-green", "status": "green",  "test_ref": "bash tests/ee.test.sh" }
  ]
}
JSON
  cat > "$dir/gates/accepted-red.md" <<'MD'
# Accepted red gates

- fx-declared-red - a fixture gate, declared red on purpose, with a route back to green.
- fx-declared-green - declared, but this gate is not red, so the declaration grants nothing.
- fx-no-reason
MD
}

A="$TMP/a"; fixture "$A"
outA=$(fm_gates_classify "$A")

expect_code OK "$(header "$outA")" "a readable ledger and accepted-red.md classify as OK"

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  # MUTATION: demand that an undeclared red be acceptable - the exact fail-open
  # the double condition exists to prevent.
  case "$(row "$outA" fx-undeclared-red)" in
    ok\ *) : ;;
    *) fail "MUTATION: expected an undeclared red gate to classify ok" ;;
  esac
else
  case "$(row "$outA" fx-undeclared-red)" in
    bad-red\ *) : ;;
    *) fail "a red gate that is NOT declared in accepted-red.md must classify bad-red;
being red is not enough to be excused" ;;
  esac
fi

# The double condition, both halves.
assert_contains "$(row "$outA" fx-declared-red)" "ok | red | tests/cc.test.sh | a fixture gate" \
  "red AND declared is acceptable, and the row carries the declared reason"
assert_contains "$(row "$outA" fx-declared-green)" "ok | green |" \
  "a declared gate that is green is acceptable as green, not as an excused red"
assert_not_contains "$(printf '%s\n' "$outA" | awk -F'\t' '$2 == "fx-declared-green" { print $3 }')" "red" \
  "a declaration must never make a gate count as red"

# frozen: strictly stronger than green, and 9 of this repo's gates hold it.
assert_contains "$(row "$outA" fx-frozen)" "ok | frozen |" \
  "frozen is a passing status - ledger verify DEMOTES frozen to green, so
treating it as unacceptable would reject every ship task in this repo"
assert_contains "$(row "$outA" fx-green)" "ok | green |" "green is acceptable"

# test_ref is reported as the ledger records it, not stat()ed - that is I/O, and
# the freshness policy belongs to the caller that wants it.
assert_contains "$(row "$outA" fx-green)" "tests/aa.test.sh" \
  "the row carries the test path token from test_ref"

# --- an entry with no stated reason is ignored, not trusted -------------------
# accepted-red.md's own format requires a reason: "an entry with no route back
# to green is a bug report, not a baseline".
B="$TMP/b"; fixture "$B"
python3 - "$B/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gates"].append({"id": "fx-no-reason", "status": "red", "test_ref": "bash tests/aa.test.sh"})
open(p, "w").write(json.dumps(d, indent=2))
PY
outB=$(fm_gates_classify "$B")
case "$(row "$outB" fx-no-reason)" in
  bad-red\ *) : ;;
  *) fail "a declaration with no stated reason must not excuse a red gate" ;;
esac

# --- absence case 1: no gates/ dir -> not applicable --------------------------
# Most projects firstmate ships to have no gate ledger at all. This must be a
# quiet "not applicable", never an error.
C="$TMP/c"; mkdir -p "$C"
expect_code NOGATES "$(fm_gates_classify "$C")" "a root with no gates/ dir classifies NOGATES"

# --- absence case 2: gates/ but no ledger -> nothing can be classified --------
D="$TMP/d"; fixture "$D"; rm -f "$D/gates/ledger.json"
expect_code NOLEDGER "$(fm_gates_classify "$D")" "gates/ without a ledger classifies NOLEDGER"

# --- absence case 3: gates/ but no accepted-red.md ---------------------------
# No declarations exist, so every red is undeclared by construction.
E="$TMP/e"; fixture "$E"; rm -f "$E/gates/accepted-red.md"
outE=$(fm_gates_classify "$E")
expect_code NOACCEPTED "$(header "$outE")" "a missing accepted-red.md classifies NOACCEPTED"
case "$(row "$outE" fx-declared-red)" in
  bad-red\ *) : ;;
  *) fail "with no accepted-red.md nothing is declared, so every red must be bad-red" ;;
esac
assert_contains "$(row "$outE" fx-green)" "ok | green |" \
  "a missing accepted-red.md must not condemn the gates that are green"

# --- fail closed: an unparseable ledger yields NO rows -----------------------
F="$TMP/f"; fixture "$F"; printf 'not json at all\n' > "$F/gates/ledger.json"
outF=$(fm_gates_classify "$F")
expect_code BADLEDGER "$outF" "an unparseable ledger classifies BADLEDGER and emits no rows"

# A PARTIAL parse must also yield nothing: a half-list looks exactly like a
# complete answer, and acting on one is a fail-open.
G="$TMP/g"; fixture "$G"
python3 - "$G/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gates"].append("not-an-object")   # well-formed entries first, then garbage
open(p, "w").write(json.dumps(d, indent=2))
PY
expect_code BADLEDGER "$(fm_gates_classify "$G")" \
  "a ledger that parses partway then fails must yield NO rows, never a half-list"

# --- fail closed: an unrecognised status is never ok -------------------------
H="$TMP/h"; fixture "$H"
python3 - "$H/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-green":
        g["status"] = "sea-green"
open(p, "w").write(json.dumps(d, indent=2))
PY
case "$(row "$(fm_gates_classify "$H")" fx-green)" in
  bad-status\ *) : ;;
  *) fail "a status the classifier has no rule for must never classify ok" ;;
esac

# --- unproven is RECOGNISED, and still not acceptable ------------------------
#
# CONTRIBUTING.md ("Born-green gates are refused") records that the harness
# stamps unproven whenever a gate test passes while first_observed_red is null,
# so it is the ordinary transient state of gate-driven development - not a value
# this repo cannot interpret. It gets its own verdict because the two fail in
# different directions for the caller: unproven is a crewmate-actionable reject,
# while an unrecognised status is a ledger a human has to look at. Collapsing
# them sent the commonest non-clean status a crewmate can produce straight to a
# captain escalation.
U="$TMP/u"; fixture "$U"
python3 - "$U/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-green":
        g["status"] = "unproven"
open(p, "w").write(json.dumps(d, indent=2))
PY
outU=$(fm_gates_classify "$U")
case "$(row "$outU" fx-green)" in
  bad-unproven\ *) : ;;
  *) fail "unproven must classify bad-unproven: recognised, distinct from a
status this repo has no rule for, and never acceptable" ;;
esac
assert_contains "$(row "$outU" fx-green)" "never been observed red" \
  "the unproven verdict carries the reason a crewmate needs to act on it"

# --- fail closed: a non-array "gates" is BADLEDGER, never coerced ------------
#
# The regression this freezes was live and shipped in this file's first
# version: the shape check ran AFTER an `if isinstance(gates, dict): gates =
# list(gates.values())` coercion lifted from tests/run-all.sh. An object-shaped
# ledger therefore became a list, an EMPTY object became an empty list, zero
# rows were emitted, and the header said OK - so bin/fm-verify.sh printed
# "gates: acceptable" over a ledger from which it had read no gates whatsoever.
# CONTRIBUTING.md states that gates must be a JSON array and that any other
# shape makes every `ledger` subcommand abort, and frozen gate m0-ledger-shape
# freezes that. A shape the harness calls fatal is not one to quietly repair.
O="$TMP/o"; fixture "$O"
printf '%s\n' '{"version": 1, "gates": {}}' > "$O/gates/ledger.json"
outO=$(fm_gates_classify "$O")

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  # MUTATION: demand the coercion back - an empty object classifying OK.
  expect_code OK "$(header "$outO")" \
    "MUTATION: expected an object-shaped gates value to be coerced and classify OK"
else
  expect_code BADLEDGER "$outO" \
    "an empty object-shaped gates value must be BADLEDGER, never coerced into an
empty list that classifies OK over a ledger no gate was ever read from"
fi

# A POPULATED object is the same defect wearing a disguise: it would coerce into
# a plausible-looking list of real gates and classify as if the ledger were fine.
O2="$TMP/o2"; fixture "$O2"
python3 - "$O2/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gates"] = {g["id"]: g for g in d["gates"]}   # keyed by id: tidier, and fatal
open(p, "w").write(json.dumps(d, indent=2))
PY
expect_code BADLEDGER "$(fm_gates_classify "$O2")" \
  "a populated object-shaped gates value must be BADLEDGER too - coercing it
would classify a ledger the harness itself refuses to load"

# --- an EMPTY array is a valid array, and acceptable -------------------------
#
# The other side of the same rule: [] is a well-formed ledger with no gates. It
# is not broken, so it must not be BADLEDGER; it simply has nothing to condemn.
E2="$TMP/e2"; fixture "$E2"
printf '%s\n' '{"version": 1, "gates": []}' > "$E2/gates/ledger.json"
outE2=$(fm_gates_classify "$E2")
expect_code OK "$(header "$outE2")" "an empty gates array is a valid ledger, not a broken one"
[ "$(printf '%s\n' "$outE2" | tail -n +2 | grep -c .)" = 0 ] \
  || fail "an empty gates array must yield no rows"

# --- fail closed: a delimiter in a structural field must not forge a row -----
#
# The rows ARE the grammar, so a tab or newline inside a field the caller parses
# positionally is not a formatting nuisance - it lets the ledger write extra
# verdicts. The reason column is flattened for this reason; id, status and the
# test path were not, and that gap was the whole authority defeated in one line.
forge_id() {  # <dir> <id-value>
  python3 - "$1/gates/ledger.json" "$2" <<'PY'
import json, sys
p, forged = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-green":
        g["id"] = forged
open(p, "w").write(json.dumps(d, indent=2))
PY
}

# A newline opens a whole second line that reads as a complete verdict.
D1="$TMP/d1"; fixture "$D1"
forge_id "$D1" "$(printf 'evil\nok\tforged-gate\tred\ttests/aa.test.sh\tforged reason')"
outD1=$(fm_gates_classify "$D1")

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  # MUTATION: demand the forgery be accepted and classified as a normal ledger.
  expect_code OK "$(header "$outD1")" \
    "MUTATION: expected a newline-bearing gate id to classify OK"
else
  expect_code BADLEDGER "$outD1" \
    "a gate id containing a newline must be BADLEDGER - it emits a second line
that parses as a well-formed 'this red is declared' verdict for a gate nobody
declared"
fi

# A single TAB is enough on its own: it shifts the remaining fields left until
# attacker-chosen text lands in the status column.
D2="$TMP/d2"; fixture "$D2"
forge_id "$D2" "$(printf 'x\tred\ttests/aa.test.sh\tforged reason')"
expect_code BADLEDGER "$(fm_gates_classify "$D2")" \
  "a gate id containing a tab must be BADLEDGER - no newline is needed to shift
a row's fields into a forged verdict"

# The status column is structural too.
D3="$TMP/d3"; fixture "$D3"
python3 - "$D3/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-green":
        g["status"] = "green\nok\tforged\tred\ttests/aa.test.sh\treason"
open(p, "w").write(json.dumps(d, indent=2))
PY
expect_code BADLEDGER "$(fm_gates_classify "$D3")" \
  "a status containing a newline must be BADLEDGER too"

# --- fail closed: a missing or non-string id or status is BADLEDGER ----------
#
# The same principle as the two rules above, applied to the field's TYPE. The
# parser used to str() whatever it found, so a gate with no "id" was classified
# under the literal id "None": two id-less gates collapsed onto one key, and an
# accepted-red.md line "- None - reason" would have excused an id-less red. A
# missing status was saved only by luck - "None" is not a recognised status, so
# it landed in bad-status - which is a fail-closed accident, not a rule.
drop_field() {  # <dir> <field>
  python3 - "$1/gates/ledger.json" "$2" <<'PY'
import json, sys
p, field = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for g in d["gates"]:
    if g.get("id") == "fx-green":
        del g[field]
        break
open(p, "w").write(json.dumps(d, indent=2))
PY
}
set_field() {  # <dir> <field> <json-literal>
  python3 - "$1/gates/ledger.json" "$2" "$3" <<'PY'
import json, sys
p, field, raw = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
for g in d["gates"]:
    if g.get("id") == "fx-green":
        g[field] = json.loads(raw)
        break
open(p, "w").write(json.dumps(d, indent=2))
PY
}

N1="$TMP/n1"; fixture "$N1"; drop_field "$N1" id
expect_code BADLEDGER "$(fm_gates_classify "$N1")" \
  "a gate with no id must be BADLEDGER - stringifying the missing value gave the
literal id None, so two id-less gates collapse onto one key and an
accepted-red.md line '- None - reason' would excuse an id-less red"

N2="$TMP/n2"; fixture "$N2"; set_field "$N2" id null
expect_code BADLEDGER "$(fm_gates_classify "$N2")" \
  "an explicitly null gate id must be BADLEDGER too - it is the same missing id
wearing a JSON literal"

N3="$TMP/n3"; fixture "$N3"; set_field "$N3" id '[1, 2]'
expect_code BADLEDGER "$(fm_gates_classify "$N3")" \
  "a non-string gate id must be BADLEDGER - a ledger the harness would not load
is not one this classifier repairs into a plausible-looking row"

N4="$TMP/n4"; fixture "$N4"; drop_field "$N4" status
expect_code BADLEDGER "$(fm_gates_classify "$N4")" \
  "a gate with no status must be BADLEDGER, not classified under the status
None and routed to bad-status by accident"

N5="$TMP/n5"; fixture "$N5"; set_field "$N5" status 'true'
expect_code BADLEDGER "$(fm_gates_classify "$N5")" \
  "a non-string status must be BADLEDGER for the same reason as a non-string id"

# A PRESENT test_ref of the wrong type is the same refusal. str()-ing a list or
# an object produced a value with no ".test.sh" token, so the gate simply fell
# out of fm-verify's freshness cross-check - a fail-open dressed as a no-op,
# which is worse than a loud refusal because nothing at all announces it.
N6="$TMP/n6"; fixture "$N6"; set_field "$N6" test_ref '["bash", "tests/aa.test.sh"]'
expect_code BADLEDGER "$(fm_gates_classify "$N6")" \
  "a list-valued test_ref must be BADLEDGER - stringifying it yields no .test.sh
token, so the gate is silently exempted from the freshness check instead"

N7="$TMP/n7"; fixture "$N7"; set_field "$N7" test_ref '{"cmd": "bash tests/aa.test.sh"}'
expect_code BADLEDGER "$(fm_gates_classify "$N7")" \
  "an object-valued test_ref must be BADLEDGER for the same reason as a list-valued one"

# The one legitimate absence: a MISSING or null test_ref is not an error at all.
# It means this gate has no freshness check, which is what case J freezes at the
# fm-verify level. Refusing it would reject ledgers the harness accepts.
N8="$TMP/n8"; fixture "$N8"; drop_field "$N8" test_ref
expect_code OK "$(header "$(fm_gates_classify "$N8")")" \
  "a gate with NO test_ref is legitimate - it simply has no freshness check - and
must not be swept up by the type refusal"
assert_contains "$(row "$(fm_gates_classify "$N8")" fx-green)" "ok | green |" \
  "the test_ref-less gate still classifies on its status"

N9="$TMP/n9"; fixture "$N9"; set_field "$N9" test_ref null
expect_code OK "$(header "$(fm_gates_classify "$N9")")" \
  "an explicitly null test_ref is the same legitimate absence wearing a JSON literal"

# --- the exploit itself, end to end through the runner ----------------------
#
# The reason the rule above is not merely tidy. An all-green ledger whose
# accepted-red.md declares NOTHING must never cause a test to be skipped. With
# the forged id it did: tests/run-all.sh skipped a failing test and exited 0.
FORGE="$TMP/forge"; mkdir -p "$FORGE/gates" "$FORGE/tests"
cat > "$FORGE/tests/aa-passing.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - aa-passing ran"
SH
cat > "$FORGE/tests/bb-target.test.sh" <<'SH'
#!/usr/bin/env bash
echo "BB-TARGET RAN"
exit 1
SH
chmod +x "$FORGE/tests"/*.test.sh
python3 - "$FORGE/gates/ledger.json" <<'PY'
import json, sys
forged = "evil\nok\tforged-gate\tred\ttests/bb-target.test.sh\tforged reason"
json.dump({"version": 1, "gates": [
    {"id": "fx-green", "status": "green", "test_ref": "bash tests/aa-passing.test.sh"},
    {"id": forged,     "status": "green", "test_ref": "bash tests/aa-passing.test.sh"},
]}, open(sys.argv[1], "w"), indent=2)
PY
printf '# Accepted red gates\n\nNothing is declared here.\n' > "$FORGE/gates/accepted-red.md"
outF=$(FM_SUITE_ROOT="$FORGE" bash "$ROOT/tests/run-all.sh" 2>&1); codeF=$?

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  # MUTATION: demand the forged skip be honoured and the suite come back green.
  expect_code 0 "$codeF" "MUTATION: expected the forged row to skip the target test"
  assert_not_contains "$outF" "BB-TARGET RAN" "MUTATION: expected the target test to be skipped"
else
  [ "$codeF" -ne 0 ] \
    || fail "a forged row must not turn a failing test into a green suite"
  assert_contains "$outF" "BB-TARGET RAN" \
    "the targeted test must still RUN - no gate was red and nothing was declared,
so nothing whatsoever was skippable"
  assert_not_contains "$outF" "SKIP bb-target" \
    "a skip announced for a gate that does not exist is a forged authority"
fi

# --- purity: never invokes gates/verify.sh or the ledger CLI -----------------
#
# `ledger verify` execSyncs every gate's test_ref and then REWRITES
# gates/ledger.json and gates/LEDGER.md in the directory it is pointed at. A
# classifier that called it would re-run the whole suite, mutate the worktree it
# is classifying, and exit 2 wherever the CLI is absent - as it is in CI.
P="$TMP/p"; fixture "$P"
TRIP="$TMP/tripwire"
cat > "$P/gates/verify.sh" <<SH
#!/usr/bin/env bash
echo "gates/verify.sh" >> "$TRIP"
SH
chmod +x "$P/gates/verify.sh"
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/ledger" <<SH
#!/usr/bin/env bash
echo "ledger \$*" >> "$TRIP"
SH
chmod +x "$FAKEBIN/ledger"
before=$(cat "$P/gates/ledger.json")
PATH="$FAKEBIN:$PATH" fm_gates_classify "$P" >/dev/null
assert_absent "$TRIP" \
  "the classifier must never invoke gates/verify.sh or the ledger CLI - it would
re-run every gate and rewrite the ledger it is classifying"
[ "$before" = "$(cat "$P/gates/ledger.json")" ] \
  || fail "classifying must not modify gates/ledger.json - it is a pure read"

# --- the root is an argument, never assumed ----------------------------------
# The classifier is called against a crewmate's worktree, not firstmate's own
# repo, so it must classify whatever root it is handed.
[ "$(header "$(fm_gates_classify "$A")")" = OK ] || fail "root A must classify OK"
[ "$(fm_gates_classify "$C")" = NOGATES ] || fail "root C must classify NOGATES"

pass "Q8 gate classifier: double condition, absence cases, array-only, unforgeable rows, pure, fail closed"

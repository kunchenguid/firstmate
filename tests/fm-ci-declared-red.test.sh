#!/usr/bin/env bash
# ci-declared-red: the suite runner skips a declared-red gate's test, and ONLY
# a declared-red gate's test.
#
# The problem it solves: CI runs every tests/*.test.sh, so a gate that is
# deliberately red - an accepted baseline, or one blocked on another repo -
# fails the job forever. Making such a test pass would be a false green, which
# the whole gate discipline exists to prevent. So the runner skips it instead.
#
# The hazard that creates, and the reason this gate exists: a runner that skips
# "any gate that is currently red" would mask a real regression the moment
# someone commits a ledger in which a working gate has gone red. Skipping must
# therefore require an EXPLICIT declaration, not an incidental status. Two
# independent conditions must both hold:
#
#   1. the gate's status is "red" in gates/ledger.json, AND
#   2. the gate id is listed in gates/accepted-red.md, with a stated reason
#
# A gate that is red but undeclared still runs, still fails, and still fails CI.
# That is the property this gate freezes.
#
# And no skip may be silent: each one prints a visible line naming the gate and
# its test, so a reader of the CI log can see exactly what was not run.
#
# Mutation (LEDGER_MUTATE=1): the assertions are inverted to expect the unsafe
# behaviour - that an undeclared red gate's test is skipped too. A correct
# runner refuses to skip it, so the assertion fails.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/tests/run-all.sh"
assert_present "$RUNNER" "tests/run-all.sh must exist"

TMP=$(fm_test_tmproot fm-ci-declared-red)

# fixture <dir> <include-undeclared-red>
# A miniature repo: a gates/ dir and a tests/ dir holding three suites.
fixture() {
  local dir=$1 with_undeclared=$2
  mkdir -p "$dir/gates" "$dir/tests"

  cat > "$dir/tests/aa-passing.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - aa-passing ran"
SH
  cat > "$dir/tests/bb-declared-red.test.sh" <<'SH'
#!/usr/bin/env bash
echo "bb-declared-red RAN - it should not have"
exit 1
SH
  cat > "$dir/tests/cc-undeclared-red.test.sh" <<'SH'
#!/usr/bin/env bash
echo "cc-undeclared-red ran"
exit 1
SH
  chmod +x "$dir/tests"/*.test.sh
  [ "$with_undeclared" = yes ] || rm -f "$dir/tests/cc-undeclared-red.test.sh"

  cat > "$dir/gates/ledger.json" <<'JSON'
{
  "version": 1,
  "gates": [
    { "id": "fx-green", "status": "green", "test_ref": "bash tests/aa-passing.test.sh" },
    { "id": "fx-declared-red", "status": "red", "test_ref": "bash tests/bb-declared-red.test.sh" },
    { "id": "fx-undeclared-red", "status": "red", "test_ref": "bash tests/cc-undeclared-red.test.sh" }
  ]
}
JSON

  cat > "$dir/gates/accepted-red.md" <<'MD'
# Accepted red gates

- fx-declared-red - a fixture gate, declared red on purpose so the runner may skip it.
MD
}

run_suite() { FM_SUITE_ROOT="$1" bash "$RUNNER" 2>&1; }

# --- case A: an undeclared red gate must still run, and still fail -----------
A="$TMP/a"; fixture "$A" yes
outA=$(run_suite "$A"); codeA=$?

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  # MUTATION: demand the unsafe behaviour - the undeclared red test skipped and
  # the suite green. A correct runner runs it and fails, so this fails.
  expect_code 0 "$codeA" "MUTATION: expected an undeclared red gate to be skipped"
  assert_not_contains "$outA" "cc-undeclared-red ran" \
    "MUTATION: expected the undeclared red test not to run"
else
  [ "$codeA" -ne 0 ] \
    || fail "a red gate that is NOT declared accepted must still fail the suite"
  assert_contains "$outA" "cc-undeclared-red ran" \
    "an undeclared red gate's test must still be RUN, not skipped - otherwise a
regression is masked the moment a working gate goes red"
fi

# The declared one is skipped, visibly, in every case.
assert_not_contains "$outA" "bb-declared-red RAN" \
  "a declared-red gate's test must not be executed"
assert_contains "$outA" "SKIP" "a skip must be announced"
assert_contains "$outA" "fx-declared-red" "the skip line must name the gate"
assert_contains "$outA" "bb-declared-red.test.sh" "the skip line must name the test"

# A skipped test is never counted as a pass.
assert_contains "$outA" "skipped" "the summary must report the skip count"

# --- case B: with only declared reds left, the suite is green ---------------
B="$TMP/b"; fixture "$B" no
outB=$(run_suite "$B"); codeB=$?
expect_code 0 "$codeB" "a suite whose only red gate is declared accepted must pass"
assert_contains "$outB" "aa-passing ran" "the healthy test must still run"
assert_contains "$outB" "SKIP" "the skip must still be announced when the suite is green"

# --- case C: no ledger means no skipping, loudly ----------------------------
C="$TMP/c"; fixture "$C" yes
rm -f "$C/gates/ledger.json"
outC=$(run_suite "$C"); codeC=$?
[ "$codeC" -ne 0 ] || fail "without a ledger the suite must run everything and fail on the red test"
assert_contains "$outC" "bb-declared-red RAN" \
  "with no ledger to read, nothing may be skipped - fail closed, never open"

# --- case D: an unparseable ledger also skips nothing, loudly ---------------
D="$TMP/d"; fixture "$D" no
printf 'not json at all\n' > "$D/gates/ledger.json"
outD=$(run_suite "$D"); codeD=$?
[ "$codeD" -ne 0 ] || fail "an unparseable ledger must not silently enable skipping"
assert_contains "$outD" "bb-declared-red RAN" \
  "an unparseable ledger must skip nothing"

# --- case E: declaring a gate that is NOT red skips nothing -----------------
# The declaration is permission to skip a red gate, not permission to skip a
# test. A green gate's test always runs.
E="$TMP/e"; fixture "$E" no
python3 - "$E/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-declared-red":
        g["status"] = "green"
open(p, "w").write(json.dumps(d, indent=2))
PY
outE=$(run_suite "$E"); codeE=$?
[ "$codeE" -ne 0 ] || fail "a declared gate that is green must still have its test run"
assert_contains "$outE" "bb-declared-red RAN" \
  "declaration alone must not skip a test; the gate must also be red"

# --- case F: a PARTIAL parse must skip nothing ------------------------------
#
# A real fail-open, not a hypothetical: the sentinel used to be appended to the
# same stream the parse wrote its rows to, so a ledger that parsed far enough to
# emit some rows and then failed produced "rows + BADLEDGER". The exact-match
# handling missed the sentinel, and skipping proceeded on a half-read ledger -
# in the one place this runner promises to fail closed.
#
# A ledger whose gates list is well-formed up to a non-object entry reproduces
# it: the declared-red row is emitted first, then the parse dies.
F="$TMP/f"; fixture "$F" yes
python3 - "$F/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
# Well-formed entries first, then garbage - so any row-at-a-time parse emits
# the declared-red row before it hits trouble.
d["gates"].append("not-an-object")
open(p, "w").write(json.dumps(d, indent=2))
PY
outF=$(run_suite "$F"); codeF=$?
[ "$codeF" -ne 0 ] || fail "a partially-parseable ledger must not produce a green suite"
assert_contains "$outF" "bb-declared-red RAN" \
  "a partial parse must skip NOTHING - a half-read ledger is not a mandate to skip"
assert_not_contains "$outF" "SKIP" \
  "a partial parse must announce no skips at all"

# --- case G: exit 2 is a prerequisite skip, not a failure -------------------
#
# This repo already uses exit 2 for "a prerequisite tool is missing" -
# tests/fm-loop-l2.test.sh needs the loop-audit CLI, tests/fm-boot-m0.test.sh
# needs the ledger CLI, and CI installs neither. Treating that as a failure made
# those tests fail the job for a reason that says nothing about the code. It is
# a skip, and like every other skip here it must be announced.
G="$TMP/g"; fixture "$G" no
cat > "$G/tests/dd-prereq.test.sh" <<'SH'
#!/usr/bin/env bash
echo "PREREQUISITE MISSING: some-cli not on PATH - install it to run this suite" >&2
exit 2
SH
chmod +x "$G/tests/dd-prereq.test.sh"
outG=$(run_suite "$G"); codeG=$?
expect_code 0 "$codeG" "a missing prerequisite (exit 2) must not fail the suite"
assert_contains "$outG" "prerequisite missing (declared)" \
  "an exit-2 skip must be announced, and only when the test DECLARED it"
assert_contains "$outG" "dd-prereq.test.sh" "the skip line must name the test"
assert_contains "$outG" "some-cli not on PATH" \
  "the test's own explanation must be shown, so the skip is diagnosable"

# A genuine failure is still a failure - exit 1 must not be swept up with it.
cat > "$G/tests/ee-real-failure.test.sh" <<'SH'
#!/usr/bin/env bash
echo "a real assertion failed"
exit 1
SH
chmod +x "$G/tests/ee-real-failure.test.sh"
outG2=$(run_suite "$G"); codeG2=$?
[ "$codeG2" -ne 0 ] || fail "exit 1 must still fail the suite"
assert_contains "$outG2" "a real assertion failed" "a real failure must still surface"

# --- case H: a BROKEN test must never be laundered into a skip ---------------
#
# The regression this freezes was live and shipped: exit 2 was accepted as
# "prerequisite missing" purely from the exit code, and bash ALSO exits 2 on a
# syntax error. A test whose entire body was `fi` was reported as
# "SKIP ... prerequisite missing" and the suite exited 0. A test that cannot run
# at all is exactly what CI exists to catch, so that fail-open was worse than
# the problem it solved.
#
# Three outcomes must now be distinguishable, and case G above already covers a
# properly declared skip.
H="$TMP/h"; fixture "$H" no

# A syntax error: fails, and is named as a broken test rather than a skip.
printf '#!/usr/bin/env bash\nfi\n' > "$H/tests/zz-syntax.test.sh"
chmod +x "$H/tests/zz-syntax.test.sh"
outH=$(run_suite "$H"); codeH=$?
[ "$codeH" -ne 0 ] || fail "a test with a syntax error must FAIL the suite, never skip it"
assert_contains "$outH" "does not parse" \
  "a syntax error must be reported as a broken test"
assert_not_contains "$outH" "SKIP zz-syntax" \
  "a syntax error must never be reported as a skip"

# An undeclared exit 2: also a failure, because the skip must be CLAIMED.
rm -f "$H/tests/zz-syntax.test.sh"
printf '#!/usr/bin/env bash\necho "something went wrong"\nexit 2\n' > "$H/tests/zz-bare2.test.sh"
chmod +x "$H/tests/zz-bare2.test.sh"
outH2=$(run_suite "$H"); codeH2=$?
[ "$codeH2" -ne 0 ] \
  || fail "exit 2 without a declared prerequisite must fail, not skip"
assert_contains "$outH2" "without declaring a missing prerequisite" \
  "an undeclared exit 2 must say why it was not treated as a skip"

pass "ci suite runner skips only declared-red gates"

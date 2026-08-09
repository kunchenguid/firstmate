#!/usr/bin/env bash
# Behavior tests for bin/fm-verify.sh and bin/fm-verify-lib.sh - the three-valued
# observation type.
#
# Every case here is a measured instance, not a hypothetical:
#   - chrome-devtools-axi printing "Protocol error (Target.setDiscoverTargets):
#     Target closed" and exiting 0 against a control site;
#   - a pull request whose check-run set is empty being read as green;
#   - git merge-tree exiting 1 both for a real conflict and for a ref it cannot
#     resolve, so one exit status covers a verdict and a non-verdict.
#
# Each is run against the wrappers fm-verify replaces, and the replaced wrapper
# is asserted to get it WRONG. A test that only goes green after the fix proves
# nothing; these assert the negative control first. Three such wrappers exist,
# because "naive" is not one shape:
#   naive_exit_strict     exit 0 -> PASS, anything else -> FAIL
#   naive_exit_lenient    exit 0 -> PASS, anything else -> NO_VERIFIER_RAN
#   naive_output_presence any output -> PASS, no output -> FAIL
#
# The suite also pins the four properties the wrapper exists to hold:
#   1. each value is produced for its own condition and never borrows another's;
#   2. NO_VERIFIER_RAN reaches a consumer AS NO_VERIFIER_RAN (non-coercion);
#   3. a consumer that handles only two of the three is refused;
#   4. PASS still means pass - a verifier that never passes is as useless as one
#      that always does.
#
# Finally, the conformance obligation: every verifier the registry declares must
# have an unobservable-case control in this file. Adding a verifier without one
# fails this suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verify-lib.sh
. "$ROOT/bin/fm-verify-lib.sh"

VERIFY="$ROOT/bin/fm-verify.sh"
TMP=$(fm_test_tmproot fm-verify)
fm_git_identity fmtest fmtest@example.invalid

# --- harness ----------------------------------------------------------------

OUT=''
CODE=''
RESULT=''
REASON=''

# run_verify <args...>: run fm-verify and parse its record.
run_verify() {
  OUT=$("$VERIFY" "$@" 2>&1)
  CODE=$?
  if fm_verify_parse "$OUT"; then
    RESULT=$FM_VERIFY_RESULT
    REASON=$FM_VERIFY_REASON
  else
    RESULT=UNPARSEABLE
    REASON=-
  fi
}

# expect_verify <expected-result> <expected-reason> <label> -- <args...>
expect_verify() {
  local want=$1 want_reason=$2 label=$3
  shift 4
  run_verify "$@"
  [ "$RESULT" = "$want" ] || fail "$label: expected $want, got $RESULT"$'\n'"$OUT"
  [ "$want_reason" = - ] || [ "$REASON" = "$want_reason" ] ||
    fail "$label: expected reason $want_reason, got $REASON"$'\n'"$OUT"
  # Exit 0 for PASS and only for PASS: the structural half of non-coercion, so
  # that even a caller reading nothing but the status cannot land on a pass.
  case "$want" in
    PASS) expect_code 0 "$CODE" "$label exit" ;;
    FAIL) expect_code 1 "$CODE" "$label exit" ;;
    *) expect_code 2 "$CODE" "$label exit" ;;
  esac
}

# The wrappers fm-verify replaces. Each takes a command and prints its verdict.
naive_exit_strict() {
  if "$@" >/dev/null 2>&1; then printf 'PASS\n'; else printf 'FAIL\n'; fi
}

naive_exit_lenient() {
  if "$@" >/dev/null 2>&1; then printf 'PASS\n'; else printf 'NO_VERIFIER_RAN\n'; fi
}

naive_output_presence() {
  local out
  out=$("$@" 2>/dev/null)
  if [ -n "$out" ]; then printf 'PASS\n'; else printf 'FAIL\n'; fi
}

# expect_naive_wrong <naive-fn> <wrong-verdict> <label> -- <command...>
# Witnesses the control red before the real check is trusted.
expect_naive_wrong() {
  local fn=$1 wrong=$2 label=$3 got
  shift 4
  got=$("$fn" "$@")
  [ "$got" = "$wrong" ] ||
    fail "$label: control did not reproduce the defect (expected $wrong, got $got)"
}

# minimal_path <dir>: a PATH holding only the tools fm-verify itself needs, so a
# case can prove a verifier is genuinely absent rather than merely unused.
minimal_path() {
  local dir=$1 tool src
  mkdir -p "$dir"
  for tool in env bash sh mktemp cat head sed tr rm ln git jq awk dirname basename; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# with_path <path> <command...>: run with PATH replaced and restore it after.
# A bare `PATH=... some_function` would leave the assignment in effect once the
# function returns, which is how a later case ends up running without coreutils.
with_path() {
  local want=$1 saved=$PATH rc
  shift
  PATH=$want
  "$@"
  rc=$?
  PATH=$saved
  return $rc
}

# --- fixture: the browser that reports a transport failure and exits 0 -------

BROWSER_BIN=$(fm_fakebin "$TMP/browser")
cat >"$BROWSER_BIN/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
# The exact observed shape: the failure goes to stdout, the status says fine.
printf 'Protocol error (Target.setDiscoverTargets): Target closed\n'
exit 0
SH
chmod +x "$BROWSER_BIN/chrome-devtools-axi"

BROWSER_OK_BIN=$(fm_fakebin "$TMP/browser-ok")
cat >"$BROWSER_OK_BIN/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'snapshot: <h1>Control site</h1>\n'
exit 0
SH
chmod +x "$BROWSER_OK_BIN/chrome-devtools-axi"

BROWSER_SILENT_BIN=$(fm_fakebin "$TMP/browser-silent")
cat >"$BROWSER_SILENT_BIN/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BROWSER_SILENT_BIN/chrome-devtools-axi"

expect_naive_wrong naive_exit_strict PASS \
  'browser protocol error, exit-status wrapper' -- \
  "$BROWSER_BIN/chrome-devtools-axi" open https://example.invalid
expect_naive_wrong naive_output_presence PASS \
  'browser protocol error, output-presence wrapper' -- \
  "$BROWSER_BIN/chrome-devtools-axi" open https://example.invalid

with_path "$BROWSER_BIN:$PATH" expect_verify NO_VERIFIER_RAN verification_unreachable \
  'browser protocol error' -- browser open https://example.invalid
pass "browser transport failure with exit 0 is NO_VERIFIER_RAN, not PASS"

with_path "$BROWSER_OK_BIN:$PATH" expect_verify PASS verified \
  'browser reachable' -- browser open https://example.invalid
pass "browser that actually answers still passes"

with_path "$BROWSER_SILENT_BIN:$PATH" expect_verify NO_VERIFIER_RAN empty_result_set \
  'browser silent' -- browser open https://example.invalid
pass "silent browser is NO_VERIFIER_RAN, not PASS"

BROWSER_CRASH_BIN=$(fm_fakebin "$TMP/browser-crash")
cat >"$BROWSER_CRASH_BIN/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
# A non-zero exit for a reason no signature names: a crash, a page-load
# timeout, a DNS failure. None of them is a statement about the page.
printf 'chrome exited unexpectedly while loading the page\n' >&2
exit 3
SH
chmod +x "$BROWSER_CRASH_BIN/chrome-devtools-axi"

# chrome-devtools-axi is a control tool, not an assertion tool: it has no way to
# report a bad page, so an exit status nobody can interpret is could-not-observe.
# The exit-status wrapper calls it FAIL, which is a verdict about the page that
# nothing in the evidence earned - and it hides a broken verifier among real
# failures.
expect_naive_wrong naive_exit_strict FAIL \
  'uninterpretable browser exit, exit-status wrapper' -- \
  "$BROWSER_CRASH_BIN/chrome-devtools-axi" open https://example.invalid
with_path "$BROWSER_CRASH_BIN:$PATH" expect_verify NO_VERIFIER_RAN verification_unreachable \
  'uninterpretable browser exit' -- browser open https://example.invalid
pass "a browser exit matching no signature is NO_VERIFIER_RAN, not a verdict about the page"

BARE_PATH=$(minimal_path "$TMP/bare-bin")
with_path "$BARE_PATH" expect_verify NO_VERIFIER_RAN verifier_unavailable \
  'browser absent' -- browser open https://example.invalid
pass "absent browser tool is NO_VERIFIER_RAN, not PASS"

# --- fixture: the empty check-run set ---------------------------------------

make_gh() {
  local dir=$1 body=$2 status=${3:-0} bin
  bin=$(fm_fakebin "$dir")
  cat >"$bin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' '$body'
exit $status
SH
  chmod +x "$bin/gh"
  printf '%s\n' "$bin"
}

GH_EMPTY=$(make_gh "$TMP/gh-empty" '{"statusCheckRollup":[]}')
GH_PASSING=$(make_gh "$TMP/gh-passing" \
  '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}')
GH_FAILING=$(make_gh "$TMP/gh-failing" \
  '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}]}')
GH_PENDING=$(make_gh "$TMP/gh-pending" \
  '{"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]}')
GH_SKIPPED=$(make_gh "$TMP/gh-skipped" \
  '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SKIPPED"}]}')
GH_NO_CONCLUSION=$(make_gh "$TMP/gh-no-conclusion" \
  '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":null}]}')
GH_ONE_STALE=$(make_gh "$TMP/gh-one-stale" \
  '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"STALE"}]}')
GH_DOWN=$(make_gh "$TMP/gh-down" 'gh: could not reach api.github.com' 1)

PR=https://github.com/example/repo/pull/1

expect_naive_wrong naive_exit_strict PASS \
  'empty check set, exit-status wrapper' -- \
  "$GH_EMPTY/gh" pr view "$PR" --json statusCheckRollup
expect_naive_wrong naive_output_presence PASS \
  'empty check set, output-presence wrapper' -- \
  "$GH_EMPTY/gh" pr view "$PR" --json statusCheckRollup

with_path "$GH_EMPTY:$PATH" expect_verify NO_VERIFIER_RAN empty_result_set \
  'empty check set' -- pr-checks "$PR"
pass "empty check-run set is NO_VERIFIER_RAN, not PASS"

with_path "$GH_PASSING:$PATH" expect_verify PASS verified \
  'passing checks' -- pr-checks "$PR"
pass "a non-empty all-successful check set still passes"

with_path "$GH_FAILING:$PATH" expect_verify FAIL verifier_reported_failure \
  'failing checks' -- pr-checks "$PR"
pass "a failing check set is FAIL, and never borrows NO_VERIFIER_RAN"

with_path "$GH_PENDING:$PATH" expect_verify NO_VERIFIER_RAN verification_incomplete \
  'pending checks' -- pr-checks "$PR"
pass "a pending check set is NO_VERIFIER_RAN, not PASS and not FAIL"

# The empty set's defect one level down, inside the rule that owns the PASS
# verdict: a check skipped by a path filter, or gone stale, completed without
# earning a verdict, and zero failing checks still looks exactly like every
# check passing. Both naive wrappers read the same gh success and say PASS.
expect_naive_wrong naive_exit_strict PASS \
  'skipped checks, exit-status wrapper' -- \
  "$GH_SKIPPED/gh" pr view "$PR" --json statusCheckRollup
expect_naive_wrong naive_output_presence PASS \
  'skipped checks, output-presence wrapper' -- \
  "$GH_SKIPPED/gh" pr view "$PR" --json statusCheckRollup

with_path "$GH_SKIPPED:$PATH" expect_verify NO_VERIFIER_RAN no_verdict_reached \
  'skipped checks' -- pr-checks "$PR"
pass "a check set that only skipped is NO_VERIFIER_RAN, not PASS"

with_path "$GH_ONE_STALE:$PATH" expect_verify NO_VERIFIER_RAN no_verdict_reached \
  'one stale check among successes' -- pr-checks "$PR"
pass "passing means EVERY member succeeded, so one unconcluded check withholds it"

# --- the conclusion partition, one conclusion at a time ----------------------
#
# The partition is what the three values are worth: a conclusion in the wrong
# list produces a value for a condition that never earned it. Each conclusion is
# asserted on its own so a misplacement names itself instead of hiding inside an
# aggregate.

# gh_with_conclusion <json-conclusion> <slug>: a gh whose pull request carries
# exactly one COMPLETED check with that conclusion.
gh_with_conclusion() {
  make_gh "$TMP/gh-conclusion-$2" \
    "{\"statusCheckRollup\":[{\"status\":\"COMPLETED\",\"conclusion\":$1}]}"
}

while read -r conclusion want; do
  [ -n "$conclusion" ] || continue
  bin=$(gh_with_conclusion "\"$conclusion\"" "$(printf '%s' "$conclusion" | tr '[:upper:]' '[:lower:]')")
  with_path "$bin:$PATH" expect_verify "$want" - "conclusion $conclusion" -- pr-checks "$PR"
  pass "a check concluding $conclusion is $want"
done <<'EOF'
SUCCESS PASS
FAILURE FAIL
STARTUP_FAILURE FAIL
TIMED_OUT NO_VERIFIER_RAN
CANCELLED NO_VERIFIER_RAN
ACTION_REQUIRED NO_VERIFIER_RAN
SKIPPED NO_VERIFIER_RAN
STALE NO_VERIFIER_RAN
NEUTRAL NO_VERIFIER_RAN
EOF

with_path "$GH_NO_CONCLUSION:$PATH" expect_verify NO_VERIFIER_RAN no_verdict_reached \
  'absent conclusion' -- pr-checks "$PR"
pass "a check completing with no conclusion at all is NO_VERIFIER_RAN"

# ERROR is not a check-run conclusion: it comes from the older commit-status
# state vocabulary, which is why the rule reads .conclusion // .state. Asserted
# in its own shape so repartitioning cannot quietly drop one vocabulary.
GH_STATE_ERROR=$(make_gh "$TMP/gh-state-error" \
  '{"statusCheckRollup":[{"state":"ERROR"}]}')
with_path "$GH_STATE_ERROR:$PATH" expect_verify FAIL verifier_reported_failure \
  'commit status ERROR' -- pr-checks "$PR"
pass "a commit status in the ERROR state is FAIL, so both GitHub vocabularies stay live"

# A cancelled or timed-out run observed nothing: a superseding push killed it,
# or the clock did. Calling either FAIL asserts a verdict about the pull request
# that nothing earned, and hides a broken verifier among real failures.
for conclusion in TIMED_OUT CANCELLED; do
  bin=$(gh_with_conclusion "\"$conclusion\"" "notfail-$conclusion")
  with_path "$bin:$PATH" run_verify pr-checks "$PR"
  [ "$RESULT" != FAIL ] ||
    fail "$conclusion must not read as FAIL: nothing about the pull request was observed"
  with_path "$bin:$PATH" expect_verify NO_VERIFIER_RAN no_verdict_reached \
    "$conclusion is not a verdict" -- pr-checks "$PR"
done
pass "a cancelled or timed-out run is NO_VERIFIER_RAN, never a FAIL it did not earn"

# The mirror: a workflow that failed to start is terminal. Reporting it as
# could-not-observe sends the reader to "wait or re-run", the one action that
# cannot help, and the failure never resolves.
GH_STARTUP=$(gh_with_conclusion '"STARTUP_FAILURE"' notunverified-startup)
with_path "$GH_STARTUP:$PATH" run_verify pr-checks "$PR"
[ "$RESULT" != NO_VERIFIER_RAN ] ||
  fail "STARTUP_FAILURE must not read as could-not-observe: it is terminal and re-running reproduces it"
with_path "$GH_STARTUP:$PATH" expect_verify FAIL verifier_reported_failure \
  'startup failure' -- pr-checks "$PR"
pass "a workflow that failed to start is FAIL, not parked as unobservable"

# The default branch fails closed: a conclusion this rule has never heard of
# cannot fall into a verdict on its way past the last elif.
GH_UNKNOWN=$(gh_with_conclusion '"QUANTUM_INDETERMINATE"' unknown)
with_path "$GH_UNKNOWN:$PATH" expect_verify NO_VERIFIER_RAN no_verdict_reached \
  'unknown conclusion' -- pr-checks "$PR"
pass "a conclusion the rule does not know is NO_VERIFIER_RAN by design, not by omission"

# An unreachable forge is not a failing pull request. The exit-status wrapper
# calls it FAIL, which is a verdict nobody earned.
expect_naive_wrong naive_exit_strict FAIL \
  'unreachable forge, exit-status wrapper' -- \
  "$GH_DOWN/gh" pr view "$PR" --json statusCheckRollup
with_path "$GH_DOWN:$PATH" expect_verify NO_VERIFIER_RAN verification_unreachable \
  'unreachable forge' -- pr-checks "$PR"
pass "unreachable forge is NO_VERIFIER_RAN, not a failing pull request"

# --- fixture: git merge-tree, one exit code over two different answers -------

REPO="$TMP/merge"
git init -q -b main "$REPO"
git -C "$REPO" config user.email fmtest@example.invalid
git -C "$REPO" config user.name fmtest
printf 'a\n' >"$REPO/f"
git -C "$REPO" add f
git -C "$REPO" commit -qm base
git -C "$REPO" checkout -q -b conflicting
printf 'b\n' >"$REPO/f"
git -C "$REPO" commit -qam conflicting
git -C "$REPO" checkout -q -b clean main
printf 'z\n' >"$REPO/g"
git -C "$REPO" add g
git -C "$REPO" commit -qm clean
git -C "$REPO" checkout -q main
printf 'c\n' >"$REPO/f"
git -C "$REPO" commit -qam main

# The conflict still prints a written tree object, which is what fooled the
# output-presence wrapper. It exits 1, which is what the lenient exit-status
# wrapper misreads as "we could not look".
expect_naive_wrong naive_output_presence PASS \
  'merge conflict, output-presence wrapper' -- \
  git -C "$REPO" merge-tree --write-tree main conflicting
expect_naive_wrong naive_exit_lenient NO_VERIFIER_RAN \
  'merge conflict, lenient exit-status wrapper' -- \
  git -C "$REPO" merge-tree --write-tree main conflicting
expect_verify FAIL verifier_reported_failure \
  'merge conflict' -- merge-clean main conflicting "$REPO"
pass "merge conflict is FAIL even though a tree object was printed"

# The unresolvable ref exits 1 TOO. No exit-status-only mapping can get both
# this and the conflict right, which is the whole argument for the third value.
expect_naive_wrong naive_exit_strict FAIL \
  'unresolvable ref, strict exit-status wrapper' -- \
  git -C "$REPO" merge-tree --write-tree main nosuchref
# The output-presence wrapper reads stdout, where the unresolvable ref leaves
# nothing, so it lands on FAIL: a different wrong answer, not a right one.
expect_naive_wrong naive_output_presence FAIL \
  'unresolvable ref, output-presence wrapper' -- \
  git -C "$REPO" merge-tree --write-tree main nosuchref
expect_verify NO_VERIFIER_RAN verification_unreachable \
  'unresolvable ref' -- merge-clean main nosuchref "$REPO"
pass "unresolvable ref is NO_VERIFIER_RAN, sharing an exit code with a real verdict"

expect_verify PASS verified 'clean merge' -- merge-clean main clean "$REPO"
pass "a clean merge still passes"

# --- refusals ---------------------------------------------------------------

expect_verify NO_VERIFIER_RAN verifier_undeclared \
  'undeclared verifier' -- not-a-verifier arg
pass "an undeclared verifier is refused rather than run"

expect_verify NO_VERIFIER_RAN usage_error 'no verifier named' --
pass "a malformed call is NO_VERIFIER_RAN, never a pass"

expect_verify NO_VERIFIER_RAN usage_error 'comma in evidence path' -- \
  --evidence "$TMP/a,b.log" merge-clean main clean "$REPO"
pass "an evidence path that would corrupt the record is refused"

# --- evidence ---------------------------------------------------------------

EV="$TMP/evidence.log"
with_path "$BROWSER_BIN:$PATH" run_verify --evidence "$EV" browser open https://example.invalid
[ "$RESULT" = NO_VERIFIER_RAN ] || fail "evidence case: expected NO_VERIFIER_RAN, got $RESULT"
[ "$FM_VERIFY_EVIDENCE" = "$EV" ] || fail "record must point at the evidence file"
assert_grep 'Target closed' "$EV" "evidence must hold what was actually observed"
assert_grep 'exit_status: 0' "$EV" "evidence must record the misleading exit status"
pass "every result points at captured evidence, including a refusal"

# --- property 2: NO_VERIFIER_RAN is not coercible ---------------------------

UNVERIFIED_RECORD=$(printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  browser,NO_VERIFIER_RAN,verification_unreachable,/tmp/e.log\n')
PASS_RECORD=$(printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  browser,PASS,verified,/tmp/e.log\n')

saw() { printf 'saw:%s\n' "$FM_VERIFY_RESULT"; }
on_pass() { printf 'pass-branch\n'; }
on_fail() { printf 'fail-branch\n'; }
on_unverified() { printf 'unverified-branch\n'; }

got=$(fm_verify_case "$UNVERIFIED_RECORD" on_pass on_fail saw)
[ "$got" = "saw:NO_VERIFIER_RAN" ] ||
  fail "NO_VERIFIER_RAN must reach the consumer as itself, got '$got'"
pass "an unobservable case reaches the consumer as NO_VERIFIER_RAN, not downgraded en route"

got=$(fm_verify_case "$PASS_RECORD" on_pass on_fail on_unverified)
[ "$got" = pass-branch ] || fail "PASS must still reach the pass branch, got '$got'"
pass "PASS still means pass"

err=$(fm_verify_case "$UNVERIFIED_RECORD" on_pass on_fail 2>&1)
code=$?
expect_code 3 "$code" "two-handler consumer"
assert_contains "$err" 'must handle all three results' "two-handler consumer refusal"
pass "a consumer handling only two of the three results is refused"

err=$(fm_verify_case "$UNVERIFIED_RECORD" on_pass on_fail on_pass 2>&1)
code=$?
expect_code 3 "$code" "unverified aliased to pass"
assert_contains "$err" 'not coercible' "aliasing refusal"
err=$(fm_verify_case "$UNVERIFIED_RECORD" on_pass on_fail on_fail 2>&1)
code=$?
expect_code 3 "$code" "unverified aliased to fail"
assert_contains "$err" 'not coercible' "aliasing refusal"
pass "handling NO_VERIFIER_RAN as pass or fail is refused, not silently accepted"

err=$(fm_verify_case "$UNVERIFIED_RECORD" on_pass on_fail no_such_function 2>&1)
code=$?
expect_code 3 "$code" "undefined handler"
pass "a consumer naming a handler it never defined is refused"

err=$(fm_verify_case 'not a record' on_pass on_fail on_unverified 2>&1)
code=$?
expect_code 3 "$code" "unparseable record"
assert_contains "$err" 'unreadable result record' "unparseable record refusal"
pass "an unreadable record is refused, never read as an empty pass"

# Rejecting a record is only half the promise. A record refused on its LAST
# field must leave nothing behind either, or a consumer that reads the fields
# without the status sees a PASS extracted from a record just refused - the
# unparseable record read as an empty pass, one layer in.
REJECTED_RECORD=$(printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  browser,PASS,,/tmp/e.log\n')
! fm_verify_parse "$REJECTED_RECORD" || fail "a record with an empty reason must be rejected"
[ -z "$FM_VERIFY_RESULT" ] && [ -z "$FM_VERIFY_VERIFIER" ] &&
  [ -z "$FM_VERIFY_REASON" ] && [ -z "$FM_VERIFY_EVIDENCE" ] ||
  fail "a rejected record left fields behind: verifier='$FM_VERIFY_VERIFIER' result='$FM_VERIFY_RESULT' reason='$FM_VERIFY_REASON' evidence='$FM_VERIFY_EVIDENCE'"
pass "a rejected record leaves no partially-populated fields behind"

# --- the one sanctioned narrowing, which is loud and logged ------------------

LOG="$TMP/coercions.log"
out=$(FM_VERIFY_COERCION_LOG="$LOG" fm_verify_coerce "$UNVERIFIED_RECORD" PASS \
  'captain accepted the risk for this smoke run' 2>"$TMP/coerce.err")
code=$?
expect_code 0 "$code" "sanctioned coercion"
[ "$out" = PASS ] || fail "coercion must return its target, got '$out'"
assert_grep 'captain accepted the risk' "$LOG" "coercion must be logged"
assert_grep 'COERCED' "$TMP/coerce.err" "coercion must also be loud on stderr"
pass "narrowing NO_VERIFIER_RAN is possible only as an explicit, logged decision"

err=$(FM_VERIFY_COERCION_LOG="$LOG" fm_verify_coerce "$UNVERIFIED_RECORD" PASS '' 2>&1)
code=$?
expect_code 3 "$code" "coercion without a reason"
err=$(FM_VERIFY_COERCION_LOG="$LOG" fm_verify_coerce "$PASS_RECORD" FAIL 'because' 2>&1)
code=$?
expect_code 3 "$code" "coercion of an observed result"
assert_contains "$err" 'only NO_VERIFIER_RAN is coercible' "observed-result coercion refusal"
pass "a coercion with no reason, or of a result that was actually observed, is refused"

# --- the conformance obligation ---------------------------------------------
#
# Every declared verifier ships with a control proving its unobservable case is
# distinct. Adding one without such a control fails here rather than shipping a
# verifier that cannot say "I could not look".
COVERED='browser merge-clean pr-checks'
declared=$("$VERIFY" --list | LC_ALL=C sort | tr '\n' ' ')
declared=${declared% }
[ "$declared" = "$COVERED" ] ||
  fail "every declared verifier needs an unobservable-case control here; registry is '$declared', covered is '$COVERED'"
pass "each declared verifier has a witnessed unobservable-case control"

pass "fm-verify: three-valued observation contract holds"

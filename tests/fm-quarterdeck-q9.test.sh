#!/usr/bin/env bash
# Q9: the Quarterdeck honours gates/accepted-red.md, structurally, ahead of both
# models.
#
# The defect it freezes: bin/fm-verify.sh did not know accepted-red.md existed.
# Its verifier prompt told the model "every gate must be green; red or unproven
# gates are an automatic reject", which is unsatisfiable in a repo holding a
# declared red - and firstmate's own ledger holds two. CI honoured the baseline;
# the verifier contradicted it, so whether correct work was accepted depended on
# whether the LLM happened to reason about that file on a given run. Correct work
# was rejected non-deterministically, after the build, the pipeline, and CI.
#
# It asserts:
#   - a ledger whose only reds are declared PROCEEDS to the lens and verifier.
#   - an UNDECLARED red rejects, and does so WITHOUT SPENDING EITHER MODEL -
#     the whole point of adjudicating in front of them.
#   - a repo with no gates/ dir proceeds and never escalates. Most projects
#     firstmate ships to have no ledger at all; escalating on a missing file
#     would stop every one of them.
#   - gates/ with no accepted-red.md rejects an undeclared red rather than
#     treating "no declarations" as "nothing to declare".
#   - gates/ with no ledger, but WITH gate machinery (verify.sh or
#     accepted-red.md), escalates: the repo declares itself gate-governed and
#     the record of what is proven is gone. Fail closed, not open.
#   - a gates/ dir holding ordinary source and none of that machinery is NOT a
#     claim of gate governance and must proceed. "gates" is an ordinary
#     directory name, and fm-verify runs against every ship task in every
#     project firstmate manages, so escalating on the NAME conscripted
#     unrelated repos into a captain escalation on every task.
#   - a ledger carrying a delimiter in a gate id escalates rather than being
#     announced acceptable: a tab or newline there forges a classifier row.
#   - a ledger whose "gates" value is not a JSON array escalates rather than
#     being announced acceptable. The classifier once coerced an object into a
#     list, so {"gates": {}} yielded zero rows and fm-verify printed
#     "gates: acceptable" over a ledger it had read no gates from.
#   - a ledger citing a test file that no longer exists rejects as stale.
#   - a gate whose test_ref carries no ".test.sh" token is simply not
#     freshness-checked. Its test-path column is empty, and an empty middle
#     field must survive the row split rather than letting the next field slide
#     into it - which once made the gate's own declared reason read as a
#     missing test path.
#   - a declaration this branch ADDS to gates/accepted-red.md, and then relies
#     on to be acceptable, escalates instead of passing. accepted-red.md calls
#     itself a deliberate, reviewable statement, so a line a branch writes into
#     its own diff has been reviewed by nobody; a crewmate whose gate will not
#     go green could otherwise excuse it by writing the excuse. It escalates
#     rather than rejects because adding a baseline is legitimate work that a
#     human still has to say yes to.
#   - a declaration a branch adds for a gate that is GREEN, or that is not in
#     the ledger at all, excuses nothing and must not escalate.
#   - a declaration carried on origin/<default> is honoured even when the LOCAL
#     default branch is behind it. Pooled clones keep their local default frozen
#     at clone time, so a base resolved from it can predate the commit that
#     landed the declaration - and the branch that rebased onto the fetched
#     origin would be accused of forging a line it merely inherited.
#   - a declaration reachable only from the LOCAL default, while an origin
#     exists, ESCALATES. That ref is not a reviewed base: a pooled clone shares
#     it with the primary checkout, so an ordinary local commit would launder a
#     branch's own excuse into a baseline. With NO origin at all it is the only
#     candidate there is, so it is the base and fm-verify says so out loud; with
#     an origin configured but origin/<default> unresolvable, the base cannot be
#     established and the stage fails closed rather than degrading to a ref the
#     crewmate can write.
#   - an unproven gate or a stale test_ref in a gate THIS BRANCH TOUCHED still
#     rejects; one it merely inherited is reported as pre-existing ledger debt
#     and does not. Neither condition is visible to CI - run-all iterates tests
#     on disk, and an unproven gate's test passes by definition - so rejecting
#     repo-wide rejected every ship task in a repo carrying that debt, three
#     times, over work the crewmate did not do and could not undo.
#   - "touched" is decided per FIELD, over status and test_ref only. `ledger
#     verify` re-stamps last_verified on every gate it runs and a re-freeze
#     sweep is mandatory, so comparing whole ledger entries put nearly the whole
#     ledger back in scope on any gate-driven branch and undid the scoping.
#   - a RENAMED test file cannot hide from its own staleness check. Rename
#     detection prints only the destination path, so the old path the ledger
#     still cites vanished from the changed-file set and the gate fell out of
#     scope in exactly the case that check exists for.
#   - gates/LEDGER.md alone is gate machinery, so a repo holding only that and no
#     ledger.json escalates. `ledger verify` regenerates LEDGER.md, so it exists
#     in every gate-governed repo, while a repo with no declared reds
#     legitimately has no accepted-red.md.
#   - an origin that cannot be resolved must not narrow the LENS payload. The
#     origin-only base is a security rule about authorising a declaration; a
#     patch file authorises nothing, so the diff payload keeps its permissive
#     fallback and says out loud when it degrades.
#   - a BACKSLASH in a gate id cannot walk a self-authorised red past the guard.
#     awk escape-processes a -v assignment, so an id holding the two characters
#     \n arrived inside awk as a real newline and split in two while the base row
#     kept the backslash: the declared set never matched, and a red the branch
#     excused itself was announced acceptable. The set is read as an input file
#     instead, where no escape processing runs.
#   - a ./-prefixed test_ref cannot slip out of its own staleness scope. The
#     scope check compares byte for byte while the existence check normalizes, so
#     a file this branch DELETED was seen as gone and then excused as inherited
#     debt - a fail-open decided by nothing but how the path was spelled.
#   - when the reviewed base is unresolvable, scope is UNKNOWN: every offending
#     gate still rejects - fail closed - but the stage says so on stdout and the
#     reject text drops its "gates this branch touched" claim. Fail closed must
#     not mean fail dishonest: it once accused the crewmate of breaking gates it
#     had never seen, and the "not your responsibility" qualifier could not
#     appear because the pre-existing lists are empty in that state.
#   - a gate whose status is unproven REJECTS, and the relay tells the crewmate
#     to let the gate be observed red. The harness stamps unproven whenever a
#     gate test passes while first_observed_red is null (CONTRIBUTING.md), so it
#     is ordinary WIP, not a ledger a human has to interpret.
#   - a classifier header outside the documented set ESCALATES and names itself.
#     The gate stage was entered by EXCLUDING the inapplicable headers, so any
#     other one fell through with no rows and the stage announced "gates:
#     acceptable" over a ledger it had read not one gate from.
#   - the verifier prompt no longer carries a gate rule of its own. Two
#     authorities over one decision is what produced the contradiction.
#
# Mutation (LEDGER_MUTATE=1): the assertions demand the unsafe behaviour - that
# an undeclared red be approved. A correct implementation rejects it.
#
# spec: docs/specs/2026-07-01-agent-os-council.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verdict-lib.sh
. "$ROOT/bin/fm-verdict-lib.sh"

TMP=$(fm_test_tmproot fm-qd-q9)
S="$TMP/state"; D="$TMP/data"; mkdir -p "$S" "$D"
export FM_STATE_OVERRIDE="$S" FM_DATA_OVERRIDE="$D"
fm_git_identity

# Both models are stubs that leave a tripwire when they run, so "the ledger was
# adjudicated before either model" is observable rather than asserted.
LENS_TRIP="$TMP/lens-ran"; VERIFY_TRIP="$TMP/verify-ran"
cat > "$TMP/lens.sh" <<SH
#!/usr/bin/env bash
echo ran >> "$LENS_TRIP"
echo "stub lens review"
SH
cat > "$TMP/verify.sh" <<SH
#!/usr/bin/env bash
echo ran >> "$VERIFY_TRIP"
echo "VERDICT: approve - stub"
SH
chmod +x "$TMP/lens.sh" "$TMP/verify.sh"
export FM_LENS_CMD="$TMP/lens.sh"
: > "$TMP/relay.log"
cat > "$TMP/relay.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/relay.log"
SH
chmod +x "$TMP/relay.sh"
export FM_RELAY_CMD="$TMP/relay.sh"

# The two accepted-red.md bodies the cases use. DECL_RED declares the gate that
# is actually red; DECL_OTHER declares a different one, so the red stays
# undeclared.
DECL_RED='# Accepted red gates

- fx-red - a fixture baseline, accepted red on purpose; goes away when the other repo lands.'
DECL_OTHER='# Accepted red gates

- fx-some-other-gate - declared, but not the gate that is actually red.'

# task <id> [base-accepted-red] -> a repo + worktree + ship meta, worktree path
# echoed. When a body is given it is committed as gates/accepted-red.md on the
# default branch BEFORE the task branch exists, so it is present at the merge
# base - a reviewed baseline, which is the only kind fm-verify lets a ledger
# lean on. Without it the declaration exists only in the branch diff.
#
# The fixture branch is pinned to main rather than inherited from the host: any
# case whose ledger leans on a declared red reaches fm-verify's base comparison,
# and a host carrying init.defaultBranch=trunk would make every one of them
# escalate on an unresolvable base - failing with an exit-code mismatch that
# says nothing about the real cause. fm_git_init_commit is shared with other
# gates' fixtures, so the pin belongs here rather than in it.
task() {
  local id=$1 base=${2:-} repo="$TMP/$1-repo" wt="$TMP/$1-wt"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  if [ -n "$base" ]; then
    mkdir -p "$repo/gates"
    printf '%s\n' "$base" > "$repo/gates/accepted-red.md"
    git -C "$repo" add gates/accepted-red.md
    git -C "$repo" commit -qm "gates: reviewed red baseline"
  fi
  git -C "$repo" worktree add --quiet -b "fm/$id" "$wt"
  mkdir -p "$D/$id"
  fm_write_meta "$S/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$repo" \
    "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
  printf '%s\n' "$wt"
}

# gates <worktree> <declare-the-red>: a ledger with one green, one frozen and
# one red gate, the red declared or not.
gates() {
  local wt=$1 declare_red=$2
  mkdir -p "$wt/gates" "$wt/tests"
  : > "$wt/tests/aa.test.sh"; : > "$wt/tests/bb.test.sh"; : > "$wt/tests/cc.test.sh"
  cat > "$wt/gates/ledger.json" <<'JSON'
{
  "version": 1,
  "gates": [
    { "id": "fx-green",  "status": "green",  "test_ref": "bash tests/aa.test.sh" },
    { "id": "fx-frozen", "status": "frozen", "test_ref": "bash tests/bb.test.sh" },
    { "id": "fx-red",    "status": "red",    "test_ref": "bash tests/cc.test.sh" }
  ]
}
JSON
  if [ "$declare_red" = yes ]; then
    printf '%s\n' "$DECL_RED" > "$wt/gates/accepted-red.md"
  else
    printf '%s\n' "$DECL_OTHER" > "$wt/gates/accepted-red.md"
  fi
}

run() { FM_VERIFY_CMD="$TMP/verify.sh" "$ROOT/bin/fm-verify.sh" "$1" >"$TMP/$1.out" 2>&1; }

# --- case A: the only red is declared -> proceed, approve --------------------
WA=$(task a "$DECL_RED"); gates "$WA" yes
run a; codeA=$?
expect_code 0 "$codeA" "a ledger whose only red is DECLARED must not block acceptance;
demanding an all-green ledger is unsatisfiable while a declared baseline exists"
assert_grep "approve:" "$(fm_verdict_file "$S" a)" "the declared-red run reaches an approve"
assert_present "$VERIFY_TRIP" "the verifier must actually run when the ledger is acceptable"
assert_grep "gates: acceptable" "$TMP/a.out" "the acceptable verdict is announced, not silent"

# --- case B: an UNDECLARED red -> reject, before either model ----------------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WB=$(task b); gates "$WB" no
run b; codeB=$?

if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  # MUTATION: demand that an undeclared red sail through. A correct
  # implementation rejects it, so this fails.
  expect_code 0 "$codeB" "MUTATION: expected an undeclared red gate to be approved"
  assert_grep "approve:" "$(fm_verdict_file "$S" b)" "MUTATION: expected an approve"
else
  expect_code 2 "$codeB" "a red gate that is NOT declared must reject"
  assert_grep "reject: (attempt 1 of 3)" "$(fm_verdict_file "$S" b)" \
    "the gate reject is recorded with an attempt count, like any other reject"
  assert_grep "fx-red" "$(fm_verdict_file "$S" b)" "the reject names the offending gate"
  assert_grep "QUARTERDECK REJECTED" "$TMP/relay.log" "the finding is relayed to the crewmate"
  assert_absent "$LENS_TRIP" \
    "an unacceptable ledger must reject BEFORE the foreign lens - adjudicating
after the models is the expense this stage exists to avoid"
  assert_absent "$VERIFY_TRIP" "an unacceptable ledger must reject BEFORE the verifier"
fi

# --- case C: no gates/ dir -> not applicable, never an escalation ------------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
task c >/dev/null   # no gates/ dir in this one
run c; codeC=$?
expect_code 0 "$codeC" "a repo with no gates/ dir must proceed normally"
assert_no_grep "escalate:" "$(fm_verdict_file "$S" c)" \
  "a missing gates/ dir must never escalate - most projects have no ledger at all"
assert_present "$VERIFY_TRIP" "with no gates/ dir the verifier still runs"

# --- case D: gates/ but no accepted-red.md -> the red is undeclared ----------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WD=$(task d); gates "$WD" yes; rm -f "$WD/gates/accepted-red.md"
run d; codeD=$?
expect_code 2 "$codeD" "with no accepted-red.md, no red is declared, so a red rejects"
assert_absent "$VERIFY_TRIP" "the no-declarations reject also precedes the verifier"

# --- case E: gates/ but no ledger -> escalate, fail closed ------------------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WE=$(task e); gates "$WE" yes; rm -f "$WE/gates/ledger.json"
run e; codeE=$?
expect_code 3 "$codeE" "gates/ with no ledger must escalate, never approve"
assert_grep "escalate:" "$(fm_verdict_file "$S" e)" "the missing ledger is recorded as an escalation"
assert_no_grep "approve:" "$(fm_verdict_file "$S" e)" "an unprovable ledger must never approve"

# --- case F: a ledger citing a test file that is gone -> stale, reject -------
#
# This proves only that the ledger is not referencing tests that no longer
# exist. It does NOT prove any test passes - that is CI's job, and re-running
# the suite here would duplicate it at the most expensive moment.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WF=$(task f "$DECL_RED"); gates "$WF" yes; rm -f "$WF/tests/aa.test.sh"
run f; codeF=$?
expect_code 2 "$codeF" "a ledger claiming a gate whose test file is gone is stale, and rejects"
assert_grep "fx-green" "$(fm_verdict_file "$S" f)" "the stale reject names the gate"
assert_grep "tests/aa.test.sh" "$(fm_verdict_file "$S" f)" "the stale reject names the missing test"

# --- case H: a non-array "gates" escalates, and is never called acceptable ---
#
# The end of the fail-open Q8 covers at the unit level: an object-shaped ledger
# must not reach the models, and must never be announced as acceptable.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WH=$(task h); gates "$WH" yes
printf '%s\n' '{"version": 1, "gates": {}}' > "$WH/gates/ledger.json"
run h; codeH=$?
expect_code 3 "$codeH" "a gates value that is not a JSON array must escalate, never approve"
assert_grep "escalate:" "$(fm_verdict_file "$S" h)" "the bad shape is recorded as an escalation"
assert_no_grep "approve:" "$(fm_verdict_file "$S" h)" "a ledger the harness refuses to load must never approve"
assert_no_grep "gates: acceptable" "$TMP/h.out" \
  "fm-verify must not announce an unreadable-shaped ledger as acceptable"
assert_absent "$VERIFY_TRIP" "the bad-shape escalation also precedes the verifier"

# --- case I: a delimiter-bearing gate id escalates, never "acceptable" -------
#
# The fm-verify half of the forgery Q8 covers at the unit level. A gate id
# carrying a tab or newline can write extra verdict rows, so the ledger cannot
# be trusted at all - and an untrustworthy ledger is a human's problem, not
# something to announce as acceptable and wave through to the models.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WI=$(task i); gates "$WI" yes
python3 - "$WI/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-green":
        g["id"] = "evil\nok\tforged\tred\ttests/aa.test.sh\tforged reason"
open(p, "w").write(json.dumps(d, indent=2))
PY
run i; codeI=$?
expect_code 3 "$codeI" "a gate id carrying a row delimiter must escalate, never approve"
assert_grep "escalate:" "$(fm_verdict_file "$S" i)" "the forgeable ledger is recorded as an escalation"
assert_no_grep "approve:" "$(fm_verdict_file "$S" i)" "a forgeable ledger must never approve"
assert_no_grep "gates: acceptable" "$TMP/i.out" \
  "fm-verify must not announce a ledger that can forge its own verdicts as acceptable"
assert_absent "$VERIFY_TRIP" "the forgery escalation also precedes the verifier"

# --- case J: no ".test.sh" token means no freshness check, never a reject ----
#
# The freshness cross-check splits tab-separated rows, and an EMPTY MIDDLE FIELD
# has to stay empty. `IFS=<tab> read` collapses runs of tabs, so a red-and-
# declared gate with no ".test.sh" token in its test_ref had its declared REASON
# read as a test path, and fm-verify rejected the crewmate for a "missing test
# file" the ledger never named - the same spurious reject this whole stage
# exists to remove. A gate with no readable test path has nothing to check.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WJ=$(task j "$DECL_RED"); gates "$WJ" yes
python3 - "$WJ/gates/ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-red":
        g["test_ref"] = "pytest tests/x.py"
open(p, "w").write(json.dumps(d, indent=2))
PY
run j; codeJ=$?
expect_code 0 "$codeJ" "a red-and-declared gate whose test_ref holds no .test.sh token
has no test path to check, and must never be rejected over its own declared reason"
assert_grep "gates: acceptable" "$TMP/j.out" \
  "the ledger is acceptable: its only red is declared, and the gate with no
readable test path is simply not freshness-checked"
assert_no_grep "reject:" "$(fm_verdict_file "$S" j)" \
  "no stale-test reject may be recorded for a path the ledger never claimed"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# --- case K: a declaration this branch added itself -> escalate --------------
#
# The base declares a DIFFERENT gate, so the reviewed baseline exists but says
# nothing about fx-red; the branch adds that line to its own diff. Nobody has
# reviewed it, and the ledger leans on it to be acceptable, so it is the
# captain who decides - never a silent pass.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WK=$(task k "$DECL_OTHER"); gates "$WK" yes
run k; codeK=$?
expect_code 3 "$codeK" "a red excused only by a declaration this branch added must escalate"
assert_grep "escalate:" "$(fm_verdict_file "$S" k)" "the self-authorised red is recorded as an escalation"
assert_grep "fx-red" "$(fm_verdict_file "$S" k)" "the escalation names the gate whose declaration is new"
assert_no_grep "approve:" "$(fm_verdict_file "$S" k)" "a branch must never authorise its own red"
assert_no_grep "gates: acceptable" "$TMP/k.out" \
  "fm-verify must not announce a self-authorised red as acceptable"
assert_absent "$VERIFY_TRIP" "the self-authorisation escalation also precedes the verifier"

# --- case L: no accepted-red.md at the base at all -> unverifiable, escalate -
#
# Fail closed: with nothing to compare against, whether the declaration was ever
# reviewed cannot be established, and "cannot establish" is not "fine".
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WL=$(task l); gates "$WL" yes
run l; codeL=$?
expect_code 3 "$codeL" "a declared red with no base copy of accepted-red.md must escalate"
assert_grep "escalate:" "$(fm_verdict_file "$S" l)" "the unverifiable declaration is recorded as an escalation"
assert_no_grep "approve:" "$(fm_verdict_file "$S" l)" "an unverifiable declaration must never approve"

# --- case M: a new declaration the ledger does not rely on -> unaffected -----
#
# Only RELIED-UPON declarations matter. Declaring a gate that is green, or one
# that is not in the ledger at all, excuses nothing, so it must not escalate -
# otherwise every edit to that file would wake the captain.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WM=$(task m "$DECL_RED"); gates "$WM" yes
cat >> "$WM/gates/accepted-red.md" <<'MD'
- fx-green - declared, but this gate is green, so the declaration excuses nothing.
- fx-not-in-the-ledger - declared, and no such gate exists.
MD
run m; codeM=$?
expect_code 0 "$codeM" "declaring a green or absent gate changes nothing and must not escalate"
assert_grep "approve:" "$(fm_verdict_file "$S" m)" "the run proceeds to an approve"
assert_no_grep "escalate:" "$(fm_verdict_file "$S" m)" \
  "a declaration the ledger does not lean on must never escalate"
assert_present "$VERIFY_TRIP" "the run reaches the verifier"

# --- case N: an unproven gate rejects, and is never a captain escalation -----
#
# The harness stamps unproven whenever a gate test passes while
# first_observed_red is null (CONTRIBUTING.md, "Born-green gates are refused"),
# so it is the ordinary transient state of gate-driven development and the
# commonest non-clean status a crewmate can produce. It is crewmate-actionable:
# let the gate be observed red. Sending it to the captain instead was both a
# wrong route and a wrong claim - the repo does have a rule for it.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WN=$(task n "$DECL_RED"); gates "$WN" yes
python3 - "$WN/gates/ledger.json" <<'PYX'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    if g["id"] == "fx-green":
        g["status"] = "unproven"
open(p, "w").write(json.dumps(d, indent=2))
PYX
run n; codeN=$?
expect_code 2 "$codeN" "an unproven gate is crewmate-actionable and must reject, not escalate"
assert_grep "reject: (attempt 1 of 3)" "$(fm_verdict_file "$S" n)" \
  "the unproven reject is recorded with an attempt count, like any other reject"
assert_grep "fx-green" "$(fm_verdict_file "$S" n)" "the reject names the unproven gate"
assert_no_grep "escalate:" "$(fm_verdict_file "$S" n)" \
  "unproven must never take the captain path - this repo has a rule for it"
assert_grep "observed red" "$TMP/relay.log" \
  "the relay tells the crewmate to let the gate be observed red first"
assert_absent "$VERIFY_TRIP" "the unproven reject also precedes the verifier"

# --- case O: a stale LOCAL default must not read an inherited line as forged -
#
# Pooled project clones keep their local default branch frozen at clone time
# (bin/fm-review-diff.sh exists for exactly this), so a merge base taken against
# it can predate the very commit that landed a declaration. The crewmate rebases
# onto the fetched origin, inherits that reviewed line, and a base resolved from
# the stale local branch would accuse it of forging one - a false captain
# escalation, the class of spurious block this whole stage exists to remove.
#
# The fixture makes the two answers disagree: origin/main carries the reviewed
# declaration and local main is rewound behind it, so only a base resolved from
# origin lets this run proceed.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
repo_o="$TMP/o-repo"; wt_o="$TMP/o-wt"
fm_git_init_commit "$repo_o"
git -C "$repo_o" branch -M main
stale_o=$(git -C "$repo_o" rev-parse HEAD)
fm_git_add_origin "$repo_o" "$TMP/o-remote.git"
mkdir -p "$repo_o/gates"
printf '%s\n' "$DECL_RED" > "$repo_o/gates/accepted-red.md"
git -C "$repo_o" add gates/accepted-red.md
git -C "$repo_o" commit -qm "gates: reviewed red baseline"
git -C "$repo_o" push -q origin main
git -C "$repo_o" worktree add --quiet -b fm/o "$wt_o"
# Only now rewind the LOCAL default, leaving origin/main ahead of it.
git -C "$repo_o" reset --hard --quiet "$stale_o"
mkdir -p "$D/o"
fm_write_meta "$S/o.meta" \
  "window=firstmate:fm-o" "worktree=$wt_o" "project=$repo_o" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
gates "$wt_o" yes
run o; codeO=$?
expect_code 0 "$codeO" "a declaration present on origin/<default> is a reviewed baseline
even when the local default branch is behind it; resolving the base from that stale
local branch accuses a rebased crewmate of forging a line it merely inherited"
assert_grep "gates: acceptable" "$TMP/o.out" \
  "the inherited declaration is honoured, so the ledger is acceptable"
assert_no_grep "escalate:" "$(fm_verdict_file "$S" o)" \
  "a stale local default must never produce a self-authorised-red escalation"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# --- case P: a declaration on a LOCAL default only is NOT a reviewed base ----
#
# The bypass case. An earlier round chose the furthest-forward merge base so
# that a declaration committed to an unpushed local default would not read as
# forged - a usability argument about a guard whose whole purpose is security.
# The candidates are not equal: origin/<default> takes a push to a protected
# branch, while refs/heads/<default> takes an ordinary local commit, and
# firstmate's project clones are POOLED, so a crewmate worktree shares that ref
# with the primary checkout. Ranking them by position therefore made the bypass
# the ordinary path rather than an attack, and it is withdrawn.
#
# The fixture pushes a declaration-free main, then lands the declaration on the
# LOCAL default only. Nobody has reviewed it, so it must reach the captain.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
repo_p="$TMP/p-repo"; wt_p="$TMP/p-wt"
fm_git_init_commit "$repo_p"
git -C "$repo_p" branch -M main
fm_git_add_origin "$repo_p" "$TMP/p-remote.git"
git -C "$repo_p" push -q origin main
# The declaration lands on local main only - origin/main stays behind it.
mkdir -p "$repo_p/gates"
printf '%s\n' "$DECL_RED" > "$repo_p/gates/accepted-red.md"
git -C "$repo_p" add gates/accepted-red.md
git -C "$repo_p" commit -qm "gates: red baseline, local default only"
git -C "$repo_p" worktree add --quiet -b fm/p "$wt_p"
mkdir -p "$D/p"
fm_write_meta "$S/p.meta" \
  "window=firstmate:fm-p" "worktree=$wt_p" "project=$repo_p" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
gates "$wt_p" yes
run p; codeP=$?
expect_code 3 "$codeP" "a declaration reachable only from the LOCAL default branch has been
reviewed by nobody - a pooled clone shares that ref with the primary checkout, so an
ordinary local commit would otherwise launder a branch's own excuse into a baseline"
assert_grep "escalate:" "$(fm_verdict_file "$S" p)" \
  "the unreviewed local-only declaration is recorded as an escalation"
assert_grep "fx-red" "$(fm_verdict_file "$S" p)" "the escalation names the gate it excuses"
assert_no_grep "approve:" "$(fm_verdict_file "$S" p)" \
  "a declaration the crewmate could have written itself must never approve"
assert_absent "$VERIFY_TRIP" "the escalation precedes the verifier"

# --- case Q: no origin remote at all -> the local default IS the base --------
#
# For a local-only project refs/heads/<default> is the only candidate there is,
# so it is the base, and fm-verify says out loud that the base is only as
# trustworthy as that branch rather than pretending to a review that never
# happened.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WQ=$(task q "$DECL_RED"); gates "$WQ" yes
[ -z "$(git -C "$TMP/q-repo" remote)" ] || fail "case Q fixture must have no remote at all"
run q; codeQ=$?
expect_code 0 "$codeQ" "with no origin remote there is no second candidate, so the local
default branch is the base and a declaration carried on it is the reviewed baseline"
assert_grep "gates: acceptable" "$TMP/q.out" \
  "the local default answers the base comparison for a project with no remote"
assert_grep "no origin remote" "$TMP/q.out" \
  "fm-verify must say that a local-only base is only as trustworthy as the local default"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# --- case R: an origin that cannot be resolved -> escalate, never degrade ----
#
# The counterpart to case Q, and the reason the fallback is not "try the local
# branch next". An origin IS configured, so refs/heads/<default> is a ref the
# crewmate can write; falling back to it when the fetch fails would hand any
# crewmate the bypass just by making origin unreachable. The base cannot be
# established, so the stage fails closed.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
repo_r="$TMP/r-repo"; wt_r="$TMP/r-wt"
fm_git_init_commit "$repo_r"
git -C "$repo_r" branch -M main
# An origin that does not exist: the fetch fails and no cached origin/main
# was ever created, so there is no reviewed candidate at all.
git -C "$repo_r" remote add origin "file://$TMP/r-remote-does-not-exist.git"
mkdir -p "$repo_r/gates"
printf '%s\n' "$DECL_RED" > "$repo_r/gates/accepted-red.md"
git -C "$repo_r" add gates/accepted-red.md
git -C "$repo_r" commit -qm "gates: reviewed red baseline"
git -C "$repo_r" worktree add --quiet -b fm/r "$wt_r"
mkdir -p "$D/r"
fm_write_meta "$S/r.meta" \
  "window=firstmate:fm-r" "worktree=$wt_r" "project=$repo_r" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
gates "$wt_r" yes
run r; codeR=$?
expect_code 3 "$codeR" "with an origin configured but origin/<default> unresolvable, the
reviewed base cannot be established - degrading to the local branch would hand every
crewmate the bypass simply by making origin unreachable"
assert_grep "escalate:" "$(fm_verdict_file "$S" r)" \
  "an unestablishable base is recorded as an escalation"
assert_no_grep "approve:" "$(fm_verdict_file "$S" r)" \
  "a declaration whose review cannot be established must never approve"
assert_absent "$VERIFY_TRIP" "the fail-closed escalation precedes the verifier"

# --- case S: a gates/ dir that is not gate machinery -> not applicable -------
#
# "gates" is an ordinary directory name - a Go package, a Python module, a
# state-machine dir - and fm-verify runs against every ship task in every
# project firstmate manages. Escalating on the directory NAME conscripted
# unrelated repos into a captain escalation on every single task, with no
# crewmate-side remedy. What claims gate governance is the machinery:
# gates/ledger.json, gates/verify.sh, gates/accepted-red.md.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WS=$(task s)
mkdir -p "$WS/gates"
printf 'package gates\n' > "$WS/gates/registry.go"
printf 'type Gate struct{}\n' > "$WS/gates/gate.go"
run s; codeS=$?
expect_code 0 "$codeS" "a gates/ directory holding ordinary source and no ledger, verify.sh
or accepted-red.md is not a gate-governed repo, and must proceed rather than escalate
every ship task in it to the captain"
assert_no_grep "escalate:" "$(fm_verdict_file "$S" s)" \
  "a directory that merely shares the name gates/ must never escalate"
assert_grep "not a gate-governed repo" "$TMP/s.out" \
  "the not-applicable answer is announced rather than silently assumed"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# Case E's counterpart: with the machinery present and the ledger gone, the
# record of what is proven really is absent, and the escalation is right.
# (Case E above covers that, and keeps gates/accepted-red.md in place.)

# --- ledger debt: whose is it? ------------------------------------------------
#
# An unproven gate and a test_ref naming a file that is not on disk are both
# invisible to CI - run-all iterates tests/*.test.sh ON DISK, so a ledger citing
# a deleted test never fails the suite, and an unproven gate's test passes by
# definition. Rejecting on either one repo-wide therefore rejected EVERY ship
# task dispatched into a repo carrying that debt: three relays the crewmate
# could not act on, then a captain escalation, while the pipeline and CI stayed
# green. So both are scoped to the gates this branch's own diff touches.
#
# scope_repo <id> <ledger-json>: a repo whose DEFAULT BRANCH already carries the
# gate machinery - reviewed baseline, ledger, tests - plus a task worktree
# branched off it. That is what makes "did this branch touch that gate" a real
# question: with the ledger arriving in the branch diff, every gate in it is
# this branch's by construction.
scope_repo() {
  local id=$1 ledger=$2 repo="$TMP/$1-repo" wt="$TMP/$1-wt"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  mkdir -p "$repo/gates" "$repo/tests"
  printf '%s\n' "$DECL_RED" > "$repo/gates/accepted-red.md"
  printf '%s\n' "$ledger" > "$repo/gates/ledger.json"
  : > "$repo/tests/aa.test.sh"; : > "$repo/tests/bb.test.sh"; : > "$repo/tests/cc.test.sh"
  git -C "$repo" add gates tests
  git -C "$repo" commit -qm "gates: reviewed baseline"
  git -C "$repo" worktree add --quiet -b "fm/$id" "$wt"
  mkdir -p "$D/$id"
  fm_write_meta "$S/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$repo" \
    "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
  printf '%s\n' "$wt"
}

LEDGER_CLEAN='{
  "version": 1,
  "gates": [
    { "id": "fx-green",  "status": "green",  "test_ref": "bash tests/aa.test.sh" },
    { "id": "fx-frozen", "status": "frozen", "test_ref": "bash tests/bb.test.sh" },
    { "id": "fx-red",    "status": "red",    "test_ref": "bash tests/cc.test.sh" }
  ]
}'
LEDGER_UNPROVEN=${LEDGER_CLEAN/\"fx-green\",  \"status\": \"green\"/\"fx-green\",  \"status\": \"unproven\"}
LEDGER_STALE=${LEDGER_CLEAN/bash tests\/aa.test.sh/bash tests\/zz.test.sh}

# unrelated_commit <worktree>: work that touches no gate and no test.
unrelated_commit() {
  mkdir -p "$1/src"
  printf 'hello\n' > "$1/src/thing.txt"
  git -C "$1" add src/thing.txt
  git -C "$1" commit -qm "unrelated work"
}

# --- case T: an unproven gate this branch did NOT touch -> report, not reject -
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WT=$(scope_repo t "$LEDGER_UNPROVEN"); unrelated_commit "$WT"
run t; codeT=$?
expect_code 0 "$codeT" "pre-existing unproven debt in a gate this branch never touched must
not reject - it is invisible to CI, so it would reject every ship task in that repo, three
times, over work the crewmate did not do and cannot undo"
assert_grep "pre-existing ledger debt" "$TMP/t.out" \
  "inherited debt is REPORTED rather than silently dropped"
assert_grep "fx-green" "$TMP/t.out" "the report names the gate carrying the debt"
assert_no_grep "reject:" "$(fm_verdict_file "$S" t)" "inherited debt must not be a reject"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# --- case U: an unproven gate this branch ADDED -> still rejects -------------
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WU=$(scope_repo u "$LEDGER_CLEAN")
python3 - "$WU/gates/ledger.json" <<'PYU'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["gates"].append({"id": "fx-new", "status": "unproven", "test_ref": "bash tests/dd.test.sh"})
open(p, "w").write(json.dumps(d, indent=2))
PYU
: > "$WU/tests/dd.test.sh"
git -C "$WU" add gates/ledger.json tests/dd.test.sh
git -C "$WU" commit -qm "gates: register a new gate"
run u; codeU=$?
expect_code 2 "$codeU" "an unproven gate whose ledger entry this branch added is squarely
the crewmate's, and still rejects"
assert_grep "fx-new" "$(fm_verdict_file "$S" u)" "the reject names the gate this branch added"
assert_grep "observed red" "$TMP/relay.log" \
  "the relay still tells the crewmate to let the gate be observed red"
assert_absent "$VERIFY_TRIP" "the in-scope reject still precedes the verifier"

# --- case V: a test file THIS BRANCH deleted -> stale, and still rejects -----
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WV=$(scope_repo v "$LEDGER_CLEAN")
git -C "$WV" rm -q tests/aa.test.sh
git -C "$WV" commit -qm "drop a test the ledger still cites"
run v; codeV=$?
expect_code 2 "$codeV" "deleting a test the ledger still cites is this branch's own staleness -
the deletion is in its diff - and must still reject"
assert_grep "fx-green" "$(fm_verdict_file "$S" v)" "the stale reject names the gate"
assert_grep "tests/aa.test.sh" "$(fm_verdict_file "$S" v)" "the stale reject names the test"
assert_absent "$VERIFY_TRIP" "the in-scope stale reject still precedes the verifier"

# --- case W: a stale test_ref this branch did NOT touch -> report, not reject -
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WW=$(scope_repo w "$LEDGER_STALE"); unrelated_commit "$WW"
run w; codeW=$?
expect_code 0 "$codeW" "a ledger that already cited a missing test at the base is inherited
debt, invisible to CI, and must not reject work that never touched that gate"
assert_grep "pre-existing ledger debt" "$TMP/w.out" \
  "the inherited stale reference is reported rather than silently dropped"
assert_grep "tests/zz.test.sh" "$TMP/w.out" "the report names the test the ledger still cites"
assert_no_grep "reject:" "$(fm_verdict_file "$S" w)" "inherited staleness must not be a reject"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# --- case X: a gate whose ONLY diff is a refreshed last_verified -------------
#
# The scope comparison must key on the fields the two conditions actually turn
# on, not on the whole entry. `ledger verify` re-stamps last_verified on every
# gate it RUNS, and CONTRIBUTING.md mandates a re-freeze sweep after any change,
# so comparing whole entries put nearly the entire ledger back in scope on an
# ordinary gate-driven branch - undoing the scoping altogether.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WX=$(scope_repo x "$LEDGER_STALE")
python3 - "$WX/gates/ledger.json" <<'PYX2'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for g in d["gates"]:
    g["last_verified"] = "2026-08-31T00:00:00Z"
    g["mutation_verified"] = "2026-08-31T00:00:00Z"
    g["first_observed_red"] = "2026-08-30T00:00:00Z"
open(p, "w").write(json.dumps(d, indent=2))
PYX2
git -C "$WX" add gates/ledger.json
git -C "$WX" commit -qm "gates: re-stamp every gate after a verify sweep"
run x; codeX=$?
expect_code 0 "$codeX" "a gate whose only difference from the base is a bookkeeping re-stamp
was not touched in any sense the debt conditions care about; comparing whole ledger entries
put the entire ledger back in scope on every gate-driven branch and undid the scoping"
assert_grep "pre-existing ledger debt" "$TMP/x.out" \
  "the inherited staleness is still reported, just not charged to this branch"
assert_grep "tests/zz.test.sh" "$TMP/x.out" "the report names the test the ledger still cites"
assert_no_grep "reject:" "$(fm_verdict_file "$S" x)" \
  "a re-stamped gate must not be rejected as though this branch had touched it"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# --- case Y: a RENAMED test file cannot hide from its own staleness check -----
#
# Rename detection is on by default (diff.renames since git 2.9) and prints only
# the DESTINATION path, so a crewmate who renames a test file and forgets to
# update the gate's test_ref left the ledger entry unchanged AND the old path
# invisible: the gate fell out of scope and its staleness was merely reported -
# in exactly the case the staleness check exists for. --no-renames puts both
# paths in the changed-file set.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WY=$(scope_repo y "$LEDGER_CLEAN")
git -C "$WY" mv tests/aa.test.sh tests/renamed-aa.test.sh
git -C "$WY" commit -qm "rename a test the ledger still cites by its old path"
run y; codeY=$?
expect_code 2 "$codeY" "renaming a test file without updating the gate's test_ref is this
branch's own staleness - the old path is in its diff - and must still reject; rename
detection hides that old path unless the diff is taken with --no-renames"
assert_grep "fx-green" "$(fm_verdict_file "$S" y)" "the stale reject names the gate"
assert_grep "tests/aa.test.sh" "$(fm_verdict_file "$S" y)" \
  "the stale reject names the path the ledger still cites, not the new one"
assert_absent "$VERIFY_TRIP" "the in-scope stale reject still precedes the verifier"

# --- case Z: gates/LEDGER.md alone is gate machinery -> escalate --------------
#
# LEDGER.md is regenerated by `ledger verify` (CONTRIBUTING.md), so it exists in
# every gate-governed repo, while a repo with no declared reds legitimately has
# no accepted-red.md and gates/verify.sh is a firstmate convention rather than
# something the CLI creates. Omitting it let a gate-governed repo holding only
# ledger.json + LEDGER.md proceed SILENTLY once its ledger.json went missing -
# the exact fail-open this test exists to prevent. It also cannot conscript an
# unrelated Go or Python gates/ package, which will not contain it (case S).
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
WZ=$(task z)
mkdir -p "$WZ/gates"
printf '# Gate ledger\n\nGenerated by the ledger CLI; never hand-edited.\n' > "$WZ/gates/LEDGER.md"
run z; codeZ=$?
expect_code 3 "$codeZ" "gates/ holding only LEDGER.md and no ledger.json is a gate-governed
repo whose record of what is proven is gone, and must escalate rather than proceed silently"
assert_grep "escalate:" "$(fm_verdict_file "$S" z)" "the missing ledger is recorded as an escalation"
assert_grep "LEDGER.md" "$(fm_verdict_file "$S" z)" \
  "the escalation names the machinery that made this a gate-governed repo"
assert_no_grep "approve:" "$(fm_verdict_file "$S" z)" "an unprovable ledger must never approve"
assert_absent "$VERIFY_TRIP" "the fail-closed escalation precedes the verifier"

# --- case AA: an unresolvable origin must not narrow the LENS payload ---------
#
# The two bases answer different questions. Origin-only is right for the
# self-authorisation guard, where a ref the crewmate can write must not certify
# the crewmate's own declaration. It is wrong for the diff payload, which
# authorises nothing: tying the lens to it meant an origin that merely could not
# be REACHED cut the review down to `git show HEAD` - the top commit alone - for
# every project, including the majority with no gates/ dir at all. Worse review,
# identical safety.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"
repo_aa="$TMP/aa-repo"; wt_aa="$TMP/aa-wt"
fm_git_init_commit "$repo_aa"
git -C "$repo_aa" branch -M main
git -C "$repo_aa" remote add origin "file://$TMP/aa-remote-does-not-exist.git"
git -C "$repo_aa" worktree add --quiet -b fm/aa "$wt_aa"
mkdir -p "$D/aa"
fm_write_meta "$S/aa.meta" \
  "window=firstmate:fm-aa" "worktree=$wt_aa" "project=$repo_aa" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
# Two commits, so "whole branch" and "HEAD only" are distinguishable.
printf 'one\n' > "$wt_aa/first.txt"
git -C "$wt_aa" add first.txt
git -C "$wt_aa" commit -qm "branch work: the first commit"
printf 'two\n' > "$wt_aa/second.txt"
git -C "$wt_aa" add second.txt
git -C "$wt_aa" commit -qm "branch work: the second commit"
run aa; codeAA=$?
expect_code 0 "$codeAA" "a repo with no gates/ dir and an unreachable origin has nothing to
adjudicate and must still proceed"
assert_grep "branch work: the first commit" "$D/aa/lens-diff.patch" \
  "the foreign lens must see the WHOLE branch: the origin-only base is a security rule
about authorising a declaration, and a patch file authorises nothing, so an unreachable
origin must not silently narrow the review to the top commit"
assert_grep "first.txt" "$D/aa/lens-diff.patch" \
  "the earlier commit's changes are in the payload, not just the last commit's"
assert_grep "untrusted as an authorisation base" "$TMP/aa.out" \
  "the fallback is announced on stdout, where an operator reads it, not only inside
the patch file"
assert_present "$VERIFY_TRIP" "the run proceeds to the verifier"

# --- case AB: a backslash in a gate id must not walk past the self-auth guard --
#
# awk performs ESCAPE-SEQUENCE processing on a -v assignment, so passing the
# declared-red set as -v want="..." made a gate id holding the two characters \n
# arrive inside awk as a real newline and split into the keys "fx" and "red",
# while the base row still carried the literal backslash. `$2 in d` never
# matched, so a declaration this branch added to its own diff sailed through the
# one guard that exists to catch it - the same forgery class as a delimiter in a
# gate id, and defeating the whole property the stage claims to establish.
#
# The fix removes the escape processing rather than escaping around it: the set
# is read as awk's first INPUT FILE, and field values read from input are not
# escape-processed. Restoring the -v form makes this case pass with exit 0.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WAB=$(task ab "$DECL_OTHER")
mkdir -p "$WAB/gates" "$WAB/tests"
: > "$WAB/tests/aa.test.sh"; : > "$WAB/tests/cc.test.sh"
cat > "$WAB/gates/ledger.json" <<'JSON'
{
  "version": 1,
  "gates": [
    { "id": "fx-green", "status": "green", "test_ref": "bash tests/aa.test.sh" },
    { "id": "fx\\nred", "status": "red",   "test_ref": "bash tests/cc.test.sh" }
  ]
}
JSON
cat > "$WAB/gates/accepted-red.md" <<'DECL'
# Accepted red gates

- fx\nred - a red this branch excuses by writing the excuse itself.
DECL
run ab; codeAB=$?
expect_code 3 "$codeAB" "a gate id holding a literal backslash-n must not slip past the
self-authorisation guard: awk escape-processes a -v assignment, so the declared set arrived
with that id split in two while the base row kept the backslash, and a red the branch
excused itself was announced acceptable"
assert_grep "escalate:" "$(fm_verdict_file "$S" ab)" \
  "the self-authorised red is recorded as an escalation, backslash in the id or not"
assert_grep 'fx\nred' "$(fm_verdict_file "$S" ab)" \
  "the escalation names the gate whose declaration this branch wrote"
assert_no_grep "approve:" "$(fm_verdict_file "$S" ab)" \
  "a branch must never authorise its own red, however the gate is spelled"
assert_no_grep "gates: acceptable" "$TMP/ab.out" \
  "fm-verify must not announce a self-authorised red as acceptable"
assert_absent "$VERIFY_TRIP" "the self-authorisation escalation still precedes the verifier"

# --- case AC: a ./-prefixed test_ref must not slip out of its own scope --------
#
# The scope check compares the ledger's test path against git's changed-file list
# byte for byte, while the existence check hands it to the filesystem, which
# normalizes. So a ledger writing "bash ./tests/aa.test.sh" had its file
# correctly seen as GONE and then incorrectly excused as somebody else's
# pre-existing debt, because ./tests/aa.test.sh never matched git's
# tests/aa.test.sh - a fail-open decided by nothing but how the path happens to
# be spelled. Same class as the rename case: a spelling difference must not let
# a gate slip out of its own check.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
LEDGER_DOTSLASH=${LEDGER_CLEAN/bash tests\/aa.test.sh/bash .\/tests\/aa.test.sh}
[ "$LEDGER_DOTSLASH" != "$LEDGER_CLEAN" ] || fail "case AC fixture must actually ./-prefix a test_ref"
WAC=$(scope_repo ac "$LEDGER_DOTSLASH")
git -C "$WAC" rm -q tests/aa.test.sh
git -C "$WAC" commit -qm "drop a test the ledger still cites as ./tests/aa.test.sh"
run ac; codeAC=$?
expect_code 2 "$codeAC" "deleting a test the ledger cites as ./tests/<x> is this branch's own
staleness exactly as tests/<x> would be - the deletion is in its diff - and must reject
rather than be excused as inherited debt because of a leading ./"
assert_grep "fx-green" "$(fm_verdict_file "$S" ac)" "the stale reject names the gate"
assert_grep "tests/aa.test.sh" "$(fm_verdict_file "$S" ac)" "the stale reject names the test"
assert_no_grep "pre-existing ledger debt" "$TMP/ac.out" \
  "a gate this branch is answerable for must not be reported as somebody else's debt"
assert_absent "$VERIFY_TRIP" "the in-scope stale reject still precedes the verifier"

# --- case AD: unknown scope rejects, but must not claim the branch touched it ---
#
# Fail closed must not mean fail dishonest. With the reviewed base unresolvable,
# every offending gate goes in scope - the right SAFETY behaviour, and it stays -
# but the reject text then asserted "unproven gates this branch touched" over a
# gate the branch had never seen, while the "(pre-existing and not your
# responsibility)" qualifier could not appear because the pre-existing lists are
# necessarily empty in that state. The crewmate was told it broke something it
# did not break and sent to fix inherited debt on a false premise, and nothing on
# stdout admitted the check had degraded at all.
#
# The combination is reachable and not exotic: this ledger carries NO declared
# red, so the self-authorisation escalation - the other consumer of that base -
# never fires, and nothing else stops the run.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
repo_ad="$TMP/ad-repo"; wt_ad="$TMP/ad-wt"
fm_git_init_commit "$repo_ad"
git -C "$repo_ad" branch -M main
# An origin that does not exist: the fetch fails, no cached origin/main was ever
# created, so the reviewed base cannot be established and scope is UNKNOWN.
git -C "$repo_ad" remote add origin "file://$TMP/ad-remote-does-not-exist.git"
mkdir -p "$repo_ad/gates" "$repo_ad/tests"
printf '%s\n' "$DECL_RED" > "$repo_ad/gates/accepted-red.md"
cat > "$repo_ad/gates/ledger.json" <<'JSONAD'
{
  "version": 1,
  "gates": [
    { "id": "fx-green",  "status": "unproven", "test_ref": "bash tests/aa.test.sh" },
    { "id": "fx-frozen", "status": "frozen",   "test_ref": "bash tests/bb.test.sh" }
  ]
}
JSONAD
: > "$repo_ad/tests/aa.test.sh"; : > "$repo_ad/tests/bb.test.sh"
git -C "$repo_ad" add gates tests
git -C "$repo_ad" commit -qm "gates: inherited unproven debt, no declared red"
git -C "$repo_ad" worktree add --quiet -b fm/ad "$wt_ad"
mkdir -p "$D/ad"
fm_write_meta "$S/ad.meta" \
  "window=firstmate:fm-ad" "worktree=$wt_ad" "project=$repo_ad" \
  "harness=echo" "kind=ship" "mode=local-only" "yolo=off"
unrelated_commit "$wt_ad"
run ad; codeAD=$?
expect_code 2 "$codeAD" "with the reviewed base unresolvable, scope is unknown and every
offending gate must still be treated as this branch's own - fail closed, never excuse the lot"
assert_grep "could not be determined" "$TMP/ad.out" \
  "a degraded scope check must be announced on stdout, exactly as the diff-base degradation
is; silence about a degraded check is how a degraded check becomes invisible"
assert_grep "fx-green" "$TMP/relay.log" "the reject still names the offending gate"
assert_grep "could not be established" "$TMP/relay.log" \
  "the relayed text must say that scope could not be established, so the crewmate can tell
\"you broke this\" from \"we could not tell whose this is, so you are seeing all of it\""
assert_no_grep "unproven gates this branch touched" "$TMP/relay.log" \
  "the reject must not claim the branch touched a gate it never saw - fail closed must not
mean fail dishonest"
assert_absent "$VERIFY_TRIP" "the fail-closed reject still precedes the verifier"

# --- case AE: an unrecognised classifier header must never read as acceptable ---
#
# The header set is a cross-file contract, documented under "Headers:" in
# bin/fm-gates-lib.sh. fm-verify handled NOGATES, NOLEDGER and BADLEDGER and then
# entered the gate stage by EXCLUDING the two inapplicable ones, so any other
# header fell through carrying no rows fm-verify could read: every awk filter
# came back empty and the stage announced "gates: acceptable (every gate green,
# frozen, or a declared red)" over a ledger it had read not one gate from. That is
# the accept path claiming a property it never established - the third instance of
# the shape already closed twice inside the classifier, at the non-array coercion
# and the all-or-nothing row build.
#
# The classifier is stubbed rather than broken, because reaching this state for
# real needs a version skew between the two files, which is precisely what the
# escalation has to survive. The stub is a whole shim bin/ of symlinks with one
# file replaced, so nothing but the classifier's answer differs from any other
# case here.
rm -f "$LENS_TRIP" "$VERIFY_TRIP"; : > "$TMP/relay.log"
WAE=$(task ae "$DECL_RED"); gates "$WAE" yes
SHIM="$TMP/shim-bin"; mkdir -p "$SHIM"
for shim_f in "$ROOT"/bin/*; do ln -sf "$shim_f" "$SHIM/$(basename "$shim_f")"; done
rm -f "$SHIM/fm-gates-lib.sh"
cat > "$SHIM/fm-gates-lib.sh" <<'SHIMLIB'
# A header from outside the documented set - a newer classifier, or a corrupted
# capture. It carries no rows, exactly as NOGATES and NOLEDGER do not.
fm_gates_classify() { echo "SOMENEWHEADER"; }
SHIMLIB
FM_ROOT_OVERRIDE="$ROOT" FM_VERIFY_CMD="$TMP/verify.sh" \
  "$SHIM/fm-verify.sh" ae >"$TMP/ae.out" 2>&1
codeAE=$?
expect_code 3 "$codeAE" "a classifier header this script has no rule for must ESCALATE:
nothing can be concluded about the gates, and the captain has to tell a version skew
from a corruption"
assert_no_grep "gates: acceptable" "$TMP/ae.out" \
  "the stage must never announce acceptable over a ledger it read no gate from - that is
the accept path claiming a property it never established"
assert_grep "SOMENEWHEADER" "$TMP/ae.out" \
  "the escalation must name the header it actually saw, or the captain cannot tell a
version skew from a corrupt classification"
assert_grep "escalate:" "$(fm_verdict_file "$S" ae)" \
  "the escalation is recorded on the verdict trail like any other"
assert_absent "$LENS_TRIP" "an unclassifiable ledger must fail closed BEFORE the lens"
assert_absent "$VERIFY_TRIP" "an unclassifiable ledger must fail closed BEFORE the verifier"

# --- case G: the prompt no longer carries a gate rule of its own -------------
#
# Comments are stripped first: the file's header deliberately QUOTES the deleted
# instruction to record what went wrong, and that history must not be mistaken
# for the instruction still being live. Only what the model actually reads
# counts.
V="$ROOT/bin/fm-verify.sh"
BODY="$TMP/verify-body.sh"
grep -v '^[[:space:]]*#' "$V" > "$BODY"
assert_no_grep "every gate must be" "$BODY" \
  "the verifier prompt must not state its own gate rule; the classifier owns that
decision, and a second authority over it is what produced the contradiction"
assert_no_grep "run: bash gates/verify.sh" "$BODY" \
  "the prompt must not tell the verifier to run gates/verify.sh - ledger verify
re-runs every gate and rewrites the ledger inside the crewmate's worktree"
assert_grep "fm-gates-lib.sh" "$BODY" "fm-verify must cite the classifier"

# The verifier prompt is an UNQUOTED heredoc inside a command substitution, so
# bash re-scans its body at run time: a lone apostrophe opens a quote that never
# closes and the script dies with "unexpected EOF" pointing at a line well past
# the heredoc. bash -n does not catch it. Writing the possessive form of "repo"
# while editing this stage did exactly that - fm-verify exited 2 mid-run, and it
# surfaced only because Q6 happened to exercise that path.
# shellcheck disable=SC2016 # the \$ is a literal in the sed address, not an expansion
APOS=$(sed -n '/^PROMPT=\$(cat <<EOF$/,/^EOF$/p' "$V" | grep -c "'" || true)
expect_code 0 "$APOS" "the verifier prompt heredoc must contain no apostrophe -
it is unquoted inside a command substitution, so bash re-scans it and an
unmatched quote kills fm-verify at run time, invisibly to bash -n"

pass "Q9 Quarterdeck honours declared-red gates, ahead of both models"

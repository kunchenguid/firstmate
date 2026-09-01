#!/usr/bin/env bash
# T1-preflight-rules: the brief preflight's classifier. One committed fixture
# brief per rule must be REFUSED with the offending path or command NAMED - a
# refusal that only says "invalid brief" costs another cycle to diagnose, which
# is the cost this gate exists to remove. Two fixtures must PASS: a realistic
# clean brief, and a lookalike brief carrying every near-miss the rules must not
# match (firstmate-notes vs firstmate, fm-spawn.sh.bak vs fm-spawn.sh, a
# MENTION of a pool-leasing script vs an invocation of it). The real scaffolds
# that bin/fm-brief.sh writes - ship and scout - must pass untouched, since a
# gate the standard brief cannot get through is a gate nothing gets through.
# A project with no git at all is not "cannot tell": nothing is hidden there, so
# the other three rules still run.
# Mutation (LEDGER_MUTATE=1): the refusal assertions are inverted to demand that
# each offending fixture PASSES - a correct preflight refuses it, so the gate
# goes red exactly when the classifier still works.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FIX="$ROOT/tests/fixtures/preflight"
ID=fixture-k3
TMP=$(fm_test_tmproot fm-wd-t1-pf)

# A project shaped like firstmate's own ignore rules, so the gitignored rule has
# something real to ask. The preflight asks THIS repo's git, never a pattern of
# its own.
PROJ="$TMP/proj"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf 'projects/\nstate/\ndata/\n.no-mistakes/\n' > "$PROJ/.gitignore"
mkdir -p "$PROJ/docs/specs" "$PROJ/gates" "$PROJ/bin"
: > "$PROJ/AGENTS.md"
: > "$PROJ/docs/specs/2026-07-03-wardroom-intake.md"
: > "$PROJ/gates/accepted-red.md"
: > "$PROJ/bin/fm-intake-lib.sh"
git -C "$PROJ" add -A >/dev/null
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=t commit -qm init >/dev/null

# FM_HOME is pointed somewhere that is NOT the primary checkout on purpose: the
# ~/firstmate roots the fixtures use must be recognised from the conventional
# form alone, so this suite behaves the same on any machine.
# Sets the globals PF_OUT and PF_CODE rather than printing: a command
# substitution runs in a subshell, so an exit code captured inside one is lost
# to the caller.
PF_OUT=""; PF_CODE=0
pf() {  # <brief-path> [<project-dir>]
  PF_OUT=$(FM_HOME="$TMP/not-the-home" FM_ROOT="$TMP/not-the-home" \
           bash "$ROOT/bin/fm-preflight-lib.sh" "$1" "${2:-$PROJ}" "$ID" 2>&1)
  PF_CODE=$?
}

# refused <fixture> <label> <named...>: the fixture must be refused AND every
# offender must appear by name in the findings.
refused() {
  local file=$1 label=$2
  shift 2
  pf "$file"
  if [ "${LEDGER_MUTATE:-}" = 1 ]; then
    expect_code 0 "$PF_CODE" "MUTATION: $label expected to pass the preflight"
    return 0
  fi
  expect_code 1 "$PF_CODE" "$label must be refused"
  local want
  for want in "$@"; do
    assert_contains "$PF_OUT" "$want" "$label refusal must name '$want'"
  done
}

# 1. gitignored: invisible in a worktree, and no commit can move or delete it
refused "$FIX/gitignored.md" "gitignored brief" \
  "gitignored" "data/command-center-roadmap.md" "worktree"

# 2. primary checkout: denied to crewmates by the permission profile
refused "$FIX/primary-checkout.md" "primary-checkout brief" \
  "primary-checkout" "/firstmate/data/*/brief.md" "/firstmate/AGENTS.md" \
  "/firstmate/data/old-task-q4/report.md"

# 3. pool lease: leaks a durable lease into the captain's pool whatever FM_HOME
#    says - by the invocation itself, and by the FM_HOME=$(mktemp -d) assignment
#    that claims an isolation FM_HOME cannot provide. That literal is
#    single-quoted on purpose: it is the text the brief contains, not something
#    this shell should expand.
# shellcheck disable=SC2016
refused "$FIX/pool-lease.md" "pool-lease brief" \
  "pool-lease" "bin/fm-home-seed.sh" "bin/fm-spawn.sh" \
  'FM_HOME=$(mktemp -d)' \
  "does not redirect the treehouse lease"

# 4. retired >> status redirect: the report is silently discarded
refused "$FIX/status-redirect.md" "status-redirect brief" \
  "status-redirect" "state/fixture-k3.status" "bin/fm-status.sh"

# 5. THE CLEAN BRIEF PASSES. Without this the gate could be satisfied by a
#    preflight that refuses everything, which is worse than no preflight.
pf "$FIX/clean.md"
expect_code 0 "$PF_CODE" "the clean brief must pass"$'\n'"--- findings ---"$'\n'"$PF_OUT"

# 6. LOOKALIKES PASS. Fail closed, but not noisily wrong.
pf "$FIX/lookalike.md"
expect_code 0 "$PF_CODE" "the lookalike brief must pass"$'\n'"--- findings ---"$'\n'"$PF_OUT"
assert_not_contains "$PF_OUT" "firstmate-notes" "a sibling dir is not the primary checkout"
assert_not_contains "$PF_OUT" "firstmate-old" "a sibling dir is not the primary checkout"
assert_not_contains "$PF_OUT" "fm-spawn.sh.bak" "a .bak is not the script"
assert_not_contains "$PF_OUT" "my-fm-spawn.sh" "a differently-named script is not the script"
# The lookalike brief carries three prose citations that a naive interpreter or
# ./ check reads as invocations - "the flagship bash bin/fm-spawn.sh wrapper",
# "./bin/fm-home-seed.sh is the file you are editing", and "Run bash first, then
# `bin/fm-spawn.sh`" where the interpreter belongs to the sentence and not to
# the code span. It also names this task's OWN state files as a glob,
# ~/firstmate/state/fixture-k3.*, which the sanctioned set advertises.
assert_not_contains "$PF_OUT" "pool-lease" "prose that names a script is not an invocation of it"
assert_not_contains "$PF_OUT" "state/fixture-k3" "this task's own state files are sanctioned, glob and all"

# 7. The REAL scaffolds pass, both kinds. This is the standard brief every task
#    starts from, so a preflight it cannot get through blocks the whole fleet.
#    The scaffold home here sits under the system temp dir, which is deliberate:
#    an earlier cut of the FM_HOME rule matched any literal /tmp or /var/folders
#    path and refused the standard scaffold outright. Only the DYNAMIC throwaway
#    constructs - $(mktemp ...) and $TMPDIR - are evidence of the false-isolation
#    belief; where a home happens to live is not.
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
for kind in ship scout; do
  sid="scaffold-$kind-k3"
  if [ "$kind" = scout ]; then
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$sid" alpha --scout >/dev/null 2>&1
  else
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$sid" alpha >/dev/null 2>&1
  fi
  [ -f "$HOME_DIR/data/$sid/brief.md" ] || fail "fm-brief.sh wrote no $kind scaffold"
  out=$(FM_HOME="$HOME_DIR" FM_ROOT="$HOME_DIR" \
        bash "$ROOT/bin/fm-preflight-lib.sh" "$HOME_DIR/data/$sid/brief.md" "$PROJ" "$sid" 2>&1)
  code=$?
  expect_code 0 "$code" "the standard $kind scaffold must pass"$'\n'"--- findings ---"$'\n'"$out"
done

# 7b. The sanctioned set is honoured exactly as the refusal message advertises
#     it, and a glob may not widen past this task. state/<id>.* is the shape a
#     real status or meta file has; state/<id>* and data/*/ are not, because
#     both also match another task's material.
cat > "$TMP/glob.md" <<'BRIEF'
# Task
Read `~/firstmate/state/fixture-k3.*` and `~/firstmate/data/fixture-k3/notes.md`,
and run the helpers in `~/firstmate/bin/*.sh`.
Report with `bash ~/firstmate/bin/fm-status.sh`.
BRIEF
pf "$TMP/glob.md"
expect_code 0 "$PF_CODE" "this task's own material must be sanctioned under a glob"$'\n'"$PF_OUT"

cat > "$TMP/glob-wide.md" <<'BRIEF'
# Task
Fix `~/firstmate/data/*/brief.md` and `~/firstmate/state/fixture-k3-other.status`,
then sweep `~/firstmate/**`.
Report with `bash ~/firstmate/bin/fm-status.sh`.
BRIEF
pf "$TMP/glob-wide.md"
expect_code 1 "$PF_CODE" "a glob reaching past this task must be refused"
assert_contains "$PF_OUT" "data/*/brief.md" "the widening glob is named"
assert_contains "$PF_OUT" "state/fixture-k3-other.status" "another task's state file is named"

# 8. A project with no git is NOT "cannot tell": a tree with no ignore machinery
#    hides nothing, so the gitignored rule is inapplicable and the rest still run.
NOGIT="$TMP/nogit"
mkdir -p "$NOGIT"
pf "$FIX/gitignored.md" "$NOGIT"
expect_code 0 "$PF_CODE" "no git means the gitignored rule cannot apply"
pf "$FIX/pool-lease.md" "$NOGIT"
expect_code 1 "$PF_CODE" "the text rules still run without git"
assert_contains "$PF_OUT" "pool-lease" "the pool-lease rule needs no git"

# 9. An unreadable brief is refused, not waved through.
pf "$TMP/no-such-brief.md"
expect_code 1 "$PF_CODE" "a missing brief must be refused"
assert_contains "$PF_OUT" "unreadable-brief" "the missing brief is named as such"

pass "T1 brief preflight: every rule fires, names its offender, and lets the clean brief through"

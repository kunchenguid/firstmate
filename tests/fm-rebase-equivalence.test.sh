#!/usr/bin/env bash
# Behavior tests for bin/fm-rebase-equivalence.sh.
#
# The script exists because a pipeline's push-time rebase twice produced a head
# that had silently dropped validated content, and no pipeline signal reported
# it. These tests pin the discrimination that matters: a faithful rebase over a
# moved trunk must PASS, and a rebase that loses content must be REFUSED with
# the losing paths named.
#
# The refusal cases come first and are the point of the suite. A check of this
# shape can only be trusted once it has been watched going red against a
# reconstructed drop, because "no refusal" is otherwise indistinguishable from
# "never compared anything".
#
# Every fixture is built commit by commit rather than by running `git rebase`,
# so a scenario means exactly one thing and cannot drift with git's rebase
# heuristics.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-rebase-equivalence.sh"
TMP_ROOT=$(fm_test_tmproot fm-rebase-equivalence)

git_do() {  # <dir> <args...>
  local dir=$1; shift
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

commit_all() {  # <dir> <message>
  git_do "$1" add -A
  git_do "$1" commit -qm "$2"
  git -C "$1" rev-parse HEAD
}

# new_repo <name>: a repo whose single commit holds a small file the scenarios
# then evolve along two independent lines.
new_repo() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'alpha\nbravo\ncharlie\n' > "$dir/core.sh"
  printf 'shared\n' > "$dir/README.md"
  commit_all "$dir" base > /dev/null
  printf '%s' "$dir"
}

run_check() {  # <repo> <validated-base> <validated-head> <candidate-head>
  RC=0
  OUT=$("$CHECK" --repo "$1" --validated-base "$2" --validated-head "$3" \
    --candidate-head "$4" 2>&1) || RC=$?
}

# --- refusal: a whole path the validated change touched vanishes -------------
#
# The first reproduced incident's shape: the rebased head kept one unrelated
# commit and lost the fix plus its regression tests entirely.

REPO=$(new_repo whole-path-drop)
B=$(git -C "$REPO" rev-parse HEAD)

# The validated head carries three things: an unrelated tweak, the fix, and the
# fix's regression test.
printf 'alpha\nbravo\ncharlie\nunrelated tweak\n' > "$REPO/core.sh"
printf 'ledger record one\nledger record two\n' > "$REPO/ledger.sh"
printf 'regression for the ledger\n' > "$REPO/ledger.test.sh"
V=$(commit_all "$REPO" 'validated: unrelated tweak, the ledger fix, and its test')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'shared\ntrunk moved on\n' > "$REPO/README.md"
commit_all "$REPO" 'trunk: unrelated movement' > /dev/null
# Only the unrelated tweak survived the rebase; the fix and its test are gone.
printf 'alpha\nbravo\ncharlie\nunrelated tweak\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: only the unrelated tweak survived')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'whole-path drop must be refused'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: DROPPED' 'whole-path drop must report DROPPED'
assert_contains "$OUT" 'ledger.sh' 'the dropped fix path must be named'
assert_contains "$OUT" 'ledger.test.sh' 'the dropped regression test must be named'
assert_contains "$OUT" 'dropped-path' 'the direction of a vanished path must be named'
pass 'a rebase that drops whole paths is refused, naming them'

# --- refusal: the path survives but hunks inside it are lost ----------------
#
# The second reproduced incident's shape: path footprints matched almost
# exactly and only the accepted review-fix hunks were missing, so a path-level
# comparison alone would have called this clean.

REPO=$(new_repo hunk-drop)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\nbravo\ncharlie\nvalidated header line\nvalidated rationale line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: header and rationale')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nbravo\ncharlie\nvalidated header line\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: rationale hunk lost in the rebase')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'hunk-level drop must be refused'
assert_contains "$OUT" 'dropped-content' 'a lost hunk must be reported as dropped content'
assert_contains "$OUT" 'core.sh' 'the path holding the lost hunk must be named'
pass 'a rebase that drops hunks inside a surviving path is refused'

# --- refusal: a deletion the validated change made comes back ---------------

REPO=$(new_repo resurrected)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\ncharlie\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: remove the bravo line')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nbravo\ncharlie\nunrelated trunk line\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: the removal was undone')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'an undone removal must be refused'
assert_contains "$OUT" 'resurrected-content' 'an undone removal must be named as resurrected content'
pass 'a rebase that undoes a validated removal is refused'

# --- refusal: a whole file the validated change deleted comes back ----------

REPO=$(new_repo resurrected-path)
B=$(git -C "$REPO" rev-parse HEAD)

git_do "$REPO" rm -q README.md
V=$(commit_all "$REPO" 'validated: delete the file')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'shared\ntrunk kept editing it\n' > "$REPO/README.md"
C=$(commit_all "$REPO" 'candidate: the deleted file is back')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'a resurrected deleted path must be refused'
assert_contains "$OUT" 'resurrected-path' 'a resurrected path must be named with its direction'
pass 'a rebase that resurrects a validated deletion is refused'

# --- pass: a faithful rebase over a trunk that moved ------------------------
#
# The trunk edits the same file above and below the validated change, so every
# validated line shifts position. Position must not read as loss.

REPO=$(new_repo faithful)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\nbravo\ncharlie\nvalidated addition\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one addition')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'trunk prologue\nalpha\nbravo\ncharlie\ntrunk epilogue\n' > "$REPO/core.sh"
git_do "$REPO" commit -qam 'trunk: surround the region' || true
printf 'trunk prologue\nalpha\nbravo\ncharlie\nvalidated addition\ntrunk epilogue\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: validated addition reapplied in its new position')

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'a faithful rebase over a moved trunk must pass'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'a faithful rebase must report PASS'
pass 'a faithful rebase over a moved trunk still passes'

# --- pass: the trunk landed the same content independently ------------------
#
# A rebase legitimately drops a hunk the trunk already contains. The content
# landed, so refusing here would refuse a correct rebase.

REPO=$(new_repo trunk-supplied)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\nbravo\ncharlie\nthe very same fix line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: add the fix line')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nbravo\ncharlie\nthe very same fix line\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'trunk landed the identical fix; rebase left nothing to apply')

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'content the trunk supplied independently must still count as carried'
pass 'a hunk the trunk already landed is not reported as dropped'

# --- pass: the candidate carries work made after validation -----------------
#
# The pipeline commits its own fixes, and some land only on the pushed side.
# The check refuses loss, never growth, which is what lets a caller compare a
# local validated head against a pushed head that legitimately moved on.

REPO=$(new_repo later-work)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one addition')

printf 'alpha\nbravo\ncharlie\nvalidated line\na fix made after validation\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: a later pipeline fix on top')

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'content added after validation must not read as loss'
pass 'a candidate that grew after validation still passes'

# --- pass: whitespace-only churn is not content ------------------------------

REPO=$(new_repo whitespace)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\n\nbravo\ncharlie\nreal content\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: a blank line and a real line')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nbravo\ncharlie\nreal content\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: kept the content, lost the blank line')

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'a lost blank line is not lost content'
pass 'whitespace-only differences do not refuse a rebase'

# --- could-not-observe: an input that cannot be resolved --------------------
#
# Each of these would be a silent pass in a check that treated an unusable
# input as nothing to do.

REPO=$(new_repo unobservable)
B=$(git -C "$REPO" rev-parse HEAD)
printf 'alpha\nbravo\ncharlie\nsomething\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: a change')

run_check "$REPO" "$B" "$V" 'refs/heads/no-such-branch'
expect_code 2 "$RC" 'an unresolvable candidate must be could-not-observe'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: CANNOT-OBSERVE' 'an unresolvable ref must say so'
pass 'an unresolvable ref is could-not-observe, not a pass'

run_check "$TMP_ROOT/not-a-repo" "$B" "$V" "$V"
expect_code 2 "$RC" 'a missing repository must be could-not-observe'
pass 'a missing repository directory is could-not-observe, not a pass'

mkdir -p "$TMP_ROOT/plain-dir"
run_check "$TMP_ROOT/plain-dir" "$B" "$V" "$V"
expect_code 2 "$RC" 'a non-git directory must be could-not-observe'
pass 'a directory that is not a git repository is could-not-observe'

RC=0
OUT=$("$CHECK" --repo "$REPO" --validated-head "$V" --candidate-head "$V" 2>&1) || RC=$?
expect_code 2 "$RC" 'a missing required argument must be could-not-observe'
assert_contains "$OUT" 'missing required --validated-base' 'the missing argument must be named'
pass 'a missing required argument is could-not-observe, not a pass'

run_check "$REPO" "$V" "$V" "$V"
expect_code 2 "$RC" 'an empty validated contribution must be could-not-observe'
assert_contains "$OUT" 'validated contribution is empty' 'an empty contribution must say so'
pass 'an empty validated contribution refuses instead of passing vacuously'

# --- could-not-observe: a binary path that changed --------------------------

REPO=$(new_repo binary)
B=$(git -C "$REPO" rev-parse HEAD)
printf 'bin\000ary\001one\n' > "$REPO/blob.bin"
V=$(commit_all "$REPO" 'validated: add a binary file')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'bin\000ary\002two\n' > "$REPO/blob.bin"
C=$(commit_all "$REPO" 'candidate: a different binary payload')

run_check "$REPO" "$B" "$V" "$C"
expect_code 2 "$RC" 'a changed binary path cannot be compared line by line'
assert_contains "$OUT" 'binary path' 'the uncomparable binary path must be named'
pass 'a binary path that changed is could-not-observe, never assumed carried'

# An identical binary blob is still a sound observation.
git_do "$REPO" checkout -q -b same "$B"
printf 'bin\000ary\001one\n' > "$REPO/blob.bin"
C=$(commit_all "$REPO" 'candidate: the identical binary payload')
run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'an identical binary blob is carried'
pass 'an unchanged binary path passes on blob identity'

# --- a verdict is always printed --------------------------------------------
#
# A caller must be able to tell "compared and passed" from "never ran".

for scenario in 3 0 2; do
  case "$scenario" in
    3) run_check "$REPO" "$B" "$V" "$B" ;;
    0) run_check "$REPO" "$B" "$V" "$C" ;;
    2) run_check "$REPO" "$B" "$V" 'nope' ;;
  esac
  assert_contains "$OUT" 'REBASE-EQUIVALENCE:' 'every run must print a verdict line'
done
pass 'every outcome prints a verdict line, so a silent run is detectable'

printf 'all rebase-equivalence tests passed\n'

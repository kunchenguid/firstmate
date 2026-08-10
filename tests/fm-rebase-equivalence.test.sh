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

run_check() {  # <repo> <validated-base> <validated-head> <candidate-head> [extra...]
  local repo=$1 vb=$2 vh=$3 ch=$4
  shift 4
  RC=0
  OUT=$("$CHECK" --repo "$repo" --validated-base "$vb" --validated-head "$vh" \
    --candidate-head "$ch" "$@" 2>&1) || RC=$?
}

run_check_pr() {  # <repo> <validated-base> <validated-head> <request> [extra...]
  local repo=$1 vb=$2 vh=$3 pr=$4
  shift 4
  RC=0
  OUT=$("$CHECK" --repo "$repo" --validated-base "$vb" --validated-head "$vh" \
    --candidate-pr "$pr" "$@" 2>&1) || RC=$?
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

# --- refusal: a dropped hunk that only duplicates lines already in the file --
#
# Presence-anywhere matching clears this by mistake: a copy of the line was in
# the file before the change, so the whole added hunk can vanish and still look
# carried. Only counting occurrences sees the loss.

REPO=$(new_repo duplicate-line-drop)
printf 'alpha\nguard\nbravo\ncharlie\n' > "$REPO/core.sh"
B=$(commit_all "$REPO" 'base: one guard already present')

printf 'alpha\nguard\nbravo\nguard\ncharlie\nguard\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: two more guards')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nguard\nbravo\ncharlie\ntrunk line\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: the guard hunk never landed')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'a dropped hunk of already-present lines must be refused'
assert_contains "$OUT" 'dropped-content' 'the lost copies must be reported as dropped content'
assert_contains "$OUT" 'core.sh' 'the path holding the lost copies must be named'
pass 'added copies of an already-present line are counted, not merely looked up'

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

# --- refusal: an undone removal measured against the candidate's own base ---

REPO=$(new_repo resurrected-against-base)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\ncharlie\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: remove the bravo line')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nbravo\ncharlie\ntrunk line\n' > "$REPO/core.sh"
T=$(commit_all "$REPO" 'trunk: unrelated movement')
printf 'alpha\nbravo\ncharlie\ntrunk line\nlater trunk line\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: the removal was undone')

run_check "$REPO" "$B" "$V" "$C" --candidate-base "$T"
expect_code 3 "$RC" 'an undone removal must still be refused against the candidate base'
assert_contains "$OUT" 'resurrected-content' 'an undone removal must be named as resurrected content'
pass 'the candidate base sharpens the removal check without blunting it'

# --- refusal: a binary path the candidate lacks entirely --------------------
#
# A path that is simply gone is an unambiguous drop. Reporting it as an
# inability to observe would leave the losing path unnamed and teach a reader
# to discount could-not-observe.

REPO=$(new_repo binary-drop)
B=$(git -C "$REPO" rev-parse HEAD)
printf 'bin\000ary\001one\n' > "$REPO/blob.bin"
V=$(commit_all "$REPO" 'validated: add a binary file')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'shared\ntrunk moved on\n' > "$REPO/README.md"
C=$(commit_all "$REPO" 'candidate: the binary file never landed')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'a binary path the candidate lacks entirely must be refused as a drop'
assert_contains "$OUT" 'dropped-path' 'a vanished binary path must be named with its direction'
assert_contains "$OUT" 'blob.bin' 'the vanished binary path must be named'
pass 'a binary path that vanished is a drop, not an inability to observe'

# --- pass: the trunk independently added a line the change had deleted ------
#
# Boilerplate makes this ordinary: the change deletes one `fi` while the trunk
# adds an unrelated block that ends in one. Comparing the two heads' absolute
# counts reads that as a resurrected removal and refuses a correct rebase, so
# each side is measured against its own base instead.

REPO=$(new_repo trunk-added-boilerplate)
printf 'alpha\nfi\nbravo\nfi\ncharlie\n' > "$REPO/core.sh"
B=$(commit_all "$REPO" 'base: two fi lines')

printf 'alpha\nfi\nbravo\ncharlie\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: drop one fi')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nfi\nbravo\nfi\ncharlie\ndelta\nfi\n' > "$REPO/core.sh"
T=$(commit_all "$REPO" 'trunk: an unrelated block ending in fi')
printf 'alpha\nfi\nbravo\ncharlie\ndelta\nfi\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: the validated removal reapplied on the moved trunk')

run_check "$REPO" "$B" "$V" "$C" --candidate-base "$T"
expect_code 0 "$RC" 'a line the trunk added must not read as a resurrected removal'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'the faithful rebase must report PASS'
pass 'a line the trunk added independently is not a resurrected removal'

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'the same rebase must pass with no candidate base given'
pass 'with no candidate base, only a line removed entirely is judged'

# --- pass: a path whose name globs onto other tracked paths -----------------
#
# The path is a git pathspec, so a name holding *, ? or [ would otherwise pull
# other files into the same diff, whose file headers would then be harvested as
# content that the candidate cannot possibly hold.

REPO=$(new_repo literal-pathspec)
printf 'alpha\n' > "$REPO/a1.sh"
printf 'alpha\n' > "$REPO/a2.sh"
printf 'alpha\n' > "$REPO/a*.sh"
B=$(commit_all "$REPO" 'base: a name that globs onto its siblings')

printf 'alpha\nvalidated star line\n' > "$REPO/a*.sh"
printf 'alpha\nvalidated one line\n' > "$REPO/a1.sh"
printf 'alpha\nvalidated two line\n' > "$REPO/a2.sh"
V=$(commit_all "$REPO" 'validated: change all three')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nvalidated star line\n' > "$REPO/a*.sh"
printf 'alpha\nvalidated one line\n' > "$REPO/a1.sh"
printf 'alpha\nvalidated two line\n' > "$REPO/a2.sh"
C=$(commit_all "$REPO" 'candidate: all three reapplied faithfully')

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'a faithful rebase must pass even when a path name globs'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'a globbing path name must not fabricate a drop'
pass 'a path name is matched literally, never as a wildcard'

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

# --- the candidate head is fetched from the forge ---------------------------
#
# The pipeline builds the pushed head inside its own repository and those
# objects never reach the worker's clone, so a check that could only name a
# local commit would report could-not-observe on every run and gate nothing.
# The forge is the reachable source. These fixtures keep each candidate ONLY
# under a request head ref, so any verdict other than could-not-observe is
# itself proof the fetch happened.

SRC="$TMP_ROOT/forge-src"
mkdir -p "$SRC"
git -C "$SRC" init -q
printf 'alpha\nbravo\ncharlie\n' > "$SRC/core.sh"
B=$(commit_all "$SRC" 'base')
printf 'shared\ntrunk moved on\n' > "$SRC/README.md"
T=$(commit_all "$SRC" 'trunk: moved on')
git_do "$SRC" checkout -q -b dropped "$T"
printf 'unrelated\n' > "$SRC/unrelated.txt"
D=$(commit_all "$SRC" 'candidate: the validated line never landed')
git_do "$SRC" checkout -q -b faithful "$T"
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$SRC/core.sh"
F=$(commit_all "$SRC" 'candidate: the validated line reapplied')

FORGE="$TMP_ROOT/forge.git"
git init -q --bare -b main "$FORGE"
git_do "$SRC" push -q "$FORGE" \
  "$T:refs/heads/main" "$D:refs/pull/7/head" "$F:refs/pull/8/head"

# --no-local: a local clone hardlinks the whole object store, which would hand
# the worker the pushed heads for free and hide whether the fetch ran.
WORKER="$TMP_ROOT/worker"
git clone -q --no-local "$FORGE" "$WORKER"
git_do "$WORKER" checkout -q -b work "$B"
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$WORKER/core.sh"
V=$(commit_all "$WORKER" 'validated: one addition')

if git -C "$WORKER" cat-file -e "$D^{commit}" 2>/dev/null; then
  fail 'the fixture must not already hold the candidate head locally'
fi

run_check_pr "$WORKER" "$B" "$V" 7
expect_code 3 "$RC" 'a dropping candidate fetched from the forge must be refused'
assert_contains "$OUT" 'dropped-content' 'the fetched candidate must be compared, not skipped'
assert_contains "$OUT" 'core.sh' 'the losing path must be named'
pass 'a head that exists only on the forge is fetched and refused'

run_check_pr "$WORKER" "$B" "$V" 8
expect_code 0 "$RC" 'a faithful candidate fetched from the forge must pass'
pass 'a faithful head fetched from the forge still passes'

run_check_pr "$WORKER" "$B" "$V" 'https://github.com/example/project/pull/8' \
  --candidate-remote "$FORGE"
expect_code 0 "$RC" 'a request URL must resolve to the pull head namespace'
pass 'a request URL names the number and the head namespace'

run_check_pr "$WORKER" "$B" "$V" 9
expect_code 2 "$RC" 'an unfetchable request must be could-not-observe'
assert_contains "$OUT" 'cannot fetch the candidate head' 'the unreachable candidate must say so'
pass 'a candidate that cannot be fetched refuses instead of passing'

run_check_pr "$WORKER" "$B" "$V" 'not-a-request'
expect_code 2 "$RC" 'an unparseable request must be could-not-observe'
pass 'a request that is neither a URL nor a number is could-not-observe'

RC=0
OUT=$("$CHECK" --repo "$WORKER" --validated-base "$B" --validated-head "$V" 2>&1) || RC=$?
expect_code 2 "$RC" 'naming no candidate at all must be could-not-observe'
assert_contains "$OUT" 'missing required --candidate-head or --candidate-pr' \
  'the missing candidate must be named'
RC=0
OUT=$("$CHECK" --repo "$WORKER" --validated-base "$B" --validated-head "$V" \
  --candidate-head "$V" --candidate-pr 8 2>&1) || RC=$?
expect_code 2 "$RC" 'naming two candidates must be could-not-observe'
RC=0
OUT=$("$CHECK" --repo "$WORKER" --validated-base "$B" --validated-head "$V" \
  --candidate-head "$V" --candidate-base 'no-such-trunk' 2>&1) || RC=$?
expect_code 2 "$RC" 'an unresolvable candidate base must be could-not-observe'
pass 'an ambiguous, absent, or unusable candidate input never reads as a pass'

# --- a verdict is always printed --------------------------------------------
#
# A caller must be able to tell "compared and passed" from "never ran", and the
# exit status must match the verdict it printed.

REPO=$(new_repo verdicts)
B=$(git -C "$REPO" rev-parse HEAD)
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one addition')

for scenario in 3 0 2; do
  case "$scenario" in
    3) run_check "$REPO" "$B" "$V" "$B" ;;
    0) run_check "$REPO" "$B" "$V" "$V" ;;
    2) run_check "$REPO" "$B" "$V" 'nope' ;;
  esac
  assert_contains "$OUT" 'REBASE-EQUIVALENCE:' 'every run must print a verdict line'
  expect_code "$scenario" "$RC" 'the exit status must match the verdict printed'
done
pass 'every outcome prints a verdict line and exits with its own status'

printf 'all rebase-equivalence tests passed\n'

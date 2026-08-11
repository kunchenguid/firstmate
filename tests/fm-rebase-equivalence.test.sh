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

# commit_mode <dir> <path> <+x|-x> <message>: commit with the path's recorded
# file mode set explicitly, so a mode scenario means the same thing whatever
# the checkout's umask or filesystem does with the executable bit.
commit_mode() {  # <dir> <path> <+x|-x> <message>
  # The on-disk bit is set as well as the recorded one, so the commit leaves a
  # clean worktree whether or not the checkout honours core.filemode.
  chmod "$3" "$1/$2"
  git_do "$1" add -A
  git_do "$1" update-index --chmod="$3" -- "$2"
  git_do "$1" commit -qm "$4"
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

# The same failure with the counts the other way round: the file already held
# MORE copies than the change added. Requiring only the net added count clears
# this by mistake, because the copies that were always there already satisfy it.

REPO=$(new_repo duplicate-line-partial-drop)
printf 'alpha\nguard\nbravo\nguard\n' > "$REPO/core.sh"
B=$(commit_all "$REPO" 'base: two guards already present')

printf 'alpha\nguard\nbravo\nguard\nguard\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one more guard')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'shared\ntrunk moved on\n' > "$REPO/README.md"
T=$(commit_all "$REPO" 'trunk: unrelated movement')
printf 'unrelated\n' > "$REPO/unrelated.txt"
C=$(commit_all "$REPO" 'candidate: the guard hunk never landed')

run_check "$REPO" "$B" "$V" "$C" --candidate-base "$T"
expect_code 3 "$RC" 'a dropped hunk must be refused even when the file already held more copies'
assert_contains "$OUT" 'dropped-content' 'the lost copy must be reported as dropped content'
pass 'the candidate must carry what the validated head holds, not merely what the change added'

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

# --- refusal: an executable bit the validated change set is lost ------------
#
# Every script in this repository must be executable, so a rebase that lands
# one at 100644 has lost real validated content. A mode change emits only
# `old mode`/`new mode` lines and no `@@` hunk, so a line-only comparison sees
# nothing at all and records the path as carried.

REPO=$(new_repo mode-drop)
B=$(git -C "$REPO" rev-parse HEAD)

printf '#!/usr/bin/env bash\necho new\n' > "$REPO/new.sh"
V=$(commit_mode "$REPO" new.sh +x 'validated: add an executable script')

git_do "$REPO" checkout -q -b trunk "$B"
printf '#!/usr/bin/env bash\necho new\n' > "$REPO/new.sh"
C=$(commit_mode "$REPO" new.sh -x 'candidate: the same script landed non-executable')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'a dropped executable bit must be refused'
assert_contains "$OUT" 'dropped-mode' 'a lost mode must be named with its own direction'
assert_contains "$OUT" 'new.sh' 'the path whose mode was lost must be named'
assert_contains "$OUT" '100755' 'the mode the validated change set must be named'
pass 'an executable bit the validated change set is validated content'

# The same loss with no content change at all: the validated change only ran
# chmod, so there is not one line for a content comparison to look at.

REPO=$(new_repo mode-only-drop)
printf '#!/usr/bin/env bash\necho hi\n' > "$REPO/run.sh"
B=$(commit_mode "$REPO" run.sh -x 'base: a script that is not executable yet')
V=$(commit_mode "$REPO" run.sh +x 'validated: make it executable')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'shared\ntrunk moved on\n' > "$REPO/README.md"
C=$(commit_all "$REPO" 'candidate: the trunk moved and the chmod never landed')

run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'a mode-only validated change that is lost must be refused'
assert_contains "$OUT" 'dropped-mode' 'a mode-only loss must still be named'
assert_contains "$OUT" 'run.sh' 'the path whose mode-only change was lost must be named'
pass 'a validated change made entirely of a mode is not silently cleared'

# --- pass: a mode the validated change never touched belongs to the trunk ---

REPO=$(new_repo mode-trunk-owned)
printf '#!/usr/bin/env bash\necho hi\n' > "$REPO/run.sh"
B=$(commit_mode "$REPO" run.sh -x 'base: a script that is not executable yet')
printf '#!/usr/bin/env bash\necho hi\nvalidated line\n' > "$REPO/run.sh"
V=$(commit_all "$REPO" 'validated: one addition, mode untouched')

git_do "$REPO" checkout -q -b trunk "$B"
printf '#!/usr/bin/env bash\necho hi\nvalidated line\n' > "$REPO/run.sh"
C=$(commit_mode "$REPO" run.sh +x 'candidate: the trunk made it executable')

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'a mode the validated change never set must not read as loss'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'a trunk-owned mode must still pass'
pass 'only a mode the validated change set is required of the candidate'

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
commit_all "$REPO" 'trunk: surround the region' > /dev/null
printf 'trunk prologue\nalpha\nbravo\ncharlie\nvalidated addition\ntrunk epilogue\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: validated addition reapplied in its new position')

run_check "$REPO" "$B" "$V" "$C"
expect_code 0 "$RC" 'a faithful rebase over a moved trunk must pass'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'a faithful rebase must report PASS'
pass 'a faithful rebase over a moved trunk still passes'

# --- pass: the same trunk ref given to both base flags -----------------------
#
# Both flags take a TRUNK ref, so handing the same one to both must mean the
# same thing on both sides. Used verbatim, a moved trunk turns every
# trunk-only line into a removal the validated change never made, and the
# faithful rebase that carries it is refused as resurrected content.

REPO=$(new_repo shared-trunk-base)
B=$(git -C "$REPO" rev-parse HEAD)

printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one addition')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'alpha\nbravo\ncharlie\ntrunk only line\n' > "$REPO/core.sh"
T=$(commit_all "$REPO" 'trunk: one addition of its own')
printf 'alpha\nbravo\ncharlie\ntrunk only line\nvalidated line\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: the validated addition replayed onto the moved trunk')

run_check "$REPO" "$T" "$V" "$C" --candidate-base "$T"
expect_code 0 "$RC" 'the same trunk given to both base flags must mean the same thing'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'a moved trunk named as both bases must still pass'
pass 'both base flags take a trunk ref and narrow it to their own head'

# The validated base may then be omitted entirely, which is the form the
# header documents: the validated head's own base is that same trunk narrowed
# to the validated head.

RC=0
OUT=$("$CHECK" --repo "$REPO" --validated-head "$V" \
  --candidate-head "$C" --candidate-base "$T" 2>&1) || RC=$?
expect_code 0 "$RC" 'a candidate trunk alone must resolve the validated base too'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'the derived validated base must report PASS'
pass 'the candidate trunk alone resolves both bases'

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

# The candidate must differ from the validated head here, or the comparison
# would be refused as vacuous before the contribution is ever measured.
run_check "$REPO" "$V" "$V" "$B"
expect_code 2 "$RC" 'an empty validated contribution must be could-not-observe'
assert_contains "$OUT" 'validated contribution is empty' 'an empty contribution must say so'
pass 'an empty validated contribution refuses instead of passing vacuously'

# --- the fail-open holes: a verdict reached without comparing anything -------
#
# Each of these produced a confident verdict before the guards existed: the
# vacuous case printed PASS in a form indistinguishable from a real comparison,
# and the empty remote silently resolved the validated head as an ordinary
# local ref. Both are the "passes without looking" outcome this check exists to
# make impossible, so both must refuse.

run_check "$REPO" "$B" "$V" "$V"
expect_code 2 "$RC" 'a head compared against itself must be could-not-observe'
assert_contains "$OUT" 'resolve to the same commit' 'the vacuous comparison must name why nothing was compared'
assert_not_contains "$OUT" 'PASS' 'a vacuous comparison must never read as a pass'
pass 'a head compared against itself refuses instead of passing vacuously'

RC=0
OUT=$("$CHECK" --repo "$REPO" --validated-base "$B" --validated-head "$V" \
  --validated-remote "" --candidate-head "$B" 2>&1) || RC=$?
expect_code 2 "$RC" 'an explicitly empty flag value must be could-not-observe'
assert_contains "$OUT" 'empty value' 'the empty flag value must be named'
pass 'an explicitly empty flag value refuses instead of silently falling back'

RC=0
OUT=$("$CHECK" --repo "$REPO" --validated-head "$V" \
  --candidate-pr https://github.com/example/example/pull/1 2>&1) || RC=$?
expect_code 2 "$RC" 'a forge candidate without an authoritative validated head must refuse'
assert_contains "$OUT" '--validated-remote' 'the missing authoritative source must be named'
pass 'a forge candidate is never compared against a local validated ref'

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

# --- a textconv gitattribute must not turn a drop into a pass ---------------
#
# The counted copies come from `git show <commit>:<path>`, which always emits
# the raw blob, while `git diff` applies a `diff=<driver>` textconv wherever the
# repository configures one. Harvesting converted lines and counting raw ones
# compares two different texts, and it fails OPEN: a harvested line that occurs
# nowhere in the validated copy requires zero copies of itself, so a candidate
# that dropped the hunk outright reports PASS. This repository has no
# .gitattributes, but --repo takes any directory, so the fixture builds one.

# Built inline rather than from new_repo, because the driver must be in force
# at the BASE commit: git reads .gitattributes from the worktree, so a fixture
# that introduced it later would lose it at the first checkout back to the base.
REPO="$TMP_ROOT/textconv"
mkdir -p "$REPO"
git -C "$REPO" init -q
cat > "$TMP_ROOT/upcase.sh" <<'SH'
#!/bin/sh
exec tr a-z A-Z < "$1"
SH
chmod +x "$TMP_ROOT/upcase.sh"
git -C "$REPO" config diff.upcase.textconv "$TMP_ROOT/upcase.sh"
printf 'core.sh diff=upcase\n' > "$REPO/.gitattributes"
printf 'alpha\nbravo\ncharlie\n' > "$REPO/core.sh"
B=$(commit_all "$REPO" 'base: core.sh carries a textconv diff driver')
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one addition, under a textconv driver')

git_do "$REPO" checkout -q -b trunk "$B"
printf 'unrelated\n' > "$REPO/unrelated.txt"
C=$(commit_all "$REPO" 'candidate: the validated line never landed')

# The driver must really be in force, or this case would prove nothing.
git -C "$REPO" diff "$B" "$V" -- core.sh | grep -q '^+VALIDATED LINE$' \
  || fail 'the textconv fixture must actually convert the diff it produces'
run_check "$REPO" "$B" "$V" "$C"
expect_code 3 "$RC" 'a textconv driver must not hide a dropped hunk'
assert_contains "$OUT" 'dropped-content' 'the drop must still be named under a textconv driver'
assert_contains "$OUT" 'core.sh' 'the losing path must be named under a textconv driver'
pass 'a converted diff cannot be counted against raw copies and pass by not comparing'

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
# The validated head lives only in a stand-in for the pipeline's gate
# repository, exactly as a run's own fix commits do. Pairing a forge candidate
# with a local validated ref is the defect this check was rebuilt to remove, so
# the fixture makes BOTH sides authoritative and the check must fetch each.
git_do "$SRC" checkout -q -b validated "$B"
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$SRC/core.sh"
V=$(commit_all "$SRC" 'validated: one addition')
GATE="$TMP_ROOT/gate.git"
git init -q --bare -b main "$GATE"
git_do "$SRC" push -q "$GATE" "$V:refs/heads/fm/work"

WORKER="$TMP_ROOT/worker"
git clone -q --no-local "$FORGE" "$WORKER"
# Requests are addressed by URL because a bare number names no repository, so
# the check cannot prove any source is the one the request belongs to.
git -C "$WORKER" config "url.$FORGE.insteadOf" 'https://github.com/o/r.git'

for absent in "$D" "$V"; do
  if git -C "$WORKER" cat-file -e "$absent^{commit}" 2>/dev/null; then
    fail 'the fixture must not already hold a head the check is meant to fetch'
  fi
done

run_check_pr "$WORKER" "$B" "$V" 'https://github.com/o/r/pull/7' --candidate-base origin/main --validated-remote "$GATE"
expect_code 3 "$RC" 'a dropping candidate fetched from the forge must be refused'
assert_contains "$OUT" 'dropped-content' 'the fetched candidate must be compared, not skipped'
assert_contains "$OUT" 'core.sh' 'the losing path must be named'
pass 'a head that exists only on the forge is fetched and refused'

run_check_pr "$WORKER" "$B" "$V" 'https://github.com/o/r/pull/8' --candidate-base origin/main --validated-remote "$GATE"
expect_code 0 "$RC" 'a faithful candidate fetched from the forge must pass'
pass 'a faithful head fetched from the forge still passes'

run_check_pr "$WORKER" "$B" "$V" 'https://github.com/o/r/pull/9' --candidate-base origin/main --validated-remote "$GATE"
expect_code 2 "$RC" 'an unfetchable request must be could-not-observe'
assert_contains "$OUT" 'cannot fetch the candidate head' 'the unreachable candidate must say so'
pass 'a candidate that cannot be fetched refuses instead of passing'

run_check_pr "$WORKER" "$B" "$V" 'not-a-request' --candidate-base origin/main --validated-remote "$GATE"
expect_code 2 "$RC" 'an unparseable request must be could-not-observe'
pass 'a request that is neither a URL nor a number is could-not-observe'

# --- only the repository the request URL names may answer for it ------------
#
# A request number is unique only within one repository and every forge
# publishes the same head namespace for all of them, so a remote that is not
# that repository answers with a DIFFERENT request carrying the same number.
# This fixture is that collision: the worker's own origin holds a request 7 that
# would clear the comparison, while the URL names a repository the worker cannot
# reach at all. Answering from origin would be a confident verdict about code
# nobody asked about, so the only sound outcome is could-not-observe.

COLLIDE="$TMP_ROOT/collide.git"
git init -q --bare -b main "$COLLIDE"
git_do "$SRC" push -q "$COLLIDE" "$T:refs/heads/main" "$F:refs/merge-requests/7/head"
COLLIDE_WORKER="$TMP_ROOT/collide-worker"
git clone -q --no-local "$COLLIDE" "$COLLIDE_WORKER"
git_do "$COLLIDE_WORKER" checkout -q -b work "$B"
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$COLLIDE_WORKER/core.sh"
CV=$(commit_all "$COLLIDE_WORKER" 'validated: one addition')

run_check_pr "$COLLIDE_WORKER" "$B" "$CV" \
  'https://127.0.0.1/group/project/-/merge_requests/7' --candidate-base origin/main --validated-remote "$GATE"
expect_code 2 "$RC" 'a request must never be answered by a repository it does not name'
assert_not_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' \
  'a colliding request number must not clear the comparison'
assert_not_contains "$OUT" 'REBASE-EQUIVALENCE: DROPPED' \
  'a colliding request number must not fabricate a refusal'
pass 'a remote that does not name the request repository is never used for it'

run_check_pr "$WORKER" "$B" "$V" 'https://github.com/example/project/pull/8' \
  --candidate-remote "$FORGE" --candidate-base origin/main --validated-remote "$GATE"
expect_code 2 "$RC" 'a remote that names another repository must be refused'
assert_contains "$OUT" 'not github.com/example/project' \
  'the mismatch must name the repository the request URL identifies'
pass 'a candidate remote is refused unless it is proven to be the request repository'

# --- the request URL resolves the head, the base, and the validated base ----
#
# `url.<local>.insteadOf` lets the check reach the fixture forge through the
# exact https URL it derives from the request, so the identity rule, the
# request-derived base, and the fetches are all exercised offline. `gh` is
# stubbed because the base BRANCH name is forge metadata, not a ref.

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_GH_FAIL:-0}" = 0 ] || exit 1
printf '%s\n' "${FM_FAKE_GH_BASE:-main}"
SH
chmod +x "$FAKEBIN/gh"
PATH="$FAKEBIN:$PATH"
export PATH

git -C "$WORKER" config "url.$FORGE.insteadOf" 'https://github.com/example/project.git'

RC=0
OUT=$("$CHECK" --repo "$WORKER" --validated-head "$V" --validated-remote "$GATE" \
  --candidate-pr 'https://github.com/example/project/pull/8' 2>&1) || RC=$?
expect_code 0 "$RC" 'a faithful candidate resolved wholly from the request must pass'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'the request-resolved comparison must report PASS'
pass 'the request URL alone resolves the head, the trunk, and the validated base'

RC=0
OUT=$("$CHECK" --repo "$WORKER" --validated-head "$V" --validated-remote "$GATE" \
  --candidate-pr 'https://github.com/example/project/pull/7' 2>&1) || RC=$?
expect_code 3 "$RC" 'a dropping candidate resolved wholly from the request must be refused'
assert_contains "$OUT" 'core.sh' 'the losing path must be named'
pass 'a request-resolved comparison still refuses a dropping rebase'

RC=0
OUT=$(FM_FAKE_GH_FAIL=1 "$CHECK" --repo "$WORKER" --validated-head "$V" --validated-remote "$GATE" \
  --candidate-pr 'https://github.com/example/project/pull/8' 2>&1) || RC=$?
expect_code 2 "$RC" 'a base the forge cannot report must be could-not-observe'
assert_contains "$OUT" 'cannot read the base branch' 'the unreadable base must say so'
RC=0
OUT=$(FM_FAKE_GH_BASE=no-such-branch "$CHECK" --repo "$WORKER" --validated-head "$V" --validated-remote "$GATE" \
  --candidate-pr 'https://github.com/example/project/pull/8' 2>&1) || RC=$?
expect_code 2 "$RC" 'a base branch that cannot be fetched must be could-not-observe'
# The validated side is made obtainable so this reaches the NUMBER's own
# refusal rather than the earlier missing-validated-remote guard, and the text
# is asserted because exit 2 alone cannot tell those two refusals apart.
run_check_pr "$WORKER" "$B" "$V" 8 --validated-remote "$GATE"
expect_code 2 "$RC" 'a bare request number names no repository, so it must be could-not-observe'
assert_contains "$OUT" 'names no repository' \
  'the bare-number refusal must be distinguishable from a missing validated remote'
assert_not_contains "$OUT" 'needs --validated-remote' \
  'this case must exercise the bare number, not an input it forgot to pass'
pass 'a candidate base that cannot be read from the request never falls back to a local ref'

# --- the request's base is fetched, never read from a stale local ref -------
#
# The trunk has moved by definition whenever this check matters, since
# otherwise no rebase would have been needed. Here the trunk grew a block that
# happens to contain the line the validated change deleted, and the candidate is
# a faithful rebase onto it. Measured against the trunk the candidate really
# sits on, that is carried; measured against the worker's stale origin/main, it
# reads as a resurrected removal.

STALE_SRC="$TMP_ROOT/stale-src"
mkdir -p "$STALE_SRC"
git -C "$STALE_SRC" init -q
printf 'alpha\nguard\nbravo\n' > "$STALE_SRC/core.sh"
SB=$(commit_all "$STALE_SRC" 'base: one guard')

STALE_FORGE="$TMP_ROOT/stale-forge.git"
git init -q --bare -b main "$STALE_FORGE"
git_do "$STALE_SRC" push -q "$STALE_FORGE" "$SB:refs/heads/main"

STALE_WORKER="$TMP_ROOT/stale-worker"
git clone -q --no-local "$STALE_FORGE" "$STALE_WORKER"
git -C "$STALE_WORKER" config "url.$STALE_FORGE.insteadOf" 'https://github.com/example/stale.git'
git_do "$STALE_WORKER" checkout -q -b work "$SB"
printf 'alpha\nbravo\n' > "$STALE_WORKER/core.sh"
SV=$(commit_all "$STALE_WORKER" 'validated: drop the guard')
# The validated head must come from an authoritative source here too, so it is
# published to a stand-in gate rather than read off the worker's own branch.
STALE_GATE="$TMP_ROOT/stale-gate.git"
git init -q --bare -b main "$STALE_GATE"
git_do "$STALE_WORKER" push -q "$STALE_GATE" "$SV:refs/heads/fm/work"

printf 'alpha\nguard\nbravo\ndelta\nguard\n' > "$STALE_SRC/core.sh"
ST=$(commit_all "$STALE_SRC" 'trunk: a later block that also ends in guard')
printf 'alpha\nbravo\ndelta\nguard\n' > "$STALE_SRC/core.sh"
SC=$(commit_all "$STALE_SRC" 'candidate: the validated removal reapplied on the moved trunk')
git_do "$STALE_SRC" push -q "$STALE_FORGE" "$ST:refs/heads/main" "$SC:refs/pull/5/head"

RC=0
OUT=$("$CHECK" --repo "$STALE_WORKER" --validated-head "$SV" --validated-remote "$STALE_GATE" \
  --candidate-pr 'https://github.com/example/stale/pull/5' 2>&1) || RC=$?
expect_code 0 "$RC" 'the base fetched from the request must clear a faithful rebase'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' 'the request-fetched base must report PASS'
run_check "$STALE_WORKER" "$SB" "$SV" 'refs/fm-rebase-equivalence/candidate/5' \
  --candidate-base origin/main --validated-remote "$GATE"
expect_code 3 "$RC" 'the same comparison against the stale local trunk must diverge'
pass 'the candidate base comes from the request, so a stale local trunk cannot refuse a faithful rebase'

# --- the validated head comes from the pipeline, never from this clone ------
#
# A run commits its own fixes onto its copy of the branch, so the worker's head
# holds OLDER content. Here the pipeline's accepted fix rewrote a line the
# branch added - foo(a) became foo(a, b) - and the push carried that faithfully.
# Comparing the worker's own head reports the pipeline's own fix as dropped
# content; comparing the head the run record names reports the truth. The
# pipeline's repository keeps that commit only as a loose object with no ref
# pointing at it, exactly as a gate whose branch has moved past it does.

PIPE_SRC="$TMP_ROOT/pipeline-src"
mkdir -p "$PIPE_SRC"
git -C "$PIPE_SRC" init -q
printf 'alpha\nbravo\ncharlie\n' > "$PIPE_SRC/core.sh"
printf 'shared\n' > "$PIPE_SRC/README.md"
PB=$(commit_all "$PIPE_SRC" 'base')
printf 'alpha\nbravo\ncharlie\nfoo(a)\n' > "$PIPE_SRC/core.sh"
commit_all "$PIPE_SRC" 'submitted: the branch as the worker handed it over' > /dev/null
printf 'alpha\nbravo\ncharlie\nfoo(a, b)\n' > "$PIPE_SRC/core.sh"
PV=$(commit_all "$PIPE_SRC" 'validated: the pipeline applied its own accepted fix')

git_do "$PIPE_SRC" checkout -q -b pipe-trunk "$PB"
printf 'shared\ntrunk moved on\n' > "$PIPE_SRC/README.md"
PT=$(commit_all "$PIPE_SRC" 'trunk: moved on')
printf 'alpha\nbravo\ncharlie\nfoo(a, b)\n' > "$PIPE_SRC/core.sh"
PC=$(commit_all "$PIPE_SRC" 'candidate: the validated head replayed onto the moved trunk')

PIPE="$TMP_ROOT/pipeline.git"
git init -q --bare -b main "$PIPE"
git_do "$PIPE_SRC" push -q "$PIPE" "$PV:refs/heads/parked" "$PC:refs/heads/fm/work"
git --git-dir="$PIPE" update-ref -d refs/heads/parked

PIPE_FORGE="$TMP_ROOT/pipeline-forge.git"
git init -q --bare -b main "$PIPE_FORGE"
git_do "$PIPE_SRC" push -q "$PIPE_FORGE" "$PT:refs/heads/main" "$PC:refs/pull/3/head"

PIPE_WORKER="$TMP_ROOT/pipeline-worker"
git clone -q --no-local "$PIPE_FORGE" "$PIPE_WORKER"
git -C "$PIPE_WORKER" config "url.$PIPE_FORGE.insteadOf" 'https://github.com/pipe/proj.git'
git_do "$PIPE_WORKER" checkout -q -b work "$PB"
printf 'alpha\nbravo\ncharlie\nfoo(a)\n' > "$PIPE_WORKER/core.sh"
PW=$(commit_all "$PIPE_WORKER" 'local: the branch as this clone still holds it')

if git -C "$PIPE_WORKER" cat-file -e "$PV^{commit}" 2>/dev/null; then
  fail 'the fixture must not already hold the validated head locally'
fi

# Reading the validated side from this clone is the defect itself: the run's
# fix commits are not here, so the pipeline's own accepted rewrite would read as
# dropped content. It is no longer merely wrong, it is refused outright, which
# is what makes the false refusal impossible rather than less likely.
run_check_pr "$PIPE_WORKER" "$PB" "$PW" 'https://github.com/pipe/proj/pull/3' --candidate-base origin/main
expect_code 2 "$RC" "a forge candidate must refuse a validated head read from this clone"
assert_contains "$OUT" '--validated-remote' \
  'the refusal must name the authoritative source it requires'
assert_not_contains "$OUT" 'dropped-content' \
  'the local validated head must never reach the comparison at all'

RC=0
OUT=$("$CHECK" --repo "$PIPE_WORKER" --validated-base "$PB" --validated-head "$PV" \
  --validated-remote "$PIPE" --candidate-pr 'https://github.com/pipe/proj/pull/3' --candidate-base origin/main 2>&1) || RC=$?
expect_code 0 "$RC" 'the head the run record names must clear a faithful push'
assert_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' \
  'a pipeline fix that rewrote a validated line must not read as dropped content'
# The fetched object must be present, since the comparison above used it, but
# the ref that carried it must NOT persist: one ref per validated commit would
# accumulate forever in what is a SHARED object store for a gate worktree, and
# each would pin its objects against gc.
git -C "$PIPE_WORKER" cat-file -e "$PV^{commit}" 2>/dev/null \
  || fail 'the validated head must actually be fetched, not merely named'
if git -C "$PIPE_WORKER" rev-parse --verify --quiet "refs/fm-rebase-equivalence/validated/$PV" >/dev/null; then
  fail 'the fetched validated ref must be released once the head resolves'
fi
pass 'the validated head is taken from the pipeline, so its own fixes are not read as loss'

RC=0
OUT=$("$CHECK" --repo "$PIPE_WORKER" --validated-base "$PB" --validated-head HEAD \
  --validated-remote "$PIPE" --candidate-pr 'https://github.com/pipe/proj/pull/3' --candidate-base origin/main --validated-remote "$GATE" 2>&1) || RC=$?
expect_code 2 "$RC" 'a symbolic validated head cannot name a commit on the pipeline side'
assert_contains "$OUT" 'full commit id' 'the refusal must say what the run record supplies'

ABSENT_OID=$(printf '%s' "$PW" | tr '0-9a-f' '1-9a-f0')
RC=0
OUT=$("$CHECK" --repo "$PIPE_WORKER" --validated-base "$PB" --validated-head "$ABSENT_OID" \
  --validated-remote "$PIPE" --candidate-pr 'https://github.com/pipe/proj/pull/3' --candidate-base origin/main --validated-remote "$GATE" 2>&1) || RC=$?
expect_code 2 "$RC" 'a validated head no side holds must be could-not-observe'
assert_contains "$OUT" 'cannot fetch the validated head' 'the unfetchable validated head must say so'
assert_not_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' \
  'an unfetchable validated head must never resolve to something else'
assert_not_contains "$OUT" 'REBASE-EQUIVALENCE: DROPPED' \
  'an unfetchable validated head must never resolve to something else'
pass 'a validated head that cannot be obtained refuses instead of comparing anything'

# --- every fetch is non-interactive, including a caller-supplied ssh --------
#
# An unattended worker blocked on a passphrase or a host-key prompt prints no
# verdict line at all, and that is the one outcome a caller cannot tell apart
# from a crash. A caller that already exports GIT_SSH_COMMAND is the hard case:
# keeping its value verbatim drops batch mode and reopens exactly that hang, so
# the option must be APPENDED. This is measured on the ssh command git actually
# invokes rather than read off the script's source.

assert_grep 'GIT_TERMINAL_PROMPT=0' "$CHECK" \
  'every fetch must run non-interactively so a credential prompt cannot swallow the verdict'

SSH_LOG="$TMP_ROOT/ssh-argv.log"
FAKE_SSH="$TMP_ROOT/fm-fake-ssh"
cat > "$FAKE_SSH" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSH_LOG"
exit 255
SH
chmod +x "$FAKE_SSH"

RC=0
OUT=$(GIT_SSH_COMMAND="$FAKE_SSH -oIdentitiesOnly=yes" \
  "$CHECK" --repo "$PIPE_WORKER" --validated-base "$PB" --validated-head "$ABSENT_OID" \
  --validated-remote 'ssh://git@example.invalid/pipe/proj.git' \
  --candidate-head "$PW" 2>&1) || RC=$?
expect_code 2 "$RC" 'an ssh remote that cannot answer must refuse, never hang'
assert_present "$SSH_LOG" "the ssh form must reach the caller's own GIT_SSH_COMMAND"
assert_grep '-oBatchMode=yes' "$SSH_LOG" \
  'a fetch must stay in batch mode even when the caller already exported GIT_SSH_COMMAND'
assert_grep '-oIdentitiesOnly=yes' "$SSH_LOG" \
  "batch mode must be appended to the caller's ssh command rather than replace it"
pass 'the fetch path is non-interactive even when the caller supplies an ssh command'

RC=0
OUT=$("$CHECK" --repo "$WORKER" --validated-base "$B" --validated-head "$V" 2>&1) || RC=$?
expect_code 2 "$RC" 'naming no candidate at all must be could-not-observe'
assert_contains "$OUT" 'missing required --candidate-head or --candidate-pr' \
  'the missing candidate must be named'
RC=0
OUT=$("$CHECK" --repo "$WORKER" --validated-base "$B" --validated-head "$V" \
  --candidate-head "$V" --candidate-pr 'https://github.com/o/r/pull/8' 2>&1) || RC=$?
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

# The passing scenario needs a candidate that is a DIFFERENT commit carrying
# the validated content. Comparing the validated head against itself is refused
# as vacuous, so it can no longer stand in for a real pass here.
git_do "$REPO" checkout -q -b verdict-trunk "$B"
printf 'alpha\nbravo\ncharlie\nvalidated line\ntrunk epilogue\n' > "$REPO/core.sh"
VC=$(commit_all "$REPO" 'candidate: validated line carried, trunk moved too')

for scenario in 3 0 2; do
  case "$scenario" in
    3) run_check "$REPO" "$B" "$V" "$B" ;;
    0) run_check "$REPO" "$B" "$V" "$VC" ;;
    2) run_check "$REPO" "$B" "$V" 'nope' ;;
  esac
  assert_contains "$OUT" 'REBASE-EQUIVALENCE:' 'every run must print a verdict line'
  expect_code "$scenario" "$RC" 'the exit status must match the verdict printed'
done
pass 'every outcome prints a verdict line and exits with its own status'

# --- a cancelled run must not report a verdict -------------------------------
#
# Bash resumes at the next statement once a signal handler returns, so a handler
# that only cleaned up would hand the rest of the script a deleted working
# directory. The per-path result files would be gone, both emptiness tests would
# read false, and the run would print PASS and exit 0 - a confident clean
# verdict produced by cancelling the check.
#
# The signal is landed deterministically rather than raced: `tr` is shimmed to
# sleep after doing its real work, and the only `tr` this invocation reaches is
# the one that reads the per-path counts, which is the last file the loop opens.
# The handler therefore runs with the loop's remaining work all builtins, which
# is exactly the window that used to reach the PASS line.

REPO=$(new_repo cancelled)
B=$(git -C "$REPO" rev-parse HEAD)
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one addition')
git_do "$REPO" checkout -q -b cancel-trunk "$B"
printf 'alpha\nbravo\ncharlie\nvalidated line\ntrunk epilogue\n' > "$REPO/core.sh"
C=$(commit_all "$REPO" 'candidate: validated line carried, trunk moved too')

REAL_TR=$(command -v tr)
SIGBIN="$TMP_ROOT/signal-bin"
mkdir -p "$SIGBIN"
cat > "$SIGBIN/tr" <<SH
#!/usr/bin/env bash
"$REAL_TR" "\$@"
rc=\$?
sleep 5
exit \$rc
SH
chmod +x "$SIGBIN/tr"

CANCEL_OUT="$TMP_ROOT/cancelled.out"
PATH="$SIGBIN:$PATH" "$CHECK" --repo "$REPO" --validated-base "$B" \
  --validated-head "$V" --candidate-head "$C" > "$CANCEL_OUT" 2>&1 &
CANCEL_PID=$!
sleep 2
kill -TERM "$CANCEL_PID" 2>/dev/null || true
RC=0
wait "$CANCEL_PID" || RC=$?
OUT=$(cat "$CANCEL_OUT")

expect_code 143 "$RC" 'a run killed by TERM must exit on the signal, not on a verdict status'
assert_not_contains "$OUT" 'REBASE-EQUIVALENCE: PASS' \
  'cancelling the check must never produce a pass it did not earn'
assert_not_contains "$OUT" 'REBASE-EQUIVALENCE:' \
  'a cancelled comparison is not an observation, so it reports no verdict at all'
pass 'a signal terminates the run instead of falling through to a verdict'

# --- a bare request number names no repository -------------------------------
#
# Every forge publishes the same head namespace for every repository, so a bare
# number resolves against whichever repository the fallback source happens to
# be. Measured against this repo, where origin fetches upstream while requests
# are opened on the fork, that returned a confident DROPPED verdict over 12
# paths of an unrelated project's request. A verdict about code nobody asked
# about is worse than no verdict, so the numeric form is refused outright.

REPO=$(new_repo bare-number)
B=$(git -C "$REPO" rev-parse HEAD)
printf 'alpha\nbravo\ncharlie\nvalidated line\n' > "$REPO/core.sh"
V=$(commit_all "$REPO" 'validated: one addition')

# The validated side is made obtainable so the refusal is reached for the
# NUMBER's sake and not merely because some earlier input was missing.
BARE_GATE="$TMP_ROOT/bare-gate.git"
git init -q --bare -b main "$BARE_GATE"
git_do "$REPO" push -q "$BARE_GATE" "$V:refs/heads/fm/work"

RC=0
OUT=$("$CHECK" --repo "$REPO" --validated-base "$B" --validated-head "$V" \
  --validated-remote "$BARE_GATE" --candidate-pr 7 2>&1) || RC=$?
expect_code 2 "$RC" 'a bare request number must be could-not-observe'
assert_contains "$OUT" 'names no repository' 'the refusal must say why a number is not enough'
assert_not_contains "$OUT" 'DROPPED' 'a bare number must never produce a comparison verdict'
pass 'bare candidate-pr number refuses without repository identity'

printf 'all rebase-equivalence tests passed\n'

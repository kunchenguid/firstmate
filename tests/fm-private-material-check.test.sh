#!/usr/bin/env bash
# tests/fm-private-material-check.test.sh - behavior of the private-material gate.
#
# The seam under test is the script's observable contract, not its internals:
# given a repo and a private home, does it exit non-zero and name the offending
# file:line? Every fixture here is synthetic - this file must never carry a real
# project, owner, person, or device name, because the check exists to keep those
# out of the tracked surface and would be self-defeating if it leaked them.
#
# Exit codes are the contract, so every case asserts the exact one it expects and
# none of them settles for "not a failure": 0 proved clean, 1 found something,
# 3 proved nothing (SKIPPED or INCOMPLETE). Accepting 0 for all three is what let
# a run that proved nothing read as a passing guard.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-private-material-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-private-material-check)
fm_git_identity

# new_case <name>: a tracked repo plus an empty private home, and echo the base.
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/data" "$dir/home/projects" "$dir/home/config"
  fm_git_init_commit "$dir/repo" >/dev/null
  printf '%s' "$dir"
}

# clone <base> <name>: a project clone, which in a real home is a git repository.
# A bare directory would be a coverage gap of its own and would obscure whatever
# the case is actually about.
clone() {
  fm_git_init_commit "$1/home/projects/$2" >/dev/null
}

# track <base> <relpath> <content>: add a tracked file carrying <content>.
track() {
  local base=$1 rel=$2 content=$3
  mkdir -p "$(dirname "$base/repo/$rel")"
  printf '%s\n' "$content" > "$base/repo/$rel"
  git -C "$base/repo" add "$rel"
  git -C "$base/repo" -c user.name=t -c user.email=t@example.invalid commit -qm "add $rel"
}

run_check() {
  local base=$1; shift
  "$CHECK" --root "$base/repo" --home "$base/home" "$@" 2>&1
}

# --- a marker present in a tracked file fails and names the location ---------

base=$(new_case project-name-in-tracked-file)
clone "$base" widget-store
track "$base" docs/guide.md 'Deploy the widget-store service nightly.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a registered project name in a tracked file must fail"
assert_contains "$out" "widget-store" "failure must name the marker"
assert_contains "$out" "docs/guide.md:1" "failure must name the offending file and line"
pass "a project clone name appearing in a tracked file fails with its location"

# --- the same repo with no such text passes ---------------------------------

# The clone is a real repo here so the run has no coverage gap at all: an
# unqualified OK is exactly what must NOT appear when anything went unscanned.

base=$(new_case clean-surface)
clone "$base" widget-store
track "$base" docs/guide.md 'Deploy the service nightly.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "a clean tracked surface must pass"
assert_contains "$out" "OK -" "a fully covered clean run must report OK"
assert_not_contains "$out" "COVERAGE GAP" "a fully covered run must report no gap"
pass "a tracked surface free of every marker passes"

# --- every marker source is accounted for by name ----------------------------
# An operator cannot tell what a run covered unless the run says so, and an
# unaccounted source is how a name goes unscanned while the output reads clean.

assert_contains "$out" "projects/ clone directories: 1 name(s)" \
  "the run must report how many names each present source yielded"
assert_contains "$out" "data/projects.md: absent" \
  "the run must distinguish an absent source from an empty one"
pass "each marker source is reported by name with the count it contributed"

# --- separator-insensitivity: the case that a plain grep misses -------------
# A registered id leaks just as badly spelled as a display name, so "sm-thing"
# must also match "SM THING" and "SM Thing".

for spelling in 'SM THING' 'SM Thing' 'smthing' 'sm_thing'; do
  base=$(new_case "spelling-$(printf '%s' "$spelling" | tr ' ' '-')")
  printf -- '- sm-thing - Persistent firstmate for the thing (added 2026-01-01)\n' \
    > "$base/home/data/secondmates.md"
  track "$base" bin/example.sh "# label example: $spelling"
  out=$(run_check "$base") && code=0 || code=$?
  expect_code 1 "$code" "secondmate id must be caught spelled '$spelling'"
  assert_contains "$out" "bin/example.sh" "failure must name the file for '$spelling'"
done
pass "a registered secondmate id is caught in hyphen, space, underscore, and joined spellings"

# --- a marker inside a longer word does not fire -----------------------------

base=$(new_case word-boundary)
printf -- '- sm-thing - Persistent firstmate (added 2026-01-01)\n' > "$base/home/data/secondmates.md"
track "$base" docs/guide.md 'The transmthingle field is unrelated.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "a marker embedded in a longer word must not fire"
pass "matches are word-bounded, so a marker inside a longer word is not a hit"

# --- a forge owner is derived from a project clone's remote ------------------

base=$(new_case remote-owner)
clone "$base" localclone
git -C "$base/home/projects/localclone" remote add origin 'https://github.com/Acme-Private-Org/widget.git'
track "$base" docs/guide.md 'See https://github.com/Acme-Private-Org/widget for details.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a project clone's remote owner must be a marker"
assert_contains "$out" "acme-private-org" "failure must name the derived owner"
pass "a forge owner is derived from a project clone's remote and caught in tracked files"

# --- a remote whose URL yields no owner is reported, never dropped -----------
# An scp-style remote with a bare repository path has no owner component. Saying
# nothing would leave a forge owner unscanned while the run still read as
# covered, which is the failure this whole source exists to avoid.

base=$(new_case remote-owner-unparsed)
clone "$base" localclone
git -C "$base/home/projects/localclone" remote add origin 'git@buildhost:widget.git'
track "$base" docs/guide.md 'Nothing private here.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 3 "$code" "a remote that yields no owner must stop the run reading as clean"
assert_contains "$out" "COVERAGE GAP" "a remote that yields no owner must be reported"
assert_contains "$out" "remote.origin.url" "the gap must name the remote it could not resolve"
assert_not_contains "$out" "OK -" "a run with an unresolved remote must not read as a clean pass"
pass "a remote URL that yields no forge owner raises a coverage gap instead of vanishing"

# --- the allowlist suppresses a legitimately public identity -----------------

base=$(new_case allowlist)
clone "$base" localclone
git -C "$base/home/projects/localclone" remote add origin 'https://github.com/Acme-Private-Org/widget.git'
track "$base" docs/guide.md 'See https://github.com/Acme-Private-Org/widget for details.'
printf '# public upstream\nAcme-Private-Org\n' > "$base/home/config/private-material-allow"
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "an allowlisted identity must stop failing"
pass "an identity recorded in the allowlist is no longer treated as private"

# --- operator-supplied markers cover what nothing can derive ----------------

base=$(new_case extra-markers)
track "$base" docs/guide.md 'Bench unit 2026040005 is the reference rig.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "an underived token is invisible before it is declared"
printf '# not derivable from local state\n2026040005\n' > "$base/home/config/private-material-markers"
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a declared extra marker must be caught"
assert_contains "$out" "2026040005" "failure must name the declared marker"
pass "an operator-declared marker catches material nothing can derive"

# --- a hand-edited config file without a trailing newline keeps its last line -
# Missing newline-at-EOF is routine in a hand-edited file, and dropping the last
# line would drop a whole marker while the run still reported a result.

base=$(new_case markers-no-trailing-newline)
track "$base" docs/guide.md 'Bench unit 2026040005 is the reference rig.'
printf '%s' '2026040005' > "$base/home/config/private-material-markers"
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a declared marker on an unterminated final line must still be read"
pass "a config file with no trailing newline keeps its final marker"

# --- a declared marker is never dropped by the generic filter ----------------
# The generic filter exists to keep derived noise down, not to overrule an
# operator who has explicitly declared a token private. A fleet that really owns
# a generic-looking name declares it, and that declaration must win.

base=$(new_case declared-beats-stopword)
generic_word=$(sed -n '/^STOPWORDS="/,/"$/p' "$CHECK" | sed 's/^STOPWORDS="//' | awk 'NR==1 {print $1}')
[ -n "$generic_word" ] || fail "could not derive a stopword from $CHECK"
clone "$base" "$generic_word"
track "$base" docs/guide.md "The $generic_word service is ours."
out=$(run_check "$base") && code=0 || code=$?
expect_code 3 "$code" "a generic derived name is filtered, so the run proved nothing"
assert_contains "$out" "COVERAGE GAP" "a filtered derived name must be reported, never silent"
assert_contains "$out" "$generic_word" "the gap must name the derived name it dropped"
assert_not_contains "$out" "OK -" "a run that dropped a name must not read as a clean pass"
printf '%s\n' "$generic_word" > "$base/home/config/private-material-markers"
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a declared marker must be scanned even when it looks generic"
pass "a generic name is dropped loudly when derived and honored when declared"

# --- an allowlist entry never allows its interior words ----------------------
# The markers file holds people too, so multi-word entries are expected. A
# multi-word allowance must suppress that identity and nothing else.

base=$(new_case allowlist-multiword)
clone "$base" foundry
track "$base" docs/guide.md 'The foundry pipeline runs nightly.'
printf 'Open Foundry\n' > "$base/home/config/private-material-allow"
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a multi-word allowance must not allow its interior words"
assert_contains "$out" "foundry" "the standalone marker must still be reported"
pass "an allowlist entry with a space suppresses only that whole identity"

# --- a present-but-empty marker source is never silent -----------------------
# A registry that exists but parses to nothing means a whole class of names went
# unscanned. Reporting OK there would be the exact false confidence this gate
# exists to prevent.

base=$(new_case empty-source)
clone "$base" widget-store
printf '\n' > "$base/home/data/projects.md"
track "$base" docs/guide.md 'Nothing private here.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 3 "$code" "an unparsed source must exit as proved-nothing, not as clean"
assert_contains "$out" "COVERAGE GAP" "a present-but-empty source must be reported"
assert_contains "$out" "INCOMPLETE" "a run with a gap must say it proved nothing clean"
assert_not_contains "$out" "OK -" "a run with a gap must not read as a clean pass"
pass "a source that is present but yields nothing reports INCOMPLETE, never OK"

# --- an empty directory of clones is a legitimate zero, not a gap ------------
# A fresh home, or one whose clones live only in a secondmate home, has nothing
# to enumerate. Warning there would make every run yellow, and a guard that
# always warns is one people stop reading.

base=$(new_case empty-clone-directory)
printf -- '- widget-store [no-mistakes off] - a registered project\n' \
  > "$base/home/data/projects.md"
track "$base" docs/guide.md 'Nothing private here.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "an empty clone directory must not downgrade a clean run"
assert_contains "$out" "projects/ clone directories: 0 name(s)" \
  "the empty directory must still be accounted for by name and count"
assert_not_contains "$out" "COVERAGE GAP" "an unambiguous zero must not be reported as a gap"
pass "an empty projects/ directory is reported as zero without raising a coverage gap"

# --- the legacy bracketless registry line is still parsed --------------------
# bin/fm-project-mode.sh still resolves "- <name> - <desc>", so a project
# registered that way must not go unscanned.

base=$(new_case legacy-registry-form)
printf -- '- legacy-thing - a registered project (added 2026-01-01)\n' \
  > "$base/home/data/projects.md"
track "$base" docs/guide.md 'The legacy-thing rollout continues.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a bracketless registry entry must still yield a marker"
assert_contains "$out" "legacy-thing" "failure must name the legacy-form project"
pass "both the delivery-mode and legacy registry line forms yield markers"

# --- the local account name is a marker, so machine-local paths are caught ---
# Derived at runtime here too, so this test hardcodes no real account name.

acct=$(id -un 2>/dev/null || printf '')
acct_lower=$(printf '%s' "$acct" | tr '[:upper:]' '[:lower:]')
# Derived from the script rather than copied: a second copy would drift the
# moment a stopword changes, and the drift would be silent in both directions.
stopwords=$(sed -n '/^STOPWORDS="/,/"$/p' "$CHECK" | sed 's/^STOPWORDS="//; s/"$//' | tr '\n' ' ')
[ -n "$(printf '%s' "$stopwords" | tr -d '[:space:]')" ] \
  || fail "could not derive the stopword list from $CHECK"
generic=" $stopwords "
case "$generic" in
  *" $acct_lower "*) acct='' ;;
esac
if [ -n "$acct" ] && [ "${#acct}" -ge 3 ]; then
  base=$(new_case account-name)
  track "$base" docs/guide.md "Run it from /home/$acct/firstmate to reproduce."
  out=$(run_check "$base") && code=0 || code=$?
  expect_code 1 "$code" "a machine-local home path must be caught via the account name"
  pass "the local account name is a marker, so a machine-local path in a tracked file fails"
else
  pass "account-name marker case skipped: this account name is filtered as generic or too short"
fi

# --- a vacuous run must announce itself rather than read as a clean pass -----
# On a runner with no private dirs there is nothing to derive. That MUST NOT
# look like evidence the surface is clean, or CI would launder a false negative.

base=$(new_case no-marker-sources)
rm -rf "${base:?}/home"
mkdir -p "$base/home"
track "$base" docs/guide.md 'Nothing private here.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 3 "$code" "a vacuous run must exit as proved-nothing, never as clean"
assert_contains "$out" "SKIPPED" "a vacuous run must say SKIPPED"
assert_contains "$out" "proves nothing" "a vacuous run must refuse to read as a clean pass"
assert_not_contains "$out" "OK -" "a vacuous run must not report a clean result"
pass "a run with no marker sources reports SKIPPED and disclaims its own result"

# --- --history reaches commits whose tip no longer carries the marker --------
# A marker deleted at tip is still published forever once the repo is public.

base=$(new_case history)
clone "$base" widget-store
track "$base" docs/guide.md 'Deploy the widget-store service.'
printf 'Deploy the service.\n' > "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
git -C "$base/repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'scrub'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "the tip scan must pass once the marker is removed from tip"
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 1 "$code" "--history must still catch a marker removed at tip"
assert_contains "$out" "HISTORY" "history failure must be labelled distinctly from a tip hit"
pass "--history catches a marker that only survives in past commits"

# --- a dirty checkout is not the surface a push publishes --------------------
# git grep reads the working tree, so editing a marker out without committing it
# would otherwise make the default scan report clean on the very commit that
# carries the marker into the target repository.

base=$(new_case committed-not-in-worktree)
clone "$base" widget-store
track "$base" docs/guide.md 'Deploy the widget-store service.'
printf 'Deploy the service.\n' > "$base/repo/docs/guide.md"
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a committed marker edited out of the working tree must still fail"
assert_contains "$out" "AT HEAD" "the committed-only hit must be labelled distinctly"
assert_contains "$out" "docs/guide.md:1" "the committed-only hit must name file and line"
pass "the default scan reads HEAD too, so a dirty checkout cannot hide a committed marker"

# --- --history matches case-insensitively, exactly like the tip scan ---------
# Markers are lowercased, so a history scan that respected case would miss the
# display-name spelling the tip scan catches - and history cannot be un-published.

base=$(new_case history-case)
clone "$base" widget-store
track "$base" docs/guide.md 'Deploy the Widget-Store service.'
printf 'Deploy the service.\n' > "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
git -C "$base/repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'scrub'
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 1 "$code" "--history must catch a marker spelled with different case"
assert_contains "$out" "HISTORY" "the mixed-case history hit must be labelled as history"
pass "--history is case-insensitive, so a display-name spelling cannot slip through"

# --- --history also reads commit metadata, which travels with a pull request ---
# An author identity is the usual way a real name or an org email domain reaches
# a third-party repo, and no file-content scan would ever see it.

base=$(new_case commit-metadata)
clone "$base" widget-store
track "$base" docs/guide.md 'Nothing private in the text.'
printf 'more\n' >> "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
# The identity must come from the environment: tests/lib.sh exports
# GIT_AUTHOR_*, which git prefers over any -c user.email passed here.
GIT_AUTHOR_NAME='A Person' GIT_AUTHOR_EMAIL='someone@widget-store.example' \
GIT_COMMITTER_NAME='A Person' GIT_COMMITTER_EMAIL='someone@widget-store.example' \
  git -C "$base/repo" commit -qm 'ordinary subject'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "a marker only in commit metadata must not fail the tip scan"
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 1 "$code" "--history must catch a marker carried in an author identity"
assert_contains "$out" "COMMIT METADATA" "metadata failure must be labelled distinctly"
pass "--history catches a marker in commit metadata that no file-content scan sees"

# --- a multi-line commit body cannot hide a marker from the line scan ---------

base=$(new_case commit-body)
clone "$base" widget-store
track "$base" docs/guide.md 'Nothing private in the text.'
printf 'more\n' >> "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
git -C "$base/repo" -c user.name=t -c user.email=t@example.invalid \
  commit -qm 'subject' -m 'first body line' -m 'context: widget-store rollout'
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 1 "$code" "a marker in a later commit-body line must still be caught"
pass "a marker buried in a multi-line commit body is still caught"

# --- teeth on this repo's real tracked surface, when a real home is named -----
# Every case above proves the script works against fixtures; none of them looks
# at firstmate's own tracked files. Point FM_HOME at a real operational home and
# this last case becomes a genuine regression guard on the surface we publish.
# Without it there is nothing to derive, so it skips loudly rather than passing
# quietly - a skip here must never read as "the tracked surface is clean".

if [ -n "${FM_HOME:-}" ] && { [ -d "$FM_HOME/data" ] || [ -d "$FM_HOME/projects" ]; }; then
  out=$("$CHECK" --root "$ROOT" --home "$FM_HOME" 2>&1) && code=0 || code=$?
  # Exit 0 specifically: 3 would mean the run proved nothing, and accepting it
  # here would report a guard as passing on the strength of a run that did not
  # look. Exit 3 on a real home means the run itself named what it could not
  # cover, and that is the thing to fix, not the assertion.
  expect_code 0 "$code" \
    "firstmate's own tracked surface must be PROVED clean (exit 0); exit 3 means the run proved nothing"$'\n'"$out"
  pass "this repo's tracked surface is free of every marker derived from FM_HOME"
else
  # Deliberately not an "ok -" line: a case that never ran must never be
  # counted, read, or parsed as a passing one.
  printf 'skip: the real-surface case did NOT run - no operational home named by FM_HOME\n'
  printf '#      nothing above checked firstmate own tracked surface; run it with\n'
  printf '#      FM_HOME set, or run bin/fm-private-material-check.sh directly.\n'
fi

printf '# all fm-private-material-check tests passed\n'

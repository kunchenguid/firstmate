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

# The script derives a marker from `id -un`. On a host whose account name is a
# STOPWORDS entry or shorter than MIN_LEN, that raises a coverage gap and
# downgrades every case here that asserts a clean run - so the suite's result
# would depend on who is running it. Shim `id` to a synthetic name instead, used
# by every case including the real-surface one at the end. The one deliberate
# exception is the real-account case beside it, which needs the host's own name
# on the surface and so states plainly when that name cannot be derived.
# The name is generated rather than written literally: the real-surface case
# scans THIS repo's tracked files, and a literal would sit in this very file and
# match itself. Generating it also hardcodes no real account name.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_ID=$(command -v id)
TEST_ACCOUNT="fmacct$$"
cat > "$FAKEBIN/id" <<SH
#!/usr/bin/env bash
[ "\$*" = "-un" ] && { printf '%s\n' '$TEST_ACCOUNT'; exit 0; }
exec '$REAL_ID' "\$@"
SH
chmod +x "$FAKEBIN/id"

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
  PATH="$FAKEBIN:$PATH" "$CHECK" --root "$base/repo" --home "$base/home" "$@" 2>&1
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

# --- a marker in a tracked PATH fails even when the content is clean ---------
# A path publishes its own name: anyone listing the tree reads it without
# opening the file, so a clean-content file named after a registered project is
# a leak, not a stated limit. No content scan can see it - git grep matches blob
# contents and git log -G matches patch text, and neither reads a pathname.

base=$(new_case project-name-in-tracked-path)
clone "$base" widget-store
track "$base" docs/widget-store-notes.md 'Nothing private in the text.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a registered project name in a tracked FILENAME must fail"
assert_contains "$out" "TRACKED PATH" "a path hit must be labelled apart from a content hit"
assert_contains "$out" "docs/widget-store-notes.md" "the failure must name the offending path"
pass "a marker in a tracked filename fails even when the file's content is clean"

# --- a marker in a tracked DIRECTORY name fails the same way -----------------

base=$(new_case project-name-in-tracked-directory)
clone "$base" widget-store
track "$base" docs/widget-store/guide.md 'Nothing private in the text.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a registered project name in a tracked DIRECTORY must fail"
assert_contains "$out" "TRACKED PATH" "a directory-name hit must be labelled as a path hit"
assert_contains "$out" "docs/widget-store/guide.md" "the failure must name the path under it"
pass "a marker in a tracked directory name fails, not just a marker in a filename"

# --- a committed path deleted from the working tree is still committed -------
# The working-tree list no longer carries it, exactly as with content, so the
# committed pass is what keeps a dirty checkout from hiding the published name.

base=$(new_case committed-path-not-in-worktree)
clone "$base" widget-store
track "$base" docs/widget-store-notes.md 'Nothing private in the text.'
git -C "$base/repo" rm -q --cached docs/widget-store-notes.md
rm -f "$base/repo/docs/widget-store-notes.md"
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a path removed from the index but still committed must fail"
assert_contains "$out" "COMMITTED PATH" "the committed-only path must be labelled distinctly"
assert_contains "$out" "docs/widget-store-notes.md" "the committed-only hit must name the path"
pass "a marker in a path that is committed but no longer tracked is still caught"

# --- a path tracked at both points is reported once --------------------------
# The COMMITTED PATH label drives the remedy, so it must not fire for a path the
# working-tree list already reported.

base=$(new_case path-both-points)
clone "$base" widget-store
track "$base" docs/widget-store-notes.md 'Nothing private in the text.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "an unchanged tracked path carrying a marker must still fail"
assert_contains "$out" "TRACKED PATH" "the path must be reported at the working-tree point"
assert_not_contains "$out" "COMMITTED PATH" \
  "a path present at both points must not also read as committed-only"
pass "a path tracked in the working tree and at HEAD is reported once, not twice"

# --- a marker inside a longer path component does not fire -------------------
# Paths use the same word-bounded rules as content, so a green run here is not
# bought by loosening the matching only for names.

base=$(new_case path-word-boundary)
printf -- '- sm-thing - Persistent firstmate (added 2026-01-01)\n' > "$base/home/data/secondmates.md"
track "$base" docs/transmthingle.md 'Nothing private in the text.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "a marker embedded in a longer path component must not fire"
pass "path matching is word-bounded, exactly like content matching"

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
# Suppression is the one thing a clean run must never do quietly: an operator
# reading OK cannot tell what the allowlist removed unless the run says so.
assert_contains "$out" 'allowed: "acme-private-org" (config/private-material-allow)' \
  "an allowlisted name must be accounted for by name and by the source that allowed it"
pass "an identity recorded in the allowlist is no longer treated as private, and the drop is reported"

# --- the implicit repo-directory allowance is accounted for too --------------
# A checkout that happens to sit in a directory named after a registered project
# loses that marker, and the only way an operator can know is if the run says so.

base=$(new_case allowlist-repo-directory-name)
clone "$base" "$(basename "$base/repo")"
track "$base" docs/guide.md 'Nothing private here.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" \
  "the repo-directory name is allowed, and the account-name marker still proves the run clean"
assert_contains "$out" "allowed: \"$(basename "$base/repo")\" (this repo's own directory name)" \
  "the implicit repo-directory allowance must be reported, never applied silently"
pass "a derived name dropped as this repo's own directory name is reported, not silent"

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

base=$(new_case account-name)
track "$base" docs/guide.md "Run it from /home/$TEST_ACCOUNT/firstmate to reproduce."
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a machine-local home path must be caught via the account name"
assert_contains "$out" "$TEST_ACCOUNT" "failure must name the account-derived marker"
pass "the local account name is a marker, so a machine-local path in a tracked file fails"

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
assert_not_contains "$out" "NOTICE" \
  "a marker that is not a contributor identity must never be downgraded to a notice"
pass "--history catches a marker in commit metadata that no file-content scan sees"

# --- a contributor's own identity is expected, not a leak --------------------
# The local account name and a forge owner are published by construction the
# moment a pull request carries its own commits, so flagging them would make
# --history permanently red on every branch and train operators to ignore it.
# It must still be SAID, so it is a notice that survives an otherwise clean run.

base=$(new_case contributor-identity)
clone "$base" widget-store
track "$base" docs/guide.md 'Nothing private in the text.'
printf 'more\n' >> "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
GIT_AUTHOR_NAME="$TEST_ACCOUNT" GIT_AUTHOR_EMAIL="$TEST_ACCOUNT@example.invalid" \
GIT_COMMITTER_NAME="$TEST_ACCOUNT" GIT_COMMITTER_EMAIL="$TEST_ACCOUNT@example.invalid" \
  git -C "$base/repo" commit -qm 'ordinary subject'
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 0 "$code" "the contributor's own identity must not fail --history"
assert_contains "$out" "NOTICE" "the identity must still be reported on a clean run"
assert_contains "$out" "$TEST_ACCOUNT" "the notice must name the marker it is standing down on"
assert_not_contains "$out" "PRIVATE MATERIAL" "an expected identity must not read as a finding"
pass "a contributor identity in the author field is a standing notice, not a failure"

# --- the same name in a subject or body is still a hard failure --------------
# Only the identity fields are published by construction; authored text is not,
# so the relaxation must not leak sideways into the message.

base=$(new_case contributor-identity-in-subject)
clone "$base" widget-store
track "$base" docs/guide.md 'Nothing private in the text.'
printf 'more\n' >> "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
GIT_AUTHOR_NAME="$TEST_ACCOUNT" GIT_AUTHOR_EMAIL="$TEST_ACCOUNT@example.invalid" \
GIT_COMMITTER_NAME="$TEST_ACCOUNT" GIT_COMMITTER_EMAIL="$TEST_ACCOUNT@example.invalid" \
  git -C "$base/repo" commit -qm "ran it as $TEST_ACCOUNT"
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 1 "$code" "the same name in a commit subject must still fail"
assert_contains "$out" "subject or body" "the failure must name the surface it was found on"
pass "the identity allowance is scoped to the identity fields and does not cover the message"

# --- a declared marker is never excused as a contributor identity ------------
# Declaring a token is the strongest available statement that it is private, so
# it outranks the identity allowance even when it is also the account name.

base=$(new_case declared-beats-identity)
clone "$base" widget-store
track "$base" docs/guide.md 'Nothing private in the text.'
printf 'more\n' >> "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
printf '%s\n' "$TEST_ACCOUNT" > "$base/home/config/private-material-markers"
GIT_AUTHOR_NAME="$TEST_ACCOUNT" GIT_AUTHOR_EMAIL="$TEST_ACCOUNT@example.invalid" \
GIT_COMMITTER_NAME="$TEST_ACCOUNT" GIT_COMMITTER_EMAIL="$TEST_ACCOUNT@example.invalid" \
  git -C "$base/repo" commit -qm 'ordinary subject'
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 1 "$code" "an operator-declared marker must fail even in an identity field"
assert_contains "$out" "COMMIT METADATA" "the declared marker must be reported as a finding"
pass "an operator-declared token outranks the contributor-identity allowance"

# --- a working-tree line shift does not fake a committed-only hit ------------
# The AT HEAD label drives the remedy - tip fix or committed fix - so it must
# not fire for a hit the working tree already reported at a different line.

base=$(new_case head-dedup-line-shift)
clone "$base" widget-store
track "$base" docs/guide.md 'Deploy the widget-store service.'
printf 'An added first line.\nDeploy the widget-store service.\n' > "$base/repo/docs/guide.md"
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "the marker is still in the working tree, so the run must fail"
assert_contains "$out" "docs/guide.md:2" "the working-tree hit must be reported at its current line"
assert_not_contains "$out" "AT HEAD" \
  "a shifted line number must not re-report a known hit as committed-only"
pass "the committed-hit dedup compares path and content, so a line shift does not mislabel a hit"

# --- this repo's own remote owner is the other half of the allowance ----------
# A pull request from here goes to this repo's own forge owner, so that name is
# on every published commit by construction, exactly like the account name.

base=$(new_case own-remote-owner-identity)
clone "$base" localclone
git -C "$base/repo" remote add origin 'https://github.com/Publish-Target/tool.git'
track "$base" docs/guide.md 'Nothing private in the text.'
printf 'more\n' >> "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
GIT_AUTHOR_NAME='Publish Target' GIT_AUTHOR_EMAIL='bot@publish-target.example' \
GIT_COMMITTER_NAME='Publish Target' GIT_COMMITTER_EMAIL='bot@publish-target.example' \
  git -C "$base/repo" commit -qm 'ordinary subject'
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 0 "$code" "this repo's own forge owner must not fail --history in an identity field"
assert_contains "$out" "NOTICE" "the owner must still be reported on a clean run"
assert_not_contains "$out" "PRIVATE MATERIAL" "an expected identity must not read as a finding"
pass "the forge owner of this repo's own remote is a standing notice in an identity field"

# --- a project clone's forge owner is NOT excused in an identity field -------
# A clone under projects/ is a private repository by definition, so its forge
# owner is a private organisation and the most sensitive name in the marker set.
# Nothing publishes it from here, so it must fail as hard in an author field as
# it does in a tracked file - the allowance covers the publishing target only.

base=$(new_case clone-owner-identity)
clone "$base" localclone
git -C "$base/home/projects/localclone" remote add origin 'https://github.com/Acme-Private-Org/widget.git'
track "$base" docs/guide.md 'Nothing private in the text.'
printf 'more\n' >> "$base/repo/docs/guide.md"
git -C "$base/repo" add docs/guide.md
GIT_AUTHOR_NAME='CI Bot' GIT_AUTHOR_EMAIL='ci@acme-private-org.example' \
GIT_COMMITTER_NAME='CI Bot' GIT_COMMITTER_EMAIL='ci@acme-private-org.example' \
  git -C "$base/repo" commit -qm 'ordinary subject'
out=$(run_check "$base" --history) && code=0 || code=$?
expect_code 1 "$code" "a project clone's forge owner in an author identity must fail"
assert_contains "$out" "COMMIT METADATA" "the clone owner must be reported as a finding"
assert_contains "$out" "acme-private-org" "the failure must name the private organisation"
assert_not_contains "$out" "NOTICE" \
  "a private organisation must never be downgraded to an expected-identity notice"
pass "a project clone's forge owner stays a hard failure in an author or committer field"

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
  # The same `id` shim as every other case: without it the account name is
  # whoever runs the suite, so a host account that is a STOPWORD or shorter than
  # MIN_LEN raises a gap and fails the assertion below for a reason that has
  # nothing to do with the tracked surface.
  out=$(PATH="$FAKEBIN:$PATH" "$CHECK" --root "$ROOT" --home "$FM_HOME" 2>&1) && code=0 || code=$?
  # Exit 0 specifically: 3 would mean the run proved nothing, and accepting it
  # here would report a guard as passing on the strength of a run that did not
  # look. Exit 3 on a real home means the run itself named what it could not
  # cover, and that is the thing to fix, not the assertion.
  expect_code 0 "$code" \
    "firstmate's own tracked surface must be PROVED clean (exit 0); exit 3 means the run proved nothing"$'\n'"$out"
  pass "this repo's tracked surface is free of every marker derived from FM_HOME"

  # The case above is deterministic precisely because the account name is
  # synthetic - which also means it can never match anything. A tracked
  # /home/<real-account>/ path is the exact leak the account-name marker source
  # exists for, so run once WITHOUT the shim to put that name on the surface.
  # The host coupling that the shim removes is real, so it is handled by naming
  # it rather than by accepting a weaker result: if the host account name is
  # filtered out before the scan, this case proved nothing and says so loudly
  # instead of reporting a pass. It either proves clean, or says it could not
  # look; there is no third answer where a run that did not look reads as ok.
  host_acct=$(id -un 2>/dev/null | tr '[:upper:]' '[:lower:]') || host_acct=""
  out=$("$CHECK" --root "$ROOT" --home "$FM_HOME" 2>&1) && code=0 || code=$?
  if [ -z "$host_acct" ]; then
    printf 'skip: the real-account case did NOT run - the host account name could not be read,\n'
    printf '#      so no machine-local home path was scanned. This is NOT a pass.\n'
  elif printf '%s\n' "$out" | grep -qF "derived name \"$host_acct\"" \
    || printf '%s\n' "$out" | grep -qF "allowed: \"$host_acct\""; then
    # Generic, too short, or the same word as this checkout's directory name.
    printf 'skip: the real-account case did NOT run - the host account name is filtered out\n'
    printf '#      before the scan (the run above names which filter), so no machine-local\n'
    printf '#      home path was scanned. This is NOT a pass.\n'
  else
    expect_code 0 "$code" \
      "the tracked surface must be PROVED clean of the real account name (exit 0)"$'\n'"$out"
    pass "this repo's tracked surface carries no machine-local path for the real account"
  fi
else
  # Deliberately not an "ok -" line: a case that never ran must never be
  # counted, read, or parsed as a passing one.
  printf 'skip: the real-surface case did NOT run - no operational home named by FM_HOME\n'
  printf '#      nothing above checked firstmate own tracked surface; run it with\n'
  printf '#      FM_HOME set, or run bin/fm-private-material-check.sh directly.\n'
fi

printf '# all fm-private-material-check tests passed\n'

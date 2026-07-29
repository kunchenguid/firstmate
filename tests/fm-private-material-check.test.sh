#!/usr/bin/env bash
# tests/fm-private-material-check.test.sh - behavior of the private-material gate.
#
# The seam under test is the script's observable contract, not its internals:
# given a repo and a private home, does it exit non-zero and name the offending
# file:line? Every fixture here is synthetic - this file must never carry a real
# project, owner, person, or device name, because the check exists to keep those
# out of the tracked surface and would be self-defeating if it leaked them.
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
mkdir -p "$base/home/projects/widget-store"
track "$base" docs/guide.md 'Deploy the widget-store service nightly.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a registered project name in a tracked file must fail"
assert_contains "$out" "widget-store" "failure must name the marker"
assert_contains "$out" "docs/guide.md:1" "failure must name the offending file and line"
pass "a project clone name appearing in a tracked file fails with its location"

# --- the same repo with no such text passes ---------------------------------

base=$(new_case clean-surface)
mkdir -p "$base/home/projects/widget-store"
track "$base" docs/guide.md 'Deploy the service nightly.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 0 "$code" "a clean tracked surface must pass"
assert_contains "$out" "OK" "a clean run must say so"
pass "a tracked surface free of every marker passes"

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
fm_git_init_commit "$base/home/projects/localclone" >/dev/null
git -C "$base/home/projects/localclone" remote add origin 'https://github.com/Acme-Private-Org/widget.git'
track "$base" docs/guide.md 'See https://github.com/Acme-Private-Org/widget for details.'
out=$(run_check "$base") && code=0 || code=$?
expect_code 1 "$code" "a project clone's remote owner must be a marker"
assert_contains "$out" "acme-private-org" "failure must name the derived owner"
pass "a forge owner is derived from a project clone's remote and caught in tracked files"

# --- the allowlist suppresses a legitimately public identity -----------------

base=$(new_case allowlist)
fm_git_init_commit "$base/home/projects/localclone" >/dev/null
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

# --- the local account name is a marker, so machine-local paths are caught ---
# Derived at runtime here too, so this test hardcodes no real account name.

acct=$(id -un 2>/dev/null || printf '')
acct_lower=$(printf '%s' "$acct" | tr '[:upper:]' '[:lower:]')
generic=" main master api web app core src bin lib doc docs data home user users
admin root dev test tests tmp temp work repo repos git github gitlab build dist
node http https com org net local shared common util utils new old the and for
firstmate treehouse herdr zellij orca cmux tmux claude codex opencode grok kimi
anthropic openai vercel supabase "
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
expect_code 0 "$code" "a run with no marker sources must not fail the build"
assert_contains "$out" "SKIPPED" "a vacuous run must say SKIPPED"
assert_contains "$out" "proves nothing" "a vacuous run must refuse to read as a clean pass"
assert_not_contains "$out" "OK -" "a vacuous run must not report a clean result"
pass "a run with no marker sources reports SKIPPED and disclaims its own result"

# --- --history reaches commits whose tip no longer carries the marker --------
# A marker deleted at tip is still published forever once the repo is public.

base=$(new_case history)
mkdir -p "$base/home/projects/widget-store"
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

# --- --history also reads commit metadata, which travels with a pull request ---
# An author identity is the usual way a real name or an org email domain reaches
# a third-party repo, and no file-content scan would ever see it.

base=$(new_case commit-metadata)
mkdir -p "$base/home/projects/widget-store"
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
mkdir -p "$base/home/projects/widget-store"
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
  expect_code 0 "$code" \
    "firstmate's own tracked surface must carry no private material"$'\n'"$out"
  pass "this repo's tracked surface is free of every marker derived from FM_HOME"
else
  printf '# skip - set FM_HOME to a real operational home to scan this repo for real\n'
  pass "real-surface case skipped: no operational home named by FM_HOME"
fi

printf '# all fm-private-material-check tests passed\n'

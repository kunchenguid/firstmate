#!/usr/bin/env bash
# Regression: tracked .gitignore must ignore .env key backups (.env.bak, .env.bak-*).
#
# lisaa-avain.sh writes .env.bak-* copies that hold API keys. A local
# .git/info/exclude may already hide them in one home; this suite pins the
# shared, versioned .gitignore so a plain `git add -A` cannot stage them
# everywhere. Hermetic: builds a throwaway repo with only ROOT's .gitignore so
# the common-dir exclude cannot mask a missing tracked rule.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GITIGNORE="$ROOT/.gitignore"
TMP=$(fm_test_tmproot gitignore-env-bak)
fm_git_identity fmtest fmtest@example.invalid

assert_gitignore_lists() {
  local pattern=$1
  # Exact pattern line (comment lines are free-form; the rule itself must exist).
  grep -Fxq -- "$pattern" "$GITIGNORE" \
    || fail "tracked .gitignore missing exact pattern: $pattern"
}

# setup_repo_with_tracked_gitignore -> echoes repo path using only ROOT/.gitignore
setup_repo_with_tracked_gitignore() {
  local repo=$1
  mkdir -p "$repo"
  git init -q -b main "$repo"
  # Empty exclude and a neutralized excludes file so only .gitignore can match;
  # a host core.excludesFile (commonly ~/.gitignore with .env*) would otherwise
  # satisfy the assertions even with the tracked rule missing.
  : > "$repo/.git/info/exclude"
  git -C "$repo" config core.excludesFile /dev/null
  cp "$GITIGNORE" "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" commit -q -m 'seed gitignore'
  printf '%s\n' "$repo"
}

assert_ignored_via_gitignore() {
  local repo=$1 path=$2
  local out
  out=$(git -C "$repo" check-ignore -v -- "$path") \
    || fail "expected $path to be ignored (check-ignore exit $?)"
  # Must cite the repo-root .gitignore, not info/exclude, a global excludes
  # file (~/.gitignore would match an unanchored pattern), or another source.
  printf '%s\n' "$out" | grep -Eq '^\.gitignore:' \
    || fail "ignore for $path did not come from .gitignore: $out"
  pass "ignored via .gitignore: $path"
}

assert_not_ignored() {
  local repo=$1 path=$2
  if git -C "$repo" check-ignore -q -- "$path"; then
    fail "did not expect $path to be ignored"
  fi
  pass "not ignored (legitimate path): $path"
}

# --- static: tracked rules present next to .env -----------------------------

assert_gitignore_lists '.env'
assert_gitignore_lists '.env.bak'
assert_gitignore_lists '.env.bak-*'
# Comment should mention why (key backups / secrets out of VCS).
grep -Eiq 'key|secret|avain|varmuuskop' "$GITIGNORE" \
  || fail "tracked .gitignore should briefly document why .env.bak* is ignored"
pass "tracked .gitignore lists .env and .env.bak* rules with a comment"

# --- no intentionally tracked file matches the backup patterns --------------

matched=$(git -C "$ROOT" ls-files | grep -E '(^|/)\.env\.bak(-.*)?$' || true)
[ -z "$matched" ] \
  || fail "tracked file(s) match .env.bak patterns (would be newly untracked only if removed from index): $matched"
pass "no tracked file matches .env.bak / .env.bak-*"

# --- behavioral: check-ignore against a copy of the tracked .gitignore ------

REPO=$(setup_repo_with_tracked_gitignore "$TMP/repo")

# Dummy placeholders only — never real keys.
: > "$REPO/.env.bak-testi"
: > "$REPO/.env.bak"
: > "$REPO/.env.bak-20260724"
: > "$REPO/.env"
: > "$REPO/README.md"
mkdir -p "$REPO/subdir"
: > "$REPO/subdir/.env.bak-nested"

assert_ignored_via_gitignore "$REPO" '.env.bak-testi'
assert_ignored_via_gitignore "$REPO" '.env.bak'
assert_ignored_via_gitignore "$REPO" '.env.bak-20260724'
assert_ignored_via_gitignore "$REPO" '.env'
assert_ignored_via_gitignore "$REPO" 'subdir/.env.bak-nested'
assert_not_ignored "$REPO" 'README.md'
assert_not_ignored "$REPO" '.gitignore'

# Staging must refuse to add the backups without -f (git add exits non-zero).
if git -C "$REPO" add -- '.env.bak-testi' 2>/dev/null; then
  fail "plain git add should not succeed for ignored .env.bak-testi"
fi
staged=$(git -C "$REPO" diff --cached --name-only)
printf '%s\n' "$staged" | grep -qx '.env.bak-testi' \
  && fail "git add staged ignored .env.bak-testi without -f"
pass "plain git add does not stage .env.bak-testi"

# Cleanup is via fm_test_tmproot trap; no secrets ever written.
pass "gitignore-env-bak regression complete"

#!/usr/bin/env bash
# .gitignore must ignore config/ as a directory, not by exact filename.
#
# A name-by-name list silently stops ignoring any new or home-local file under
# config/ (fm-gitignore-config-name-by-name): an unrecognized file there makes
# the working tree read as dirty, which then blocks guarded sync paths that
# refuse to touch a dirty home.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

random_leaf() {
  printf '%s-%s' "$1" "$$-$RANDOM-$RANDOM"
}

test_config_dir_ignored_as_category() {
  local direct nested sample
  direct="$(random_leaf config/unlisted-key)"
  nested="config/$(random_leaf nested-dir)/$(random_leaf deep-file)"
  for sample in "$direct" "$nested" config/some-new-key.admin; do
    git -C "$ROOT" check-ignore -q "$sample" \
      || fail "git does not ignore $sample (config/ must be ignored as a directory)"
  done
  pass "config/ is ignored as a directory, covering unlisted and nested paths"
}

test_unrelated_path_stays_visible() {
  # Control: a path outside config/ must remain visible to Git, so the
  # coverage above is proven by contrast rather than an always-ignoring rule.
  local sibling
  sibling="$(random_leaf not-config)"
  git -C "$ROOT" check-ignore -q "$sibling" \
    && fail "git unexpectedly ignores $sibling (outside config/)"
  pass "an unrelated path outside config/ remains visible to git"
}

test_scratchpad_prefix_is_ignored() {
  local sample
  for sample in scratchpad scratchpad2/file scratchpad-foo scratchpad/tmp; do
    git -C "$ROOT" check-ignore -q "$sample" \
      || fail "git does not ignore $sample (names starting with scratchpad must be ignored)"
  done
  git -C "$ROOT" check-ignore -q not-scratchpad \
    && fail "git unexpectedly ignores not-scratchpad (must not match the scratchpad* prefix)"
  pass "names starting with scratchpad are gitignored"
}

test_scratchpad_prefix_ignores_no_tracked_path() {
  local tracked
  tracked=$(git -C "$ROOT" ls-files | grep -E '(^|/)scratchpad' || true)
  [ -z "$tracked" ] \
    || fail "a currently tracked path would be newly ignored by scratchpad*: $tracked"
  pass "no currently tracked path starts with scratchpad"
}

test_scratchpad2_does_not_dirty_porcelain() {
  # Remote sync uses git status --porcelain. A scratchpad2/ directory must not
  # make a home look dirty once scratchpad* is gitignored.
  local repo status
  repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-scratchpad-ignore.XXXXXX")
  git init -q "$repo"
  cp "$ROOT/.gitignore" "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'seed gitignore'
  mkdir -p "$repo/scratchpad2"
  printf 'notes\n' > "$repo/scratchpad2/notes.txt"
  printf 'loose\n' > "$repo/scratchpad"
  printf 'named\n' > "$repo/scratchpad-foo"
  status=$(git -C "$repo" status --porcelain)
  rm -rf "$repo"
  [ -z "$status" ] || fail "scratchpad* paths still dirty porcelain: $status"
  pass "scratchpad2/ does not make git status --porcelain dirty"
}

test_config_dir_ignored_as_category
test_unrelated_path_stays_visible
test_scratchpad_prefix_is_ignored
test_scratchpad_prefix_ignores_no_tracked_path
test_scratchpad2_does_not_dirty_porcelain

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

test_config_dir_ignored_as_category() {
  local sample
  for sample in config/anything config/nested/dir/file config/some-new-key.admin; do
    git -C "$ROOT" check-ignore -q "$sample" \
      || fail "git does not ignore $sample (config/ must be ignored as a directory)"
  done
  pass "config/ is ignored as a directory, covering unlisted paths"
}

test_config_not_ignored_by_name_by_name_list() {
  # Regression guard: .gitignore must not go back to enumerating config/ entries
  # by exact filename, since that reintroduces the same silent-drift failure.
  grep -qE '^config/[^/]+$' "$ROOT/.gitignore" \
    && fail ".gitignore lists config/ entries by exact filename instead of ignoring the directory"
  pass "no name-by-name config/ entries remain in .gitignore"
}

test_config_dir_ignored_as_category
test_config_not_ignored_by_name_by_name_list

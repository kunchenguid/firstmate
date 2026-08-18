#!/usr/bin/env bash
# Regression coverage for the repository compatibility-pointer invariant used
# by both GitHub and Codebase CI.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$ROOT/bin/fm-repo-compatibility-pointers-check.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  echo "ok - $*"
}

make_repo() {
  local repo=$1
  mkdir -p "$repo/.claude" "$repo/.agents/skills"
  printf '%s\n' \
    '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->' \
    '@AGENTS.md' >"$repo/CLAUDE.md"
  ln -s ../.agents/skills "$repo/.claude/skills"
}

expect_rejected() {
  local repo=$1 expected=$2 out
  out="$repo/check.err"
  if "$CHECK" "$repo" >"$repo/check.out" 2>"$out"; then
    fail "invariant accepted invalid fixture: $expected"
  fi
  grep -F "$expected" "$out" >/dev/null \
    || fail "invariant rejection did not explain $expected: $(cat "$out")"
}

test_canonical_pointers_pass() {
  local repo="$TMP_ROOT/canonical"
  make_repo "$repo"
  "$CHECK" "$repo" || fail "canonical compatibility pointers were rejected"
  pass "canonical real CLAUDE.md pointer and skills symlink pass"
}

test_claude_symlink_is_rejected() {
  local repo="$TMP_ROOT/claude-symlink"
  make_repo "$repo"
  rm "$repo/CLAUDE.md"
  : >"$repo/AGENTS.md"
  ln -s AGENTS.md "$repo/CLAUDE.md"
  expect_rejected "$repo" "CLAUDE.md must be a real @AGENTS.md pointer file, not a symlink"
  pass "legacy CLAUDE.md symlink fails the migrated invariant"
}

test_noncanonical_real_pointer_is_rejected() {
  local repo="$TMP_ROOT/noncanonical"
  make_repo "$repo"
  printf '@AGENTS.md\n' >"$repo/CLAUDE.md"
  expect_rejected "$repo" "CLAUDE.md must be the canonical @AGENTS.md pointer"
  pass "noncanonical real CLAUDE.md pointer is rejected"
}

test_skills_symlink_target_is_preserved() {
  local repo="$TMP_ROOT/wrong-skills-target"
  make_repo "$repo"
  rm "$repo/.claude/skills"
  ln -s ../skills "$repo/.claude/skills"
  expect_rejected "$repo" ".claude/skills must be a symlink to ../.agents/skills"
  pass "wrong skills symlink target remains rejected"
}

test_skills_real_directory_is_rejected() {
  local repo="$TMP_ROOT/real-skills-directory"
  make_repo "$repo"
  rm "$repo/.claude/skills"
  mkdir "$repo/.claude/skills"
  expect_rejected "$repo" ".claude/skills must be a symlink to ../.agents/skills"
  pass "real skills directory cannot replace the required symlink"
}

test_canonical_pointers_pass
test_claude_symlink_is_rejected
test_noncanonical_real_pointer_is_rejected
test_skills_symlink_target_is_preserved
test_skills_real_directory_is_rejected

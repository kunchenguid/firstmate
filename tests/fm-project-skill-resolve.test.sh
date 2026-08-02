#!/usr/bin/env bash
# Behavioral tests for project-local skill discovery through the executable
# resolver interface.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT/bin/fm-project-skill-resolve.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_skill() {
  local path=$1 name=$2
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '---' "name: $name" '---' '' '# Fixture' >"$path"
}

run_resolver() {
  local project=$1 query=$2
  set +e
  OUTPUT=$($RESOLVER "$project" "$query" 2>"$TMP_ROOT/stderr")
  STATUS=$?
  set -e
  ERROR=$(<"$TMP_ROOT/stderr")
}

assert_success_path() {
  local expected=$1 label=$2
  [ "$STATUS" -eq 0 ] || fail "$label: exit $STATUS: $ERROR"
  [ "$OUTPUT" = "$(realpath "$expected")" ] || fail "$label: unexpected output: $OUTPUT"
  pass "$label"
}

test_hidden_agents_root() {
  local project="$TMP_ROOT/hidden-project"
  local skill="$project/.agents/skills/writing-great-skills/SKILL.md"
  make_skill "$skill" writing-great-skills
  run_resolver "$project" writing-great-skills
  assert_success_path "$skill" "discovers a skill under hidden .agents"
}

test_codex_root() {
  local project="$TMP_ROOT/codex-project"
  local skill="$project/.codex/skills/release-notes/SKILL.md"
  make_skill "$skill" release-notes
  run_resolver "$project" release-notes
  assert_success_path "$skill" "discovers a skill under .codex"
}

test_project_skills_root() {
  local project="$TMP_ROOT/public-project"
  local skill="$project/skills/repo-guide/SKILL.md"
  make_skill "$skill" repo-guide
  run_resolver "$project" repo-guide
  assert_success_path "$skill" "discovers a project skills surface"
}

test_slug_normalization_without_partial_match() {
  local project="$TMP_ROOT/normalized-project"
  local skill="$project/.agents/skills/Writing_Great Skills/SKILL.md"
  make_skill "$skill" unrelated-name
  run_resolver "$project" "Writing Great Skills"
  assert_success_path "$skill" "normalizes human names and slugs"

  run_resolver "$project" "Writing Great"
  [ "$STATUS" -eq 1 ] || fail "partial slug match returned exit $STATUS"
  [ -z "$OUTPUT" ] || fail "partial slug match returned a path"
  pass "rejects partial slug matches"
}

test_exact_frontmatter_name() {
  local project="$TMP_ROOT/name-project"
  local skill="$project/.agents/skills/opaque-directory/SKILL.md"
  make_skill "$skill" "writing-great-skills"
  run_resolver "$project" writing-great-skills
  assert_success_path "$skill" "resolves an exact frontmatter name"

  run_resolver "$project" Writing-Great-Skills
  [ "$STATUS" -eq 1 ] || fail "non-exact frontmatter name returned exit $STATUS"
  pass "frontmatter name matching is exact"
}

test_local_scope_excludes_global_homonym() {
  local project="$TMP_ROOT/local-project"
  local local_skill="$project/.agents/skills/writing-great-skills/SKILL.md"
  local global_skill="$TMP_ROOT/global/.agents/skills/writing-great-skills/SKILL.md"
  make_skill "$local_skill" writing-great-skills
  make_skill "$global_skill" writing-great-skills
  run_resolver "$project" writing-great-skills
  assert_success_path "$local_skill" "keeps resolution inside the selected project"
}

test_ambiguity() {
  local project="$TMP_ROOT/ambiguous-project"
  make_skill "$project/.agents/skills/shared/SKILL.md" shared
  make_skill "$project/.codex/skills/shared/SKILL.md" shared
  run_resolver "$project" shared
  [ "$STATUS" -eq 3 ] || fail "ambiguity returned exit $STATUS: $ERROR"
  case "$ERROR" in *"ambiguous project skill"*) ;; *) fail "ambiguity diagnostic missing" ;; esac
  pass "rejects ambiguous local matches"
}

test_absence() {
  local project="$TMP_ROOT/absent-project"
  mkdir -p "$project/.agents/skills"
  run_resolver "$project" missing-skill
  [ "$STATUS" -eq 1 ] || fail "absence returned exit $STATUS: $ERROR"
  case "$ERROR" in *"absent project skill"*) ;; *) fail "absence diagnostic missing" ;; esac
  pass "reports absence with a non-zero exit"
}

test_unsafe_symlink() {
  local project="$TMP_ROOT/unsafe-project"
  local outside="$TMP_ROOT/outside/escape"
  make_skill "$outside/SKILL.md" escape
  mkdir -p "$project/.agents/skills"
  ln -s "$outside" "$project/.agents/skills/escape"
  run_resolver "$project" escape
  [ "$STATUS" -eq 4 ] || fail "unsafe symlink returned exit $STATUS: $ERROR"
  [ -z "$OUTPUT" ] || fail "unsafe symlink returned a path"
  case "$ERROR" in *"unsafe matching symlink candidate"*) ;; *) fail "unsafe path diagnostic missing" ;; esac
  pass "refuses a matching skill symlink outside the project"
}

test_help() {
  "$RESOLVER" --help >/dev/null || fail "--help failed"
  pass "help is available from the executable interface"
}

test_hidden_agents_root
test_codex_root
test_project_skills_root
test_slug_normalization_without_partial_match
test_exact_frontmatter_name
test_local_scope_excludes_global_homonym
test_ambiguity
test_absence
test_unsafe_symlink
test_help

#!/usr/bin/env bash
# Resolution, bootstrap, inheritance, brief, and meta tests for crew-skills.json.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVER="$ROOT/bin/fm-crew-skills.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-skills)

make_skill() {
  local root=$1 name=$2
  mkdir -p "$root/$name"
  printf '# %s\n' "$name" > "$root/$name/SKILL.md"
}

run_resolve() {
  local home=$1 skills=$2
  shift 2
  FM_HOME="$home" FM_USER_SKILLS_DIR="$skills" FM_REPO_SKILLS_DIR="$home/repo-skills" \
    "$RESOLVER" resolve "$@"
}

test_resolution_precedence_and_absence() {
  local home="$TMP_ROOT/resolution/home" skills="$TMP_ROOT/resolution/user" out
  mkdir -p "$home/config" "$home/repo-skills"
  make_skill "$skills" fleet-plan
  make_skill "$skills" fleet-review
  make_skill "$skills" project-review
  make_skill "$skills" explicit-review
  printf '%s\n' '{"phases":{"plan":{"skill":"fleet-plan"},"review":{"skill":"fleet-review"}},"projects":{"alpha":{"review":{"skill":"project-review"}}}}' > "$home/config/crew-skills.json"

  out=$(run_resolve "$home" "$skills" plan alpha)
  [ "$out" = fleet-plan ] || fail "fleet plan default did not resolve: $out"
  out=$(run_resolve "$home" "$skills" review alpha)
  [ "$out" = project-review ] || fail "project review override did not resolve: $out"
  out=$(run_resolve "$home" "$skills" review beta)
  [ "$out" = fleet-review ] || fail "project override leaked into another project: $out"
  out=$(run_resolve "$home" "$skills" review alpha --explicit explicit-review)
  [ "$out" = explicit-review ] || fail "explicit review did not win: $out"
  rm "$home/config/crew-skills.json"
  out=$(run_resolve "$home" "$skills" review alpha)
  [ -z "$out" ] || fail "absent config should resolve no added skill: $out"
  pass "crew skills resolve explicit, project, fleet, and absent behavior in order"
}

test_validation_fails_loudly() {
  local home="$TMP_ROOT/validation/home" skills="$TMP_ROOT/validation/user" out rc
  mkdir -p "$home/config" "$home/repo-skills" "$skills"
  printf '%s\n' '{"phases":{"review":{"skill":"missing-review"}}}' > "$home/config/crew-skills.json"
  out=$(FM_HOME="$home" FM_USER_SKILLS_DIR="$skills" FM_REPO_SKILLS_DIR="$home/repo-skills" "$RESOLVER" validate 2>&1); rc=$?
  expect_code 1 "$rc" "unknown configured skill should fail validation"
  [ "$out" = 'unknown skill: missing-review' ] || fail "unknown-skill error drifted: $out"
  printf '%s\n' '{"phases":{"implement":{"skill":"missing-review"}}}' > "$home/config/crew-skills.json"
  out=$(FM_HOME="$home" FM_USER_SKILLS_DIR="$skills" FM_REPO_SKILLS_DIR="$home/repo-skills" "$RESOLVER" validate 2>&1); rc=$?
  expect_code 1 "$rc" "unsupported phase should fail validation"
  [ "$out" = 'unknown phase: implement' ] || fail "unknown-phase error drifted: $out"
  pass "crew skills reject unknown skills and phases loudly"
}

test_inheritance_allowlist_contains_crew_skills() {
  local src="$TMP_ROOT/inherit/source" dest="$TMP_ROOT/inherit/destination"
  unset FM_INHERITABLE_CONFIG
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  mkdir -p "$src" "$dest"
  printf '%s\n' '{"phases":{"review":{"skill":"review-skill"}}}' > "$src/crew-skills.json"
  propagate_inheritable_config "$src" "$dest" \
    || fail "crew-skills inheritance copy failed"
  cmp -s "$src/crew-skills.json" "$dest/crew-skills.json" \
    || fail "secondmate did not inherit crew-skills bytes"
  rm "$src/crew-skills.json"
  propagate_inheritable_config "$src" "$dest" \
    || fail "crew-skills inheritance absence mirror failed"
  assert_absent "$dest/crew-skills.json" "primary absence did not remove inherited crew-skills"
  pass "crew skills copy and absence-mirror into secondmate homes"
}

test_brief_records_additive_phase_contracts() {
  local home="$TMP_ROOT/brief/home" skills="$TMP_ROOT/brief/user"
  mkdir -p "$home/config" "$home/state"
  make_skill "$skills" plan-skill
  make_skill "$skills" review-skill
  printf '%s\n' '{"phases":{"plan":{"skill":"plan-skill"},"review":{"skill":"review-skill"}}}' > "$home/config/crew-skills.json"
  FM_HOME="$home" FM_USER_SKILLS_DIR="$skills" "$ROOT/bin/fm-brief.sh" scout alpha --scout >/dev/null
  FM_HOME="$home" FM_USER_SKILLS_DIR="$skills" "$ROOT/bin/fm-brief.sh" ship alpha --mode no-mistakes >/dev/null
  assert_grep 'Workflow skill: phase=plan skill=plan-skill' "$home/data/scout/brief.md" "scout brief lacks resolved plan skill"
  assert_grep 'Workflow skill: phase=review skill=review-skill' "$home/data/ship/brief.md" "ship brief lacks resolved review skill"
  assert_grep 'invoke the configured review skill' "$home/data/ship/brief.md" "review gate was not recorded"
  assert_grep 'instruct you to run /no-mistakes' "$home/data/ship/brief.md" "review did not stay additive to No Mistakes"
  pass "briefs record plan and additive review phase contracts"
}

test_resolution_precedence_and_absence
test_validation_fails_loudly
test_inheritance_allowlist_contains_crew_skills
test_brief_records_additive_phase_contracts

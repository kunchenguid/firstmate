#!/usr/bin/env bash
# Tests for bin/fm-epic-lint.sh: the single executable owner of the epic/story
# contract, run as the epic-review gate and by fm-umbrella-promote.sh validate.
#
# A table of good/bad cases proves the lint is GREEN on a standard epic and RED
# (exit 1, naming the exact problem) on each contract violation - the seven story
# keys, lower-kebab unique ids that match their filenames, matching epic slug,
# registered repos, valid pr_base, exactly one gate story, acyclic depends, and a
# resolving plan pointer - including the real incident case (uppercase id +
# story:/phase: keys + id-vs-filename mismatch) that this story exists to catch.
#
# The optional `delivery:` key (epflow-07) is covered too: absent = no finding,
# a valid mode passes, an unknown value is RED, and a direct-PR story on a
# no-mistakes-prod-only repo WARNS (stderr) without failing the lint.
#
# One story = one repo (epflow-08) is covered last: a body naming a SECOND
# registered repo WARNS on a bare mention and FAILS when the mention shares a
# line with a deliverable verb, detection is word-bounded (no substring hits),
# and FM_EPIC_LINT_MULTIREPO tunes strictness (off / warn / strict / default).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-epic-lint.sh"
TMP_ROOT=$(fm_test_tmproot fm-epic-lint)

# A shared registry that registers `svc` (and nothing else).
REG="$TMP_ROOT/projects.md"
mkdir -p "$TMP_ROOT"
cat > "$REG" <<'EOF'
# Projects
- svc [direct-PR production=main] - fixture repo (added 260101)
EOF

lint() {  # <epic-dir> -> sets OUT, RC
  OUT=$(FM_PROJECTS_REG="$REG" "$LINT" "$1" 2>&1)
  RC=$?
}

# write_story <dir> <id> <epic> <repo> <pr_base> <depends> <kind> <gate> :
# a story file with full control over every field, for building bad cases.
write_story() {
  local dir=$1 id=$2 epic=$3 repo=$4 pr_base=$5 depends=$6 kind=$7 gate=$8
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    printf 'epic: %s\n' "$epic"
    printf 'repo: %s\n' "$repo"
    printf 'pr_base: %s\n' "$pr_base"
    printf 'depends: %s\n' "$depends"
    printf 'kind: %s\n' "$kind"
    printf 'gate: %s\n' "$gate"
    printf -- '---\n'
    printf '# Story %s heading\n' "$id"
  } > "$dir/$id.md"
}

# fresh <name> : a NEW, standard, valid epic dir (epic `things`, repo `svc`,
# stories svc-01 (the gate) / svc-02 / svc-03). Echoes the epic dir path so a
# caller can mutate exactly one thing before linting.
fresh() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/stories"
  cat > "$dir/epic.md" <<'EOF'
---
epic: things
title: Things epic
repos: [svc]
---
# Epic things
EOF
  write_story "$dir/stories" svc-01 things svc main '[]'         ship true
  write_story "$dir/stories" svc-02 things svc epic/things '[]'  ship false
  write_story "$dir/stories" svc-03 things svc main '[svc-01]'   ship false
  printf '%s\n' "$dir"
}

# expect_red <epic-dir> <substring> <label> : lint must exit 1 and name it.
expect_red() {
  lint "$1"
  expect_code 1 "$RC" "$3: expected the lint to fail"
  assert_contains "$OUT" "$2" "$3"
}

# --- GREEN: a standard epic passes -------------------------------------------
test_green_standard_epic() {
  local d; d=$(fresh green)
  lint "$d"
  expect_code 0 "$RC" "standard epic should pass: $OUT"
  assert_contains "$OUT" "epic lint OK" "did not confirm the epic is valid"
  pass "a standard, contract-correct epic is GREEN"
}

# --- GREEN: a resolvable plan pointer passes; a templated one is skipped ------
test_green_plan_pointers() {
  local d; d=$(fresh greenptr)
  # svc-02 gets a CONCRETE pointer to a plan dir that EXISTS under the epic.
  mkdir -p "$d/stories/svc-02-plan"
  cat >> "$d/stories/svc-02.md" <<'EOF'

## Implementation plan
_Pointer: `stories/svc-02-plan/`._
EOF
  # svc-03 keeps a still-templated pointer (contains ...), which is not-yet-planned.
  cat >> "$d/stories/svc-03.md" <<'EOF'

## Implementation plan
_Pointer placeholder (filled at task-time by the worker under plan-review): `plans/things/stories/svc-03-.../`._
EOF
  lint "$d"
  expect_code 0 "$RC" "resolvable + templated pointers should pass: $OUT"
  pass "a resolvable plan pointer passes and a templated (...) pointer is skipped"
}

# --- GREEN: story fmops-07 §3 - a scaffolded, NOT-yet-planned epic stays green.
# With /epic-plan dropped, the scaffold leaves each story's Implementation plan
# section a pointer placeholder (or absent); the lint must pass so a scaffolded
# epic reaches /epic-review and sign-off with no upfront plan.
test_green_scaffolded_not_yet_planned() {
  local d; d=$(fresh notplanned)
  # svc-02: a templated pointer placeholder exactly as the scaffold leaves it.
  cat >> "$d/stories/svc-02.md" <<'EOF'

## Implementation plan
_Filled at task-time by the dispatched worker under firstmate's plan-review gate: `.../`._
EOF
  # svc-03: no Implementation plan section at all (also not-yet-planned).
  lint "$d"
  expect_code 0 "$RC" "a scaffolded not-yet-planned epic must be lint-green: $OUT"
  pass "a scaffolded not-yet-planned epic is lint-green (no upfront /epic-plan step)"
}

# --- RED: the real incident case (uppercase id + story:/phase: + mismatch) ----
test_red_incident_case() {
  local d; d=$(fresh incident)
  # Replace svc-02 with an out-of-pipeline story exactly like the aimica LH-01.
  rm -f "$d/stories/svc-02.md"
  cat > "$d/stories/LH-01.md" <<'EOF'
---
story: LH-01
phase: 1
epic: things
repo: svc
pr_base: main
depends: []
kind: ship
gate: false
---
# Story LH-01
EOF
  lint "$d"
  expect_code 1 "$RC" "the incident-shaped story must fail"
  assert_contains "$OUT" 'unexpected frontmatter key "story:"' "did not reject the story: key"
  assert_contains "$OUT" 'unexpected frontmatter key "phase:"' "did not reject the phase: key"
  assert_contains "$OUT" 'missing frontmatter key "id:"' "did not flag the missing id"
  pass "the real incident case (story:/phase: keys, no id) is RED with exact reasons"
}

# --- RED: each single contract violation --------------------------------------
test_red_uppercase_id() {
  local d; d=$(fresh upper)
  rm -f "$d/stories/svc-02.md"
  # Filename == id so ONLY the lower-kebab rule fires.
  write_story "$d/stories" SVC-02 things svc main '[]' ship false
  expect_red "$d" "is not lower-kebab" "uppercase id not rejected"
  pass "an uppercase id is RED (not lower-kebab)"
}

test_red_id_filename_mismatch() {
  local d; d=$(fresh mismatch)
  # File svc-02.md but id svc-99 (both lower-kebab): pure filename mismatch.
  rm -f "$d/stories/svc-02.md"
  write_story "$d/stories" svc-02 things svc main '[]' ship false
  perl -i -pe 's/^id: svc-02$/id: svc-99/' "$d/stories/svc-02.md"
  expect_red "$d" "does not match its filename" "id-vs-filename mismatch not rejected"
  pass "an id that differs from its filename is RED"
}

test_red_duplicate_id() {
  local d; d=$(fresh dup)
  # A second file whose id collides with svc-03.
  write_story "$d/stories" svc-03-copy things svc main '[]' ship false
  perl -i -pe 's/^id: svc-03-copy$/id: svc-03/' "$d/stories/svc-03-copy.md"
  expect_red "$d" "duplicate story id" "duplicate id not rejected"
  pass "a duplicate story id is RED"
}

test_red_epic_mismatch() {
  local d; d=$(fresh epicmm)
  perl -i -pe 's/^epic: things$/epic: other-epic/' "$d/stories/svc-02.md"
  expect_red "$d" "does not match epic.md" "epic mismatch not rejected"
  pass "a story epic: that does not match epic.md is RED"
}

test_red_bad_pr_base() {
  local d; d=$(fresh badpr)
  perl -i -pe 's{^pr_base: main$}{pr_base: bad~~name}' "$d/stories/svc-03.md"
  expect_red "$d" "is not a valid branch name" "bad pr_base not rejected"
  pass "an invalid pr_base branch name is RED"
}

test_red_unregistered_repo() {
  local d; d=$(fresh badrepo)
  perl -i -pe 's/^repo: svc$/repo: ghost-repo/' "$d/stories/svc-02.md"
  expect_red "$d" "is not registered in this home" "unregistered repo not rejected"
  assert_contains "$OUT" "ghost-repo" "did not name the unregistered repo"
  pass "a story repo not registered in the home is RED"
}

test_red_epic_unregistered_repo() {
  local d; d=$(fresh badepicrepo)
  perl -i -pe 's/^repos: \[svc\]$/repos: [svc, ghost-repo]/' "$d/epic.md"
  expect_red "$d" "epic.md: repo \"ghost-repo\" is not registered" "epic repos registration not checked"
  pass "an unregistered repo in epic.md repos: is RED"
}

test_red_missing_key() {
  local d; d=$(fresh nokey)
  # Drop the gate: line from svc-02.
  perl -i -ne 'print unless /^gate: false$/' "$d/stories/svc-02.md"
  expect_red "$d" 'missing frontmatter key "gate:"' "missing key not rejected"
  pass "a story missing one of the seven keys is RED"
}

test_red_bad_kind() {
  local d; d=$(fresh badkind)
  perl -i -pe 's/^kind: ship$/kind: frobnicate/' "$d/stories/svc-02.md"
  expect_red "$d" "must be ship or scout" "bad kind not rejected"
  pass "a kind that is not ship or scout is RED"
}

test_red_zero_gate() {
  local d; d=$(fresh zerogate)
  perl -i -pe 's/^gate: true$/gate: false/' "$d/stories/svc-01.md"
  expect_red "$d" "0 stories with gate: true" "zero-gate not rejected"
  pass "an epic with no gate story is RED"
}

test_red_many_gate() {
  local d; d=$(fresh manygate)
  perl -i -pe 's/^gate: false$/gate: true/' "$d/stories/svc-02.md"
  expect_red "$d" "2 stories with gate: true" "many-gate not rejected"
  pass "an epic with more than one gate story is RED"
}

test_red_depends_unknown() {
  local d; d=$(fresh depunknown)
  perl -i -pe 's/^depends: \[\]$/depends: [nope-99]/' "$d/stories/svc-02.md"
  expect_red "$d" 'names no story in this epic' "unknown depends id not rejected"
  pass "a depends id that names no story is RED"
}

test_red_depends_cycle() {
  local d; d=$(fresh depcycle)
  # svc-02 -> svc-03 and svc-03 -> svc-02 : a 2-cycle.
  perl -i -pe 's/^depends: \[\]$/depends: [svc-03]/' "$d/stories/svc-02.md"
  perl -i -pe 's/^depends: \[svc-01\]$/depends: [svc-02]/' "$d/stories/svc-03.md"
  expect_red "$d" "dependency cycle" "dependency cycle not rejected"
  pass "a dependency cycle among stories is RED"
}

test_red_unresolvable_pointer() {
  local d; d=$(fresh badptr)
  # A CONCRETE (non-templated) pointer to a plan dir that does not exist.
  cat >> "$d/stories/svc-02.md" <<'EOF'

## Implementation plan
_Pointer: `stories/svc-02-plan/`._
EOF
  expect_red "$d" "does not resolve" "unresolvable plan pointer not rejected"
  pass "a concrete plan pointer that resolves nowhere is RED"
}

test_red_missing_epic_slug() {
  local d; d=$(fresh noepic)
  perl -i -ne 'print unless /^epic: things$/' "$d/epic.md"
  expect_red "$d" "missing epic: slug" "missing epic slug not rejected"
  pass "an epic.md with no epic: slug is RED"
}

# --- delivery: OPTIONAL key (epflow-07) --------------------------------------
# A separate registry+data dir so the posture warning resolves through
# fm-project-mode.sh against the SAME registry the lint reads (FM_DATA_OVERRIDE,
# not FM_PROJECTS_REG, so both agree). `svc` is direct-PR, `prod` is prod-only.
DEL_DATA="$TMP_ROOT/deldata"
mkdir -p "$DEL_DATA"
cat > "$DEL_DATA/projects.md" <<'EOF'
# Projects
- svc [direct-PR production=main] - fixture repo (added 260101)
- prod [no-mistakes-prod-only production=main] - prod-only fixture (added 260101)
EOF

# add_delivery <story-file> <value> : append a `delivery:` key to a story.
add_delivery() { perl -i -pe "s/^(gate: .*)\$/\$1\ndelivery: $2/" "$1"; }

# lint_data <epic-dir> -> OUT, RC : lint reading the delivery-fixture data dir.
lint_data() { OUT=$(FM_DATA_OVERRIDE="$DEL_DATA" "$LINT" "$1" 2>&1); RC=$?; }

# --- GREEN: absence changes nothing (backward compatible) --------------------
test_green_delivery_absent() {
  local d; d=$(fresh delabsent)
  lint_data "$d"
  expect_code 0 "$RC" "no delivery key should still pass: $OUT"
  assert_not_contains "$OUT" "delivery" "an absent delivery key must produce no finding"
  pass "a story with no delivery: key is GREEN and unmentioned (backward compatible)"
}

# --- GREEN: a valid delivery mode passes -------------------------------------
test_green_delivery_valid() {
  local d; d=$(fresh delvalid)
  add_delivery "$d/stories/svc-02.md" no-mistakes
  add_delivery "$d/stories/svc-03.md" local-only
  lint_data "$d"
  expect_code 0 "$RC" "valid delivery modes should pass: $OUT"
  assert_contains "$OUT" "epic lint OK" "a valid delivery: key must not fail the lint"
  pass "a story carrying a valid delivery: mode is GREEN"
}

# --- GREEN + WARN: direct-PR on a prod-only repo warns but does not fail ------
test_warn_delivery_posture_conflict() {
  local d; d=$(fresh delposture)
  # Point svc-02 at the prod-only repo and mark it direct-PR.
  perl -i -pe 's/^repo: svc$/repo: prod/' "$d/stories/svc-02.md"
  add_delivery "$d/stories/svc-02.md" direct-PR
  lint_data "$d"
  expect_code 0 "$RC" "a posture conflict must WARN, not fail: $OUT"
  assert_contains "$OUT" "WARNINGS" "the posture conflict must surface as a warning"
  assert_contains "$OUT" "no-mistakes-prod-only" "the warning must name the conflicting posture"
  assert_contains "$OUT" "epic lint OK" "the epic must still pass despite the warning"
  pass "delivery: direct-PR on a no-mistakes-prod-only repo WARNS without failing"
}

# --- GREEN: direct-PR on a non-prod-only repo is silent ----------------------
test_green_delivery_directpr_ok() {
  local d; d=$(fresh deldirect)
  add_delivery "$d/stories/svc-02.md" direct-PR   # svc is registered direct-PR
  lint_data "$d"
  expect_code 0 "$RC" "direct-PR on a matching repo should pass silently: $OUT"
  assert_not_contains "$OUT" "WARNINGS" "no warning when the repo is not prod-only"
  pass "delivery: direct-PR on a non-prod-only repo is GREEN and silent"
}

# --- RED: an unknown delivery value is a hard contract error ------------------
test_red_delivery_unknown() {
  local d; d=$(fresh delbad)
  add_delivery "$d/stories/svc-02.md" yolo-ship
  lint_data "$d"
  expect_code 1 "$RC" "an unknown delivery mode must fail"
  assert_contains "$OUT" "must be no-mistakes, direct-PR, or local-only" "did not reject the unknown delivery value"
  pass "an unknown delivery: value is RED"
}

# --- one story = one repo (epflow-08) ----------------------------------------
# A registry that registers a SECOND repo (webapp) so the body scan has another
# repo to find; `svc` stays each story's own repo. Detection: a body naming a
# registered repo other than its own `repo:` WARNS on a bare mention and FAILS
# when the mention shares a line with a deliverable verb (it assigns work there).
MREG="$TMP_ROOT/mrepo-projects.md"
cat > "$MREG" <<'EOF'
# Projects
- svc [direct-PR production=main] - fixture repo (added 260101)
- webapp [no-mistakes production=main] - second fixture repo (added 260101)
EOF

# lint_mrepo <epic-dir> -> OUT, RC : lint with the two-repo registry.
lint_mrepo() { OUT=$(FM_PROJECTS_REG="$MREG" "$LINT" "$1" 2>&1); RC=$?; }

# append_body <story-file> <text> : add a body line to a story.
append_body() { printf '\n%s\n' "$2" >> "$1"; }

test_green_single_repo_clean() {
  local d; d=$(fresh mrclean)
  # Mentions ONLY its own repo (svc) with a deliverable verb: no second repo.
  append_body "$d/stories/svc-02.md" "This story only touches svc and adds a handler."
  lint_mrepo "$d"
  expect_code 0 "$RC" "a single-repo story must pass: $OUT"
  assert_not_contains "$OUT" "second repo" "a story naming only its own repo must not flag"
  assert_not_contains "$OUT" "webapp" "no cross-repo finding for a single-repo story"
  pass "a clean single-repo story (own repo only) passes"
}

test_warn_benign_cross_repo_mention() {
  local d; d=$(fresh mrwarn)
  # svc-02 (repo svc) names webapp with NO deliverable verb: a benign reference.
  append_body "$d/stories/svc-02.md" "Context: this consumes a flag that webapp exposes."
  lint_mrepo "$d"
  expect_code 0 "$RC" "a benign cross-repo mention must WARN, not fail: $OUT"
  assert_contains "$OUT" "WARNINGS" "the benign mention must surface as a warning"
  assert_contains "$OUT" "webapp" "the warning must name the extra repo"
  assert_contains "$OUT" "epic lint OK" "a benign mention must still pass"
  pass "a benign cross-repo mention WARNS without failing"
}

test_red_deliverable_second_repo() {
  local d; d=$(fresh mrfail)
  # The canonical smuggle: svc-02 (repo svc) assigns work to webapp on one line.
  append_body "$d/stories/svc-02.md" "Also touches webapp: update the client to read the new flag."
  lint_mrepo "$d"
  expect_code 1 "$RC" "a story assigning work to a second repo must FAIL"
  assert_contains "$OUT" "second repo" "did not flag the second-repo deliverable"
  assert_contains "$OUT" "webapp" "did not name the smuggled repo"
  pass "a story assigning deliverables to a second repo is RED (split it)"
}

test_green_multirepo_word_boundary() {
  local d; d=$(fresh mrboundary)
  # `webapp` as a substring of a longer word must NOT trigger, even next to a verb.
  append_body "$d/stories/svc-02.md" "The change updates the webapplication-agnostic layer."
  lint_mrepo "$d"
  expect_code 0 "$RC" "a substring match must not fire: $OUT"
  assert_not_contains "$OUT" "webapp\"" "webapplication must not match the webapp repo"
  pass "repo detection is word-bounded (no substring false positives)"
}

test_off_disables_multirepo() {
  local d; d=$(fresh mroff)
  append_body "$d/stories/svc-02.md" "Also touches webapp: update the client."
  OUT=$(FM_PROJECTS_REG="$MREG" FM_EPIC_LINT_MULTIREPO=off "$LINT" "$d" 2>&1); RC=$?
  expect_code 0 "$RC" "off must disable the check: $OUT"
  assert_not_contains "$OUT" "webapp" "off must produce no cross-repo finding"
  pass "FM_EPIC_LINT_MULTIREPO=off disables the cross-repo check"
}

test_strict_fails_bare_mention() {
  local d; d=$(fresh mrstrict)
  append_body "$d/stories/svc-02.md" "See webapp for the existing pattern."
  OUT=$(FM_PROJECTS_REG="$MREG" FM_EPIC_LINT_MULTIREPO=strict "$LINT" "$d" 2>&1); RC=$?
  expect_code 1 "$RC" "strict must fail even a bare mention"
  assert_contains "$OUT" "second repo" "strict did not upgrade the bare mention to a fail"
  pass "FM_EPIC_LINT_MULTIREPO=strict fails on any cross-repo mention"
}

test_warn_mode_downgrades_deliverable() {
  local d; d=$(fresh mrwarnmode)
  append_body "$d/stories/svc-02.md" "Also touches webapp: update the client."
  OUT=$(FM_PROJECTS_REG="$MREG" FM_EPIC_LINT_MULTIREPO=warn "$LINT" "$d" 2>&1); RC=$?
  expect_code 0 "$RC" "warn mode must never fail: $OUT"
  assert_contains "$OUT" "WARNINGS" "warn mode must still surface the finding"
  assert_contains "$OUT" "epic lint OK" "warn mode must pass"
  pass "FM_EPIC_LINT_MULTIREPO=warn downgrades a deliverable mention to a warning"
}

# --- structural: bad usage exits 2 -------------------------------------------
test_structural_errors() {
  lint "$TMP_ROOT/does-not-exist"
  expect_code 2 "$RC" "a missing epic dir should be a usage error"
  assert_contains "$OUT" "no such epic dir" "wrong message for a missing dir"

  local d; d=$(fresh nostories)
  rm -rf "$d/stories"
  lint "$d"
  expect_code 2 "$RC" "a missing stories/ dir should be a structural error"
  assert_contains "$OUT" "no stories/ dir" "wrong message for a missing stories dir"
  pass "bad usage and structural errors exit 2 with a clear message"
}

test_green_standard_epic
test_green_plan_pointers
test_green_scaffolded_not_yet_planned
test_red_incident_case
test_red_uppercase_id
test_red_id_filename_mismatch
test_red_duplicate_id
test_red_epic_mismatch
test_red_bad_pr_base
test_red_unregistered_repo
test_red_epic_unregistered_repo
test_red_missing_key
test_red_bad_kind
test_red_zero_gate
test_red_many_gate
test_red_depends_unknown
test_red_depends_cycle
test_red_unresolvable_pointer
test_red_missing_epic_slug
test_green_delivery_absent
test_green_delivery_valid
test_warn_delivery_posture_conflict
test_green_delivery_directpr_ok
test_red_delivery_unknown
test_green_single_repo_clean
test_warn_benign_cross_repo_mention
test_red_deliverable_second_repo
test_green_multirepo_word_boundary
test_off_disables_multirepo
test_strict_fails_bare_mention
test_warn_mode_downgrades_deliverable
test_structural_errors

echo "# all fm-epic-lint tests passed"

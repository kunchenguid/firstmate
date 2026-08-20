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
_Pointer (filled by /epic-plan): `plans/things/stories/svc-03-.../`._
EOF
  lint "$d"
  expect_code 0 "$RC" "resolvable + templated pointers should pass: $OUT"
  pass "a resolvable plan pointer passes and a templated (...) pointer is skipped"
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
test_structural_errors

echo "# all fm-epic-lint tests passed"

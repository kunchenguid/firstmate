#!/usr/bin/env bash
# Behavioral regressions for fm-verification-skill-check.sh, the executable
# shape contract behind the verification-skill generator skill.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-verification-skill-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-verification-skill-check)

make_good_skill() {
  local dir=$1
  mkdir -p "$dir/features"
  cat >"$dir/SKILL.md" <<'EOF'
---
name: verify-timetracker
description: >-
  Drive the timetracker CLI the way a user would and capture behavioral proof.
  Use when a task changes timetracker behavior and the delivery gate needs evidence.
---

# verify-timetracker

## Launch

Run `./build.sh` once, then `bin/timetracker --data-dir "$RUN_DIR/data" start`.
Ready when the startup line `listening on 127.0.0.1:8437` appears.
Teardown: `bin/timetracker --data-dir "$RUN_DIR/data" stop`.

## Doctor

`bin/timetracker --data-dir "$RUN_DIR/data" status` must print the build
revision and the data directory. Run it first whenever anything looks off.

## Drive

Start a timer: `bin/timetracker start "Writing report"`.
Stop it: `bin/timetracker stop`.
List entries: `bin/timetracker list --format json`.

## Evidence

Exercise the real user path: capture the command, stdout, stderr, and exit
code, then re-read the stored entry with `bin/timetracker show <id>`.
Store artifacts under "$RUN_DIR/artifacts/".

## Cleanup

Stop the instance you started and remove "$RUN_DIR/scratch".
Never kill by process name; kill what you started.
Evidence under "$RUN_DIR/artifacts/" survives cleanup.

## Helpers

`bin/timetracker` ships in the repo; every recipe above shows its invocation.
EOF
  cat >"$dir/features/README.md" <<'EOF'
# Timetracker verification map

Read the index, then the matching feature file as the recipe.

- [Track time](track-time.md)
EOF
  cat >"$dir/features/track-time.md" <<'EOF'
# Track time

## Sub-features

- `start` opens a timer.
- `stop` closes it.

## How to get to it (user POV)

- Run `bin/timetracker start "Task name"` in a terminal.

## Driving it with shell

Preconditions: the instance is healthy per the doctor.

- **Start.** Run `bin/timetracker start "Task name"`. Exit code 0.
- **Proof.** `bin/timetracker list --format json` shows the entry.

## Gotchas

- A stopped instance prints an empty list, not an error.
EOF
}

run_check() {
  "$CHECK" "$1" 2>&1
}

test_accepts_well_shaped_skill() {
  local dir out code
  dir="$TMP_ROOT/good/verify-timetracker"
  make_good_skill "$dir"
  out=$(run_check "$dir") && code=0 || code=$?
  expect_code 0 "$code" "well-shaped generated skill passes the shape check"
  assert_contains "$out" "ok:" "passing output names the validated directory"
}

test_accepts_skill_without_helpers() {
  local dir out code
  dir="$TMP_ROOT/no-helpers/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/^## Helpers$/,$d' "$dir/SKILL.md"
  out=$(run_check "$dir") && code=0 || code=$?
  expect_code 0 "$code" "generated skill without helpers passes the shape check"
}

test_rejects_missing_sections() {
  local dir out
  dir="$TMP_ROOT/no-evidence/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/^## Evidence$/,/^## Cleanup$/ { /^## Cleanup$/!d; }' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "missing Evidence section must fail" || true
  assert_contains "$out" "'## Evidence'" "missing-section failure names the section"
}

test_rejects_unclosed_frontmatter() {
  local dir out
  dir="$TMP_ROOT/unclosed-frontmatter/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/^description: >-$/,/^---$/ { /^---$/d; }' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "unclosed frontmatter must fail" || true
  assert_contains "$out" "opening and closing YAML frontmatter delimiters" "failure names malformed frontmatter"
}

test_rejects_missing_description() {
  local dir out
  dir="$TMP_ROOT/missing-description/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/^description: >-$/,+2d' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "missing frontmatter description must fail" || true
  assert_contains "$out" "description is missing or invalid" "failure names the missing description"
}

test_accepts_supported_description_forms() {
  local dir form out code
  for form in plain literal double-quoted single-quoted; do
    dir="$TMP_ROOT/description-$form/verify-timetracker"
    make_good_skill "$dir"
    case "$form" in
      plain)
        sed -i '/^description: >-$/,+2c\description: Drive the timetracker CLI as a user.' "$dir/SKILL.md"
        ;;
      literal)
        sed -i 's/^description: >-$/description: |-/' "$dir/SKILL.md"
        ;;
      double-quoted)
        sed -i '/^description: >-$/,+2c\description: "Drive the app: capture proof"' "$dir/SKILL.md"
        ;;
      single-quoted)
        sed -i "/^description: >-$/,+2c\\description: 'Drive the app: capture proof'" "$dir/SKILL.md"
        ;;
    esac
    out=$(run_check "$dir") && code=0 || code=$?
    expect_code 0 "$code" "$form description passes the shape check"
  done
}

test_rejects_invalid_descriptions() {
  local dir index out value
  index=0
  for value in '' 'null' '""' '[unfinished' 'false' '123' '1.25' '2026-09-19' 'Drive app: now'; do
    index=$((index + 1))
    dir="$TMP_ROOT/invalid-description-$index/verify-timetracker"
    make_good_skill "$dir"
    sed -i "/^description: >-$/,+2c\\description: $value" "$dir/SKILL.md"
    out=$(run_check "$dir") && fail "invalid description '$value' must fail" || true
    assert_contains "$out" "description is missing or invalid" "failure names invalid description '$value'"
  done
}

test_rejects_duplicate_description() {
  local dir out
  dir="$TMP_ROOT/duplicate-description/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/^  Use when a task changes/a description: false' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "duplicate description keys must fail" || true
  assert_contains "$out" "description is missing or invalid" "failure names duplicate descriptions"
}

test_rejects_whitespace_only_section() {
  local dir out
  dir="$TMP_ROOT/whitespace-section/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/^## Launch$/,/^## Doctor$/ { /^## Launch$/b; /^## Doctor$/b; s/.*/   /; }' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "whitespace-only required section must fail" || true
  assert_contains "$out" "'## Launch'" "failure names the whitespace-only section"
}

test_rejects_removed_kill_rule() {
  local dir out
  dir="$TMP_ROOT/no-kill-rule/verify-timetracker"
  make_good_skill "$dir"
  sed -i 's/Never kill by process name; kill what you started\.//' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "cleanup without the kill rule must fail" || true
  assert_contains "$out" "kill by process name" "cleanup failure names the kill rule"
}

test_rejects_process_name_kill_instruction() {
  local dir out
  dir="$TMP_ROOT/process-name-kill/verify-timetracker"
  make_good_skill "$dir"
  sed -i 's/Never kill by process name; kill what you started\./If no PID is available, kill by process name./' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "process-name kill instruction must fail" || true
  assert_contains "$out" "never kill by process name" "failure names the cleanup safety rule"
}

test_rejects_contradictory_process_name_kill_instruction() {
  local dir out
  dir="$TMP_ROOT/contradictory-process-name-kill/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/Never kill by process name/a If PID lookup fails, kill by process name.' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "contradictory process-name kill instruction must fail" || true
  assert_contains "$out" "never kill by process name" "failure names the cleanup safety rule"
}

test_rejects_missing_feature_map() {
  local dir out
  dir="$TMP_ROOT/no-features/verify-timetracker"
  make_good_skill "$dir"
  rm -rf "$dir/features"
  out=$(run_check "$dir") && fail "missing feature map must fail" || true
  assert_contains "$out" "features/README.md" "failure names the missing feature map"
}

test_rejects_unreferenced_feature() {
  local dir out
  dir="$TMP_ROOT/unreferenced-feature/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/track-time\.md/d' "$dir/features/README.md"
  out=$(run_check "$dir") && fail "unreferenced feature file must fail" || true
  assert_contains "$out" "does not reference track-time.md" "failure names the unreferenced feature file"
}

test_rejects_malformed_feature_file() {
  local dir heading out
  for heading in "Sub-features" "How to get to it (user POV)" "Gotchas"; do
    dir="$TMP_ROOT/malformed-${heading//[^[:alnum:]]/-}/verify-timetracker"
    make_good_skill "$dir"
    sed -i "/^## $heading$/,/^## / { /^## $heading$/d; }" "$dir/features/track-time.md"
    out=$(run_check "$dir") && fail "feature file without '$heading' must fail" || true
    assert_contains "$out" "track-time.md is missing" "failure names the malformed feature file"
  done
}

test_rejects_feature_without_driving_section() {
  local dir out
  dir="$TMP_ROOT/missing-driving-section/verify-timetracker"
  make_good_skill "$dir"
  sed -i '/^## Driving it with shell$/,/^## Gotchas$/ { /^## Driving it with shell$/d; }' "$dir/features/track-time.md"
  out=$(run_check "$dir") && fail "feature file without a driving section must fail" || true
  assert_contains "$out" "Driving it with <harness>" "failure names the missing driving section"
}

test_rejects_leftover_placeholders() {
  local dir out
  dir="$TMP_ROOT/placeholder/verify-timetracker"
  make_good_skill "$dir"
  printf '\nSee the guide for <app> specifics.\n' >>"$dir/features/README.md"
  out=$(run_check "$dir") && fail "leftover placeholder must fail" || true
  assert_contains "$out" "placeholder or template marker" "failure names leftover placeholders"
}

test_rejects_name_directory_mismatch() {
  local dir out
  dir="$TMP_ROOT/mismatch/verify-othertool"
  make_good_skill "$dir"
  out=$(run_check "$dir") && fail "name/directory mismatch must fail" || true
  assert_contains "$out" "does not match directory name" "failure names the mismatch"
}

test_rejects_generic_skill_name() {
  local dir out
  dir="$TMP_ROOT/generic-name/verification"
  make_good_skill "$dir"
  sed -i 's/^name: verify-timetracker$/name: verification/' "$dir/SKILL.md"
  out=$(run_check "$dir") && fail "non verify- name must fail" || true
  assert_contains "$out" "must start with verify-" "failure names the verify- prefix rule"
}

test_rejects_missing_skill_file() {
  local dir out
  dir="$TMP_ROOT/empty/verify-nothing"
  mkdir -p "$dir"
  out=$(run_check "$dir") && fail "missing SKILL.md must fail" || true
  assert_contains "$out" "missing" "failure names the missing SKILL.md"
}

test_accepts_well_shaped_skill
test_accepts_skill_without_helpers
test_rejects_missing_sections
test_rejects_unclosed_frontmatter
test_rejects_missing_description
test_accepts_supported_description_forms
test_rejects_invalid_descriptions
test_rejects_duplicate_description
test_rejects_whitespace_only_section
test_rejects_removed_kill_rule
test_rejects_process_name_kill_instruction
test_rejects_contradictory_process_name_kill_instruction
test_rejects_missing_feature_map
test_rejects_unreferenced_feature
test_rejects_malformed_feature_file
test_rejects_feature_without_driving_section
test_rejects_leftover_placeholders
test_rejects_name_directory_mismatch
test_rejects_generic_skill_name
test_rejects_missing_skill_file

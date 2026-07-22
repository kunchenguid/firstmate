#!/usr/bin/env bash
# Behavior tests for bin/fm-playwright-scaffold.sh - the scaffold that drops a
# headless, isolated Playwright QA harness into a project worktree. Covers the
# generated file set and safety markers, custom and invalid viewports, idempotent
# keep-by-default vs --force overwrite, and usage/error exit codes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAFFOLD="$ROOT/bin/fm-playwright-scaffold.sh"
TMP_ROOT=$(fm_test_tmproot fm-playwright-scaffold)

test_default_scaffold_writes_headless_isolated_harness() {
  local dir="$TMP_ROOT/default"
  mkdir -p "$dir"
  "$SCAFFOLD" --dir "$dir" >/dev/null 2>&1 || fail "scaffold failed on empty dir"

  assert_present "$dir/playwright.config.ts" "config not created"
  assert_present "$dir/qa/specs/example.spec.ts" "example spec not created"
  assert_present "$dir/qa/.gitignore" "qa/.gitignore not created"
  assert_present "$dir/qa/screenshots/.gitkeep" "screenshots evidence dir not created"

  assert_grep "headless: true" "$dir/playwright.config.ts" "config is not headless"
  assert_grep "never attaches to the" "$dir/playwright.config.ts" "config lost the isolation/no-real-Chrome note"
  assert_grep "testDir: './qa/specs'" "$dir/playwright.config.ts" "config testDir is wrong"
  assert_grep "desktop-1857x933" "$dir/playwright.config.ts" "default desktop viewport project missing"
  assert_grep "viewport: { width: 1857, height: 933 }" "$dir/playwright.config.ts" "default desktop viewport size missing"
  assert_grep "laptop-1440x900" "$dir/playwright.config.ts" "default laptop viewport project missing"
  assert_grep "viewport: { width: 1440, height: 900 }" "$dir/playwright.config.ts" "default laptop viewport size missing"

  assert_grep "results/" "$dir/qa/.gitignore" "qa/.gitignore does not ignore run artifacts"
  pass "fm-playwright-scaffold.sh: default scaffold writes headless, isolated harness"
}

test_custom_viewports() {
  local dir="$TMP_ROOT/custom"
  mkdir -p "$dir"
  "$SCAFFOLD" --dir "$dir" --viewports "wide:1920x1080,phone:390x844" >/dev/null 2>&1 \
    || fail "scaffold failed with custom viewports"
  assert_grep "name: 'wide'" "$dir/playwright.config.ts" "custom wide project missing"
  assert_grep "viewport: { width: 1920, height: 1080 }" "$dir/playwright.config.ts" "custom wide size missing"
  assert_grep "name: 'phone'" "$dir/playwright.config.ts" "custom phone project missing"
  assert_grep "viewport: { width: 390, height: 844 }" "$dir/playwright.config.ts" "custom phone size missing"
  assert_no_grep "desktop-1857x933" "$dir/playwright.config.ts" "custom run leaked default viewports"
  pass "fm-playwright-scaffold.sh: custom viewports drive the generated projects"
}

test_idempotent_keep_by_default() {
  local dir="$TMP_ROOT/idempotent" out
  mkdir -p "$dir"
  "$SCAFFOLD" --dir "$dir" >/dev/null 2>&1 || fail "first scaffold failed"
  printf '// crewmate edit\n' >> "$dir/qa/specs/example.spec.ts"
  local before
  before=$(cat "$dir/qa/specs/example.spec.ts")
  out=$("$SCAFFOLD" --dir "$dir" 2>&1) || fail "idempotent re-run failed"
  assert_contains "$out" "kept" "re-run did not report kept files"
  [ "$(cat "$dir/qa/specs/example.spec.ts")" = "$before" ] \
    || fail "re-run clobbered a crewmate edit without --force"
  pass "fm-playwright-scaffold.sh: re-run keeps existing files and never clobbers edits"
}

test_force_overwrites() {
  local dir="$TMP_ROOT/force"
  mkdir -p "$dir"
  "$SCAFFOLD" --dir "$dir" >/dev/null 2>&1 || fail "first scaffold failed"
  printf '// crewmate edit\n' >> "$dir/qa/specs/example.spec.ts"
  "$SCAFFOLD" --dir "$dir" --force >/dev/null 2>&1 || fail "--force scaffold failed"
  assert_no_grep "// crewmate edit" "$dir/qa/specs/example.spec.ts" "--force did not overwrite the edited spec"
  pass "fm-playwright-scaffold.sh: --force overwrites existing files"
}

test_bad_viewport_is_usage_error() {
  local dir="$TMP_ROOT/badvp" out rc
  mkdir -p "$dir"
  out=$("$SCAFFOLD" --dir "$dir" --viewports "nope" 2>&1)
  rc=$?
  expect_code 2 "$rc" "bad viewport"
  assert_contains "$out" "viewport" "bad viewport error did not mention viewport"
  assert_absent "$dir/playwright.config.ts" "bad viewport still wrote a config"
  pass "fm-playwright-scaffold.sh: malformed viewport is a usage error and writes nothing"
}

test_unknown_flag_is_usage_error() {
  local out rc
  out=$("$SCAFFOLD" --dir "$TMP_ROOT" --nope 2>&1)
  rc=$?
  expect_code 2 "$rc" "unknown flag"
  assert_contains "$out" "unknown argument" "unknown flag not reported by name"
  pass "fm-playwright-scaffold.sh: unknown flag is a usage error"
}

test_missing_dir_errors() {
  local out rc
  out=$("$SCAFFOLD" --dir "$TMP_ROOT/does-not-exist" 2>&1)
  rc=$?
  expect_code 1 "$rc" "missing dir"
  assert_contains "$out" "not a directory" "missing dir not reported"
  pass "fm-playwright-scaffold.sh: missing target dir errors"
}

test_default_scaffold_writes_headless_isolated_harness
test_custom_viewports
test_idempotent_keep_by_default
test_force_overwrites
test_bad_viewport_is_usage_error
test_unknown_flag_is_usage_error
test_missing_dir_errors

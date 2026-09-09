#!/usr/bin/env bash
# tests/fm-spawn-disabled-plugins.test.sh - build_crew_settings_json behavior.
#
# Tests:
#   (a) absent file → base JSON only, no enabledPlugins key
#   (b) two IDs plus a comment line → both IDs set false, base keys preserved
#   (c) whitespace, blank lines, and inline comments are ignored
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

# shellcheck source=bin/fm-spawn-settings-lib.sh
source "$ROOT/bin/fm-spawn-settings-lib.sh"

BASE_JSON='{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}'

# ---------------------------------------------------------------------------
# (a) absent file: no enabledPlugins key, base keys present
# ---------------------------------------------------------------------------
unit_absent_file_emits_base_json() {
  local dir out
  dir=$(mktemp -d)
  out=$(build_crew_settings_json "$dir")
  rm -rf "$dir"
  if [ "$out" = "$BASE_JSON" ]; then
    pass "absent crew-disabled-plugins: settings JSON is base only"
  else
    fail "absent crew-disabled-plugins: expected base JSON, got: $out"
  fi
}

# ---------------------------------------------------------------------------
# (b) two IDs + comment line: both set false, base keys preserved
# ---------------------------------------------------------------------------
unit_two_ids_and_comment_produce_enabledplugins() {
  local dir out
  dir=$(mktemp -d)
  printf '%s\n' \
    "# context-mode's hooks cause 400 errors in crew sessions" \
    "context-mode@context-mode" \
    "other-plugin@vendor" \
    > "$dir/crew-disabled-plugins"
  out=$(build_crew_settings_json "$dir")
  rm -rf "$dir"
  local want
  want='{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"enabledPlugins":{"context-mode@context-mode":false,"other-plugin@vendor":false}}'
  if [ "$out" = "$want" ]; then
    pass "two IDs with comment line: both IDs false, base keys preserved"
  else
    fail "two IDs with comment line: expected '$want', got: $out"
  fi
}

# ---------------------------------------------------------------------------
# (c) blank lines, all-whitespace lines, and inline comments are stripped
# ---------------------------------------------------------------------------
unit_whitespace_and_blank_lines_ignored() {
  local dir out
  dir=$(mktemp -d)
  printf '%s\n' \
    "" \
    "   " \
    "  real-plugin@pub  # trailing comment" \
    "" \
    > "$dir/crew-disabled-plugins"
  out=$(build_crew_settings_json "$dir")
  rm -rf "$dir"
  local want
  want='{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"enabledPlugins":{"real-plugin@pub":false}}'
  if [ "$out" = "$want" ]; then
    pass "whitespace/blank/inline-comment lines ignored, trimmed id extracted"
  else
    fail "whitespace/blank/inline-comment lines ignored: expected '$want', got: $out"
  fi
}

# ---------------------------------------------------------------------------
# (d) empty file (all blank): base JSON only
# ---------------------------------------------------------------------------
unit_empty_file_emits_base_json() {
  local dir out
  dir=$(mktemp -d)
  printf '' > "$dir/crew-disabled-plugins"
  out=$(build_crew_settings_json "$dir")
  rm -rf "$dir"
  if [ "$out" = "$BASE_JSON" ]; then
    pass "empty crew-disabled-plugins: settings JSON is base only"
  else
    fail "empty crew-disabled-plugins: expected base JSON, got: $out"
  fi
}

# ---------------------------------------------------------------------------
# (e) lint: build_crew_settings_json source is shellcheck-clean
# ---------------------------------------------------------------------------
unit_lint() {
  local out
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-spawn.sh" 2>&1) \
    || { fail "fm-spawn.sh is not lint-clean: $out"; return; }
  pass "bin/fm-spawn.sh is lint-clean"
}

unit_absent_file_emits_base_json
unit_two_ids_and_comment_produce_enabledplugins
unit_whitespace_and_blank_lines_ignored
unit_empty_file_emits_base_json
unit_lint

[ "$FAILED" -eq 0 ] || exit 1

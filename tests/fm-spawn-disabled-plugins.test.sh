#!/usr/bin/env bash
# tests/fm-spawn-disabled-plugins.test.sh - build_crew_settings_json behavior.
#
# Tests:
#   (a) absent file → base JSON only, no enabledPlugins key
#   (b) two IDs plus a comment line → both IDs set false, base keys preserved
#   (c) whitespace, blank lines, and inline comments are ignored
#
# The three helpers under test (json_escape, shell_quote, build_crew_settings_json)
# are extracted verbatim from bin/fm-spawn.sh; do not assert implementation
# source bytes — this file drives the observable JSON output only.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

# --- pull the three self-contained helpers from fm-spawn.sh -----------------

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

build_crew_settings_json() {
  local config_dir=$1 disabled_file plugins_json="" id_escaped line
  disabled_file="$config_dir/crew-disabled-plugins"
  if [ -f "$disabled_file" ]; then
    while IFS= read -r line; do
      line=${line%%#*}
      # shellcheck disable=SC2001
      line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$line" ] || continue
      id_escaped=$(json_escape "$line")
      if [ -z "$plugins_json" ]; then
        plugins_json="\"$id_escaped\":false"
      else
        plugins_json="$plugins_json,\"$id_escaped\":false"
      fi
    done < "$disabled_file"
  fi
  if [ -n "$plugins_json" ]; then
    printf '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false},"enabledPlugins":{%s}}' "$plugins_json"
  else
    printf '%s' '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}'
  fi
}

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

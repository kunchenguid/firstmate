#!/usr/bin/env bash
# Behavioral coverage for /helm's read/write logic: config/captain-style.json
# show and set, including the absent case, partial-field merge, and
# validation refusals.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELM="$ROOT/bin/fm-helm.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

new_home() {
  fm_test_tmproot fm-helm
}

test_show_absent() {
  local home out
  home=$(new_home)
  out=$(FM_HOME="$home" "$HELM" show) || fail "show exited non-zero on an absent file"
  printf '%s' "$out" | grep -q '^ABSENT:' || fail "show did not report ABSENT for a missing config/captain-style.json: $out"
  pass "show reports ABSENT when config/captain-style.json does not exist"
}

test_set_both_then_show() {
  local home out
  home=$(new_home)
  FM_HOME="$home" "$HELM" set --language vi --response-tone 'blunt and playful' \
    || fail "set with both fields exited non-zero"
  out=$(FM_HOME="$home" "$HELM" show) || fail "show exited non-zero after set"
  printf '%s' "$out" | grep -qx 'language=vi' || fail "language missing from show output: $out"
  printf '%s' "$out" | grep -qx 'response_tone=blunt and playful' || fail "response_tone missing from show output: $out"
  pass "set writes both fields and show reads them back"
}

test_set_one_field_preserves_other() {
  local home out
  home=$(new_home)
  FM_HOME="$home" "$HELM" set --language vi --response-tone 'blunt and playful' \
    || fail "initial set with both fields exited non-zero"
  FM_HOME="$home" "$HELM" set --language en \
    || fail "set with only --language exited non-zero"
  out=$(FM_HOME="$home" "$HELM" show) || fail "show exited non-zero after partial set"
  printf '%s' "$out" | grep -qx 'language=en' || fail "language was not updated: $out"
  printf '%s' "$out" | grep -qx 'response_tone=blunt and playful' \
    || fail "response_tone was clobbered by a language-only set: $out"
  pass "setting one field never clobbers the other"
}

test_set_requires_a_field() {
  local home
  home=$(new_home)
  if FM_HOME="$home" "$HELM" set >/dev/null 2>&1; then
    fail "set with no flags unexpectedly succeeded"
  fi
  [ ! -f "$home/config/captain-style.json" ] \
    || fail "set with no flags must not create config/captain-style.json"
  pass "set with neither flag is refused and creates no file"
}

test_set_rejects_empty_value() {
  local home
  home=$(new_home)
  if FM_HOME="$home" "$HELM" set --language '   ' >/dev/null 2>&1; then
    fail "set accepted a whitespace-only --language"
  fi
  [ ! -f "$home/config/captain-style.json" ] \
    || fail "a rejected set must not create config/captain-style.json"
  pass "set rejects a whitespace-only value"
}

test_write_is_atomic_no_stray_tmp() {
  local home
  home=$(new_home)
  FM_HOME="$home" "$HELM" set --language vi >/dev/null || fail "set exited non-zero"
  local stray
  stray=$(find "$home/config" -maxdepth 1 -name '.fm-helm.*' 2>/dev/null)
  [ -z "$stray" ] || fail "temp file left behind after a successful set: $stray"
  pass "a successful set leaves no stray temp file in config/"
}

test_malformed_existing_file_is_refused() {
  local home
  home=$(new_home)
  mkdir -p "$home/config"
  printf 'not json' > "$home/config/captain-style.json"
  if FM_HOME="$home" "$HELM" show >/dev/null 2>&1; then
    fail "show accepted a malformed config/captain-style.json"
  fi
  if FM_HOME="$home" "$HELM" set --language vi >/dev/null 2>&1; then
    fail "set merged over a malformed config/captain-style.json instead of refusing"
  fi
  pass "malformed existing JSON is refused by both show and set rather than silently replaced"
}

test_non_object_root_is_refused() {
  local home
  home=$(new_home)
  mkdir -p "$home/config"
  printf '["vi", "blunt"]' > "$home/config/captain-style.json"
  if FM_HOME="$home" "$HELM" show >/dev/null 2>&1; then
    fail "show accepted a non-object JSON root (an array)"
  fi
  if FM_HOME="$home" "$HELM" set --language vi >/dev/null 2>&1; then
    fail "set merged over a non-object JSON root instead of refusing"
  fi
  pass "valid JSON with a non-object root is refused by both show and set"
}

test_non_string_field_is_refused() {
  local home
  home=$(new_home)
  mkdir -p "$home/config"
  printf '{"language": ["vi", "en"]}' > "$home/config/captain-style.json"
  if FM_HOME="$home" "$HELM" show >/dev/null 2>&1; then
    fail "show accepted a structured (non-string) language field"
  fi
  if FM_HOME="$home" "$HELM" set --response-tone 'blunt' >/dev/null 2>&1; then
    fail "set merged over a structured (non-string) field instead of refusing"
  fi
  pass "a structured (non-string) field value is refused by both show and set"
}

# no_jq_path: a minimal PATH containing only what fm-helm.sh needs to launch
# and run its non-jq logic (bash for the shebang, dirname for SCRIPT_DIR) -
# with no directory that provides jq. Used to prove a missing jq is reported
# as its own distinct, loudly-named failure rather than being conflated with
# a schema-invalid file.
no_jq_path() {
  local dir tool
  dir=$(fm_test_tmproot fm-helm-no-jq)/bin
  mkdir -p "$dir"
  for tool in bash dirname; do
    ln -s "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s' "$dir"
}

test_show_missing_jq_is_distinct_from_schema_invalid() {
  local home noqjs out status
  home=$(new_home)
  FM_HOME="$home" "$HELM" set --language vi --response-tone 'blunt and playful' \
    || fail "initial set with both fields exited non-zero"

  noqjs=$(no_jq_path)
  status=0
  out=$(PATH="$noqjs" FM_HOME="$home" "$HELM" show 2>&1) || status=$?
  [ "$status" -eq 3 ] \
    || fail "show without jq on PATH must exit 3 (distinct from schema-invalid's 1), got $status: $out"
  printf '%s' "$out" | grep -q 'jq' || fail "missing-jq failure did not name the missing dependency: $out"
  pass "show without jq on PATH fails with a distinct status naming the missing dependency, not a schema error"
}

test_set_missing_jq_is_distinct_from_schema_invalid() {
  local home noqjs out status
  home=$(new_home)

  noqjs=$(no_jq_path)
  status=0
  out=$(PATH="$noqjs" FM_HOME="$home" "$HELM" set --language vi 2>&1) || status=$?
  [ "$status" -eq 3 ] \
    || fail "set without jq on PATH must exit 3 (distinct from schema-invalid's 1), got $status: $out"
  printf '%s' "$out" | grep -q 'jq' || fail "missing-jq failure did not name the missing dependency: $out"
  [ ! -f "$home/config/captain-style.json" ] \
    || fail "set without jq on PATH must not write a file"
  pass "set without jq on PATH fails with a distinct status naming the missing dependency, not a schema error"
}

test_help_prints_full_text_not_truncated() {
  local out
  out=$("$HELM" --help) || fail "--help exited non-zero"
  printf '%s' "$out" | grep -qx 'config/captain-style.json behind.' \
    || fail "--help output was truncated before its last line: $out"
  pass "--help prints its full usage text, not truncated"
}

test_help_prints_full_text_not_truncated
test_show_absent
test_malformed_existing_file_is_refused
test_non_object_root_is_refused
test_non_string_field_is_refused
test_set_both_then_show
test_set_one_field_preserves_other
test_set_requires_a_field
test_set_rejects_empty_value
test_write_is_atomic_no_stray_tmp
test_show_missing_jq_is_distinct_from_schema_invalid
test_set_missing_jq_is_distinct_from_schema_invalid

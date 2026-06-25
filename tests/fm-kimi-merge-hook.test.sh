#!/usr/bin/env bash
# Tests for bin/fm-kimi-merge-hook.sh.
#
# Covers safe TOML merging of a Stop hook into a copied kimi config.toml.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT/bin/fm-kimi-merge-hook.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-merge-hook.XXXXXX")

test_appends_stop_hook_to_plain_config() {
  local config turnend
  config="$TMP_ROOT/plain-config.toml"
  turnend="$TMP_ROOT/state/task-x1.turn-ended"
  printf '%s\n' 'theme = "dark"' > "$config"

  "$MERGE" "$config" "$turnend" || fail "merge failed on plain config"

  grep -qF 'event = "Stop"' "$config" || fail "Stop event missing"
  grep -qF "command = \"touch '$turnend'\"" "$config" || fail "Stop command missing"
  grep -qF '[[hooks]]' "$config" || fail "[[hooks]] section missing"
  pass "appends Stop hook to a plain config"
}

test_does_not_duplicate_identical_stop_hook() {
  local config turnend hooks_before hooks_after
  config="$TMP_ROOT/dedup-config.toml"
  turnend="$TMP_ROOT/state/task-x2.turn-ended"
  printf '%s\n' 'theme = "dark"' > "$config"

  "$MERGE" "$config" "$turnend" || fail "first merge failed"
  hooks_before=$(grep -cF '[[hooks]]' "$config")
  "$MERGE" "$config" "$turnend" || fail "second merge failed"
  hooks_after=$(grep -cF '[[hooks]]' "$config")

  [ "$hooks_before" -eq "$hooks_after" ] || fail "duplicate Stop hook added (count changed)"
  pass "does not duplicate an identical Stop hook"
}

test_errors_on_bare_hooks_table() {
  local config turnend rc
  config="$TMP_ROOT/bare-table-config.toml"
  turnend="$TMP_ROOT/state/task-x3.turn-ended"
  printf '%s\n' '[hooks]' 'event = "Stop"' "command = \"touch $turnend\"" > "$config"

  set +e
  "$MERGE" "$config" "$turnend" >/dev/null 2>&1
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "merge succeeded on a bare [hooks] table"
  pass "errors on a config with a bare [hooks] table"
}

test_appends_to_existing_hooks_array() {
  local config turnend
  config="$TMP_ROOT/array-config.toml"
  turnend="$TMP_ROOT/state/task-x4.turn-ended"
  cat > "$config" <<'EOF'
theme = "dark"

[[hooks]]
event = "Start"
command = "echo start"
EOF

  "$MERGE" "$config" "$turnend" || fail "merge failed on existing hooks array"

  grep -cF '[[hooks]]' "$config" | grep -q '^2$' || fail "expected two [[hooks]] blocks"
  grep -qF 'event = "Stop"' "$config" || fail "Stop event missing"
  pass "appends Stop hook to an existing [[hooks]] array"
}

test_ensures_trailing_newline() {
  local config turnend last
  config="$TMP_ROOT/no-newline-config.toml"
  turnend="$TMP_ROOT/state/task-x5.turn-ended"
  printf 'theme = "dark"' > "$config"  # no trailing newline

  "$MERGE" "$config" "$turnend" || fail "merge failed on config without trailing newline"

  last=$(tail -c 1 "$config" | od -An -tx1 | tr -d ' ')
  [ "$last" = "0a" ] || fail "config did not end with a newline after merge"
  pass "ensures config ends with a newline"
}

test_appends_distinct_stop_command() {
  local config turnend hooks_count
  config="$TMP_ROOT/other-stop-config.toml"
  turnend="$TMP_ROOT/state/task-x6.turn-ended"
  cat > "$config" <<'EOF'
[[hooks]]
event = "Stop"
command = "echo other"
EOF

  "$MERGE" "$config" "$turnend" || fail "merge failed with existing different Stop hook"
  hooks_count=$(grep -cF '[[hooks]]' "$config")
  [ "$hooks_count" -eq 2 ] || fail "expected two [[hooks]] blocks, got $hooks_count"
  grep -qF "command = \"touch '$turnend'\"" "$config" || fail "new touch command missing"
  pass "adds a Stop hook when an existing Stop hook has a different command"
}

test_appends_stop_hook_to_plain_config
test_does_not_duplicate_identical_stop_hook
test_errors_on_bare_hooks_table
test_appends_to_existing_hooks_array
test_ensures_trailing_newline
test_appends_distinct_stop_command

#!/usr/bin/env bash
# Focused bootstrap coverage for dispatch-policy directory entry handling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bootstrap-dispatch-policy)
EXPECTED='CREW_DISPATCH: invalid config/crew-dispatch.json - invalid dispatch policy'

prepare_home() {
  local label=$1 home
  home="$TMP_ROOT/$label/home"
  mkdir -p "$home/config"
  printf '%s\n' manual > "$home/config/backlog-backend"
  printf '%s\n' "$home"
}

run_bootstrap() {
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_BOOTSTRAP_NETWORK=skip \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

dispatch_lines() {
  printf '%s\n' "$1" | grep '^CREW_DISPATCH:' || true
}

assert_invalid_entry() {
  local output=$1 label=$2 lines count
  lines=$(dispatch_lines "$output")
  count=$(printf '%s\n' "$lines" | awk 'NF { count += 1 } END { print count + 0 }')
  [ "$count" -eq 1 ] || fail "$label: expected one dispatch diagnostic, got $count: $lines"
  [ "$lines" = "$EXPECTED" ] || fail "$label: unstable dispatch diagnostic: $lines"
  assert_not_contains "$output" 'jq:' "$label exposed raw jq output"
  assert_not_contains "$output" 'TOKEN=exposed' "$label exposed caller-controlled path bytes"
  assert_not_contains "$output" "$TMP_ROOT" "$label exposed an external path"
}

test_absent_and_valid_entries_remain_silent() {
  local home output target
  home=$(prepare_home absent)
  output=$(run_bootstrap "$home")
  [ -z "$(dispatch_lines "$output")" ] || fail "genuinely absent dispatch policy was not silent"

  home=$(prepare_home valid-regular)
  printf '%s\n' '{"rules":[]}' > "$home/config/crew-dispatch.json"
  output=$(run_bootstrap "$home")
  [ -z "$(dispatch_lines "$output")" ] || fail "valid regular dispatch policy was rejected"

  home=$(prepare_home valid-symlink)
  target="$TMP_ROOT/valid-policy.json"
  printf '%s\n' '{"rules":[]}' > "$target"
  ln -s "$target" "$home/config/crew-dispatch.json"
  output=$(run_bootstrap "$home")
  [ -z "$(dispatch_lines "$output")" ] || fail "valid regular-file symlink was rejected"
  pass "bootstrap keeps absent and valid dispatch-policy entries silent"
}

test_existing_invalid_entry_types_are_reported() {
  local home output
  home=$(prepare_home directory)
  mkdir "$home/config/crew-dispatch.json"
  output=$(run_bootstrap "$home")
  assert_invalid_entry "$output" directory

  home=$(prepare_home dangling-link)
  ln -s "$TMP_ROOT/missing-TOKEN=exposed" "$home/config/crew-dispatch.json"
  output=$(run_bootstrap "$home")
  assert_invalid_entry "$output" dangling-symlink

  home=$(prepare_home special-link)
  ln -s /dev/null "$home/config/crew-dispatch.json"
  output=$(run_bootstrap "$home")
  assert_invalid_entry "$output" special-file-symlink
  pass "bootstrap reports directory, dangling-symlink, and special-file entries"
}

test_no_writer_fifo_is_reported_promptly() {
  local home output_file error_file process watchdog rc output
  home=$(prepare_home fifo)
  mkfifo "$home/config/crew-dispatch.json"
  output_file="$TMP_ROOT/fifo-output"
  error_file="$TMP_ROOT/fifo-error"
  run_bootstrap "$home" >"$output_file" 2>"$error_file" &
  process=$!
  (sleep 2; kill "$process" >/dev/null 2>&1 || true) &
  watchdog=$!
  set +e
  wait "$process"
  rc=$?
  set -e
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" >/dev/null 2>&1 || true
  [ "$rc" -eq 0 ] || fail "no-writer FIFO bootstrap did not return promptly (rc=$rc)"
  output=$(cat "$output_file" "$error_file")
  assert_invalid_entry "$output" no-writer-fifo
  pass "bootstrap reports a no-writer FIFO promptly and safely"
}

test_absent_and_valid_entries_remain_silent
test_existing_invalid_entry_types_are_reported
test_no_writer_fifo_is_reported_promptly

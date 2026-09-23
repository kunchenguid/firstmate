#!/usr/bin/env bash
set -eu

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-content-dispatch)
CAPTURE_LOG="$TMP_ROOT/captures"
: > "$CAPTURE_LOG"
fm_backend_source orca
fm_backend_source cmux

fm_backend_orca_composer_capture() {
  printf 'orca\n' >> "$CAPTURE_LOG"
  printf '────────\n❯ pending text\n────────\n'
}
fm_backend_cmux_composer_capture() {
  printf 'cmux\n' >> "$CAPTURE_LOG"
  printf '────────\n❯ pending text\n────────\n'
}

for backend in orca cmux; do
  rc=0
  output=$(fm_backend_composer_content "$backend" fixture-target) || rc=$?
  [ "$rc" = 1 ] || fail "$backend exact-content read must refuse"
  [ -z "$output" ] || fail "$backend refusal must emit no content"
  [ ! -s "$CAPTURE_LOG" ] || fail "$backend refusal must not capture a pane"
done
pass "unsupported exact-content backends refuse without capturing"

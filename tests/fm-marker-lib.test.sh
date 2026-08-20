#!/usr/bin/env bash
# Characterization coverage for the compatibility entry point used by callers
# that still source bin/fm-marker-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

test_compatibility_entry_point_exports_marker_api() {
  local marked separator
  separator=$(printf '\342\201\243')

  fm_message_mark_from_firstmate 'inspect the report' marked \
    || fail "marker compatibility entry point did not export the marker helper"
  [ "$marked" = "[fm-from-firstmate]${separator}inspect the report" ] \
    || fail "marker helper changed its established wire format: $marked"

  fm_message_mark_from_firstmate "$marked" marked \
    || fail "marker helper rejected an already-marked message"
  [ "$marked" = "[fm-from-firstmate]${separator}inspect the report" ] \
    || fail "marker helper was not idempotent: $marked"

  pass "marker-lib: compatibility source exports the established idempotent marker API"
}

test_compatibility_entry_point_exports_marker_api

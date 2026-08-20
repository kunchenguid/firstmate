#!/usr/bin/env bash
# Characterization coverage for fm-decision-hold identity validation.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-decision-hold.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)

identity=$(
  FM_HOME="$TMP_ROOT" \
    "$SCRIPT" id origin_7 api-shape
) || fail 'valid decision identity should be accepted'
[ "$identity" = 'origin_7-decision-api-shape' ] \
  || fail "decision identity changed: $identity"

if FM_HOME="$(fm_test_tmproot fm-decision-hold-invalid)" \
  "$SCRIPT" id origin/7 api-shape >/dev/null 2>"$TMP_ROOT/stderr"; then
  fail 'unsafe origin identity should be rejected'
fi
assert_grep 'origin-id must be a non-empty privacy-safe slug' \
  "$TMP_ROOT/stderr" \
  'unsafe origin identity should explain the slug contract'

pass 'fm-decision-hold validates and composes durable decision identities'
echo '# fm-decision-hold.test.sh: all assertions passed'

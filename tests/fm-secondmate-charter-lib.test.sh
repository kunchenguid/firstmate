#!/usr/bin/env bash
# Characterization coverage for secondmate charter extraction and normalization.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-charter-lib-tests)
BRIEF="$TMP_ROOT/brief.md"
cat > "$BRIEF" <<'EOF'
# Charter

Remote secondmate; owns (review) and
  release   operations.

# Routing scope

GitHub; CI   and
  release.

# Other

ignored
EOF

# shellcheck source=bin/fm-secondmate-charter-lib.sh disable=SC1091
. "$ROOT/bin/fm-secondmate-charter-lib.sh"

[ "$(registry_summary_for_brief "$BRIEF")" = 'Remote secondmate owns review and release operations.' ] \
  || fail "charter extraction should normalize punctuation and whitespace"
[ "$(registry_scope_for_brief "$BRIEF")" = 'GitHub CI and release.' ] \
  || fail "routing-scope extraction should stop at the next heading"

FM_SECONDMATE_CHARTER='  Explicit; charter (override)  ' \
FM_SECONDMATE_SCOPE=$' Explicit\n scope ' \
  bash -c 'source "$1"; [ "$(registry_summary_for_brief "$2")" = "Explicit charter override" ] && [ "$(registry_scope_for_brief "$3")" = "Explicit scope" ]' \
  bash "$ROOT/bin/fm-secondmate-charter-lib.sh" "$BRIEF" "$BRIEF" \
  || fail "explicit charter and scope overrides should take precedence"

pass "secondmate-charter-lib extracts bounded sections and honors explicit overrides"
echo "# fm-secondmate-charter-lib.test.sh: all assertions passed"

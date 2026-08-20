#!/usr/bin/env bash
# Characterization coverage for the shared status classifier's pure functions.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

status_line_is_parseable 'needs-decision [key=api-shape]: choose a response' \
  || fail 'keyed decision status should be parseable'
status_line_is_parseable 'working: still implementing' \
  || fail 'ordinary status should be parseable'
if status_line_is_parseable 'needs-decision: '; then
  fail 'status without a note should not be parseable'
fi

[ "$(status_line_verb 'needs-decision [key=api-shape]: choose a response')" = needs-decision ] \
  || fail 'status_line_verb should strip keyed metadata'
[ "$(status_line_note 'needs-decision [key=api-shape]:   choose a response')" = 'choose a response' ] \
  || fail 'status_line_note should trim the decision note'
status_is_captain_relevant 'blocked [key=api-shape]: unresolved' \
  || fail 'blocked status should be captain-relevant'
if status_is_captain_relevant 'working: merged the branch'; then
  fail 'working status should not become relevant from free-text prose'
fi
status_is_paused 'paused: waiting for upstream' \
  || fail 'paused status should be recognized'

TMP_ROOT=$(fm_test_tmproot fm-classify-lib)
STATUS_FILE="$TMP_ROOT/task.status"
cat > "$STATUS_FILE" <<'EOF'
needs-decision [key=api-shape]: choose a response
working: continued implementation
blocked [key=release]: release dependency
resolved [key=api-shape]: selected response
EOF
open_decisions=$(status_open_decisions "$STATUS_FILE")
assert_contains "$open_decisions" $'release\tblocked\trelease dependency' \
  'decision fold should preserve unresolved keyed decisions'

pass 'fm-classify-lib classifies status grammar and folds keyed decisions'
echo '# fm-classify-lib.test.sh: all assertions passed'

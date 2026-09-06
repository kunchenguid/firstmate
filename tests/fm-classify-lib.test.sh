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

printf '%s\n' \
  'paused [key=x]: waiting' \
  'note [key=x]: progress' \
  'working [key=x]: resumed' > "$STATUS_FILE"
resume_line=$(status_resume_line "$STATUS_FILE" key:x 1)
[ "$resume_line" = 3 ] || fail 'phase transition accessor should find the later working line'
printf '%s\n' 'paused [key=x]: waiting' 'note [key=x]: progress' > "$STATUS_FILE"
if status_resume_line "$STATUS_FILE" key:x 1 >/dev/null; then
  fail 'phase transition accessor should ignore keyed notes'
fi
printf '%s\n' 'paused [key=x]: waiting' 'paused [key=x]: refreshed' 'working [key=x]: resumed' > "$STATUS_FILE"
if status_resume_line "$STATUS_FILE" key:x 1 >/dev/null; then
  fail 'a replaced keyed pause must not borrow a later resume'
fi
resume_line=$(status_resume_line "$STATUS_FILE" key:x 2)
[ "$resume_line" = 3 ] || fail 'the newest keyed pause should close at the later working line'
for bad_line in 0 00 junk:1; do
  if status_resume_line "$STATUS_FILE" key:x "$bad_line" >/dev/null; then
    fail "malformed cache line $bad_line must not prove a pause transition"
  fi
done

pass 'fm-classify-lib owns the keyed phase transition accessor'
echo '# fm-classify-lib.test.sh: all assertions passed'

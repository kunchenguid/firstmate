#!/usr/bin/env bash
# Characterization coverage for fm-pending-reply-lib correlation matching.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh disable=SC1091
. "$ROOT/bin/fm-pending-reply-lib.sh"

corr=0123456789abcdef

fm_pending_reply_line_resolves "done [corr=$corr]: report ready" "$corr" \
  || fail 'a status line carrying the exact correlation token should resolve'

if fm_pending_reply_line_resolves "pending-reply-missed: pending-reply-id=$corr" "$corr"; then
  fail 'the parent missed-report escalation must not self-resolve'
fi

pass 'pending-reply correlation matching accepts reports and rejects escalation self-matches'
echo '# fm-pending-reply-lib.test.sh: all assertions passed'

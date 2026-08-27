#!/usr/bin/env bash
# Characterization coverage for fm-pending-reply-lib correlation matching and
# for the producer-side refusal that keeps a malformed correlation token out of
# an append-only reply log in the first place.
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

# --- producer-side refusal --------------------------------------------------
#
# Every appendable corr= byte comes from fm_pending_reply_corr_token. A token
# that is not exactly 16 hexadecimal characters can only ever be quarantined by
# the parent ingest, so the producer refuses it before any append. Each case
# below fails if that validation is removed.

# dc9b78419d7c1b6 is the exact 15-hex shape observed in the production incident.
for bad in dc9b78419d7c1b6 0123456789abcde 0123456789abcdef0 '' 'zzzzzzzzzzzzzzzz' \
  '0123456789abcde ' '0123456789abcd-f' 'corr=0123456789abcdef'; do
  if token=$(fm_pending_reply_corr_token "$bad"); then
    fail "a malformed correlation token was produced for '$bad': $token"
  fi
  [ -z "$token" ] \
    || fail "a refused correlation token still emitted bytes for '$bad': $token"
  if fm_pending_reply_corr_valid "$bad"; then
    fail "a malformed correlation id validated: '$bad'"
  fi
done

for good in 0123456789abcdef 0123456789ABCDEF ffffffffffffffff 0000000000000000; do
  token=$(fm_pending_reply_corr_token "$good") \
    || fail "a 16-hex correlation token must be produced: $good"
  [ "$token" = "corr=$good" ] \
    || fail "the produced token changed shape for $good: $token"
  fm_pending_reply_corr_valid "$good" \
    || fail "a 16-hex correlation id must validate: $good"
done

pass 'the token producer emits exactly-16-hex correlations and refuses every other shape'

# The message embedder is the second producer path: it must refuse rather than
# mark a request with a token the parent can never correlate.
embedded=
fm_pending_reply_embed_corr 'run the audit' "$corr" embedded \
  || fail 'embedding a valid correlation token must succeed'
case "$embedded" in
  *"corr=$corr"*) ;;
  *) fail "the embedded message lost its correlation token: $embedded" ;;
esac

embedded=
if fm_pending_reply_embed_corr 'run the audit' dc9b78419d7c1b6 embedded; then
  fail "a malformed correlation token was embedded into an outbound request: $embedded"
fi
case "$embedded" in
  *corr=*) fail "a refused embed still produced correlation bytes: $embedded" ;;
esac

if fm_pending_reply_text_has_corr "done [corr=dc9b78419d7c1b6]: report" dc9b78419d7c1b6; then
  fail 'a malformed correlation token must never be recognized as a correlation'
fi
if fm_pending_reply_text_has_corr "done [corr=${corr}0]: report" "$corr"; then
  fail 'a longer malformed correlation token must not match its valid prefix'
fi
if fm_pending_reply_text_has_corr "done [corr=${corr}G]: report" "$corr"; then
  fail 'a nonhex alphanumeric suffix must not terminate a correlation token'
fi
if fm_pending_reply_text_has_corr "done [corr=${corr}_]: report" "$corr"; then
  fail 'an identifier suffix must not terminate a correlation token'
fi
if fm_pending_reply_text_has_corr "done [xcorr=${corr}]: report" "$corr"; then
  fail 'a correlation token without a left boundary must not match'
fi
extracted=sentinel
if extracted=$(fm_pending_reply_extract_corr "inspect corr=${corr}0"); then
  fail 'correlation extraction accepted a malformed token prefix'
fi
[ -z "$extracted" ] \
  || fail "refused correlation extraction emitted bytes: $extracted"
embedded=
if fm_pending_reply_embed_corr "inspect corr=${corr}G" "$corr" embedded; then
  fail 'the embedder retained a malformed correlation token'
fi
[ -z "$embedded" ] \
  || fail "the refused embedder emitted bytes: $embedded"

pass 'the request embedder and the correlation reader both refuse a malformed token'

# --- the optional report helper is the same owner ---------------------------
#
# bin/fm-secondmate-report.sh is the helper a mate uses to append a correlated
# report. It must refuse a malformed token before the append, and must not
# create the status file as a side effect of that refusal.

HELPER_ROOT=$(fm_test_tmproot fm-pending-reply-lib-helper)
trap fm_test_cleanup EXIT
STATUS_FILE="$HELPER_ROOT/parent/state/mate.status"

set +e
helper_out=$("$ROOT/bin/fm-secondmate-report.sh" "$STATUS_FILE" 'done' dc9b78419d7c1b6 'audit clean' 2>&1)
helper_rc=$?
set -e
[ "$helper_rc" -ne 0 ] \
  || fail 'the report helper appended a 15-hex correlation instead of refusing it'
assert_contains "$helper_out" 'corr_id must be 16 hex characters' \
  'the report helper refusal did not name the correlation shape'
assert_absent "$STATUS_FILE" \
  'the report helper wrote a status file while refusing a malformed correlation'

"$ROOT/bin/fm-secondmate-report.sh" "$STATUS_FILE" 'done' "$corr" 'audit clean' \
  || fail 'the report helper refused a valid 16-hex correlation'
assert_grep "corr=$corr" "$STATUS_FILE" \
  'the report helper did not append the correlated report'
[ "$(wc -l < "$STATUS_FILE" | tr -d ' ')" -eq 1 ] \
  || fail 'the report helper appended more than the one correlated report line'

pass 'the optional report helper refuses a malformed correlation before any append'
echo '# fm-pending-reply-lib.test.sh: all assertions passed'

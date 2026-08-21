#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
REMOTE_INTERLEAVE="$TMP_ROOT/remote-interleave"
REMOTE_UTF8="$TMP_ROOT/remote-utf8"
REMOTE_KEYED="$TMP_ROOT/remote-keyed"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" \
  "$REMOTE_INTERLEAVE/state" "$REMOTE_INTERLEAVE/data" "$REMOTE_UTF8/state" \
  "$REMOTE_KEYED/state" "$CLAIMS"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; fm_test_cleanup' EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
- interleave - interleaved reply fixture (host: remote-interleave; root: $ROOT; home: $REMOTE_INTERLEAVE; scope: test; projects: alpha; added 2026-08-02)
- utf8 - utf8 reply fixture (host: remote-utf8; root: $ROOT; home: $REMOTE_UTF8; scope: test; projects: alpha; added 2026-08-02)
- keyed - keyed reply fixture (host: remote-keyed; root: $ROOT; home: $REMOTE_KEYED; scope: test; projects: alpha; added 2026-08-20)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
  case "$host" in remote-mac|remote-interleave|remote-utf8|remote-keyed) ;;
    *) exit 91 ;;
  esac
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=0123456789abcdef]: build verified (data/reply/report.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
wait "$RUNNER" || fail "remote reply source failed to capture its first delta"
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
assert_grep "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue" "runner did not publish the normalized remote-reply event"
assert_no_grep 'build verified' "$PARENT/state/.wake-queue" "reply payload leaked into the event queue"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=1' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not commit the reply before retry"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'handled: remote-reply-ios 1' "captured generation was not acknowledged"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "parent status did not receive the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" "remote document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" "reply cursor did not advance to the committed delta"
pass "ingest appends one validated line, fetches its document, and advances the cursor"

out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

# Generation 2 compatibility fixture: an old remote status prefix can be
# replayed from byte zero before a current correlated reply arrives.
remote_env "$ADAPTER" retire ios >/dev/null \
  || fail "could not retire the first generation before the compatibility replay"
: > "$REMOTE/state/parent-replies.status"
printf 'working: legacy remote prefix\n' \
  >> "$REMOTE/state/parent-replies.status"
printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ADAPTER" arm ios >/dev/null \
  || fail "could not re-arm the generation-2 compatibility fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
assert_grep 'working: legacy remote prefix' "$PARENT/state/ios.status" \
  "legacy prefix was not preserved while ingesting the correlated reply"
printf 'working: legacy remote prefix\n' > "$TMP_ROOT/expected-legacy-prefix"
grep -F -x 'working: legacy remote prefix' "$PARENT/state/ios.status" \
  > "$TMP_ROOT/actual-legacy-prefix" \
  || fail "legacy prefix was not retained as a complete line"
cmp -s "$TMP_ROOT/expected-legacy-prefix" "$TMP_ROOT/actual-legacy-prefix" \
  || fail "legacy prefix bytes were changed during compatibility ingest"
generation_two_offset=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/ios.cursor")
generation_two_hash=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/ios.cursor")
head -c "$generation_two_offset" "$REMOTE/state/parent-replies.status" > "$TMP_ROOT/generation-two-prefix"
[ "$(sha256_file "$TMP_ROOT/generation-two-prefix")" = "$generation_two_hash" ] \
  || fail "generation-2 cursor hash did not match its committed byte prefix"
printf 'done [corr=2222222222222222]: third generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "third reply generation was not captured"
RESULT_THREE="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ADAPTER" handle ios 3 "$RESULT_THREE" >/dev/null \
  || fail "third reply generation was not handled"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
out=$(remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "earlier generation did not replay from its durable ingestion receipt"
assert_contains "$out" 'handled: remote-reply-ios 2' "earlier generation remained unacknowledged after later cursor advancement"
[ "$(grep -cF 'working [corr=1111111111111111]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "earlier generation replay duplicated its parent status"
pass "later generations cannot invalidate an unacknowledged ingested result"

# An uncorrelated line after the legacy prefix must not discard surrounding
# correlated replies or prevent the cursor from advancing past the delta.
{
  printf 'working [corr=aaaaaaaaaaaaaaaa]: first interleaved reply\n'
  printf 'working: uncorrelated noise after a correlated reply\n'
  printf 'done [corr=bbbbbbbbbbbbbbbb]: second interleaved reply\n'
} >> "$REMOTE_INTERLEAVE/state/parent-replies.status"
INTERLEAVE_SID=$(remote_env "$ADAPTER" source-id interleave)
remote_env "$ADAPTER" arm interleave >/dev/null \
  || fail "could not arm the interleaved reply fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$INTERLEAVE_SID" >/dev/null \
  || fail "interleaved reply fixture was not captured"
INTERLEAVE_RESULT="$PARENT/state/procevent-inbox/$INTERLEAVE_SID.1.result"
interleave_out=$(remote_env "$ADAPTER" handle interleave 1 "$INTERLEAVE_RESULT") \
  || fail "an uncorrelated line discarded the valid lines in the same delta"
assert_contains "$interleave_out" 'ingested: interleave appended=2' \
  "valid correlated lines were not ingested around the uncorrelated line"
assert_grep 'first interleaved reply' "$PARENT/state/interleave.status" \
  "the first correlated line was discarded"
assert_grep 'second interleaved reply' "$PARENT/state/interleave.status" \
  "the second correlated line was discarded"
assert_no_grep 'uncorrelated noise' "$PARENT/state/interleave.status" \
  "the uncorrelated line was appended instead of skipped"
INTERLEAVE_OFFSET=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/interleave.cursor")
[ "$INTERLEAVE_OFFSET" -gt 0 ] \
  || fail "the cursor did not advance after ingesting an interleaved delta"
printf 'done [corr=cccccccccccccccc]: third interleaved reply\n' \
  >> "$REMOTE_INTERLEAVE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$INTERLEAVE_SID" >/dev/null \
  || fail "the re-armed source did not capture a later delta"
INTERLEAVE_RESULT_TWO="$PARENT/state/procevent-inbox/$INTERLEAVE_SID.2.result"
assert_grep 'from_offset=' "$INTERLEAVE_RESULT_TWO" \
  "the second capture did not include a committed starting offset"
interleave_payload_boundary=$(grep -n -m 1 '^$' "$INTERLEAVE_RESULT_TWO" | cut -d: -f1)
tail -n "+$((interleave_payload_boundary + 1))" "$INTERLEAVE_RESULT_TWO" \
  | grep -F -q 'third interleaved reply' \
  || fail "the second capture did not begin after the committed cursor"
if tail -n "+$((interleave_payload_boundary + 1))" "$INTERLEAVE_RESULT_TWO" \
  | grep -F -q 'first interleaved reply'; then
  fail "the second capture replayed bytes from the rejected delta"
fi
pass "uncorrelated lines are skipped while correlated replies ingest and the cursor advances"

# Correlated UTF-8 status text must ingest without rejecting the whole delta.
printf 'working [corr=dddddddddddddddd]: reviewer\xe2\x80\x99s note complete\n' \
  > "$REMOTE_UTF8/state/parent-replies.status"
UTF8_SID=$(remote_env "$ADAPTER" source-id utf8)
remote_env "$ADAPTER" arm utf8 >/dev/null \
  || fail "could not arm the utf8 reply fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$UTF8_SID" >/dev/null \
  || fail "utf8 reply fixture was not captured"
UTF8_RESULT="$PARENT/state/procevent-inbox/$UTF8_SID.1.result"
utf8_out=$(remote_env "$ADAPTER" handle utf8 1 "$UTF8_RESULT") \
  || fail "valid correlated UTF-8 status text was rejected"
assert_contains "$utf8_out" 'ingested: utf8 appended=1' \
  "utf8 correlated line was not ingested"
assert_grep 'reviewer' "$PARENT/state/utf8.status" \
  "utf8 status note did not reach the parent status channel"
UTF8_OFFSET=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/utf8.cursor")
[ "$UTF8_OFFSET" -gt 0 ] \
  || fail "utf8 ingest did not advance the cursor"
pass "correlated UTF-8 status text ingests and advances the cursor"

# Non-printable bytes still reject the delta at the public ingest boundary.
# Each crafted delta continues the live utf8 cursor so the failure is the
# status-line validation, not cursor continuity.
craft_utf8_delta() { # <payload-file> <destination>
  local payload=$1 destination=$2 boundary bytes hash from_offset from_hash
  cp "$UTF8_RESULT" "$destination"
  boundary=$(grep -n -m 1 '^$' "$destination" | cut -d: -f1)
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(sha256_file "$payload")
  from_offset=$(sed -n 's/^to_offset=//p' "$UTF8_RESULT")
  from_hash=$(sed -n 's/^to_prefix_sha256=//p' "$UTF8_RESULT")
  head -n "$boundary" "$destination" \
    | sed "s/^payload_sha256=.*/payload_sha256=$hash/;s/^payload_bytes=.*/payload_bytes=$bytes/;s/^from_offset=.*/from_offset=$from_offset/;s/^from_prefix_sha256=.*/from_prefix_sha256=$from_hash/;s/^to_offset=.*/to_offset=$((from_offset + bytes))/" \
    > "$destination.header"
  cat "$destination.header" "$payload" > "$destination"
  rm -f "$destination.header"
}
printf 'working [corr=eeeeeeeeeeeeeeee]: bad \xff byte\n' > "$TMP_ROOT/invalid-utf8.payload"
printf 'working [corr=eeeeeeeeeeeeeeee]: trailing return\r\n' > "$TMP_ROOT/carriage-return.payload"
printf 'working [corr=eeeeeeeeeeeeeeee]: \xc2\x9b31mtinted note\n' > "$TMP_ROOT/c1-control.payload"
for bad in invalid-utf8 carriage-return c1-control; do
  craft_utf8_delta "$TMP_ROOT/$bad.payload" "$TMP_ROOT/$bad.result"
  set +e
  bad_out=$(remote_env "$ADAPTER" ingest utf8 "$TMP_ROOT/$bad.result" 2>&1)
  bad_rc=$?
  set -e
  [ "$bad_rc" -ne 0 ] || fail "ingest accepted a $bad status line"
  assert_contains "$bad_out" 'invalid status line' \
    "$bad delta was not rejected by status-line validation"
done
assert_grep "offset=$UTF8_OFFSET" "$PARENT/state/remote-replies/utf8.cursor" \
  "a rejected non-printable delta moved the cursor"
pass "ingest rejects invalid UTF-8, carriage-return, and C1-control status lines"

# After a rejected delta, rebase can advance the cursor without duplicating bytes.
printf 'done [corr=ffffffffffffffff]: second utf8 reply\n' \
  >> "$REMOTE_UTF8/state/parent-replies.status"
remote_env "$ADAPTER" arm utf8 >/dev/null \
  || fail "could not re-arm the utf8 fixture for rebase recovery"
remote_env "$ROOT/bin/fm-procevent.sh" start "$UTF8_SID" >/dev/null \
  || fail "utf8 second capture was not recorded"
UTF8_RESULT_TWO="$PARENT/state/procevent-inbox/$UTF8_SID.2.result"
rebase_offset=$(sed -n 's/^to_offset=//p' "$UTF8_RESULT_TWO")
rebase_hash=$(sed -n 's/^to_prefix_sha256=//p' "$UTF8_RESULT_TWO")
[ -n "$rebase_offset" ] && [ -n "$rebase_hash" ] \
  || fail "utf8 second capture did not record its committed cursor"
printf 'done [corr=1010101010101010]: third utf8 reply\n' \
  >> "$REMOTE_UTF8/state/parent-replies.status"
remote_env "$ADAPTER" rebase utf8 "$rebase_offset" "$rebase_hash" >/dev/null \
  || fail "cursor rebase could not recover past a rejected delta on a grown log"
assert_grep "offset=$rebase_offset" "$PARENT/state/remote-replies/utf8.cursor" \
  "cursor rebase did not commit the validated offset"
utf8_handle_two=$(remote_env "$ADAPTER" handle utf8 2 "$UTF8_RESULT_TWO") \
  || fail "rebased cursor could not acknowledge the captured generation"
assert_contains "$utf8_handle_two" 'ingested: utf8 appended=1' \
  "post-rebase handle did not ingest the skipped correlated line once"
[ "$(grep -cF 'second utf8 reply' "$PARENT/state/utf8.status")" -eq 1 ] \
  || fail "post-rebase handle duplicated the recovered status line"
remote_env "$ROOT/bin/fm-procevent.sh" start "$UTF8_SID" >/dev/null \
  || fail "utf8 source did not capture after cursor rebase"
UTF8_RESULT_THREE="$PARENT/state/procevent-inbox/$UTF8_SID.3.result"
utf8_payload_boundary=$(grep -n -m 1 '^$' "$UTF8_RESULT_THREE" | cut -d: -f1)
tail -n "+$((utf8_payload_boundary + 1))" "$UTF8_RESULT_THREE" \
  | grep -F -q 'third utf8 reply' \
  || fail "post-rebase capture did not begin after the rebased cursor"
if tail -n "+$((utf8_payload_boundary + 1))" "$UTF8_RESULT_THREE" \
  | grep -F -q 'second utf8 reply'; then
  fail "post-rebase capture replayed bytes from the rebased delta"
fi
pass "cursor rebase recovers a rejected delta without replaying committed bytes"

INTERLEAVE_HASH=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/interleave.cursor")
EMPTY_PREFIX_HASH=$(sha256_file /dev/null)
cp "$PARENT/state/remote-replies/interleave.cursor" "$TMP_ROOT/interleave-cursor.before"
BOGUS_HASH=$(printf '%sa' "${INTERLEAVE_HASH%?}")
set +e
bogus_out=$(remote_env "$ADAPTER" rebase interleave "$INTERLEAVE_OFFSET" "$BOGUS_HASH" 2>&1)
bogus_rc=$?
set -e
[ "$bogus_rc" -ne 0 ] || fail "rebase accepted a bogus prefix hash"
assert_contains "$bogus_out" 'prefix hash does not match' \
  "wrong-hash rebase did not explain the refusal"
cmp -s "$TMP_ROOT/interleave-cursor.before" "$PARENT/state/remote-replies/interleave.cursor" \
  || fail "wrong-hash rebase changed the cursor"
REMOTE_LOG_SIZE=$(LC_ALL=C wc -c < "$REMOTE_INTERLEAVE/state/parent-replies.status" | tr -d ' ')
PAST_END=$((REMOTE_LOG_SIZE + 10))
set +e
past_out=$(remote_env "$ADAPTER" rebase interleave "$PAST_END" "$EMPTY_PREFIX_HASH" 2>&1)
past_rc=$?
set -e
[ "$past_rc" -ne 0 ] || fail "rebase accepted an offset past the remote log end"
assert_contains "$past_out" 'prefix could not be validated' \
  "past-end rebase did not explain the refusal"
cmp -s "$TMP_ROOT/interleave-cursor.before" "$PARENT/state/remote-replies/interleave.cursor" \
  || fail "past-end rebase changed the cursor"
pass "rebase refuses wrong-hash and past-end offsets without moving the cursor"

remote_env "$ADAPTER" rebase interleave 0 "$EMPTY_PREFIX_HASH" >/dev/null \
  || fail "cursor rebase to offset zero was rejected"
assert_grep 'offset=0' "$PARENT/state/remote-replies/interleave.cursor" \
  "zero-offset rebase did not commit the empty cursor"
pass "cursor rebase validates offset zero against the empty prefix"

# A digest-valid but uncorrelated line is still rejected at the public ingest
# boundary. Recalculate its payload commitment so the behavioral assertion is
# specifically about status validation, not incidental digest failure.
BAD_RESULT="$TMP_ROOT/bad.result"
cp "$RESULT" "$BAD_RESULT"
boundary=$(grep -n -m 1 '^$' "$BAD_RESULT" | cut -d: -f1)
tail -n "+$((boundary + 1))" "$BAD_RESULT" \
  | sed 's/corr=0123456789abcdef/no-correlation/' > "$TMP_ROOT/bad.payload"
bad_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/bad.payload" | tr -d ' ')
bad_hash=$(sha256_file "$TMP_ROOT/bad.payload")
head -n "$boundary" "$BAD_RESULT" \
  | sed "s/^payload_sha256=.*/payload_sha256=$bad_hash/;s/^payload_bytes=.*/payload_bytes=$bad_bytes/" \
  > "$TMP_ROOT/bad.header"
cat "$TMP_ROOT/bad.header" "$TMP_ROOT/bad.payload" > "$BAD_RESULT"
if remote_env "$ADAPTER" ingest ios "$BAD_RESULT" >/dev/null 2>&1; then
  fail "ingest accepted a status line with no correlation token"
fi
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "invalid ingest disturbed the accepted parent status line"
pass "ingest rejects uncorrelated payload even when its transport digest is valid"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_FOUR=$(find "$PARENT/state/procevent-inbox" -name "$SID.4.result" -print -quit)
[ -n "$RESULT_FOUR" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_FOUR")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" > "$TMP_ROOT/handle-four.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$RESULT_FOUR" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.4.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
pass "remote reply retirement quiesces and refuses unhandled captured results"

# Documented two-bracket keyed/correlated resolved lines must ingest. A single
# optional bracket group rejected this shape and refused the whole remote delta.
printf 'resolved [key=work-slug] [corr=cafebabef00d1234]: keyed correlated result\n' \
  > "$REMOTE_KEYED/state/parent-replies.status"
KEYED_SID=$(remote_env "$ADAPTER" source-id keyed)
remote_env "$ADAPTER" arm keyed >/dev/null \
  || fail "could not arm the keyed reply fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$KEYED_SID" >/dev/null \
  || fail "keyed reply fixture was not captured"
KEYED_RESULT="$PARENT/state/procevent-inbox/$KEYED_SID.1.result"
keyed_out=$(remote_env "$ADAPTER" handle keyed 1 "$KEYED_RESULT") \
  || fail "a two-bracket keyed correlated resolved line was rejected"
assert_contains "$keyed_out" 'ingested: keyed appended=1' \
  "keyed correlated resolved line was not ingested"
assert_grep 'resolved [key=work-slug] [corr=cafebabef00d1234]: keyed correlated result' \
  "$PARENT/state/keyed.status" \
  "keyed correlated resolved line did not reach the parent status channel"
KEYED_OFFSET=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/keyed.cursor")
[ "$KEYED_OFFSET" -gt 0 ] \
  || fail "keyed ingest did not advance the cursor"
pass "a two-bracket keyed correlated resolved line ingests and advances the cursor"

# Extra bracket groups still have to be well-formed. Empty or malformed groups
# must keep failing at the public ingest boundary so repeating `[]` does not
# weaken the existing validator.
craft_keyed_delta() { # <payload-file> <destination>
  local payload=$1 destination=$2 boundary bytes hash from_offset from_hash
  cp "$KEYED_RESULT" "$destination"
  boundary=$(grep -n -m 1 '^$' "$destination" | cut -d: -f1)
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(sha256_file "$payload")
  from_offset=$(sed -n 's/^to_offset=//p' "$KEYED_RESULT")
  from_hash=$(sed -n 's/^to_prefix_sha256=//p' "$KEYED_RESULT")
  head -n "$boundary" "$destination" \
    | sed "s/^payload_sha256=.*/payload_sha256=$hash/;s/^payload_bytes=.*/payload_bytes=$bytes/;s/^from_offset=.*/from_offset=$from_offset/;s/^from_prefix_sha256=.*/from_prefix_sha256=$from_hash/;s/^to_offset=.*/to_offset=$((from_offset + bytes))/" \
    > "$destination.header"
  cat "$destination.header" "$payload" > "$destination"
  rm -f "$destination.header"
}
printf 'resolved [key=work-slug] [] [corr=cafebabef00d9999]: empty extra group\n' \
  > "$TMP_ROOT/empty-extra.payload"
printf 'resolved [key=work-slug] [corr=cafebabef00d9999] [unclosed: missing closer\n' \
  > "$TMP_ROOT/unclosed-extra.payload"
printf 'resolved [key=work-slug][corr=cafebabef00d9999]: adjacent groups\n' \
  > "$TMP_ROOT/adjacent-groups.payload"
for bad in empty-extra unclosed-extra adjacent-groups; do
  craft_keyed_delta "$TMP_ROOT/$bad.payload" "$TMP_ROOT/$bad.result"
  set +e
  bad_out=$(remote_env "$ADAPTER" ingest keyed "$TMP_ROOT/$bad.result" 2>&1)
  bad_rc=$?
  set -e
  [ "$bad_rc" -ne 0 ] || fail "ingest accepted a $bad status line"
  assert_contains "$bad_out" 'invalid status line' \
    "$bad delta was not rejected by status-line validation"
done
assert_grep "offset=$KEYED_OFFSET" "$PARENT/state/remote-replies/keyed.cursor" \
  "a rejected extra-bracket delta moved the cursor"
pass "ingest still rejects empty, unclosed, and adjacent extra bracket groups"

echo "ALL TESTS PASSED"

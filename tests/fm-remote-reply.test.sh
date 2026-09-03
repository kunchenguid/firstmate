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
REMOTE_MIXED="$TMP_ROOT/remote-mixed"
REMOTE_STARVE="$TMP_ROOT/remote-starve"
REMOTE_HELPER="$TMP_ROOT/remote-helper"
REMOTE_SEQ122="$TMP_ROOT/remote-seq122"
REMOTE_REVIEWER="$TMP_ROOT/remote-reviewer"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" \
  "$REMOTE_INTERLEAVE/state" "$REMOTE_INTERLEAVE/data" "$REMOTE_UTF8/state" \
  "$REMOTE_KEYED/state" "$REMOTE_MIXED/state" "$REMOTE_MIXED/data/reply" \
  "$REMOTE_STARVE/state" "$REMOTE_STARVE/data" \
  "$REMOTE_HELPER/state" "$REMOTE_HELPER/data" \
  "$REMOTE_SEQ122/state" "$REMOTE_SEQ122/data" \
  "$REMOTE_REVIEWER/state" "$REMOTE_REVIEWER/data/review" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
- interleave - interleaved reply fixture (host: remote-interleave; root: $ROOT; home: $REMOTE_INTERLEAVE; scope: test; projects: alpha; added 2026-08-02)
- utf8 - utf8 reply fixture (host: remote-utf8; root: $ROOT; home: $REMOTE_UTF8; scope: test; projects: alpha; added 2026-08-02)
- keyed - keyed reply fixture (host: remote-keyed; root: $ROOT; home: $REMOTE_KEYED; scope: test; projects: alpha; added 2026-08-20)
- mixed - mixed reply fixture (host: remote-mixed; root: $ROOT; home: $REMOTE_MIXED; scope: test; projects: alpha; added 2026-08-21)
- seq122 - sequence 122 reply fixture (host: remote-seq122; root: $ROOT; home: $REMOTE_SEQ122; scope: test; projects: alpha; added 2026-08-21)
- reviewer - reviewer reply fixture (host: remote-reviewer; root: $ROOT; home: $REMOTE_REVIEWER; scope: review; projects: alpha; added 2026-08-21)
- starve - starvation matrix reply fixture (host: remote-starve; root: $ROOT; home: $REMOTE_STARVE; scope: test; projects: alpha; added 2026-08-27)
- helper - producer-helper composition fixture (host: remote-helper; root: $ROOT; home: $REMOTE_HELPER; scope: test; projects: alpha; added 2026-08-27)
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
  case "$host" in remote-mac|remote-interleave|remote-utf8|remote-keyed|remote-mixed|remote-seq122|remote-reviewer|remote-starve|remote-helper) ;;
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

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
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
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue"; then
  fail "an automatically handled remote reply still published a duplicate check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" && fail "the mirrored reply bytes are not visible to the watcher signal scan"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" \
  "the captured reply was not applied to the parent status stream at capture"
assert_present "$PARENT/state/procevent-inbox/$SID.1.handled" \
  "the applied capture was left unacknowledged"
assert_present "$PARENT/state/procevent/$SID.source" \
  "applying the capture left the relay unarmed for the next delta"
pass "a captured delta is applied, acknowledged, and re-armed without a handler"

rm -f "$PARENT/state/procevent-inbox/$SID.1.handled"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=0' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not replay the committed reply"
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

# Generation 2 keeps an uncorrelated progress line adjacent to a current
# correlated reply, preserving the fork's mixed-delta coverage without
# interrupting the runner's re-armed source lifecycle.
printf 'working [key=legacy-prefix]: legacy remote prefix\n' \
  >> "$REMOTE/state/parent-replies.status"
printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
assert_grep 'working [key=legacy-prefix]: legacy remote prefix' "$PARENT/state/ios.status" \
  "legacy prefix was not preserved while ingesting the correlated reply"
printf 'working [key=legacy-prefix]: legacy remote prefix\n' > "$TMP_ROOT/expected-legacy-prefix"
grep -F -x 'working [key=legacy-prefix]: legacy remote prefix' "$PARENT/state/ios.status" \
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
assert_contains "$interleave_out" 'ingested: interleave appended=0' \
  "automatic interleaved ingest was not replay-idempotent"
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

# The primary stream also accepts local progress and decision lines next to a
# correlated answer, then advances its cursor over the entire mixed delta.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
PENDING_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'audit the release chain')
[ -n "$PENDING_CORR" ] || fail "could not create the parent pending-reply record"
fm_pending_reply_mark_delivered "$PARENT/state" "$PENDING_CORR" \
  || fail "could not mark the pending-reply request delivered"
{

  printf 'working [key=version-audit]: family --version audit complete (data/reply/report.md)\n'
  printf 'needs-decision [key=rough-cut-version]: implement --version or retire the tool\n'
  printf 'done [corr=%s]: release chain audited\n' "$PENDING_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the mirrored status stream was not captured"
RESULT_FOUR="$PARENT/state/procevent-inbox/$SID.4.result"
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" > "$TMP_ROOT/handle-mirror.out" 2>&1 \
  || fail "an uncorrelated status line stopped the delta: $(cat "$TMP_ROOT/handle-mirror.out")"
assert_grep 'working [key=version-audit]' "$PARENT/state/ios.status" "an uncorrelated progress line never reached the parent stream"
assert_grep 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status" "a newly raised remote decision never reached the parent stream"
assert_grep "done [corr=$PENDING_CORR]" "$PARENT/state/ios.status" "the correlated answer sharing the delta was lost"
mirror_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past an uncorrelated line"
pass "the remote status and decision model mirrors and the cursor advances"

# The newly raised decision must be indistinguishable from a local mate's, so the
# shared fold - not this adapter - decides it is open.
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
OPEN=$(status_open_decisions "$PARENT/state/ios.status")
printf '%s' "$OPEN" | grep -q '^rough-cut-version	needs-decision	' \
  || fail "the remote mate's new decision did not surface as open to the parent: $OPEN"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$PENDING_CORR" phase)" = resolved ] \
  || fail "the correlated answer in the same delta did not settle its pending-reply record"
pass "a remote mate's new decision folds open exactly as a local mate's does"

# Ingesting the same generation again is idempotent: no duplicated lines and no
# cursor movement, so a replay can never wedge or double-count the stream.
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" >/dev/null 2>&1 || true
[ "$(grep -cF 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replaying the mirrored delta duplicated the new decision"
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "replaying the mirrored delta moved the cursor"
pass "a replayed mirrored delta is idempotent in both the stream and the cursor"

# Bytes crossing a machine boundary are normalized, never dropped: a control
# character cannot make the parent's status file unsafe and cannot stop the
# stream either.
printf 'blocked [key=ctl]: escape \033[31mhere\033[0m bell \007 caf\xc3\xa9 end\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the control-character line was not captured"
RESULT_FIVE="$PARENT/state/procevent-inbox/$SID.5.result"
remote_env "$ADAPTER" handle ios 5 "$RESULT_FIVE" >/dev/null 2>&1 \
  || fail "a control character stopped the stream"
assert_grep 'blocked [key=ctl]: escape ?[31mhere' "$PARENT/state/ios.status" \
  "the control-character line was not mirrored in normalized form"
[ -z "$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$PARENT/state/ios.status")" ] \
  || fail "a control byte reached the parent status file"
assert_grep "$(printf 'caf\xc3\xa9 end')" "$PARENT/state/ios.status" \
  "normalization mangled a UTF-8 note a local secondmate could have written"
ctl_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$ctl_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a control-character line"
pass "transported control bytes are normalized in place and never stop the stream"

printf 'status=delta\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the header-collision line was not captured"
RESULT_SIX="$PARENT/state/procevent-inbox/$SID.6.result"
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" >/dev/null 2>&1 \
  || fail "a payload protocol-field name stopped the stream"
assert_grep 'status=delta' "$PARENT/state/ios.status" \
  "the payload protocol-field line did not reach the parent stream"
collision_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$collision_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a payload protocol-field line"
pass "payload protocol-field names cannot collide with transport metadata"

printf 'working [key=nul-byte]: before\000after\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the NUL-bearing line was not captured"
RESULT_SEVEN="$PARENT/state/procevent-inbox/$SID.7.result"
remote_env "$ADAPTER" handle ios 7 "$RESULT_SEVEN" >/dev/null 2>&1 \
  || fail "a NUL byte stopped the stream"
assert_grep 'working [key=nul-byte]: before?after' "$PARENT/state/ios.status" \
  "the NUL byte was not normalized in place"
nul_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$nul_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a NUL-bearing line"
pass "NUL bytes are normalized in place before shell line processing"

printf '# Retryable remote answer\n' > "$REMOTE/data/reply/retry.md"
printf 'done [key=retry-document]: retry local storage (data/reply/retry.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
# Obstruct local document storage BEFORE the capture, so the runner's own
# automatic application fails for real. That is the documented fallback: a
# capture whose application does not complete stays unacknowledged and
# uncommitted, and the handler finishes it once storage recovers.
retry_destination="$PARENT/data/remote-secondmates/ios/data/reply/retry.md"
retry_decoy="$TMP_ROOT/retry-decoy.md"
printf 'local decoy\n' > "$retry_decoy"
ln -s "$retry_decoy" "$retry_destination"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the retryable document line was not captured"
RESULT_EIGHT="$PARENT/state/procevent-inbox/$SID.8.result"
assert_absent "$PARENT/state/procevent-inbox/$SID.8.handled" \
  "a capture whose automatic application failed was acknowledged anyway"
# The self-announcing declaration never silences a capture the adapter could
# NOT fully apply: this one must still publish its check wake for the handler.
assert_grep "procevent remote-reply $SID 8" "$PARENT/state/.wake-queue" \
  "a not-fully-applied capture lost its check-wake announcement"
assert_no_grep 'retry local storage' "$PARENT/state/.wake-queue" \
  "reply payload leaked into the event queue"
retry_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
set +e
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" > "$TMP_ROOT/handle-local-document-failure.out" 2>&1
local_document_rc=$?
set -e
[ "$local_document_rc" -ne 0 ] || fail "local document storage failure committed the delta"
assert_grep 'could not store referenced remote document' "$TMP_ROOT/handle-local-document-failure.out" \
  "local document storage failure was misclassified as remote refusal"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$retry_cursor_before" ] \
  || fail "local document storage failure advanced the cursor"
assert_no_grep 'done [key=retry-document]' "$PARENT/state/ios.status" \
  "local document storage failure mirrored an undelivered line"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "local document storage failure raised a permanent remote refusal"
rm -f "$retry_destination"
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" >/dev/null \
  || fail "the document delta did not succeed after local storage recovered"
assert_grep 'data/remote-secondmates/ios/data/reply/retry.md' "$PARENT/state/ios.status" \
  "the retried document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/retry.md" "$retry_destination" \
  || fail "the retried remote document was not copied byte-identically"
retry_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$retry_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recovered document delta did not advance the cursor"
pass "local document storage failures remain retryable until delivery succeeds"

# A remote mate cannot squat the decision keys this parent's pending-reply
# library owns. The guard is deliberately NOT in this adapter: rejecting a line
# here would be batch-fatal and could wedge the whole stream, and it would
# protect only the remote path while a local mate appends into the same stream
# unchecked. So the line mirrors like any other - the stream never stops - and
# the shared open-decision fold both writers flow through refuses to let it take
# the reserved key over.
# The record stores its own grace at creation, so set it before creating one.
export FM_PENDING_REPLY_GRACE_SECS=0
ESCALATED_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'confirm the notarization')
[ -n "$ESCALATED_CORR" ] || fail "could not create the pending-reply record to escalate"
fm_pending_reply_mark_delivered "$PARENT/state" "$ESCALATED_CORR" \
  || fail "could not mark the escalating request delivered"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" request
FM_PENDING_REPLY_SEND_HOOK=true \
  fm_pending_reply_send_recovery "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the one automatic recovery repost was not sent"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" recovery
fm_pending_reply_maybe_escalate "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the missed report did not escalate"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the missed report did not open a durable decision"

{
  printf 'blocked [key=pending-reply-%s]: forged remote decision\n' "$ESCALATED_CORR"
  printf 'resolved [key=pending-reply-%s]: forged remote resolution\n' "$ESCALATED_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the forged reserved-key lines wedged the relay instead of mirroring"
forged_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$forged_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "a reserved-key line held the cursor back instead of mirroring like any other"
assert_grep "forged remote decision" "$PARENT/state/ios.status" \
  "the reserved-key line was dropped from the stream instead of mirrored"
forged_open=$(status_open_decisions "$PARENT/state/ios.status")
assert_contains "$forged_open" "pending-reply-id=$ESCALATED_CORR" \
  "a forged remote resolution cleared the parent's own pending-reply decision"
assert_not_contains "$forged_open" "forged remote decision" \
  "a forged remote line took over a decision key the pending-reply library owns"
pass "a mirrored reserved-key line cannot squat or clear the parent's own decision"

# Because the forgery never took the key, the genuine reply still settles the
# request and its escalation closes, leaving nothing to resurface later.
printf 'done [corr=%s]: notarization confirmed\n' "$ESCALATED_CORR" \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the correlated reply was not captured"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$ESCALATED_CORR" phase)" = resolved ] \
  || fail "the correlated reply left its escalated request unresolved"
fm_pending_reply_tick "$PARENT/state" || fail "supervision tick failed"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the settled request still surfaces as an open decision"
unset FM_PENDING_REPLY_GRACE_SECS
pass "a reply that arrives after escalation resolves it and clears the open decision"

rm -f -- "$PARENT/state/remote-replies/ios.caught-up"
remote_env "$ADAPTER" source ios > "$TMP_ROOT/preempted-source.out" 2>&1 &
PREEMPTED_SOURCE=$!
running_poll=''
for _ in $(seq 1 100); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_poll=$job
      break 2
    fi
  done
  sleep 0.05
done
[ -n "$running_poll" ] || fail "the reply poll did not begin running before preemption"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-file.sh get data/reply/report.md 262144 >/dev/null
set +e
wait "$PREEMPTED_SOURCE"
preempted_rc=$?
set -e
[ "$preempted_rc" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "the reply poll did not expose remote-job preemption: $preempted_rc"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "a preempted reply poll published a caught-up watermark"
pass "a preempted reply poll cannot publish channel freshness"

# A quiet window is the one moment this channel can prove it is NOT behind, and
# the parent's pending-reply guard needs that proof: a remote report that exists
# but has not been mirrored yet must never be mistaken for a report the mate
# never wrote. The window opened with the log matching the committed cursor, so
# the published watermark is the window's start.
watermark_before=$(date +%s)
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
quiet_rc=$?
set -e
[ "$quiet_rc" -eq 75 ] || fail "a quiet reply window exited with an unexpected status: $quiet_rc"
watermark_after=$(date +%s)
caught_up=$(FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_remote_channel_epoch "$2/state" ios
' _ "$ROOT" "$PARENT")
[ -n "$caught_up" ] || fail "a quiet reply window published no caught-up watermark"
[ "$caught_up" -ge "$watermark_before" ] && [ "$caught_up" -le "$watermark_after" ] \
  || fail "the caught-up watermark ($caught_up) is outside the quiet window"
pass "a quiet reply window publishes the caught-up watermark the reply guard reads"

# The observed already-handled replay class: a lost cursor (an update or
# convergence retire) makes the next armed source recapture the WHOLE remote
# log from offset 0. Every line is already mirrored, so the at-most-once
# append adds no bytes, the adapter acknowledges the generation, and the
# self-announcing runner publishes nothing - the replay stays completely
# quiet, observed through the same seen-signature gate the watcher consumes.
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_status_mark_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "could not prime the seen marker for the replay leg"
cp "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-replay"
mv "$PARENT/state/.wake-queue" "$TMP_ROOT/wake-queue-before-replay" 2>/dev/null || true
rm -f "$PARENT/state/remote-replies/ios.cursor"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the cursor-loss recapture was not captured"
assert_present "$PARENT/state/procevent-inbox/$SID.11.handled" \
  "the whole-log recapture was not acknowledged by the adapter"
cmp -s "$TMP_ROOT/ios-status-before-replay" "$PARENT/state/ios.status" \
  || fail "the whole-log recapture duplicated already-mirrored lines"
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 11" "$PARENT/state/.wake-queue"; then
  fail "an already-mirrored recapture still published a check wake"
fi
INTERLEAVE_QUARANTINE="$PARENT/state/remote-replies/quarantine/interleave"
[ "$(grep -l '^reason=missing-correlation$' "$INTERLEAVE_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "uncorrelated interleaved line lacks stable private quarantine evidence"
pass "uncorrelated lines are quarantined while correlated replies ingest and the cursor advances"

# One malformed line or unavailable referenced document must be quarantined
# without rejecting valid correlated replies around it.
{
  printf 'working [corr=4141414141414141]: valid before mixed failures\n'
  printf 'not-a-status [corr=4242424242424242]: malformed middle line\n'
  printf 'working [corr=short]: malformed correlation token\n'
  printf 'done: correlation after delimiter [corr=4545454545454545]\n'
  printf 'working [corr=4646464646464646] [note=corr=short]: extra malformed correlation token\n'
  printf 'working [corr=4343434343434343]: unavailable detail data/reply/missing.md\n'
  printf 'done [corr=4444444444444444]: valid after mixed failures\n'
} > "$REMOTE_MIXED/state/parent-replies.status"
MIXED_SID=$(remote_env "$ADAPTER" source-id mixed)
remote_env "$ADAPTER" arm mixed >/dev/null \
  || fail "could not arm the mixed reply fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$MIXED_SID" >/dev/null \
  || fail "mixed reply fixture was not captured"
MIXED_RESULT="$PARENT/state/procevent-inbox/$MIXED_SID.1.result"
mixed_out=$(remote_env "$ADAPTER" handle mixed 1 "$MIXED_RESULT") \
  || fail "one bad mixed-delta line rejected later valid replies"
assert_contains "$mixed_out" 'ingested: mixed appended=0' \
  "automatic mixed ingest was not replay-idempotent"
assert_grep 'valid before mixed failures' "$PARENT/state/mixed.status" \
  "valid line before mixed failures was lost"
assert_grep 'valid after mixed failures' "$PARENT/state/mixed.status" \
  "valid line after mixed failures was lost"
assert_no_grep 'malformed middle line' "$PARENT/state/mixed.status" \
  "malformed status line reached the parent status channel"
assert_no_grep 'malformed correlation token' "$PARENT/state/mixed.status" \
  "line with a malformed correlation token reached the parent status channel"
assert_no_grep 'correlation after delimiter' "$PARENT/state/mixed.status" \
  "line with a post-delimiter correlation reached the parent status channel"
assert_no_grep 'extra malformed correlation token' "$PARENT/state/mixed.status" \
  "line with multiple correlation tokens reached the parent status channel"
assert_no_grep 'unavailable detail' "$PARENT/state/mixed.status" \
  "line with an unavailable document reached the parent status channel"
assert_not_contains "$mixed_out" 'malformed middle line' \
  "quarantined status content leaked through command output"
assert_not_contains "$mixed_out" 'data/reply/missing.md' \
  "quarantined document-reference content leaked through command output"
MIXED_QUARANTINE="$PARENT/state/remote-replies/quarantine/mixed"
[ "$(find "$MIXED_QUARANTINE" -type f -name '*.quarantine' | wc -l | tr -d ' ')" -eq 5 ] \
  || fail "mixed ingest did not preserve exactly five quarantine artifacts"
[ "$(file_mode "$MIXED_QUARANTINE")" = 700 ] \
  || fail "mixed quarantine directory is not private"
for artifact in "$MIXED_QUARANTINE"/*.quarantine; do
  [ "$(file_mode "$artifact")" = 600 ] \
    || fail "mixed quarantine artifact is not private: $artifact"
  assert_grep 'schema=fm-remote-reply-quarantine.v1' "$artifact" \
    "quarantine artifact lacks its schema"
  assert_grep 'secondmate_id=mixed' "$artifact" \
    "quarantine artifact lacks remote-home provenance"
  assert_grep 'source_path=state/parent-replies.status' "$artifact" \
    "quarantine artifact lacks source provenance"
  assert_grep 'result_sha256=' "$artifact" \
    "quarantine artifact lacks captured-result provenance"
  assert_grep 'line_sha256=' "$artifact" \
    "quarantine artifact lacks line integrity evidence"
done
[ "$(grep -l '^reason=invalid-status$' "$MIXED_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "malformed status line lacks a stable quarantine reason"
[ "$(grep -l '^reason=invalid-correlation$' "$MIXED_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "malformed correlation line lacks a stable quarantine reason"
[ "$(grep -l '^reason=referenced-document-unfetchable$' "$MIXED_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "unfetchable document line lacks a stable quarantine reason"
[ "$(grep -lF 'malformed middle line' "$MIXED_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "malformed line bytes are not privately recoverable"
[ "$(grep -lF 'unavailable detail data/reply/missing.md' "$MIXED_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "unfetchable-document line bytes are not privately recoverable"
MIXED_QUARANTINE_LIST="$TMP_ROOT/mixed-quarantine.before"
find "$MIXED_QUARANTINE" -type f -name '*.quarantine' -print | sort > "$MIXED_QUARANTINE_LIST"
remote_env "$ADAPTER" ingest mixed "$MIXED_RESULT" >/dev/null \
  || fail "mixed delta was not restart-idempotent"
find "$MIXED_QUARANTINE" -type f -name '*.quarantine' -print | sort > "$TMP_ROOT/mixed-quarantine.after"
cmp -s "$MIXED_QUARANTINE_LIST" "$TMP_ROOT/mixed-quarantine.after" \
  || fail "mixed delta replay duplicated quarantine evidence"
[ "$(grep -cF 'valid before mixed failures' "$PARENT/state/mixed.status")" -eq 1 ] \
  || fail "mixed delta replay duplicated the first valid line"
[ "$(grep -cF 'valid after mixed failures' "$PARENT/state/mixed.status")" -eq 1 ] \
  || fail "mixed delta replay duplicated the later valid line"
set +e
identity_out=$(remote_env "$ADAPTER" ingest unknown-route "$MIXED_RESULT" 2>&1)
identity_rc=$?
set -e
[ "$identity_rc" -ne 0 ] || fail "ingest accepted a result without a configured remote-home identity"
assert_contains "$identity_out" 'is not a configured remote route' \
  "remote-home identity refusal was not explicit"
assert_absent "$PARENT/state/unknown-route.status" \
  "identity-refused ingest wrote a parent status line"
pass "mixed valid and bad lines ingest independently with private idempotent quarantine evidence"

# Production sequence 122 contained one 15-hex correlation between valid lines.
# Preserve the captured bytes while proving that exact malformed token cannot
# block the later valid line or move onto the accepted parent status channel.
{
  printf 'working [corr=1212121212121212]: valid before sequence 122 defect\n'
  printf 'working [corr=dc9b78419d7c1b6]: malformed 15-hex sequence 122 token\n'
  printf 'done [corr=3434343434343434]: valid after sequence 122 defect\n'
} > "$REMOTE_SEQ122/state/parent-replies.status"
SEQ122_SOURCE="$TMP_ROOT/seq122-source.before"
cp "$REMOTE_SEQ122/state/parent-replies.status" "$SEQ122_SOURCE"
SEQ122_SID=$(remote_env "$ADAPTER" source-id seq122)
remote_env "$ADAPTER" arm seq122 >/dev/null \
  || fail "could not arm the sequence 122 fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SEQ122_SID" >/dev/null \
  || fail "sequence 122 fixture was not captured"
SEQ122_RESULT_ONE="$PARENT/state/procevent-inbox/$SEQ122_SID.1.result"
SEQ122_ADAPTER_ONE="$PARENT/state/procevent-inbox/$SEQ122_SID.1.adapter"
SEQ122_RESULT="$PARENT/state/procevent-inbox/$SEQ122_SID.122.result"
SEQ122_ADAPTER="$PARENT/state/procevent-inbox/$SEQ122_SID.122.adapter"
cp -p "$SEQ122_RESULT_ONE" "$SEQ122_RESULT"
cp -p "$SEQ122_ADAPTER_ONE" "$SEQ122_ADAPTER"
SEQ122_CAPTURE_HASH=$(sha256_file "$SEQ122_RESULT")
seq122_out=$(remote_env "$ADAPTER" autohandle "$SEQ122_SID" 122 "$SEQ122_RESULT") \
  || fail "sequence 122 did not route through the automatic ingest owner"
assert_contains "$seq122_out" 'ingested: seq122 appended=0' \
  "sequence 122 automatic ingest was not replay-idempotent"
assert_grep 'valid before sequence 122 defect' "$PARENT/state/seq122.status" \
  "valid line before the sequence 122 defect was lost"
assert_grep 'valid after sequence 122 defect' "$PARENT/state/seq122.status" \
  "valid line after the sequence 122 defect was lost"
assert_no_grep 'dc9b78419d7c1b6' "$PARENT/state/seq122.status" \
  "15-hex correlation token reached the accepted status channel"
SEQ122_QUARANTINE="$PARENT/state/remote-replies/quarantine/seq122"
[ "$(find "$SEQ122_QUARANTINE" -type f -name '*.quarantine' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "sequence 122 did not retain exactly one quarantine artifact"
SEQ122_ARTIFACT=$(find "$SEQ122_QUARANTINE" -type f -name '*.quarantine' -print -quit)
assert_grep 'reason=invalid-correlation' "$SEQ122_ARTIFACT" \
  "sequence 122 malformed token lacks its stable quarantine reason"
assert_grep 'dc9b78419d7c1b6' "$SEQ122_ARTIFACT" \
  "sequence 122 malformed line is not privately recoverable"
[ "$(sha256_file "$SEQ122_RESULT")" = "$SEQ122_CAPTURE_HASH" ] \
  || fail "sequence 122 dispatch rewrote its append-only capture"
cmp -s "$SEQ122_SOURCE" "$REMOTE_SEQ122/state/parent-replies.status" \
  || fail "sequence 122 dispatch rewrote its append-only remote source"
SEQ122_ARTIFACT_LIST="$TMP_ROOT/seq122-quarantine.before"
find "$SEQ122_QUARANTINE" -type f -name '*.quarantine' -print | sort > "$SEQ122_ARTIFACT_LIST"
seq122_replay=$(remote_env "$ADAPTER" autohandle "$SEQ122_SID" 122 "$SEQ122_RESULT") \
  || fail "sequence 122 replay was not idempotent"
assert_contains "$seq122_replay" 'ingested: seq122 appended=0' \
  "sequence 122 replay repeated an accepted-line effect"
[ "$(grep -cF 'valid before sequence 122 defect' "$PARENT/state/seq122.status")" -eq 1 ] \
  || fail "sequence 122 replay duplicated the first valid line"
[ "$(grep -cF 'valid after sequence 122 defect' "$PARENT/state/seq122.status")" -eq 1 ] \
  || fail "sequence 122 replay duplicated the later valid line"
find "$SEQ122_QUARANTINE" -type f -name '*.quarantine' -print | sort > "$TMP_ROOT/seq122-quarantine.after"
cmp -s "$SEQ122_ARTIFACT_LIST" "$TMP_ROOT/seq122-quarantine.after" \
  || fail "sequence 122 replay duplicated quarantine evidence"
[ "$(sha256_file "$SEQ122_RESULT")" = "$SEQ122_CAPTURE_HASH" ] \
  || fail "sequence 122 replay changed its captured bytes"
pass "sequence 122 quarantines its 15-hex correlation and delivers later valid replies exactly once"

# A reviewer-home result is dispatched from its immutable process-event identity
# into the same remote-reply handler used by every other secondmate. Resolving
# that correlation must win over an already-completed recovery turn.
REVIEWER_CORR=$(FM_PENDING_REPLY_NOW=100 FM_PENDING_REPLY_GRACE_SECS=0 bash -c '
  . "$1"
  corr=$(fm_pending_reply_create "$2" "$2/state" reviewer "review batch") || exit 1
  fm_pending_reply_mark_delivered "$2/state" "$corr" 101 || exit 1
  rec=$(fm_pending_reply_path "$2/state" "$corr")
  fm_pending_reply_set "$rec" phase recovery_sent || exit 1
  fm_pending_reply_set "$rec" recovery_attempted_epoch 102 || exit 1
  fm_pending_reply_set "$rec" recovery_sent_epoch 103 || exit 1
  fm_pending_reply_set "$rec" recovery_delivery_outcome delivered || exit 1
  fm_pending_reply_set "$rec" recovery_turn_seen_busy 1 || exit 1
  fm_pending_reply_set "$rec" recovery_turn_completed_epoch 104 || exit 1
  printf "%s" "$corr"
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT") \
  || fail "could not prepare the reviewer pending-reply fixture"
printf '# Reviewer evidence\n\nThe reviewed head is sound.\n' \
  > "$REMOTE_REVIEWER/data/review/report.md"
printf 'done [corr=%s]: reviewer answer data/review/report.md\n' "$REVIEWER_CORR" \
  > "$REMOTE_REVIEWER/state/parent-replies.status"
REVIEWER_SID=$(remote_env "$ADAPTER" source-id reviewer)
remote_env "$ADAPTER" arm reviewer >/dev/null \
  || fail "could not arm the reviewer reply fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$REVIEWER_SID" >/dev/null \
  || fail "reviewer reply fixture was not captured"
REVIEWER_RESULT="$PARENT/state/procevent-inbox/$REVIEWER_SID.1.result"
assert_grep "done [corr=$REVIEWER_CORR]" "$REVIEWER_RESULT" \
  "captured reviewer generation lost its correlated answer"
assert_present "$PARENT/state/procevent-inbox/$REVIEWER_SID.1.handled" \
  "captured reviewer answer was not applied automatically"
reviewer_dispatch=$(remote_env "$ADAPTER" autohandle "$REVIEWER_SID" 1 "$REVIEWER_RESULT") \
  || fail "captured reviewer answer did not replay through its recorded adapter"
assert_contains "$reviewer_dispatch" 'ingested: reviewer appended=0' \
  "reviewer automatic ingest was not replay-idempotent"
assert_grep "done [corr=$REVIEWER_CORR]: reviewer answer data/remote-secondmates/reviewer/data/review/report.md" \
  "$PARENT/state/reviewer.status" \
  "reviewer answer did not reach its parent status channel"
cmp -s "$REMOTE_REVIEWER/data/review/report.md" \
  "$PARENT/data/remote-secondmates/reviewer/data/review/report.md" \
  || fail "reviewer document did not retain byte integrity"
REVIEWER_PENDING="$PARENT/state/pending-replies/$REVIEWER_CORR"
assert_grep 'phase=resolved' "$REVIEWER_PENDING" \
  "delivered reviewer correlation did not resolve its pending expectation"
cat > "$TMP_ROOT/reviewer-recovery-hook" <<'SH'
#!/usr/bin/env bash
printf 'unexpected recovery\n' >> "$FM_REVIEWER_RECOVERY_LOG"
SH
chmod +x "$TMP_ROOT/reviewer-recovery-hook"
FM_REVIEWER_RECOVERY_LOG="$TMP_ROOT/reviewer-recovery.log" \
FM_PENDING_REPLY_SEND_HOOK="$TMP_ROOT/reviewer-recovery-hook" \
FM_PENDING_REPLY_NOW=200 FM_PENDING_REPLY_GRACE_SECS=0 \
  bash -c '. "$1"; fm_pending_reply_tick "$2"' \
  _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT/state" >/dev/null \
  || fail "pending-reply tick failed after reviewer delivery"
assert_absent "$TMP_ROOT/reviewer-recovery.log" \
  "resolved reviewer answer triggered a false recovery"
assert_no_grep 'pending-reply-missed' "$PARENT/state/reviewer.status" \
  "resolved reviewer answer false-escalated as a missed reply"
reviewer_replay=$(remote_env "$ADAPTER" autohandle "$REVIEWER_SID" 1 "$REVIEWER_RESULT") \
  || fail "reviewer process-event replay was not idempotent"
assert_contains "$reviewer_replay" 'ingested: reviewer appended=0' \
  "reviewer replay repeated its parent status effect"
[ "$(grep -cF "done [corr=$REVIEWER_CORR]" "$PARENT/state/reviewer.status")" -eq 1 ] \
  || fail "reviewer dispatch duplicated its correlated answer"
pass "reviewer process-event dispatch resolves correlation and suppresses false missed-reply escalation"

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
assert_contains "$utf8_out" 'ingested: utf8 appended=0' \
  "automatic utf8 ingest was not replay-idempotent"
assert_grep 'reviewer' "$PARENT/state/utf8.status" \
  "utf8 status note did not reach the parent status channel"
UTF8_OFFSET=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/utf8.cursor")
[ "$UTF8_OFFSET" -gt 0 ] \
  || fail "utf8 ingest did not advance the cursor"
pass "correlated UTF-8 status text ingests and advances the cursor"

# Non-printable lines remain invalid, but each is quarantined independently so
# a valid line in the same captured delta can still ingest.
{
  printf 'working [corr=eeeeeeeeeeeeeeee]: bad \xff byte\n'
  printf 'working [corr=eeeeeeeeeeeeeeee]: trailing return\r\n'
  printf 'working [corr=eeeeeeeeeeeeeeee]: \xc2\x9b31mtinted note\n'
  printf 'done [corr=ffffffffffffffff]: second utf8 reply\n'
} >> "$REMOTE_UTF8/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$UTF8_SID" >/dev/null \
  || fail "utf8 mixed-validity capture was not recorded"
UTF8_RESULT_TWO="$PARENT/state/procevent-inbox/$UTF8_SID.2.result"
rebase_offset=$(LC_ALL=C sed -n 's/^to_offset=//p' "$UTF8_RESULT_TWO")
rebase_hash=$(LC_ALL=C sed -n 's/^to_prefix_sha256=//p' "$UTF8_RESULT_TWO")
[ -n "$rebase_offset" ] && [ -n "$rebase_hash" ] \
  || fail "utf8 second capture did not record its committed cursor"
printf 'done [corr=1010101010101010]: third utf8 reply\n' \
  >> "$REMOTE_UTF8/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" retire "$UTF8_SID" >/dev/null \
  || fail "could not retire the utf8 source before cursor rebase"
rebase_out=$(remote_env "$ADAPTER" cursor-rebase utf8 "$rebase_offset" "$rebase_hash") \
  || fail "cursor rebase could not select a captured complete-line boundary"
assert_contains "$rebase_out" "from_offset=$rebase_offset" \
  "cursor rebase did not report its prior cursor"
assert_contains "$rebase_out" "to_offset=$rebase_offset" \
  "cursor rebase did not report its target cursor"
assert_grep "offset=$rebase_offset" "$PARENT/state/remote-replies/utf8.cursor" \
  "cursor rebase did not commit the validated offset"
utf8_handle_two=$(remote_env "$ADAPTER" handle utf8 2 "$UTF8_RESULT_TWO") \
  || fail "rebased mixed-validity generation could not be handled"
assert_contains "$utf8_handle_two" 'ingested: utf8 appended=0' \
  "automatic mixed UTF-8 ingest was not replay-idempotent"
[ "$(grep -cF 'second utf8 reply' "$PARENT/state/utf8.status")" -eq 1 ] \
  || fail "mixed UTF-8 generation did not ingest its valid line exactly once"
UTF8_QUARANTINE="$PARENT/state/remote-replies/quarantine/utf8"
[ "$(LC_ALL=C grep -l '^reason=invalid-status$' "$UTF8_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "non-printable lines were not retained as three invalid-status artifacts"
remote_env "$ROOT/bin/fm-procevent.sh" start "$UTF8_SID" >/dev/null \
  || fail "utf8 source did not capture after cursor rebase"
UTF8_RESULT_THREE="$PARENT/state/procevent-inbox/$UTF8_SID.3.result"
utf8_payload_boundary=$(LC_ALL=C grep -n -m 1 '^$' "$UTF8_RESULT_THREE" | cut -d: -f1)
tail -n "+$((utf8_payload_boundary + 1))" "$UTF8_RESULT_THREE" \
  | LC_ALL=C grep -F -q 'third utf8 reply' \
  || fail "post-rebase capture did not begin after the rebased cursor"
if tail -n "+$((utf8_payload_boundary + 1))" "$UTF8_RESULT_THREE" \
  | LC_ALL=C grep -F -q 'second utf8 reply'; then
  fail "post-rebase capture replayed bytes from the rebased delta"
fi
pass "invalid UTF-8 and control lines quarantine while cursor rebase remains inspectable"

remote_env "$ROOT/bin/fm-procevent.sh" retire "$INTERLEAVE_SID" >/dev/null \
  || fail "could not retire the interleaved source before cursor rebase"
INTERLEAVE_HASH=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/interleave.cursor")
EMPTY_PREFIX_HASH=$(sha256_file /dev/null)
cp "$PARENT/state/remote-replies/interleave.cursor" "$TMP_ROOT/interleave-cursor.before"
BOGUS_HASH=$(printf '%sa' "${INTERLEAVE_HASH%?}")
set +e
bogus_out=$(remote_env "$ADAPTER" cursor-rebase interleave "$INTERLEAVE_OFFSET" "$BOGUS_HASH" 2>&1)
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
past_out=$(remote_env "$ADAPTER" cursor-rebase interleave "$PAST_END" "$EMPTY_PREFIX_HASH" 2>&1)
past_rc=$?
set -e
[ "$past_rc" -ne 0 ] || fail "rebase accepted an offset past the remote log end"
assert_contains "$past_out" 'prefix could not be validated' \
  "past-end rebase did not explain the refusal"
cmp -s "$TMP_ROOT/interleave-cursor.before" "$PARENT/state/remote-replies/interleave.cursor" \
  || fail "past-end rebase changed the cursor"
MIDLINE_OFFSET=1
head -c "$MIDLINE_OFFSET" "$REMOTE_INTERLEAVE/state/parent-replies.status" > "$TMP_ROOT/midline-prefix"
MIDLINE_HASH=$(sha256_file "$TMP_ROOT/midline-prefix")
set +e
midline_out=$(remote_env "$ADAPTER" cursor-rebase interleave "$MIDLINE_OFFSET" "$MIDLINE_HASH" 2>&1)
midline_rc=$?
set -e
[ "$midline_rc" -ne 0 ] || fail "cursor rebase accepted a mid-line target"
assert_contains "$midline_out" 'not a complete-line boundary' \
  "mid-line cursor rebase did not explain its ambiguity refusal"
cmp -s "$TMP_ROOT/interleave-cursor.before" "$PARENT/state/remote-replies/interleave.cursor" \
  || fail "mid-line cursor rebase changed the cursor"
remote_env "$ADAPTER" arm interleave >/dev/null \
  || fail "could not arm the cursor-rebase ambiguity fixture"
set +e
armed_out=$(remote_env "$ADAPTER" cursor-rebase interleave 0 "$EMPTY_PREFIX_HASH" 2>&1)
armed_rc=$?
set -e
[ "$armed_rc" -ne 0 ] || fail "cursor rebase accepted a target while its source was armed"
assert_contains "$armed_out" 'ambiguous while the remote reply source is armed' \
  "armed-source cursor rebase did not explain its ambiguity refusal"
remote_env "$ROOT/bin/fm-procevent.sh" retire "$INTERLEAVE_SID" >/dev/null \
  || fail "could not retire the cursor-rebase ambiguity fixture"
pass "cursor rebase refuses wrong-hash, out-of-range, mid-line, and armed targets"

remote_env "$ADAPTER" cursor-rebase interleave 0 "$EMPTY_PREFIX_HASH" >/dev/null \
  || fail "cursor rebase to offset zero was rejected"
assert_grep 'offset=0' "$PARENT/state/remote-replies/interleave.cursor" \
  "zero-offset rebase did not commit the empty cursor"
pass "cursor rebase validates offset zero against the empty prefix"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
CONTINUITY_RESULT=
CONTINUITY_SEQ=0
for candidate in "$PARENT/state/procevent-inbox/$SID".*.result; do
  [ -e "$candidate" ] || continue
  candidate_seq=${candidate%.result}
  candidate_seq=${candidate_seq##*.}
  case "$candidate_seq" in ''|*[!0-9]*) continue ;; esac
  if [ "$candidate_seq" -gt "$CONTINUITY_SEQ" ]; then
    CONTINUITY_SEQ=$candidate_seq
    CONTINUITY_RESULT=$candidate
  fi
done
[ -n "$CONTINUITY_RESULT" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$CONTINUITY_RESULT")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios "$CONTINUITY_SEQ" "$CONTINUITY_RESULT" > "$TMP_ROOT/handle-four.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity replay returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$CONTINUITY_RESULT" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.$CONTINUITY_SEQ.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios "$CONTINUITY_SEQ" "$CONTINUITY_RESULT" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
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
assert_contains "$keyed_out" 'ingested: keyed appended=0' \
  "automatic keyed ingest was not replay-idempotent"
assert_grep 'resolved [key=work-slug] [corr=cafebabef00d1234]: keyed correlated result' \
  "$PARENT/state/keyed.status" \
  "keyed correlated resolved line did not reach the parent status channel"
KEYED_OFFSET=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/keyed.cursor")
[ "$KEYED_OFFSET" -gt 0 ] \
  || fail "keyed ingest did not advance the cursor"
pass "a two-bracket keyed correlated resolved line ingests and advances the cursor"

# Extra bracket groups still have to be well-formed. Empty or malformed groups
# are quarantined rather than accepted, and one cannot block the next line.
{
  printf 'resolved [key=work-slug] [] [corr=cafebabef00d9999]: empty extra group\n'
  printf 'resolved [key=work-slug] [corr=cafebabef00d9999] [unclosed: missing closer\n'
  printf 'resolved [key=work-slug][corr=cafebabef00d9999]: adjacent groups\n'
} >> "$REMOTE_KEYED/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$KEYED_SID" >/dev/null \
  || fail "malformed keyed reply fixture was not captured"
KEYED_RESULT_TWO="$PARENT/state/procevent-inbox/$KEYED_SID.2.result"
keyed_bad_out=$(remote_env "$ADAPTER" handle keyed 2 "$KEYED_RESULT_TWO") \
  || fail "malformed keyed lines blocked completion of their captured delta"
assert_contains "$keyed_bad_out" 'ingested: keyed appended=0' \
  "automatic malformed-key ingest was not replay-idempotent"
assert_no_grep 'empty extra group' "$PARENT/state/keyed.status" \
  "empty extra bracket group was accepted"
assert_no_grep 'missing closer' "$PARENT/state/keyed.status" \
  "unclosed extra bracket group was accepted"
assert_no_grep 'adjacent groups' "$PARENT/state/keyed.status" \
  "adjacent extra bracket groups were accepted"
KEYED_QUARANTINE="$PARENT/state/remote-replies/quarantine/keyed"
[ "$(grep -l '^reason=invalid-status$' "$KEYED_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "malformed keyed lines lack distinct invalid-status evidence"
KEYED_OFFSET_TWO=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/keyed.cursor")
[ "$KEYED_OFFSET_TWO" -gt "$KEYED_OFFSET" ] \
  || fail "quarantined keyed lines did not advance the cursor"
pass "empty, unclosed, and adjacent extra bracket groups remain invalid without wedging ingest"

# --- malformed-token starvation matrix --------------------------------------
#
# One captured delta carrying malformed correlation tokens first, in the middle,
# and last, with valid correlated lines on both sides of each. Before the ingest
# isolation existed, the whole delta was refused at its first malformed line and
# the cursor never moved, so every later valid update in that generation - and
# in every generation after it - stayed invisible. Each assertion below fails if
# that isolation is removed.

new_delivered_pending() { # <task-id> <request-text>; prints the correlation id
  local task=$1 text=$2 corr
  corr=$(bash -c '
    . "$1"
    corr=$(fm_pending_reply_create "$2" "$2/state" "$3" "$4") || exit 1
    fm_pending_reply_mark_delivered "$2/state" "$corr" 101 || exit 1
    printf "%s" "$corr"
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT" "$task" "$text") || return 1
  printf '%s' "$corr"
}

pending_phase() { # <corr>
  sed -n 's/^phase=//p' "$PARENT/state/pending-replies/$1" | tail -1
}

STARVE_CORR_ONE=$(new_delivered_pending starve 'first starvation-matrix request') \
  || fail "could not create the first starvation-matrix expectation"
STARVE_CORR_TWO=$(new_delivered_pending starve 'second starvation-matrix request') \
  || fail "could not create the second starvation-matrix expectation"
STARVE_CORR_THREE=$(new_delivered_pending starve 'third starvation-matrix request') \
  || fail "could not create the third starvation-matrix expectation"

{
  printf 'working [corr=dc9b78419d7c1b6]: malformed first fifteen hex\n'
  printf 'working [corr=%s]: valid after the first malformed line\n' "$STARVE_CORR_ONE"
  printf 'needs-decision [corr=zzzzzzzzzzzzzzzz]: malformed middle nonhex\n'
  printf 'working [corr=%s]: valid between malformed lines\n' "$STARVE_CORR_TWO"
  printf 'blocked [corr=0123456789abcdef0]: malformed middle seventeen hex\n'
  printf 'done [corr=%s]: valid before the last malformed line\n' "$STARVE_CORR_THREE"
  printf 'failed [corr=eeeeeeeeeeeeeee]: malformed last fifteen hex\n'
} > "$REMOTE_STARVE/state/parent-replies.status"
STARVE_SOURCE="$TMP_ROOT/starve-source.before"
cp "$REMOTE_STARVE/state/parent-replies.status" "$STARVE_SOURCE"
STARVE_SID=$(remote_env "$ADAPTER" source-id starve)
remote_env "$ADAPTER" arm starve >/dev/null \
  || fail "could not arm the starvation-matrix fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$STARVE_SID" >/dev/null \
  || fail "starvation-matrix fixture was not captured"
STARVE_RESULT="$PARENT/state/procevent-inbox/$STARVE_SID.1.result"
STARVE_CAPTURE_HASH=$(sha256_file "$STARVE_RESULT")
starve_out=$(remote_env "$ADAPTER" autohandle "$STARVE_SID" 1 "$STARVE_RESULT") \
  || fail "malformed correlation tokens blocked completion of their captured delta"
STARVE_STATUS="$PARENT/state/starve.status"

for expected in \
  "valid after the first malformed line" \
  "valid between malformed lines" \
  "valid before the last malformed line"; do
  [ "$(grep -cF "$expected" "$STARVE_STATUS")" -eq 1 ] \
    || fail "a valid correlated line did not ingest exactly once: $expected"
done
for rejected in \
  "malformed first fifteen hex" \
  "malformed middle nonhex" \
  "malformed middle seventeen hex" \
  "malformed last fifteen hex"; do
  assert_no_grep "$rejected" "$STARVE_STATUS" \
    "a malformed correlation line reached the parent status channel: $rejected"
done
STARVE_ORDER=$(grep -nF 'valid ' "$STARVE_STATUS" | cut -d: -f1 | tr '\n' ' ')
[ "$STARVE_ORDER" = "1 2 3 " ] \
  || fail "valid lines did not keep their source order: $STARVE_ORDER"

for corr in "$STARVE_CORR_ONE" "$STARVE_CORR_TWO" "$STARVE_CORR_THREE"; do
  [ "$(pending_phase "$corr")" = resolved ] \
    || fail "a valid correlated line did not resolve its pending request: $corr"
done

STARVE_QUARANTINE="$PARENT/state/remote-replies/quarantine/starve"
[ "$(find "$STARVE_QUARANTINE" -type f -name '*.quarantine' | wc -l | tr -d ' ')" -eq 4 ] \
  || fail "the starvation matrix did not preserve one artifact per malformed line"
[ "$(grep -l '^reason=invalid-correlation$' "$STARVE_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 4 ] \
  || fail "malformed correlation tokens lack their stable quarantine reason"
STARVE_OFFSET=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/starve.cursor")
STARVE_SOURCE_BYTES=$(LC_ALL=C wc -c < "$REMOTE_STARVE/state/parent-replies.status" | tr -d ' ')
[ "$STARVE_OFFSET" = "$STARVE_SOURCE_BYTES" ] \
  || fail "the cursor did not advance past a delta containing malformed tokens"
cmp -s "$STARVE_SOURCE" "$REMOTE_STARVE/state/parent-replies.status" \
  || fail "the starvation-matrix ingest rewrote its append-only remote source"
[ "$(sha256_file "$STARVE_RESULT")" = "$STARVE_CAPTURE_HASH" ] \
  || fail "the starvation-matrix ingest rewrote its append-only capture"
assert_not_contains "$starve_out" 'malformed' \
  "quarantined line content leaked through command output"
pass "malformed tokens first, middle, and last cannot starve the valid lines around them"

# The quarantine is private evidence, but a dropped reply must not be silently
# invisible: exactly one bounded event announces the generation, carrying no
# line bytes and never entering a task status stream.
starve_notice_rows() {
  grep -cF "remote-reply-quarantine:starve:" "$PARENT/state/.wake-queue" 2>/dev/null || true
}
[ "$(starve_notice_rows)" -eq 1 ] \
  || fail "quarantined lines were not announced exactly once"
assert_no_grep 'malformed first fifteen hex' "$PARENT/state/.wake-queue" \
  "quarantined line bytes leaked into the event queue"
assert_no_grep 'dc9b78419d7c1b6' "$PARENT/state/.wake-queue" \
  "a malformed correlation token leaked into the event queue"
assert_grep 'remote secondmate starve sent 4 reply line(s) that could not be correlated' \
  "$PARENT/state/.wake-queue" \
  "the quarantine announcement did not name its scale"
assert_no_grep 'could not be correlated' "$STARVE_STATUS" \
  "the quarantine announcement entered a task status stream"
STARVE_NOTICE=$(find "$STARVE_QUARANTINE" -type f -name '*.notice' -print -quit)
[ -n "$STARVE_NOTICE" ] \
  || fail "the quarantine announcement left no durable receipt"
assert_grep 'state=notified' "$STARVE_NOTICE" \
  "the quarantine announcement receipt was left unconfirmed"
pass "quarantined lines are announced once on the durable queue and never as status"

# Replaying the same generation, and the same captured bytes under a second
# generation, repeats no effect.
starve_replay=$(remote_env "$ADAPTER" autohandle "$STARVE_SID" 1 "$STARVE_RESULT") \
  || fail "replaying the starvation-matrix generation was not idempotent"
assert_contains "$starve_replay" 'ingested: starve appended=0' \
  "the starvation-matrix replay repeated an accepted-line effect"
STARVE_RESULT_TWO="$PARENT/state/procevent-inbox/$STARVE_SID.7.result"
cp -p "$STARVE_RESULT" "$STARVE_RESULT_TWO"
cp -p "$PARENT/state/procevent-inbox/$STARVE_SID.1.adapter" \
  "$PARENT/state/procevent-inbox/$STARVE_SID.7.adapter"
starve_dup=$(remote_env "$ADAPTER" autohandle "$STARVE_SID" 7 "$STARVE_RESULT_TWO") \
  || fail "a duplicate generation carrying the same bytes was refused"
assert_contains "$starve_dup" 'ingested: starve appended=0' \
  "a duplicate generation repeated an accepted-line effect"
[ "$(find "$STARVE_QUARANTINE" -type f -name '*.quarantine' | wc -l | tr -d ' ')" -eq 4 ] \
  || fail "a duplicate generation duplicated quarantine evidence"
[ "$(starve_notice_rows)" -eq 1 ] \
  || fail "a duplicate generation duplicated the quarantine announcement"
for expected in "valid after the first malformed line" "valid between malformed lines"; do
  [ "$(grep -cF "$expected" "$STARVE_STATUS")" -eq 1 ] \
    || fail "a duplicate generation duplicated a valid line: $expected"
done
pass "a replayed and a duplicated generation repeat no ingest, quarantine, or announcement"

# Crash boundary one: quarantine is durable, the valid effects are not yet.
# Replay must land every valid line exactly once and add no second announcement.
rm -f "$STARVE_STATUS" "$PARENT/state/remote-replies/starve.cursor"
remote_env "$ADAPTER" ingest starve "$STARVE_RESULT" >/dev/null \
  || fail "replay after a crash between quarantine and the valid effects failed"
for expected in \
  "valid after the first malformed line" \
  "valid between malformed lines" \
  "valid before the last malformed line"; do
  [ "$(grep -cF "$expected" "$STARVE_STATUS")" -eq 1 ] \
    || fail "replay after the quarantine boundary lost or duplicated a valid line: $expected"
done
[ "$(find "$STARVE_QUARANTINE" -type f -name '*.quarantine' | wc -l | tr -d ' ')" -eq 4 ] \
  || fail "replay after the quarantine boundary duplicated quarantine evidence"
[ "$(starve_notice_rows)" -eq 1 ] \
  || fail "replay after the quarantine boundary duplicated the quarantine announcement"
[ "$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/starve.cursor")" = "$STARVE_SOURCE_BYTES" ] \
  || fail "replay after the quarantine boundary did not advance the cursor"
pass "a crash between quarantine and the valid effects replays with no lost or repeated effect"

# Crash boundary two: quarantine, announcement, and valid effects are durable,
# the cursor advance is not. Replay must repeat nothing and advance the cursor.
rm -f "$PARENT/state/remote-replies/starve.cursor"
remote_env "$ADAPTER" ingest starve "$STARVE_RESULT" >/dev/null \
  || fail "replay after a crash before the cursor advance failed"
for expected in \
  "valid after the first malformed line" \
  "valid between malformed lines" \
  "valid before the last malformed line"; do
  [ "$(grep -cF "$expected" "$STARVE_STATUS")" -eq 1 ] \
    || fail "replay before the cursor advance duplicated a valid line: $expected"
done
[ "$(find "$STARVE_QUARANTINE" -type f -name '*.quarantine' | wc -l | tr -d ' ')" -eq 4 ] \
  || fail "replay before the cursor advance duplicated quarantine evidence"
[ "$(starve_notice_rows)" -eq 1 ] \
  || fail "replay before the cursor advance duplicated the quarantine announcement"
[ "$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/starve.cursor")" = "$STARVE_SOURCE_BYTES" ] \
  || fail "replay before the cursor advance left the cursor behind"
pass "a crash between the valid effects and the cursor advance replays idempotently"

# Crash boundary three: the announcement was claimed but its completion is
# unproven. The still-queued event, not a second append, settles the claim.
printf 'schema=fm-remote-reply-quarantine-notice.v1\nstate=claimed\nlines=4\nreasons=invalid-correlation\n' \
  > "$STARVE_NOTICE"
rm -f "$PARENT/state/remote-replies/starve.cursor"
remote_env "$ADAPTER" ingest starve "$STARVE_RESULT" >/dev/null \
  || fail "replay after an unproven quarantine announcement failed"
[ "$(starve_notice_rows)" -eq 1 ] \
  || fail "an unproven quarantine announcement was appended a second time"
assert_grep 'state=notified' "$STARVE_NOTICE" \
  "an unproven quarantine announcement was not settled against the queue"
pass "an unproven quarantine announcement settles against the queue without repeating"

printf 'schema=fm-remote-reply-quarantine-notice.v1\nstate=claimed\nlines=4\nreasons=invalid-correlation\n' \
  > "$STARVE_NOTICE"
wake_drain_out=$(remote_env "$ROOT/bin/fm-wake-drain.sh" 2>&1) \
  || fail "the wake drain could not present the quarantine announcement"
wake_ack_through=$(printf '%s\n' "$wake_drain_out" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p' | tail -1)
wake_recovery_generation=$(printf '%s\n' "$wake_drain_out" | sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' | tail -1)
[ -n "$wake_ack_through" ] && [ -n "$wake_recovery_generation" ] \
  || fail "the wake drain did not provide an acknowledgement command"
remote_env "$ROOT/bin/fm-wake-drain.sh" \
  --ack-through "$wake_ack_through" --recovery-generation "$wake_recovery_generation" >/dev/null \
  || fail "the wake drain could not acknowledge the quarantine announcement"
assert_grep 'state=notified' "$STARVE_NOTICE" \
  "acknowledging the quarantine announcement did not confirm its receipt"
[ "$(starve_notice_rows)" -eq 0 ] \
  || fail "the acknowledged quarantine announcement remained queued"
rm -f "$PARENT/state/remote-replies/starve.cursor"
remote_env "$ADAPTER" ingest starve "$STARVE_RESULT" >/dev/null \
  || fail "replay after the quarantine announcement was acknowledged failed"
[ "$(starve_notice_rows)" -eq 0 ] \
  || fail "replay duplicated an acknowledged quarantine announcement"
pass "an acknowledged quarantine announcement remains exactly once after replay"

# --- real composition through the producer helper ---------------------------
#
# The optional report helper is the producer, the runner is the capture, and the
# adapter owns quarantine, correlation resolution, and the cursor. Drive all of
# them together: the helper refuses the malformed token outright, a hand-written
# malformed line is quarantined, and the helper-written lines still land.

HELPER_CORR_ONE=$(new_delivered_pending helper 'first helper request') \
  || fail "could not create the first helper expectation"
HELPER_CORR_TWO=$(new_delivered_pending helper 'second helper request') \
  || fail "could not create the second helper expectation"
HELPER_LOG="$REMOTE_HELPER/state/parent-replies.status"

"$ROOT/bin/fm-secondmate-report.sh" "$HELPER_LOG" working "$HELPER_CORR_ONE" 'helper reply before the defect' \
  || fail "the report helper refused a valid correlation"
set +e
helper_refusal=$("$ROOT/bin/fm-secondmate-report.sh" "$HELPER_LOG" 'done' dc9b78419d7c1b6 'helper reply with a bad token' 2>&1)
helper_refusal_rc=$?
set -e
[ "$helper_refusal_rc" -ne 0 ] \
  || fail "the report helper appended a malformed correlation into the reply log"
assert_contains "$helper_refusal" 'corr_id must be 16 hex characters' \
  "the report helper refusal did not name the correlation shape"
assert_no_grep 'helper reply with a bad token' "$HELPER_LOG" \
  "a refused helper report still reached the append-only reply log"
printf 'done [corr=dc9b78419d7c1b6]: hand written reply with a bad token\n' >> "$HELPER_LOG"
"$ROOT/bin/fm-secondmate-report.sh" "$HELPER_LOG" 'done' "$HELPER_CORR_TWO" 'helper reply after the defect' \
  || fail "the report helper refused the second valid correlation"

HELPER_SID=$(remote_env "$ADAPTER" source-id helper)
remote_env "$ADAPTER" arm helper >/dev/null \
  || fail "could not arm the producer-helper fixture"
remote_env "$ROOT/bin/fm-procevent.sh" start "$HELPER_SID" >/dev/null \
  || fail "producer-helper fixture was not captured"
HELPER_RESULT="$PARENT/state/procevent-inbox/$HELPER_SID.1.result"
remote_env "$ADAPTER" autohandle "$HELPER_SID" 1 "$HELPER_RESULT" >/dev/null \
  || fail "a hand-written malformed line blocked the helper-written replies"
HELPER_STATUS="$PARENT/state/helper.status"
[ "$(grep -cF 'helper reply before the defect' "$HELPER_STATUS")" -eq 1 ] \
  || fail "the helper-written reply before the defect did not ingest exactly once"
[ "$(grep -cF 'helper reply after the defect' "$HELPER_STATUS")" -eq 1 ] \
  || fail "the helper-written reply after the defect did not ingest exactly once"
assert_no_grep 'hand written reply with a bad token' "$HELPER_STATUS" \
  "a hand-written malformed line reached the parent status channel"
for corr in "$HELPER_CORR_ONE" "$HELPER_CORR_TWO"; do
  [ "$(pending_phase "$corr")" = resolved ] \
    || fail "a helper-written reply did not resolve its pending request: $corr"
done
[ "$(find "$PARENT/state/remote-replies/quarantine/helper" -type f -name '*.quarantine' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "the hand-written malformed line was not quarantined exactly once"
[ "$(grep -cF "remote-reply-quarantine:helper:" "$PARENT/state/.wake-queue")" -eq 1 ] \
  || fail "the helper composition did not announce its quarantined line exactly once"
HELPER_BYTES=$(LC_ALL=C wc -c < "$HELPER_LOG" | tr -d ' ')
[ "$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/helper.cursor")" = "$HELPER_BYTES" ] \
  || fail "the helper composition did not advance the cursor past the whole delta"
pass "producer, capture, quarantine, correlation resolution, and cursor compose end to end"

echo "ALL TESTS PASSED"

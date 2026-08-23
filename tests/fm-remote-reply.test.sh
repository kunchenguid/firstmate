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
REMOTE_SEQ122="$TMP_ROOT/remote-seq122"
REMOTE_REVIEWER="$TMP_ROOT/remote-reviewer"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" \
  "$REMOTE_INTERLEAVE/state" "$REMOTE_INTERLEAVE/data" "$REMOTE_UTF8/state" \
  "$REMOTE_KEYED/state" "$REMOTE_MIXED/state" "$REMOTE_MIXED/data/reply" \
  "$REMOTE_SEQ122/state" "$REMOTE_SEQ122/data" \
  "$REMOTE_REVIEWER/state" "$REMOTE_REVIEWER/data/review" "$CLAIMS"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; fm_test_cleanup' EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
- interleave - interleaved reply fixture (host: remote-interleave; root: $ROOT; home: $REMOTE_INTERLEAVE; scope: test; projects: alpha; added 2026-08-02)
- utf8 - utf8 reply fixture (host: remote-utf8; root: $ROOT; home: $REMOTE_UTF8; scope: test; projects: alpha; added 2026-08-02)
- keyed - keyed reply fixture (host: remote-keyed; root: $ROOT; home: $REMOTE_KEYED; scope: test; projects: alpha; added 2026-08-20)
- mixed - mixed reply fixture (host: remote-mixed; root: $ROOT; home: $REMOTE_MIXED; scope: test; projects: alpha; added 2026-08-21)
- seq122 - sequence 122 reply fixture (host: remote-seq122; root: $ROOT; home: $REMOTE_SEQ122; scope: test; projects: alpha; added 2026-08-21)
- reviewer - reviewer reply fixture (host: remote-reviewer; root: $ROOT; home: $REMOTE_REVIEWER; scope: review; projects: alpha; added 2026-08-21)
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
  case "$host" in remote-mac|remote-interleave|remote-utf8|remote-keyed|remote-mixed|remote-seq122|remote-reviewer) ;;
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
assert_contains "$mixed_out" 'ingested: mixed appended=2 quarantined=5' \
  "mixed ingest did not report two accepted and five quarantined lines"
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
seq122_out=$(remote_env "$ROOT/bin/fm-procevent.sh" dispatch "$SEQ122_SID" 122) \
  || fail "sequence 122 did not dispatch through the shared ingest owner"
assert_contains "$seq122_out" 'ingested: seq122 appended=2 quarantined=1' \
  "sequence 122 did not isolate its one malformed correlation"
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
seq122_replay=$(remote_env "$ROOT/bin/fm-procevent.sh" dispatch "$SEQ122_SID" 122) \
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
reviewer_dispatch=$(remote_env "$ROOT/bin/fm-procevent.sh" dispatch "$REVIEWER_SID" 1) \
  || fail "captured reviewer answer did not dispatch through its recorded adapter"
assert_contains "$reviewer_dispatch" 'ingested: reviewer appended=1 quarantined=0' \
  "reviewer dispatch did not use the validated remote-reply ingest"
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
reviewer_replay=$(remote_env "$ROOT/bin/fm-procevent.sh" dispatch "$REVIEWER_SID" 1) \
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
assert_contains "$utf8_out" 'ingested: utf8 appended=1' \
  "utf8 correlated line was not ingested"
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
rebase_offset=$(sed -n 's/^to_offset=//p' "$UTF8_RESULT_TWO")
rebase_hash=$(sed -n 's/^to_prefix_sha256=//p' "$UTF8_RESULT_TWO")
[ -n "$rebase_offset" ] && [ -n "$rebase_hash" ] \
  || fail "utf8 second capture did not record its committed cursor"
printf 'done [corr=1010101010101010]: third utf8 reply\n' \
  >> "$REMOTE_UTF8/state/parent-replies.status"
rebase_out=$(remote_env "$ADAPTER" cursor-rebase utf8 "$rebase_offset" "$rebase_hash") \
  || fail "cursor rebase could not select a captured complete-line boundary"
assert_contains "$rebase_out" "from_offset=$UTF8_OFFSET" \
  "cursor rebase did not report its prior cursor"
assert_contains "$rebase_out" "to_offset=$rebase_offset" \
  "cursor rebase did not report its target cursor"
assert_grep "offset=$rebase_offset" "$PARENT/state/remote-replies/utf8.cursor" \
  "cursor rebase did not commit the validated offset"
utf8_handle_two=$(remote_env "$ADAPTER" handle utf8 2 "$UTF8_RESULT_TWO") \
  || fail "rebased mixed-validity generation could not be handled"
assert_contains "$utf8_handle_two" 'ingested: utf8 appended=1 quarantined=3' \
  "mixed UTF-8 generation did not isolate three invalid lines"
[ "$(grep -cF 'second utf8 reply' "$PARENT/state/utf8.status")" -eq 1 ] \
  || fail "mixed UTF-8 generation did not ingest its valid line exactly once"
UTF8_QUARANTINE="$PARENT/state/remote-replies/quarantine/utf8"
[ "$(grep -l '^reason=invalid-status$' "$UTF8_QUARANTINE"/*.quarantine | wc -l | tr -d ' ')" -eq 3 ] \
  || fail "non-printable lines were not retained as three invalid-status artifacts"
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
pass "invalid UTF-8 and control lines quarantine while cursor rebase remains inspectable"

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
assert_contains "$keyed_bad_out" 'ingested: keyed appended=0 quarantined=3' \
  "malformed keyed lines were not independently quarantined"
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

echo "ALL TESTS PASSED"

#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
printf '# Mentioned but never offered\n' > "$REMOTE/data/reply/prose-only.md"
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
[ "$host" = remote-mac ] || exit 91
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
printf 'done [corr=0123456789abcdef]: build verified report=data/reply/report.md\n' \
  >> "$REMOTE/state/parent-replies.status"
wait "$RUNNER" || fail "remote reply source failed to capture its first delta"
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
# One remote note, one announcement: the adapter declares self-announcing, so a
# fully autohandled capture publishes NO check wake - the mirrored status bytes
# are the single announcement, observed here through the same signature-vs-seen
# gate the watcher's signal scan and the drain's annotation check consume.
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue"; then
  fail "an autohandled remote-reply capture still published a duplicate check wake"
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

# The runner applies a captured result through this adapter itself, so the reply
# is already mirrored, acknowledged, and the next source re-armed before any
# handler runs. That is the primary guarantee; assert it before exercising the
# handler's own path below.
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" \
  "the captured reply was not applied to the parent status stream at capture"
assert_present "$PARENT/state/procevent-inbox/$SID.1.handled" \
  "the applied capture was left unacknowledged"
assert_present "$PARENT/state/procevent/$SID.source" \
  "applying the capture left the relay unarmed for the next delta"
pass "a captured delta is applied, acknowledged, and re-armed without a handler"

# Now the handler's own retry path, from the state a crash between applying and
# acknowledging leaves behind: the acknowledgement is gone and re-arming fails.
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

printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
# The runner already applied and acknowledged this capture. Drop that genuine
# acknowledgement and put an unsafe one in its place, so the handler's refusal
# to trust a non-regular marker stays under test.
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
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

# The channel mirrors the remote mate's content-bearing status lines at most once
# while omitting blank separators. A remote mate's own progress line and a NEWLY
# raised needs-decision carry no corr= by charter contract, and a delta carrying
# them alongside a correlated answer must ingest whole: every content-bearing
# line reaches the parent stream, the new decision reaches the parent's
# open-decision fold, the correlated line still settles its pending-reply record,
# and the cursor advances so the channel cannot wedge on a line it once refused.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
PENDING_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'audit the release chain')
[ -n "$PENDING_CORR" ] || fail "could not create the parent pending-reply record"
fm_pending_reply_mark_delivered "$PARENT/state" "$PENDING_CORR" \
  || fail "could not mark the pending-reply request delivered"
{
  printf 'working [key=version-audit]: family --version audit complete (data/reply/prose-only.md)\n'
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
# The prose line NAMES a path that really does exist on the remote, so only the
# structured-pointer trigger can explain the parent never fetching it.
assert_absent "$PARENT/data/remote-secondmates/ios/data/reply/prose-only.md" \
  "a bare path mentioned in prose was fetched as though the line offered it"
assert_grep 'audit complete (data/reply/prose-only.md)' "$PARENT/state/ios.status" \
  "the prose mention was rewritten as though its document had been fetched"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "a bare path mentioned in prose raised a document transfer obligation"
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
printf 'done [key=retry-document]: retry local storage report=data/reply/retry.md\n' \
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

# ---------------------------------------------------------------------------
# The document a line OFFERS is a durable, re-attemptable obligation, never a
# verdict. The reader cannot tell a report that is still being written from one
# that will never exist, so an early offer must escalate, say why, and then
# clear itself the moment the document arrives - while the cursor keeps
# advancing so no delta ever stalls on one pointer.
GEN=8
mirror_lines() { # <line>...
  GEN=$((GEN + 1))
  printf '%s\n' "$@" >> "$REMOTE/state/parent-replies.status"
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
    || fail "generation $GEN was not captured"
  assert_present "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
    "generation $GEN was captured but never applied"
}
mirrored_cursor_is_current() { # <label>
  local offset
  offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
  assert_grep "offset=$offset" "$PARENT/state/remote-replies/ios.cursor" "$1"
}
document_decision_open() {
  status_open_decisions "$PARENT/state/ios.status" | grep -q '^remote-reply-document-ios	'
}

printf '# valid report behind a malformed pointer\n' > "$REMOTE/data/reply/result.md"
mirror_lines 'working [key=malformed-report]: malformed offer report=data/reply/result.md.bak'
assert_absent "$PARENT/data/remote-secondmates/ios/data/reply/result.md" \
  "a valid prefix of a malformed report pointer was fetched"
assert_grep 'report=data/reply/result.md.bak' "$PARENT/state/ios.status" \
  "a valid prefix of a malformed report pointer was rewritten"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "a malformed report pointer raised a document transfer obligation"
mirrored_cursor_is_current "a malformed report pointer prevented the cursor from advancing"
pass "a structured pointer must end at its token boundary"

printf '# first adjacent report\n' > "$REMOTE/data/reply/adjacent-a.md"
printf '# second adjacent report\n' > "$REMOTE/data/reply/adjacent-b.md"
mirror_lines 'done [key=adjacent-reports]: report=data/reply/adjacent-a.md,report=data/reply/adjacent-b.md report=data/reply/result.md alongside report=data/reply/result.md.bak'
cmp -s "$REMOTE/data/reply/adjacent-a.md" "$PARENT/data/remote-secondmates/ios/data/reply/adjacent-a.md" \
  || fail "the first comma-separated structured pointer was not fetched"
cmp -s "$REMOTE/data/reply/adjacent-b.md" "$PARENT/data/remote-secondmates/ios/data/reply/adjacent-b.md" \
  || fail "the second comma-separated structured pointer was not fetched"
cmp -s "$REMOTE/data/reply/result.md" "$PARENT/data/remote-secondmates/ios/data/reply/result.md" \
  || fail "the whitespace-separated structured pointer was not fetched"
assert_grep 'report=data/remote-secondmates/ios/data/reply/adjacent-a.md,report=data/remote-secondmates/ios/data/reply/adjacent-b.md report=data/remote-secondmates/ios/data/reply/result.md alongside report=data/reply/result.md.bak' "$PARENT/state/ios.status" \
  "structured pointer rewriting skipped an adjacent pointer or changed a malformed token"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "adjacent deliverable pointers raised a document transfer obligation"
mirrored_cursor_is_current "adjacent structured pointers prevented the cursor from advancing"
pass "adjacent pointers are fetched while malformed tokens remain unchanged"

# A line may name a path under ANOTHER home's mirror tree; that document is
# provably not this mate's to serve, and prose naming it is not an offer.
mirror_lines 'working [key=cross-home]: the sibling relayed data/remote-secondmates/other/data/reply/report.md and its own data/reply/prose-only.md earlier'
assert_grep 'the sibling relayed data/remote-secondmates/other/data/reply/report.md' "$PARENT/state/ios.status" \
  "the cross-home mention was not mirrored verbatim"
assert_absent "$PARENT/data/remote-secondmates/ios/data/remote-secondmates" \
  "a path under another home's mirror tree was fetched from this mate"
document_decision_open && fail "a cross-home path mentioned in prose opened a document obligation"
mirrored_cursor_is_current "a prose-only delta did not advance the cursor"
pass "a path mentioned in prose, including another home's, is never fetched"

# STEP 1 of the reported timeline: the mate offers a report it has not written
# yet. The escalation must name the document AND the reader's own reason.
mirror_lines 'reply [corr=3333333333333333]: dispatched the voice scout report=data/reply/late.md, will relay on completion'
assert_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "an offered document that could not be delivered raised no escalation"
assert_grep 'data/reply/late.md: file is not a non-symlink regular file' "$PARENT/state/ios.status" \
  "the escalation discarded the reader's own reason for refusing"
document_decision_open || fail "the undelivered document did not open a decision on the parent's board"
assert_grep 'report=data/reply/late.md' "$PARENT/state/ios.status" \
  "an undelivered document's line was not mirrored with its own pointer intact"
assert_grep 'doc data/reply/late.md	' "$PARENT/state/remote-replies/ios.pending-docs" \
  "the undelivered document was not recorded as a re-attemptable obligation"
mirrored_cursor_is_current "an undelivered document held the cursor back"
pass "an offered document the reader cannot deliver escalates with its reason and does not stall"

# STEP 2: two more lines in ONE delta offer the SAME still-absent document.
# The gap is named once, and an unchanged obligation raises nothing new.
blocks_before=$(grep -cF 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status")
mirror_lines \
  'reply [corr=3333333333333333]: no report to transfer yet, report=data/reply/late.md is not written' \
  'reply [corr=3333333333333333]: same - the scout is still working on report=data/reply/late.md'
[ "$(grep -cF 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status")" -eq "$blocks_before" ] \
  || fail "re-offering an already-recorded document accumulated a second escalation"
newest_block=$(grep -F 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" | tail -1)
[ "$(printf '%s\n' "$newest_block" | grep -oF 'data/reply/late.md' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "one missing document was named more than once in a single escalation: $newest_block"
pass "one missing document is named once per escalation and never accumulates"

# STEP 3 and 4: the scout finishes and writes the report. The very next delta
# re-attempts the obligation, so recovery no longer depends on some later line
# happening to offer the same path again.
printf '# late scout report\n\nfindings\n' > "$REMOTE/data/reply/late.md"
mirror_lines 'working [key=unrelated]: unrelated later progress line'
cmp -s "$REMOTE/data/reply/late.md" "$PARENT/data/remote-secondmates/ios/data/reply/late.md" \
  || fail "the re-attempted document was not fetched once it existed"
assert_grep 'resolved [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "the arriving document did not retire its own escalation"
assert_grep 'data/remote-secondmates/ios/data/reply/late.md' "$PARENT/state/ios.status" \
  "the resolution did not name the local copy the captain can now read"
document_decision_open && fail "the escalation stayed open after its document arrived"
assert_no_grep 'doc data/reply/late.md	' "$PARENT/state/remote-replies/ios.pending-docs" \
  "a delivered document was left recorded as outstanding"
mirrored_cursor_is_current "the recovering delta did not advance the cursor"
pass "an undelivered document is re-attempted and its escalation clears itself"

# STEP 5: the same self-clearing must work on a channel that stays QUIET, where
# no further delta is coming. The obligation rides the channel's own poll.
# The exact shape bin/fm-inactive-reconcile.sh publishes for a finished child.
mirror_lines 'done [key=child-outcome-quiet-scout-done-ab12cd34]: child quiet-scout done: report ready mode=scout report=data/reply/quiet.md'
document_decision_open || fail "the second undelivered document opened no decision"
printf '# quiet-window report\n' > "$REMOTE/data/reply/quiet.md"
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios > "$TMP_ROOT/quiet-retry.out" 2>&1
quiet_retry_rc=$?
set -e
[ "$quiet_retry_rc" -eq 75 ] || fail "the quiet retry window exited with an unexpected status: $quiet_retry_rc"
[ ! -s "$TMP_ROOT/quiet-retry.out" ] \
  || fail "the poll's document retry wrote to the captured-result stream: $(cat "$TMP_ROOT/quiet-retry.out")"
cmp -s "$REMOTE/data/reply/quiet.md" "$PARENT/data/remote-secondmates/ios/data/reply/quiet.md" \
  || fail "a quiet channel never re-attempted its outstanding document"
document_decision_open && fail "a quiet channel's escalation never cleared itself"
pass "an outstanding document is re-attempted on the channel's own poll and clears the board"

# A document that goes missing AGAIN must re-open the board. The escalation for
# an already-seen document and reason is otherwise byte-identical to the earlier
# one, and the at-most-once append would silently swallow it.
rm -f "$REMOTE/data/reply/quiet.md"
mirror_lines 'reply [corr=5555555555555555]: relaying the second scout once more, report=data/reply/quiet.md'
document_decision_open || fail "a document that went missing again did not re-open its decision"
[ "$(grep -cF 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status")" -ge 3 ] \
  || fail "the repeated escalation was suppressed as duplicate bytes"
printf '# quiet-window report\n' > "$REMOTE/data/reply/quiet.md"
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
set -e
document_decision_open && fail "the repeated escalation did not clear itself a second time"
[ "$(grep -cF 'resolved [key=remote-reply-document-ios]' "$PARENT/state/ios.status")" -ge 2 ] \
  || fail "the repeated resolution was suppressed as duplicate bytes"
pass "a document that fails again re-opens the board, and its later arrival clears it again"

# The positive remote-refusal case with a genuinely non-transient cause: the
# reader bounds document size, and that refusal must reach the board by name.
head -c 300000 /dev/zero | tr '\0' 'x' > "$REMOTE/data/reply/big.md"
mirror_lines 'done [key=big-report]: oversize deliverable report=data/reply/big.md'
assert_grep 'data/reply/big.md: file exceeds max-bytes' "$PARENT/state/ios.status" \
  "an oversize document's refusal did not reach the board with its reason"
document_decision_open || fail "an oversize document raised no obligation"
assert_absent "$PARENT/data/remote-secondmates/ios/data/reply/big.md" \
  "a refused oversize document was stored locally anyway"
mirrored_cursor_is_current "an oversize document held the cursor back"
printf '# trimmed deliverable\n' > "$REMOTE/data/reply/big.md"
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
set -e
document_decision_open && fail "the oversize obligation did not clear once the document fit the bound"
pass "a remote refusal names its own reason and stays re-attemptable"

# Two documents outstanding at once are ONE obligation whose set is
# order-independent: re-offering a document already recorded must not manufacture
# a fresh escalation just because it re-enters the set from the other side.
mirror_lines 'reply [corr=6666666666666666]: first deliverable report=data/reply/pair-a.md'
mirror_lines 'reply [corr=6666666666666666]: second deliverable report=data/reply/pair-b.md'
blocks_before=$(grep -cF 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status")
mirror_lines 'reply [corr=6666666666666666]: re-offering report=data/reply/pair-a.md while the second is written'
[ "$(grep -cF 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status")" -eq "$blocks_before" ] \
  || fail "an unchanged set of outstanding documents raised a fresh escalation"
printf '# first deliverable\n' > "$REMOTE/data/reply/pair-a.md"
printf '# second deliverable\n' > "$REMOTE/data/reply/pair-b.md"
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
set -e
document_decision_open && fail "both documents arrived and the obligation stayed open"
cmp -s "$REMOTE/data/reply/pair-b.md" "$PARENT/data/remote-secondmates/ios/data/reply/pair-b.md" \
  || fail "the second outstanding document was never re-attempted"
pass "several outstanding documents are one order-independent obligation"

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
GEN=$((GEN + 1))
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
GEN=$((GEN + 1))
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
GEN=$((GEN + 1))
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the cursor-loss recapture was not captured"
assert_present "$PARENT/state/procevent-inbox/$SID.$GEN.handled" \
  "the whole-log recapture was not acknowledged by the adapter"
# Documents that were undelivered when their lines first mirrored have since
# arrived, so this replay also pins that a line mirrors once whichever pointer
# form it was first written under.
cmp -s "$TMP_ROOT/ios-status-before-replay" "$PARENT/state/ios.status" \
  || fail "the whole-log recapture duplicated already-mirrored lines"
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID $GEN" "$PARENT/state/.wake-queue"; then
  fail "an already-mirrored recapture still published a check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "a byte-identical recapture left unannounced status bytes behind"
replay_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$replay_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recapture did not rebuild the lost cursor"
pass "a cursor-loss whole-log recapture is acknowledged quietly with no duplicate wake"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
GEN=$((GEN + 1))
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_TWELVE=$(find "$PARENT/state/procevent-inbox" -name "$SID.$GEN.result" -print -quit)
[ -n "$RESULT_TWELVE" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_TWELVE")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_TWELVE" > "$TMP_ROOT/handle-nine.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$RESULT_TWELVE" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.$GEN.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_TWELVE" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "adapter retirement left a caught-up watermark a later route could inherit"
assert_absent "$PARENT/state/remote-replies/ios.pending-docs" \
  "adapter retirement left a document obligation a later route could inherit"
pass "remote reply retirement quiesces and refuses unhandled captured results"

echo "ALL TESTS PASSED"

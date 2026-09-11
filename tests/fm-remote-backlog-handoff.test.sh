#!/usr/bin/env bash
# Outbox-based remote secondmate backlog handoff and dropped-link recovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-handoff)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
WAKE_LOG="$TMP_ROOT/wake.log"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE_ROOT/bin" \
  "$REMOTE/data" "$REMOTE/state" "$REMOTE/config" "$REMOTE/projects" "$REMOTE/bin"
# Tear down deterministically. Releasing the blocked stages and killing the
# detached remote worker is not enough on its own: kill only signals, so the
# worker (and this shell's own background stages) could still be writing into
# $TMP_ROOT when rm -rf ran, which surfaced as a real CI flake:
#   rm: cannot remove '/tmp/fm-remote-handoff.XXXXXX': Directory not empty
# So wait for the worker to actually exit and drain the shell's background jobs
# before removing the tree, then retry rm -rf until the now-quiesced tree is gone.
fm_remote_handoff_teardown() {
  local worker_pid i
  touch "$TMP_ROOT/put.release" "$TMP_ROOT/route.release" 2>/dev/null || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid" 2>/dev/null || true)
    if [ -n "$worker_pid" ]; then
      kill "$worker_pid" 2>/dev/null || true
      i=0
      while [ "$i" -lt 500 ] && kill -0 "$worker_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
    fi
  fi
  wait 2>/dev/null || true
  i=0
  while [ "$i" -lt 50 ]; do
    rm -rf -- "$TMP_ROOT" 2>/dev/null && return 0
    sleep 0.02
    i=$((i + 1))
  done
  rm -rf -- "$TMP_ROOT" 2>/dev/null || true
}
trap fm_remote_handoff_teardown EXIT
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" \
  "$ROOT/bin/fm-remote-job-worker.sh" "$ROOT/bin/fm-remote-file.sh" \
  "$ROOT/bin/fm-backlog-receive.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
  "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-stdlib.sh" "$REMOTE_ROOT/bin/"
ln -s "$(command -v tasks-axi)" "$REMOTE_ROOT/bin/tasks-axi"
ln -s "$(command -v node)" "$REMOTE_ROOT/bin/node"
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'tracked remote fixture'
printf 'fixture\n' > "$REMOTE/AGENTS.md"
printf 'ios\n' > "$REMOTE/.fm-secondmate-home"
cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
cat > "$PARENT/state/ios.meta" <<EOF
window=fm-remote:w1:p1
endpoint_task_id=ios
harness=claude
kind=secondmate
mode=secondmate
remote_host=remote-mac
remote_root=$REMOTE_ROOT
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
EOF
: > "$WAKE_LOG"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
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
argv_b64=$4
command_name=$(perl -MMIME::Base64=decode_base64 -e '$d=decode_base64($ARGV[0]); ($c)=split(/\0/, $d); print $c' "$argv_b64")
case "${FM_FAKE_SSH_MODE:-normal}:$command_name" in
  *:fm-remote-secondmate-control.sh)
    printf '%s\n' "$command_name" >> "$FM_FAKE_REMOTE_WAKE_LOG"
    [ "${FM_FAKE_REMOTE_WAKE_RC:-0}" -eq 0 ] || printf 'remote receiver wake failed\n' >&2
    exit "${FM_FAKE_REMOTE_WAKE_RC:-0}"
    ;;
  unreachable:*) exit 255 ;;
  serialize:fm-backlog-receive.sh)
    if mkdir "$FM_FAKE_SERIALIZE_ONCE" 2>/dev/null; then
      touch "$FM_FAKE_SERIALIZE_ENTERED"
      while [ ! -f "$FM_FAKE_SERIALIZE_RELEASE" ]; do sleep 0.02; done
    fi
    exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    ;;
  after-put:fm-remote-file.sh)
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    exit 255
    ;;
  after-receive:fm-backlog-receive.sh)
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    exit 255
    ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

handoff_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_WAKE_LOG="$WAKE_LOG" \
  FM_FAKE_REMOTE_WAKE_RC="${FM_FAKE_REMOTE_WAKE_RC:-0}" \
  FM_FAKE_SERIALIZE_ONCE="$TMP_ROOT/serialize.once" \
  FM_FAKE_SERIALIZE_ENTERED="$TMP_ROOT/serialize.entered" \
  FM_FAKE_SERIALIZE_RELEASE="$TMP_ROOT/serialize.release" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$@"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

printf 'complete handoff payload\n' > "$TMP_ROOT/complete-payload"
complete_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/complete-payload" | tr -d ' ')
complete_hash=$(sha256_file "$TMP_ROOT/complete-payload")
if printf 'complete' | FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-remote-file.sh" \
  put state/handoff/integrity.outbox.md 1024 "$complete_bytes" "$complete_hash" 1 >/dev/null 2>&1; then
  fail "confined put published a truncated payload"
fi
assert_absent "$REMOTE/state/handoff/integrity.outbox.md" "truncated confined put published a destination"
FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-remote-file.sh" \
  put state/handoff/integrity.outbox.md 1024 "$complete_bytes" "$complete_hash" 2 \
  < "$TMP_ROOT/complete-payload" >/dev/null
printf 'stale handoff payload\n' > "$TMP_ROOT/stale-payload"
stale_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/stale-payload" | tr -d ' ')
stale_hash=$(sha256_file "$TMP_ROOT/stale-payload")
if FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-remote-file.sh" \
  put state/handoff/integrity.outbox.md 1024 "$stale_bytes" "$stale_hash" 1 \
  < "$TMP_ROOT/stale-payload" >/dev/null 2>&1; then
  fail "confined put accepted a superseded payload generation"
fi
cmp -s "$TMP_ROOT/complete-payload" "$REMOTE/state/handoff/integrity.outbox.md" \
  || fail "superseded confined put replaced the current payload"
pass "confined put rejects incomplete and superseded payload generations"
rm -f "$REMOTE/state/handoff/integrity.outbox.md" "$REMOTE/state/handoff/.integrity.upload-generation"

mkdir -p "$REMOTE/state/handoff" "$TMP_ROOT/external-handoff"
printf 'race-safe handoff\n' > "$TMP_ROOT/race-payload"
race_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/race-payload" | tr -d ' ')
race_hash=$(sha256_file "$TMP_ROOT/race-payload")
(
  set -o pipefail
  (
    while [ ! -f "$TMP_ROOT/put.release" ]; do sleep 0.02; done
    cat "$TMP_ROOT/race-payload"
  ) | FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-remote-file.sh" \
    put state/handoff/race.outbox.md 1024 "$race_bytes" "$race_hash" 1
) > "$TMP_ROOT/put-race.out" 2>&1 &
put_race_pid=$!
put_wait=0
while ! find "$REMOTE/state/handoff" -maxdepth 1 -name '.put.*' -print -quit | grep -q .; do
  kill -0 "$put_race_pid" 2>/dev/null || fail "confined put exited before staging input"
  put_wait=$((put_wait + 1))
  [ "$put_wait" -le 250 ] || fail "confined put never staged input"
  sleep 0.02
done
mv "$REMOTE/state/handoff" "$TMP_ROOT/pinned-handoff"
ln -s "$TMP_ROOT/external-handoff" "$REMOTE/state/handoff"
touch "$TMP_ROOT/put.release"
if wait "$put_race_pid"; then
  fail "confined put reported success after its destination directory changed"
fi
if find "$TMP_ROOT/external-handoff" -mindepth 1 -print -quit | grep -q .; then
  fail "confined put followed a replacement handoff symlink"
fi
assert_absent "$TMP_ROOT/pinned-handoff/race.outbox.md" "confined put retained a publication outside the named handoff directory"
rm -f "$REMOTE/state/handoff"
mv "$TMP_ROOT/pinned-handoff" "$REMOTE/state/handoff"
pass "confined put rejects directory replacement without external writes"

write_backlog() {
  cat > "$PARENT/data/backlog.md" <<EOF
## In flight

## Queued
$1

## Done
EOF
}

# Completion can become unknown after the remote atomic move. The local outbox
# remains the whole recovery record, the primary dispatch queue is already
# empty, and a blind retry is not performed inside the transport call.
write_backlog $'- [ ] ios-a - first iOS task (repo: alpha)\n- [ ] ios-b - dependent iOS task (repo: alpha) blocked-by: ios-a - waits'
: > "$SSH_COUNT"
set +e
FM_FAKE_SSH_MODE=after-receive handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios ios-a ios-b \
  > "$TMP_ROOT/ambiguous.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "handoff claimed success after ambiguous remote receipt"
assert_no_grep 'ios-a' "$PARENT/data/backlog.md" "ambiguous handoff left ios-a dispatchable in the primary backlog"
assert_no_grep 'ios-b' "$PARENT/data/backlog.md" "ambiguous handoff left ios-b dispatchable in the primary backlog"
assert_present "$PARENT/data/handoff/ios.outbox.md" "ambiguous handoff lost its durable outbox"
if [ ! -f "$REMOTE/data/backlog.md" ]; then
  printf 'handoff output:\n%s\n' "$(cat "$TMP_ROOT/ambiguous.out")" >&2
  fail "remote atomic receipt created no destination backlog before the dropped acknowledgement"
fi
if ! grep -F ios-a "$REMOTE/data/backlog.md" >/dev/null; then
  printf 'handoff output:\n%s\nremote backlog:\n%s\n' "$(cat "$TMP_ROOT/ambiguous.out")" "$(cat "$REMOTE/data/backlog.md")" >&2
  fail "remote atomic receipt did not deliver ios-a before the dropped acknowledgement"
fi
assert_grep 'ios-b' "$REMOTE/data/backlog.md" "remote atomic receipt did not deliver ios-b before the dropped acknowledgement"
[ "$(cat "$SSH_COUNT")" -eq 2 ] || fail "transport retried an ambiguously completed command"
pass "ambiguous receipt leaves one durable outbox and no duplicate dispatchable source"

out=$(handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending)
assert_contains "$out" 'received: ios moved=0 already=2' "retry did not classify already-delivered keys idempotently"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq 1 ] \
  || fail "confirmed remote receipt did not wake its supported receiver endpoint exactly once"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "confirmed retry did not clean the local outbox"
[ "$(grep -cF -- '- [ ] ios-a - first iOS task' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "receipt retry duplicated ios-a"
[ "$(grep -cF -- '- [ ] ios-b - dependent iOS task' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "receipt retry duplicated ios-b"
pass "re-delivery after unknown completion converges without duplication"

# A dropped transfer can leave a complete atomically published scratch file but
# cannot apply half a backlog mutation. The next explicit recovery overwrites
# that scratch and receives it normally.
rm -f "$REMOTE/data/backlog.md"
write_backlog '- [ ] transfer-cut - survives a dropped transfer (repo: alpha)'
: > "$SSH_COUNT"
set +e
FM_FAKE_SSH_MODE=after-put handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios transfer-cut \
  > "$TMP_ROOT/transfer-cut.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "handoff claimed success after a dropped transfer acknowledgement"
assert_no_grep 'transfer-cut' "$PARENT/data/backlog.md" "dropped transfer left the item dispatchable"
assert_present "$PARENT/data/handoff/ios.outbox.md" "dropped transfer lost the local outbox"
assert_present "$REMOTE/state/handoff/ios.outbox.md" "dropped transfer did not atomically publish its remote scratch copy"
assert_absent "$REMOTE/data/backlog.md" "dropped transfer applied a destination mutation"
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null \
  || fail "recovery after dropped transfer failed"
assert_grep 'transfer-cut' "$REMOTE/data/backlog.md" "recovery after dropped transfer lost the item"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "recovery after dropped transfer left the local outbox"
pass "dropped transfer recovery overwrites scratch and delivers exactly once"

rm -f "$REMOTE/data/backlog.md" "$TMP_ROOT/serialize.entered" "$TMP_ROOT/serialize.release"
rm -rf "$TMP_ROOT/serialize.once"
write_backlog '- [ ] serialized-a - first concurrent handoff (repo: alpha)'
FM_FAKE_SSH_MODE=serialize handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios serialized-a \
  > "$TMP_ROOT/serialized-a.out" 2>&1 &
handoff_a=$!
wait_for_serialization=0
while [ ! -f "$TMP_ROOT/serialize.entered" ]; do
  kill -0 "$handoff_a" 2>/dev/null || fail "first serialized handoff exited before receipt"
  wait_for_serialization=$((wait_for_serialization + 1))
  [ "$wait_for_serialization" -le 250 ] || fail "first serialized handoff never reached receipt"
  sleep 0.02
done
write_backlog '- [ ] serialized-b - second concurrent handoff (repo: alpha)'
FM_FAKE_SSH_MODE=serialize handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios serialized-b \
  > "$TMP_ROOT/serialized-b.out" 2>&1 &
handoff_b=$!
sleep 0.2
assert_grep 'serialized-b' "$PARENT/data/backlog.md" "concurrent handoff staged while the first transaction was in flight"
assert_no_grep 'serialized-b' "$PARENT/data/handoff/ios.outbox.md" "concurrent handoff mutated the in-flight outbox"
touch "$TMP_ROOT/serialize.release"
wait "$handoff_a" || fail "first serialized handoff failed"
wait "$handoff_b" || fail "second serialized handoff failed"
assert_no_grep 'serialized-a' "$PARENT/data/backlog.md" "first serialized handoff remained dispatchable"
assert_no_grep 'serialized-b' "$PARENT/data/backlog.md" "second serialized handoff remained dispatchable"
[ "$(grep -cF serialized-a "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "first serialized handoff was lost or duplicated"
[ "$(grep -cF serialized-b "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "second serialized handoff was lost or duplicated"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "serialized handoffs left a pending outbox"
pass "concurrent handoffs serialize staging through confirmed cleanup"

# A stale tasks-axi lock is removed only on the destination host after the first
# move refusal proves a retry is needed. The dead pid and age satisfy the same
# conservative procedure tasks-axi prints.
write_backlog '- [ ] stale-lock-item - remote stale lock recovery (repo: alpha)'
printf '999999:abandoned:0:1\n' > "$REMOTE/data/backlog.md.lock"
touch -t 202001010000 "$REMOTE/data/backlog.md.lock"
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios stale-lock-item >/dev/null \
  || fail "host-local stale lock recovery did not retry receipt"
assert_grep 'stale-lock-item' "$REMOTE/data/backlog.md" "stale-lock receipt lost the item"
assert_absent "$REMOTE/data/backlog.md.lock" "stale destination lock survived successful receipt"
pass "receiver removes one proven dead stale lock and retries once"

# Unreachable delivery keeps the backlog-format outbox visible to bootstrap.
write_backlog '- [ ] pending-offline - waits for the remote Mac (repo: alpha)'
set +e
FM_FAKE_SSH_MODE=unreachable handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios pending-offline \
  > "$TMP_ROOT/offline.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "offline handoff claimed success"
bootstrap_out=$(FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
  FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1)
assert_contains "$bootstrap_out" 'SECONDMATE_HANDOFF: secondmate ios: pending delivery: 1 item(s)' \
  "bootstrap did not surface the pending outbox count"
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null \
  || fail "pending bootstrap-visible outbox did not later converge"
pass "bootstrap detects pending outbox handoffs without a journal"

write_backlog '- [ ] remote-wake-fail - receiver failure stays recoverable (repo: alpha)'
FM_FAKE_REMOTE_WAKE_RC=1 handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios remote-wake-fail \
  > "$TMP_ROOT/remote-wake-fail.out" 2>&1 \
  || fail "durably received remote handoff failed only because its best-effort wake failed"
assert_contains "$(cat "$TMP_ROOT/remote-wake-fail.out")" 'receiver wake failed' \
  "remote receiver wake failure was not surfaced"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "remote receiver wake failure retained the durably received outbox"
assert_present "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "remote receiver wake failure was not tracked separately"
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null \
  || fail "remote receiver wake failure did not recover through resume-pending"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "remote receiver wake recovery left separate wake state pending"
pass "remote handoff releases durable work and separately retries its receiver wake"

# The receiver wake is a best-effort live nudge sent AFTER the backlog receipt
# is durable. A wake whose remote transport is lost leaves its correlation
# undelivered with delivery unknown, and the watcher's very next pending-reply
# tick escalates that correlation. That escalated-but-undelivered wake must
# stay retryable: the outbox otherwise jams every later handoff to this mate
# behind a correlation the resume refuses to resend forever.
write_backlog '- [ ] wake-escalated - escalated undelivered wake stays retryable (repo: alpha)'
wakes_before=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
FM_FAKE_REMOTE_WAKE_RC=255 handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios wake-escalated \
  > "$TMP_ROOT/wake-escalated.out" 2>&1 \
  || fail "durably received handoff failed only because its wake transport was lost"
assert_grep 'wake-escalated' "$REMOTE/data/backlog.md" "lost wake transport did not leave the backlog durably received"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "lost wake transport retained the durably received outbox"
wake_marker=$(cat "$PARENT/state/.backlog-handoff-ios.wake-pending" 2>/dev/null || true)
case "$wake_marker" in
  pending:*) escalated_corr=${wake_marker#pending:} ;;
  *) fail "lost wake transport did not leave a pending correlated wake, got '$wake_marker'" ;;
esac
escalated_rec="$PARENT/state/pending-replies/$escalated_corr"
[ -f "$escalated_rec" ] || fail "lost wake transport left no pending-reply record for $escalated_corr"
[ "$(grep '^phase=' "$escalated_rec" | cut -d= -f2-)" = delivery_unknown ] \
  || fail "lost wake transport did not record delivery unknown"
# The watcher's pending-reply tick (bin/fm-watch.sh -> fm_pending_reply_tick)
# escalates an undelivered delivery-unknown correlation before any resume runs.
bash -c '. "$1"; fm_pending_reply_tick "$2"' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT/state" \
  || fail "pending-reply tick failed on the undelivered wake"
[ "$(grep '^phase=' "$escalated_rec" | cut -d= -f2-)" = escalated ] \
  || fail "watcher tick did not escalate the undelivered wake, got $(grep '^phase=' "$escalated_rec")"
[ -z "$(grep '^delivered_epoch=' "$escalated_rec" | cut -d= -f2-)" ] \
  || fail "escalation must not invent a delivery for the undelivered wake"
[ "$(grep -cF "blocked [key=pending-reply-$escalated_corr]:" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "undelivered wake escalation was not published exactly once"
set +e
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending > "$TMP_ROOT/wake-escalated-resume.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  printf 'resume output:\n%s\n' "$(cat "$TMP_ROOT/wake-escalated-resume.out")" >&2
  fail "resume refused to retry the escalated undelivered wake (outbox deadlock)"
fi
assert_absent "$PARENT/data/handoff/ios.outbox.md" "escalated wake retry recreated a released outbox"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" "escalated wake retry left wake state behind"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq $((wakes_before + 3)) ] \
  || fail "escalated wake retry did not resend the wake exactly once after the two lost attempts"
[ -n "$(grep '^delivered_epoch=' "$escalated_rec" | cut -d= -f2-)" ] \
  || fail "successful wake retry did not confirm delivery on the same correlation"
[ "$(grep '^phase=' "$escalated_rec" | cut -d= -f2-)" = awaiting_report ] \
  || fail "delivered wake retry did not return the correlation to awaiting its report"
[ "$(grep -cF "blocked [key=pending-reply-$escalated_corr]:" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "wake retry duplicated the published escalation"
write_backlog '- [ ] after-escalated - next handoff flows once the escalated wake is retried (repo: alpha)'
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios after-escalated >/dev/null \
  || fail "handoff after the escalated wake retry did not flow"
[ "$(grep -cF after-escalated "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "handoff after the escalated wake retry was lost or duplicated"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "handoff after the escalated wake retry left an outbox pending"
pass "an escalated undelivered receiver wake stays retryable instead of jamming the outbox"

write_backlog '- [ ] wake-permanent-a - first handoff with permanently lost wake (repo: alpha)'
wakes_before=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
FM_FAKE_REMOTE_WAKE_RC=255 handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios wake-permanent-a \
  > "$TMP_ROOT/wake-permanent-a.out" 2>&1 \
  || fail "first durably received handoff was held hostage to a permanently lost wake"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "permanently lost wake retained the first durable outbox"
[ "$(grep -cF wake-permanent-a "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "first handoff under a permanently lost wake was lost or duplicated"
permanent_marker=$(cat "$PARENT/state/.backlog-handoff-ios.wake-pending" 2>/dev/null || true)
case "$permanent_marker" in
  pending:*) permanent_corr=${permanent_marker#pending:} ;;
  *) fail "permanently lost wake was not separately tracked, got '$permanent_marker'" ;;
esac
wakes_after_first=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
[ "$wakes_after_first" -gt "$wakes_before" ] || fail "first permanently lost wake was not attempted"
set +e
FM_FAKE_REMOTE_WAKE_RC=255 handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending \
  > "$TMP_ROOT/wake-permanent-resume.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "resume claimed that the permanently lost wake was confirmed"
[ "$(cat "$PARENT/state/.backlog-handoff-ios.wake-pending")" = "pending:$permanent_corr" ] \
  || fail "failed wake resume did not preserve the original correlation"
wakes_after_resume=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
[ "$wakes_after_resume" -gt "$wakes_after_first" ] || fail "resume did not retry the separately pending wake"
write_backlog '- [ ] wake-permanent-b - second handoff despite permanently lost wake (repo: alpha)'
FM_FAKE_REMOTE_WAKE_RC=255 handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios wake-permanent-b \
  > "$TMP_ROOT/wake-permanent-b.out" 2>&1 \
  || fail "second durable handoff was blocked by the permanently lost wake"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "permanently lost wake retained the second durable outbox"
[ "$(grep -cF wake-permanent-a "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "later handoff duplicated the first durably received item"
[ "$(grep -cF wake-permanent-b "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "later handoff was lost or duplicated behind the pending wake"
[ "$(cat "$PARENT/state/.backlog-handoff-ios.wake-pending")" = "pending:$permanent_corr" ] \
  || fail "later handoff did not retain the same pending wake correlation"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -gt "$wakes_after_resume" ] \
  || fail "later handoff did not retry the separately pending wake"
pass "a permanently unconfirmable wake never jams later durable handoffs"

RM_FAKEBIN="$TMP_ROOT/rm-fakebin"
mkdir -p "$RM_FAKEBIN"
REAL_RM=$(command -v rm)
cat > "$RM_FAKEBIN/rm" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_FAIL_RM_PATH" ]; then
  exit 1
fi
exec "$FM_REAL_RM" "$@"
SH
chmod +x "$RM_FAKEBIN/rm"
write_backlog '- [ ] cleanup-retry - confirmed wake survives cleanup retry (repo: alpha)'
wakes_before=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
set +e
PATH="$RM_FAKEBIN:$PATH" FM_REAL_RM="$REAL_RM" \
  FM_FAIL_RM_PATH="$PARENT/data/handoff/ios.outbox.md" \
  handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios cleanup-retry \
  > "$TMP_ROOT/cleanup-retry.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "remote handoff ignored local outbox cleanup failure"
assert_present "$PARENT/data/handoff/ios.outbox.md" \
  "remote cleanup failure did not preserve the outbox"
case "$(cat "$PARENT/state/.backlog-handoff-ios.wake-pending")" in
  confirmed:*) ;;
  *) fail "remote cleanup failure did not preserve confirmed wake state" ;;
esac
wakes_after=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
[ "$wakes_after" -eq $((wakes_before + 1)) ] \
  || fail "remote cleanup failure did not perform exactly one receiver wake"
write_backlog '- [ ] after-cleanup - fresh work after confirmed cleanup failure (repo: alpha)'
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios after-cleanup >/dev/null \
  || fail "fresh handoff did not converge an older confirmed cleanup failure"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq $((wakes_after + 1)) ] \
  || fail "fresh handoff reused the older confirmed wake instead of waking its receiver"
[ "$(grep -cF cleanup-retry "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "cleanup recovery lost or duplicated the older delivered item"
[ "$(grep -cF after-cleanup "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "fresh handoff after cleanup recovery was lost or duplicated"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "fresh handoff left the recovered outbox pending"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "fresh handoff left confirmed wake state behind"
pass "fresh remote work gets a new wake after confirmed cleanup recovery"

write_backlog '- [ ] confirmed-marker-stale - completed handoff ignores marker cleanup failure (repo: alpha)'
wakes_before=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
PATH="$RM_FAKEBIN:$PATH" FM_REAL_RM="$REAL_RM" \
  FM_FAIL_RM_PATH="$PARENT/state/.backlog-handoff-ios.wake-pending" \
  handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios confirmed-marker-stale \
  > "$TMP_ROOT/confirmed-marker-stale.out" 2>&1 \
  || fail "confirmed marker cleanup failure falsely failed a completed handoff"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "confirmed marker cleanup failure retained a completed outbox"
case "$(cat "$PARENT/state/.backlog-handoff-ios.wake-pending")" in
  confirmed:*) ;;
  *) fail "forced confirmed marker cleanup failure did not preserve confirmed state" ;;
esac
assert_contains "$(cat "$TMP_ROOT/confirmed-marker-stale.out")" \
  "stale confirmed wake marker remains at $PARENT/state/.backlog-handoff-ios.wake-pending" \
  "confirmed marker cleanup failure did not name the stale marker"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq $((wakes_before + 1)) ] \
  || fail "confirmed marker cleanup failure changed the completed wake count"
[ "$(grep -cF -- '- [ ] confirmed-marker-stale -' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "confirmed marker cleanup failure lost or duplicated durable work"
rm -f -- "$PARENT/state/.backlog-handoff-ios.wake-pending"
pass "confirmed marker cleanup cannot fail a completed remote handoff"

CONFIRM_MV_FAKEBIN="$TMP_ROOT/confirm-mv-fakebin"
mkdir -p "$CONFIRM_MV_FAKEBIN"
REAL_MV=$(command -v mv)
cat > "$CONFIRM_MV_FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_CONFIRM_MV_PATH" ]; then
  count=$(cat "$FM_CONFIRM_MV_COUNT" 2>/dev/null || echo 0)
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_CONFIRM_MV_COUNT"
  [ "$count" -ne 2 ] || exit 1
fi
exec "$FM_REAL_MV" "$@"
SH
chmod +x "$CONFIRM_MV_FAKEBIN/mv"
write_backlog '- [ ] delivered-pending-old - wake confirms before state promotion fails (repo: alpha)'
wakes_before=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
PATH="$CONFIRM_MV_FAKEBIN:$PATH" FM_REAL_MV="$REAL_MV" \
  FM_CONFIRM_MV_PATH="$PARENT/state/.backlog-handoff-ios.wake-pending" \
  FM_CONFIRM_MV_COUNT="$TMP_ROOT/confirm-mv.count" \
  handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios delivered-pending-old \
  > "$TMP_ROOT/delivered-pending-old.out" 2>&1 \
  || fail "confirmed wake state promotion failure failed durable work"
delivered_pending_marker=$(cat "$PARENT/state/.backlog-handoff-ios.wake-pending" 2>/dev/null || true)
case "$delivered_pending_marker" in
  pending:*) delivered_pending_corr=${delivered_pending_marker#pending:} ;;
  *) fail "confirmed wake state promotion failure did not leave pending correlation state" ;;
esac
delivered_pending_rec="$PARENT/state/pending-replies/$delivered_pending_corr"
[ -n "$(grep '^delivered_epoch=' "$delivered_pending_rec" | cut -d= -f2-)" ] \
  || fail "pending marker fixture did not retain confirmed delivery evidence"
write_backlog '- [ ] delivered-pending-new - new work after delivered pending marker (repo: alpha)'
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios delivered-pending-new >/dev/null \
  || fail "delivered pending marker blocked the next handoff"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq $((wakes_before + 2)) ] \
  || fail "delivered pending marker suppressed the new handoff wake"
[ "$(grep -cF -- '- [ ] delivered-pending-old -' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "state promotion failure lost or duplicated the older item"
[ "$(grep -cF -- '- [ ] delivered-pending-new -' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "handoff after delivered pending state was lost or duplicated"
assert_present "$delivered_pending_rec" \
  "clearing delivered pending state discarded its pending-reply record"
[ -n "$(grep '^delivered_epoch=' "$delivered_pending_rec" | cut -d= -f2-)" ] \
  || fail "clearing delivered pending state reset confirmed delivery"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "new handoff left delivered pending state behind"
pass "delivered pending state cannot suppress a new handoff wake"

MV_FAKEBIN="$TMP_ROOT/mv-fakebin"
mkdir -p "$MV_FAKEBIN"
REAL_MV=$(command -v mv)
cat > "$MV_FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_FAIL_MV_PATH" ]; then
  exit 1
fi
exec "$FM_REAL_MV" "$@"
SH
chmod +x "$MV_FAKEBIN/mv"
write_backlog '- [ ] wake-state-drop - durable work survives lost wake state (repo: alpha)'
pending_records_before=$(find "$PARENT/state/pending-replies" -maxdepth 1 -type f | wc -l | tr -d ' ')
wakes_before=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
PATH="$MV_FAKEBIN:$PATH" FM_REAL_MV="$REAL_MV" \
  FM_FAIL_MV_PATH="$PARENT/state/.backlog-handoff-ios.wake-pending" \
  handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios wake-state-drop \
  > "$TMP_ROOT/wake-state-drop.out" 2>&1 \
  || fail "wake-state write failure held the durable outbox hostage"
assert_contains "$(cat "$TMP_ROOT/wake-state-drop.out")" 'receiver wake state: DROPPED' \
  "wake-state write failure did not report an honest dropped state"
assert_contains "$(cat "$TMP_ROOT/wake-state-drop.out")" 'best-effort receiver wake was dropped' \
  "wake-state write failure did not log the dropped wake"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "wake-state write failure retained the durably received outbox"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "wake-state write failure left a marker claiming the wake was pending"
pending_records_after=$(find "$PARENT/state/pending-replies" -maxdepth 1 -type f | wc -l | tr -d ' ')
[ "$pending_records_after" -eq "$pending_records_before" ] \
  || fail "wake-state write failure left an unreferenced pending-reply record"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq "$wakes_before" ] \
  || fail "wake-state write failure attempted an untracked wake"
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null \
  || fail "resume treated the dropped wake as pending"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq "$wakes_before" ] \
  || fail "resume retried a wake whose state was dropped"
write_backlog '- [ ] after-wake-state-drop - later handoff after dropped wake state (repo: alpha)'
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios after-wake-state-drop >/dev/null \
  || fail "later handoff was blocked by dropped wake state"
[ "$(grep -cF -- '- [ ] wake-state-drop -' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "wake-state failure lost or duplicated its durably received item"
[ "$(grep -cF -- '- [ ] after-wake-state-drop -' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "later handoff after dropped wake state was lost or duplicated"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "later successful handoff left stale wake state"
pass "unrecordable best-effort wake state drops without blocking later handoffs"

stale_wake_marker="$PARENT/state/.backlog-handoff-ios.wake-pending"
printf 'invalid wake state\n' > "$stale_wake_marker"
PATH="$RM_FAKEBIN:$PATH" FM_REAL_RM="$REAL_RM" FM_FAIL_RM_PATH="$stale_wake_marker" \
  handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending \
  > "$TMP_ROOT/stale-wake-resume.out" 2>&1 \
  || fail "resume was blocked by an undeletable invalid wake marker"
assert_present "$stale_wake_marker" "invalid wake marker did not survive the forced removal failure"
assert_contains "$(cat "$TMP_ROOT/stale-wake-resume.out")" 'receiver wake state: DROPPED' \
  "resume did not report the invalid wake marker as dropped"
assert_contains "$(cat "$TMP_ROOT/stale-wake-resume.out")" "stale wake marker remains at $stale_wake_marker" \
  "resume did not name the surviving stale wake marker"
write_backlog '- [ ] after-stale-wake - later handoff ignores stale wake state (repo: alpha)'
PATH="$RM_FAKEBIN:$PATH" FM_REAL_RM="$REAL_RM" FM_FAIL_RM_PATH="$stale_wake_marker" \
  handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios after-stale-wake \
  > "$TMP_ROOT/after-stale-wake.out" 2>&1 \
  || fail "later handoff was blocked by an undeletable invalid wake marker"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "stale wake marker retained the later handoff outbox"
[ "$(grep -cF -- '- [ ] after-stale-wake -' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "handoff past a stale wake marker was lost or duplicated"
assert_contains "$(cat "$TMP_ROOT/after-stale-wake.out")" 'receiver wake state: DROPPED' \
  "later handoff did not report the stale wake as dropped"
assert_contains "$(cat "$TMP_ROOT/after-stale-wake.out")" "stale wake marker remains at $stale_wake_marker" \
  "later handoff did not name the surviving stale wake marker"
assert_present "$stale_wake_marker" "later handoff concealed the forced stale-marker removal failure"
rm -f -- "$stale_wake_marker"
pass "undeletable invalid wake state cannot block remote handoffs"

write_backlog '- [ ] route-race - remains dispatchable through retirement (repo: alpha)'
registry_lock="$PARENT/state/.secondmate-registry.lock"
handoff_lock="$PARENT/state/.backlog-handoff-ios.lock"
FM_HOME="$PARENT" /bin/bash -c '
  . "$1"
  fm_lock_acquire_wait "$2"
  fm_lock_acquire_wait "$3"
  touch "$4"
  while [ ! -f "$5" ]; do sleep 0.02; done
  tmp="$6.tmp.$$"
  grep -vE "^- ios( |$)" "$6" > "$tmp" || true
  mv -f -- "$tmp" "$6"
  fm_lock_release "$3"
  fm_lock_release "$2"
' _ "$ROOT/bin/fm-wake-lib.sh" "$registry_lock" "$handoff_lock" \
  "$TMP_ROOT/route.entered" "$TMP_ROOT/route.release" "$PARENT/data/secondmates.md" &
route_holder_pid=$!
route_wait=0
while [ ! -f "$TMP_ROOT/route.entered" ]; do
  kill -0 "$route_holder_pid" 2>/dev/null || fail "route lock holder exited before acquiring lifecycle locks"
  route_wait=$((route_wait + 1))
  [ "$route_wait" -le 250 ] || fail "route lock holder never acquired lifecycle locks"
  sleep 0.02
done
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios route-race \
  > "$TMP_ROOT/route-race.out" 2>&1 &
route_handoff_pid=$!
sleep 0.2
kill -0 "$route_handoff_pid" 2>/dev/null || fail "handoff bypassed the lifecycle lock boundary"
touch "$TMP_ROOT/route.release"
wait "$route_holder_pid" || fail "route lock holder failed to retire the route"
if wait "$route_handoff_pid"; then
  fail "handoff accepted a route removed at its lifecycle boundary"
fi
assert_grep 'route-race' "$PARENT/data/backlog.md" "route retirement stranded queued work outside the primary backlog"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "route retirement left an orphaned handoff outbox"
pass "route classification serializes with retirement before staging"

# With no handoff directory or remote route, bootstrap neither invokes SSH nor
# emits a remote handoff line.
FRESH="$TMP_ROOT/fresh"
mkdir -p "$FRESH/data" "$FRESH/state"
: > "$SSH_COUNT"
fresh_out=$(FM_HOME="$FRESH" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
  FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>&1)
assert_not_contains "$fresh_out" 'SECONDMATE_HANDOFF:' "unconfigured bootstrap emitted a remote handoff diagnostic"
[ ! -s "$SSH_COUNT" ] || fail "unconfigured bootstrap touched SSH"
pass "unconfigured bootstrap has no remote handoff behavior"

echo "ALL TESTS PASSED"

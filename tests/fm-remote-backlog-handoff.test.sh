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
  "$ROOT/bin/fm-work-identity.sh" "$ROOT/bin/fm-work-identity-fs.py" "$ROOT/bin/fm-pr-lib.sh" \
  "$ROOT/bin/fm-wake-lib.sh" "$REMOTE_ROOT/bin/"
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
command_arg=$(perl -MMIME::Base64=decode_base64 -e '$d=decode_base64($ARGV[0]); @p=split(/\0/, $d); print $p[1] // ""' "$argv_b64")
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_arg" in
  *:fm-remote-secondmate-control.sh:*)
    printf '%s\n' "$command_name" >> "$FM_FAKE_REMOTE_WAKE_LOG"
    [ "${FM_FAKE_REMOTE_WAKE_RC:-0}" -eq 0 ] || printf 'remote receiver wake failed\n' >&2
    exit "${FM_FAKE_REMOTE_WAKE_RC:-0}"
    ;;
  unreachable:*) exit 255 ;;
  serialize:fm-backlog-receive.sh:state/handoff/*)
    if mkdir "$FM_FAKE_SERIALIZE_ONCE" 2>/dev/null; then
      touch "$FM_FAKE_SERIALIZE_ENTERED"
      while [ ! -f "$FM_FAKE_SERIALIZE_RELEASE" ]; do sleep 0.02; done
    fi
    exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    ;;
  after-put:fm-remote-file.sh:*)
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    exit 255
    ;;
  after-receive:fm-backlog-receive.sh:state/handoff/*)
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
    exit 255
    ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || printf '%s\n' '0.1.25'
exit 0
SH
chmod +x "$FAKEBIN/quota-axi"

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

receiver_preflight_refuses_changed_commitment() {
  local preflight_task preflight_task_hash preflight_transfer preflight_bytes preflight_hash rc=0
  preflight_task=receipt-preflight-race
  write_backlog '- [ ] receipt-preflight-race - original committed row (repo: alpha)'
  printf '%s\n' '- [ ] receipt-preflight-race - original committed row (repo: alpha)' \
    > "$TMP_ROOT/preflight-original-row"
  preflight_task_hash=$(sha256_file "$TMP_ROOT/preflight-original-row")
  preflight_transfer=$(FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" \
    handoff-prepare "$preflight_task" --to-home "$REMOTE" --to-home-id secondmate:ios \
      --backlog-sha256 "$preflight_task_hash")
  printf '%s\n' "$preflight_transfer" | FM_HOME="$REMOTE" \
    "$REMOTE_ROOT/bin/fm-work-identity.sh" handoff-stage "$preflight_task" --file - >/dev/null
  printf '%s\n' "$preflight_transfer" | FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    "$REMOTE_ROOT/bin/fm-backlog-receive.sh" --prepare-handoff "$preflight_task" >/dev/null
  cat > "$TMP_ROOT/preflight-delivery.md" <<'EOF'
## In flight

## Queued
- [ ] receipt-preflight-race - changed after target reservation (repo: alpha)

## Done
EOF
  preflight_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/preflight-delivery.md" | tr -d ' ')
  preflight_hash=$(sha256_file "$TMP_ROOT/preflight-delivery.md")
  FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-remote-file.sh" \
    put state/handoff/preflight.outbox.md 1048576 "$preflight_bytes" "$preflight_hash" 1 \
    < "$TMP_ROOT/preflight-delivery.md" >/dev/null
  FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    "$REMOTE_ROOT/bin/fm-backlog-receive.sh" state/handoff/preflight.outbox.md \
      "$preflight_bytes" "$preflight_hash" 1 > "$TMP_ROOT/preflight-receive.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "receiver accepted a backlog row changed after target reservation"
  if [ -e "$REMOTE/data/backlog.md" ]; then
    assert_no_grep "$preflight_task" "$REMOTE/data/backlog.md" \
      "receiver moved a row before validating its exact target commitment"
  fi
  assert_present "$REMOTE/state/handoff/preflight.outbox.md" \
    "receiver discarded a refused delivery scratch record"
  pass "receiver validates every target commitment before batch move"
}

receiver_refuses_malformed_later_receipt_without_reserving_earlier_key() {
  local first second first_row second_row first_hash second_hash first_transfer second_transfer
  local delivery bytes digest first_receipt rc=0
  first=receipt-batch-valid
  second=receipt-batch-malformed
  first_row='- [ ] receipt-batch-valid - valid earlier batch row (repo: alpha)'
  second_row='- [ ] receipt-batch-malformed - malformed later batch row (repo: alpha)'
  printf '%s\n' "$first_row" > "$TMP_ROOT/receipt-batch-first-row"
  printf '%s\n' "$second_row" > "$TMP_ROOT/receipt-batch-second-row"
  first_hash=$(sha256_file "$TMP_ROOT/receipt-batch-first-row")
  second_hash=$(sha256_file "$TMP_ROOT/receipt-batch-second-row")
  first_transfer=$(FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" \
    handoff-prepare "$first" --to-home "$REMOTE" --to-home-id secondmate:ios \
      --backlog-sha256 "$first_hash")
  second_transfer=$(FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" \
    handoff-prepare "$second" --to-home "$REMOTE" --to-home-id secondmate:ios \
      --backlog-sha256 "$second_hash")
  printf '%s\n' "$first_transfer" | FM_HOME="$REMOTE" \
    "$REMOTE_ROOT/bin/fm-work-identity.sh" handoff-stage "$first" --file - >/dev/null
  printf '%s\n' "$second_transfer" | FM_HOME="$REMOTE" \
    "$REMOTE_ROOT/bin/fm-work-identity.sh" handoff-stage "$second" --file - >/dev/null
  first_receipt="$REMOTE/data/$first/work-identity-handoff-target.json"
  printf '%s\n' malformed > "$REMOTE/data/$second/work-identity-handoff-target.json"
  delivery="$TMP_ROOT/receipt-batch-delivery.md"
  cat > "$delivery" <<EOF
## In flight

## Queued
$first_row
$second_row

## Done
EOF
  bytes=$(LC_ALL=C wc -c < "$delivery" | tr -d ' ')
  digest=$(sha256_file "$delivery")
  FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-remote-file.sh" \
    put state/handoff/receipt-batch.outbox.md 1048576 "$bytes" "$digest" 1 \
    < "$delivery" >/dev/null
  FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    "$REMOTE_ROOT/bin/fm-backlog-receive.sh" state/handoff/receipt-batch.outbox.md \
      "$bytes" "$digest" 1 > "$TMP_ROOT/receipt-batch.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "receiver accepted a malformed later identity receipt"
  jq -e '.role == "target" and .state == "prepared"' "$first_receipt" >/dev/null \
    || fail "receiver partially reserved the earlier identity before refusing the batch"
  if [ -e "$REMOTE/data/backlog.md" ]; then
    assert_no_grep "$first" "$REMOTE/data/backlog.md" \
      "receiver moved the earlier row before refusing the malformed later receipt"
    assert_no_grep "$second" "$REMOTE/data/backlog.md" \
      "receiver moved the malformed later row"
  fi
  pass "receiver validates the complete identity batch before reservation"
}

if [ "${FM_TEST_ONLY:-}" = receiver-preflight ]; then
  receiver_preflight_refuses_changed_commitment
  receiver_refuses_malformed_later_receipt_without_reserving_earlier_key
  exit 0
fi

# Completion can become unknown after the remote atomic move. The local outbox
# remains the backlog recovery record alongside the source identity prepare.
# The primary dispatch queue is already empty, and the transport does not retry blindly.
write_backlog $'- [ ] ios-a - first iOS task (repo: alpha)\n- [ ] ios-b - dependent iOS task (repo: alpha) blocked-by: ios-a - waits'
: > "$SSH_COUNT"
set +e
FM_FAKE_SSH_MODE=after-receive handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios ios-a ios-b \
  > "$TMP_ROOT/ambiguous.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "handoff claimed success after ambiguous remote receipt"
if grep -F ios-a "$PARENT/data/backlog.md" >/dev/null; then
  printf 'handoff output:\n%s\n' "$(cat "$TMP_ROOT/ambiguous.out")" >&2
  fail "ambiguous handoff left ios-a dispatchable in the primary backlog"
fi
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
[ "$(cat "$SSH_COUNT")" -eq 6 ] || fail "transport retried an ambiguously completed command"
pass "ambiguous receipt leaves one durable outbox and no duplicate dispatchable source"

write_backlog '- [ ] ios-c - new work joining a pending outbox (repo: alpha)'
out=$(handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios ios-c)
assert_contains "$out" 'received: ios moved=1 already=2' \
  "new handoff did not include every row from the pending outbox"
[ "$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")" -eq 1 ] \
  || fail "confirmed remote receipt did not wake its supported receiver endpoint exactly once"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "confirmed retry did not clean the local outbox"
[ "$(grep -cF -- '- [ ] ios-a - first iOS task' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "receipt retry duplicated ios-a"
[ "$(grep -cF -- '- [ ] ios-b - dependent iOS task' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "receipt retry duplicated ios-b"
[ "$(grep -cF -- '- [ ] ios-c - new work joining' "$REMOTE/data/backlog.md")" -eq 1 ] \
  || fail "new handoff did not deliver ios-c"
jq -e '.role == "source" and .state == "completed"' \
  "$PARENT/data/ios-a/work-identity-handoff-source.json" >/dev/null \
  || fail "new handoff deleted the outbox before completing ios-a source ownership"
jq -e '.role == "target" and .state == "completed"' \
  "$REMOTE/data/ios-a/work-identity-handoff-target.json" >/dev/null \
  || fail "new handoff deleted the outbox before committing ios-a target ownership"
pass "new remote handoff preserves identities for every pending outbox row"

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
write_backlog '- [ ] transfer-cut - survives a dropped transfer (repo: alpha)'
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null \
  || fail "recovery after dropped transfer failed"
assert_grep 'transfer-cut' "$REMOTE/data/backlog.md" "recovery after dropped transfer lost the item"
assert_no_grep 'transfer-cut' "$PARENT/data/backlog.md" \
  "recovery after target-first interruption retained a duplicate source row"
assert_absent "$PARENT/data/handoff/ios.outbox.md" "recovery after dropped transfer left the local outbox"
pass "dropped transfer recovery removes exact interrupted source duplicates"

mkdir -p "$TMP_ROOT/external-resume-handoff"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$TMP_ROOT/external-resume-handoff/ios.outbox.md"
mv "$PARENT/data/handoff" "$TMP_ROOT/anchored-resume-handoff"
ln -s "$TMP_ROOT/external-resume-handoff" "$PARENT/data/handoff"
if handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null 2>&1; then
  fail "pending handoff recovery followed a symlinked handoff directory"
fi
assert_present "$TMP_ROOT/external-resume-handoff/ios.outbox.md" \
  "pending handoff recovery removed an external symlink target"
rm -f "$PARENT/data/handoff"
mv "$TMP_ROOT/anchored-resume-handoff" "$PARENT/data/handoff"
printf '## In flight\n\n## Queued\n- [ ] linked-resume - unsafe outbox\n\n## Done\n' \
  > "$TMP_ROOT/hardlinked-resume.outbox.md"
ln "$TMP_ROOT/hardlinked-resume.outbox.md" "$PARENT/data/handoff/ios.outbox.md"
if handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null 2>&1; then
  fail "pending handoff recovery accepted a hardlinked outbox"
fi
assert_present "$TMP_ROOT/hardlinked-resume.outbox.md" \
  "pending handoff recovery removed a hardlinked external outbox"
rm -f "$PARENT/data/handoff/ios.outbox.md" "$TMP_ROOT/hardlinked-resume.outbox.md"
pass "pending handoff recovery refuses symlinked and hardlinked records"

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
  if [ "$wait_for_serialization" -gt 250 ]; then
    printf 'serialized handoff output:\n%s\n' "$(cat "$TMP_ROOT/serialized-a.out")" >&2
    fail "first serialized handoff never reached receipt"
  fi
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

conflict_task=target-conflict
write_backlog '- [ ] target-conflict - target identity conflict (repo: alpha)'
FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" template "$conflict_task" \
  | jq '.initiative.id="source-project" | .plan_id.id="source-plan" | .stage.id="source-stage"
      | .work_units[0].id="source-unit" | .sources[0].id="source-issue"' \
  > "$TMP_ROOT/source-conflict.json"
FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" record "$conflict_task" \
  --file "$TMP_ROOT/source-conflict.json" >/dev/null
FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-work-identity.sh" template "$conflict_task" \
  | jq '.initiative.id="target-project" | .plan_id.id="target-plan" | .stage.id="target-stage"
      | .work_units[0].id="target-unit" | .sources[0].id="target-issue"' \
  > "$TMP_ROOT/target-conflict.json"
FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-work-identity.sh" record "$conflict_task" \
  --file "$TMP_ROOT/target-conflict.json" >/dev/null
rc=0
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios "$conflict_task" \
  > "$TMP_ROOT/target-conflict.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "remote handoff moved a row before detecting its target identity conflict"
assert_grep "$conflict_task" "$PARENT/data/backlog.md" \
  "target identity conflict removed the source backlog row"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "target identity conflict published a remote outbox"
assert_absent "$PARENT/data/$conflict_task/work-identity-handoff-source.json" \
  "target identity conflict retained a source reservation after exact compensation"
assert_absent "$REMOTE/data/$conflict_task/work-identity-handoff-target.json" \
  "target identity conflict published a destination reservation"
FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-work-identity.sh" verify "$conflict_task" \
  | jq -e '.status == "linked" and .initiative.id == "target-project"' >/dev/null \
  || fail "target identity conflict changed the pre-existing exact target relation"
pass "remote handoff reserves target identity before moving source backlog rows"

write_backlog '- [ ] linked-remote - linked remote handoff (repo: alpha)'
manifest="$PARENT/linked-remote.json"
FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" template linked-remote \
  | jq '.initiative.id="remote-project"
      | .plan_id.id="remote-plan"
      | .stage.id="remote-stage"
      | .work_units=[{namespace:"work-aligner",kind:"work-unit",id:"remote-unit",label:"Remote Unit"}]
      | .sources=[{namespace:"dtm",kind:"issue",id:"DTM-REMOTE-1",label:"Remote Issue"}]' \
  > "$manifest"
FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" record linked-remote --file "$manifest" >/dev/null
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios linked-remote >/dev/null \
  || fail "linked remote handoff failed"
FM_HOME="$REMOTE" "$REMOTE_ROOT/bin/fm-work-identity.sh" verify linked-remote \
  | jq -e --arg home "$REMOTE" '
      .status == "linked" and .binding.home == $home
        and .binding.home_id == "secondmate:ios" and .binding.task_id == "linked-remote"
        and .work_units[0].id == "remote-unit" and .sources[0].id == "DTM-REMOTE-1"
    ' >/dev/null || fail "remote receipt lost or misbound the exact work identity"
assert_grep 'linked-remote' "$REMOTE/data/backlog.md" "linked remote backlog row did not arrive"
jq -e '.role == "target" and .state == "completed"
    and .transfer.source.home_id == "main"' \
  "$REMOTE/data/linked-remote/work-identity-handoff-target.json" >/dev/null \
  || fail "remote handoff did not retain a completed target ownership receipt"
jq -e '.state == "completed" and .transfer.target.home_id == "secondmate:ios"' \
  "$PARENT/data/linked-remote/work-identity-handoff-source.json" >/dev/null \
  || fail "remote handoff did not retain a completed source ownership tombstone"
pass "remote handoff commits an exact destination identity and source tombstone"

receiver_preflight_refuses_changed_commitment
receiver_refuses_malformed_later_receipt_without_reserving_earlier_key

recovered_task=receipt-recovery-a
conflicting_task=receipt-recovery-b
write_backlog $'- [ ] receipt-recovery-a - committed target awaiting source completion (repo: alpha)\n- [ ] receipt-recovery-b - conflicting later prepare (repo: alpha)'
printf '%s\n' '- [ ] receipt-recovery-a - committed target awaiting source completion (repo: alpha)' \
  > "$TMP_ROOT/recovered-block"
recovered_hash=$(sha256_file "$TMP_ROOT/recovered-block")
recovered_transfer=$(FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" \
  handoff-prepare "$recovered_task" --to-home "$REMOTE" --to-home-id secondmate:ios \
    --backlog-sha256 "$recovered_hash")
printf '%s\n' "$recovered_transfer" | FM_HOME="$REMOTE" \
  "$REMOTE_ROOT/bin/fm-work-identity.sh" handoff-stage "$recovered_task" --file - >/dev/null
printf '%s\n' "$recovered_transfer" | FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-backlog-receive.sh" --prepare-handoff "$recovered_task" >/dev/null
mkdir -p "$PARENT/data/handoff"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/handoff/ios.outbox.md"
tasks-axi mv "$recovered_task" --file "$PARENT/data/backlog.md" \
  --to "$PARENT/data/handoff/ios.outbox.md" >/dev/null
cp "$PARENT/data/handoff/ios.outbox.md" "$TMP_ROOT/recovered-delivery.md"
tasks-axi mv "$recovered_task" --file "$TMP_ROOT/recovered-delivery.md" \
  --to "$REMOTE/data/backlog.md" >/dev/null
printf '%s\n' "$recovered_transfer" | FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-backlog-receive.sh" --complete-handoff "$recovered_task" >/dev/null
printf '%s\n' "$recovered_transfer" | FM_HOME="$REMOTE" \
  "$REMOTE_ROOT/bin/fm-work-identity.sh" handoff-commit "$recovered_task" --file - >/dev/null
printf 'kind=ship\n' > "$PARENT/state/$conflicting_task.meta"
rc=0
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios \
  "$recovered_task" "$conflicting_task" > "$TMP_ROOT/receipt-recovery.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "mixed remote retry ignored the later source prepare conflict"
jq -e '.role == "source" and .state == "completed"
    and .transfer.target.home_id == "secondmate:ios"' \
  "$PARENT/data/$recovered_task/work-identity-handoff-source.json" >/dev/null \
  || fail "mixed remote retry canceled ownership after a proven destination commit"
jq -e '.role == "target" and .state == "completed"' \
  "$REMOTE/data/$recovered_task/work-identity-handoff-target.json" >/dev/null \
  || fail "mixed remote retry lost its committed destination receipt"
if FM_HOME="$PARENT" "$ROOT/bin/fm-work-identity.sh" verify "$recovered_task" >/dev/null 2>&1; then
  fail "mixed remote retry resurrected source ownership"
fi
assert_grep "$conflicting_task" "$PARENT/data/backlog.md" \
  "mixed remote retry moved the conflicting source backlog item"
rm -f -- "$PARENT/state/$conflicting_task.meta" "$PARENT/data/handoff/ios.outbox.md"
pass "mixed remote recovery completes source ownership from the target receipt"

# A stale tasks-axi lock is removed only on the destination host after the first
# move refusal proves a retry is needed. The dead pid and age satisfy the same
# conservative procedure tasks-axi prints.
write_backlog '- [ ] stale-lock-item - remote stale lock recovery (repo: alpha)'
printf '999999:abandoned:0:1\n' > "$REMOTE/data/backlog.md.lock"
if [ "$(uname 2>/dev/null)" = Darwin ]; then
  touch -t 202001010000 "$REMOTE/data/backlog.md.lock"
else
  touch -d '2020-01-01 00:00:00' "$REMOTE/data/backlog.md.lock"
fi
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios stale-lock-item >/dev/null \
  || fail "host-local stale lock recovery did not retry receipt"
assert_grep 'stale-lock-item' "$REMOTE/data/backlog.md" "stale-lock receipt lost the item"
assert_absent "$REMOTE/data/backlog.md.lock" "stale destination lock survived successful receipt"
pass "receiver removes one proven dead stale lock and retries once"

# An unreachable target cannot reserve identity, so source backlog mutation never starts.
write_backlog '- [ ] pending-offline - waits for the remote Mac (repo: alpha)'
set +e
FM_FAKE_SSH_MODE=unreachable handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios pending-offline \
  > "$TMP_ROOT/offline.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "offline handoff claimed success"
assert_grep 'pending-offline' "$PARENT/data/backlog.md" \
  "offline identity reservation removed the source backlog row"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "offline identity reservation published an unreserved outbox"
jq -e '.role == "source" and .state == "prepared"' \
  "$PARENT/data/pending-offline/work-identity-handoff-source.json" >/dev/null \
  || fail "offline identity reservation lost its unknown-completion recovery receipt"
pass "offline target reservation preserves recovery without source backlog mutation"

write_backlog '- [ ] remote-wake-fail - receiver failure stays recoverable (repo: alpha)'
set +e
FM_FAKE_REMOTE_WAKE_RC=1 handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios remote-wake-fail \
  > "$TMP_ROOT/remote-wake-fail.out" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "remote handoff claimed success after its receiver wake failed"
assert_contains "$(cat "$TMP_ROOT/remote-wake-fail.out")" 'receiver wake failed' \
  "remote receiver wake failure was not surfaced"
assert_present "$PARENT/data/handoff/ios.outbox.md" \
  "remote receiver wake failure discarded the recoverable outbox"
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" --resume-pending >/dev/null \
  || fail "remote receiver wake failure did not recover through resume-pending"
assert_absent "$PARENT/data/handoff/ios.outbox.md" \
  "remote receiver wake recovery left its outbox pending"
pass "remote handoff wakes its supported endpoint or remains loudly recoverable"

CLEANUP_FAKEBIN="$TMP_ROOT/cleanup-fakebin"
mkdir -p "$CLEANUP_FAKEBIN"
REAL_PYTHON3=$(command -v python3)
cat > "$CLEANUP_FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "$FM_FAIL_PYTHON_OWNER" ] && [ "${2:-}" = remove ] \
  && [ "${3:-}/${5:-}" = "$FM_FAIL_REMOVE_PATH" ]; then
  exit 1
fi
exec "$FM_REAL_PYTHON3" "$@"
SH
chmod +x "$CLEANUP_FAKEBIN/python3"
write_backlog '- [ ] cleanup-retry - confirmed wake survives cleanup retry (repo: alpha)'
wakes_before=$(grep -cF fm-remote-secondmate-control.sh "$WAKE_LOG")
set +e
PATH="$CLEANUP_FAKEBIN:$PATH" FM_REAL_PYTHON3="$REAL_PYTHON3" \
  FM_FAIL_PYTHON_OWNER="$ROOT/bin/fm-work-identity-fs.py" \
  FM_FAIL_REMOVE_PATH="$PARENT/data/handoff/ios.outbox.md" \
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
printf '%s\n' \
  "- ios - iOS delivery (host: remote-mac; root: $REMOTE_ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)" \
  > "$PARENT/data/secondmates.md"

write_backlog '- [ ] remote-collision - source work that must remain (repo: alpha)'
mkdir -p "$PARENT/data/handoff"
cat > "$PARENT/data/handoff/ios.outbox.md" <<'EOF'
## In flight

## Queued
- [ ] remote-collision - unrelated pending outbox work (repo: beta)

## Done
EOF
cp "$PARENT/data/backlog.md" "$TMP_ROOT/remote-collision-source.before"
cp "$PARENT/data/handoff/ios.outbox.md" "$TMP_ROOT/remote-collision-outbox.before"
rc=0
handoff_env "$ROOT/bin/fm-backlog-handoff.sh" ios remote-collision \
  > "$TMP_ROOT/remote-collision.out" 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "remote same-ID outbox collision was accepted"
cmp -s "$TMP_ROOT/remote-collision-source.before" "$PARENT/data/backlog.md" \
  || fail "remote same-ID collision changed source work"
cmp -s "$TMP_ROOT/remote-collision-outbox.before" "$PARENT/data/handoff/ios.outbox.md" \
  || fail "remote same-ID collision changed pending outbox work"
assert_contains "$(cat "$TMP_ROOT/remote-collision.out")" \
  "same-ID source and outbox rows with different content" \
  "remote same-ID collision did not refuse at exact content classification"
assert_absent "$PARENT/data/remote-collision/work-identity-handoff-source.json" \
  "remote same-ID collision prepared source identity"
assert_absent "$REMOTE/data/remote-collision/work-identity-handoff-target.json" \
  "remote same-ID collision prepared target identity"
rm -f -- "$PARENT/data/handoff/ios.outbox.md"
pass "remote same-ID outbox rows require exact source content"

# With no handoff directory or remote route, bootstrap neither invokes SSH nor
# emits a remote handoff line.
FRESH="$TMP_ROOT/fresh"
mkdir -p "$FRESH/data" "$FRESH/state"
: > "$SSH_COUNT"
fresh_out=$(FM_HOME="$FRESH" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
  FM_BOOTSTRAP_DETECT_ONLY=1 PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
assert_not_contains "$fresh_out" 'SECONDMATE_HANDOFF:' "unconfigured bootstrap emitted a remote handoff diagnostic"
[ ! -s "$SSH_COUNT" ] || fail "unconfigured bootstrap touched SSH"
pass "unconfigured bootstrap has no remote handoff behavior"

echo "ALL TESTS PASSED"

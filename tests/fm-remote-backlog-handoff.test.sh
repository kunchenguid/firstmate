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
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE_ROOT/bin" \
  "$REMOTE/data" "$REMOTE/state" "$REMOTE/config" "$REMOTE/projects" "$REMOTE/bin"
trap 'touch "$TMP_ROOT/put.release" "$TMP_ROOT/route.release" 2>/dev/null || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; rm -rf -- "$TMP_ROOT"' EXIT
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" \
  "$ROOT/bin/fm-remote-job-worker.sh" "$ROOT/bin/fm-remote-file.sh" \
  "$ROOT/bin/fm-backlog-receive.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
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

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
trap 'rm -rf -- "$TMP_ROOT"' EXIT
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-file.sh" \
  "$ROOT/bin/fm-backlog-receive.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" "$REMOTE_ROOT/bin/"
ln -s "$(command -v tasks-axi)" "$REMOTE_ROOT/bin/tasks-axi"
ln -s "$(command -v node)" "$REMOTE_ROOT/bin/node"
chmod +x "$REMOTE_ROOT/bin"/*.sh
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
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  "$@"
}

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

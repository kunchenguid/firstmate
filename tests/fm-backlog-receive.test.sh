#!/usr/bin/env bash
# Characterization coverage for fm-backlog-receive.sh's successful receipt
# contract and commitment-mismatch refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-receive)

# Same fallback the receiver uses so a host without shasum still hashes.
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# seed_delivered_home <home-dir>: build a secondmate home holding one delivered
# outbox plus the upload generation that commits to its exact bytes and digest.
# Echoes "<bytes> <hash>" so a caller can pass the same commitment the sender
# recorded - or deliberately break it.
seed_delivered_home() {  # <home-dir>
  local home=$1 delivered bytes hash
  delivered="$home/state/handoff/ios.outbox.md"
  mkdir -p "$home/bin" "$home/data" "$(dirname "$delivered")"
  printf 'fixture\n' > "$home/AGENTS.md"
  printf 'ios\n' > "$home/.fm-secondmate-home"
  cat > "$delivered" <<'OUTBOX'
## In flight

## Queued
- [ ] ios-task - received remotely (repo: alpha)

## Done
OUTBOX
  bytes=$(LC_ALL=C wc -c < "$delivered" | tr -d ' ')
  hash=$(sha256_file "$delivered")
  printf '7\n%s\n%s\n' "$bytes" "$hash" > "$home/state/handoff/.ios.upload-generation"
  printf '%s %s\n' "$bytes" "$hash"
}

MISMATCH_HOME="$TMP_ROOT/mismatch-home"
MISMATCH_DELIVERED="$MISMATCH_HOME/state/handoff/ios.outbox.md"
mismatch_commitment=$(seed_delivered_home "$MISMATCH_HOME") \
  || fail "could not seed the mismatch fixture"
read -r mismatch_bytes mismatch_hash <<< "$mismatch_commitment"

# Same length, different payload: the stored commitment no longer matches the file.
printf 'X' | dd of="$MISMATCH_DELIVERED" bs=1 seek=0 conv=notrunc 2>/dev/null
mutated_hash=$(sha256_file "$MISMATCH_DELIVERED")
[ "$mutated_hash" != "$mismatch_hash" ] \
  || fail "could not mutate the delivered outbox without changing its length"

mismatch_rc=0
mismatch_out=$(FM_HOME="$MISMATCH_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-backlog-receive.sh" state/handoff/ios.outbox.md \
  "$mismatch_bytes" "$mismatch_hash" 7 2>&1) || mismatch_rc=$?
expect_code 1 "$mismatch_rc" "a digest mismatch must be refused"
assert_contains "$mismatch_out" "digest does not match its commitment" \
  "a digest mismatch must name the commitment refusal"
assert_present "$MISMATCH_DELIVERED" \
  "a refused receipt must preserve the delivered scratch file"
assert_absent "$MISMATCH_HOME/data/backlog.md" \
  "a refused receipt must not create a destination backlog"
pass "fm-backlog-receive.sh refuses a delivered outbox that mismatches its commitment"

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "skip: tasks-axi not found; success-path receipt not exercised"
  exit 0
fi

HOME_FIXTURE="$TMP_ROOT/home"
DELIVERED="$HOME_FIXTURE/state/handoff/ios.outbox.md"
commitment=$(seed_delivered_home "$HOME_FIXTURE") || fail "could not seed the delivered fixture"
read -r bytes hash <<< "$commitment"

out=$(FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-backlog-receive.sh" state/handoff/ios.outbox.md "$bytes" "$hash" 7)
assert_contains "$out" 'received: ios moved=1 already=0' \
  "successful receipt must report the moved item count"
assert_grep 'ios-task' "$HOME_FIXTURE/data/backlog.md" \
  "successful receipt must move the queued item into the destination backlog"
assert_absent "$DELIVERED" \
  "successful receipt must remove the delivered scratch file"
pass "fm-backlog-receive.sh receives one committed queued item"

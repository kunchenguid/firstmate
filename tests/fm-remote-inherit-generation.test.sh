#!/usr/bin/env bash
# Inheritance counter recovery through synthetic homes and the fake SSH boundary.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$ROOT/bin/fm-secondmate-nudge-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-inherit-generation)
PARENT="$TMP_ROOT/parent"
REMOTE_HOME="$TMP_ROOT/receiver"
mkdir -p "$PARENT/config" "$PARENT/data" "$PARENT/state" "$REMOTE_HOME/config" "$REMOTE_HOME/data"
cat > "$PARENT/data/secondmates.md" <<EOF
- fixture - Synthetic inheritance (host: fixture-host; root: $ROOT; home: $REMOTE_HOME; scope: fixtures; projects: none; added 2026-11-05)
EOF
cat > "$TMP_ROOT/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = fixture-host ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
shift 2
[ "$1" = 1 ] || exit 92
decode() { perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$1"; }
root=$(decode "$2")
receiver=$(decode "$3")
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(decode "$4")
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 93
[ -d "$FM_FIXTURE_SENDER_LOCK" ] || { echo 'sender transaction is unlocked' >&2; exit 94; }
if [ -n "${FM_FIXTURE_PROBE_MODE:-}" ] && [ "${args[1]}" = generation ]; then
  case "$FM_FIXTURE_PROBE_MODE" in
    malformed) printf 'invalid\n'; exit 0 ;;
    unreadable) exit 255 ;;
  esac
fi
if [ -n "${FM_FIXTURE_BLOCK:-}" ] && [ "${args[1]}" = generation ]; then
  touch "$FM_FIXTURE_BLOCK.entered"
  for ((i=0; i<600; i++)); do
    [ ! -f "$FM_FIXTURE_BLOCK.release" ] || break
    sleep 0.05
  done
  [ -f "$FM_FIXTURE_BLOCK.release" ] || exit 95
fi
exec env FM_HOME="$receiver" FM_INHERITABLE_CONFIG=crew-harness bash "$root/bin/${args[0]}" "${args[@]:1}"
SH
chmod +x "$TMP_ROOT/fake-ssh"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
receive() { # <generation> <payload-file>
  local bytes hash
  bytes=$(LC_ALL=C wc -c < "$2" | tr -d ' ')
  hash=$(sha256_file "$2")
  FM_HOME="$REMOTE_HOME" FM_INHERITABLE_CONFIG=crew-harness \
    bash "$ROOT/bin/fm-remote-inherit.sh" put config/crew-harness "$bytes" "$hash" "$1" < "$2"
}
push_fixture() (
  local lock generation
  lock=$(fm_remote_inherit_transaction_lock_path "$PARENT/state" fixture)
  fm_lock_acquire_wait "$lock" || exit 1
  trap 'fm_lock_release "$lock"' EXIT
  generation=$(fm_remote_inherit_generation_next "$PARENT/state" fixture) || exit 1
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_INHERITABLE_CONFIG=crew-harness \
    FM_FIXTURE_SENDER_LOCK="$lock" FM_SSH_BIN="$TMP_ROOT/fake-ssh" \
    bash "$ROOT/bin/fm-remote-inherit-push.sh" fixture "$generation"
)
COUNTER="$PARENT/state/.remote-inherit-fixture.generation"
RECORD="$REMOTE_HOME/config/.fm-inherit-crew-harness.generation"
printf 'receiver original\n' > "$TMP_ROOT/original"
printf 'current sender\n' > "$PARENT/config/crew-harness"
receive 40 "$TMP_ROOT/original" >/dev/null
: > "$TMP_ROOT/empty"
FM_HOME="$REMOTE_HOME" FM_INHERITABLE_CONFIG=crew-harness \
  bash "$ROOT/bin/fm-remote-inherit.sh" absent data/captain-shared.md 0 "$(sha256_file "$TMP_ROOT/empty")" 100 >/dev/null
if ! push_fixture > "$TMP_ROOT/missing.out" 2>&1; then
  fail "missing sender counter did not recover beyond receiver generation 40: $(cat "$TMP_ROOT/missing.out")"
fi
cmp -s "$PARENT/config/crew-harness" "$REMOTE_HOME/config/crew-harness" || fail 'missing-counter push did not converge'
read -r committed < "$RECORD"
[ "$committed" -gt 100 ] && [ "$(cat "$COUNTER")" = "$committed" ] || fail 'sender did not recover above every receiver item'
pass 'missing sender counter recovers above the receiver under the sender transaction lock'

for old in 1 20 "$committed"; do
  printf '%s\n' "$old" > "$COUNTER"
  previous=$committed
  printf 'sender after restore %s\n' "$old" > "$PARENT/config/crew-harness"
  push_fixture > "$TMP_ROOT/restored-$old.out" 2>&1 || fail "restored counter $old did not recover"
  read -r committed < "$RECORD"
  [ "$committed" -gt "$previous" ] || fail 'restored push did not advance the receiver'
  [ "$(cat "$COUNTER")" = "$committed" ] || fail 'recovered sender counter did not persist'
  cmp -s "$PARENT/config/crew-harness" "$REMOTE_HOME/config/crew-harness" || fail 'restored push did not converge'
done
pass 'lower, restored and same-generation conflicting sender counters recover'

if receive 40 "$TMP_ROOT/original" > "$TMP_ROOT/delayed.out" 2>&1; then fail 'delayed older write was accepted'; fi
assert_grep 'superseded' "$TMP_ROOT/delayed.out" 'delayed write did not retain the stale-generation refusal'
if receive "$committed" "$TMP_ROOT/original" > "$TMP_ROOT/conflict.out" 2>&1; then fail 'same-generation different payload was accepted'; fi
assert_grep 'conflicts' "$TMP_ROOT/conflict.out" 'same-generation conflict was not refused'
cmp -s "$PARENT/config/crew-harness" "$REMOTE_HOME/config/crew-harness" || fail 'refused write changed current payload'
pass 'delayed older and conflicting same-generation payloads remain refused'

# Make the first push hold the existing sender transaction while a second waits.
previous=$committed
printf '1\n' > "$COUNTER"
FM_FIXTURE_BLOCK="$TMP_ROOT/race" push_fixture > "$TMP_ROOT/race-first.out" 2>&1 &
first=$!
for ((i=0; i<600; i++)); do
  [ ! -f "$TMP_ROOT/race.entered" ] || break
  sleep 0.05
done
assert_present "$TMP_ROOT/race.entered" 'first push did not reach its generation query'
push_fixture > "$TMP_ROOT/race-second.out" 2>&1 &
second=$!
touch "$TMP_ROOT/race.release"
wait "$first" || fail 'first racing push failed'
wait "$second" || fail 'second racing push failed'
read -r committed < "$RECORD"
[ "$committed" -ge "$((previous + 2))" ] || fail 'racing pushes lost a generation'
[ "$(cat "$COUNTER")" = "$committed" ] || fail 'racing sender and receiver counters diverged'
cmp -s "$PARENT/config/crew-harness" "$REMOTE_HOME/config/crew-harness" || fail 'racing push changed the payload'
pass 'racing pushes commit increasing generations through the shared sender transaction'

cp "$RECORD" "$TMP_ROOT/record-good"
cp "$REMOTE_HOME/config/crew-harness" "$TMP_ROOT/payload-good"
for mode in malformed unreadable; do
  if FM_FIXTURE_PROBE_MODE="$mode" push_fixture > "$TMP_ROOT/probe-$mode.out" 2>&1; then fail "$mode remote generation was accepted"; fi
  cmp -s "$RECORD" "$TMP_ROOT/record-good" || fail "$mode probe changed the receiver generation"
  cmp -s "$REMOTE_HOME/config/crew-harness" "$TMP_ROOT/payload-good" || fail "$mode probe changed the receiver payload"
done
printf 'not-a-generation\n' > "$RECORD"
if push_fixture > "$TMP_ROOT/record-malformed.out" 2>&1; then fail 'malformed receiver record was accepted'; fi
cmp -s "$REMOTE_HOME/config/crew-harness" "$TMP_ROOT/payload-good" || fail 'malformed record changed the payload'
cp "$TMP_ROOT/record-good" "$RECORD"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$RECORD"
  unreadable_rc=0
  push_fixture > "$TMP_ROOT/record-unreadable.out" 2>&1 || unreadable_rc=$?
  chmod 600 "$RECORD"
  [ "$unreadable_rc" -ne 0 ] || fail 'unreadable receiver record was accepted'
  cmp -s "$REMOTE_HOME/config/crew-harness" "$TMP_ROOT/payload-good" || fail 'unreadable record changed the payload'
fi
printf 'not-a-generation\n' > "$COUNTER"
if push_fixture > "$TMP_ROOT/counter-malformed.out" 2>&1; then fail 'malformed sender counter was accepted'; fi
cmp -s "$RECORD" "$TMP_ROOT/record-good" || fail 'malformed sender counter changed the receiver generation'
pass 'malformed or unreadable generation state fails closed without changing inherited content'

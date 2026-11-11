#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-home-worktree-lock-lib.sh"
. "$ROOT/bin/fm-home-payload-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-payload-return)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/slot"
parent="$TMP_ROOT/parent"
mkdir -p "$repo" "$parent/state"
git -C "$repo" init -q
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm initial --allow-empty
git -C "$repo" worktree add --quiet --detach "$home" HEAD
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
printf 'durable data\n' > "$home/data/notes"
printf 'mate\n' > "$home/.fm-secondmate-home"
printf '%s\n' "$parent" > "$home/.fm-secondmate-parent"
fm_home_worktree_lock_acquire "$home" mate "$parent"
gitdir=$(git -C "$home" rev-parse --absolute-git-dir)
printf 'mate\n' > "$TMP_ROOT/lease"
return_slot() {
  [ -f "$TMP_ROOT/lease" ] || return 1
  for path in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
    [ ! -e "$home/$path" ] || return 1
  done
  [ ! -e "$gitdir/firstmate-home-lock" ] || return 1
  [ ! -e "$gitdir/locked" ] || return 1
  printf 'observed\n' > "$TMP_ROOT/return-observed"
  [ "$1" = success ] || return 1
  rm "$TMP_ROOT/lease"
}
if fm_home_payload_return "$home" mate "$parent" return_slot failure; then
  fail 'failed return reported success'
fi
assert_present "$TMP_ROOT/return-observed" 'return saw an uncleared slot'
assert_present "$TMP_ROOT/lease" 'failed return lost lease'
assert_present "$gitdir/locked" 'failed return lost protection'
assert_present "$gitdir/firstmate-home-lock" 'failed return lost ownership'
[ "$(cat "$home/data/notes")" = 'durable data' ] || fail 'failed return lost data'
[ "$(cat "$home/.fm-secondmate-home")" = mate ] || fail 'failed return lost identity'
git -C "$home" add -f data/notes
if fm_home_payload_return "$home" mate "$parent" return_slot success; then
  fail 'tracked payload was retired'
fi
assert_present "$gitdir/locked" 'refused cleanup unlocked the home'
assert_present "$TMP_ROOT/lease" 'refused cleanup returned the lease'
git -C "$home" reset -q
fm_home_payload_return "$home" mate "$parent" return_slot success
assert_absent "$TMP_ROOT/lease" 'successful return retained lease'
assert_absent "$home/data" 'successful return retained payload'
assert_absent "$gitdir/firstmate-home-lock" 'successful return retained receipt'

# A handled interrupt during the payload move restores what already staged, so
# the home keeps payload, identity, ownership and protection for the retry
# instead of coming back stripped and unretirable. The move is shimmed slow
# enough to signal; the shim reports its parent - the process performing the
# return, which owns the restore trap - because fm_home_payload_return is a
# subshell and the background job around it holds no traps.
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
printf 'durable data\n' > "$home/data/notes"
printf 'mate\n' > "$home/.fm-secondmate-home"
printf '%s\n' "$parent" > "$home/.fm-secondmate-parent"
fm_home_worktree_lock_acquire "$home" mate "$parent"
printf 'mate\n' > "$TMP_ROOT/lease"
rm -f "$TMP_ROOT/return-observed"
mkdir -p "$TMP_ROOT/fakebin"
real_mv=$(command -v mv)
cat > "$TMP_ROOT/fakebin/mv" <<SH
#!/usr/bin/env bash
if [ ! -e "\$FM_TEST_MOVER_MARKER" ]; then
  printf '%s\n' "\$PPID" > "\$FM_TEST_MOVER_MARKER"
fi
sleep 0.2
exec "$real_mv" "\$@"
SH
chmod +x "$TMP_ROOT/fakebin/mv"
mover_marker="$TMP_ROOT/mover.pid"
rm -f "$mover_marker"
FM_TEST_MOVER_MARKER="$mover_marker" \
  PATH="$TMP_ROOT/fakebin:$PATH" \
  fm_home_payload_return "$home" mate "$parent" return_slot success &
interrupt_job=$!
waits=0
while [ ! -s "$mover_marker" ]; do
  waits=$((waits + 1))
  [ "$waits" -lt 400 ] || { kill -KILL "$interrupt_job" 2>/dev/null || true; fail 'the return never started its payload move'; }
  sleep 0.05
done
mover_pid=$(cat "$mover_marker")
kill -TERM "$mover_pid" 2>/dev/null || fail 'the mover exited before the interrupt'
waits=0
while kill -0 "$interrupt_job" 2>/dev/null; do
  waits=$((waits + 1))
  [ "$waits" -lt 400 ] || { kill -KILL "$interrupt_job" 2>/dev/null || true; fail 'the interrupted return did not stop'; }
  sleep 0.05
done
interrupt_status=0
wait "$interrupt_job" || interrupt_status=$?
[ "$interrupt_status" = 143 ] || fail "interrupted return exited $interrupt_status instead of 143"
[ "$(cat "$home/data/notes")" = 'durable data' ] || fail 'handled interrupt lost data'
[ "$(cat "$home/.fm-secondmate-home")" = mate ] || fail 'handled interrupt lost identity'
[ "$(cat "$home/.fm-secondmate-parent")" = "$parent" ] || fail 'handled interrupt lost parent binding'
assert_present "$gitdir/locked" 'handled interrupt lost protection'
assert_present "$gitdir/firstmate-home-lock" 'handled interrupt lost ownership'
assert_present "$TMP_ROOT/lease" 'handled interrupt returned the lease early'
assert_absent "$TMP_ROOT/return-observed" 'handled interrupt ran the slot release'
[ -z "$(ls -A "$parent/state")" ] || fail 'handled interrupt left payload staging behind'
fm_home_payload_return "$home" mate "$parent" return_slot success
assert_absent "$TMP_ROOT/lease" 'retried return retained lease'
assert_absent "$home/data" 'retried return retained payload'
assert_absent "$gitdir/firstmate-home-lock" 'retried return retained receipt'
pass 'pool return observes a clean slot, failures preserve retry ownership, and a handled interrupt restores the home'

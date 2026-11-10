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

# A handled interrupt restores what the return already staged, so the home keeps
# its payload, identity, ownership, and protection for the retry instead of
# coming back stripped and marked unretirable. The interrupt has to reach the
# process that performs the return and owns the restore trap: fm_home_payload_return
# is a subshell, so signalling the background job around it would kill a shell
# that holds no staging and leave the mover waiting forever.
staged_marker="$TMP_ROOT/return-staged"
staging_root="$parent/state"
hang_return() {
  for path in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
    [ ! -e "$home/$path" ] || return 1
  done
  printf '%s\n' "$BASHPID" > "$staged_marker"
  while :; do sleep 0.05; done
}
wait_for_staging() {  # -> echoes the pid of the process performing the return
  local waits=0
  while [ ! -s "$staged_marker" ]; do
    [ "$waits" -lt 400 ] || fail 'the return never staged the home payload'
    waits=$((waits + 1))
    sleep 0.05
  done
  cat "$staged_marker"
}
wait_for_exit() {  # <pid> <what>
  local pid=$1 what=$2 waits=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$waits" -lt 400 ] || { kill -KILL "$pid" 2>/dev/null || true; fail "$what did not stop"; }
    waits=$((waits + 1))
    sleep 0.05
  done
}
assert_home_restored() {  # <what>
  [ "$(cat "$home/data/notes")" = 'durable data' ] || fail "$1 lost data"
  [ "$(cat "$home/.fm-secondmate-home")" = mate ] || fail "$1 lost identity"
  [ "$(cat "$home/.fm-secondmate-parent")" = "$parent" ] || fail "$1 lost parent binding"
  assert_present "$gitdir/locked" "$1 lost protection"
  assert_present "$gitdir/firstmate-home-lock" "$1 lost ownership"
  assert_present "$TMP_ROOT/lease" "$1 returned the lease"
  [ -z "$(ls -A "$staging_root")" ] || fail "$1 left payload staging behind"
}
rm -f "$staged_marker"
fm_home_payload_return "$home" mate "$parent" hang_return &
interrupted_job=$!
mover_pid=$(wait_for_staging)
kill -TERM "$mover_pid"
wait_for_exit "$interrupted_job" 'the interrupted return'
interrupt_status=0
wait "$interrupted_job" || interrupt_status=$?
[ "$interrupt_status" = 143 ] || fail "interrupted return exited $interrupt_status instead of 143"
assert_home_restored 'handled interrupt'

# A return killed outright cannot restore its own staging. The record it wrote
# before moving anything is what lets a later entry put the home back together
# instead of refusing a home whose identity is still staged.
kill_return() {  # stages the home in a return and SIGKILLs the process performing it
  rm -f "$staged_marker"
  # The mover's own shell reports the SIGKILLed child it reaped; keep that notice
  # out of the test output.
  fm_home_payload_return "$home" mate "$parent" hang_return 2>"$TMP_ROOT/killed-return.err" &
  killed_job=$!
  mover_pid=$(wait_for_staging)
  kill -KILL "$mover_pid" 2>/dev/null || true
  kill_status=0
  wait "$killed_job" 2>/dev/null || kill_status=$?
  [ "$kill_status" = 137 ] || fail "killed return exited $kill_status instead of 137"
  assert_absent "$home/data" 'a killed return kept the payload in the home'
  assert_absent "$home/.fm-secondmate-home" 'a killed return kept the home identity'
  [ -n "$(ls -A "$staging_root")" ] || fail 'a killed return left no staging to recover from'
}
kill_return
# The recovery restores what the killed return had already moved, rather than
# discarding the staging and leaving the home stripped and unretirable.
fm_home_payload_recover "$home" "$parent"
assert_home_restored 'recovery of a killed return'
# The same staging seen by a retrying return: the return recovers it before it
# decides anything about the slot, then returns the slot and clears the payload.
kill_return
fm_home_payload_return "$home" mate "$parent" return_slot success
assert_absent "$TMP_ROOT/lease" 'successful return retained lease'
assert_absent "$home/data" 'successful return retained payload'
assert_absent "$gitdir/firstmate-home-lock" 'successful return retained receipt'
[ -z "$(ls -A "$staging_root")" ] || fail 'successful return left payload staging behind'
pass 'pool return observes a clean slot, failures preserve retry ownership, and an interrupted return recovers'

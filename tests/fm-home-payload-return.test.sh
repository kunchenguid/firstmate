#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
. "$ROOT/bin/fm-home-worktree-lock-lib.sh"
. "$ROOT/bin/fm-home-payload-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-payload-return)
repo="$TMP_ROOT/repo"
home="$TMP_ROOT/pool/1/repo"
pool_state="$TMP_ROOT/pool/treehouse-state.json"
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
write_pool_lease() {
  python3 - "$pool_state" "$home" "$1" <<'PYSTATE'
import json
import sys
state, home, holder = sys.argv[1:]
with open(state, "w") as stream:
    json.dump({"worktrees": [{"name": "1", "path": home, "leased": bool(holder),
                              "lease_holder": holder, "leased_at": holder + "-generation"}]}, stream)
PYSTATE
}
write_pool_lease mate
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
  write_pool_lease ""
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
fm_home_worktree_lock_release "$home" mate "$parent"
fm_home_worktree_lock_forget "$home" mate "$parent"
kill_return
fm_home_payload_recover "$home" "$parent" mate
assert_home_restored 'recovery without a saved receipt' 
# The same staging seen by a retrying return: the return recovers it before it
# decides anything about the slot, then returns the slot and clears the payload.
kill_return
fm_home_payload_return "$home" mate "$parent" return_slot success
assert_absent "$TMP_ROOT/lease" 'successful return retained lease'
assert_absent "$home/data" 'successful return retained payload'
assert_absent "$gitdir/firstmate-home-lock" 'successful return retained receipt'
fm_home_payload_recover "$home" "$parent" mate
[ "$FM_HOME_PAYLOAD_RETIRED" = 1 ] || fail 'committed return was not retained for finalization'
fm_home_payload_finalize "$home" "$parent" mate
[ -z "$(ls -A "$staging_root")" ] || fail 'finalization left payload staging behind'

prepare_retry() {
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf 'durable data\n' > "$home/data/notes"
  printf 'mate\n' > "$home/.fm-secondmate-home"
  printf '%s\n' "$parent" > "$home/.fm-secondmate-parent"
  printf 'mate\n' > "$TMP_ROOT/lease"
  write_pool_lease mate
  fm_home_worktree_lock_acquire "$home" mate "$parent"
}
prepare_retry
printf() {
  [ "$1" != 'committed=1\n' ] || return 1
  builtin printf "$@"
}
fm_home_payload_return "$home" mate "$parent" return_slot success
unset -f printf
assert_absent "$home/data" 'commit-record failure restored a released payload'
assert_absent "$gitdir/locked" 'commit-record failure relocked a released slot'
fm_home_payload_recover "$home" "$parent" mate
[ "$FM_HOME_PAYLOAD_RETIRED" = 1 ] || fail 'commit-record failure lost released outcome'
fm_home_payload_finalize "$home" "$parent" mate

release_then_signal() {
  return_slot success
  write_pool_lease next
  mkdir -p "$home/data" "$home/state"
  printf 'next occupant\n' > "$home/data/notes"
  printf 'next\n' > "$home/.fm-secondmate-home"
  printf 'unrelated child\n' > "$home/state/sentinel.meta"
  fm_home_worktree_lock_acquire "$home" next "$parent"
  kill -TERM "$BASHPID"
}
prepare_retry
status=0
fm_home_payload_return "$home" mate "$parent" release_then_signal || status=$?
[ "$status" = 143 ] || fail 'post-release signal was not delivered'
fm_home_payload_recover "$home" "$parent" mate
[ "$FM_HOME_PAYLOAD_RETIRED" = 1 ] || fail 'released lease was restored'
[ "$(cat "$home/data/notes")" = 'next occupant' ] || fail 'recovery overwrote the next occupant'
fm_home_worktree_lock_check "$home" next "$parent" || fail 'recovery changed the next occupant lock'
mkdir -p "$parent/data"
fm_write_secondmate_meta "$parent/state/mate.meta" "$home"
printf '%s\n' "- mate - old mate (home: $home; scope: old mate; projects: alpha; added 2026-06-22)" > "$parent/data/secondmates.md"
fakebin=$(make_fake_tmux "$TMP_ROOT/fake")
PATH="$fakebin:$PATH" FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
  FM_FAKE_TMUX_LOG="$TMP_ROOT/fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fake/pane.txt" \
  bash "$ROOT/bin/fm-teardown.sh" mate --force >"$TMP_ROOT/finalize.out" 2>"$TMP_ROOT/finalize.err" \
  || { cat "$TMP_ROOT/finalize.err" >&2; fail 'committed return could not finish parent retirement'; }
assert_absent "$parent/state/mate.meta" 'records-only retirement retained parent metadata'
[ "$(cat "$home/data/notes")" = 'next occupant' ] || fail 'records-only retirement changed the slot'
assert_present "$home/state/sentinel.meta" 'records-only retirement traversed the next occupant'
fm_home_worktree_lock_check "$home" next "$parent" || fail 'records-only retirement changed new protection'

fm_home_worktree_lock_release "$home" next "$parent"
fm_home_worktree_lock_forget "$home" next "$parent"
rm -rf "$home/data" "$home/state"
prepare_retry
printf() {
  builtin printf "$@"
  if [ "$1" = 'committed=1\n' ]; then
    kill -KILL "$BASHPID"
  fi
}
status=0
fm_home_payload_return "$home" mate "$parent" return_slot success 2>"$TMP_ROOT/commit-kill.err" || status=$?
unset -f printf
[ "$status" = 137 ] || fail 'commit interruption was not delivered'
fm_home_payload_recover "$home" "$parent" mate
[ "$FM_HOME_PAYLOAD_RETIRED" = 1 ] || fail 'committed interruption lost finalization state'
assert_absent "$home/.fm-secondmate-home" 'committed interruption restored old identity'
assert_absent "$gitdir/locked" 'committed interruption restored old protection'
make_firstmate_git_root "$parent"
printf 'outer\n' > "$parent/.fm-secondmate-home"
fm_write_secondmate_meta "$parent/state/mate.meta" "$home"
: > "$parent/data/secondmates.md"
grandparent="$TMP_ROOT/grandparent"
mkdir -p "$grandparent/data" "$grandparent/state"
fm_write_secondmate_meta "$grandparent/state/outer.meta" "$parent"
printf '%s\n' "- outer - outer mate (home: $parent; scope: outer; projects: alpha; added 2026-06-22)" > "$grandparent/data/secondmates.md"
mkdir -p "$home/data" "$home/state"
printf 'next occupant\n' > "$home/data/notes"
printf 'next\n' > "$home/.fm-secondmate-home"
printf 'unrelated child\n' > "$home/state/sentinel.meta"
git -C "$home" worktree lock --reason next "$home"
PATH="$fakebin:$PATH" FM_HOME="$grandparent" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
  FM_FAKE_TMUX_LOG="$TMP_ROOT/fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fake/pane.txt" \
  bash "$ROOT/bin/fm-teardown.sh" outer --force >"$TMP_ROOT/nested.out" 2>"$TMP_ROOT/nested.err" \
  || { cat "$TMP_ROOT/nested.err" >&2; fail 'nested committed retirement could not finish'; }
assert_absent "$grandparent/state/outer.meta" 'nested retirement retained outer metadata'
assert_absent "$parent" 'nested retirement retained retired parent home'
[ "$(cat "$home/data/notes")" = 'next occupant' ] || fail 'nested retirement changed the next occupant'
assert_present "$home/state/sentinel.meta" 'nested retirement traversed the next occupant'
assert_present "$gitdir/locked" 'nested retirement unlocked the next occupant'
git -C "$home" worktree unlock "$home"
rm -rf "$home/data" "$home/state" "$home/config" "$home/projects"
parent="$TMP_ROOT/concurrent-parent"
staging_root="$parent/state"
make_firstmate_git_root "$parent"
mkdir -p "$parent/data" "$parent/state"
printf 'outer\n' > "$parent/.fm-secondmate-home"
: > "$parent/data/secondmates.md"
prepare_retry
fm_write_secondmate_meta "$parent/state/mate.meta" "$home"
fm_write_secondmate_meta "$grandparent/state/outer.meta" "$parent"
printf '%s\n' "- outer - outer mate (home: $parent; scope: outer; projects: alpha; added 2026-06-22)" > "$grandparent/data/secondmates.md"
for lock_kind in control meta; do
  rm -f "$staged_marker"
  (
    export FM_HOME="$parent" STATE="$parent/state"
    . "$ROOT/bin/fm-wake-lib.sh"
    if [ "$lock_kind" = control ]; then
      test_lock="$parent/state/.control-mate.lock"
    else
      test_lock=$(fm_meta_lock_path "$parent/state/mate.meta")
    fi
    fm_lock_try_acquire "$test_lock" || exit 1
    trap 'fm_lock_release "$test_lock"' EXIT
    fm_home_payload_return "$home" mate "$parent" hang_return
  ) 2>"$TMP_ROOT/concurrent-child.err" &
  active_job=$!
  mover_pid=$(wait_for_staging)
  if PATH="$fakebin:$PATH" FM_HOME="$grandparent" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_FAKE_TMUX_LOG="$TMP_ROOT/fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fake/pane.txt" \
    bash "$ROOT/bin/fm-teardown.sh" outer --force >"$TMP_ROOT/concurrent.out" 2>"$TMP_ROOT/concurrent.err"; then
    kill -TERM "$mover_pid"
    wait "$active_job" || true
    fail "parent ignored held child $lock_kind lock"
  fi
  assert_absent "$home/.fm-secondmate-home" "parent restored identity before acquiring child $lock_kind lock"
  assert_absent "$home/data" "parent restored payload before acquiring child $lock_kind lock"
  assert_absent "$gitdir/locked" "parent relocked the active return under child $lock_kind lock"
  assert_present "$parent/state/mate.meta" 'parent removed the active child record'
  kill -TERM "$mover_pid"
  wait "$active_job" || [ "$?" = 143 ]
  [ "$(cat "$home/data/notes")" = 'durable data' ] || fail 'active return could not restore its own payload'
  fm_home_worktree_lock_check "$home" mate "$parent" || fail 'active return lost owned protection'
done

seedroot="$TMP_ROOT/replacement-code"
git clone --quiet --no-checkout "$ROOT" "$seedroot"
git -C "$seedroot" checkout --quiet "$(git -C "$ROOT" rev-parse HEAD)"
home="$TMP_ROOT/replacement-pool/1/firstmate"
pool_state="$TMP_ROOT/replacement-pool/treehouse-state.json"
parent="$TMP_ROOT/replacement-parent"
staging_root="$parent/state"
mkdir -p "$parent/data" "$parent/state"
git -C "$seedroot" worktree add --quiet --detach "$home" HEAD
gitdir=$(git -C "$home" rev-parse --absolute-git-dir)
prepare_retry
fm_home_payload_return "$home" mate "$parent" return_slot success
fm_home_payload_recover "$home" "$parent" mate
[ "$FM_HOME_PAYLOAD_RETIRED" = 1 ] || fail 'replacement fixture has no committed return'
PATH="$fakebin:$PATH" FM_HOME="$parent" FM_ROOT_OVERRIDE="$seedroot" FM_FAKE_TMUX_LOG="$TMP_ROOT/fake/tmux.log" \
  FM_FAKE_TREEHOUSE_HOME="$home" FM_FAKE_TREEHOUSE_LEASE_FILE="$TMP_ROOT/lease" \
  FM_SECONDMATE_CHARTER='replacement domain' FM_SECONDMATE_SCOPE='replacement domain' \
  bash "$ROOT/bin/fm-home-seed.sh" mate - --no-projects >"$TMP_ROOT/replacement.out" 2>"$TMP_ROOT/replacement.err" \
  || { cat "$TMP_ROOT/replacement.err" >&2; fail 'replacement seed failed'; }
fm_home_payload_recover "$home" "$parent" mate
[ "$FM_HOME_PAYLOAD_RETIRED" = 0 ] || fail 'replacement seed inherited old retirement state'
assert_present "$home/data/charter.md" 'replacement seed lost its payload'
assert_present "$gitdir/locked" 'replacement seed lacks owned protection'
fm_write_secondmate_meta "$parent/state/mate.meta" "$home"
write_pool_lease mate
PATH="$fakebin:$PATH" FM_HOME="$parent" FM_ROOT_OVERRIDE="$seedroot" FM_BACKEND=tmux \
  FM_FAKE_TMUX_LOG="$TMP_ROOT/fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/fake/pane.txt" \
  FM_FAKE_TREEHOUSE_KEEP_HOME=1 FM_FAKE_TREEHOUSE_LEASE_FILE="$TMP_ROOT/lease" \
  bash "$ROOT/bin/fm-teardown.sh" mate >"$TMP_ROOT/replacement-retire.out" 2>"$TMP_ROOT/replacement-retire.err" \
  || { cat "$TMP_ROOT/replacement-retire.err" >&2; fail 'replacement retirement failed'; }
assert_absent "$TMP_ROOT/lease" 'replacement retirement stranded its lease'
assert_absent "$home/.fm-secondmate-home" 'replacement retirement skipped physical cleanup'
assert_absent "$home/data" 'replacement retirement stranded its payload'
assert_absent "$gitdir/locked" 'replacement retirement stranded protection'
assert_absent "$parent/state/mate.meta" 'replacement retirement retained its parent record'
pass 'recovery respects active child locks and replacement home incarnations'

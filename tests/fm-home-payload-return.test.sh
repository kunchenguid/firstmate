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
pass 'pool return observes a clean slot and failures preserve retry ownership'

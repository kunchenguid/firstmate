#!/usr/bin/env bash
# What a durable linked-worktree home leaves behind when its slot is returned.
# A returned slot is an ordinary pool checkout again, so it must not keep the
# retired mate's home payload: identity markers, data/, state/, config/ and
# projects/. A slot that keeps them is not reusable - the next seed in that slot
# refuses it as a home "already marked for <retired mate>" - and it turns a
# routine retirement into a pool slot no secondmate can ever lease again.
# Cleanup is return-only, because that is the point where the caller has already
# decided the home is retired; removal paths delete the whole home and never
# reach here. fm_home_payload_return stages the paths so a failed return can
# put them back, and a handled INT/TERM/HUP during that staging restores them
# the same way before the slot is released. Without that, an interruption
# leaves the home stripped of its identity, and every later teardown refuses
# it as "not a seeded secondmate home" while its records stay stranded in the
# parent's staging directory. A return killed outright, or signalled while the
# slot release itself runs, can still strand that staging; cleanup on handled
# interruption is the whole contract here.
# A refusal returns before anything moves, so there is nothing to put back.
# A payload path that carries tracked files is left in place and refuses the
# return, so a home whose tree tracks any of them keeps its checkout intact
# instead of being dirtied into a failed return.
# The home-lock library owns Git lock ownership; this library owns only the
# payload cleanup that makes the returned slot reusable.

# The paths a slot return takes out of the home and puts back on abort. One list
# owns the staging move and the failure or interruption restore.
FM_HOME_PAYLOAD_PATHS=(data state config projects .fm-secondmate-home .fm-secondmate-parent)

fm_home_payload_check() {
  local home=$1 tracked
  [ -d "$home" ] || return 0
  if git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
    tracked=$(git -C "$home" ls-files -- data state config projects .fm-secondmate-home .fm-secondmate-parent 2>/dev/null) || return 1
    [ -z "$tracked" ] || {
      echo "error: durable home $home tracks payload paths ($tracked); leaving its slot payload in place" >&2
      return 1
    }
  fi
}

fm_home_payload_check_devices() {
  python3 - "$1" "$2" "${FM_HOME_PAYLOAD_PATHS[@]}" <<'PYDEV'
import os
import sys

source, destination, *paths = sys.argv[1:]
try:
    device = os.stat(destination).st_dev
    if os.stat(source).st_dev != device:
        raise ValueError(f"payload staging requires the same filesystem: {source} and {destination}")
    for path in [os.path.join(source, name) for name in paths]:
        try:
            entry = os.lstat(path)
        except FileNotFoundError:
            continue
        if entry.st_dev != device:
            raise ValueError(f"payload staging requires the same filesystem: {path} and {destination}")
except (OSError, ValueError) as error:
    print(f"error: cannot move durable home payload: {error}", file=sys.stderr)
    sys.exit(1)
PYDEV
}

fm_home_payload_restore() {  # <home> <staging> [<lock-receipt>]
  local home=$1 staging=$2 receipt=${3:-} path
  fm_home_payload_check_devices "$staging" "$home" || return 1
  for path in "${FM_HOME_PAYLOAD_PATHS[@]}"; do
    if [ -e "$staging/$path" ] || [ -L "$staging/$path" ]; then
      [ ! -e "$home/$path" ] && [ ! -L "$home/$path" ] || {
        echo "error: cannot restore staged payload path $path for durable home $home; it exists again" >&2
        return 1
      }
      mv -- "$staging/$path" "$home/$path" || return 1
    fi
  done
  if [ -n "$receipt" ] && [ -f "$staging/receipt" ]; then
    cp -p "$staging/receipt" "$receipt" || return 1
  fi
}

# Put a staged return back and reassert owned protection. The staging directory
# goes away only once the home is whole again, so a restore that fails leaves
# it behind for a later look.
fm_home_payload_abort() {  # <home> <id> <parent> <staging> [<lock-receipt>]
  local home=$1 id=$2 parent=$3 staging=$4 receipt=${5:-}
  fm_home_payload_restore "$home" "$staging" "$receipt" || return 1
  fm_home_worktree_lock_acquire "$home" "$id" "$parent" || return 1
  rm -rf -- "$staging"
}

fm_home_payload_interrupted() {  # <exit-status> <home> <id> <parent> <staging> [<lock-receipt>]
  local status=$1 home=$2 id=$3 parent=$4 staging=$5 receipt=${6:-}
  trap - INT TERM HUP
  fm_home_payload_abort "$home" "$id" "$parent" "$staging" "$receipt" \
    || echo "error: interrupted return of durable home $home could not restore $staging" >&2
  exit "$status"
}

fm_home_payload_return() (
  local home=$1 id=$2 parent=$3 staging path receipt='' rc=0
  shift 3
  fm_home_payload_check "$home" || return 1
  fm_home_worktree_lock_check "$home" "$id" "$parent" || return 1
  staging=$(mktemp -d "$parent/state/.home-return.XXXXXX") || return 1
  fm_home_payload_check_devices "$home" "$staging" || { rmdir "$staging"; return 1; }
  if [ "$FM_HOME_LOCK_LINKED" = 1 ] && [ -f "$FM_HOME_LOCK_RECEIPT" ]; then
    receipt=$FM_HOME_LOCK_RECEIPT
    cp -p "$receipt" "$staging/receipt" || { rmdir "$staging"; return 1; }
  fi
  # Handled interruption restores what the move already staged, so the home
  # keeps its payload, identity, ownership and protection for the retry. The
  # traps cover staging through the owned-lock release and stop before the
  # slot release itself: once "$@" runs, the slot may be gone for good and
  # restoring the payload into it would re-mark a leasable checkout.
  trap 'fm_home_payload_interrupted 130 "$home" "$id" "$parent" "$staging" "$receipt"' INT
  trap 'fm_home_payload_interrupted 143 "$home" "$id" "$parent" "$staging" "$receipt"' TERM
  trap 'fm_home_payload_interrupted 129 "$home" "$id" "$parent" "$staging" "$receipt"' HUP
  for path in "${FM_HOME_PAYLOAD_PATHS[@]}"; do
    if [ -e "$home/$path" ] || [ -L "$home/$path" ]; then
      mv -- "$home/$path" "$staging/$path" || { rc=1; break; }
    fi
  done
  if [ "$rc" = 0 ]; then
    fm_home_worktree_lock_release "$home" "$id" "$parent" \
      && fm_home_worktree_lock_forget "$home" "$id" "$parent" || rc=1
  fi
  trap - INT TERM HUP
  if [ "$rc" = 0 ]; then
    "$@" || rc=1
  fi
  if [ "$rc" != 0 ]; then
    fm_home_payload_abort "$home" "$id" "$parent" "$staging" "$receipt" || return 1
  else
    rm -rf -- "$staging" || echo "warning: retired payload staging remains at $staging" >&2
  fi
  return "$rc"
)

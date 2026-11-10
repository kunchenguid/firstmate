#!/usr/bin/env bash
# What a durable linked-worktree home leaves behind when its slot is returned.
# A returned slot is an ordinary pool checkout again, so it must not keep the
# retired mate's home payload: identity markers, data/, state/, config/ and
# projects/. A slot that keeps them is not reusable - the next seed in that slot
# refuses it as a home "already marked for <retired mate>" - and it turns a
# routine retirement into a pool slot no secondmate can ever lease again.
# Cleanup is return-only, because that is the point where the caller has already
# decided the home is retired; removal paths delete the whole home and never
# reach here. fm_home_payload_prune deletes the paths outright, while
# fm_home_payload_return stages the same paths first so a failed or interrupted
# return can put them back: a handled INT/TERM/HUP restores the staging it
# moved, and a return that is killed outright leaves a record naming the home in
# that staging directory so fm_home_payload_recover puts the payload back before
# the next retirement entry decides anything about the home.
# Without that, an interruption leaves the home stripped of its identity, and
# every later teardown refuses it as "not a seeded secondmate home" while its
# records stay stranded in the parent's staging directory.
# A refusal returns before anything moves, so there is nothing to put back.
# A payload path that carries tracked files is left in place and refuses either
# entry point, so a home whose tree tracks any of them keeps its checkout intact
# instead of being dirtied into a failed return.
# The home-lock library owns Git lock ownership; this library owns only the
# payload cleanup that makes the returned slot reusable.

# The paths a slot return takes out of the home and puts back on abort. One list
# owns the staging move, the failure and interruption restore, and the recovery.
FM_HOME_PAYLOAD_PATHS=(data state config projects .fm-secondmate-home .fm-secondmate-parent)
# Written into the staging directory before anything moves, so a later entry can
# tell that directory is an unfinished return of that home and what it owned.
FM_HOME_PAYLOAD_RECORD=return-record

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

fm_home_payload_prune() {
  local home=$1
  fm_home_payload_check "$home" || return 1
  rm -rf -- "$home/data" "$home/state" "$home/config" "$home/projects" || return 1
  rm -f -- "$home/.fm-secondmate-home" "$home/.fm-secondmate-parent" || return 1
}

# A return that already committed its slot must never take its payload back: the
# pool slot is unleased and leasable, so restoring the retired mate's identity
# would mark a slot that no longer belongs to it.
fm_home_payload_committed() {  # <record>
  [ -f "$1" ] && grep -Fxq -- 'committed=1' "$1"
}

fm_home_payload_restore() {  # <home> <staging> [<lock-receipt>]
  local home=$1 staging=$2 receipt=${3:-} path
  for path in "${FM_HOME_PAYLOAD_PATHS[@]}"; do
    if [ -e "$staging/$path" ] || [ -L "$staging/$path" ]; then
      [ ! -e "$home/$path" ] && [ ! -L "$home/$path" ] || {
        echo "error: cannot restore staged payload path $path for durable home $home; it exists again" >&2
        return 1
      }
      mv -- "$staging/$path" "$home/$path" || return 1
    fi
  done
  if [ -n "$receipt" ]; then
    cp -p "$staging/receipt" "$receipt" || return 1
  fi
}

# Put a staged return back and reassert owned protection. The staging directory
# goes away only once the home is whole again, so a restore that fails leaves
# its record behind for the next attempt.
fm_home_payload_abort() {  # <home> <id> <parent> <staging> [<lock-receipt>]
  local home=$1 id=$2 parent=$3 staging=$4 receipt=${5:-}
  fm_home_payload_restore "$home" "$staging" "$receipt" || return 1
  fm_home_worktree_lock_acquire "$home" "$id" "$parent" || return 1
  rm -rf -- "$staging"
}

fm_home_payload_interrupted() {  # <exit-status> <home> <id> <parent> <staging> [<lock-receipt>]
  local status=$1 home=$2 id=$3 parent=$4 staging=$5 receipt=${6:-}
  trap - INT TERM HUP
  if fm_home_payload_committed "$staging/$FM_HOME_PAYLOAD_RECORD"; then
    rm -rf -- "$staging" || echo "warning: retired payload staging remains at $staging" >&2
  else
    fm_home_payload_abort "$home" "$id" "$parent" "$staging" "$receipt" \
      || echo "error: interrupted return of durable home $home could not restore its payload and protection; its staged payload remains at $staging" >&2
  fi
  exit "$status"
}

# A return that is killed outright - SIGKILL, a crash, a lost terminal - cannot
# restore its own staging. The record it wrote before moving anything names the
# home, so the next entry for that home puts the staged payload and its lock
# ownership back before deciding anything about the slot.
fm_home_payload_recover() {  # <home> <parent>
  local home=$1 parent=$2 abs_home staging record id
  [ -d "$home" ] || return 0
  abs_home=$(cd "$home" && pwd -P) || return 1
  for staging in "$parent"/state/.home-return.*; do
    [ -d "$staging" ] && [ ! -L "$staging" ] || continue
    record=$staging/$FM_HOME_PAYLOAD_RECORD
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    grep -Fx -- "home=$abs_home" "$record" >/dev/null 2>&1 || continue
    if fm_home_payload_committed "$record"; then
      echo "warning: discarding the retired payload of an interrupted return for durable home $home" >&2
      rm -rf -- "$staging" || return 1
      continue
    fi
    id=$(sed -n 's/^id=//p' "$record") || return 1
    [ -n "$id" ] || continue
    fm_home_worktree_lock_context "$home" "$parent" || return 1
    if [ "$FM_HOME_LOCK_LINKED" = 1 ] && [ -f "$FM_HOME_LOCK_RECEIPT" ] \
      && ! grep -Fxq -- "id=$id" "$FM_HOME_LOCK_RECEIPT"; then
      echo "warning: leaving the interrupted return staging for durable home $home at $staging; the home is locked for another mate" >&2
      continue
    fi
    echo "warning: recovering the interrupted return of durable home $home" >&2
    fm_home_payload_abort "$home" "$id" "$parent" "$staging" "$FM_HOME_LOCK_RECEIPT" || return 1
  done
}

fm_home_payload_return() (
  local home=$1 id=$2 parent=$3 staging path receipt='' rc=0
  shift 3
  fm_home_payload_recover "$home" "$parent" || return 1
  fm_home_payload_check "$home" || return 1
  fm_home_worktree_lock_check "$home" "$id" "$parent" || return 1
  staging=$(mktemp -d "$parent/state/.home-return.XXXXXX") || return 1
  if [ "$FM_HOME_LOCK_LINKED" = 1 ] && [ -f "$FM_HOME_LOCK_RECEIPT" ]; then
    receipt=$FM_HOME_LOCK_RECEIPT
    cp -p "$receipt" "$staging/receipt" || { rmdir "$staging"; return 1; }
  fi
  trap 'fm_home_payload_interrupted 130 "$home" "$id" "$parent" "$staging" "$receipt"' INT
  trap 'fm_home_payload_interrupted 143 "$home" "$id" "$parent" "$staging" "$receipt"' TERM
  trap 'fm_home_payload_interrupted 129 "$home" "$id" "$parent" "$staging" "$receipt"' HUP
  printf 'schema=fm-home-return.v1\nid=%s\nhome=%s\n' "$id" "$FM_HOME_LOCK_HOME" \
    > "$staging/$FM_HOME_PAYLOAD_RECORD" || { rm -rf -- "$staging"; return 1; }
  for path in "${FM_HOME_PAYLOAD_PATHS[@]}"; do
    if [ -e "$home/$path" ] || [ -L "$home/$path" ]; then
      mv -- "$home/$path" "$staging/$path" || { rc=1; break; }
    fi
  done
  if [ "$rc" = 0 ]; then
    fm_home_worktree_lock_release "$home" "$id" "$parent" \
      && fm_home_worktree_lock_forget "$home" "$id" "$parent" \
      && "$@" || rc=1
  fi
  if [ "$rc" = 0 ]; then
    printf 'committed=1\n' >> "$staging/$FM_HOME_PAYLOAD_RECORD" || rc=1
  fi
  trap - INT TERM HUP
  if [ "$rc" != 0 ]; then
    fm_home_payload_abort "$home" "$id" "$parent" "$staging" "$receipt" || return 1
    return "$rc"
  fi
  rm -rf -- "$staging" || echo "warning: retired payload backup remains at $staging" >&2
  return 0
)

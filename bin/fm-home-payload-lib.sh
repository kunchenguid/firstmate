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
# that staging directory.
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

fm_home_payload_pool_state() {
  python3 - "$1" "$2" "$3" <<'PYPOOL'
import json
import os
import subprocess
import sys

mode, home, staging = sys.argv[1:]
snapshot = os.path.join(staging, "pool-entry")
try:
    if mode == "save":
        state = os.path.join(os.path.dirname(os.path.dirname(home)), "treehouse-state.json")
        if os.path.exists(state):
            with open(state) as stream:
                entries = json.load(stream)["worktrees"]
            matches = [entry for entry in entries if os.path.realpath(entry["path"]) == home]
            if len(matches) != 1:
                raise ValueError("pool slot is missing or ambiguous")
            entry = matches[0]
            if entry.get("leased") is True and not (entry.get("lease_id") or entry.get("leased_at")):
                raise ValueError("pool lease has no acquisition identity")
            saved = {"state": state, "entry": entry}
        else:
            gitdir = subprocess.check_output(
                ["git", "-C", home, "rev-parse", "--absolute-git-dir"], text=True
            ).strip()
            saved = {"state": None, "gitdir": gitdir}
        with open(snapshot, "x") as stream:
            json.dump(saved, stream)
    else:
        with open(snapshot) as stream:
            saved = json.load(stream)
        if saved["state"] is None:
            sys.exit(0 if os.path.isdir(home) and os.path.isdir(saved["gitdir"]) else 2)
        with open(saved["state"]) as stream:
            entries = json.load(stream)["worktrees"]
        matches = [entry for entry in entries if os.path.realpath(entry["path"]) == home]
        if len(matches) > 1:
            raise ValueError("ambiguous pool slot")
        if not matches:
            sys.exit(2)
        old, current = saved["entry"], matches[0]
        if current.get("destroying", False):
            raise ValueError("pool slot is being destroyed")
        if not isinstance(current.get("leased", False), bool):
            raise ValueError("invalid pool lease")
        fields = ("leased", "lease_id", "lease_holder", "leased_at", "owner_pid", "owner_started_at")
        if old.get("leased") is True and all(old.get(key) == current.get(key) for key in fields):
            sys.exit(0)
        if current.get("leased", False) is False or current.get("leased_at") != old.get("leased_at") or current.get("lease_holder") != old.get("lease_holder") or current.get("lease_id") != old.get("lease_id"):
            sys.exit(2)
        raise ValueError("pool ownership cannot be reconciled")
except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
    print(f"error: cannot reconcile durable home {home}: {error}", file=sys.stderr)
    sys.exit(1)
PYPOOL
}

# A staged return is only put back when the pool still owes this home its slot.
# The saved pool entry decides: an unchanged held lease means the return never
# took effect, so the caller restores the payload, while a released or
# reassigned slot means the return already committed and the payload must stay
# out. An unreadable or contradictory pool reads as an error, never as a guess,
# because either wrong answer strips a live home or re-marks a leasable slot.
# Returns 0 when the staging is settled as committed, 2 when it must be
# restored, and 1 when the pool cannot be reconciled.
fm_home_payload_reconcile() {
  local home=$1 staging=$2 rc=0
  fm_home_payload_committed "$staging/$FM_HOME_PAYLOAD_RECORD" && return 0
  grep -Fxq 'returning=1' "$staging/$FM_HOME_PAYLOAD_RECORD" || return 2
  fm_home_payload_pool_state check "$home" "$staging" || rc=$?
  case "$rc" in
    0) return 2 ;;
    2) printf 'committed=1\n' >> "$staging/$FM_HOME_PAYLOAD_RECORD"; return $? ;;
    *) return 1 ;;
  esac
}

fm_home_payload_finalize() {
  local home=$1 parent=$2 id=$3 staging record
  if [ -d "$home" ]; then
    home=$(cd "$home" && pwd -P) || return 1
  fi
  for staging in "$parent"/state/.home-return.*; do
    [ -d "$staging" ] && [ ! -L "$staging" ] || continue
    record=$staging/$FM_HOME_PAYLOAD_RECORD
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    grep -Fxq "home=$home" "$record" || continue
    grep -Fxq "id=$id" "$record" || continue
    fm_home_payload_reconcile "$home" "$staging" || {
      echo "error: durable home $home has an unresolved return at $staging" >&2
      return 1
    }
    rm -rf -- "$staging" || return 1
  done
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
  if [ -n "$receipt" ] && [ -f "$staging/receipt" ]; then
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

fm_home_payload_interrupted() {  # <exit-status> <home> <id> <parent> <staging>
  local status=$1 home=$2 id=$3 parent=$4 staging=$5
  trap - INT TERM HUP
  fm_home_payload_recover "$home" "$parent" "$id" \
    || echo "error: interrupted return of durable home $home needs recovery from $staging" >&2
  exit "$status"
}

fm_home_payload_recover() {  # <home> <parent> [<id>]
  local home=$1 parent=$2 expected_id=${3:-} abs_home staging record id rc
  FM_HOME_PAYLOAD_RETIRED=0
  if [ -d "$home" ]; then
    abs_home=$(cd "$home" && pwd -P) || return 1
  else
    abs_home=$home
  fi
  for staging in "$parent"/state/.home-return.*; do
    [ -d "$staging" ] && [ ! -L "$staging" ] || continue
    record=$staging/$FM_HOME_PAYLOAD_RECORD
    [ -f "$record" ] && [ ! -L "$record" ] || continue
    grep -Fxq "home=$abs_home" "$record" || continue
    id=$(sed -n 's/^id=//p' "$record") || return 1
    [ -n "$id" ] || return 1
    [ -z "$expected_id" ] || [ "$id" = "$expected_id" ] || continue
    rc=0
    fm_home_payload_reconcile "$abs_home" "$staging" || rc=$?
    case "$rc" in
      0) FM_HOME_PAYLOAD_RETIRED=1; continue ;;
      2) ;;
      *) return 1 ;;
    esac
    fm_home_worktree_lock_check "$home" "$id" "$parent" || return 1
    echo "warning: recovering the interrupted return of durable home $home" >&2
    fm_home_payload_abort "$home" "$id" "$parent" "$staging" "$FM_HOME_LOCK_RECEIPT" || return 1
  done
}

fm_home_payload_return() (
  local home=$1 id=$2 parent=$3 staging path receipt='' rc=0
  shift 3
  fm_home_payload_recover "$home" "$parent" "$id" || return 1
  [ "$FM_HOME_PAYLOAD_RETIRED" = 0 ] || return 0
  fm_home_payload_check "$home" || return 1
  fm_home_worktree_lock_check "$home" "$id" "$parent" || return 1
  staging=$(mktemp -d "$parent/state/.home-return.XXXXXX") || return 1
  if [ "$FM_HOME_LOCK_LINKED" = 1 ] && [ -f "$FM_HOME_LOCK_RECEIPT" ]; then
    receipt=$FM_HOME_LOCK_RECEIPT
    cp -p "$receipt" "$staging/receipt" || { rmdir "$staging"; return 1; }
  fi
  trap 'fm_home_payload_interrupted 130 "$home" "$id" "$parent" "$staging"' INT
  trap 'fm_home_payload_interrupted 143 "$home" "$id" "$parent" "$staging"' TERM
  trap 'fm_home_payload_interrupted 129 "$home" "$id" "$parent" "$staging"' HUP
  printf 'schema=fm-home-return.v1\nid=%s\nhome=%s\n' "$id" "$FM_HOME_LOCK_HOME" \
    > "$staging/$FM_HOME_PAYLOAD_RECORD" || { rm -rf -- "$staging"; return 1; }
  fm_home_payload_pool_state save "$FM_HOME_LOCK_HOME" "$staging" || { rm -rf -- "$staging"; return 1; }
  for path in "${FM_HOME_PAYLOAD_PATHS[@]}"; do
    if [ -e "$home/$path" ] || [ -L "$home/$path" ]; then
      mv -- "$home/$path" "$staging/$path" || { rc=1; break; }
    fi
  done
  if [ "$rc" = 0 ]; then
    fm_home_worktree_lock_release "$home" "$id" "$parent" \
      && fm_home_worktree_lock_forget "$home" "$id" "$parent" \
      && printf 'returning=1\n' >> "$staging/$FM_HOME_PAYLOAD_RECORD" \
      && "$@" || rc=1
  fi
  if [ "$rc" = 0 ]; then
    printf 'committed=1\n' >> "$staging/$FM_HOME_PAYLOAD_RECORD" \
      || echo "warning: return committed; pool reconciliation is required for $home" >&2
  fi
  trap - INT TERM HUP
  if [ "$rc" != 0 ]; then
    fm_home_payload_recover "$home" "$parent" "$id" || return 1
    [ "$FM_HOME_PAYLOAD_RETIRED" = 0 ] || return 0
    return "$rc"
  fi
  return 0
)

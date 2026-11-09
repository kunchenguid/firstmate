#!/usr/bin/env bash
# What a durable linked-worktree home leaves behind when its slot is returned.
# A returned slot is an ordinary pool checkout again, so it must not keep the
# retired mate's home payload: identity markers, data/, state/, config/ and
# projects/. A slot that keeps them is not reusable - the next seed in that slot
# refuses it as a home "already marked for <retired mate>" - and it turns a
# routine retirement into a pool slot no secondmate can ever lease again.
# Prune runs only on a return path, because that is the point where the caller
# has already decided the home is retired; removal paths delete the whole home
# and never reach here. A payload path that carries tracked files is left in
# place and refuses the prune, so a home whose tree tracks any of them keeps its
# checkout intact instead of being dirtied into a failed return.
# The home-lock library owns Git lock ownership; this library owns only the
# payload cleanup that makes the returned slot reusable.

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

fm_home_payload_return() (
  local home=$1 id=$2 parent=$3 backup path receipt= rc=0
  shift 3
  fm_home_payload_check "$home" || return 1
  fm_home_worktree_lock_check "$home" "$id" "$parent" || return 1
  backup=$(mktemp -d "$parent/state/.home-return.XXXXXX") || return 1
  if [ "$FM_HOME_LOCK_LINKED" = 1 ] && [ -f "$FM_HOME_LOCK_RECEIPT" ]; then
    receipt=$FM_HOME_LOCK_RECEIPT
    cp -p "$receipt" "$backup/receipt" || { rmdir "$backup"; return 1; }
  fi
  for path in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
    if [ -e "$home/$path" ] || [ -L "$home/$path" ]; then
      mv -- "$home/$path" "$backup/$path" || { rc=1; break; }
    fi
  done
  if [ "$rc" = 0 ]; then
    fm_home_worktree_lock_release "$home" "$id" "$parent" \
      && fm_home_worktree_lock_forget "$home" "$id" "$parent" \
      && "$@" || rc=1
  fi
  if [ "$rc" != 0 ]; then
    for path in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
      if [ -e "$backup/$path" ] || [ -L "$backup/$path" ]; then
        mv -- "$backup/$path" "$home/$path" || return 1
      fi
    done
    if [ -n "$receipt" ]; then
      cp -p "$backup/receipt" "$receipt" || return 1
    fi
    fm_home_worktree_lock_acquire "$home" "$id" "$parent" || return 1
  fi
  rm -rf -- "$backup" || echo "warning: retired payload backup remains at $backup" >&2
  return "$rc"
)

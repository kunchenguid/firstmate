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

fm_home_payload_prune() { # <home>
  local home=$1 tracked
  [ -d "$home" ] || return 0
  if git -C "$home" rev-parse --git-dir >/dev/null 2>&1; then
    tracked=$(git -C "$home" ls-files -- data state config projects 2>/dev/null) || tracked=
    [ -z "$tracked" ] || {
      echo "error: durable home $home tracks payload paths ($tracked); leaving its slot payload in place" >&2
      return 1
    }
  fi
  rm -rf -- "$home/data" "$home/state" "$home/config" "$home/projects" || return 1
  rm -f -- "$home/.fm-secondmate-home" "$home/.fm-secondmate-parent" || return 1
}

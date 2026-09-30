#!/usr/bin/env bash
# bin/fm-backend-hometag-lib.sh - shared per-installation home-tag derivation
# for session-provider backends whose container has ONE namespace shared by
# every firstmate home on the machine, with no native per-home split (cmux's
# one app-global workspace list, zellij's one shared "firstmate" session's
# tab bar). Without a per-home discriminator embedded in the actual
# title/name, two firstmate homes (two secondmates, a primary plus a
# secondmate, or two independent primary installations) whose task ids
# happen to collide can send/peek/close each other's tabs - the gap a
# captain-directed no-mistakes review gate caught for cmux
# (docs/cmux-backend.md) and this same tag mechanism was later ported to
# zellij to close for the same reason (docs/zellij-backend.md "Home-scoped
# tab titles").
#
# fm_backend_hometag() derives a short, stable tag: a readable prefix
# ("firstmate" for the primary home, "2ndmate-<id>" for a secondmate home
# carrying .fm-secondmate-home) plus a short hash of the resolved FM_ROOT
# path, so distinct installations - including multiple primaries on one
# machine - never collide even though they share one backend-global
# namespace. Callers source this file AFTER resolving their own
# FM_HOME/FM_ROOT fallbacks (both adapters already do this for their own
# purposes before any other function runs).
#
# fm_task_home_marker() is the per-home marker bin/fm-spawn.sh exports into
# ship and scout panes as FM_TASK_HOME, beside FM_TASK_ID, so bin/fm-teardown.sh
# can tell this home's task apart from an equal task id in another home when it
# stops the browser bridges a task started (its header's Fix 4). It is this tag
# plus a short hash of the resolved FM_HOME, because homes that run from one
# code root share the tag itself; fm_backend_hometag stays per-installation
# because the zellij and cmux titles depend on it.
#
# Moving/relocating a firstmate installation changes its FM_ROOT path and
# therefore its tag; titles created under the old tag simply stop matching -
# an accepted limitation, no worse than the existing fact that a task's
# recorded absolute worktree path does not survive a move either.

FM_BACKEND_HOMETAG_SECONDMATE_MARKER=".fm-secondmate-home"

fm_backend_hometag() {
  local marker="$FM_HOME/$FM_BACKEND_HOMETAG_SECONDMATE_MARKER" id prefix root hash
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  root=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || root=$FM_ROOT
  hash=$(fm_backend_hometag_hash "$root")
  printf '%s-%s' "$prefix" "$hash"
}

# fm_backend_hometag_hash <text>: eight hex characters naming <text>.
fm_backend_hometag_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x", $1}'
  fi
}

fm_task_home_marker() {
  local home
  home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || home=$FM_HOME
  printf '%s-%s' "$(fm_backend_hometag)" "$(fm_backend_hometag_hash "$home")"
}

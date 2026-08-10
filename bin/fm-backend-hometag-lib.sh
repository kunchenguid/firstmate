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
# Moving/relocating a firstmate installation changes its FM_ROOT path and
# therefore its tag; titles created under the old tag simply stop matching -
# an accepted limitation, no worse than the existing fact that a task's
# recorded absolute worktree path does not survive a move either.
#
# fm_backend_hometag_for() is the same derivation with both inputs passed in
# explicitly, because the right discriminating path is NOT the same for every
# backend. zellij and cmux discriminate INSTALLATIONS sharing one app-global
# namespace, so FM_ROOT is right for them and fm_backend_hometag keeps that
# exact behavior. The tmux adapter's container is per-FM_HOME (its
# @firstmate-home stamp stores the resolved FM_HOME), so its collision
# fallback must discriminate by FM_HOME instead: a caller running the primary
# home's scripts with FM_HOME pointed at a secondmate home (the fail-closed
# cross-home form bin/fm-send.sh requires) has that secondmate's FM_HOME but
# the primary's FM_ROOT, and an FM_ROOT hash would derive a DIFFERENT session
# name there than the secondmate derives for itself from its own root.

FM_BACKEND_HOMETAG_SECONDMATE_MARKER=".fm-secondmate-home"

fm_backend_hometag_for() {  # <home-dir> <discriminator-path>
  local home_dir=$1 discriminator=$2
  local marker="$home_dir/$FM_BACKEND_HOMETAG_SECONDMATE_MARKER" id prefix resolved hash
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
  resolved=$(cd "$discriminator" 2>/dev/null && pwd -P) || resolved=$discriminator
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$resolved" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$resolved" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$resolved" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}

fm_backend_hometag() {
  fm_backend_hometag_for "$FM_HOME" "$FM_ROOT"
}

#!/usr/bin/env bash
# bin/fm-backend-hometag-lib.sh - shared per-installation home-tag derivation
# for session-provider backends whose container has ONE namespace shared by
# every firstmate home on the machine, with no native per-home split (cmux's
# one app-global workspace list, zellij's one shared "firstmate" session's
# tab bar, tern's one window-global session list, tmux's one shared
# "firstmate" container session, whose window names the tmux adapter keeps
# unique). Without a per-home
# discriminator embedded in the actual title/name, two firstmate homes (two
# secondmates, a primary plus a secondmate, or two independent primary
# installations) whose task ids
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
# FM_HOME/FM_ROOT fallbacks (every adapter already does this for its own
# purposes before any other function runs).
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
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}

# fm_backend_hometag_valid: succeed when <tag> has the shape
# fm_backend_hometag emits for SOME home - "firstmate-<8hex>" or
# "2ndmate-<id>-<8hex>" - without recomputing any home's tag. A reader that
# must accept another home's tag (a parent validating a child home's
# endpoint) anchors on this shape rather than on any dash-separated text.
fm_backend_hometag_valid() {  # <tag>
  local hash=${1##*-} prefix=${1%-*}
  case "$hash" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac
  case "$prefix" in
    *[!A-Za-z0-9._-]*) return 1 ;;
    firstmate|2ndmate-?*) return 0 ;;
  esac
  return 1
}

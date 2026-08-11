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
# carrying .fm-secondmate-home) plus a short hash of the resolved home identity
# path, so distinct homes - including multiple primaries on one
# machine - never collide even though they share one backend-global
# namespace. Callers source this file AFTER resolving their own
# FM_HOME/FM_ROOT fallbacks. FM_HOME_IDENTITY defaults to FM_ROOT for backward
# compatibility, but a relocated code installation sets it to the stable path
# identity that owns backend titles and deletion authority.
#
# Relocating only the installed code root does not change the tag when the
# caller preserves FM_HOME_IDENTITY.

FM_BACKEND_HOMETAG_SECONDMATE_MARKER=".fm-secondmate-home"

fm_backend_hometag() {
  local marker="$FM_HOME/$FM_BACKEND_HOMETAG_SECONDMATE_MARKER" id prefix identity hash
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
  identity=${FM_HOME_IDENTITY:-$FM_ROOT}
  identity=$(cd "$identity" 2>/dev/null && pwd -P) || identity=${FM_HOME_IDENTITY:-$FM_ROOT}
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$identity" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$identity" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$identity" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}

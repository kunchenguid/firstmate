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
# tab titles"). Herdr, which DOES split one workspace per home, uses the
# same tag for that one workspace-container label instead of per-tab titles,
# so two independent primary installations resolve to distinct workspaces
# rather than one shared bare-"firstmate" space (docs/herdr-backend.md
# "Label derivation").
#
# fm_backend_hometag() derives a short, stable tag: a readable prefix
# ("firstmate" for the primary home, "2ndmate-<id>" for a secondmate home
# carrying .fm-secondmate-home) plus a short hash of the resolved FM_HOME
# path, so distinct installations - including multiple primaries on one
# machine - never collide even though they share one backend-global
# namespace. Callers source this file AFTER resolving their own
# FM_HOME/FM_ROOT fallbacks (all three adapters already do this for their
# own purposes before any other function runs).
#
# BOTH halves of the tag come from the SAME home, $FM_HOME, and must keep
# doing so: FM_HOME is what selects the operational home, while FM_ROOT is
# only the repo the scripts happen to live in. In every well-formed home the
# two are the same path, so hashing FM_HOME is a no-op for existing tags and
# for cmux/zellij tabs already live under them - do not "restore" FM_ROOT
# here thinking it is load-bearing. It is not: the ONE case the two differ is
# a cross-home invocation (FM_HOME naming one home while another home's bin/
# runs the operation, which the FM_HOME contract permits), and hashing
# FM_ROOT there minted a tag whose readable prefix named one home and whose
# hash named another - a third label that neither home's find/list_live could
# ever match, so the tab was silently orphaned.
#
# Moving/relocating a firstmate home changes its FM_HOME path and therefore
# its tag; titles created under the old tag simply stop matching - an accepted
# limitation, no worse than the existing fact that a task's recorded absolute
# worktree path does not survive a move either.

FM_BACKEND_HOMETAG_SECONDMATE_MARKER=".fm-secondmate-home"

fm_backend_hometag() {
  local home="${FM_HOME:-$FM_ROOT}" marker id prefix real hash
  marker="$home/$FM_BACKEND_HOMETAG_SECONDMATE_MARKER"
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
  real=$(cd "$home" 2>/dev/null && pwd -P) || real=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$real" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}

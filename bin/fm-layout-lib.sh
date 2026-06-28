#!/usr/bin/env bash
# fm-layout-lib.sh — shared worker-discovery primitives for the orchestrator
# dashboard layout (bin/fm-layout.sh, bin/fm-watch-pane.sh, bin/fm-layout-pick.sh).
#
# ONE source of truth for: where a firstmate home's state lives, which crewmate
# windows are live "workers" worth watching, the terse repo/label a worker shows
# in the summary and watch headers, and the per-slot assignment files. Decoupled
# from any tmux arrangement so the discovery logic is unit-testable with a fake
# `tmux list-windows` and fixture state/*.meta, no real terminal required.
#
# A "worker" is any task this home recorded in state/<id>.meta whose tmux window
# is currently live. The orchestrator's own pane has no meta, so it is never a
# worker. Liveness is read from `tmux list-windows` (stubbable in tests), so a
# stale meta whose window is gone never appears as an assignable worker.
#
# All functions are `set -u`/`set -e` safe so they can be sourced into either an
# interactive arrange or a long-lived watch loop.

# Resolve this home's state dir the same way every other fm-*.sh does, honoring
# FM_STATE_OVERRIDE / FM_HOME / FM_ROOT_OVERRIDE. The caller may pre-export
# FM_LAYOUT_STATE to pin it (the watch panes do this so they read the same home
# the arrange command used regardless of the pane's inherited environment).
fm_layout_state() {
  if [ -n "${FM_LAYOUT_STATE:-}" ]; then
    printf '%s\n' "$FM_LAYOUT_STATE"
    return 0
  fi
  local script_dir root home
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}"
  home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
  printf '%s\n' "${FM_STATE_OVERRIDE:-$home/state}"
}

# fm_layout_label <id>: a terse, deterministic feature label for a task id by
# dropping the random suffix (the trailing "-<2-3 alnum>") and turning the rest
# into spaced words. e.g. "scrub-pajamas-refactor-y8" -> "scrub pajamas refactor".
# Truncated to FM_LAYOUT_LABEL_MAX (default 30) so the summary never long-wraps.
fm_layout_label() {
  local id=$1 max=${FM_LAYOUT_LABEL_MAX:-30} base
  base=$(printf '%s' "$id" | sed -E 's/-[a-z0-9]{2,3}$//')
  base=${base//-/ }
  if [ "${#base}" -gt "$max" ]; then
    base="${base:0:$((max - 1))}…"
  fi
  printf '%s' "$base"
}

# fm_layout_live_windows: print "session:window" for every live tmux window,
# one per line. Isolated behind a function so tests can stub `tmux`.
fm_layout_live_windows() {
  tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null || true
}

# fm_layout_meta_field <meta-file> <key>: echo the last value of key= in a meta
# file (last wins, mirroring fm-peek/fm-send), empty if absent.
fm_layout_meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_layout_workers: print every live worker as a TAB-separated record
#   <session:window>\t<repo>\t<label>
# sorted by window for stable ordering. A worker is a state/<id>.meta whose
# window= is currently live. repo is the basename of project=; label comes from
# fm_layout_label. Secondmate homes (kind=secondmate) are persistent supervisors,
# not project workers, so they are skipped unless FM_LAYOUT_INCLUDE_SECONDMATES=1.
fm_layout_workers() {
  local state live meta id window repo project kind
  state=$(fm_layout_state)
  [ -d "$state" ] || return 0
  live=$(fm_layout_live_windows)
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    window=$(fm_layout_meta_field "$meta" window)
    [ -n "$window" ] || continue
    # Only live windows are assignable workers.
    printf '%s\n' "$live" | grep -Fxq "$window" || continue
    kind=$(fm_layout_meta_field "$meta" kind)
    if [ "$kind" = secondmate ] && [ "${FM_LAYOUT_INCLUDE_SECONDMATES:-0}" != 1 ]; then
      continue
    fi
    project=$(fm_layout_meta_field "$meta" project)
    if [ -n "$project" ]; then repo=$(basename "$project"); else repo=$id; fi
    printf '%s\t%s\t%s\n' "$window" "$repo" "$(fm_layout_label "$id")"
  done | sort
}

# fm_layout_slot_file <state> <slot>: path of a slot's assignment file. Slot is
# 1..3 or the literal "summary". Lives under state/ (gitignored runtime), in the
# .layout-* namespace the watcher never touches.
fm_layout_slot_file() {
  printf '%s/.layout-slot-%s\n' "$1" "$2"
}

# fm_layout_ref <window> [format]: the worker-reference token to type into the
# composer for a worker, given its session:window. The format (default from
# FM_LAYOUT_REF_FORMAT, else "window") chooses what reaches the captain's message
# so they stop hand-copying terminal targets:
#   window  - just "fm-foo-k9" (the bare window name firstmate's tools resolve);
#             the short, human-readable default.
#   target  - "session:window" as-is (e.g. firstmate:fm-foo-k9); the literal tmux
#             target, directly usable with tmux and resolvable by fm-send/fm-peek.
#   select  - a ready-to-run "tmux select-window -t session:window" command.
# An unknown format falls back to target. This is pure string work (no tmux call),
# so it is trivially testable.
fm_layout_ref() {
  local window=$1 format=${2:-${FM_LAYOUT_REF_FORMAT:-window}}
  case "$format" in
    window) printf '%s' "${window##*:}" ;;
    select) printf 'tmux select-window -t %s' "$window" ;;
    target|*) printf '%s' "$window" ;;
  esac
}

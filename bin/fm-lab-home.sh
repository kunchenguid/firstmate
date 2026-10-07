#!/usr/bin/env bash
# fm-lab-home.sh - mint a disposable firstmate "lab" home.
#
# A lab home is a throwaway FM_HOME that a no-mistakes GATE agent may drive
# through the fleet lifecycle entrypoints: bin/fm-gate-refuse-lib.sh refuses
# those calls inside a gate agent unless FM_HOME carries the marker file this
# helper writes (the lib owns the marker format and authorization decision;
# this script is the supported writer).
#
# Usage:
#   fm-lab-home.sh create <dir>       make a marked lab home and print it
#   fm-lab-home.sh tmux-dir <dir>     create or print its private tmux socket dir
#   fm-lab-home.sh tmux <dir> <args>  run tmux against the lab's own server only
#   fm-lab-home.sh teardown <dir>     remove its private tmux socket dir
#
# A lab home is the stock layout only - state/, data/, config/, projects/ - and
# callers remove it with ordinary rm -rf when done. Drive it with plain
# FM_HOME=<dir>; any FM_*_OVERRIDE relocation defeats the allowance.
# tmux-dir is the single owner of the short private socket directory, and tmux
# the single way to address the server in it: it names the socket explicitly
# and refuses while no private directory exists. Never address the lab server
# through TMUX_TMPDIR alone: tmux treats a missing or empty TMUX_TMPDIR as absent
# and falls back to /tmp/tmux-<uid>, the operator's own default server, so a
# cleanup kill-server that runs before tmux-dir or after teardown stops every
# live session there. Processes started inside a running lab may still inherit
# TMUX_TMPDIR=<printed-dir>. A cleanup trap stops the lab server with
# `tmux <dir> kill-server`, then calls teardown.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

fm_lab_home_error() {
  echo "fm-lab-home: $*" >&2
}

fm_lab_home_tmux_record() { printf '%s/state/.fm-lab-tmux-dir' "$1"; }
fm_lab_home_mode() {
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}
fm_lab_home_owner() {
  case "$(uname -s)" in Darwin) stat -f '%u' "$1" ;; *) stat -c '%u' "$1" ;; esac
}

fm_lab_home_require() {  # <dir> <subcommand>
  [ -n "$1" ] || { fm_lab_home_error "$2 requires a marked lab home"; exit 2; }
  [ -f "$1/.fm-lab-home" ] && [ -d "$1/state" ] \
    || { fm_lab_home_error "refusing '$1': not a marked lab home"; exit 1; }
}

# Print the recorded private tmux directory once it is proven to be the private,
# user-owned directory tmux-dir minted. Returns 3 when none is recorded.
fm_lab_home_recorded_tmux_dir() {  # <dir>
  local record socket_dir
  record=$(fm_lab_home_tmux_record "$1")
  [ -f "$record" ] || return 3
  socket_dir=$(cat "$record")
  case "$socket_dir" in /tmp/fml.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) fm_lab_home_error "invalid recorded tmux directory"; return 1 ;; esac
  [ -d "$socket_dir" ] && [ ! -L "$socket_dir" ] \
    || { fm_lab_home_error "recorded tmux directory is missing or unsafe"; return 1; }
  [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
    || { fm_lab_home_error "recorded tmux directory is not private and user-owned"; return 1; }
  printf '%s\n' "$socket_dir"
}

case "${1:-}" in
  create)
    dir=${2:-}
    [ -n "$dir" ] || { fm_lab_home_error "create requires a directory path"; exit 2; }
    if [ -e "$dir" ] && [ ! -d "$dir" ]; then
      fm_lab_home_error "refusing '$dir': exists and is not a directory"
      exit 1
    fi
    mkdir -p "$dir" || exit 1
    fm_gate_lab_mark "$dir" || {
      fm_lab_home_error "refusing '$dir': a lab marker is only ever stamped on a fresh empty dir"
      exit 1
    }
    mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/projects" || exit 1
    printf '%s\n' "$dir"
    ;;
  tmux-dir)
    fm_lab_home_require "${2:-}" tmux-dir
    dir=$2
    record=$(fm_lab_home_tmux_record "$dir")
    socket_dir=$(fm_lab_home_recorded_tmux_dir "$dir")
    rc=$?
    if [ "$rc" -eq 3 ]; then
      socket_dir=$(mktemp -d /tmp/fml.XXXXXX) || exit 1
      chmod 700 "$socket_dir" || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      [ "$(fm_lab_home_mode "$socket_dir")" = 700 ] && [ "$(fm_lab_home_owner "$socket_dir")" = "$(id -u)" ] \
        || { rmdir "$socket_dir" 2>/dev/null || true; fm_lab_home_error "cannot secure tmux directory"; exit 1; }
      (umask 077; printf '%s\n' "$socket_dir" > "$record") || { rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
      chmod 600 "$record" || { rm -f "$record"; rmdir "$socket_dir" 2>/dev/null || true; exit 1; }
    elif [ "$rc" -ne 0 ]; then
      exit 1
    fi
    # The explicit socket the tmux subcommand names needs its directory up front;
    # it is the same path a TMUX_TMPDIR=<socket_dir> server listens on.
    (umask 077; mkdir -p "$socket_dir/tmux-$(id -u)") || exit 1
    printf '%s\n' "$socket_dir"
    ;;
  tmux)
    fm_lab_home_require "${2:-}" tmux
    dir=$2
    shift 2
    socket_dir=$(fm_lab_home_recorded_tmux_dir "$dir")
    rc=$?
    [ "$rc" -ne 3 ] || { fm_lab_home_error "refusing '$dir': it has no private tmux directory, so there is no lab server to address"; exit 1; }
    [ "$rc" -eq 0 ] || exit 1
    exec env -u TMUX -u TMUX_PANE tmux -S "$socket_dir/tmux-$(id -u)/default" "$@"
    ;;
  teardown)
    fm_lab_home_require "${2:-}" teardown
    dir=$2
    record=$(fm_lab_home_tmux_record "$dir")
    socket_dir=$(fm_lab_home_recorded_tmux_dir "$dir")
    rc=$?
    [ "$rc" -ne 3 ] || exit 0
    [ "$rc" -eq 0 ] || exit 1
    # -L names its own socket (not "default"); inspect every socket this
    # private TMUX_TMPDIR could have hosted before removing the directory.
    for socket in "$socket_dir/tmux-$(id -u)"/*; do
      [ -e "$socket" ] || [ -L "$socket" ] || continue
      if probe=$(tmux -S "$socket" list-sessions 2>&1 >/dev/null) \
        || [ "${probe#*no server running}" = "$probe" ]; then
        fm_lab_home_error "refusing teardown: cannot confirm the lab tmux server has stopped"
        exit 1
      fi
    done
    rm -rf "$socket_dir" && rm -f "$record"
    ;;
  *)
    fm_lab_home_error "usage: fm-lab-home.sh create <dir> | tmux-dir <dir> | tmux <dir> <args...> | teardown <dir>"
    exit 2
    ;;
esac

#!/usr/bin/env bash
# fm-remote-hc-lib.sh - where a remote second mate's herdr-core (hc) endpoint
# lives on its host, shared by the host-local control plane
# (bin/fm-remote-secondmate-control.sh) and the readiness doctor
# (bin/fm-remote-doctor.sh) so the two can never disagree about it.
#
# Source this file and call:
#   fm_remote_hc_session        print the hc session a remote mate lives in
#   fm_remote_hc_runtime_env    pin the per-user runtime directory hc resolves
#                               its core socket under
#
# The session is the host's `default` core: Herdr.app shows a connected
# machine's `default` core unless the machine was added with `--session`, so
# that is the core whose terminals appear in the captain's window.
# FM_REMOTE_HC_SESSION overrides it for labs and tests, which must never touch a
# real core; it accepts only a plain session name.
#
# The runtime pin exists because remote control commands can run under the
# Linux remote job worker, a system-level service whose environment carries no
# XDG_RUNTIME_DIR. hc then resolves its socket under ~/.local/state instead of
# /run/user/<uid>, finds no core there, and starts a second, empty core whose
# terminals the app never shows. When XDG_RUNTIME_DIR is unset and
# /run/user/<uid> is an existing directory owned by this account (the systemd
# convention every user service, including hc's own, runs under), this exports
# it; otherwise the environment is left unchanged and docs/hc-backend.md's
# socket resolution applies as written. An explicit FM_HC_SOCKET pin always
# wins over both, through the adapter.

fm_remote_hc_session() {
  local session=${FM_REMOTE_HC_SESSION:-default}
  case "$session" in
    '' | -* | *[!A-Za-z0-9_-]*)
      printf 'error: FM_REMOTE_HC_SESSION must be a plain hc session name, not %s\n' "$session" >&2
      return 1
      ;;
  esac
  printf '%s' "$session"
}

fm_remote_hc_runtime_env() {
  local uid dir
  [ -z "${XDG_RUNTIME_DIR:-}" ] || return 0
  uid=$(id -u 2>/dev/null) || return 0
  dir="/run/user/$uid"
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 0
  XDG_RUNTIME_DIR=$dir
  export XDG_RUNTIME_DIR
}

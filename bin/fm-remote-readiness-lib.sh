#!/usr/bin/env bash
# fm-remote-readiness-lib.sh - the remote second-mate readiness gate sequence.
#
# Source this file and call:
#   fm_remote_readiness_ensure <bin-dir> <secondmate-id>
#
# It runs bin/fm-remote-doctor.sh on that route's configured host, and when the
# read-only run reports any gap it runs the doctor again with --fix and then a
# third read-only time. That last read-only run is the verdict, so a repair is
# never trusted on its own word. bin/fm-remote-doctor.sh remains the single
# owner of every check, every repair, and every message; nothing here restates
# them.
#
# Returns 0 when the host is ready, 1 when a gap remains, and 255 when SSH could
# not complete. 255 means unknown remote completion, so a caller preserves its
# route and reconciles on the same host instead of treating it as a refusal.
# FM_REMOTE_READINESS_OUT always holds the output of the last run, which carries
# the check lines, the remaining human: gaps, and their exact operator actions.

# Consumed by the sourcing caller, so every assignment reads as unused here.
# shellcheck disable=SC2034
FM_REMOTE_READINESS_OUT=

# fm_wsl2_mirrored_networking_hint: prints one hint line when THIS host is the
# likely reason a remote route went unreachable, empty otherwise.
#
# SSH timing out to a remote LAN host this session previously reached is a
# known local-side failure mode on WSL2: the mirrored-networking mode that
# gives WSL2 a real LAN address needs a per-user .wslconfig
# (`[wsl2]` / `networkingMode=mirrored`), and that file can go missing (a
# Windows update, a profile reset) without any local error - WSL2 just falls
# back to isolated NAT, which still has a default route but no path to the
# LAN. This is a heuristic, additive hint only: it never replaces the
# existing unreachable-host message and a false negative (missed hint) is
# harmless, so detection stays deliberately simple rather than exhaustive.
# FM_WSL_CONFIG_PATH overrides the .wslconfig path this checks (tests only);
# unset or empty uses the real per-user Windows path.
# FM_WSL_USERS_DIR overrides the /mnt/c/Users base directory used to resolve
# that per-user path (tests only); unset or empty uses the real mount.
fm_wsl2_mirrored_networking_hint() {
  case "$(uname -r 2>/dev/null)" in
    *microsoft*|*WSL2*) ;;
    *) return 0 ;;
  esac
  local cfg="${FM_WSL_CONFIG_PATH:-}"
  if [ -z "$cfg" ]; then
    local users_dir="${FM_WSL_USERS_DIR:-/mnt/c/Users}" winuser
    winuser=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r\n')
    if [ -n "$winuser" ] && [ -f "$users_dir/$winuser/.wslconfig" ]; then
      cfg="$users_dir/$winuser/.wslconfig"
    else
      local matches=("$users_dir"/*/.wslconfig)
      if [ "${#matches[@]}" -eq 1 ] && [ -f "${matches[0]}" ]; then
        cfg="${matches[0]}"
      elif [ -n "${USER:-}" ]; then
        cfg="$users_dir/${USER}/.wslconfig"
      else
        return 0
      fi
    fi
  fi
  if [ -f "$cfg" ] && grep -Eiq '^[[:space:]]*networkingMode[[:space:]]*=[[:space:]]*mirrored[[:space:]]*$' "$cfg" 2>/dev/null; then
    return 0
  fi
  printf 'this host is WSL2 without networkingMode=mirrored in %s - if this route was reachable before, WSL2 likely reverted to isolated NAT networking; recreate that file with [wsl2] / networkingMode=mirrored, then run "wsl --shutdown" from Windows (not from inside WSL) and relaunch' "$cfg"
}

fm_remote_readiness_ensure() { # <bin-dir> <secondmate-id>
  local bin_dir=$1 id=$2 out rc

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh --fix < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255

  out=$("$bin_dir/fm-on.sh" "$id" fm-remote-doctor.sh < /dev/null 2>&1)
  rc=$?
  FM_REMOTE_READINESS_OUT=$out
  [ "$rc" -ne 255 ] || return 255
  [ "$rc" -eq 0 ] || return 1
  return 0
}

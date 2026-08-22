#!/usr/bin/env bash
# fm-lavish.sh - authoritative Firstmate Lavish runtime router.
#
# Usage:
#   fm-lavish.sh <artifact.html> [lavish-axi args...]
#   fm-lavish.sh open|poll|end|export|share <artifact.html> [args...]
#   fm-lavish.sh stop
#   fm-lavish.sh doctor [minimum-version]
#   fm-lavish.sh setup
#   fm-lavish.sh runtime
#
# On native Linux and macOS, this is a transparent argv-preserving launcher for
# the installed lavish-axi CLI. On WSL it refuses to start a Linux live session
# and routes every live-session lifecycle action through the tracked Windows
# PowerShell bridge instead. The bridge uses one Windows CLI, state store, and
# port for open, poll, end, export, share, and stop.
#
# FM_LAVISH_RUNTIME_OVERRIDE=native|windows is accepted only with
# FM_LAVISH_TESTING=1. Production routing is derived from WSL_DISTRO_NAME or the
# Microsoft WSL kernel release.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_BRIDGE="$SCRIPT_DIR/fm-lavish-windows.ps1"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-lavish: %s\n' "$*" >&2
  exit 1
}

runtime() {
  case "${FM_LAVISH_RUNTIME_OVERRIDE:-}" in
    native|windows)
      [ "${FM_LAVISH_TESTING:-0}" = 1 ] \
        || die "FM_LAVISH_RUNTIME_OVERRIDE is available only to executable tests"
      printf '%s\n' "$FM_LAVISH_RUNTIME_OVERRIDE"
      return 0
      ;;
    '') ;;
    *) die "FM_LAVISH_RUNTIME_OVERRIDE must be native or windows" ;;
  esac
  if [ -n "${WSL_DISTRO_NAME:-}" ] \
    || uname -r 2>/dev/null | grep -qi microsoft; then
    printf 'windows\n'
  else
    printf 'native\n'
  fi
}

windows_prerequisites() {
  [ -f "$WINDOWS_BRIDGE" ] || die "tracked Windows bridge is missing: $WINDOWS_BRIDGE"
  command -v powershell.exe >/dev/null 2>&1 \
    || die "powershell.exe is unavailable; install or enable Windows PowerShell interoperability for WSL"
  command -v wslpath >/dev/null 2>&1 \
    || die "wslpath is unavailable; install the WSL path utilities"
}

windows_invoke() { # <action> [artifact] [args...]
  local action=$1 windows_bridge artifact real windows_artifact
  shift
  windows_prerequisites
  windows_bridge=$(wslpath -w "$WINDOWS_BRIDGE") \
    || die "cannot convert the Windows bridge path"
  case "$action" in
    doctor|setup|stop)
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_bridge" "$action" "$@"
      return $?
      ;;
  esac
  artifact=${1-}
  [ -n "$artifact" ] || { usage; exit 2; }
  shift
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(realpath -- "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  windows_artifact=$(wslpath -w "$real") \
    || die "cannot convert the artifact path for Windows: $real"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$windows_bridge" \
    "$action" "$windows_artifact" "$@"
}

native_doctor() {
  local minimum=${1-} output version
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  [ -n "$minimum" ] || exit 0
  output=$(lavish-axi --version 2>/dev/null) || die "cannot read lavish-axi version"
  version=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)
  [ -n "$version" ] || die "cannot parse lavish-axi version: $output"
  if ! awk -v have="$version" -v need="$minimum" '
    BEGIN {
      split(have, h, "."); split(need, n, ".");
      for (i=1; i<=3; i++) {
        if ((h[i] + 0) > (n[i] + 0)) exit 0;
        if ((h[i] + 0) < (n[i] + 0)) exit 1;
      }
      exit 0;
    }
  '; then
    die "lavish-axi $version is older than required $minimum"
  fi
}

native_setup() {
  command -v npm >/dev/null 2>&1 || die "npm is required to install lavish-axi"
  npm install -g lavish-axi
  lavish-axi setup hooks
}

run_native() {
  local action=$1
  shift
  case "$action" in
    open)
      command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
      exec lavish-axi "$@"
      ;;
    poll|end|export|share|stop)
      command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
      exec lavish-axi "$action" "$@"
      ;;
  esac
}

case "${1-}" in
  runtime)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    runtime
    exit $?
    ;;
  doctor)
    shift
    [ "$#" -le 1 ] || { usage; exit 2; }
    if [ "$(runtime)" = windows ]; then
      windows_invoke doctor "$@"
    else
      native_doctor "$@"
    fi
    exit $?
    ;;
  setup)
    shift
    [ "$#" -eq 0 ] || { usage; exit 2; }
    if [ "$(runtime)" = windows ]; then
      windows_invoke setup
    else
      native_setup
    fi
    exit $?
    ;;
  stop)
    shift
    [ "$#" -eq 0 ] || { usage; exit 2; }
    if [ "$(runtime)" = windows ]; then
      windows_invoke stop
    else
      run_native stop
    fi
    exit $?
    ;;
  open|poll|end|export|share)
    action=$1
    shift
    ;;
  ''|-h|--help|help)
    usage
    exit 2
    ;;
  *)
    action=open
    ;;
esac

if [ "$(runtime)" = windows ]; then
  windows_invoke "$action" "$@"
else
  run_native "$action" "$@"
fi

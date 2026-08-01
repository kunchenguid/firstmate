#!/usr/bin/env bash
# fm-primary-pi-install.sh - reversible local convenience install for guarded
# Pi-on-Herdr recovery.
#
# Usage:
#   fm-primary-pi-install.sh install
#   fm-primary-pi-install.sh uninstall
#   fm-primary-pi-install.sh status
#
# `install` writes two user-local files but never calls launchctl, enables a
# service, changes SSH/Tailscale, or starts Herdr/Pi:
#   ~/Library/LaunchAgents/dev.firstmate.primary-herdr.plist
#     - RunAtLoad=true, KeepAlive=false, one call to
#       bin/fm-primary-pi.sh server-ensure after the next login.
#   ~/.local/bin/firstmate-attach
#     - an exact-path wrapper for bin/fm-primary-pi.sh recover, suitable for a
#       local or already-established remote shell such as a phone SSH session.
#
# Installation is idempotent and atomic. Existing files are replaceable only
# when they carry this installer's exact marker. Foreign files or symlinks are
# refused. `uninstall` removes only marker-owned regular files and is otherwise
# idempotent. FM_PRIMARY_INSTALL_HOME is a test/specialized-setup override for
# the destination user home; FM_HOME binds both generated files to the intended
# Firstmate state home, and the tracked script path is always canonicalized.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DEST_HOME="${FM_PRIMARY_INSTALL_HOME:-$HOME}"
MARKER='firstmate-primary-pi-install:v1'
PLIST="$DEST_HOME/Library/LaunchAgents/dev.firstmate.primary-herdr.plist"
HELPER="$DEST_HOME/.local/bin/firstmate-attach"
OWNER="$FM_ROOT/bin/fm-primary-pi.sh"
SOURCE_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

fail() {
  printf 'fm-primary-pi-install: %s\n' "$*" >&2
  exit 1
}

canonical_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (cd "$1" && pwd -P)
}

validate_destination() {
  local home source_home
  home=$(canonical_dir "$DEST_HOME") || fail "destination home is not a canonical existing directory: $DEST_HOME"
  [ "$home" = "$DEST_HOME" ] || fail "destination home must use canonical spelling: $home"
  source_home=$(canonical_dir "$SOURCE_HOME") || fail "Firstmate home is not a canonical existing directory: $SOURCE_HOME"
  [ "$source_home" = "$SOURCE_HOME" ] || fail "Firstmate home must use canonical spelling: $source_home"
  case "$OWNER$SOURCE_HOME" in *'<'*|*'>'*|*'&'*|*"'"*|*$'\n'*|*$'\r'*) fail "tracked script or home path cannot be represented safely in installed files" ;; esac
  [ -x "$OWNER" ] || fail "tracked recovery script is not executable: $OWNER"
}

render_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $MARKER -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.firstmate.primary-herdr</string>
  <key>ProgramArguments</key>
  <array>
    <string>$OWNER</string>
    <string>server-ensure</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$SOURCE_HOME</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF
}

render_helper() {
  cat <<EOF
#!/bin/sh
# $MARKER
exec env FM_HOME='$SOURCE_HOME' '$OWNER' recover "\$@"
EOF
}

owned_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && grep -Fq "$MARKER" "$1"
}

preflight_path() {
  local path=$1 dir canonical
  dir=${path%/*}
  mkdir -p "$dir" || fail "cannot create destination directory: $dir"
  canonical=$(canonical_dir "$dir") || fail "destination directory is not a regular directory: $dir"
  [ "$canonical" = "$dir" ] || fail "destination directory contains a symlink or noncanonical component: $dir"
  if [ -e "$path" ] || [ -L "$path" ]; then
    owned_file "$path" || fail "refusing to replace foreign or symlink destination: $path"
  fi
}

atomic_install() {
  local path=$1 mode=$2 renderer=$3 dir tmp canonical
  dir=${path%/*}
  canonical=$(canonical_dir "$dir") || fail "destination directory changed before install: $dir"
  [ "$canonical" = "$dir" ] || fail "destination directory changed to a symlink before install: $dir"
  if [ -e "$path" ] || [ -L "$path" ]; then
    owned_file "$path" || fail "destination changed to a foreign file before install: $path"
  fi
  tmp="$dir/.fm-primary-install.$$"
  umask 077
  "$renderer" > "$tmp" || { rm -f "$tmp"; fail "could not render $path"; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; fail "could not protect $path"; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; fail "could not install $path"; }
}

install_files() {
  validate_destination
  preflight_path "$PLIST"
  preflight_path "$HELPER"
  atomic_install "$PLIST" 600 render_plist
  atomic_install "$HELPER" 700 render_helper
  printf 'installed for next login without enabling: %s\n' "$PLIST"
  printf 'phone/local attach helper: %s\n' "$HELPER"
}

uninstall_file() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 0; fi
  owned_file "$1" || fail "refusing to remove foreign or symlink destination: $1"
  rm -f "$1"
}

uninstall_files() {
  validate_destination
  uninstall_file "$HELPER"
  uninstall_file "$PLIST"
  printf 'uninstalled local recovery convenience files\n'
}

status_files() {
  local plist=absent helper=absent
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then
    owned_file "$PLIST" && plist=installed || plist=foreign
  fi
  if [ -e "$HELPER" ] || [ -L "$HELPER" ]; then
    owned_file "$HELPER" && helper=installed || helper=foreign
  fi
  printf 'launch-agent=%s attach-helper=%s enabled=not-managed\n' "$plist" "$helper"
}

case "${1:-}" in
  -h|--help|help) usage ;;
  install) [ "$#" -eq 1 ] || fail "install takes no options"; fm_refuse_if_gate_agent "$FM_ROOT"; install_files ;;
  uninstall) [ "$#" -eq 1 ] || fail "uninstall takes no options"; fm_refuse_if_gate_agent "$FM_ROOT"; uninstall_files ;;
  status) [ "$#" -eq 1 ] || fail "status takes no options"; status_files ;;
  *) usage >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# Resume this firstmate home's supervision session on demand, from a launchd
# LaunchAgent that is registered but carries no automatic trigger.
# Usage: fm-relaunch.sh install|status|uninstall|run [--help]
#
# Mechanism, safety property, and the AppleScript-driven trust-dialog and
# kickoff-message handshake are owned by docs/relaunch-tool.md - this header
# stays a pointer, not a restatement.
#
# macOS-only (launchd). Fails closed with a clear message on any other platform.
set -eu

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  sed -n '2,10p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

fm_relaunch_require_macos() {
  [ "$(uname -s)" = Darwin ] || {
    echo "error: fm-relaunch.sh is macOS-only (needs launchd); this platform is $(uname -s)" >&2
    exit 1
  }
}

# Label derivation: the default (unoverridden) home gets the bare label so a
# fresh install cleanly supersedes the hand-built prototype job of the same
# name; any home with an explicit FM_HOME (e.g. a secondmate) gets a stable
# suffix derived from that path so multiple homes never collide on one label.
fm_relaunch_label() {
  if [ "$FM_HOME" = "$FM_ROOT" ]; then
    printf 'dev.firstmate.relaunch'
    return
  fi
  local slug
  if command -v shasum >/dev/null 2>&1; then
    slug=$(printf '%s' "$FM_HOME" | shasum -a 256 | cut -c1-8)
  elif command -v sha256sum >/dev/null 2>&1; then
    slug=$(printf '%s' "$FM_HOME" | sha256sum | cut -c1-8)
  else
    echo "error: need shasum or sha256sum to derive a per-home label" >&2
    exit 1
  fi
  printf 'dev.firstmate.relaunch.%s' "$slug"
}

LABEL="$(fm_relaunch_label)"
DOMAIN="gui/$(id -u)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"

fm_relaunch_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

fm_relaunch_write_plist() {  # <out-path>
  local out=$1
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$SCRIPT_PATH</string>
		<string>fire</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>FM_HOME</key>
		<string>$FM_HOME</string>
	</dict>
	<key>StandardOutPath</key>
	<string>$FM_HOME/state/fm-relaunch.log</string>
	<key>StandardErrorPath</key>
	<string>$FM_HOME/state/fm-relaunch.log</string>
</dict>
</plist>
PLIST
}

cmd_install() {
  fm_relaunch_require_macos
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-relaunch-plist.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  fm_relaunch_write_plist "$tmp"
  if [ -f "$PLIST_PATH" ] && cmp -s "$tmp" "$PLIST_PATH" && fm_relaunch_loaded; then
    rm -f -- "$tmp"
    trap - EXIT
    echo "installed: $LABEL already up to date and loaded"
    return 0
  fi
  if fm_relaunch_loaded; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  mv -f -- "$tmp" "$PLIST_PATH"
  trap - EXIT
  chmod 0644 "$PLIST_PATH"
  launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
  echo "installed: $LABEL ($PLIST_PATH), loaded with no automatic trigger"
}

cmd_status() {
  fm_relaunch_require_macos
  if [ ! -f "$PLIST_PATH" ]; then
    echo "status: $LABEL not installed"
    return 1
  fi
  if grep -Eq '<key>(RunAtLoad|StartInterval|StartCalendarInterval|WatchPaths|QueueDirectories|KeepAlive)</key>' "$PLIST_PATH"; then
    echo "status: DANGER - $PLIST_PATH declares an automatic trigger key; reinstall to regenerate it safely" >&2
    return 1
  fi
  echo "status: $LABEL installed at $PLIST_PATH, no automatic trigger key present"
  if fm_relaunch_loaded; then
    echo "status: loaded in $DOMAIN"
  else
    echo "status: NOT loaded in $DOMAIN (run install)"
    return 1
  fi
}

cmd_uninstall() {
  fm_relaunch_require_macos
  if fm_relaunch_loaded; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  rm -f -- "$PLIST_PATH"
  echo "uninstalled: $LABEL"
}

cmd_run() {
  fm_relaunch_require_macos
  [ -f "$PLIST_PATH" ] || {
    echo "error: $LABEL is not installed; run 'fm-relaunch.sh install' first" >&2
    exit 1
  }
  fm_relaunch_loaded || launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
  launchctl kickstart -k "$DOMAIN/$LABEL"
  echo "fired: $LABEL"
}

# Invoked only as the launchd job's ProgramArguments target (see
# fm_relaunch_write_plist); opens a terminal running claude in $FM_HOME and
# drives the trust-dialog/kickoff handshake documented in docs/relaunch-tool.md.
cmd_fire() {
  fm_relaunch_require_macos
  command -v osascript >/dev/null 2>&1 || {
    echo "error: osascript not found; cannot open a terminal" >&2
    exit 1
  }
  local target_dir script
  target_dir=$FM_HOME
  script=$(cat <<'APPLESCRIPT'
on run argv
  set targetDir to item 1 of argv
  tell application "Terminal"
    activate
    do script "cd " & quoted form of targetDir & " && exec claude"
  end tell
  delay 2.5
  tell application "System Events"
    tell process "Terminal"
      set frontmost to true
      key code 36
      delay 1
      keystroke "hi"
      key code 36
    end tell
  end tell
end run
APPLESCRIPT
)
  osascript -e "$script" -- "$target_dir"
}

case "${1:-}" in
  install) cmd_install ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  run) cmd_run ;;
  fire) cmd_fire ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac

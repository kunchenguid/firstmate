#!/usr/bin/env bash
# Install and operate the central macOS Crosscheck Slack listener.
#
# Usage: fm-crosscheck-slack-service.sh install|start|stop|restart|status|uninstall
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CROSSCHECK_SLACK_CONFIG:-$FM_HOME/config/crosscheck-slack.json}"
LABEL=com.firstmate.crosscheck-slack
DOMAIN="gui/$(id -u)"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"
LOG_DIR="$FM_HOME/logs"
STDOUT_LOG="$LOG_DIR/crosscheck-slack.log"
STDERR_LOG="$LOG_DIR/crosscheck-slack.error.log"
WRAPPER="$FM_ROOT/bin/fm-crosscheck-slack.sh"

usage() {
  echo "usage: $0 install|start|stop|restart|status|uninstall" >&2
  exit 2
}

write_plist() {
  # shellcheck source=bin/fm-crosscheck-python-lib.sh
  . "$SCRIPT_DIR/fm-crosscheck-python-lib.sh"
  interpreter=$(fm_crosscheck_resolve_python)
  interpreter=$("$interpreter" -c 'import os, sys; print(os.path.abspath(sys.executable))')
  mkdir -p "$AGENT_DIR" "$LOG_DIR"
  temporary=$(mktemp "$AGENT_DIR/.$LABEL.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  "$interpreter" - "$temporary" "$LABEL" "$WRAPPER" "$CONFIG" "$HOME" \
    "$PATH" "$interpreter" "$FM_HOME" "$STDOUT_LOG" "$STDERR_LOG" <<'PY'
import plistlib
import sys

(
    destination,
    label,
    wrapper,
    config,
    home,
    path,
    interpreter,
    fm_home,
    stdout_log,
    stderr_log,
) = sys.argv[1:]
document = {
    "Label": label,
    "ProgramArguments": [wrapper, "run", "--config", config, "--keychain-only"],
    "EnvironmentVariables": {
        "HOME": home,
        "PATH": path,
        "FM_CROSSCHECK_PYTHON": interpreter,
        "FM_HOME": fm_home,
        "FM_CROSSCHECK_SLACK_CONFIG": config,
    },
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 10,
    "StandardOutPath": stdout_log,
    "StandardErrorPath": stderr_log,
}
with open(destination, "wb") as handle:
    plistlib.dump(document, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY
  chmod 600 "$temporary"
  validate_plist "$temporary"
  mv "$temporary" "$PLIST"
  trap - EXIT
}

validate_plist() {
  # shellcheck source=bin/fm-crosscheck-python-lib.sh
  . "$SCRIPT_DIR/fm-crosscheck-python-lib.sh"
  validator_python=$(fm_crosscheck_resolve_python)
  "$validator_python" - "$1" <<'PY'
import plistlib
import subprocess
import sys

with open(sys.argv[1], "rb") as handle:
    agent = plistlib.load(handle)
command = agent["ProgramArguments"]
if "--keychain-only" not in command:
    raise SystemExit("error: reinstall the service to require Keychain credentials")
environment = agent["EnvironmentVariables"]
for arguments in ([command[0], "--selftest", command[3]], [command[0], "preflight", *command[2:]]):
    result = subprocess.run(arguments, env=environment, timeout=60, check=False)
    if result.returncode:
        raise SystemExit(result.returncode)
PY
}

loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

stop_service() {
  if loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
  fi
}

case "${1:-}" in
  install)
    [ -x "$WRAPPER" ] || {
      echo "error: Crosscheck Slack wrapper is not executable at $WRAPPER" >&2
      exit 1
    }
    write_plist
    echo "installed: $PLIST"
    echo "listener remains stopped until '$0 start' passes credential preflight"
    ;;
  start)
    [ -f "$PLIST" ] || {
      echo "error: service is not installed at $PLIST" >&2
      exit 1
    }
    validate_plist "$PLIST"
    stop_service
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl enable "$DOMAIN/$LABEL"
    launchctl kickstart -k "$DOMAIN/$LABEL"
    echo "started: $LABEL"
    ;;
  stop)
    stop_service
    echo "stopped: $LABEL"
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  status)
    if loaded; then
      launchctl print "$DOMAIN/$LABEL"
    else
      echo "stopped: $LABEL"
      exit 3
    fi
    ;;
  uninstall)
    stop_service
    if [ -f "$PLIST" ]; then
      rm "$PLIST"
    fi
    echo "uninstalled: $LABEL (logs and durable review state retained)"
    ;;
  *) usage ;;
esac

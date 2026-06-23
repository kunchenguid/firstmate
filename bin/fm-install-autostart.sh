#!/usr/bin/env bash
# Install (or remove) the systemd unit that makes firstmate survive a WSL VM
# teardown - the failure that took the fleet out overnight (AGENTS.md section 5).
#
# systemd runs as PID 1 in this distro ([boot] systemd=true in /etc/wsl.conf),
# so a system unit started at multi-user.target is the native, reboot-proof way
# to auto-resurrect firstmate. The unit runs bin/fm-resume.sh as a watchdog.
#
# Usage:
#   fm-install-autostart.sh            install, enable, and start the unit
#   fm-install-autostart.sh status     show unit + session state
#   fm-install-autostart.sh uninstall  stop, disable, and remove the unit
#
# Reversible: `uninstall` leaves no trace and never touches a running firstmate
# session (KillMode=process in the unit), so removing autostart cannot discard work.
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_SRC="$FM_ROOT/systemd/firstmate.service"
UNIT_NAME="firstmate.service"
UNIT_DST="/etc/systemd/system/$UNIT_NAME"

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "error: systemctl not found; this distro is not running systemd" >&2
    exit 1
  fi
  if [ "$(ps -p 1 -o comm= 2>/dev/null)" != systemd ]; then
    echo "error: PID 1 is not systemd; enable '[boot] systemd=true' in /etc/wsl.conf, then 'wsl --shutdown'" >&2
    exit 1
  fi
}

cmd_install() {
  require_systemd
  [ -f "$UNIT_SRC" ] || { echo "error: unit not found at $UNIT_SRC" >&2; exit 1; }
  # Install a copy (not a symlink): systemd does not follow symlinks under
  # /mnt/c reliably, and the repo path is not guaranteed mounted at early boot.
  install -m 0644 "$UNIT_SRC" "$UNIT_DST"
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME"
  systemctl restart "$UNIT_NAME"
  echo "installed and enabled $UNIT_NAME"
  echo "firstmate will now auto-resurrect on every boot and self-heal if it dies."
  cmd_status
}

cmd_uninstall() {
  require_systemd
  systemctl disable "$UNIT_NAME" 2>/dev/null || true
  systemctl stop "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_DST"
  systemctl daemon-reload
  echo "removed $UNIT_NAME (any running firstmate session was left untouched)"
}

cmd_status() {
  require_systemd
  echo "--- unit ---"
  systemctl is-enabled "$UNIT_NAME" 2>/dev/null | sed 's/^/enabled: /' || echo "enabled: no"
  systemctl is-active "$UNIT_NAME" 2>/dev/null | sed 's/^/active: /' || echo "active: no"
  echo "--- session ---"
  if tmux has-session -t "${FM_SESSION:-firstmate}" 2>/dev/null; then
    echo "firstmate tmux session: LIVE (attach with: tmux attach -t ${FM_SESSION:-firstmate})"
  else
    echo "firstmate tmux session: not present"
  fi
}

case "${1:-install}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *) echo "usage: $(basename "$0") [install|status|uninstall]" >&2; exit 2 ;;
esac

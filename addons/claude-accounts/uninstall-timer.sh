#!/usr/bin/env bash
# Disable and remove the fm-claude-accounts-quota timer, its service and the copied reader.
# Usage: uninstall-timer.sh
set -euo pipefail
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
systemctl --user disable --now fm-claude-accounts-quota.timer 2>/dev/null || true
rm -f -- "$UNITS/fm-claude-accounts-quota.timer" "$UNITS/fm-claude-accounts-quota.service" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/fm-claude-accounts/claude-accounts-quota.sh"
rmdir "${XDG_DATA_HOME:-$HOME/.local/share}/fm-claude-accounts" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
echo "removed: fm-claude-accounts-quota timer"

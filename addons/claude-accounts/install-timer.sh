#!/usr/bin/env bash
# Install a systemd user timer that runs claude-accounts-quota.sh every 5 minutes for one Firstmate home, so the
# dashboard's Claude accounts card and state/claude-accounts.json stay fresh. Copies the reader to
# ${XDG_DATA_HOME:-~/.local/share}/fm-claude-accounts/, writes fm-claude-accounts-quota.service and .timer under
# ~/.config/systemd/user/ (the unit carries the installer's PATH so quota-axi and jq resolve), and enables the timer only when a file changed. Reads quota only; touches no login folder.
# Usage: install-timer.sh [--dry-run] <fm-home>      (--dry-run writes nothing)       Undo: uninstall-timer.sh
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "usage: install-timer.sh [--dry-run] <fm-home>" >&2; exit 2; }
HOME_DIR=$(cd "$1" && pwd -P)
SRC=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bin/claude-accounts-quota.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-claude-accounts/claude-accounts-quota.sh
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/service" <<UNIT
[Unit]
Description=Firstmate Claude accounts quota reading for $HOME_DIR

[Service]
Type=oneshot
Environment=FM_HOME=$HOME_DIR
Environment=PATH=$PATH
ExecStart=$DEST
UNIT
cat > "$TMP/timer" <<'UNIT'
[Unit]
Description=Read every Claude account's quota every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
changed=0
cmp -s "$SRC" "$DEST" || { echo "$DEST: install from $SRC"; changed=1; }
for u in service timer; do
  cmp -s "$TMP/$u" "$UNITS/fm-claude-accounts-quota.$u" || { echo "$UNITS/fm-claude-accounts-quota.$u:"; sed 's/^/  /' "$TMP/$u"; changed=1; }
done
[ "$changed" -eq 1 ] || { echo "unchanged: fm-claude-accounts-quota.timer"; exit 0; }
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written"; exit 0; }
install -D -m 755 "$SRC" "$DEST"
install -D -m 644 "$TMP/service" "$UNITS/fm-claude-accounts-quota.service"
install -D -m 644 "$TMP/timer" "$UNITS/fm-claude-accounts-quota.timer"
systemctl --user daemon-reload
systemctl --user enable --now fm-claude-accounts-quota.timer
echo "written and enabled: fm-claude-accounts-quota.timer"

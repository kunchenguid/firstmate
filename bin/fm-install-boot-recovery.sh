#!/usr/bin/env bash
# fm-install-boot-recovery.sh - install the machine-private user boot units.
#
# Usage:
#   FM_HOME=/path/to/firstmate bin/fm-install-boot-recovery.sh
#
# The generated files live in the user's systemd configuration, not the tracked
# repository.
# The timer runs once a few minutes after each user-manager boot.
# Its recovery service invokes bin/fm-reboot-sweep.sh --recover and retries only
# while the restored primary cannot be reached or a required safe repair fails.
# A separate static service owns one temporary fm-watch-arm.sh cycle when the
# home watcher is stale.
# No generated unit starts a Telegram listener, a channels session, or an agent
# repair command.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
SYSTEMCTL_BIN=${FM_REBOOT_SYSTEMCTL:-systemctl}
UNIT_DIR=${FM_REBOOT_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
BIZMATE_START=${FM_REBOOT_BIZMATE_START:-$HOME/.local/bin/bizmate-start}

die() {
  printf 'fm-install-boot-recovery: %s\n' "$*" >&2
  exit 1
}

[ ! -e "$FM_HOME/.fm-secondmate-home" ] \
  || die "refusing to install machine boot units from a secondmate home"
[ -x "$FM_ROOT/bin/fm-reboot-sweep.sh" ] \
  || die "missing executable $FM_ROOT/bin/fm-reboot-sweep.sh"
[ -x "$FM_ROOT/bin/fm-watch-arm.sh" ] \
  || die "missing executable $FM_ROOT/bin/fm-watch-arm.sh"
command -v "$SYSTEMCTL_BIN" >/dev/null 2>&1 \
  || [ -x "$SYSTEMCTL_BIN" ] \
  || die "systemctl is required"

fm_unit_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g'
}

ROOT_ESCAPED=$(fm_unit_escape "$FM_ROOT")
HOME_ESCAPED=$(fm_unit_escape "$FM_HOME")
BIZMATE_ESCAPED=$(fm_unit_escape "$BIZMATE_START")
mkdir -p "$UNIT_DIR"

timer_tmp=$(mktemp "$UNIT_DIR/.fm-boot-recovery.timer.XXXXXX")
service_tmp=$(mktemp "$UNIT_DIR/.fm-boot-recovery.service.XXXXXX")
watcher_tmp=$(mktemp "$UNIT_DIR/.fm-boot-watcher.service.XXXXXX")
cleanup() {
  rm -f "$timer_tmp" "$service_tmp" "$watcher_tmp"
}
trap cleanup EXIT HUP INT TERM

cat > "$timer_tmp" <<'UNIT'
[Unit]
Description=Run Firstmate boot recovery after restored sessions settle

[Timer]
OnBootSec=2min
AccuracySec=15s
Unit=fm-boot-recovery.service

[Install]
WantedBy=timers.target
UNIT

cat > "$service_tmp" <<UNIT
[Unit]
Description=Wake Firstmate and repair safe boot dependencies
After=default.target
StartLimitIntervalSec=15min
StartLimitBurst=30

[Service]
Type=oneshot
Environment="FM_HOME=$HOME_ESCAPED"
Environment="FM_ROOT_OVERRIDE=$ROOT_ESCAPED"
Environment="FM_REBOOT_BIZMATE_START=$BIZMATE_ESCAPED"
ExecStart="$ROOT_ESCAPED/bin/fm-reboot-sweep.sh" --recover
Restart=on-failure
RestartSec=30s
UNIT

cat > "$watcher_tmp" <<UNIT
[Unit]
Description=Temporary Firstmate boot watcher backstop

[Service]
Type=simple
Environment="FM_HOME=$HOME_ESCAPED"
Environment="FM_ROOT_OVERRIDE=$ROOT_ESCAPED"
ExecStart="$ROOT_ESCAPED/bin/fm-watch-arm.sh"
Restart=no
TimeoutStopSec=15s
UNIT

chmod 0644 "$timer_tmp" "$service_tmp" "$watcher_tmp"
mv -f "$timer_tmp" "$UNIT_DIR/fm-boot-recovery.timer"
mv -f "$service_tmp" "$UNIT_DIR/fm-boot-recovery.service"
mv -f "$watcher_tmp" "$UNIT_DIR/fm-boot-watcher.service"

"$SYSTEMCTL_BIN" --user daemon-reload
"$SYSTEMCTL_BIN" --user enable --now fm-boot-recovery.timer
printf 'fm-install-boot-recovery: installed and enabled fm-boot-recovery.timer in %s\n' "$UNIT_DIR"

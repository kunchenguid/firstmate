#!/usr/bin/env bash
# fm-boot-resume-install.sh - render and install the systemd user units that
# make firstmate's boot resume live (S5 away autonomy): the boot oneshot that
# runs bin/fm-boot-resume.sh at default.target, and the watcher-beat watchdog
# timer that runs bin/fm-watchdog-beat.sh every 5 minutes.
#
# Usage:
#   fm-boot-resume-install.sh [--home <dir>] [--herdr-session <name>]
#                             [--units-dir <dir>] [--enable | --no-enable] [--print]
#
# The units are rendered for ONE home with baked absolute paths (the same shape
# the herdr bucket units use), because a user manager gives this script no
# reliable way to pass a per-instance home otherwise. Rendering is idempotent:
# re-running overwrites the same files, so an updated firstmate refreshes its
# own units. Nothing is enabled unless --enable is passed, and --print renders
# to stdout only (for review, docs, and tests).
#
#   --home <dir>           home the units serve (default: this checkout's root;
#                          must contain bin/fm-boot-resume.sh and
#                          bin/fm-watchdog-beat.sh)
#   --herdr-session <name> herdr bucket session the boot unit soft-orders
#                          after (default: personal; the After= line is only a
#                          soft ordering, an absent unit is not an error - the
#                          script's own bounded readiness probe owns the wait)
#   --units-dir <dir>      unit destination (default:
#                          $HOME/.config/systemd/user)
#   --enable               after install: daemon-reload, enable the boot unit
#                          (default.target) and enable --now the watchdog
#                          timer (timers.target)
#   --no-enable            install without enabling (the default)
#   --print                render the units to stdout; install and enable
#                          nothing (incompatible with --enable)
#
# Exit status: 0 units rendered (and installed/enabled as asked), 1 bad input
# or a failed install step, 2 invalid use.
#
# The Windows-side keepalive (keeping the WSL VM from shutting down while the
# workstation is unattended) is a captain action and is documented, never
# installed here: docs/boot-resume.md owns those exact steps.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_HOME=$(cd "$SCRIPT_DIR/.." && pwd)

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-boot-resume-install: %s\n' "$*" >&2
  exit 1
}

HOME_DIR=$DEFAULT_HOME
HERDR_SESSION=personal
UNITS_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
ENABLE=0
PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "--home needs a value"; HOME_DIR=$2; shift 2 ;;
    --herdr-session) [ $# -ge 2 ] || die "--herdr-session needs a value"; HERDR_SESSION=$2; shift 2 ;;
    --units-dir) [ $# -ge 2 ] || die "--units-dir needs a value"; UNITS_DIR=$2; shift 2 ;;
    --enable) ENABLE=1; shift ;;
    --no-enable) ENABLE=0; shift ;;
    --print) PRINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

[ "$ENABLE" -eq 0 ] || [ "$PRINT" -eq 0 ] || die "--print cannot combine with --enable"

HOME_DIR=$(cd "$HOME_DIR" 2>/dev/null && pwd) || die "--home '$HOME_DIR' is not a directory"
for probe in bin/fm-boot-resume.sh bin/fm-watchdog-beat.sh bin/fm-watch.sh; do
  [ -f "$HOME_DIR/$probe" ] || die "$HOME_DIR/$probe is missing; pass --home <a firstmate checkout>"
done
command -v systemctl >/dev/null 2>&1 || [ "$ENABLE" -eq 0 ] \
  || die "systemctl not found; install without --enable on hosts without systemd"

# Bake the operator's PATH (user prefixes included) exactly like the herdr
# bucket units do; a user manager's own PATH carries none of it.
UNIT_PATH=$PATH

render_boot_unit() {
  cat <<EOF
[Unit]
Description=Firstmate boot resume for ${HOME_DIR}
Documentation=file:${HOME_DIR}/docs/boot-resume.md
# Soft ordering only: the herdr bucket unit restores the panes the resume
# relaunches agents into, but a missing bucket unit must never block boot;
# bin/fm-boot-resume.sh owns a bounded readiness probe instead.
After=herdr-bucket@${HERDR_SESSION}.service default.target

[Service]
Type=oneshot
Environment=FM_HOME=${HOME_DIR}
Environment=PATH=${UNIT_PATH}
ExecStart=${HOME_DIR}/bin/fm-boot-resume.sh
# A failed resume must not wedge default.target: the watchdog timer owns
# retries through the same bounded ledger.
TimeoutStartSec=20min

[Install]
WantedBy=default.target
EOF
}

render_watchdog_service() {
  cat <<EOF
[Unit]
Description=Firstmate watcher-beat watchdog tick for ${HOME_DIR}
Documentation=file:${HOME_DIR}/docs/boot-resume.md

[Service]
Type=oneshot
Environment=FM_HOME=${HOME_DIR}
Environment=PATH=${UNIT_PATH}
ExecStart=${HOME_DIR}/bin/fm-watchdog-beat.sh
TimeoutStartSec=15min
EOF
}

render_watchdog_timer() {
  cat <<EOF
[Unit]
Description=Run the Firstmate watcher-beat watchdog every 5 minutes for ${HOME_DIR}

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true
Unit=firstmate-watchdog-beat.service

[Install]
WantedBy=timers.target
EOF
}

write_unit() {  # <name> <body-on-stdin>
  local name=$1
  mkdir -p "$UNITS_DIR" || die "cannot create $UNITS_DIR"
  cat > "$UNITS_DIR/$name" || die "cannot write $UNITS_DIR/$name"
  printf 'installed %s\n' "$UNITS_DIR/$name"
}

if [ "$PRINT" -eq 1 ]; then
  echo "# firstmate-boot-resume.service"
  render_boot_unit
  echo "# firstmate-watchdog-beat.service"
  render_watchdog_service
  echo "# firstmate-watchdog-beat.timer"
  render_watchdog_timer
  exit 0
fi

render_boot_unit | write_unit firstmate-boot-resume.service
render_watchdog_service | write_unit firstmate-watchdog-beat.service
render_watchdog_timer | write_unit firstmate-watchdog-beat.timer

if [ "$ENABLE" -eq 1 ]; then
  systemctl --user daemon-reload || die "systemctl --user daemon-reload failed"
  systemctl --user enable firstmate-boot-resume.service || die "enabling firstmate-boot-resume.service failed"
  systemctl --user enable --now firstmate-watchdog-beat.timer || die "enabling firstmate-watchdog-beat.timer failed"
  echo "boot resume live: boot unit enabled, watchdog timer active (list: systemctl --user list-timers 'firstmate-*')"
else
  echo "units installed but NOT enabled; enable with:"
  echo "  systemctl --user daemon-reload && systemctl --user enable firstmate-boot-resume.service && systemctl --user enable --now firstmate-watchdog-beat.timer"
fi

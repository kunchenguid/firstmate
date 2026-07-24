#!/usr/bin/env bash
# Install and manage the persistent systemd user service for the captain direct-message listener.
#
# Usage:
#   fm-dm-service.sh install
#   fm-dm-service.sh status
#   fm-dm-service.sh restart
#   fm-dm-service.sh uninstall
#   fm-dm-service.sh print-unit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT_EFFECTIVE="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME_EFFECTIVE="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT_EFFECTIVE}}"
SYSTEMD_DIR=${FM_DM_SYSTEMD_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
SYSTEMCTL=${FM_DM_SYSTEMCTL:-systemctl}
SERVICE_NAME=${FM_DM_SERVICE_NAME:-firstmate-dm.service}
UNIT_FILE="$SYSTEMD_DIR/$SERVICE_NAME"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

unit_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

render_unit() {
  local root home listener
  root=$(unit_escape "$FM_ROOT_EFFECTIVE")
  home=$(unit_escape "$FM_HOME_EFFECTIVE")
  listener=$(unit_escape "$FM_ROOT_EFFECTIVE/bin/fm-dm-listener.sh")
  cat <<EOF
[Unit]
Description=Firstmate session-independent captain direct-message line
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="HOME=$(unit_escape "$HOME")"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="FM_HOME=$home"
Environment="FM_ROOT_OVERRIDE=$root"
EOF
  if [ -n "${FM_DM_DATA_DIR:-}" ]; then
    printf 'Environment="FM_DM_DATA_DIR=%s"\n' "$(unit_escape "$FM_DM_DATA_DIR")"
  fi
  if [ -n "${FM_TOPIC_CONFIG:-}" ]; then
    printf 'Environment="FM_TOPIC_CONFIG=%s"\n' "$(unit_escape "$FM_TOPIC_CONFIG")"
  fi
  if [ -n "${FM_DM_PLUGIN_PID_FILE:-}" ]; then
    printf 'Environment="FM_DM_PLUGIN_PID_FILE=%s"\n' "$(unit_escape "$FM_DM_PLUGIN_PID_FILE")"
  fi
  cat <<EOF
ExecStart="$listener"
Restart=always
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=10
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=default.target
EOF
}

command=${1:-status}
case "$command" in
  install)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    FM_HOME="$FM_HOME_EFFECTIVE" FM_ROOT_OVERRIDE="$FM_ROOT_EFFECTIVE" "$FM_ROOT_EFFECTIVE/bin/fm-dm-listener.sh" --check-config >/dev/null
    mkdir -p "$SYSTEMD_DIR"
    render_unit | {
      umask 077
      tmp=$(mktemp "$SYSTEMD_DIR/.${SERVICE_NAME}.tmp.XXXXXX")
      cat > "$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "$UNIT_FILE"
    }
    "$SYSTEMCTL" --user daemon-reload
    "$SYSTEMCTL" --user enable --now "$SERVICE_NAME"
    printf 'ok: installed and started %s\n' "$SERVICE_NAME"
    ;;
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    "$SYSTEMCTL" --user status "$SERVICE_NAME" --no-pager
    ;;
  restart)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    "$SYSTEMCTL" --user restart "$SERVICE_NAME"
    "$SYSTEMCTL" --user status "$SERVICE_NAME" --no-pager
    ;;
  uninstall)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    "$SYSTEMCTL" --user disable --now "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$UNIT_FILE"
    "$SYSTEMCTL" --user daemon-reload
    printf 'ok: removed %s; direct-message data and credentials were preserved\n' "$SERVICE_NAME"
    ;;
  print-unit)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    render_unit
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac

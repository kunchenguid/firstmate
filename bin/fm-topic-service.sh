#!/usr/bin/env bash
# Install and manage the persistent systemd user service for the Telegram topic-board listener.
#
# Usage:
#   fm-topic-service.sh install
#   fm-topic-service.sh status
#   fm-topic-service.sh restart
#   fm-topic-service.sh uninstall
#   fm-topic-service.sh print-unit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT_EFFECTIVE="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME_EFFECTIVE="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT_EFFECTIVE}}"
SYSTEMD_DIR=${FM_TOPIC_SYSTEMD_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
SYSTEMCTL=${FM_TOPIC_SYSTEMCTL:-systemctl}
SERVICE_NAME=${FM_TOPIC_SERVICE_NAME:-firstmate-topic-board.service}
UNIT_FILE="$SYSTEMD_DIR/$SERVICE_NAME"
LEGACY_CHECK="$FM_HOME_EFFECTIVE/state/topic-watch.check.sh"

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
  listener=$(unit_escape "$FM_ROOT_EFFECTIVE/bin/fm-topic-listener.sh")
  cat <<EOF
[Unit]
Description=Firstmate real-time Telegram topic board
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
  if [ -n "${FM_TOPIC_DATA_DIR:-}" ]; then
    printf 'Environment="FM_TOPIC_DATA_DIR=%s"\n' "$(unit_escape "$FM_TOPIC_DATA_DIR")"
  fi
  if [ -n "${FM_TOPIC_CONFIG:-}" ]; then
    printf 'Environment="FM_TOPIC_CONFIG=%s"\n' "$(unit_escape "$FM_TOPIC_CONFIG")"
  fi
  if [ -n "${FM_TOPIC_MAP:-}" ]; then
    printf 'Environment="FM_TOPIC_MAP=%s"\n' "$(unit_escape "$FM_TOPIC_MAP")"
  fi
  if [ -n "${FM_TOPIC_LIFELINE_CONFIG:-}" ]; then
    printf 'Environment="FM_TOPIC_LIFELINE_CONFIG=%s"\n' "$(unit_escape "$FM_TOPIC_LIFELINE_CONFIG")"
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
    [ ! -e "$LEGACY_CHECK" ] || {
      printf 'error: legacy watcher poll still exists at %s\n' "$LEGACY_CHECK" >&2
      printf 'Disable that prototype poller before installation so two getUpdates consumers cannot race on the topic-bot token.\n' >&2
      exit 1
    }
    FM_HOME="$FM_HOME_EFFECTIVE" FM_ROOT_OVERRIDE="$FM_ROOT_EFFECTIVE" "$FM_ROOT_EFFECTIVE/bin/fm-topic-listener.sh" --check-config >/dev/null
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
    printf 'ok: removed %s; topic data and credentials were preserved\n' "$SERVICE_NAME"
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

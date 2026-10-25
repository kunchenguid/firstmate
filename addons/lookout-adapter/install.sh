#!/usr/bin/env bash
# install.sh [--dry-run] [--rollback]: replace the old fleet dashboard (fm-dashboard.service) with Lookout on its address.
#   (default)    start the new unit's command on a spare port, check it with curl, then swap: stop the old unit and start the new
#                one on the old address. The old unit's files are never edited, so the swap is undone by --rollback.
#   --dry-run    print every step and the unit; change nothing.
#   --rollback   stop and remove the new unit, start the old one again (with --dry-run: print only).
# Settings (environment): LOOKOUT_DIR (required: the lookout clone, until lookout-axi is published), FM_HOME (default ~/firstmate),
# PORT (the old dashboard's port, default 4390), BIND (default: this host's tailnet address), SPARE_PORT (default 4395).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mode=apply dry=no
for arg in "$@"; do case $arg in --dry-run) dry=yes ;; --rollback) mode=rollback ;; *) echo "usage: install.sh [--dry-run] [--rollback]" >&2; exit 2 ;; esac; done
[ "$dry" = no ] || { [ "$mode" = rollback ] && mode=rollback-dry || mode=dry; }
FM_HOME=${FM_HOME:-$HOME/firstmate} PORT=${PORT:-4390} SPARE_PORT=${SPARE_PORT:-4395}
OLD=fm-dashboard.service NEW=fm-dashboard-lookout.service
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
BIND=${BIND:-$(tailscale ip -4 | head -1)}
run() { echo "+ $*"; case $mode in *dry) ;; *) "$@" ;; esac; }
unit() {
  cat <<U
[Unit]
Description=Firstmate fleet dashboard: Lookout on the adapter (tailnet only)
After=tailscaled.service network-online.target

[Service]
Environment=FM_HOME=$FM_HOME LOOKOUT_DIR=$LOOKOUT_DIR PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$here/fleet-serve --bind $BIND --port $PORT
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=default.target
U
}

if [ "$mode" = rollback ] || [ "$mode" = rollback-dry ]; then
  run systemctl --user disable --now "$NEW"
  run rm -f -- "$unit_dir/$NEW"
  run systemctl --user daemon-reload
  run systemctl --user enable --now "$OLD"
  exit 0
fi
: "${LOOKOUT_DIR:?set LOOKOUT_DIR to the lookout clone}"
[ -f "$LOOKOUT_DIR/bin/lookout.js" ] || { echo "install: $LOOKOUT_DIR has no bin/lookout.js" >&2; exit 1; }
echo "== unit $unit_dir/$NEW"; unit
echo "== 1. spare port: the unit's own command on $BIND:$SPARE_PORT, checked before anything is stopped"
probe=fm-dashboard-lookout-probe
run systemd-run --user --collect --unit "$probe" --setenv=FM_HOME="$FM_HOME" --setenv=LOOKOUT_DIR="$LOOKOUT_DIR" "$here/fleet-serve" --bind "$BIND" --port "$SPARE_PORT"
if [ "$mode" = apply ]; then
  trap 'systemctl --user stop "$probe" 2>/dev/null || true' EXIT
  for _ in $(seq 100); do curl -fs "http://$BIND:$SPARE_PORT/api/fleet" -o /dev/null && break; sleep 0.3; done
  curl -fs "http://$BIND:$SPARE_PORT/api/fleet" | python3 -c 'import json, sys; d = json.load(sys.stdin); assert d["fleet"]["lanes"], "no lanes"' || { echo "install: the spare port does not serve the fleet; nothing was changed" >&2; exit 1; }
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$BIND:$SPARE_PORT/tickets")" = 301 ] || { echo "install: /tickets does not redirect to sign-off; nothing was changed" >&2; exit 1; }
  systemctl --user stop "$probe"; trap - EXIT
else
  echo "+ curl http://$BIND:$SPARE_PORT/api/fleet (must list lanes) and /tickets (must answer 301), then stop $probe"
fi
echo "== 2. swap"
if [ "$mode" = apply ]; then mkdir -p "$unit_dir"; unit > "$unit_dir/$NEW"; else echo "+ write $unit_dir/$NEW"; fi
run systemctl --user daemon-reload
run systemctl --user disable --now "$OLD"
run systemctl --user enable --now "$NEW"
echo "== rollback: $here/install.sh --rollback"

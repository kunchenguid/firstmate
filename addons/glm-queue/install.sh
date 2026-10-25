#!/usr/bin/env bash
# Install glm-queue.mjs as the systemd user service fm-glm-queue: one local queue on 127.0.0.1 in front of Z.AI.
# Copies the proxy to ${XDG_DATA_HOME:-~/.local/share}/fm-glm-queue/, writes ~/.config/systemd/user/fm-glm-queue.service,
# and enables and (re)starts it only when either file changed. Pointing pi at it is a separate config step (README).
# Usage: install.sh [--dry-run] [--max N] [--port P]   (defaults 8 in flight, port 8787; --dry-run writes nothing)
set -euo pipefail
DRY=0 MAX=8 PORT=8787
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --max) MAX=${2:?--max needs a number}; shift ;;
    --port) PORT=${2:?--port needs a number}; shift ;;
    *) echo "usage: install.sh [--dry-run] [--max N] [--port P]" >&2; exit 2 ;;
  esac
  shift
done
case $MAX in *[!0-9]*|0) echo "install.sh: --max needs a positive integer, got '$MAX'" >&2; exit 2 ;; esac
NODE=$(command -v node) || { echo "install.sh: node not found on PATH" >&2; exit 1; }
SRC=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/glm-queue.mjs
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-glm-queue/glm-queue.mjs
UNIT=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fm-glm-queue.service
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/unit" <<EOF
[Unit]
Description=Firstmate GLM call queue (at most $MAX Z.AI calls in flight, 127.0.0.1:$PORT)

[Service]
Environment=GLM_QUEUE_MAX=$MAX GLM_QUEUE_PORT=$PORT
ExecStart=$NODE $DEST
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

changed=0
cmp -s "$SRC" "$DEST" || { echo "$DEST: install from $SRC"; changed=1; }
cmp -s "$TMP/unit" "$UNIT" || { echo "$UNIT:"; diff "$UNIT" "$TMP/unit" 2>/dev/null || sed 's/^/  /' "$TMP/unit"; changed=1; }
[ "$changed" -eq 1 ] || { echo "unchanged: $UNIT"; exit 0; }
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written"; exit 0; }
install -D -m 755 "$SRC" "$DEST"
install -D -m 644 "$TMP/unit" "$UNIT"
systemctl --user daemon-reload
systemctl --user enable fm-glm-queue.service
systemctl --user restart fm-glm-queue.service
echo "written and restarted: fm-glm-queue.service"

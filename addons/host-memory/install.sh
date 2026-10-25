#!/usr/bin/env bash
# Install or update the memory gate for this user. Idempotent. Usage: install.sh [--dry-run]
# Main's config/fm-mem-gate.sh becomes a shim that execs the installed copy; this script never writes it.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/bin/fm-mem-gate.sh
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-host-memory/fm-mem-gate.sh
ADOPT_SRC=${SRC%/*}/fm-heavy-adopt.sh
ADOPT_DEST=${DEST%/*}/fm-heavy-adopt.sh
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
SERVICE=$CONFIG/fm-heavy-adopt.service
TIMER=$CONFIG/fm-heavy-adopt.timer
if cmp -s "$SRC" "$DEST"; then echo "unchanged: $DEST"
elif [ "$DRY" -eq 1 ]; then echo "would copy: $SRC -> $DEST"
else mkdir -p "${DEST%/*}"; install -m 755 "$SRC" "$DEST"; echo "copied: $SRC -> $DEST"
fi
if [ -f "$ADOPT_SRC" ] && cmp -s "$ADOPT_SRC" "$ADOPT_DEST"; then echo "unchanged: $ADOPT_DEST"
elif [ "$DRY" -eq 1 ]; then echo "would copy: $ADOPT_SRC -> $ADOPT_DEST"
else mkdir -p "${ADOPT_DEST%/*}"; install -m 755 "$ADOPT_SRC" "$ADOPT_DEST"; echo "copied: $ADOPT_SRC -> $ADOPT_DEST"; fi
[ "$DRY" -eq 1 ] || mkdir -p "$CONFIG"
service_content="[Unit]
Description=Move heavy and CPU-intensive pane jobs out of Herdr
[Service]
Type=oneshot
ExecStart=$ADOPT_DEST"
timer_content='[Unit]
Description=Run fm-heavy-adopt every 20 s
[Timer]
OnBootSec=30
OnUnitActiveSec=20
AccuracySec=2
[Install]
WantedBy=timers.target'
for pair in "$SERVICE|$service_content" "$TIMER|$timer_content"; do
  f=${pair%%|*}; content=${pair#*|}
  if [ -f "$f" ] && cmp -s "$f" <(printf '%s\n' "$content"); then echo "unchanged: $f"
  elif [ "$DRY" -eq 1 ]; then echo "would write: $f"
  else printf '%s\n' "$content" >"$f"; echo "wrote: $f"; fi
done
for f in "$CONFIG/fm.slice.d/50-fm-heavy-weight.conf" "$CONFIG/fm-heavy.slice.d/50-fm-heavy-weight.conf"; do
  if [ -f "$f" ] && cmp -s "$f" <(printf '[Slice]\nCPUWeight=20\nIOWeight=20\n'); then echo "unchanged: $f"
  elif [ "$DRY" -eq 1 ]; then echo "would write: $f"
  else mkdir -p "${f%/*}"; printf '[Slice]\nCPUWeight=20\nIOWeight=20\n' >"$f"; echo "wrote: $f"; fi
done
if [ "$DRY" -eq 0 ]; then
  systemctl --user daemon-reload || { echo 'host-memory: systemctl --user daemon-reload failed' >&2; exit 1; }
  systemctl --user enable --now fm-heavy-adopt.timer || { echo 'host-memory: failed to enable fm-heavy-adopt.timer' >&2; exit 1; }
else echo 'dry run: nothing written'; fi

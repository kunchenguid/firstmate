#!/usr/bin/env bash
# Remove the Codex adapter: the block install.sh appended to Codex's config.toml, then bash-env.sh. The guards stay.
# Usage: uninstall.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: uninstall.sh [--dry-run]" >&2; exit 2; }
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
CONF=${CODEX_HOME:-$HOME/.codex}/config.toml
BLOCK=$(printf '\n# fm-codex-guard: fleet guards before every Codex shell command (firstmate-addons codex-guard)\n[shell_environment_policy.set]\nBASH_ENV = "%s"' "$DATA/fm-codex-guard/bash-env.sh")
if [ -f "$CONF" ] && grep -qF 'fm-codex-guard' "$CONF"; then
  python3 -c '
import sys, tomllib
conf, block = sys.argv[1], sys.argv[2] + "\n"
text = open(conf).read()
if text.count(block) != 1: sys.exit(f"refused: the fm-codex-guard block in {conf} was edited; remove it by hand")
tomllib.loads(text.replace(block, ""))
open(conf + ".tmp", "w").write(text.replace(block, ""))' "$CONF" "$BLOCK"
  echo "remove from $CONF:$BLOCK"
  if [ "$DRY" -eq 1 ]; then rm -f -- "$CONF.tmp"; else chmod --reference="$CONF" "$CONF.tmp" && cp -p "$CONF" "$CONF.bak-codex-guard-$(date +%s)" && mv "$CONF.tmp" "$CONF"; fi
fi
[ ! -e "$DATA/fm-codex-guard/bash-env.sh" ] || { echo "remove: $DATA/fm-codex-guard/bash-env.sh"; [ "$DRY" -eq 1 ] || rm -f -- "$DATA/fm-codex-guard/bash-env.sh"; }
[ "$DRY" -eq 1 ] || rmdir "$DATA/fm-codex-guard" 2>/dev/null || true

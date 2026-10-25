#!/usr/bin/env bash
# Install or update the Codex adapter for the fleet guards. Codex crewmates start with hooks off, so no hook reaches them;
# Codex's own shell_environment_policy instead sets BASH_ENV to bash-env.sh, which runs every installed delete, kill and
# read guard before each agent command. Idempotent. Usage: install.sh [--dry-run]
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 0 ] || { echo "usage: install.sh [--dry-run]" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-codex-guard
CONF=${CODEX_HOME:-$HOME/.codex}/config.toml
BLOCK=$(printf '\n# fm-codex-guard: fleet guards before every Codex shell command (firstmate-addons codex-guard)\n[shell_environment_policy.set]\nBASH_ENV = "%s"' "$DEST/bash-env.sh")
TMP=$(mktemp -d); trap 'rm -rf -- "$TMP"' EXIT
[ -d "$(dirname "$CONF")" ] || { echo "skipped: codex (not installed)"; exit 0; }

conf=append
if [ -f "$CONF" ] && grep -qxF "${BLOCK##*$'\n'}" "$CONF"; then conf=unchanged
elif [ -f "$CONF" ] && grep -q 'shell_environment_policy\|BASH_ENV' "$CONF"; then
  echo "refused: $CONF already configures shell_environment_policy; add ${BLOCK##*$'\n'} under its [shell_environment_policy.set] by hand" >&2; exit 1
else
  { [ ! -f "$CONF" ] || cat "$CONF"; printf '%s\n' "$BLOCK"; } > "$TMP/config.toml"
  # Codex refuses to start on a config it cannot parse, so the candidate must parse and carry the setting before it lands.
  python3 -c 'import sys, tomllib; c = tomllib.load(open(sys.argv[1], "rb")); assert c["shell_environment_policy"]["set"]["BASH_ENV"] == sys.argv[2]' \
    "$TMP/config.toml" "$DEST/bash-env.sh" || { echo "refused: $CONF would not parse with the guard block added" >&2; exit 1; }
fi

sed "s|__DATA__|${DEST%/*}|g" "$SRC/bash-env.sh" > "$TMP/bash-env.sh"
if [ -e "$DEST/bash-env.sh" ] && cmp -s "$DEST/bash-env.sh" "$TMP/bash-env.sh"; then echo "unchanged: $DEST/bash-env.sh"
elif [ "$DRY" -eq 1 ]; then echo "would write: $DEST/bash-env.sh"
else mkdir -p "$DEST" && cp "$TMP/bash-env.sh" "$DEST/bash-env.sh.tmp" && mv "$DEST/bash-env.sh.tmp" "$DEST/bash-env.sh"; fi

if [ "$conf" = unchanged ]; then echo "unchanged: $CONF"; exit 0; fi
echo "append to $CONF:$BLOCK"
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written"; exit 0; }
[ ! -f "$CONF" ] || cp -p "$CONF" "$CONF.bak-codex-guard-$(date +%s)"
# Append, never rewrite: Codex saves folder trust into the same file while workers launch.
printf '%s\n' "$BLOCK" >> "$CONF"

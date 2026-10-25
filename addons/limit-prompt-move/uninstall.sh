#!/usr/bin/env bash
# Retire the limit-prompt-move check from one firstmate home (its check and trust binding); with --all, from every
# active home install.sh --all reaches, and then remove the installed copy. Idempotent.
# Usage: uninstall.sh [--all] <fm-home>
set -euo pipefail
ALL=
[ "${1:-}" = --all ] && { ALL=--all; shift; }
[ "$#" -eq 1 ] && [ -d "$1/state" ] || { echo "usage: uninstall.sh [--all] <fm-home>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-limit-prompt-move
while IFS=$'\t' read -r name home; do
  [ -x "$home/bin/fm-check-unregister.sh" ] || { echo "skipped: $name: $home has no bin/fm-check-unregister.sh" >&2; continue; }
  env -u FM_STATE_OVERRIDE FM_HOME="$home" "$home/bin/fm-check-unregister.sh" limit-prompt-move >/dev/null
  echo "uninstalled: $name: limit-prompt-move from $home"
done < <("$SRC/install.sh" ${ALL:+--all} --list "$1")
[ -z "$ALL" ] || {
  rm -f -- "$DEST/limit-prompt-move/limit-prompt-move" "$DEST/limit-prompt-move/check.sh" "$DEST/parked-homes/bin/fm-parked-homes-lib.sh"
  rmdir -- "$DEST/limit-prompt-move" "$DEST/parked-homes/bin" "$DEST/parked-homes" "$DEST" 2>/dev/null || true
}

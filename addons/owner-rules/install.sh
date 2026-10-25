#!/usr/bin/env bash
# Turn on the owner rules in one firstmate home: write config/owner-rules, which brief-inherit's
# brief seam reads, and make config/merge-gate run bin/fm-owner-rules-gate.sh first, then the home's
# previous gate (moved aside to config/merge-gate.pre-owner-rules; uninstall moves it back). Idempotent.
# Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -d "$1/config" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
f=$(cd "$1" && pwd -P)/config/owner-rules
MG=${f%owner-rules}merge-gate PREV=$MG.pre-owner-rules MARK='# fm-owner-rules merge gate'
if [ "$DRY" -eq 1 ]; then echo "would write: $f"; echo "would write: $MG (owner-rules gate, then the previous gate)"; echo "dry run: nothing written"; exit 0; fi
printf '%s\n' 'owner-rules add-on installed: brief-inherit runs owner-rules/bin/fm-owner-rules-lib.sh at brief creation; config/merge-gate runs owner-rules/bin/fm-owner-rules-gate.sh' > "$f"
if [ -e "$MG" ] || [ -L "$MG" ]; then
  if grep -qxF "$MARK" "$MG" 2>/dev/null; then :
  elif [ -e "$PREV" ] || [ -L "$PREV" ]; then echo "error: $MG is not ours and $PREV exists; move one aside and rerun" >&2; exit 1
  else mv "$MG" "$PREV"; fi
fi
{
  printf '#!/usr/bin/env bash\n%s\n' "$MARK"
  printf '%q "$@" || exit $?\nprev=%q\n' "$SRC/bin/fm-owner-rules-gate.sh" "$PREV"
  cat <<'GATE'
[ -e "$prev" ] || [ -L "$prev" ] || exit 0
[ -x "$prev" ] || { echo "merge refused: $prev is not executable"; exit 1; }
exec "$prev" "$@"
GATE
} > "$MG.tmp"
chmod 755 "$MG.tmp" && mv "$MG.tmp" "$MG"

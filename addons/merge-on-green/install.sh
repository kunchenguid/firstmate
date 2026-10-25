#!/usr/bin/env bash
# Install or update the merge-on-green watcher check in one firstmate home. Idempotent.
# Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/fm-check-register.sh" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-merge-on-green
ID=merge-on-green
SHIM=$(printf '#!/usr/bin/env bash\nexec %q check %q\n' "$DEST/merge-on-green.sh" "$FMH")

run() {
  if [ "$DRY" -eq 1 ]; then echo "would run: $*"; else "$@"; fi
}

if [ "$DRY" -eq 1 ]; then
  echo "would copy: $SRC/merge-on-green.sh -> $DEST/merge-on-green.sh"
  echo "would copy: $SRC/checks-lint.sh -> $DEST/checks-lint.sh"
  echo "would copy: $SRC/fm-checks-lint.sh -> $DEST/fm-checks-lint.sh"
  echo "would copy: $SRC/.done-done.yaml -> $DEST/.done-done.yaml"
  echo "would write: $FMH/state/$ID.check.sh:"
  printf '%s\n' "$SHIM" | sed 's/^/  /'
else
  mkdir -p "$DEST"
  install -m 755 "$SRC/merge-on-green.sh" "$DEST/merge-on-green.sh"
  install -m 755 "$SRC/checks-lint.sh" "$DEST/checks-lint.sh"
  install -m 755 "$SRC/fm-checks-lint.sh" "$DEST/fm-checks-lint.sh"
  install -m 644 "$SRC/.done-done.yaml" "$DEST/.done-done.yaml"
  printf '%s\n' "$SHIM" > "$FMH/state/$ID.check.sh"
  chmod 700 "$FMH/state/$ID.check.sh"
fi
# An FM_STATE_OVERRIDE in the caller env, even empty, would redirect the register away from FMH/state.
run env -u FM_STATE_OVERRIDE FM_HOME="$FMH" "$FMH/bin/fm-check-register.sh" "$ID"
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"

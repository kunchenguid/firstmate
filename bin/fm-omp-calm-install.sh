#!/usr/bin/env bash
# Link the tracked Calm OMP extension package into OMP's user plugin scope so
# /calm-omp and the working boat load in every omp session, not only sessions
# launched inside this checkout.
# Usage: fm-omp-calm-install.sh
# The package lives at extensions/fm-calm-omp/ and loads through
# `omp plugin link`; edits to the tracked source take effect on the next omp
# session start because the link resolves to this checkout.
# A legacy project-local copy at <home>/.omp/extensions/fm-calm-omp.ts would
# load a second time in home sessions (OMP de-duplicates by absolute path, not
# realpath), so an identical legacy copy is removed and a divergent one is
# renamed to .bak with a warning.
# Uninstall with `omp plugin uninstall fm-calm-omp`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

PKG_DIR="$FM_ROOT/extensions/fm-calm-omp"
LEGACY="$FM_HOME/.omp/extensions/fm-calm-omp.ts"

command -v omp >/dev/null 2>&1 || { echo "error: omp is not on PATH" >&2; exit 1; }
[ -f "$PKG_DIR/package.json" ] || { echo "error: $PKG_DIR/package.json is missing" >&2; exit 1; }
[ -f "$PKG_DIR/fm-calm-omp.ts" ] || { echo "error: $PKG_DIR/fm-calm-omp.ts is missing" >&2; exit 1; }

if [ -f "$LEGACY" ] || [ -L "$LEGACY" ]; then
  if [ -f "$LEGACY" ] && cmp -s "$LEGACY" "$PKG_DIR/fm-calm-omp.ts"; then
    rm -f -- "$LEGACY" || { echo "error: failed to remove $LEGACY" >&2; exit 1; }
    echo "removed identical project-local copy: $LEGACY"
  else
    mv -- "$LEGACY" "$LEGACY.bak" || { echo "error: failed to move $LEGACY to $LEGACY.bak" >&2; exit 1; }
    echo "warning: divergent project-local copy moved to $LEGACY.bak" >&2
  fi
fi

omp plugin link "$PKG_DIR" || { echo "error: omp plugin link failed" >&2; exit 1; }
echo "installed: fm-calm-omp loads in every omp session (linked to $PKG_DIR)"

# A link into a disposable worktree dangles once the worktree is removed.
if git -C "$FM_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  && [ "$(git -C "$FM_ROOT" rev-parse --git-dir)" != "$(git -C "$FM_ROOT" rev-parse --git-common-dir)" ]; then
  echo "warning: linked to a git worktree; re-run from the primary checkout after it lands" >&2
fi

#!/usr/bin/env bash
# Install the standalone Calm OMP plugin into OMP's user plugin scope so /calm-omp
# and the working boat load in every omp session, not only sessions launched inside
# a firstmate checkout.
# Usage: fm-omp-calm-install.sh
# Sources are copied from extensions/fm-calm-omp/ into ~/.local/share/fm-calm-omp
# (override with FM_CALM_OMP_DIR), then linked with `omp plugin link`.
# Re-run after updating firstmate to refresh the standalone copy.
# A legacy project-local copy at <home>/.omp/extensions/fm-calm-omp.ts would load a
# second time in home sessions (OMP de-duplicates by absolute path, not realpath), so
# an identical legacy copy is removed and a divergent one is renamed to .bak.
# Unload with `omp plugin disable fm-calm-omp`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

PKG_DIR="$FM_ROOT/extensions/fm-calm-omp"
INSTALL_DIR="${FM_CALM_OMP_DIR:-$HOME/.local/share/fm-calm-omp}"
LEGACY="$FM_HOME/.omp/extensions/fm-calm-omp.ts"

command -v omp >/dev/null 2>&1 || { echo "error: omp is not on PATH" >&2; exit 1; }
[ -f "$PKG_DIR/package.json" ] || { echo "error: $PKG_DIR/package.json is missing" >&2; exit 1; }
[ -f "$PKG_DIR/fm-calm-omp.ts" ] || { echo "error: $PKG_DIR/fm-calm-omp.ts is missing" >&2; exit 1; }
[ -f "$PKG_DIR/lib/fm-calm-working-ship.ts" ] || {
  echo "error: $PKG_DIR/lib/fm-calm-working-ship.ts is missing" >&2
  exit 1
}

if [ -f "$LEGACY" ] || [ -L "$LEGACY" ]; then
  if [ -f "$LEGACY" ] && cmp -s "$LEGACY" "$PKG_DIR/fm-calm-omp.ts"; then
    rm -f -- "$LEGACY" || { echo "error: failed to remove $LEGACY" >&2; exit 1; }
    echo "removed identical project-local copy: $LEGACY"
  else
    mv -- "$LEGACY" "$LEGACY.bak" || { echo "error: failed to move $LEGACY to $LEGACY.bak" >&2; exit 1; }
    echo "warning: divergent project-local copy moved to $LEGACY.bak" >&2
  fi
fi

mkdir -p "$INSTALL_DIR" || { echo "error: failed to create $INSTALL_DIR" >&2; exit 1; }
cp -R "$PKG_DIR/." "$INSTALL_DIR/" || { echo "error: copy to $INSTALL_DIR failed" >&2; exit 1; }

omp plugin link "$INSTALL_DIR" || { echo "error: omp plugin link failed" >&2; exit 1; }
echo "installed: fm-calm-omp loads in every omp session (standalone copy at $INSTALL_DIR)"

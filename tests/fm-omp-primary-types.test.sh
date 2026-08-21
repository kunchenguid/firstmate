#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate omp (Oh My Pi)
# extensions. Mirrors tests/fm-pi-primary-types.test.sh, but resolves the omp
# package (@oh-my-pi/pi-coding-agent, installed globally by bun) and its
# sibling @oh-my-pi/pi-tui, plus @types/node from the same global root.
# typebox is NOT required: the omp extensions import only pi-tui's public
# component surface and pi-coding-agent's ExtensionAPI/Theme types, and
# skipLibCheck suppresses pi-tui's internal typebox references.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for omp extension typecheck"; exit 0; }

resolve_omp_package_dir() {
  # 1. explicit override
  if [ -n "${FM_OMP_PACKAGE_DIR:-}" ] && [ -f "${FM_OMP_PACKAGE_DIR}/package.json" ]; then
    echo "$FM_OMP_PACKAGE_DIR"; return
  fi
  # 2. npm global root
  local npm_dir
  npm_dir="$(npm root -g 2>/dev/null)/@oh-my-pi/pi-coding-agent"
  if [ -f "$npm_dir/package.json" ]; then echo "$npm_dir"; return; fi
  # 3. resolve from the `omp` binary symlink (bun global install)
  local omp_bin
  omp_bin="$(command -v omp 2>/dev/null || true)"
  if [ -n "$omp_bin" ]; then
    local cli real
    # Follow the symlink chain (portable: node realpath).
    cli="$(node -e "console.log(require('fs').realpathSync(process.argv[1]))" "$omp_bin" 2>/dev/null || true)"
    if [ -n "$cli" ]; then
      # .../node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js -> package dir
      real="$(cd "$(dirname "$(dirname "$cli")")" && pwd)"
      if [ -f "$real/package.json" ]; then echo "$real"; return; fi
    fi
  fi
  echo ""
}

OMP_PACKAGE_DIR=$(resolve_omp_package_dir)
if [ -z "$OMP_PACKAGE_DIR" ] || [ ! -f "$OMP_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @oh-my-pi/pi-coding-agent package not found"
  exit 0
fi

# Global node_modules root: sibling scope that holds @oh-my-pi/pi-tui and @types/node.
GMOD="$(cd "$(dirname "$(dirname "$OMP_PACKAGE_DIR")")" && pwd)"
if [ ! -d "$GMOD/@oh-my-pi/pi-tui" ] || [ ! -d "$GMOD/@types/node" ]; then
  echo "not ok - global root missing @oh-my-pi/pi-tui or @types/node" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/lib" "$TMP_ROOT/node_modules/@oh-my-pi" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-primary-omp-watch.ts" "$TMP_ROOT/fm-primary-omp-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-omp-turnend-guard.ts" "$TMP_ROOT/fm-primary-omp-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility-omp.ts" "$TMP_ROOT/lib/fm-calm-visibility-omp.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"
ln -s "$OMP_PACKAGE_DIR" "$TMP_ROOT/node_modules/@oh-my-pi/pi-coding-agent"
ln -s "$GMOD/@oh-my-pi/pi-tui" "$TMP_ROOT/node_modules/@oh-my-pi/pi-tui"
ln -s "$GMOD/@types/node" "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["*.ts", "lib/*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$OMP_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked omp extensions pass strict no-emit typecheck against omp %s\n' "$version"

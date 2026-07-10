#!/usr/bin/env bash
# Strict no-emit contract check for both tracked OMP primary extensions.
# Mirrors tests/fm-pi-primary-types.test.sh. OMP (Oh My Pi) is a Pi fork; the
# extensions import their types from @oh-my-pi/pi-coding-agent. OMP does not
# bundle @types/node, so this test sources Node declarations from the global npm
# root and SKIPS cleanly when the OMP package or Node declarations are not
# resolvable (e.g. on CI, where OMP is not installed) - the same skip-if-absent
# philosophy as the Pi test. Set FM_OMP_PACKAGE_DIR / FM_NODE_TYPES_DIR to point
# at non-global locations.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for OMP extension typecheck"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for OMP extension typecheck"; exit 0; }

OMP_PACKAGE_DIR=${FM_OMP_PACKAGE_DIR:-"$(npm root -g)/@oh-my-pi/pi-coding-agent"}
if [ ! -f "$OMP_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @oh-my-pi/pi-coding-agent package not found"
  exit 0
fi

NODE_TYPES_DIR=${FM_NODE_TYPES_DIR:-"$(npm root -g)/@types/node"}
if [ ! -d "$NODE_TYPES_DIR" ]; then
  echo "skip: @types/node declarations not found (OMP does not bundle them; set FM_NODE_TYPES_DIR)"
  exit 0
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/node_modules/@oh-my-pi" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$TMP_ROOT/fm-primary-omp-watch.ts"
cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
ln -s "$OMP_PACKAGE_DIR" "$TMP_ROOT/node_modules/@oh-my-pi/pi-coding-agent"
ln -s "$NODE_TYPES_DIR" "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
# ES2024 lib: the OMP extensions use Promise.withResolvers (this repo's TS lint
# requires it over new Promise(executor)), which is an ES2024 API.
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "lib": ["ES2024"],
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2024",
    "types": ["node"]
  },
  "include": ["*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json"
version=$(jq -r '.version' "$OMP_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - OMP primary extensions pass strict no-emit typecheck against OMP %s\n' "$version"

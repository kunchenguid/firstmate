#!/usr/bin/env bash
# Strict no-emit contract check for both tracked Pi primary extensions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi extension typecheck"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for Pi extension typecheck"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi
if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] || [ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ]; then
  echo "not ok - installed Pi package is missing typebox or Node declarations" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TMP_ROOT/node_modules/@types/node"

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
  "include": ["*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig.json"
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - Pi primary extensions pass strict no-emit typecheck against Pi %s\n' "$version"

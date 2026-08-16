#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate Pi extensions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || {
	echo "skip: npm not found for Pi extension typecheck"
	exit 0
}
HAS_TSC=1
command -v tsc >/dev/null 2>&1 || HAS_TSC=0

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
	echo "skip: installed @earendil-works/pi-coding-agent package not found"
	exit 0
fi
if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] ||
	[ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] ||
	[ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ]; then
	echo "not ok - installed Pi package is missing pi-tui, typebox, or Node declarations" >&2
	exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
	rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/lib" "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$TMP_ROOT/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-host-activator.ts" "$TMP_ROOT/lib/fm-host-activator.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$TMP_ROOT/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$TMP_ROOT/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$TMP_ROOT/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/marked" "$TMP_ROOT/node_modules/marked"
ln -s "$PI_PACKAGE_DIR/node_modules/get-east-asian-width" "$TMP_ROOT/node_modules/get-east-asian-width"
ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TMP_ROOT/node_modules/@types/node"

cat >"$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat >"$TMP_ROOT/tsconfig.json" <<'JSON'
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

if [ "$HAS_TSC" -eq 1 ]; then
  tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
else
  echo "skip: tsc not found for Pi extension typecheck"
fi
FM_TARGET_WORKTREE="$ROOT" EXT="$TMP_ROOT/fm-primary-pi-watch.ts" \
  node --input-type=module <<'JS' || exit 1
import { pathToFileURL } from "node:url";

const registrations = [];
const pi = {
  events: { on: (...args) => registrations.push(["events", ...args]) },
  on: (...args) => registrations.push(["on", ...args]),
  registerCommand: (...args) => registrations.push(["command", ...args]),
  registerTool: (...args) => registrations.push(["tool", ...args]),
};
const extension = await import(`${pathToFileURL(process.env.EXT).href}?target-worker=${Date.now()}`);
extension.default(pi);
if (registrations.length !== 0) {
  throw new Error(`target worker activated ${registrations.length} Pi watch registrations`);
}
JS
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
if [ "$HAS_TSC" -eq 1 ]; then
  printf 'ok - tracked Pi extensions typecheck and target workers leave primary watch supervision inert against Pi %s\n' "$version"
else
  printf 'ok - target workers leave primary Pi watch supervision inert against Pi %s\n' "$version"
fi

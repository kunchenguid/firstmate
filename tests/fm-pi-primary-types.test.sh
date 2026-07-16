#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Pi primary watcher extension.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TSC_BIN=${FM_TSC_BIN:-}
if [ -z "$TSC_BIN" ]; then
  TSC_BIN=$(command -v tsc 2>/dev/null || true)
fi
if [ -z "$TSC_BIN" ] || [ ! -x "$TSC_BIN" ]; then
  echo "skip: tsc is unavailable; CI enforces the pinned Pi type contract"
  exit 0
fi

resolve_pi_package() {
  local entry candidate npm_root
  if [ -n "${FM_PI_PACKAGE_DIR:-}" ]; then
    printf '%s\n' "$FM_PI_PACKAGE_DIR"
    return
  fi
  if command -v pi >/dev/null 2>&1; then
    entry=$(realpath "$(command -v pi)" 2>/dev/null || true)
    if [ -n "$entry" ]; then
      candidate=$(cd "$(dirname "$entry")/.." 2>/dev/null && pwd || true)
      if [ -f "$candidate/package.json" ]; then
        printf '%s\n' "$candidate"
        return
      fi
    fi
  fi
  if command -v npm >/dev/null 2>&1; then
    npm_root=$(npm root -g 2>/dev/null || true)
    candidate="$npm_root/@earendil-works/pi-coding-agent"
    if [ -f "$candidate/package.json" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi
  return 1
}

find_node_module() {  # <start-dir> <module-path>
  local cursor=$1 module=$2 parent candidate
  while :; do
    candidate="$cursor/node_modules/$module"
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    parent=$(dirname "$cursor")
    [ "$parent" != "$cursor" ] || return 1
    cursor=$parent
  done
}

PI_PACKAGE_DIR=$(resolve_pi_package) || {
  echo "skip: @earendil-works/pi-coding-agent is unavailable; CI enforces the pinned Pi type contract"
  exit 0
}
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
if [ "$version" != 0.80.6 ]; then
  echo "not ok - Pi 0.80.6 is required for the extension type contract; found $version" >&2
  exit 1
fi
TYPEBOX_DIR=$(find_node_module "$PI_PACKAGE_DIR" typebox) || {
  echo "not ok - typebox declarations were not found from $PI_PACKAGE_DIR" >&2
  exit 1
}
NODE_TYPES_DIR=$(find_node_module "$PI_PACKAGE_DIR" @types/node) || {
  echo "not ok - Node declarations were not found from $PI_PACKAGE_DIR" >&2
  exit 1
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$TYPEBOX_DIR" "$TMP_ROOT/node_modules/typebox"
ln -s "$NODE_TYPES_DIR" "$TMP_ROOT/node_modules/@types/node"

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

if ! "$TSC_BIN" -p "$TMP_ROOT/tsconfig.json"; then
  exit 1
fi
printf 'ok - Pi primary watcher extension passes strict no-emit typecheck against Pi %s\n' "$version"

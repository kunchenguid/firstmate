#!/usr/bin/env bash
# Strict no-emit production-consumer checks against public Pi 1.1.0 and 1.2.0.
# Owns temporary npm dependencies and TypeScript 5.9.3; never uses global tsc
# or FM_PI_PACKAGE_DIR. Compiler-owning lint/CI phases run this check.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in node npm; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "not ok - Pi extension typecheck prerequisite not found: $tool" >&2
    exit 1
  }
done

DEPENDENCY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
trap 'rm -rf "$DEPENDENCY_ROOT"' EXIT

printf 'Pi production-consumer typechecks: npm %s\n' "$(npm --version)"
result=0
for version in 1.1.0 1.2.0; do
TMP_ROOT="$DEPENDENCY_ROOT/sdk-$version"
mkdir -p "$TMP_ROOT/lib"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$TMP_ROOT/fm-branch-supervision.ts"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$TMP_ROOT/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$TMP_ROOT/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$TMP_ROOT/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$TMP_ROOT/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$TMP_ROOT/lib/fm-branch-model-picker.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$TMP_ROOT/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-preservation.ts" "$TMP_ROOT/lib/fm-calm-preservation.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$TMP_ROOT/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-pending-operational-layout.ts" "$TMP_ROOT/lib/fm-calm-pending-operational-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$TMP_ROOT/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts" "$TMP_ROOT/lib/fm-calm-working-ship-sprite.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"
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

# Pin the directly imported Pi packages together rather than allowing npm's
# semver ranges to make the older SDK consumer resolve newer sibling types.
(cd "$TMP_ROOT" && npm install --ignore-scripts --no-audit --no-fund --save-exact \
  "@earendil-works/pi-coding-agent@$version" \
  "@earendil-works/pi-ai@$version" \
  "@earendil-works/pi-tui@$version" \
  typebox@1.3.27 @types/node@22.19.19 typescript@5.9.3)

# Emit real installed versions and npm-verified package integrity before the
# temporary lock/vendor tree is removed; compiler diagnostics stay in CI logs.
node - "$TMP_ROOT" <<'JS'
const { readFileSync } = require("node:fs");
const root = process.argv[2];
const lock = JSON.parse(readFileSync(`${root}/package-lock.json`, "utf8"));
const packages = {};
for (const [name, expected] of Object.entries(lock.packages[""].dependencies)) {
  const entry = lock.packages[`node_modules/${name}`];
  const installed = JSON.parse(readFileSync(`${root}/node_modules/${name}/package.json`, "utf8"));
  if (installed.version !== expected || entry.version !== expected || !entry.integrity) {
    throw new Error(`Unexpected package provenance for ${name}`);
  }
  packages[name] = { version: installed.version, resolved: entry.resolved, integrity: entry.integrity };
}
console.log(JSON.stringify({ node: process.version, platform: process.platform, arch: process.arch, packages }));
JS
"$TMP_ROOT/node_modules/.bin/tsc" --version
if "$TMP_ROOT/node_modules/.bin/tsc" -p "$TMP_ROOT/tsconfig.json"; then
  printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"
else
  printf 'not ok - tracked Pi extensions fail strict no-emit typecheck against Pi %s\n' "$version" >&2
  result=1
fi
done
exit "$result"

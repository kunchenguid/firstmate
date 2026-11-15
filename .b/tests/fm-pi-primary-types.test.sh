#!/usr/bin/env bash
# Strict no-emit production-consumer checks against public Pi 1.1.0 and 1.2.0,
# plus the read guard's real SDK event/abort regression on Linux.
# Owns temporary npm dependencies and TypeScript 5.9.3; never uses global tsc
# or FM_PI_PACKAGE_DIR. Compiler-owning lint/CI phases run this check.
# FM_PI_TYPES_ARTIFACT_DIR optionally retains the verified temporary lockfiles.
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
cp "$ROOT/.pi/extensions/fm-primary-read-repetition.ts" "$TMP_ROOT/fm-primary-read-repetition.ts"
cp "$ROOT/.pi/extensions/lib/fm-primary-read-repetition-policy.ts" "$TMP_ROOT/lib/fm-primary-read-repetition-policy.ts"
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
node - "$TMP_ROOT" "$version" <<'JS'
const { writeFileSync } = require("node:fs");
// Each SDK's packages must stay on its own version. Their public ^ ranges
// otherwise let a 1.1.0 matrix silently exercise the latest 1.x agent core.
const siblings = ["chord", "pi-ai", "pi-mcp", "pi-tui", "pi-codemode", "pi-agent-core", "pi-telemetry"];
writeFileSync(`${process.argv[2]}/package.json`, JSON.stringify({ type: "module",
  overrides: Object.fromEntries(siblings.map((name) => [`@earendil-works/${name}`, process.argv[3]])),
}));
JS
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
node - "$TMP_ROOT" "$version" <<'JS'
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
for (const [path, entry] of Object.entries(lock.packages)) {
  if (/node_modules\/@earendil-works\//.test(path) && entry.version !== process.argv[3]) {
    throw new Error(`Mixed SDK matrix: ${path} resolved ${entry.version}, expected ${process.argv[3]}`);
  }
}
console.log(JSON.stringify({ node: process.version, platform: process.platform, arch: process.arch, packages,
  lifecycleScriptsDisabled: true,
  packagesWithInstallScripts: Object.entries(lock.packages).filter(([, entry]) => entry.hasInstallScript).map(([path]) => path),
}));
JS
if [ -n "${FM_PI_TYPES_ARTIFACT_DIR:-}" ]; then
  mkdir -p "$FM_PI_TYPES_ARTIFACT_DIR"
  cp "$TMP_ROOT/package-lock.json" "$FM_PI_TYPES_ARTIFACT_DIR/pi-$version-package-lock.json"
fi
"$TMP_ROOT/node_modules/.bin/tsc" --version
if "$TMP_ROOT/node_modules/.bin/tsc" -p "$TMP_ROOT/tsconfig.json"; then
  printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"
else
  printf 'not ok - tracked Pi extensions fail strict no-emit typecheck against Pi %s\n' "$version" >&2
  result=1
fi
if [ "$(uname -s)" = Linux ]; then
  if node "$ROOT/tests/fixtures/fm-read-repetition-sdk.mjs" \
      "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent" "$TMP_ROOT/read-guard-lab"; then
    printf 'ok - read guard real SDK events/abort against Pi %s\n' "$version"
  else
    printf 'not ok - read guard real SDK events/abort against Pi %s\n' "$version" >&2
    result=1
  fi
else
  printf 'skip: read guard runtime matrix supports Linux only\n'
fi
done
exit "$result"

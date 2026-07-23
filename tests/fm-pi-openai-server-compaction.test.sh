#!/usr/bin/env bash
# Contract and isolated compatibility tests for the pinned project-local Pi compaction package.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PIN=c6d593087709e9481223dc6c6c2269b371b5e055
SOURCE="git:github.com/algal/pi-openai-server-compaction@$PIN"
PI_VERSION=0.80.10
SETTINGS="$ROOT/.pi/settings.json"
CONFIG="$ROOT/.pi/openai-server-compaction.json"
AUDIT_DOC="$ROOT/docs/pi-openai-server-compaction.md"
TMP_ROOT=$(fm_test_tmproot fm-pi-openai-server-compaction)

for tool in git jq node npm; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for the Pi package integration test"
done

node_major=$(node -p 'Number(process.versions.node.split(".")[0])')
[ "$node_major" -ge 22 ] || fail "Node 22 or newer is required for the isolated Pi package smoke, got $(node --version)"

jq -e --arg source "$SOURCE" '
  .packages == [{source: $source, autoload: false}]
' "$SETTINGS" >/dev/null || fail "project Pi settings do not contain the exact disabled immutable package declaration"

jq -e '
  . == {
    enabled: true,
    includeAzure: false,
    thresholdRatio: 0.7,
    compactThreshold: 0,
    usePreviousResponseId: false,
    notify: true
  }
' "$CONFIG" >/dev/null || fail "project compaction config is not the conservative OpenAI-only trial"

assert_grep "$PIN" "$ROOT/README.md" "README does not disclose the immutable package revision"
assert_grep "$PIN" "$AUDIT_DOC" "audit does not identify the immutable package revision"
assert_grep "There is no setting that disables \`store: true\`" "$ROOT/README.md" "README does not disclose the direct OpenAI storage constraint"
assert_grep '~/.npm-global/bin/pi' "$ROOT/README.md" "README does not identify the approved temporary Pi runtime"
assert_grep 'npm uninstall -g @earendil-works/pi-coding-agent' "$AUDIT_DOC" "audit does not document temporary npm Pi removal"
assert_grep '/opt/homebrew/bin/pi --version' "$AUDIT_DOC" "audit does not require explicit Homebrew Pi verification"

tracked_generated=$(git -C "$ROOT" ls-files | grep -E '(^|/)(node_modules|\.pi/(git|npm|cache))(/|$)' || true)
[ -z "$tracked_generated" ] || fail "generated Pi package material is tracked: $tracked_generated"
tracked_credentials=$(git -C "$ROOT" ls-files '.pi/**' | grep -Ei '(^|/)(auth|trust|credentials?|tokens?)(\.|/|$)' || true)
[ -z "$tracked_credentials" ] || fail "Pi credential or trust material is tracked: $tracked_credentials"

for ignored in .pi/git/example .pi/npm/example .pi/cache/example .pi/auth.json .pi/trust.json node_modules/example; do
  git -C "$ROOT" check-ignore -q "$ignored" || fail "$ignored is not ignored"
done
pass "Pi settings, provider config, source pin, and generated-material boundaries are deterministic"

runtime="$TMP_ROOT/runtime"
fixture="$TMP_ROOT/project"
agent_dir="$TMP_ROOT/agent"
install_log="$TMP_ROOT/install.log"
mkdir -p "$runtime" "$fixture/.pi" "$agent_dir"

npm install --prefix "$runtime" --no-save --ignore-scripts \
  "@earendil-works/pi-coding-agent@$PI_VERSION" >"$TMP_ROOT/npm-pi.log" 2>&1 \
  || fail "could not install isolated Pi $PI_VERSION: $(cat "$TMP_ROOT/npm-pi.log")"

pi_bin="$runtime/node_modules/.bin/pi"
[ -x "$pi_bin" ] || fail "isolated Pi binary is missing"
[ "$($pi_bin --version)" = "$PI_VERSION" ] || fail "isolated Pi version is not $PI_VERSION"

(
  cd "$fixture"
  PI_CODING_AGENT_DIR="$agent_dir" GIT_TERMINAL_PROMPT=0 \
    "$pi_bin" install --approve -l "$SOURCE"
) >"$install_log" 2>&1 \
  || fail "isolated project package install failed: $(cat "$install_log")"

package_dir="$fixture/.pi/git/github.com/algal/pi-openai-server-compaction"
[ "$(git -C "$package_dir" rev-parse HEAD)" = "$PIN" ] || fail "installed package checkout does not match the configured commit"
[ -f "$package_dir/package-lock.json" ] || fail "Pi did not generate a local package lock during install"

(
  cd "$package_dir"
  npm ls --omit=dev --json
) >"$TMP_ROOT/production-tree.json" 2>"$TMP_ROOT/production-tree.err" \
  || fail "installed production dependency tree is invalid: $(cat "$TMP_ROOT/production-tree.err")"

PACKAGE_DIR="$package_dir" PROD_TREE="$TMP_ROOT/production-tree.json" node <<'NODE'
const assert = require("node:assert/strict");
const path = require("node:path");
const root = process.env.PACKAGE_DIR;
const manifest = require(path.join(root, "package.json"));
const lock = require(path.join(root, "package-lock.json"));
const wsManifest = require(path.join(root, "node_modules/ws/package.json"));
const productionTree = require(process.env.PROD_TREE);
assert.deepEqual(manifest.dependencies, { ws: "^8.18.0" });
for (const name of ["preinstall", "install", "postinstall", "prepare"]) {
  assert.equal(manifest.scripts?.[name], undefined, `upstream declares ${name}`);
  assert.equal(wsManifest.scripts?.[name], undefined, `ws declares ${name}`);
}
assert.deepEqual(
  Object.keys(productionTree.dependencies ?? {}).sort(),
  ["ws"],
  "unexpected installed production dependency",
);
assert.equal(lock.packages["node_modules/ws"].version, "8.21.1");
assert.equal(
  lock.packages["node_modules/ws"].integrity,
  "sha512-+0NTnW77fFN/DjQi6k/Sq/Yvk4Sgajw7urW8V+asjXnRgDs9gyGkdb7EzgfhA4goXsRIZKE28fzIXBHEzhuiWw==",
);
assert.equal(wsManifest.version, lock.packages["node_modules/ws"].version);
NODE

for package_name in pi-coding-agent pi-agent-core pi-ai; do
  peer="$runtime/node_modules/@earendil-works/$package_name"
  if [ ! -d "$peer" ]; then
    peer="$runtime/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/$package_name"
  fi
  [ -d "$peer" ] || fail "isolated Pi is missing peer package @earendil-works/$package_name"
  mkdir -p "$package_dir/node_modules/@earendil-works"
  ln -s "$peer" "$package_dir/node_modules/@earendil-works/$package_name"
done

(
  cd "$package_dir"
  PI_CODING_AGENT_DIR="$agent_dir" node --experimental-strip-types ./scripts/smoke.mjs
) >"$TMP_ROOT/upstream-smoke.log" 2>&1 \
  || fail "upstream offline smoke failed: $(cat "$TMP_ROOT/upstream-smoke.log")"
assert_grep "smoke ok" "$TMP_ROOT/upstream-smoke.log" "upstream smoke did not report success"

cp "$SETTINGS" "$fixture/.pi/settings.json"
cp "$CONFIG" "$fixture/.pi/openai-server-compaction.json"
cp -R "$ROOT/.pi/extensions" "$fixture/.pi/extensions"

jq '.packages[0].autoload = true' "$fixture/.pi/settings.json" >"$TMP_ROOT/settings-enabled.json"
cp "$TMP_ROOT/settings-enabled.json" "$fixture/.pi/settings.json"

(
  cd "$fixture"
  PI_CODING_AGENT_DIR="$agent_dir" "$pi_bin" --offline --approve --list-models openai
) >"$TMP_ROOT/load.log" 2>&1 \
  || fail "isolated Pi could not load the package with firstmate's existing extensions: $(cat "$TMP_ROOT/load.log")"

cp "$SETTINGS" "$fixture/.pi/settings.json"
PI_PACKAGE_ROOT="$runtime/node_modules/@earendil-works/pi-coding-agent" \
FIXTURE="$fixture" AGENT_DIR="$agent_dir" node --input-type=module <<'NODE'
const pi = await import(`${process.env.PI_PACKAGE_ROOT}/dist/index.js`);
if (typeof pi.compact !== "function") throw new Error("Pi built-in compact export is unavailable");
const settings = pi.SettingsManager.create(process.env.FIXTURE, process.env.AGENT_DIR, {
  projectTrusted: true,
});
if (!settings.getCompactionEnabled()) throw new Error("Pi normal compaction is disabled");
const projectPackage = settings.getProjectSettings().packages?.[0];
if (!projectPackage || typeof projectPackage !== "object" || projectPackage.autoload !== false) {
  throw new Error("package rollback gate is not disabled");
}
NODE

pass "pinned package loads offline on isolated Pi 0.80.10 and disablement preserves normal Pi compaction"

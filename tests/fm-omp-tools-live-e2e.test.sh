#!/usr/bin/env bash
# tests/fm-omp-tools-live-e2e.test.sh - opt-in installed-binary guard for the
# candidate OMP adapter's narrow tool and settings boundary.
#
# The deliberately invalid sentinel makes OMP exit during argument validation.
# This test submits no prompt, creates no session, starts no TUI, and makes no
# provider call. It is still classified as live-harness-optin because only the
# installed pinned binary can prove the accepted vendor tool names and consume
# the effective isolated settings.
set -u

if [ "${FM_OMP_TOOLS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_TOOLS_LIVE_E2E=1 to run the installed OMP tool-name guard"
  exit 0
fi

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/bin/fm-timeout-lib.sh"
OMP_BIN=$(command -v omp) || fail "FM_OMP_TOOLS_LIVE_E2E=1 but omp is not installed"
VERSION=$(fm_run_timed 15 "$OMP_BIN" --version 2>/dev/null) \
  || fail "omp --version did not complete successfully within fifteen seconds"
VERSION=$(printf '%s\n' "$VERSION" | tr -d '[:space:]')
PINNED_VERSION=omp/17.2.9
[ "$VERSION" = "$PINNED_VERSION" ] \
  || fail "installed omp is '$VERSION', expected '$PINNED_VERSION'"

LIVE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-live-e2e.XXXXXX") \
  || fail "could not allocate the OMP live-guard fixture"
trap 'rm -rf -- "$LIVE_ROOT"' EXIT
AGENT_DIR="$LIVE_ROOT/isolated-agent"
ISOLATED_CWD="$LIVE_ROOT/isolated-cwd"
AMBIENT_OVERLAY="$LIVE_ROOT/ambient-overlay.json"
printf '%s\n' '{"retry":{"modelFallback":true,"usageAwareFallback":true,"fallbackChains":{"ambient":["provider/model"]}}}' > "$AMBIENT_OVERLAY"
"$ROOT/bin/fm-omp-candidate-artifacts.sh" prepare "$AGENT_DIR" "$ISOLATED_CWD" \
  || fail "candidate OMP settings isolation did not prepare"
MANIFEST=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
  "$AGENT_DIR" "$ISOLATED_CWD" /task/worktree "$OMP_BIN" provider/model /state/task.omp-ext.ts) \
  || fail "candidate OMP manifest did not render"
TOOLS=$(MANIFEST=$MANIFEST node -e '
const manifest = JSON.parse(process.env.MANIFEST);
const index = manifest.argv.indexOf("--tools");
if (index < 0 || !manifest.unsetEnvironment.includes("PI_CONFIG_FILES") || !manifest.argv.includes("--no-lsp")) process.exit(1);
const retry = manifest.effectiveRetry;
if (!retry || retry.modelFallback !== false || retry.usageAwareFallback !== false) process.exit(1);
if (!retry.fallbackChains || Object.keys(retry.fallbackChains).length !== 0) process.exit(1);
process.stdout.write(manifest.argv[index + 1]);
') || fail "candidate OMP manifest does not carry the required containment settings"

omp_config_get() {
  (
    cd "$ISOLATED_CWD" || exit 1
    PI_CONFIG_FILES=$AMBIENT_OVERLAY
    export PI_CONFIG_FILES
    unset PI_CONFIG_FILES
    PI_CODING_AGENT_DIR=$AGENT_DIR
    export PI_CODING_AGENT_DIR
    fm_run_timed 15 "$OMP_BIN" config get "$1" --json
  )
}

MODEL_FALLBACK=$(omp_config_get retry.modelFallback 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read retry.modelFallback"
USAGE_FALLBACK=$(omp_config_get retry.usageAwareFallback 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read retry.usageAwareFallback"
FALLBACK_CHAINS=$(omp_config_get retry.fallbackChains 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read retry.fallbackChains"
MODEL_FALLBACK=$MODEL_FALLBACK USAGE_FALLBACK=$USAGE_FALLBACK \
  FALLBACK_CHAINS=$FALLBACK_CHAINS node -e '
const model = JSON.parse(process.env.MODEL_FALLBACK).value;
const usage = JSON.parse(process.env.USAGE_FALLBACK).value;
const chains = JSON.parse(process.env.FALLBACK_CHAINS).value;
if (model !== false || usage !== false || !chains || Array.isArray(chains) || Object.keys(chains).length !== 0) process.exit(1);
' || fail "pinned OMP settings consumer retained ambient fallback behavior"
SENTINEL=__fm_not_a_tool__

omp_unknown_names() {
  fm_run_timed 30 "$OMP_BIN" --tools "$1" </dev/null 2>&1 \
    | sed -n 's/.*Unknown tools\{0,1\} in --tools: \([^.]*\)\..*/\1/p' \
    | head -1
}

UNKNOWN=$(omp_unknown_names "$SENTINEL")
[ "$UNKNOWN" = "$SENTINEL" ] \
  || fail "OMP's unknown-tool diagnostic changed: asked about '$SENTINEL', parsed '$UNKNOWN'"

UNKNOWN=$(omp_unknown_names "$TOOLS,$SENTINEL")
[ "$UNKNOWN" = "$SENTINEL" ] \
  || fail "installed $VERSION rejects the adapter allowlist '$TOOLS': rejected '$UNKNOWN'"

pass "installed $VERSION accepts the contained manifest and effective fallback isolation without session startup"

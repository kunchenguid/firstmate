#!/usr/bin/env bash
# tests/fm-omp-tools-live-e2e.test.sh - opt-in installed-binary guard for the
# candidate OMP adapter's narrow tool allowlist.
#
# The deliberately invalid sentinel makes OMP exit during argument validation.
# This test submits no prompt, creates no session, starts no TUI, and makes no
# provider call. It is still classified as live-harness-optin because only the
# installed pinned binary can prove the accepted vendor tool names.
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
VERSION=$(fm_run_timed 5 "$OMP_BIN" --version 2>/dev/null) \
  || fail "omp --version did not complete successfully within five seconds"
VERSION=$(printf '%s\n' "$VERSION" | tr -d '[:space:]')
PINNED_VERSION=omp/17.2.9
[ "$VERSION" = "$PINNED_VERSION" ] \
  || fail "installed omp is '$VERSION', expected '$PINNED_VERSION'"

MANIFEST=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
  /isolated/agent /isolated/cwd /task/worktree "$OMP_BIN" provider/model /state/task.omp-ext.ts) \
  || fail "candidate OMP manifest did not render"
TOOLS=$(MANIFEST=$MANIFEST node -e '
const manifest = JSON.parse(process.env.MANIFEST);
const index = manifest.argv.indexOf("--tools");
if (index < 0 || !manifest.unsetEnvironment.includes("PI_CONFIG_FILES")) process.exit(1);
const retry = manifest.effectiveRetry;
if (!retry || retry.modelFallback !== false || retry.usageAwareFallback !== false) process.exit(1);
if (!retry.fallbackChains || Object.keys(retry.fallbackChains).length !== 0) process.exit(1);
process.stdout.write(manifest.argv[index + 1]);
') || fail "candidate OMP manifest does not carry the required containment settings"
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

pass "installed $VERSION accepts the candidate adapter allowlist '$TOOLS'; validation stopped before session startup"

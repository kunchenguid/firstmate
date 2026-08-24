#!/usr/bin/env bash
# tests/fm-omp-tools-live-e2e.test.sh - opt-in installed-binary guard for the
# candidate OMP adapter's empty tool and settings boundary.
#
# This test uses OMP's config consumer and an RPC get_state diagnostic under
# --no-session. It submits no prompt, starts no TUI, persists no session, and
# makes no provider call. It is still classified as live-harness-optin because
# only the installed pinned binary can construct the effective tool registry.
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
LIVE_HOME="$LIVE_ROOT/home"
HOSTILE_AGENT="$LIVE_HOME/.omp/profiles/hostile/agent"
RPC_INPUT="$LIVE_ROOT/rpc-input.jsonl"
mkdir -p "$HOSTILE_AGENT"
printf '%s\n' '{"retry":{"modelFallback":true,"usageAwareFallback":true,"fallbackChains":{"hostile":["provider/model"]}},"astEdit":{"enabled":true}}' > "$HOSTILE_AGENT/config.yml"
printf '%s\n' '{"id":"candidate-tools","type":"get_state"}' > "$RPC_INPUT"
"$ROOT/bin/fm-omp-candidate-artifacts.sh" prepare "$AGENT_DIR" "$ISOLATED_CWD" \
  || fail "candidate OMP settings isolation did not prepare"
MANIFEST=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
  "$AGENT_DIR" "$ISOLATED_CWD" /task/worktree "$OMP_BIN" provider/model /state/task.omp-ext.ts) \
  || fail "candidate OMP manifest did not render"
MANIFEST=$MANIFEST node -e '
const manifest = JSON.parse(process.env.MANIFEST);
if (!manifest.unsetEnvironment.includes("PI_CONFIG_FILES") || !manifest.argv.includes("--no-lsp")) process.exit(1);
if (!manifest.unsetEnvironment.includes("OMP_PROFILE") || !manifest.unsetEnvironment.includes("PI_PROFILE")) process.exit(1);
if (!manifest.argv.includes("--no-tools") || manifest.argv.includes("--tools")) process.exit(1);
if (!Array.isArray(manifest.effectiveTools) || manifest.effectiveTools.length !== 0) process.exit(1);
if (!manifest.effectiveAstEdit || manifest.effectiveAstEdit.enabled !== false) process.exit(1);
const retry = manifest.effectiveRetry;
if (!retry || retry.modelFallback !== false || retry.usageAwareFallback !== false) process.exit(1);
if (!retry.fallbackChains || Object.keys(retry.fallbackChains).length !== 0) process.exit(1);
' || fail "candidate OMP manifest does not carry the required containment settings"

RPC_STATE=$(
  cd "$ISOLATED_CWD" || exit 1
  unset OMP_PROFILE PI_PROFILE PI_CONFIG_FILES
  HOME=$LIVE_HOME PI_CODING_AGENT_DIR=$AGENT_DIR \
    fm_run_timed 15 bash -c 'input=$1; shift; exec "$@" < "$input"' bash "$RPC_INPUT" \
      "$OMP_BIN" \
        --cwd "$ISOLATED_CWD" --approval-mode yolo --no-title \
        --no-extensions --no-skills --no-lsp --no-tools \
        --model anthropic/claude-sonnet-4-5 --mode rpc --no-session 2>/dev/null
) || fail "pinned OMP no-session tool diagnostic did not complete successfully"
printf '%s\n' "$RPC_STATE" | node -e '
let input = "";
process.stdin.on("data", chunk => input += chunk).on("end", () => {
  const frames = input.split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
  const response = frames.find(frame => frame.type === "response" && frame.command === "get_state" && frame.id === "candidate-tools");
  if (!response) {
    process.stderr.write(`missing get_state response; frames=${frames.map(frame => frame.type).join(",")}\n`);
    process.exit(1);
  }
  const tools = response.data?.dumpTools;
  if (response.success !== true || !Array.isArray(tools) || tools.length !== 0) {
    process.stderr.write(`effective tools=${Array.isArray(tools) ? tools.map(tool => tool.name).join(",") : "unavailable"}\n`);
    process.exit(1);
  }
});
' || fail "pinned OMP tool-construction consumer retained an effective tool"

omp_config_get() {
  (
    cd "$ISOLATED_CWD" || exit 1
    unset OMP_PROFILE PI_PROFILE PI_CONFIG_FILES
    HOME=$LIVE_HOME PI_CODING_AGENT_DIR=$AGENT_DIR \
      fm_run_timed 15 "$OMP_BIN" config get "$1" --json
  )
}

hostile_config_get() {
  (
    cd "$ISOLATED_CWD" || exit 1
    unset PI_CONFIG_FILES
    HOME=$LIVE_HOME OMP_PROFILE=hostile PI_PROFILE=hostile PI_CODING_AGENT_DIR=$AGENT_DIR \
      fm_run_timed 15 "$OMP_BIN" config get "$1" --json
  )
}

HOSTILE_MODEL_FALLBACK=$(hostile_config_get retry.modelFallback 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read the hostile named profile"
HOSTILE_MODEL_FALLBACK=$HOSTILE_MODEL_FALLBACK node -e '
if (JSON.parse(process.env.HOSTILE_MODEL_FALLBACK).value !== true) process.exit(1);
' || fail "hostile named-profile control did not override the isolated agent directory"

MODEL_FALLBACK=$(omp_config_get retry.modelFallback 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read retry.modelFallback"
USAGE_FALLBACK=$(omp_config_get retry.usageAwareFallback 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read retry.usageAwareFallback"
FALLBACK_CHAINS=$(omp_config_get retry.fallbackChains 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read retry.fallbackChains"
AST_EDIT_ENABLED=$(omp_config_get astEdit.enabled 2>/dev/null) \
  || fail "pinned OMP settings consumer could not read astEdit.enabled"
MODEL_FALLBACK=$MODEL_FALLBACK USAGE_FALLBACK=$USAGE_FALLBACK \
  FALLBACK_CHAINS=$FALLBACK_CHAINS AST_EDIT_ENABLED=$AST_EDIT_ENABLED node -e '
const model = JSON.parse(process.env.MODEL_FALLBACK).value;
const usage = JSON.parse(process.env.USAGE_FALLBACK).value;
const chains = JSON.parse(process.env.FALLBACK_CHAINS).value;
const astEdit = JSON.parse(process.env.AST_EDIT_ENABLED).value;
if (model !== false || usage !== false || !chains || Array.isArray(chains) || Object.keys(chains).length !== 0 || astEdit !== false) process.exit(1);
' || fail "pinned OMP settings consumer retained ambient fallback or AST-edit behavior"

pass "installed $VERSION isolates hostile profiles and constructs an empty tool registry without provider startup"

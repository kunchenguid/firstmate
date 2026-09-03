#!/usr/bin/env bash
# Policy, artifact, and non-execution tests for the dormant OMP candidate.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

OMP_MODEL="anthropic/claude-sonnet-4-5"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

test_omp_launch_request_is_rendered() {
  local manifest template
  manifest=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
    /isolated/agent /isolated/cwd /opt/omp "$OMP_MODEL" /state/task.omp-ext.ts) \
    || fail "candidate OMP manifest did not render"
  template=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" launch-template) \
    || fail "candidate OMP launch template did not render"
  MANIFEST=$manifest TEMPLATE=$template node <<'NODE' \
    || fail "candidate OMP manifest or launch template drifted from its requested output contract"
const manifest = JSON.parse(process.env.MANIFEST);
if (JSON.stringify(Object.keys(manifest).sort()) !== JSON.stringify(["argv", "environment", "unsetEnvironment"])) process.exit(1);
const expectedUnset = [
  "CLAUDECODE", "PI_CODING_AGENT", "PI_CONFIG_FILES", "OMP_PROFILE", "PI_PROFILE", "GROK_AGENT",
  "FM_PI_HARNESS", "CURSOR_AGENT", "CURSOR_INVOKED_AS", "TRACEPARENT",
];
const expectedArgv = [
  "/opt/omp", "--cwd", "/isolated/cwd", "--approval-mode", "yolo",
  "--no-title", "--no-extensions", "--no-skills",
  "--no-lsp", "--no-tools", "--model", "anthropic/claude-sonnet-4-5",
  "-e", "/state/task.omp-ext.ts",
];
if (JSON.stringify(manifest.unsetEnvironment) !== JSON.stringify(expectedUnset)) process.exit(1);
if (manifest.environment.FM_OMP_HARNESS !== "1") process.exit(1);
if (manifest.environment.PI_CODING_AGENT_DIR !== "/isolated/agent") process.exit(1);
if (JSON.stringify(manifest.argv) !== JSON.stringify(expectedArgv)) process.exit(1);
if (manifest.argv.includes("--tools")) process.exit(1);
if (!manifest.argv.includes("--no-tools")) process.exit(1);
if (manifest.argv.includes("--add-dir")) process.exit(1);
if (manifest.argv.includes("/task/worktree")) process.exit(1);
const templateManifest = {
  ...manifest,
  environment: { FM_OMP_HARNESS: "1", PI_CODING_AGENT_DIR: "__OMPAGENTDIR__" },
  argv: manifest.argv.map((word) => ({
    "/opt/omp": "__OMPBIN__",
    "/isolated/cwd": "__OMPCWD__",
    "anthropic/claude-sonnet-4-5": "__OMPMODEL__",
    "/state/task.omp-ext.ts": "__OMPEXT__",
  })[word] || word),
};
const words = ["env"];
for (const name of templateManifest.unsetEnvironment) words.push("-u", name);
for (const [name, value] of Object.entries(templateManifest.environment)) words.push(`${name}=${value}`);
words.push(...templateManifest.argv);
const expectedTemplate = words.join(" ") + ' "$(__OPINPUT__ encode launch-brief < __BRIEF__)"';
if (process.env.TEMPLATE !== expectedTemplate) process.exit(1);
NODE
  pass "OMP candidate renderer emits its requested argv and environment contract"
}

test_omp_consumer_proof_gate_never_executes_candidate() {
  local dir fakebin log out status
  dir="$TMP_ROOT/omp-consumer-proof"
  fakebin="$dir/fakebin"
  log="$dir/omp-invocations"
  mkdir -p "$fakebin"
  : > "$log"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_OMP_PROOF_STUB_LOG"
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_OMP_PROOF_STUB_VERSION:-omp/17.2.9}"
  exit 0
fi
exit 97
SH
  chmod +x "$fakebin/omp"
  out=$(PATH="$fakebin:$PATH" FM_OMP_PROOF_STUB_LOG="$log" FM_OMP_TOOLS_LIVE_E2E=1 \
    "$ROOT/tests/fm-omp-tools-live-e2e.test.sh" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the unavailable exact-version consumer proof must fail closed"
  assert_contains "$out" "no supported session-free configuration and tool consumer" \
    "the consumer proof gate did not name its unresolved prerequisite"
  assert_contains "$out" "executable provenance, version, and effective behavior remain unproven" \
    "the consumer proof gate overstated requested metadata as effective proof"
  [ ! -s "$log" ] || fail "the unresolved consumer proof gate executed OMP: $(cat "$log")"
  pass "OMP consumer proof gate fails closed without candidate execution"
}

test_omp_candidate_artifacts_render_requested_settings_and_handle_continuation() {
  local state id gen agent_dir isolated_cwd ambient_agent ambient_project ambient_overlay manifest ext record turnend
  state="$TMP_ROOT/candidate-artifacts/state"
  id=omp-candidate-artifacts
  agent_dir="$state/isolated-agent"
  isolated_cwd="$state/isolated-cwd"
  ambient_agent="$state/ambient-agent"
  ambient_project="$state/ambient-project"
  ambient_overlay="$state/ambient-overlay.json"
  ext="$state/$id.omp-ext.ts"
  record="$state/$id.busy-state"
  turnend="$state/$id.turn-ended"
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "could not arm the candidate artifact fixture"
  mkdir -p "$ambient_agent" "$ambient_project/.omp"
  printf '%s\n' '{"retry":{"modelFallback":true,"usageAwareFallback":true,"fallbackChains":{"ambient":["provider/model"]}}}' > "$ambient_agent/config.yml"
  printf '%s\n' '{"retry":{"fallbackChains":{"project":["provider/model"]}}}' > "$ambient_project/.omp/config.yml"
  printf '%s\n' '{"retry":{"fallbackChains":{"overlay":["provider/model"]}}}' > "$ambient_overlay"
  "$ROOT/bin/fm-omp-candidate-artifacts.sh" prepare "$agent_dir" "$isolated_cwd" \
    || fail "could not prepare isolated candidate OMP settings"
  manifest=$("$ROOT/bin/fm-omp-candidate-artifacts.sh" manifest \
    "$agent_dir" "$isolated_cwd" /opt/omp "$OMP_MODEL" "$ext") \
    || fail "could not render the candidate OMP manifest"
  MANIFEST=$manifest AGENT_DIR=$agent_dir ISOLATED_CWD=$isolated_cwd \
    AMBIENT_AGENT=$ambient_agent AMBIENT_PROJECT=$ambient_project \
    PI_CONFIG_FILES=$ambient_overlay node <<'NODE' \
    || fail "candidate OMP settings artifacts drifted from their requested isolation contract"
const fs = require("node:fs");
const path = require("node:path");
const manifest = JSON.parse(process.env.MANIFEST);
if (!manifest.unsetEnvironment.includes("PI_CONFIG_FILES")) process.exit(1);
if (!manifest.unsetEnvironment.includes("OMP_PROFILE") || !manifest.unsetEnvironment.includes("PI_PROFILE")) process.exit(1);
if (manifest.environment.PI_CODING_AGENT_DIR === process.env.AMBIENT_AGENT) process.exit(1);
if (manifest.environment.PI_CODING_AGENT_DIR !== process.env.AGENT_DIR) process.exit(1);
const cwdIndex = manifest.argv.indexOf("--cwd");
const cwd = manifest.argv[cwdIndex + 1];
if (cwd === process.env.AMBIENT_PROJECT) process.exit(1);
if (cwd !== process.env.ISOLATED_CWD) process.exit(1);
if (manifest.argv.includes("--add-dir") || manifest.argv.includes("/task/worktree")) process.exit(1);
if (!manifest.argv.includes("--no-lsp")) process.exit(1);
const config = JSON.parse(fs.readFileSync(path.join(manifest.environment.PI_CODING_AGENT_DIR, "config.yml"), "utf8"));
const retry = config.retry;
if (!retry || retry.modelFallback !== false || retry.usageAwareFallback !== false) process.exit(1);
if (!retry.fallbackChains || Array.isArray(retry.fallbackChains) || Object.keys(retry.fallbackChains).length !== 0) process.exit(1);
if (!config.astEdit || config.astEdit.enabled !== false) process.exit(1);
NODE
  "$ROOT/bin/fm-omp-candidate-artifacts.sh" extension "$ext" \
    "$ROOT/bin/fm-busy-event.sh" "$state" "$id" "$gen" "$turnend" \
    || fail "could not render the candidate OMP extension"
  EXT_PATH="$ext" node --experimental-strip-types --input-type=module <<'NODE' \
    || fail "the candidate OMP continuation event did not execute"
import { pathToFileURL } from "node:url";
const handlers = new Map();
const module = await import(pathToFileURL(process.env.EXT_PATH).href);
module.default({ on(name, handler) { handlers.set(name, handler); } });
await handlers.get("agent_start")();
await handlers.get("agent_end")({ willContinue: true }, { isIdle: () => true });
await new Promise((resolve) => setTimeout(resolve, 150));
NODE
  assert_grep 'state=busy source=omp-ext event=agent-start' "$record" \
    "willContinue=true incorrectly settled the candidate extension"
  EXT_PATH="$ext" node --experimental-strip-types --input-type=module <<'NODE' \
    || fail "the final OMP settle event did not execute"
import { pathToFileURL } from "node:url";
const handlers = new Map();
const module = await import(pathToFileURL(process.env.EXT_PATH).href);
module.default({ on(name, handler) { handlers.set(name, handler); } });
await handlers.get("agent_end")({ willContinue: false }, { isIdle: () => true });
await new Promise((resolve) => setTimeout(resolve, 150));
NODE
  assert_grep 'state=idle source=omp-ext event=agent-end' "$record" \
    "the final OMP settle event did not record idle"
  pass "OMP candidate renders requested settings and preserves busy across willContinue"
}


make_refusal_case() {
  local name=$1 configured=${2:-} case_dir home fakebin sentinel
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  sentinel="$case_dir/candidate-executed"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$configured"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf 'executed\n' >> "${FM_OMP_EXECUTION_SENTINEL:?}"
exit 97
SH
  chmod +x "$fakebin/omp"
  printf '%s|%s|%s\n' "$home" "$fakebin" "$sentinel"
}

run_spawn_refusal() {
  local name=$1 configured=$2 expected=$3 record home fakebin sentinel out status
  shift 3
  record=$(make_refusal_case "$name" "$configured")
  IFS='|' read -r home fakebin sentinel <<EOF
$record
EOF
  out=$(FM_OMP_EXECUTION_SENTINEL="$sentinel" \
    fm_test_run_spawn "$home" /not-a-pane "$fakebin" "$@" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "$name unexpectedly dispatched the candidate"
  assert_contains "$out" "$expected" "$name did not reach the expected refusal: $out"
  assert_absent "$sentinel" "$name executed the candidate"
  if find "$home/state" -maxdepth 1 -name '*.meta' -print -quit | grep -q .; then
    fail "$name published task metadata before refusing"
  fi
}

test_spawn_policy_matrix_stays_dormant_and_tmux_only() {
  run_spawn_refusal explicit-dormant '' 'session-free omp/17.2.9 consumer'     task-explicit /not-a-project --harness omp --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal orca-refusal '' 'requires backend=tmux'     task-orca /not-a-project --harness omp --model "$OMP_MODEL"     --backend orca --mode no-mistakes --yolo off
  run_spawn_refusal missing-model '' 'requires an explicit --model'     task-missing /not-a-project --harness omp --backend tmux     --mode no-mistakes --yolo off
  run_spawn_refusal malformed-model '' 'must be exactly'     task-malformed /not-a-project --harness omp --model model-only     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal positional '' 'requires an explicit --harness omp'     task-positional /not-a-project omp --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal configured omp 'requires an explicit --harness omp'     task-configured /not-a-project --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal raw '' 'requires an explicit --harness omp'     task-raw /not-a-project 'env omp --version' --model "$OMP_MODEL"     --backend tmux --mode no-mistakes --yolo off
  run_spawn_refusal secondmate '' 'candidate crewmate/scout adapter only'     task-secondmate --secondmate --harness omp --model "$OMP_MODEL"     --backend tmux
  pass "OMP selection, model, backend, role, and dormancy gates refuse without execution"
}

test_omp_launch_request_is_rendered
test_omp_consumer_proof_gate_never_executes_candidate
test_omp_candidate_artifacts_render_requested_settings_and_handle_continuation
test_spawn_policy_matrix_stays_dormant_and_tmux_only

echo "all fm-omp-harness tests passed"

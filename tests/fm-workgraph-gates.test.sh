#!/usr/bin/env bash
# Slice-7 gates, evidence, snapshots, dependency admission, and teardown safety.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-workgraph-gates)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
GATE_HOLDER_PID=
cleanup_gate_test() {
  case "$GATE_HOLDER_PID" in ''|*[!0-9]*) ;; *) kill "$GATE_HOLDER_PID" >/dev/null 2>&1 || true ;; esac
  fm_test_cleanup
}
trap cleanup_gate_test EXIT

make_fixture() {
  local root=$1
  mkdir -p "$root/project" "$root/contracts"
  git -C "$root/project" init -q
  git -C "$root/project" config user.name test
  git -C "$root/project" config user.email test@example.invalid
  printf 'tracked\n' >"$root/project/tracked.txt"
  git -C "$root/project" add tracked.txt
  git -C "$root/project" commit -qm base
  git -C "$root/project" worktree add -q --detach "$root/wt-a"
  git -C "$root/project" worktree add -q --detach "$root/wt-b"
  node - "$root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = process.argv[2];
const refs = [];
for (const id of ["a", "b"]) {
  const contract = {
    schema_version: "slice-contract/v1",
    slice_id: id,
    goal_id: "gate-goal",
    purpose: `Gate ${id}`,
    type: "ship",
    depends_on: id === "b" ? ["a"] : [],
    immutable_inputs: [],
    outputs: [`out/${id}.txt`],
    claims: [{resource: `lock://gate-${id}`, mode: "write"}],
    worktree: path.join(root, `wt-${id}`),
    harness: "codex",
    model: "gpt-test",
    effort: "high",
    acceptance: ["accepted"],
    validation_commands: ["true"],
    expected_evidence: [`${id}.evidence`],
    context_budget: {source_tokens: 100, report_words: 100},
    gates: [id === "a" ? "unit" : "integration"],
    implementer: "worker",
    independent_validators: [id === "a" ? "validator-a" : "validator-b"],
    authorized_exceptions: [],
  };
  const bytes = Buffer.from(JSON.stringify(contract, null, 2) + "\n");
  fs.writeFileSync(path.join(root, "contracts", `${id}.json`), bytes);
  refs.push({
    slice_id: id,
    contract_path: `contracts/${id}.json`,
    contract_sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  });
}
fs.writeFileSync(path.join(root, "graph.json"), JSON.stringify({
  schema_version: "workgraph/v1",
  goal_id: "gate-goal",
  slices: refs,
}, null, 2) + "\n");
fs.writeFileSync(path.join(root, "registry.json"), JSON.stringify({
  schema_version: "resource-registry/v1",
  instances: [
    {id: "gate-a", namespace: "lock", resource: "lock://gate-a", aliases: [], contains: []},
    {id: "gate-b", namespace: "lock", resource: "lock://gate-b", aliases: [], contains: []},
  ],
}, null, 2) + "\n");
NODE
}

run_gate() {
  local home=$1
  shift
  set +e
  OUTPUT=$(FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" "$@" 2>&1)
  RC=$?
  set -e
}

test_slice7_schemas_are_closed_and_versioned() {
  node - "$ROOT/schemas/workgraph" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const expected = {
  "gate-result-v1.json": "workgraph-gate-result/v1",
  "evidence-result-v1.json": "workgraph-evidence-result/v1",
  "exception-record-v1.json": "workgraph-exception/v1",
  "snapshot-manifest-v1.json": "workgraph-snapshot-manifest/v1",
};
for (const [name, version] of Object.entries(expected)) {
  const schema = JSON.parse(fs.readFileSync(path.join(root, name), "utf8"));
  if (schema.type !== "object" || schema.additionalProperties !== false
      || !Array.isArray(schema.required)
      || schema.properties.schema_version.const !== version) {
    process.exit(1);
  }
}
NODE
  pass "Slice-7 durable schemas are closed and versioned"
}

test_gate_history_dependency_and_idempotence() {
  local fixture="$TMP_ROOT/history-fixture" home="$TMP_ROOT/history-home"
  local gate_dir before after
  make_fixture "$fixture"
  mkdir -p "$home/data" "$home/state"
  run_gate "$home" gate-status "$fixture/graph.json"
  expect_code 0 "$RC" "initial gate status"
  assert_contains "$OUTPUT" 'state=pending' "unrecorded gate was not pending"
  [ ! -e "$home/data/workgraphs" ] \
    || fail "read-only gate status materialized durable state"
  run_gate "$home" gate-check "$fixture/graph.json" b
  [ "$RC" -ne 0 ] || fail "dependent slice dispatched before predecessor gate"
  assert_contains "$OUTPUT" 'WG-G-E-PENDING' "dependency refusal diagnostic changed"

  printf 'failed evidence\n' >"$fixture/failed.txt"
  run_gate "$home" record-gate "$fixture/graph.json" a unit \
    --status failed --evidence "$fixture/failed.txt" --actor validator-a
  expect_code 0 "$RC" "failed gate record"
  assert_contains "$OUTPUT" '"sequence":1' "first gate revision is not sequence 1"
  run_gate "$home" completion-check "$fixture/graph.json" a
  [ "$RC" -ne 0 ] || fail "failed gate completed the slice"

  printf 'passed evidence\n' >"$fixture/passed.txt"
  run_gate "$home" record-gate "$fixture/graph.json" a unit \
    --status passed --evidence "$fixture/passed.txt" --actor validator-a
  expect_code 0 "$RC" "passed gate record"
  assert_contains "$OUTPUT" '"sequence":2' "second gate revision is not sequence 2"
  before=$OUTPUT
  run_gate "$home" record-gate "$fixture/graph.json" a unit \
    --status passed --evidence "$fixture/passed.txt" --actor validator-a
  expect_code 0 "$RC" "idempotent gate retry"
  after=$OUTPUT
  [ "$before" = "$after" ] || fail "idempotent gate retry changed canonical bytes"
  gate_dir=$(find "$home/data/workgraphs/gate-goal/gates/a" -mindepth 1 -maxdepth 1 -type d)
  [ "$(find "$gate_dir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')" = 2 ] \
    || fail "idempotent gate retry created another revision"
  run_gate "$home" gate-check "$fixture/graph.json" b
  expect_code 0 "$RC" "dependency passes after predecessor gate"
  assert_contains "$OUTPUT" 'dispatchable=true' "dependency gate did not become dispatchable"
  run_gate "$home" completion-check "$fixture/graph.json" a
  expect_code 0 "$RC" "completed predecessor"
  run_gate "$home" status "$fixture/graph.json"
  expect_code 0 "$RC" "WorkGraph status with durable gates"
  assert_contains "$OUTPUT" 'gate_slice[0].gate[0].state=passed' \
    "WorkGraph status did not expose durable gate state"
  pass "gate history is immutable/idempotent and controls dependency admission"
}

test_gate_actor_evidence_and_corruption_fail_closed() {
  local fixture="$TMP_ROOT/safety-fixture" home="$TMP_ROOT/safety-home"
  local evidence_digest evidence_file
  make_fixture "$fixture"
  mkdir -p "$home/data" "$home/state"
  printf 'evidence\n' >"$fixture/evidence.txt"
  run_gate "$home" record-gate "$fixture/graph.json" a unit \
    --status passed --evidence "$fixture/evidence.txt" --actor worker
  [ "$RC" -ne 0 ] || fail "implementer recorded its own independent gate"
  assert_contains "$OUTPUT" 'WG-G-E-ACTOR' "independent-validator refusal diagnostic changed"
  [ ! -e "$home/data/workgraphs" ] \
    || fail "invalid gate actor materialized evidence"

  ln -s evidence.txt "$fixture/evidence-link"
  run_gate "$home" record-gate "$fixture/graph.json" a unit \
    --status passed --evidence "$fixture/evidence-link" --actor validator-a
  [ "$RC" -ne 0 ] || fail "symlink evidence was accepted"
  assert_contains "$OUTPUT" 'WG-G-E-INPUT' "symlink evidence diagnostic changed"

  run_gate "$home" record-gate "$fixture/graph.json" a unit \
    --status passed --evidence "$fixture/evidence.txt" --actor validator-a
  expect_code 0 "$RC" "valid gate evidence"
  evidence_digest=$(printf 'evidence\n' | sha256sum | awk '{print $1}')
  evidence_file="$home/data/workgraphs/gate-goal/evidence/$evidence_digest/content.bin"
  assert_present "$evidence_file" "content-addressed evidence is missing"
  printf 'tampered\n' >"$evidence_file"
  run_gate "$home" gate-status "$fixture/graph.json" a
  [ "$RC" -ne 0 ] || fail "tampered content-addressed evidence was accepted"
  assert_contains "$OUTPUT" 'WG-G-E-CORRUPT' "evidence corruption diagnostic changed"
  pass "gate actors and evidence are independent, nonfollowing, and fail closed"
}

test_snapshot_is_content_addressed_and_clean_only() {
  local fixture="$TMP_ROOT/snapshot-fixture" home="$TMP_ROOT/snapshot-home"
  local first second digest archive
  make_fixture "$fixture"
  mkdir -p "$home/data" "$home/state"
  run_gate "$home" snapshot "$fixture/graph.json" a --actor Firstmate
  expect_code 0 "$RC" "clean snapshot"
  first=$OUTPUT
  digest=$(printf '%s' "$OUTPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).archive_sha256))')
  archive="$home/data/workgraphs/gate-goal/snapshots/a/$digest/candidate.tar"
  assert_present "$archive" "snapshot archive is missing"
  [ "$(sha256sum "$archive" | awk '{print $1}')" = "$digest" ] \
    || fail "snapshot archive digest does not match its address"
  run_gate "$home" snapshot "$fixture/graph.json" a --actor Firstmate
  expect_code 0 "$RC" "repeated clean snapshot"
  second=$OUTPUT
  [ "$first" = "$second" ] || fail "same Git tree produced different snapshot manifest bytes"
  printf 'dirty\n' >"$fixture/wt-a/untracked.txt"
  run_gate "$home" snapshot "$fixture/graph.json" a --actor Firstmate
  [ "$RC" -ne 0 ] || fail "dirty worktree produced an immutable snapshot"
  assert_contains "$OUTPUT" 'WG-G-E-DIRTY' "dirty snapshot diagnostic changed"
  pass "Git snapshots are clean-only, deterministic, and content-addressed"
}

test_contract_change_stales_prior_gate() {
  local fixture="$TMP_ROOT/stale-fixture" home="$TMP_ROOT/stale-home"
  make_fixture "$fixture"
  mkdir -p "$home/data" "$home/state"
  printf 'evidence\n' >"$fixture/evidence.txt"
  run_gate "$home" record-gate "$fixture/graph.json" a unit \
    --status passed --evidence "$fixture/evidence.txt" --actor validator-a
  expect_code 0 "$RC" "baseline gate before contract revision"
  node - "$fixture" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = process.argv[2];
const contractPath = path.join(root, "contracts/a.json");
const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
contract.purpose = "Revised contract bytes";
const bytes = Buffer.from(JSON.stringify(contract, null, 2) + "\n");
fs.writeFileSync(contractPath, bytes);
const graphPath = path.join(root, "graph.json");
const graph = JSON.parse(fs.readFileSync(graphPath, "utf8"));
graph.slices.find((item) => item.slice_id === "a").contract_sha256 =
  crypto.createHash("sha256").update(bytes).digest("hex");
fs.writeFileSync(graphPath, JSON.stringify(graph, null, 2) + "\n");
NODE
  run_gate "$home" gate-status "$fixture/graph.json" a
  expect_code 0 "$RC" "status after contract revision"
  assert_contains "$OUTPUT" 'state=stale' "old gate result was not stale after contract revision"
  run_gate "$home" gate-check "$fixture/graph.json" b
  [ "$RC" -ne 0 ] || fail "dependent slice accepted a stale predecessor gate"
  pass "a changed contract invalidates prior gate authority"
}

write_workgraph_meta() {
  local home=$1 fixture=$2 token=$3 holder_pid=$4 holder_start=$5
  local graph_sha contract_sha registry_sha
  graph_sha=$(sha256sum "$fixture/graph.json" | awk '{print $1}')
  contract_sha=$(sha256sum "$fixture/contracts/a.json" | awk '{print $1}')
  registry_sha=$(sha256sum "$fixture/registry.json" | awk '{print $1}')
  fm_write_meta "$home/state/a.meta" \
    "window=firstmate:fm-a" \
    "endpoint_task_id=a" \
    "worktree=$fixture/wt-a" \
    "project=$fixture/project" \
    "harness=codex" \
    "kind=ship" \
    "mode=local-only" \
    "workgraph_goal=gate-goal" \
    "workgraph_slice=a" \
    "workgraph_wave=0" \
    "workgraph_graph=$fixture/graph.json" \
    "workgraph_graph_sha256=$graph_sha" \
    "workgraph_contract_sha256=$contract_sha" \
    "workgraph_registry=$fixture/registry.json" \
    "workgraph_registry_sha256=$registry_sha" \
    "workgraph_lease_id=a" \
    "workgraph_fencing_token=$token" \
    "workgraph_holder_pid=$holder_pid" \
    "workgraph_holder_start_ticks=$holder_start"
}

test_teardown_waits_for_gates_then_releases_lease() {
  local fixture="$TMP_ROOT/teardown-fixture" home="$TMP_ROOT/teardown-home"
  local acquire token holder_start out rc
  make_fixture "$fixture"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin"
  sleep 2147483647 &
  GATE_HOLDER_PID=$!
  acquire=$(FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" acquire \
    "$fixture/graph.json" a --registry "$fixture/registry.json" \
    --lease-id a --holder-id a --holder-pid "$GATE_HOLDER_PID")
  token=$(printf '%s' "$acquire" | node -e 'process.stdout.write(JSON.parse(process.argv[1]).holder_fencing_token)' "$acquire")
  holder_start=$(awk '{print $22}' "/proc/$GATE_HOLDER_PID/stat")
  write_workgraph_meta "$home" "$fixture" "$token" "$GATE_HOLDER_PID" "$holder_start"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-teardown.sh" a --force 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown removed a WorkGraph task with pending gates"
  assert_contains "$out" 'WorkGraph gates or evidence are pending' \
    "pending teardown refusal diagnostic changed"
  assert_present "$home/state/a.meta" "pending teardown removed task metadata"
  FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" inspect gate-goal --lease-id a \
    | grep -q '"state":"held"' || fail "pending teardown released the held lease"

  printf 'pass\n' >"$fixture/pass.txt"
  FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" record-gate "$fixture/graph.json" a unit \
    --status passed --evidence "$fixture/pass.txt" --actor validator-a >/dev/null
  printf '#!/usr/bin/env bash\nexit 0\n' >"$home/fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$home/fakebin/treehouse"
  chmod +x "$home/fakebin/tmux" "$home/fakebin/treehouse"
  printf 'done: gate complete\n' >"$home/state/a.status"
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-crew-state.sh" a)
  assert_contains "$out" 'workgraph: gate-goal/a wave=0' \
    "crew state omitted goal/slice/wave"
  assert_contains "$out" 'claims=[{"resource":"lock://gate-a","mode":"write"}]' \
    "crew state omitted claims"
  assert_contains "$out" 'lease=held/a#' \
    "crew state omitted held lease and fencing token"
  assert_contains "$out" 'gates=passed:1' \
    "crew state omitted gate summary"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-teardown.sh" a --force >/dev/null \
    || fail "completed WorkGraph teardown failed"
  [ ! -e "$home/state/a.meta" ] || fail "completed WorkGraph teardown retained metadata"
  FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" inspect gate-goal --lease-id a --history \
    | tail -1 | grep -q '"state":"released"' \
    || fail "completed WorkGraph teardown did not terminally release its lease"
  pass "teardown preserves pending WorkGraph work and releases only after completion"
}

test_slice7_schemas_are_closed_and_versioned
test_gate_history_dependency_and_idempotence
test_gate_actor_evidence_and_corruption_fail_closed
test_snapshot_is_content_addressed_and_clean_only
test_contract_change_stales_prior_gate
test_teardown_waits_for_gates_then_releases_lease

#!/usr/bin/env bash
# Slice-8 migration inventory, disposable-state reconstruction, and runtime trigger tests.
# shellcheck disable=SC1091,SC2016,SC2153
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-workgraph-migrate)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
SLEEP_PID=
trap 'if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null || true; wait "$SLEEP_PID" 2>/dev/null || true; fi; fm_test_cleanup' EXIT

make_fixture() {
  local root=$1
  mkdir -p "$root/wt"
  node - "$root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = process.argv[2];
const contract = {
  schema_version: "slice-contract/v1",
  slice_id: "slice-a",
  goal_id: "migration-goal",
  purpose: "Verify Slice-8 migration and state reconstruction.",
  type: "ship",
  depends_on: [],
  immutable_inputs: [],
  outputs: ["out/slice-a.txt"],
  claims: [{resource: "lock://migration-a", mode: "write"}],
  worktree: path.join(root, "wt"),
  harness: "codex",
  model: "gpt-test",
  effort: "high",
  acceptance: ["Migration status is exact."],
  validation_commands: ["true"],
  expected_evidence: ["migration-status.json"],
  context_budget: {source_tokens: 100, report_words: 100},
  gates: ["unit"],
  implementer: "worker",
  independent_validators: ["validator"],
  authorized_exceptions: [],
};
const contractBytes = Buffer.from(JSON.stringify(contract, null, 2) + "\n");
fs.writeFileSync(path.join(root, "contract.json"), contractBytes);
fs.writeFileSync(path.join(root, "graph.json"), JSON.stringify({
  schema_version: "workgraph/v1",
  goal_id: "migration-goal",
  slices: [{
    slice_id: "slice-a",
    contract_path: "contract.json",
    contract_sha256: crypto.createHash("sha256").update(contractBytes).digest("hex"),
  }],
}, null, 2) + "\n");
fs.writeFileSync(path.join(root, "registry.json"), JSON.stringify({
  schema_version: "resource-registry/v1",
  instances: [{
    id: "migration-a",
    namespace: "lock",
    resource: "lock://migration-a",
    aliases: [],
    contains: [],
  }],
}, null, 2) + "\n");
NODE
}

seed_held_binding() {
  local fixture=$1 home=$2 token graph_sha contract_sha registry_sha
  mkdir -p "$home/state" "$home/data"
  token=$(FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" acquire \
    "$fixture/graph.json" slice-a \
    --registry "$fixture/registry.json" \
    --lease-id slice-a \
    --holder-id slice-a \
    --holder-pid "$$" |
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).holder_fencing_token))') \
    || fail "could not seed held WorkGraph lease"
  graph_sha=$(sha256sum "$fixture/graph.json" | awk '{print $1}')
  contract_sha=$(sha256sum "$fixture/contract.json" | awk '{print $1}')
  registry_sha=$(sha256sum "$fixture/registry.json" | awk '{print $1}')
  fm_write_meta "$home/state/slice-a.meta" \
    "window=fm-slice-a" \
    "endpoint_task_id=slice-a" \
    "worktree=$fixture/wt" \
    "project=$fixture" \
    "harness=codex" \
    "kind=ship" \
    "mode=local-only" \
    "yolo=off" \
    "model=gpt-test" \
    "effort=high" \
    "workgraph_goal=migration-goal" \
    "workgraph_slice=slice-a" \
    "workgraph_wave=0" \
    "workgraph_graph=$fixture/graph.json" \
    "workgraph_graph_sha256=$graph_sha" \
    "workgraph_contract_sha256=$contract_sha" \
    "workgraph_registry=$fixture/registry.json" \
    "workgraph_registry_sha256=$registry_sha" \
    "workgraph_lease_id=slice-a" \
    "workgraph_fencing_token=$token"
}

run_migrate() {
  local home=$1
  shift
  set +e
  OUTPUT=$(FM_HOME="$home" "$ROOT/bin/fm-workgraph-migrate.sh" "$@" 2>&1)
  RC=$?
  set -e
}

manifest_files() {
  local root=$1
  if [ ! -d "$root" ]; then
    return 0
  fi
  find "$root" -type f -print0 |
    LC_ALL=C sort -z |
    xargs -0 -r sha256sum
}

test_inventory_is_read_only_and_fail_closed() {
  local fixture="$TMP_ROOT/inventory-fixture" home="$TMP_ROOT/inventory-home"
  local before="$TMP_ROOT/inventory-before" after="$TMP_ROOT/inventory-after"
  make_fixture "$fixture"
  seed_held_binding "$fixture" "$home"
  fm_write_meta "$home/state/legacy.meta" \
    "window=fm-legacy" \
    "endpoint_task_id=legacy" \
    "worktree=$fixture/legacy"
  manifest_files "$home/state" >"$before"
  run_migrate "$home" status
  expect_code 0 "$RC" "migration inventory with one bound and one legacy task"
  printf '%s' "$OUTPUT" | node -e '
    let s = "";
    process.stdin.on("data", d => s += d).on("end", () => {
      const value = JSON.parse(s);
      if (value.schema_version !== "workgraph-migration-status/v1"
          || value.task_count !== 2 || value.workgraph_count !== 1
          || value.legacy_exclusive_count !== 1 || value.invalid_count !== 0
          || value.tasks[0].task_id !== "legacy"
          || value.tasks[0].classification !== "legacy-exclusive"
          || value.tasks[1].task_id !== "slice-a"
          || value.tasks[1].classification !== "workgraph") process.exit(1);
    });' || fail "migration inventory classification changed"
  manifest_files "$home/state" >"$after"
  cmp -s "$before" "$after" || fail "migration status rewrote active metadata or volatile state"

  fm_write_meta "$home/state/partial.meta" \
    "window=fm-partial" \
    "workgraph_goal=migration-goal"
  run_migrate "$home" status
  [ "$RC" -ne 0 ] || fail "partial WorkGraph metadata was accepted"
  printf '%s' "$OUTPUT" | node -e '
    let s = "";
    process.stdin.on("data", d => s += d).on("end", () => {
      const value = JSON.parse(s);
      const partial = value.tasks.find(task => task.task_id === "partial");
      if (value.invalid_count !== 1
          || partial.classification !== "invalid"
          || partial.reason !== "partial-or-unknown-workgraph-binding") process.exit(1);
    });' || fail "partial WorkGraph status did not fail closed clearly"
  pass "migration status is read-only and classifies WorkGraph, legacy, and invalid metadata"
}

test_runtime_projection_reconstructs_from_durable_data() {
  local fixture="$TMP_ROOT/rebuild-fixture" home="$TMP_ROOT/rebuild-home"
  local data_before="$TMP_ROOT/data-before" data_after="$TMP_ROOT/data-after"
  local first projection first_bytes second second_projection
  make_fixture "$fixture"
  seed_held_binding "$fixture" "$home"
  manifest_files "$home/data" >"$data_before"
  rm -rf "$home/state"
  run_migrate "$home" rebuild-state "$fixture/graph.json"
  expect_code 0 "$RC" "first state reconstruction"
  first=$OUTPUT
  projection=$(printf '%s' "$first" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).projection))')
  assert_present "$projection" "state projection was not published"
  grep -qx 'lease_cache=reconstructed' "$projection" \
    || fail "lease cache was not reconstructed from durable records"
  first_bytes="$TMP_ROOT/first-projection"
  cp "$projection" "$first_bytes"
  rm -rf "$home/state"
  run_migrate "$home" rebuild-state "$fixture/graph.json"
  expect_code 0 "$RC" "second state reconstruction"
  second=$OUTPUT
  second_projection=$(printf '%s' "$second" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).projection))')
  cmp -s "$first_bytes" "$second_projection" \
    || fail "same durable inputs rebuilt different projection bytes"
  [ "$(printf '%s' "$first" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).sha256))')" = \
    "$(printf '%s' "$second" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).sha256))')" ] \
    || fail "same durable inputs rebuilt different projection hashes"
  manifest_files "$home/data" >"$data_after"
  cmp -s "$data_before" "$data_after" || fail "state reconstruction changed durable authority"
  pass "disposable WorkGraph state reconstructs byte-identically from durable inputs"
}

test_mode_change_preserves_live_task() {
  local home="$TMP_ROOT/mode-home" before after
  mkdir -p "$home/state"
  fm_write_meta "$home/state/live.meta" \
    "window=fm-live" \
    "endpoint_task_id=live" \
    "worktree=$TMP_ROOT/live"
  before=$(sha256sum "$home/state/live.meta" | awk '{print $1}')
  sleep 30 &
  SLEEP_PID=$!
  FM_HOME="$home" "$ROOT/bin/fm-parallelism.sh" set off >/dev/null \
    || fail "could not set isolated off mode"
  FM_HOME="$home" "$ROOT/bin/fm-parallelism.sh" set on >/dev/null \
    || fail "could not restore isolated on mode"
  kill -0 "$SLEEP_PID" 2>/dev/null || fail "mode change killed an active process"
  after=$(sha256sum "$home/state/live.meta" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "mode change rewrote active task metadata"
  [ "$(FM_HOME="$home" "$ROOT/bin/fm-parallelism.sh" get)" = on ] \
    || fail "canonical on mode was not persisted"
  kill "$SLEEP_PID" 2>/dev/null || true
  wait "$SLEEP_PID" 2>/dev/null || true
  SLEEP_PID=
  pass "parallelism changes affect future admissions without killing or rewriting active work"
}

test_runtime_trigger_and_documentation() {
  if ! node - "$ROOT/schemas/workgraph" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const expected = {
  "migration-status-v1.json": "workgraph-migration-status/v1",
  "state-rebuild-result-v1.json": "workgraph-state-rebuild/v1",
};
for (const [name, version] of Object.entries(expected)) {
  const schema = JSON.parse(fs.readFileSync(path.join(process.argv[2], name), "utf8"));
  if (schema.type !== "object" || schema.additionalProperties !== false
      || !Array.isArray(schema.required)
      || schema.properties.schema_version.const !== version) process.exit(1);
}
NODE
  then
    fail "Slice-8 command-result schemas are not closed and versioned"
  fi
  assert_grep 'load `feature-slicing` and then `workgraph-orchestration`' \
    "$ROOT/AGENTS.md" "AGENTS.md lacks the mandatory WorkGraph intake trigger"
  assert_grep 'Firstmate alone may integrate or publish canonical bytes' \
    "$ROOT/.agents/skills/workgraph-orchestration/SKILL.md" \
    "WorkGraph skill lacks the canonical integration invariant"
  assert_grep 'Legacy active tasks without a complete lease-backed WorkGraph binding are broadly exclusive.' \
    "$ROOT/.agents/skills/workgraph-orchestration/SKILL.md" \
    "WorkGraph skill lacks the legacy-exclusive invariant"
  assert_grep 'WorkGraph storage and parallelism' "$ROOT/docs/configuration.md" \
    "configuration documentation lacks WorkGraph storage ownership"
  assert_grep 'fm-workgraph-migrate.sh' "$ROOT/docs/scripts.md" \
    "script inventory lacks WorkGraph migration"
  assert_grep 'Contract-bound brief and dispatch enforcement' "$ROOT/docs/workgraph.md" \
    "WorkGraph documentation lacks the enforcement contract"
  if [ -x "$ROOT/bin/fm-doc-audience-check.sh" ]; then
    "$ROOT/bin/fm-doc-audience-check.sh" >/dev/null \
      || fail "documentation audience inventory rejected WorkGraph Slice 8"
  fi
  pass "the intake trigger, internal skill, and maintained documentation are wired"
}

test_inventory_is_read_only_and_fail_closed
test_runtime_projection_reconstructs_from_durable_data
test_mode_change_preserves_live_task
test_runtime_trigger_and_documentation

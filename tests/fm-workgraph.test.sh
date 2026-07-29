#!/usr/bin/env bash
# Focused hermetic tests for Slice-2 parallelism modes and one-node WorkGraphs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PARALLELISM_OVERRIDE NODE_OPTIONS

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-workgraph.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

sha_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

new_home() {
  TEST_HOME=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$TEST_HOME/state"
}

run_parallelism() {
  set +e
  OUTPUT=$(FM_HOME="$TEST_HOME" "$ROOT/bin/fm-parallelism.sh" "$@" 2>&1)
  RC=$?
  set -e
}

run_workgraph() {
  set +e
  OUTPUT=$({ "$ROOT/bin/fm-workgraph.sh" "$@"; } 2>&1)
  RC=$?
  set -e
}

write_valid_graph() {
  local root=$1 contract digest
  mkdir -p "$root/contracts"
  contract="$root/contracts/slice-1.json"
  cat > "$contract" <<'JSON'
{
  "schema_version": "slice-contract/v1",
  "slice_id": "slice-1",
  "goal_id": "goal-1",
  "purpose": "Validate the Slice-2 implementation.",
  "type": "ship",
  "depends_on": [],
  "immutable_inputs": [{"path": "input.txt", "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}],
  "outputs": ["report.md"],
  "claims": [{"resource": "path://reports/slice-1", "mode": "write"}],
  "worktree": "/tmp/workgraph-slice-1",
  "harness": "codex",
  "model": "test-model",
  "effort": "high",
  "acceptance": ["The graph validates."],
  "validation_commands": ["bin/fm-workgraph.sh validate graph.json"],
  "expected_evidence": ["The exact contract digest is recorded."],
  "context_budget": {"source_tokens": 45000, "report_words": 3000},
  "gates": ["tests-green"],
  "implementer": "crew-1",
  "independent_validators": ["validator-1"],
  "authorized_exceptions": []
}
JSON
  digest=$(sha_file "$contract")
  cat > "$root/graph.json" <<JSON
{
  "schema_version": "workgraph/v1",
  "goal_id": "goal-1",
  "slices": [{"slice_id": "slice-1", "contract_path": "contracts/slice-1.json", "contract_sha256": "$digest"}]
}
JSON
}

mutate_json() {
  local source=$1 target=$2 mutation=$3
  node - "$source" "$target" "$mutation" <<'NODE'
const fs = require("node:fs");
const source = process.argv[2];
const target = process.argv[3];
const mutation = process.argv[4];
const text = fs.readFileSync(source, "utf8");
if (mutation === "duplicate-root") {
  fs.writeFileSync(target, text.replace(
    '"goal_id": "goal-1",',
    '"goal_id": "goal-1",\n  "goal_id": "goal-1",',
  ));
  process.exit(0);
}
if (mutation === "duplicate-reference") {
  fs.writeFileSync(target, text.replace(
    '"contract_path": "contracts/slice-1.json",',
    '"contract_path": "contracts/slice-1.json", "contract_path": "contracts/slice-1.json",',
  ));
  process.exit(0);
}
const value = JSON.parse(text);
if (mutation === "unknown-schema") value.schema_version = "workgraph/v99";
if (mutation === "missing-field") delete value.slices;
if (mutation === "multiple-nodes") value.slices.push({...value.slices[0], slice_id: "slice-2"});
if (mutation === "unsafe-id") value.goal_id = "../unsafe";
if (mutation === "bad-hash") value.slices[0].contract_sha256 = "0".repeat(64);
if (mutation === "unknown-root") value.unexpected = true;
if (mutation === "unknown-reference") value.slices[0].unexpected = true;
if (mutation === "control-path-lf") value.slices[0].contract_path = "contracts/\nslice-1.json";
if (mutation === "control-path-cr") value.slices[0].contract_path = "contracts/\rslice-1.json";
if (mutation === "control-path-del") value.slices[0].contract_path = "contracts/\u007fslice-1.json";
if (mutation === "control-path-c1") value.slices[0].contract_path = "contracts/\u0085slice-1.json";
if (mutation === "control-path-line-separator") value.slices[0].contract_path = "contracts/\u2028slice-1.json";
if (mutation === "control-path-paragraph-separator") value.slices[0].contract_path = "contracts/\u2029slice-1.json";
fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n");
NODE
}

mutate_contract_case() {
  local root=$1 mutation=$2 contract="$1/contracts/slice-1.json" digest
  node - "$contract" "$contract.tmp" "$mutation" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const target = process.argv[3];
const mutation = process.argv[4];
const text = fs.readFileSync(file, "utf8");
if (mutation === "duplicate-root") {
  fs.writeFileSync(target, text.replace(
    '"purpose": "Validate the Slice-2 implementation.",',
    '"purpose": "Validate the Slice-2 implementation.",\n  "purpose": "Validate the Slice-2 implementation.",',
  ));
  process.exit(0);
}
if (mutation === "duplicate-claim") {
  fs.writeFileSync(target, text.replace(
    '"mode": "write"',
    '"mode": "write", "mode": "write"',
  ));
  process.exit(0);
}
const value = JSON.parse(text);
if (mutation === "bad-claim") value.claims[0].mode = "bogus";
if (mutation === "missing-field") delete value.acceptance;
if (mutation === "bad-contract-schema") value.schema_version = "slice-contract/v99";
if (mutation === "object-output") value.outputs = [{path: "report.md"}];
if (mutation === "unknown-root") value.unexpected = true;
if (mutation === "unknown-input") value.immutable_inputs[0].unexpected = true;
if (mutation === "unknown-claim") value.claims[0].unexpected = true;
if (mutation === "unknown-context") value.context_budget.unexpected = true;
if (mutation === "unsafe-source-tokens") value.context_budget.source_tokens = 9007199254740992;
if (mutation === "unsafe-report-words") value.context_budget.report_words = 9007199254740992;
fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n");
NODE
  mv "$contract.tmp" "$contract"
  digest=$(sha_file "$contract")
  node - "$root/graph.json" "$root/graph.json.tmp" "$digest" <<'NODE'
const fs = require("node:fs");
const graph = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
graph.slices[0].contract_sha256 = process.argv[4];
fs.writeFileSync(process.argv[3], JSON.stringify(graph, null, 2) + "\n");
NODE
  mv "$root/graph.json.tmp" "$root/graph.json"
}

test_mode_round_trips() {
  local mode
  new_home
  for mode in off eco on max; do
    run_parallelism set "$mode"
    expect_code 0 "$RC" "set $mode succeeds"
    [ "$OUTPUT" = "$mode" ] || fail "set $mode output is not canonical"
    [ "$(cat "$TEST_HOME/config/parallelism")" = "$mode" ] || fail "set $mode persistence mismatch"
    run_parallelism get
    expect_code 0 "$RC" "get $mode succeeds"
    [ "$OUTPUT" = "$mode" ] || fail "get $mode round-trip mismatch"
  done
  pass "parallelism: all canonical modes round-trip"
}

test_auto_and_invalid_values() {
  new_home
  run_parallelism get
  expect_code 0 "$RC" "absent configuration resolves to the non-enforcing default"
  [ "$OUTPUT" = on ] || fail "absent configuration did not resolve to on"
  [ ! -e "$TEST_HOME/config/parallelism" ] || fail "get materialized the default global mode"
  run_parallelism status
  assert_contains "$OUTPUT" 'source=default' "status did not identify the absent default"
  [ ! -e "$TEST_HOME/config/parallelism" ] || fail "status materialized the default global mode"
  run_parallelism set auto
  expect_code 0 "$RC" "auto is accepted"
  [ "$OUTPUT" = on ] || fail "auto output was not canonical on"
  [ "$(cat "$TEST_HOME/config/parallelism")" = on ] || fail "auto was not persisted as on"
  printf 'auto\n' > "$TEST_HOME/config/parallelism"
  run_parallelism get
  [ "$RC" -ne 0 ] || fail "manually persisted auto was accepted"
  run_parallelism set invalid
  [ "$RC" -ne 0 ] || fail "invalid mode was accepted"
  printf 'invalid\n' > "$TEST_HOME/config/parallelism"
  run_parallelism get
  [ "$RC" -ne 0 ] || fail "invalid persisted mode was accepted"
  run_parallelism set off --project '../unsafe'
  [ "$RC" -ne 0 ] || fail "unsafe project id was accepted"
  pass "parallelism: auto canonicalization and invalid values fail closed"
}

test_precedence_and_scopes() {
  new_home
  run_parallelism set off
  run_parallelism set eco --project project-1
  run_parallelism set max --goal goal-1
  run_parallelism get --goal goal-1 --project project-1
  expect_code 0 "$RC" "goal precedence succeeds"
  [ "$OUTPUT" = max ] || fail "goal did not override project and global"
  run_parallelism get --project project-1
  [ "$OUTPUT" = eco ] || fail "project did not override global"
  run_parallelism status --goal goal-1 --project project-1
  assert_contains "$OUTPUT" 'goal=max' "status omitted goal scope"
  assert_contains "$OUTPUT" 'project=eco' "status omitted project scope"
  assert_contains "$OUTPUT" 'global=off' "status omitted global scope"
  run_parallelism get --project project-1 --request auto
  [ "$OUTPUT" = on ] || fail "request did not override goal/project/global"
  run_parallelism status --goal goal-1 --project project-1 --request auto
  assert_contains "$OUTPUT" 'goal=uninspected' "request status misreported the goal scope"
  assert_contains "$OUTPUT" 'project=uninspected' "request status misreported the project scope"
  assert_contains "$OUTPUT" 'global=uninspected' "request status misreported the global scope"
  FM_PARALLELISM_OVERRIDE=off run_parallelism get --project project-1
  [ "$OUTPUT" = off ] || fail "environment request override did not win"
  pass "parallelism: request > goal > project > global"
}

test_goal_identifier_alignment() {
  local goal_id
  new_home
  for goal_id in .goal _goal -goal 'égoal'; do
    run_parallelism set off --goal "$goal_id"
    [ "$RC" -ne 0 ] || fail "goal id '$goal_id' was accepted"
  done
  [ ! -e "$TEST_HOME/data/workgraphs" ] || fail "invalid goal ids materialized goal configuration"
  pass "parallelism: goal selectors match WorkGraph goal identifiers"
}

test_atomic_scoped_and_metadata_unchanged() {
  local expected_meta expected_fixture
  new_home
  expected_meta="$TEST_HOME/expected-task-1.meta"
  expected_fixture="$TEST_HOME/expected-process.fixture"
  printf 'window=fm-task-1\nmode=no-mistakes\n' > "$expected_meta"
  printf 'process-fixture\n' > "$expected_fixture"
  printf 'window=fm-task-1\nmode=no-mistakes\n' > "$TEST_HOME/state/task-1.meta"
  printf 'process-fixture\n' > "$TEST_HOME/state/process.fixture"
  run_parallelism set eco --goal goal-1
  expect_code 0 "$RC" "goal write succeeds"
  [ -f "$TEST_HOME/data/workgraphs/goal-1/parallelism" ] || fail "goal value missing"
  [ ! -e "$TEST_HOME/config/parallelism" ] || fail "goal write touched global scope"
  [ ! -e "$TEST_HOME/config/parallelism-projects/goal-1" ] || fail "goal write touched project scope"
  find "$TEST_HOME/data/workgraphs/goal-1" -name '.parallelism.tmp.*' -print -quit | grep -q . && fail "temporary file leaked"
  cmp -s "$expected_meta" "$TEST_HOME/state/task-1.meta" || fail "task metadata bytes changed"
  cmp -s "$expected_fixture" "$TEST_HOME/state/process.fixture" || fail "process fixture bytes changed"
  [ "$(find "$TEST_HOME/state" -type f | wc -l | tr -d ' ')" = 2 ] || fail "parallelism created active-state files"
  pass "parallelism: scoped atomic write leaves task fixtures unchanged"
}

test_nonregular_mode_targets() {
  new_home
  mkdir -p "$TEST_HOME/config"
  ln -s missing "$TEST_HOME/config/parallelism"
  run_parallelism get
  [ "$RC" -ne 0 ] || fail "dangling mode symlink was read as absent"
  run_parallelism set off
  [ "$RC" -ne 0 ] || fail "dangling mode symlink accepted a publish"
  rm "$TEST_HOME/config/parallelism"
  mkdir "$TEST_HOME/config/parallelism"
  run_parallelism get
  [ "$RC" -ne 0 ] || fail "mode directory was accepted for reading"
  run_parallelism set off
  [ "$RC" -ne 0 ] || fail "mode directory accepted a publish"
  find "$TEST_HOME/config/parallelism" -name '.parallelism.tmp.*' -print -quit | grep -q . \
    && fail "mode directory received a temporary file"
  rmdir "$TEST_HOME/config/parallelism"
  mkfifo "$TEST_HOME/config/parallelism"
  run_parallelism get
  [ "$RC" -ne 0 ] || fail "mode fifo was accepted for reading"
  run_parallelism set off
  [ "$RC" -ne 0 ] || fail "mode fifo accepted a publish"
  pass "parallelism: non-regular persisted targets are rejected"
}

test_valid_graph_and_status() {
  local root
  root=$(mktemp -d "$TMP_ROOT/valid.XXXXXX")
  write_valid_graph "$root"
  run_workgraph validate "$root/graph.json"
  expect_code 0 "$RC" "valid graph validates"
  [ -z "$OUTPUT" ] || fail "validate should not print a success placeholder"
  run_workgraph status "$root/graph.json"
  expect_code 0 "$RC" "valid graph status succeeds"
  assert_contains "$OUTPUT" 'valid=true' "status reports valid graph"
  assert_contains "$OUTPUT" 'slice_count=1' "status reports one node"
  assert_contains "$OUTPUT" 'contract_verified=true' "status verifies contract binding"
  assert_contains "$OUTPUT" 'enforcement=disabled' "status reports non-enforcement"
  pass "workgraph: valid one-node graph and bound contract"
}

test_graph_negative_cases() {
  local mutation root case_root
  for mutation in \
    unknown-schema missing-field multiple-nodes unsafe-id bad-hash \
    unknown-root unknown-reference duplicate-root duplicate-reference
  do
    case_root=$(mktemp -d "$TMP_ROOT/$mutation.XXXXXX")
    write_valid_graph "$case_root"
    mutate_json "$case_root/graph.json" "$case_root/bad.json" "$mutation"
    run_workgraph validate "$case_root/bad.json"
    [ "$RC" -ne 0 ] || fail "$mutation graph was accepted"
  done
  for mutation in \
    bad-contract-schema bad-claim missing-field object-output \
    unknown-root unknown-input unknown-claim unknown-context \
    duplicate-root duplicate-claim unsafe-source-tokens unsafe-report-words
  do
    root=$(mktemp -d "$TMP_ROOT/contract-$mutation.XXXXXX")
    write_valid_graph "$root"
    mutate_contract_case "$root" "$mutation"
    run_workgraph validate "$root/graph.json"
    [ "$RC" -ne 0 ] || fail "$mutation contract was accepted"
  done
  pass "workgraph: schema, field, node-count, id, hash, and claim negatives reject"
}

test_contract_path_control_characters() {
  local mutation case_root
  for mutation in \
    control-path-lf control-path-cr control-path-del control-path-c1 \
    control-path-line-separator control-path-paragraph-separator
  do
    case_root=$(mktemp -d "$TMP_ROOT/$mutation.XXXXXX")
    write_valid_graph "$case_root"
    mutate_json "$case_root/graph.json" "$case_root/bad.json" "$mutation"
    run_workgraph status "$case_root/bad.json"
    [ "$RC" -ne 0 ] || fail "$mutation contract path was accepted"
    assert_contains "$OUTPUT" 'WG-E-ID' "$mutation did not reject as an unsafe path"
  done
  pass "workgraph: contract paths reject control characters before status"
}

test_contract_bytes_captured_once() {
  local root preload contract
  root=$(mktemp -d "$TMP_ROOT/captured.XXXXXX")
  write_valid_graph "$root"
  preload="$root/mutate-after-read.cjs"
  contract="$root/contracts/slice-1.json"
  cat > "$preload" <<'NODE'
const fs = require("node:fs");
const originalRead = fs.readFileSync;
let mutated = false;
fs.readFileSync = function readFileSync(target, ...args) {
  const value = originalRead.call(this, target, ...args);
  const text = Buffer.isBuffer(value) ? value.toString("utf8") : value;
  if (!mutated && text.includes('"schema_version": "slice-contract/v1"')) {
    mutated = true;
    const contract = process.env.WORKGRAPH_RACE_CONTRACT;
    const changed = originalRead.call(this, contract, "utf8")
      .replace("slice-contract/v1", "slice-contract/v99");
    fs.writeFileSync(contract, changed);
  }
  return value;
};
NODE
  NODE_OPTIONS="--require=$preload" WORKGRAPH_RACE_CONTRACT="$contract" \
    run_workgraph validate "$root/graph.json"
  expect_code 0 "$RC" "validator hashes and parses one captured contract sequence"
  grep -q 'slice-contract/v99' "$contract" || fail "contract mutation seam did not run"
  pass "workgraph: contract hash and parse share one captured byte sequence"
}

test_schema_strictness() {
  node - "$ROOT/schemas/workgraph/workgraph-v1.json" \
    "$ROOT/schemas/workgraph/slice-contract-v1.json" \
    "$ROOT/schemas/workgraph/parallelism-v1.json" <<'NODE'
const fs = require("node:fs");
const [graphPath, contractPath, parallelismPath] = process.argv.slice(2);
const graph = JSON.parse(fs.readFileSync(graphPath, "utf8"));
const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
const parallelism = JSON.parse(fs.readFileSync(parallelismPath, "utf8"));
function requireStrictObjects(schema, name) {
  if (schema === null || typeof schema !== "object") return;
  if (schema.type === "object" && schema.additionalProperties !== false) {
    throw new Error(`${name} permits additional properties`);
  }
  if (schema.properties) {
    for (const [key, value] of Object.entries(schema.properties)) {
      requireStrictObjects(value, `${name}.properties.${key}`);
    }
  }
  if (schema.items) requireStrictObjects(schema.items, `${name}.items`);
}
requireStrictObjects(graph, "workgraph");
requireStrictObjects(contract, "slice-contract");
if (contract.properties.outputs.items.type !== "string") {
  throw new Error("slice-contract outputs are not strings");
}
if (parallelism.enum.includes("auto")) {
  throw new Error("persisted parallelism schema permits auto");
}
const pathPattern = new RegExp(graph.properties.slices.items.properties.contract_path.pattern, "u");
for (const separator of ["\u2028", "\u2029"]) {
  if (pathPattern.test(`contracts/${separator}slice-1.json`)) {
    throw new Error("workgraph schema permits a Unicode line separator");
  }
}
for (const field of ["source_tokens", "report_words"]) {
  if (contract.properties.context_budget.properties[field].maximum !== Number.MAX_SAFE_INTEGER) {
    throw new Error(`slice-contract ${field} exceeds the executable safe-integer limit`);
  }
}
NODE
  pass "schemas: object shapes and persisted modes are strict"
}

test_mode_round_trips
test_auto_and_invalid_values
test_precedence_and_scopes
test_goal_identifier_alignment
test_atomic_scoped_and_metadata_unchanged
test_nonregular_mode_targets
test_valid_graph_and_status
test_graph_negative_cases
test_contract_path_control_characters
test_contract_bytes_captured_once
test_schema_strictness

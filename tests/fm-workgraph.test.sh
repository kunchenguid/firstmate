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
if (mutation === "integral-number-forms") {
  fs.writeFileSync(target, text.replace(
    '"context_budget": {"source_tokens": 45000, "report_words": 3000},',
    '"context_budget": {"source_tokens": 1.0, "report_words": 1e0},',
  ));
  process.exit(0);
}
if (mutation === "rounded-noninteger") {
  fs.writeFileSync(target, text.replace(
    '"source_tokens": 45000',
    '"source_tokens": 1.0000000000000001',
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
  FM_PARALLELISM_OVERRIDE=auto run_parallelism get
  [ "$RC" -ne 0 ] || fail "environment auto alias was accepted"
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

test_exact_context_budget_numbers() {
  local root
  root=$(mktemp -d "$TMP_ROOT/integral-number-forms.XXXXXX")
  write_valid_graph "$root"
  mutate_contract_case "$root" integral-number-forms
  run_workgraph validate "$root/graph.json"
  expect_code 0 "$RC" "mathematically integral decimal and exponent forms validate"

  root=$(mktemp -d "$TMP_ROOT/rounded-noninteger.XXXXXX")
  write_valid_graph "$root"
  mutate_contract_case "$root" rounded-noninteger
  run_workgraph validate "$root/graph.json"
  [ "$RC" -ne 0 ] || fail "rounded non-integral context budget was accepted"
  pass "workgraph: context budgets use exact numeric lexemes"
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
    "$ROOT/schemas/workgraph/parallelism-v1.json" \
    "$ROOT/schemas/workgraph/resource-registry-v1.json" <<'NODE'
const fs = require("node:fs");
const [graphPath, contractPath, parallelismPath, registryPath] = process.argv.slice(2);
const graph = JSON.parse(fs.readFileSync(graphPath, "utf8"));
const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
const parallelism = JSON.parse(fs.readFileSync(parallelismPath, "utf8"));
const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
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
requireStrictObjects(registry, "resource-registry");
if (contract.properties.outputs.items.type !== "string") {
  throw new Error("slice-contract outputs are not strings");
}
if (parallelism.enum.includes("auto")) {
  throw new Error("persisted parallelism schema permits auto");
}
if (registry.properties.schema_version.const !== "resource-registry/v1") {
  throw new Error("resource registry schema version is not strict");
}
if (JSON.stringify(registry.$defs.instance.required) !== JSON.stringify(["id", "namespace", "resource", "aliases", "contains"])) {
  throw new Error("resource registry instance required fields are incomplete");
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

test_resource_namespace_matrix() {
  local resource expected
  while IFS='|' read -r resource expected; do
    [ -n "$resource" ] || continue
    run_workgraph normalize "$resource"
    expect_code 0 "$RC" "normalize accepts $resource"
    [ "$OUTPUT" = "$expected" ] || fail "normalization mismatch for $resource: $OUTPUT"
  done <<'CASES'
path:///tmp/./workgraph/../resource|path:///tmp/resource
branch://firstmate/fm-workgraph-s3-resource-normalization|branch://firstmate/fm-workgraph-s3-resource-normalization
worktree:///tmp/./workgraph/../resource|worktree:///tmp/resource
docker://project|docker://project
docker://network/net-1|docker://network/net-1
docker://volume/vol-1|docker://volume/vol-1
docker://container/container-1|docker://container/container-1
port://127.0.0.1/00080|port://127.0.0.1/80
port://[2001:0db8:0:0:0:0:0:1]/80|port://[2001:db8::1]/80
svc://SERVICE/account|svc://service/account
db://INSTANCE/schema|db://instance/schema
ui://PROFILE/session|ui://profile/session
lock://lock-1|lock://lock-1
CASES
  pass "resources: every namespace normalizes to a deterministic identifier"
}

test_resource_path_symlink_and_suffix() {
  local root link output
  root=$(mktemp -d "$TMP_ROOT/path.XXXXXX")
  mkdir -p "$root/real/existing"
  link="$root/alias"
  ln -s "$root/real" "$link"
  run_workgraph normalize "path://$link/existing/../new/./suffix"
  expect_code 0 "$RC" "path symlink and suffix normalize"
  output="$root/real/new/suffix"
  [ "$OUTPUT" = "path://$output" ] || fail "longest existing prefix was not resolved: $OUTPUT"
  [ ! -e "$root/real/new/suffix" ] || fail "normalization created a non-existent suffix"
  pass "resources: longest existing prefix symlink resolution preserves suffix"
}

test_resource_negative_matrix() {
  local resource
  for resource in \
    'path:///../../escape' 'path:///tmp//ambiguous' 'path://relative' \
    'worktree:///../escape' 'worktree://name' 'worktree://name/extra' 'docker://bogus/x' \
    'port://localhost/0' 'port://localhost/65536' 'port://localhost/not-port' \
    'port://localhost/1/extra' 'port://01.2.3.4/80' 'port://[2001:::1]/80' \
    'wat://resource' 'lock://name/extra' \
    $'lock://bad\nname' 'svc://service' 'ui://profile/session/extra'
  do
    run_workgraph normalize "$resource"
    [ "$RC" -ne 0 ] || fail "invalid resource was accepted: $resource"
    assert_contains "$OUTPUT" 'WG-R-' "invalid resource lacked a classifiable resource error: $resource"
  done
  pass "resources: traversal, controls, separators, ports, shapes, and unknown namespaces reject"
}

test_advisory_claim_lint() {
  local root claims
  root=$(mktemp -d "$TMP_ROOT/claims.XXXXXX")
  claims="$root/claims.json"
  node - "$claims" <<'NODE'
const fs = require("node:fs");
const output = process.argv[2];
fs.writeFileSync(output, JSON.stringify({
  schema_version: "resource-claims/v1",
  claims: [
    {resource: "path:///tmp/./claim", mode: "read"},
    {resource: "path:///tmp/claim", mode: "read"},
    {resource: "path:///tmp/claim", mode: "write"},
    {resource: "unknown://opaque", mode: "exclusive"},
    {resource: "port://localhost/0", mode: "read"},
  ],
}) + "\n");
NODE
  run_workgraph lint "$claims"
  expect_code 0 "$RC" "advisory lint returns a report for warnings"
  assert_contains "$OUTPUT" 'resource_lint=warn' "lint did not classify warnings"
  assert_contains "$OUTPUT" 'canonical_id_json="path:///tmp/claim"' "lint omitted canonical JSON ID"
  assert_contains "$OUTPUT" 'claim[3].effective_mode=exclusive' "unknown claim did not fail closed"
  assert_contains "$OUTPUT" 'claim[4].effective_scope=global' "malformed claim did not broaden globally"
  assert_contains "$OUTPUT" 'WG-W-CLAIM-DUPLICATE' "lint omitted duplicate warning"
  assert_contains "$OUTPUT" 'WG-W-CLAIM-CONFLICT' "lint omitted conflict warning"
  assert_contains "$OUTPUT" 'WG-W-RESOURCE-UNKNOWN' "lint omitted unknown warning"
  assert_contains "$OUTPUT" 'WG-W-RESOURCE-MALFORMED' "lint omitted malformed warning"
  pass "resources: advisory lint reports canonical IDs and stable warning classes"
}

test_status_resource_warning_is_non_enforcing() {
  local root
  root=$(mktemp -d "$TMP_ROOT/status-resource.XXXXXX")
  write_valid_graph "$root"
  node - "$root/contracts/slice-1.json" "$root/contracts/slice-1.tmp" <<'NODE'
const fs = require("node:fs");
const source = process.argv[2];
const target = process.argv[3];
const contract = JSON.parse(fs.readFileSync(source, "utf8"));
contract.claims.push({resource: "unknown://resource", mode: "read"});
fs.writeFileSync(target, JSON.stringify(contract, null, 2) + "\n");
NODE
  mv "$root/contracts/slice-1.tmp" "$root/contracts/slice-1.json"
  node - "$root/graph.json" "$root/graph.tmp" "$root/contracts/slice-1.json" <<'NODE'
const fs = require("node:fs");
const graph = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const crypto = require("node:crypto");
graph.slices[0].contract_sha256 = crypto.createHash("sha256").update(fs.readFileSync(process.argv[4])).digest("hex");
fs.writeFileSync(process.argv[3], JSON.stringify(graph, null, 2) + "\n");
NODE
  mv "$root/graph.tmp" "$root/graph.json"
  run_workgraph status "$root/graph.json"
  expect_code 0 "$RC" "status remains valid with an unknown resource"
  assert_contains "$OUTPUT" 'valid=true' "status stopped validating the graph"
  assert_contains "$OUTPUT" 'resource_lint=warn' "status omitted resource warning state"
  assert_contains "$OUTPUT" 'enforcement=disabled' "status lost the non-enforcement declaration"
  pass "resources: status warns without enforcing"
}

test_resource_registry_strictness() {
  local root
  root=$(mktemp -d "$TMP_ROOT/registry.XXXXXX")
  node - "$root/registry.json" <<'NODE'
const fs = require("node:fs");
  fs.writeFileSync(process.argv[2], JSON.stringify({
  schema_version: "resource-registry/v1",
  instances: [{
    id: "project-1",
    namespace: "docker",
    resource: "docker://project",
    aliases: [],
    contains: ["container-1", "port-1"],
  }, {
    id: "container-1",
    namespace: "docker",
    resource: "docker://container/app-1",
    aliases: [],
    contains: [],
  }, {
    id: "port-1",
    namespace: "port",
    resource: "port://localhost/8080",
    aliases: [],
    contains: [],
  }],
}) + "\n");
NODE
  run_workgraph registry "$root/registry.json"
  expect_code 0 "$RC" "strict resource registry validates"
  assert_contains "$OUTPUT" 'schema_version=resource-registry/v1' "registry omitted schema version"
  assert_contains "$OUTPUT" 'instance_count=3' "registry omitted instance count"
  node - "$root/bad.json" <<'NODE'
const fs = require("node:fs");
  fs.writeFileSync(process.argv[2], JSON.stringify({
  schema_version: "resource-registry/v1",
  instances: [{id: "project-1", namespace: "docker", resource: "docker://project", aliases: [], contains: [], unexpected: true}],
}) + "\n");
NODE
  run_workgraph registry "$root/bad.json"
  [ "$RC" -ne 0 ] || fail "registry unknown field was accepted"
  pass "schemas: resource registry is strict and validates broad-container relationships"
}

test_terminal_file_and_fs_errors() {
  local root file
  root=$(mktemp -d "$TMP_ROOT/terminal.XXXXXX")
  file="$root/terminal"
  printf 'terminal\n' > "$file"
  ln -s "$file" "$root/link"
  run_workgraph normalize "path://$file"
  expect_code 0 "$RC" "regular file is a valid terminal path"
  [ "$OUTPUT" = "path://$file" ] || fail "terminal file normalization changed identity: $OUTPUT"
  run_workgraph normalize "path://$root/link"
  expect_code 0 "$RC" "symlink to regular file is a valid terminal path"
  [ "$OUTPUT" = "path://$file" ] || fail "symlink-to-file normalization mismatch: $OUTPUT"
  run_workgraph normalize "path://$file/suffix"
  [ "$RC" -ne 0 ] || fail "suffix after regular file was accepted"
  assert_contains "$OUTPUT" 'WG-R-FS' "non-directory prefix lacked WG-R-FS"
  pass "resources: terminal files succeed and non-directory suffixes fail closed"
}

test_registry_projection_and_broadening() {
  local root registry claims
  root=$(mktemp -d "$TMP_ROOT/projection.XXXXXX")
  registry="$root/registry.json"
  claims="$root/claims.json"
  node - "$registry" "$claims" <<'NODE'
const fs = require("node:fs");
const [registry, claims] = process.argv.slice(2);
fs.writeFileSync(registry, JSON.stringify({
  schema_version: "resource-registry/v1",
  instances: [
    {id: "alias-target", namespace: "path", resource: "path:///tmp/alias-target", aliases: ["path:///tmp/alias-target/../alias"], contains: []},
    {id: "container-root", namespace: "path", resource: "path:///tmp/container-root", aliases: [], contains: []},
    {id: "amb-a", namespace: "path", resource: "path:///tmp/amb", aliases: [], contains: []},
    {id: "amb-b", namespace: "path", resource: "path:///tmp/amb/nested", aliases: [], contains: []},
  ],
}) + "\n");
fs.writeFileSync(claims, JSON.stringify({
  schema_version: "resource-claims/v1",
  claims: [
    {resource: "path:///tmp/alias-target/../alias", mode: "read"},
    {resource: "path:///tmp/container-root/new", mode: "read"},
    {resource: "path:///tmp/amb/nested/claim", mode: "read"},
    {resource: "unknown://raw-secret", mode: "write"},
    {resource: "path://relative-secret", mode: "read"},
  ],
}) + "\n");
NODE
  run_workgraph lint "$claims" --registry "$registry"
  expect_code 0 "$RC" "valid registry produces advisory projection"
  assert_contains "$OUTPUT" 'resource_claim_count=5' "projection claim count omitted malformed input"
  assert_contains "$OUTPUT" 'resource_resolved_count=1' "projection resolved count was not exact/alias count"
  assert_contains "$OUTPUT" 'claim[0].resolution=alias' "alias resolution missing"
  assert_contains "$OUTPUT" 'claim[0].canonical_id_json="path:///tmp/alias-target"' "alias canonical JSON missing"
  assert_contains "$OUTPUT" 'claim[1].resolution=unregistered' "unregistered resolution missing"
  assert_contains "$OUTPUT" 'claim[1].effective_mode=exclusive' "unregistered mode was not fail-closed"
  assert_contains "$OUTPUT" 'claim[1].effective_scope=container:container-root' "single-root containment missing"
  assert_contains "$OUTPUT" 'claim[2].resolution=ambiguous' "ambiguous resolution missing"
  assert_contains "$OUTPUT" 'claim[2].effective_scope=global' "ambiguous scope was not global"
  assert_contains "$OUTPUT" 'claim[3].resolution=unknown' "unknown resolution missing"
  assert_contains "$OUTPUT" 'claim[4].resolution=malformed' "malformed resolution missing"
  assert_contains "$OUTPUT" 'claim[3].effective_mode=exclusive' "unknown mode was not fail-closed"
  assert_contains "$OUTPUT" 'claim[4].effective_mode=exclusive' "malformed mode was not fail-closed"
  assert_not_contains "$OUTPUT" 'raw-secret' "unsafe unknown resource leaked into projection"
  assert_not_contains "$OUTPUT" 'relative-secret' "unsafe malformed resource leaked into projection"
  pass "resources: aliases, unregistered, ambiguous, unknown, and malformed projections broaden safely"
}

test_registry_semantic_failures() {
  local root mutation
  root=$(mktemp -d "$TMP_ROOT/registry-errors.XXXXXX")
  for mutation in duplicate-id noncanonical unknown-namespace alias-collision undefined-child duplicate-child self-link multi-parent cycle; do
    node - "$root/$mutation.json" "$mutation" <<'NODE'
const fs = require("node:fs");
const [outputPath, mutation] = process.argv.slice(2);
const value = {
  schema_version: "resource-registry/v1",
  instances: [
    {id: "root", namespace: "path", resource: "path:///tmp/registry-root", aliases: [], contains: ["child"]},
    {id: "child", namespace: "path", resource: "path:///tmp/registry-root/child", aliases: [], contains: []},
  ],
};
if (mutation === "duplicate-id") value.instances[1].id = "root";
if (mutation === "noncanonical") value.instances[0].resource = "path:///tmp/./registry-root";
if (mutation === "unknown-namespace") value.instances[0].namespace = "wat";
if (mutation === "alias-collision") {
  value.instances[0].aliases = ["path:///tmp/alias"];
  value.instances[1].aliases = ["path:///tmp/alias"];
}
if (mutation === "undefined-child") value.instances[0].contains = ["missing"];
if (mutation === "duplicate-child") value.instances[0].contains = ["child", "child"];
if (mutation === "self-link") value.instances[0].contains = ["root"];
if (mutation === "multi-parent") value.instances.push({id: "other", namespace: "path", resource: "path:///tmp/other", aliases: [], contains: ["child"]});
if (mutation === "cycle") value.instances[1].contains = ["root"];
fs.writeFileSync(outputPath, JSON.stringify(value) + "\n");
NODE
    run_workgraph registry "$root/$mutation.json"
    [ "$RC" -ne 0 ] || fail "registry semantic failure was accepted: $mutation"
    assert_contains "$OUTPUT" 'WG-E-REGISTRY' "registry failure lacked stable semantic code: $mutation"
  done
  pass "registry: canonicality, aliases, references, parentage, and cycles fail closed"
}

test_exact_lint_graph_validation_and_invalid_registry() {
  local root case_root bad_registry
  root=$(mktemp -d "$TMP_ROOT/lint-graph.XXXXXX")
  write_valid_graph "$root"
  run_workgraph lint "$root/graph.json"
  expect_code 0 "$RC" "lint accepts a complete valid graph"
  assert_contains "$OUTPUT" 'resource_claim_count=1' "graph lint omitted contract claim"
  for mutation in unknown-root unknown-claim unknown-context duplicate-root; do
    case_root=$(mktemp -d "$TMP_ROOT/lint-$mutation.XXXXXX")
    write_valid_graph "$case_root"
    if [ "$mutation" = duplicate-root ]; then
      mutate_json "$case_root/graph.json" "$case_root/bad.json" "$mutation"
      run_workgraph lint "$case_root/bad.json"
    else
      mutate_contract_case "$case_root" "$mutation"
      run_workgraph lint "$case_root/graph.json"
    fi
    [ "$RC" -ne 0 ] || fail "lint accepted invalid full graph/contract: $mutation"
  done
  bad_registry="$root/bad-registry.json"
  printf '%s\n' '{"schema_version":"resource-registry/v1","instances":[{"id":"bad","namespace":"path","resource":"path:///tmp/./bad","aliases":[],"contains":[]}]}' > "$bad_registry"
  run_workgraph lint "$root/graph.json" --registry "$bad_registry"
  [ "$RC" -ne 0 ] || fail "lint accepted an explicitly invalid registry"
  run_workgraph status "$root/graph.json" --registry "$bad_registry"
  [ "$RC" -ne 0 ] || fail "status accepted an explicitly invalid registry"
  pass "lint: complete graph validation and explicit registry failures are hard errors"
}

test_ascii_safe_projection_and_warning_records() {
  local root claims
  root=$(mktemp -d "$TMP_ROOT/ascii.XXXXXX")
  claims="$root/claims.json"
  node - "$claims" <<'NODE'
const fs = require("node:fs");
fs.writeFileSync(process.argv[2], JSON.stringify([{resource: "path:///tmp/Δ/😀", mode: "read"}, {resource: "wat://secret", mode: "read"}]) + "\n");
NODE
  run_workgraph lint "$claims"
  expect_code 0 "$RC" "Unicode path remains lintable"
  assert_contains "$OUTPUT" 'claim[0].canonical_id_json="path:///tmp/\u0394/\ud83d\ude00"' "canonical ID was not ASCII JSON escaped"
  assert_contains "$OUTPUT" 'resource_warning[0].code=WG-W-RESOURCE-UNKNOWN' "indexed warning record code missing"
  assert_contains "$OUTPUT" 'resource_warning[0].claim=1' "indexed warning record claim missing"
  assert_not_contains "$OUTPUT" '😀' "raw non-ASCII resource leaked"
  assert_not_contains "$OUTPUT" 'secret' "raw unknown resource leaked"
  pass "projection: canonical IDs and warning records are ASCII-safe and indexed"
}

test_projection_is_byte_identical() {
  local root claims first
  root=$(mktemp -d "$TMP_ROOT/repeat.XXXXXX")
  claims="$root/claims.json"
  printf '%s\n' '[{"resource":"path:///tmp/repeat/./claim","mode":"read"},{"resource":"wat://hidden","mode":"read"}]' > "$claims"
  run_workgraph lint "$claims"
  expect_code 0 "$RC" "first deterministic projection run succeeds"
  first=$OUTPUT
  run_workgraph lint "$claims"
  expect_code 0 "$RC" "second deterministic projection run succeeds"
  [ "$first" = "$OUTPUT" ] || fail "repeated projection output was not byte-identical"
  pass "projection: repeated runs are byte-identical"
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
test_exact_context_budget_numbers
test_contract_bytes_captured_once
test_schema_strictness
test_resource_namespace_matrix
test_resource_path_symlink_and_suffix
test_resource_negative_matrix
test_advisory_claim_lint
test_status_resource_warning_is_non_enforcing
test_resource_registry_strictness
test_terminal_file_and_fs_errors
test_registry_projection_and_broadening
test_registry_semantic_failures
test_exact_lint_graph_validation_and_invalid_registry
test_ascii_safe_projection_and_warning_records
test_projection_is_byte_identical

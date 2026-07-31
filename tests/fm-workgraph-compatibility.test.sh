#!/usr/bin/env bash
# Focused Slice-4 positive/negative compatibility matrix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-workgraph-compatibility.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

write_fixture() {
  local root=$1 variant=${2:-valid}
  mkdir -p "$root/worktrees" "$root/contracts"
  node - "$root" "$variant" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = process.argv[2];
const variant = process.argv[3];
const base = {
  schema_version: "slice-contract/v1", goal_id: "goal-1", purpose: "Slice 4 test",
  type: "ship", immutable_inputs: [], outputs: [], claims: [], worktree: "",
  harness: "codex", model: "test-model", effort: "high", acceptance: ["ok"],
  validation_commands: ["true"], expected_evidence: ["evidence"],
  context_budget: {source_tokens: 1, report_words: 1}, gates: ["tests-green"],
  implementer: "crew", independent_validators: ["validator"], authorized_exceptions: [],
};
const specs = [
  ["a", [], "read", "shared", "a"],
  ["b", [], "write", "shared", "b"],
  ["c", [], "read", "other", "c"],
  ["d", ["a"], "read", "third", "d"],
  ["e", ["b"], "read", "fourth", "e"],
];
const refs = [];
for (const [id, dependencies, mode, lock, directory] of specs) {
  const contract = {...base, slice_id: id, depends_on: dependencies,
    outputs: ["out/" + id + ".txt"], claims: [{resource: "lock://" + lock, mode}],
    worktree: path.join(root, "worktrees", directory)};
  if (variant === "duplicate-dependency" && id === "d") contract.depends_on = ["a", "a"];
  if (variant === "missing-dependency" && id === "d") contract.depends_on = ["missing"];
  if (variant === "self-dependency" && id === "d") contract.depends_on = ["d"];
  if (variant === "cycle") {
    if (id === "a") contract.depends_on = ["d"];
    if (id === "d") contract.depends_on = ["a"];
  }
  if (variant === "duplicate-worktree" && id === "b") contract.worktree = path.join(root, "worktrees", "a");
  if (variant === "output-overlap-internal" && id === "a") contract.outputs = ["out", "out/file.txt"];
  if (variant === "audit-write" && id === "a") { contract.type = "audit"; contract.claims[0].mode = "write"; }
  if (variant === "integration-missing" && id === "a") { contract.type = "integration"; contract.implementer = "crew"; }
  if (variant === "read-read" && (id === "a" || id === "b")) { contract.claims[0] = {resource: "lock://same", mode: "read"}; }
  if (variant === "path-worktree") {
    if (id === "a") contract.claims[0] = {resource: "path://" + path.join(root, "resource"), mode: "read"};
    if (id === "b") contract.claims[0] = {resource: "worktree://" + path.join(root, "resource", "child"), mode: "write"};
  }
  if (variant === "branch-prefix") {
    if (id === "a") contract.claims[0] = {resource: "branch://repo/main", mode: "read"};
    if (id === "b") contract.claims[0] = {resource: "branch://repo/main/feature", mode: "write"};
  }
  if (variant === "docker-kind") {
    if (id === "a") contract.claims[0] = {resource: "docker://project", mode: "read"};
    if (id === "b") contract.claims[0] = {resource: "docker://project/name", mode: "write"};
  }
  if (variant === "output-cross") {
    if (id === "a") contract.outputs = [path.join(root, "shared-out")];
    if (id === "b") contract.outputs = [path.join(root, "shared-out", "child")];
  }
  if (variant === "worktree-parent" && id === "b") contract.worktree = path.join(root, "worktrees", "a", "child");
  if (variant === "registry-alias") {
    if (id === "a") contract.claims[0] = {resource: "path://" + path.join(root, "alias"), mode: "read"};
    if (id === "b") contract.claims[0] = {resource: "path://" + path.join(root, "canonical"), mode: "write"};
  }
  const filename = id + ".json";
  const bytes = Buffer.from(JSON.stringify(contract) + "\n");
  fs.writeFileSync(path.join(root, "contracts", filename), bytes);
  refs.push({slice_id: id, contract_path: "contracts/" + filename,
    contract_sha256: crypto.createHash("sha256").update(bytes).digest("hex")});
}
if (variant === "duplicate-slice") refs.push({...refs[0]});
let slices = refs;
if (variant === "empty-graph") slices = [];
if (variant === "too-many-nodes") {
  slices = Array.from({length: 257}, (_, index) => ({slice_id: "n" + index,
    contract_path: "contracts/a.json", contract_sha256: refs[0].contract_sha256}));
}
fs.writeFileSync(path.join(root, "graph.json"), JSON.stringify({schema_version: "workgraph/v1", goal_id: "goal-1", slices}) + "\n");
if (variant === "registry-alias") {
  const resource = "path://" + path.join(root, "canonical");
  fs.writeFileSync(path.join(root, "registry.json"), JSON.stringify({schema_version: "resource-registry/v1", instances: [{id: "canonical", namespace: "path", resource, aliases: ["path://" + path.join(root, "alias")], contains: []}]}) + "\n");
}
NODE
}

run_cmd() {
  set +e
  OUTPUT=$("$@" 2>&1)
  RC=$?
  set -e
}

expect_ok_twice() {
  local label=$1
  shift
  local first second
  run_cmd "$@"
  expect_code 0 "$RC" "$label first run"
  first=$OUTPUT
  run_cmd "$@"
  expect_code 0 "$RC" "$label second run"
  second=$OUTPUT
  [ "$first" = "$second" ] || fail "$label was not byte-identical"
  pass "$label is deterministic across two runs"
}

expect_error() {
  local expected=$1 label=$2
  shift 2
  run_cmd "$@"
  [ "$RC" -eq 1 ] || fail "$label exit was $RC, expected 1"
  assert_contains "$OUTPUT" "$expected" "$label did not emit the required error"
  pass "$label fails closed"
}

expect_usage() {
  local expected=$1 label=$2
  shift 2
  run_cmd "$@"
  [ "$RC" -eq 2 ] || fail "$label exit was $RC, expected 2"
  assert_contains "$OUTPUT" "$expected" "$label did not emit the required usage"
  pass "$label fails closed"
}

test_valid_modes_and_outputs() {
  local root="$TMP_ROOT/valid"
  write_fixture "$root"
  for mode in off eco on max auto; do
    expect_ok_twice "ready mode $mode" "$ROOT/bin/fm-workgraph.sh" ready "$root/graph.json" --mode "$mode"
    assert_contains "$OUTPUT" "enforcement=disabled" "ready mode $mode missing advisory tail"
    assert_contains "$OUTPUT" "capacity_blocked_count=" "ready mode $mode missing capacity count"
  done
  expect_ok_twice "waves" "$ROOT/bin/fm-workgraph.sh" waves "$root/graph.json" --mode on
  assert_contains "$OUTPUT" 'wave_count=' "waves missing wave count"
  expect_ok_twice "status" "$ROOT/bin/fm-workgraph.sh" status "$root/graph.json"
  assert_contains "$OUTPUT" 'slice[4].slice_id=e' "status did not preserve graph order"
  expect_ok_twice "multi-node lint" "$ROOT/bin/fm-workgraph.sh" lint "$root/graph.json"
  assert_contains "$OUTPUT" 'claim[4].resolution=exact' "multi-node lint did not flatten claims in graph order"
  pass "valid DAG, modes, status, and static wave output"
}

test_conflict_explanations() {
  local root="$TMP_ROOT/conflicts"
  write_fixture "$root"
  expect_ok_twice "dependency/resource explanation" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" a d
  assert_contains "$OUTPUT" 'compatible=false' "dependency pair was compatible"
  assert_contains "$OUTPUT" 'reason[0].code=WG-C-DEPENDENCY' "dependency reason was not first"
  expect_ok_twice "reverse explanation" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" d a
  assert_contains "$OUTPUT" 'slice_a=d' "reverse selector orientation was lost"
  expect_error 'WG-E-SELECTOR' "equal selectors" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" a a
  expect_error 'WG-E-SELECTOR' "unknown selector" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" a missing
}

test_namespace_and_overlap_matrix() {
  local variant root
  for variant in path-worktree branch-prefix docker-kind output-cross worktree-parent; do
    root="$TMP_ROOT/matrix-$variant"
    write_fixture "$root" "$variant"
    expect_ok_twice "$variant explanation" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" a b
    assert_contains "$OUTPUT" 'compatible=false' "$variant did not conflict"
  done
  root="$TMP_ROOT/matrix-read-read"
  write_fixture "$root" read-read
  expect_ok_twice "read/read allowed" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" a b
  assert_contains "$OUTPUT" 'compatible=true' "read/read was not compatible"
  root="$TMP_ROOT/matrix-registry-alias"
  write_fixture "$root" registry-alias
  expect_ok_twice "registry alias containment" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" a b --registry "$root/registry.json"
  assert_contains "$OUTPUT" 'WG-C-RESOURCE' "registry alias conflict was not derived"
}

test_graph_errors() {
  local variant root
  for variant in missing-dependency self-dependency duplicate-dependency cycle duplicate-slice duplicate-worktree output-overlap-internal audit-write integration-missing empty-graph too-many-nodes; do
    root="$TMP_ROOT/error-$variant"
    write_fixture "$root" "$variant"
    case "$variant" in
      missing-dependency|self-dependency|duplicate-dependency) expect_error 'WG-E-DEPENDENCY' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
      cycle) expect_error 'WG-E-CYCLE' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
      duplicate-slice) expect_error 'WG-E-DUPLICATE' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
      duplicate-worktree) expect_error 'WG-E-WORKTREE' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
      output-overlap-internal) expect_error 'WG-E-OUTPUT' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
      audit-write) expect_error 'WG-E-AUDIT-WRITE' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
      integration-missing) expect_error 'WG-E-INTEGRATION' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
      empty-graph|too-many-nodes) expect_error 'WG-E-NODES' "$variant" "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json" ;;
    esac
  done
}

test_usage_and_registry_failures() {
  local root="$TMP_ROOT/usage" bad_registry="$TMP_ROOT/bad-registry.json"
  write_fixture "$root"
  expect_usage 'WG-E-USAGE: usage: waves' "repeated mode" "$ROOT/bin/fm-workgraph.sh" waves "$root/graph.json" --mode on --mode off
  expect_usage 'WG-E-USAGE: usage: explain-conflict' "missing selector" "$ROOT/bin/fm-workgraph.sh" explain-conflict "$root/graph.json" a
  printf '%s\n' '{}' > "$bad_registry"
  expect_error 'WG-E-MISSING' "invalid explicit registry" "$ROOT/bin/fm-workgraph.sh" waves "$root/graph.json" --registry "$bad_registry" --mode on
}

test_one_node_legacy_surface() {
  local root="$TMP_ROOT/one-node"
  write_fixture "$root"
  node - "$root" <<'NODE'
const fs=require("node:fs"), path=require("node:path"), crypto=require("node:crypto");
const root=process.argv[2]; const contract=JSON.parse(fs.readFileSync(path.join(root,"contracts/a.json"), "utf8"));
contract.depends_on=[]; fs.writeFileSync(path.join(root,"contracts/a.json"), JSON.stringify(contract)+"\n");
const bytes=fs.readFileSync(path.join(root,"contracts/a.json"));
fs.writeFileSync(path.join(root,"graph.json"), JSON.stringify({schema_version:"workgraph/v1",goal_id:"goal-1",slices:[{slice_id:"a",contract_path:"contracts/a.json",contract_sha256:crypto.createHash("sha256").update(bytes).digest("hex")}]})+"\n");
NODE
  expect_ok_twice "one-node status" "$ROOT/bin/fm-workgraph.sh" status "$root/graph.json"
  run_cmd "$ROOT/bin/fm-workgraph.sh" validate "$root/graph.json"
  expect_code 0 "$RC" "one-node validate"
  [ -z "$OUTPUT" ] || fail "one-node validate changed its zero-byte stdout"
  pass "one-node compatibility surface remains intact"
}

test_contract_selector_preserves_sealed_bytes() {
  local root="$TMP_ROOT/contract-selector"
  write_fixture "$root"
  "$ROOT/bin/fm-workgraph.sh" contract "$root/graph.json" c >"$root/selected.json" \
    || fail "contract selector rejected a valid slice"
  cmp -s "$root/contracts/c.json" "$root/selected.json" \
    || fail "contract selector did not return the exact sealed contract bytes"
  expect_error 'WG-E-SELECTOR' "unknown contract selector" \
    "$ROOT/bin/fm-workgraph.sh" contract "$root/graph.json" missing
  expect_usage 'WG-E-USAGE: usage: contract' "missing contract selector" \
    "$ROOT/bin/fm-workgraph.sh" contract "$root/graph.json"
  pass "contract selector returns only the exact sealed bytes"
}

test_valid_modes_and_outputs
test_conflict_explanations
test_namespace_and_overlap_matrix
test_graph_errors
test_usage_and_registry_failures
test_one_node_legacy_surface
test_contract_selector_preserves_sealed_bytes

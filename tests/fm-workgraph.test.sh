#!/usr/bin/env bash
# Focused hermetic tests for Slice-2 parallelism modes and one-node WorkGraphs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
const value = JSON.parse(fs.readFileSync(source, "utf8"));
if (mutation === "unknown-schema") value.schema_version = "workgraph/v99";
if (mutation === "missing-field") delete value.slices;
if (mutation === "multiple-nodes") value.slices.push({...value.slices[0], slice_id: "slice-2"});
if (mutation === "unsafe-id") value.goal_id = "../unsafe";
if (mutation === "bad-hash") value.slices[0].contract_sha256 = "0".repeat(64);
fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n");
NODE
}

mutate_contract_case() {
  local root=$1 mutation=$2 contract="$1/contracts/slice-1.json" digest
  if [ "$mutation" = bad-claim ]; then
    node - "$contract" "$contract.tmp" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const target = process.argv[3];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.claims[0].mode = "bogus";
fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n");
NODE
  elif [ "$mutation" = missing-field ]; then
    node - "$contract" "$contract.tmp" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const target = process.argv[3];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
delete value.acceptance;
fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n");
NODE
  else
    node - "$contract" "$contract.tmp" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
const target = process.argv[3];
const value = JSON.parse(fs.readFileSync(file, "utf8"));
value.schema_version = "slice-contract/v99";
fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n");
NODE
  fi
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
  run_parallelism status
  assert_contains "$OUTPUT" 'source=default' "status did not identify the absent default"
  run_parallelism set auto
  expect_code 0 "$RC" "auto is accepted"
  [ "$OUTPUT" = on ] || fail "auto output was not canonical on"
  [ "$(cat "$TEST_HOME/config/parallelism")" = on ] || fail "auto was not persisted as on"
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
  FM_PARALLELISM_OVERRIDE=off run_parallelism get --project project-1
  [ "$OUTPUT" = off ] || fail "environment request override did not win"
  pass "parallelism: request > goal > project > global"
}

test_atomic_scoped_and_metadata_unchanged() {
  local before_meta after_meta before_fixture after_fixture
  new_home
  printf 'window=fm-task-1\nmode=no-mistakes\n' > "$TEST_HOME/state/task-1.meta"
  printf 'process-fixture\n' > "$TEST_HOME/state/process.fixture"
  before_meta=$(sha_file "$TEST_HOME/state/task-1.meta")
  before_fixture=$(sha_file "$TEST_HOME/state/process.fixture")
  run_parallelism set eco --goal goal-1
  expect_code 0 "$RC" "goal write succeeds"
  [ -f "$TEST_HOME/data/workgraphs/goal-1/parallelism" ] || fail "goal value missing"
  [ ! -e "$TEST_HOME/config/parallelism" ] || fail "goal write touched global scope"
  [ ! -e "$TEST_HOME/config/parallelism-projects/goal-1" ] || fail "goal write touched project scope"
  find "$TEST_HOME/data/workgraphs/goal-1" -name '.parallelism.tmp.*' -print -quit | grep -q . && fail "temporary file leaked"
  after_meta=$(sha_file "$TEST_HOME/state/task-1.meta")
  after_fixture=$(sha_file "$TEST_HOME/state/process.fixture")
  [ "$before_meta" = "$after_meta" ] || fail "task metadata changed"
  [ "$before_fixture" = "$after_fixture" ] || fail "process fixture changed"
  pass "parallelism: scoped atomic write leaves task fixtures unchanged"
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
  for mutation in unknown-schema missing-field multiple-nodes unsafe-id bad-hash; do
    case_root=$(mktemp -d "$TMP_ROOT/$mutation.XXXXXX")
    write_valid_graph "$case_root"
    mutate_json "$case_root/graph.json" "$case_root/bad.json" "$mutation"
    run_workgraph validate "$case_root/bad.json"
    [ "$RC" -ne 0 ] || fail "$mutation graph was accepted"
  done
  for mutation in bad-contract-schema bad-claim missing-field; do
    root=$(mktemp -d "$TMP_ROOT/contract-$mutation.XXXXXX")
    write_valid_graph "$root"
    mutate_contract_case "$root" "$mutation"
    run_workgraph validate "$root/graph.json"
    [ "$RC" -ne 0 ] || fail "$mutation contract was accepted"
  done
  pass "workgraph: schema, field, node-count, id, hash, and claim negatives reject"
}

test_existing_surfaces_unchanged() {
  git diff --quiet -- bin/fm-brief.sh bin/fm-spawn.sh \
    || fail "existing brief/spawn files changed in Slice 2"
  pass "workgraph: existing brief and spawn surfaces remain unchanged"
}

test_mode_round_trips
test_auto_and_invalid_values
test_precedence_and_scopes
test_atomic_scoped_and_metadata_unchanged
test_valid_graph_and_status
test_graph_negative_cases
test_existing_surfaces_unchanged

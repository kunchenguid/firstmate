#!/usr/bin/env bash
# Validate or present a Slice-2 one-node WorkGraph and its bound contract.
#
# Usage:
#   fm-workgraph.sh validate <workgraph.json>
#   fm-workgraph.sh status <workgraph.json>
#
# The graph and contract format is owned by schemas/workgraph/ and
# docs/workgraph.md.  Slice 2 validates one node only and performs no resource,
# wave, lease, gate, integration, or dispatch enforcement.
set -eu

usage() {
  sed -n '2,10{s/^# //;p;}' "$0"
}

die() {
  printf 'fm-workgraph: %s\n' "$*" >&2
  exit 1
}

COMMAND=${1:-}
[ "$COMMAND" = -h ] || [ "$COMMAND" = --help ] && { usage; exit 0; }
[ -n "$COMMAND" ] || { usage >&2; exit 2; }
[ "$#" -eq 2 ] || die "usage: $0 validate|status <workgraph.json>"
GRAPH_PATH=$2

case "$COMMAND" in
  validate|status) ;;
  *) die "unknown command '$COMMAND'; use validate or status" ;;
esac

command -v node >/dev/null 2>&1 || die 'node is required to validate WorkGraph JSON'
[ -f "$GRAPH_PATH" ] && [ ! -L "$GRAPH_PATH" ] || die "graph is not a regular file: $GRAPH_PATH"

node - "$GRAPH_PATH" "$COMMAND" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const graphPath = path.resolve(process.argv[2]);
const command = process.argv[3];

function fail(code, message) {
  console.error(`fm-workgraph: ${code}: ${message}`);
  process.exit(1);
}

function object(value, name) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail("WG-E-CORRUPT", `${name} must be an object`);
  }
  return value;
}

function required(value, key, name) {
  if (!Object.prototype.hasOwnProperty.call(value, key)) {
    fail("WG-E-MISSING", `${name}.${key} is required`);
  }
  return value[key];
}

function nonemptyString(value, name) {
  if (typeof value !== "string" || value.length === 0) {
    fail("WG-E-MISSING", `${name} must be a non-empty string`);
  }
  return value;
}

function safeId(value, name) {
  nonemptyString(value, name);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(value)) {
    fail("WG-E-ID", `${name} is unsafe`);
  }
}

function array(value, name, allowEmpty = true) {
  if (!Array.isArray(value) || (!allowEmpty && value.length === 0)) {
    fail("WG-E-MISSING", `${name} must be ${allowEmpty ? "an" : "a non-empty"} array`);
  }
  return value;
}

function stringArray(value, name, allowEmpty = true) {
  array(value, name, allowEmpty).forEach((item, index) => {
    nonemptyString(item, `${name}[${index}]`);
  });
}

function sha256(value, name) {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value)) {
    fail("WG-E-HASH", `${name} must be a lowercase SHA-256 digest`);
  }
}

function readJson(file, name) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (error) {
    fail("WG-E-CORRUPT", `cannot read ${name}: ${error.message}`);
  }
  try {
    return object(JSON.parse(text), name);
  } catch (error) {
    if (error && typeof error.code === "string" && error.code.startsWith("WG-E-")) {
      throw error;
    }
    fail("WG-E-CORRUPT", `${name} is not valid JSON: ${error.message}`);
  }
}

let graph;
try {
  const stat = fs.lstatSync(graphPath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail("WG-E-CORRUPT", "graph is not a regular file");
  }
} catch (error) {
  fail("WG-E-CORRUPT", `cannot stat graph: ${error.message}`);
}
graph = readJson(graphPath, "graph");
if (required(graph, "schema_version", "graph") !== "workgraph/v1") {
  fail("WG-E-SCHEMA", "unknown graph schema version");
}
const goalId = required(graph, "goal_id", "graph");
safeId(goalId, "graph.goal_id");
const slices = array(required(graph, "slices", "graph"), "graph.slices", false);
if (slices.length !== 1) {
  fail("WG-E-NODES", `Slice 2 requires exactly one node; found ${slices.length}`);
}

const reference = object(slices[0], "graph.slices[0]");
const sliceId = required(reference, "slice_id", "graph.slices[0]");
safeId(sliceId, "graph.slices[0].slice_id");
const contractPath = nonemptyString(required(reference, "contract_path", "graph.slices[0]"), "graph.slices[0].contract_path");
const pathParts = contractPath.split(/[\\/]/);
if (path.isAbsolute(contractPath) || pathParts.some((part) => part === "" || part === "." || part === "..") || contractPath.includes("\0")) {
  fail("WG-E-ID", "graph.slices[0].contract_path must be a safe relative path");
}
const contractDigest = required(reference, "contract_sha256", "graph.slices[0]");
sha256(contractDigest, "graph.slices[0].contract_sha256");

const graphDirectory = path.dirname(graphPath);
const contractPathResolved = path.resolve(graphDirectory, contractPath);
let graphDirectoryReal;
let contractReal;
try {
  graphDirectoryReal = fs.realpathSync(graphDirectory);
  contractReal = fs.realpathSync(contractPathResolved);
  const relativeContract = path.relative(graphDirectoryReal, contractReal);
  if (relativeContract.startsWith("..") || path.isAbsolute(relativeContract)) {
    fail("WG-E-ID", "contract must remain under the graph directory");
  }
  const stat = fs.lstatSync(contractPathResolved);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail("WG-E-CORRUPT", "contract is not an independently stored regular file");
  }
} catch (error) {
  if (error && typeof error.code === "string" && error.code.startsWith("WG-E-")) {
    throw error;
  }
  fail("WG-E-CORRUPT", `cannot resolve contract: ${error.message}`);
}

const actualDigest = crypto.createHash("sha256").update(fs.readFileSync(contractReal)).digest("hex");
if (actualDigest !== contractDigest) {
  fail("WG-E-HASH", `contract SHA-256 mismatch; expected ${contractDigest}, got ${actualDigest}`);
}
const contract = readJson(contractReal, "contract");
if (required(contract, "schema_version", "contract") !== "slice-contract/v1") {
  fail("WG-E-SCHEMA", "unknown contract schema version");
}
if (required(contract, "slice_id", "contract") !== sliceId) {
  fail("WG-E-CORRUPT", "contract.slice_id does not match graph reference");
}
if (required(contract, "goal_id", "contract") !== goalId) {
  fail("WG-E-CORRUPT", "contract.goal_id does not match graph goal");
}

nonemptyString(required(contract, "purpose", "contract"), "contract.purpose");
const type = required(contract, "type", "contract");
if (!["ship", "scout", "audit", "integration"].includes(type)) {
  fail("WG-E-CORRUPT", "contract.type must be ship|scout|audit|integration");
}
const dependencies = array(required(contract, "depends_on", "contract"), "contract.depends_on");
dependencies.forEach((dependency, index) => safeId(dependency, `contract.depends_on[${index}]`));
if (dependencies.length !== 0) {
  fail("WG-E-CORRUPT", "a one-node graph cannot have predecessors");
}

array(required(contract, "immutable_inputs", "contract"), "contract.immutable_inputs").forEach((input, index) => {
  const item = object(input, `contract.immutable_inputs[${index}]`);
  nonemptyString(required(item, "path", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].path`);
  sha256(required(item, "sha256", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].sha256`);
});

array(required(contract, "outputs", "contract"), "contract.outputs", false).forEach((output, index) => {
  if (typeof output === "string") {
    nonemptyString(output, `contract.outputs[${index}]`);
  } else {
    const item = object(output, `contract.outputs[${index}]`);
    nonemptyString(required(item, "path", `contract.outputs[${index}]`), `contract.outputs[${index}].path`);
  }
});

array(required(contract, "claims", "contract"), "contract.claims", false).forEach((claim, index) => {
  const item = object(claim, `contract.claims[${index}]`);
  nonemptyString(required(item, "resource", `contract.claims[${index}]`), `contract.claims[${index}].resource`);
  const mode = required(item, "mode", `contract.claims[${index}]`);
  if (!["read", "write", "exclusive"].includes(mode)) {
    fail("WG-E-CLAIM", "claim mode must be read|write|exclusive");
  }
});

["worktree", "harness", "model", "effort", "implementer"].forEach((field) => {
  nonemptyString(required(contract, field, "contract"), `contract.${field}`);
});
stringArray(required(contract, "acceptance", "contract"), "contract.acceptance", false);
stringArray(required(contract, "validation_commands", "contract"), "contract.validation_commands", false);
stringArray(required(contract, "expected_evidence", "contract"), "contract.expected_evidence", false);
const contextBudget = object(required(contract, "context_budget", "contract"), "contract.context_budget");
for (const field of ["source_tokens", "report_words"]) {
  const value = required(contextBudget, field, "contract.context_budget");
  if (!Number.isSafeInteger(value) || value <= 0) {
    fail("WG-E-CORRUPT", `contract.context_budget.${field} must be a positive integer`);
  }
}
stringArray(required(contract, "gates", "contract"), "contract.gates", false);
stringArray(required(contract, "independent_validators", "contract"), "contract.independent_validators", false);
stringArray(required(contract, "authorized_exceptions", "contract"), "contract.authorized_exceptions");

if (command === "status") {
  console.log("valid=true");
  console.log(`schema_version=${graph.schema_version}`);
  console.log(`goal_id=${goalId}`);
  console.log("slice_count=1");
  console.log(`slice_id=${sliceId}`);
  console.log(`contract_path=${contractPath}`);
  console.log(`contract_sha256=${contractDigest}`);
  console.log("contract_verified=true");
  console.log("enforcement=disabled");
}
NODE

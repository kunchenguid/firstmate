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

node - "$GRAPH_PATH" "$COMMAND" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const {TextDecoder} = require("node:util");

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

function strictObject(value, name, allowedKeys) {
  object(value, name);
  const allowed = new Set(allowedKeys);
  const unknown = Object.keys(value).find((key) => !allowed.has(key));
  if (unknown !== undefined) {
    fail("WG-E-SCHEMA", `${name}[${JSON.stringify(unknown)}] is not allowed`);
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

class StrictJsonParser {
  constructor(text) {
    this.text = text;
    this.index = 0;
  }

  parse() {
    const value = this.parseValue();
    this.skipWhitespace();
    if (this.index !== this.text.length) {
      this.error("unexpected trailing content");
    }
    return value;
  }

  skipWhitespace() {
    while (this.index < this.text.length && /[ \t\r\n]/.test(this.text[this.index])) {
      this.index += 1;
    }
  }

  parseValue() {
    this.skipWhitespace();
    const current = this.text[this.index];
    if (current === "{") return this.parseObject();
    if (current === "[") return this.parseArray();
    if (current === '"') return this.parseString();
    if (current === "-" || (current >= "0" && current <= "9")) return this.parseNumber();
    if (this.text.startsWith("true", this.index)) {
      this.index += 4;
      return true;
    }
    if (this.text.startsWith("false", this.index)) {
      this.index += 5;
      return false;
    }
    if (this.text.startsWith("null", this.index)) {
      this.index += 4;
      return null;
    }
    this.error("expected a JSON value");
  }

  parseObject() {
    const value = Object.create(null);
    const keys = new Set();
    this.index += 1;
    this.skipWhitespace();
    if (this.text[this.index] === "}") {
      this.index += 1;
      return value;
    }
    while (this.index < this.text.length) {
      if (this.text[this.index] !== '"') {
        this.error("expected an object key");
      }
      const key = this.parseString();
      if (keys.has(key)) {
        this.error(`duplicate object key ${JSON.stringify(key)}`);
      }
      keys.add(key);
      this.skipWhitespace();
      if (this.text[this.index] !== ":") {
        this.error("expected ':' after an object key");
      }
      this.index += 1;
      value[key] = this.parseValue();
      this.skipWhitespace();
      if (this.text[this.index] === "}") {
        this.index += 1;
        return value;
      }
      if (this.text[this.index] !== ",") {
        this.error("expected ',' or '}' in an object");
      }
      this.index += 1;
      this.skipWhitespace();
    }
    this.error("unterminated object");
  }

  parseArray() {
    const value = [];
    this.index += 1;
    this.skipWhitespace();
    if (this.text[this.index] === "]") {
      this.index += 1;
      return value;
    }
    while (this.index < this.text.length) {
      value.push(this.parseValue());
      this.skipWhitespace();
      if (this.text[this.index] === "]") {
        this.index += 1;
        return value;
      }
      if (this.text[this.index] !== ",") {
        this.error("expected ',' or ']' in an array");
      }
      this.index += 1;
    }
    this.error("unterminated array");
  }

  parseString() {
    const start = this.index;
    this.index += 1;
    while (this.index < this.text.length) {
      const code = this.text.charCodeAt(this.index);
      if (code === 34) {
        this.index += 1;
        return JSON.parse(this.text.slice(start, this.index));
      }
      if (code === 92) {
        this.index += 1;
        const escape = this.text[this.index];
        if (escape === "u") {
          const hex = this.text.slice(this.index + 1, this.index + 5);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
            this.error("invalid Unicode escape");
          }
          this.index += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape)) {
          this.error("invalid string escape");
        }
        this.index += 1;
        continue;
      }
      if (code <= 0x1f) {
        this.error("unescaped control character in string");
      }
      this.index += 1;
    }
    this.error("unterminated string");
  }

  parseNumber() {
    const match = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(this.text.slice(this.index));
    if (match === null) {
      this.error("invalid number");
    }
    this.index += match[0].length;
    return Number(match[0]);
  }

  error(message) {
    throw new SyntaxError(`${message} at character offset ${this.index}`);
  }
}

function parseStrictJson(bytes, name) {
  let text;
  try {
    text = new TextDecoder("utf-8", {fatal: true}).decode(bytes);
  } catch (error) {
    fail("WG-E-CORRUPT", `${name} is not valid UTF-8: ${error.message}`);
  }
  try {
    return new StrictJsonParser(text).parse();
  } catch (error) {
    fail("WG-E-CORRUPT", `${name} is not valid JSON: ${error.message}`);
  }
}

function captureRegularFile(file, name) {
  let descriptor;
  let captured;
  let capturedError;
  try {
    if (typeof fs.constants.O_NOFOLLOW !== "number") {
      throw new Error("platform does not support no-follow file opens");
    }
    descriptor = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) {
      throw new Error(`${name} is not a regular file`);
    }
    captured = {bytes: fs.readFileSync(descriptor), stat};
  } catch (error) {
    capturedError = error;
  } finally {
    if (descriptor !== undefined) {
      try {
        fs.closeSync(descriptor);
      } catch {
        capturedError = capturedError || new Error(`cannot close ${name}`);
      }
    }
  }
  if (capturedError !== undefined) {
    fail("WG-E-CORRUPT", `cannot capture ${name}: ${capturedError.message}`);
  }
  return captured;
}

const graphCapture = captureRegularFile(graphPath, "graph");
const graph = strictObject(
  parseStrictJson(graphCapture.bytes, "graph"),
  "graph",
  ["schema_version", "goal_id", "slices"],
);
if (required(graph, "schema_version", "graph") !== "workgraph/v1") {
  fail("WG-E-SCHEMA", "unknown graph schema version");
}
const goalId = required(graph, "goal_id", "graph");
safeId(goalId, "graph.goal_id");
const slices = array(required(graph, "slices", "graph"), "graph.slices", false);
if (slices.length !== 1) {
  fail("WG-E-NODES", `Slice 2 requires exactly one node; found ${slices.length}`);
}

const reference = strictObject(
  slices[0],
  "graph.slices[0]",
  ["slice_id", "contract_path", "contract_sha256"],
);
const sliceId = required(reference, "slice_id", "graph.slices[0]");
safeId(sliceId, "graph.slices[0].slice_id");
const contractPath = nonemptyString(required(reference, "contract_path", "graph.slices[0]"), "graph.slices[0].contract_path");
const pathParts = contractPath.split(/[\\/]/);
if (
  path.isAbsolute(contractPath)
  || pathParts.some((part) => part === "" || part === "." || part === "..")
  || /[\u0000-\u001f\u007f-\u009f]/u.test(contractPath)
) {
  fail("WG-E-ID", "graph.slices[0].contract_path must be a safe relative path");
}
const contractDigest = required(reference, "contract_sha256", "graph.slices[0]");
sha256(contractDigest, "graph.slices[0].contract_sha256");

const graphDirectory = path.dirname(graphPath);
const contractPathResolved = path.resolve(graphDirectory, contractPath);
let graphDirectoryReal;
let contractReal;
let contractCapture;
try {
  graphDirectoryReal = fs.realpathSync(graphDirectory);
  contractCapture = captureRegularFile(contractPathResolved, "contract");
  contractReal = fs.realpathSync(contractPathResolved);
  const relativeContract = path.relative(graphDirectoryReal, contractReal);
  if (relativeContract === ".." || relativeContract.startsWith(`..${path.sep}`) || path.isAbsolute(relativeContract)) {
    fail("WG-E-ID", "contract must remain under the graph directory");
  }
  const resolvedStat = fs.statSync(contractReal);
  if (resolvedStat.dev !== contractCapture.stat.dev || resolvedStat.ino !== contractCapture.stat.ino) {
    fail("WG-E-CORRUPT", "contract path changed while it was captured");
  }
} catch (error) {
  if (error && typeof error.code === "string" && error.code.startsWith("WG-E-")) {
    throw error;
  }
  fail("WG-E-CORRUPT", `cannot resolve contract: ${error.message}`);
}

const actualDigest = crypto.createHash("sha256").update(contractCapture.bytes).digest("hex");
if (actualDigest !== contractDigest) {
  fail("WG-E-HASH", `contract SHA-256 mismatch; expected ${contractDigest}, got ${actualDigest}`);
}
const contract = strictObject(
  parseStrictJson(contractCapture.bytes, "contract"),
  "contract",
  [
    "schema_version", "slice_id", "goal_id", "purpose", "type", "depends_on",
    "immutable_inputs", "outputs", "claims", "worktree", "harness", "model",
    "effort", "acceptance", "validation_commands", "expected_evidence",
    "context_budget", "gates", "implementer", "independent_validators",
    "authorized_exceptions",
  ],
);
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
  const item = strictObject(
    input,
    `contract.immutable_inputs[${index}]`,
    ["path", "sha256"],
  );
  nonemptyString(required(item, "path", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].path`);
  sha256(required(item, "sha256", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].sha256`);
});

stringArray(required(contract, "outputs", "contract"), "contract.outputs", false);

array(required(contract, "claims", "contract"), "contract.claims", false).forEach((claim, index) => {
  const item = strictObject(
    claim,
    `contract.claims[${index}]`,
    ["resource", "mode"],
  );
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
const contextBudget = strictObject(
  required(contract, "context_budget", "contract"),
  "contract.context_budget",
  ["source_tokens", "report_words"],
);
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

#!/usr/bin/env bash
# Validate, inspect, gate, snapshot, or lease a sealed WorkGraph.
#
# Usage:
#   fm-workgraph.sh validate <workgraph.json>
#   fm-workgraph.sh status <workgraph.json>
#   fm-workgraph.sh acquire <graph.json> <slice-id> --registry <registry.json> --lease-id <id> --holder-id <id> --holder-pid <pid>
#   fm-workgraph.sh release <goal-id> --lease-id <id> --holder-id <id> --fencing-token <token>
#   fm-workgraph.sh inspect <goal-id> [--lease-id <id>] [--history]
#   fm-workgraph.sh fence <goal-id> --lease-id <id> --holder-id <id> --fencing-token <token>
#   fm-workgraph.sh recover <goal-id> --lease-id <id> --actor-id <id>
#   fm-workgraph.sh normalize <resource>
#   fm-workgraph.sh lint <claims.json|workgraph.json> [--registry <registry.json>]
#   fm-workgraph.sh registry <resource-registry.json>
#   fm-workgraph.sh waves <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]
#   fm-workgraph.sh ready <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]
#   fm-workgraph.sh explain-conflict <graph.json> <slice-a> <slice-b> [--registry <registry.json>]
#   fm-workgraph.sh contract <graph.json> <slice-id>
#   fm-workgraph.sh record-gate <graph.json> <slice-id> <gate-id> --status <passed|failed> --evidence <file> --actor <id>
#   fm-workgraph.sh gate-status <graph.json> [slice-id]
#   fm-workgraph.sh record-evidence <graph.json> <slice-id> --kind <kind> --evidence <file> --actor <id>
#   fm-workgraph.sh snapshot <graph.json> <slice-id> --actor <id>
#
# schemas/workgraph/ owns the exact graph and contract formats.
# docs/workgraph.md owns the operator behavior and enforcement boundaries.
# Static projections do not mutate runtime state; fm-spawn consumes their sealed
# inputs and enforces admission through durable leases and predecessor gates.
set -eu

usage() {
  sed -n '2,22{s/^# //;p;}' "$0"
}

die() {
  printf 'fm-workgraph: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  printf 'fm-workgraph: WG-E-USAGE: usage: %s\n' "$1" >&2
  exit 2
}

COMMAND=${1:-}
[ "$COMMAND" = -h ] || [ "$COMMAND" = --help ] && { usage; exit 0; }
[ -n "$COMMAND" ] || { usage >&2; exit 2; }

# Private captured-input seam used only by the lease bootstrap.  It is
# validated before the public command grammar and is intentionally omitted
# from help and operator-facing dispatch.
if [ "$COMMAND" = "__lease-project" ]; then
  [ "$#" -eq 5 ] && [ "$4" = "--registry" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$5" ] \
    || die "private captured projection entrypoint"
fi
if [ "$COMMAND" = "__lease-overlap" ]; then
  [ "$#" -eq 1 ] || die "private overlap entrypoint"
fi
if [ "$COMMAND" = "__lease-normalize" ]; then
  [ "$#" -eq 1 ] || die "private normalize entrypoint"
fi
if [ "$COMMAND" = "__lease-normalize" ] || [ "$COMMAND" = "__lease-overlap" ]; then
  exec 9<&0
  export FM_WORKGRAPH_PRIVATE_INPUT_FD=9
fi
if [ "$COMMAND" = "__dispatch-conflict" ]; then
  [ "$#" -eq 7 ] \
    && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] \
    && [ -n "$5" ] && [ -n "$6" ] && [ -n "$7" ] \
    || die "private dispatch conflict entrypoint"
fi

# Slice 5 lease commands are isolated in the focused lease authority library.
case "$COMMAND" in
  acquire|release|recover|fence|inspect)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec "$SCRIPT_DIR/fm-workgraph-lease-lib.sh" "$@"
    ;;
  record-gate|record-evidence|gate-status|gate-check|completion-check|snapshot)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    exec "$SCRIPT_DIR/fm-workgraph-gate-lib.sh" "$@"
    ;;
esac

if [ "$COMMAND" != "__lease-overlap" ] && [ "$COMMAND" != "__lease-normalize" ] && [ "$#" -lt 2 ]; then
  case "$COMMAND" in
    waves|ready) die_usage "$COMMAND <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]" ;;
    explain-conflict) die_usage "explain-conflict <graph.json> <slice-a> <slice-b> [--registry <registry.json>]" ;;
    contract) die_usage "contract <graph.json> <slice-id>" ;;
    *) die "usage: $0 validate|status <workgraph.json> [--registry <registry.json>]; normalize <resource>; lint <claims.json|workgraph.json> [--registry <registry.json>]; registry <resource-registry.json>" ;;
  esac
fi
GRAPH_PATH=/dev/null
[ "$#" -ge 2 ] && GRAPH_PATH=$2
REGISTRY_PATH=
SLICE_A=
SLICE_B=
MODE=
OTHER_GRAPH_PATH=
OTHER_SLICE=
OTHER_REGISTRY_PATH=
if [ "$COMMAND" = "__lease-overlap" ]; then
  GRAPH_PATH=/dev/null
fi
if [ "$COMMAND" = "__lease-normalize" ]; then
  GRAPH_PATH=/dev/null
fi

case "$COMMAND" in
  __dispatch-conflict)
    GRAPH_PATH=$2
    SLICE_A=$3
    REGISTRY_PATH=$4
    OTHER_GRAPH_PATH=$5
    OTHER_SLICE=$6
    OTHER_REGISTRY_PATH=$7
    ;;
  __lease-project)
    [ "$#" -eq 5 ] && [ "$4" = --registry ] && [ -n "$5" ] || die "private captured projection entrypoint"
    GRAPH_PATH=$2
    SLICE_A=$3
    REGISTRY_PATH=$5
    ;;
  __lease-overlap)
    ;;
  __lease-normalize)
    ;;
  normalize|registry)
    [ "$#" -eq 2 ] || die "usage: $COMMAND <path-or-resource>"
    ;;
  validate)
    [ "$#" -eq 2 ] || die "usage: validate <workgraph.json>"
    ;;
  contract)
    [ "$#" -eq 3 ] && [ -n "$3" ] || die_usage "contract <graph.json> <slice-id>"
    SLICE_A=$3
    ;;
  waves|ready)
    index=3
    while [ "$index" -le "$#" ]; do
      arg=${!index}
      case "$arg" in
        --registry)
          next_index=$((index + 1))
          [ -z "$REGISTRY_PATH" ] && [ "$next_index" -le "$#" ] || die_usage "$COMMAND <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]"
          REGISTRY_PATH=${!next_index}
          [ -n "$REGISTRY_PATH" ] || die_usage "$COMMAND <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]"
          index=$((index + 2))
          ;;
        --mode)
          next_index=$((index + 1))
          [ -z "$MODE" ] && [ "$next_index" -le "$#" ] || die_usage "$COMMAND <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]"
          MODE=${!next_index}
          case "$MODE" in off|eco|on|max|auto) ;; *) die_usage "$COMMAND <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]" ;; esac
          index=$((index + 2))
          ;;
        *) die_usage "$COMMAND <graph.json> [--registry <registry.json>] [--mode off|eco|on|max|auto]" ;;
      esac
    done
    ;;
  explain-conflict)
    [ "$#" -ge 4 ] || die_usage "explain-conflict <graph.json> <slice-a> <slice-b> [--registry <registry.json>]"
    SLICE_A=$3
    SLICE_B=$4
    if [ "$#" -eq 5 ] && [ "$5" = --registry ]; then
      die_usage "explain-conflict <graph.json> <slice-a> <slice-b> [--registry <registry.json>]"
    elif [ "$#" -eq 6 ] && [ "$5" = --registry ] && [ -n "$6" ]; then
      REGISTRY_PATH=$6
    elif [ "$#" -ne 4 ]; then
      die_usage "explain-conflict <graph.json> <slice-a> <slice-b> [--registry <registry.json>]"
    fi
    ;;
  status|lint)
    if [ "$#" -eq 4 ] && [ "$3" = --registry ]; then
      REGISTRY_PATH=$4
    elif [ "$#" -ne 2 ]; then
      die "usage: $COMMAND <path> [--registry <registry.json>]"
    fi
    ;;
  *) die "unknown command '$COMMAND'; use validate or status" ;;
esac

command -v node >/dev/null 2>&1 || die 'node is required to validate WorkGraph JSON'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WORKGRAPH_SCRIPT_DIR=$SCRIPT_DIR node - \
  "$GRAPH_PATH" "$COMMAND" "$REGISTRY_PATH" "$SLICE_A" "$SLICE_B" "$MODE" \
  "$OTHER_GRAPH_PATH" "$OTHER_SLICE" "$OTHER_REGISTRY_PATH" <<'NODE'
// WORKGRAPH_NODE_SOURCE_BEGIN
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const {TextDecoder} = require("node:util");

const graphArgument = process.argv[2];
const graphPath = path.resolve(graphArgument);
const command = process.argv[3];
const registryArgument = process.argv[4] || "";
const sliceAArgument = process.argv[5] || "";
const sliceBArgument = process.argv[6] || "";
const modeArgument = process.argv[7] || "";
const otherGraphArgument = process.argv[8] || "";
const otherSliceArgument = process.argv[9] || "";
const otherRegistryArgument = process.argv[10] || "";

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

class JsonNumber {
  constructor(lexeme) {
    this.lexeme = lexeme;
  }

  isIntegerInRange(minimum, maximum) {
    const match = /^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(this.lexeme);
    if (match === null) {
      return false;
    }
    const negative = match[1] === "-";
    const fraction = match[3] || "";
    const coefficient = `${match[2]}${fraction}`;
    const normalizedCoefficient = coefficient.replace(/^0+/, "");
    if (normalizedCoefficient === "") {
      return minimum <= 0n && maximum >= 0n;
    }
    const scale = BigInt(match[4] || "0") - BigInt(fraction.length);
    let integerText;
    if (scale >= 0n) {
      if (BigInt(normalizedCoefficient.length) + scale > BigInt(maximum.toString().length)) {
        return false;
      }
      integerText = `${normalizedCoefficient}${"0".repeat(Number(scale))}`;
    } else {
      const truncatedDigits = -scale;
      if (truncatedDigits > BigInt(coefficient.length)) {
        return false;
      }
      const integerEnd = coefficient.length - Number(truncatedDigits);
      for (let index = integerEnd; index < coefficient.length; index += 1) {
        if (coefficient[index] !== "0") {
          return false;
        }
      }
      integerText = coefficient.slice(0, integerEnd).replace(/^0+/, "") || "0";
    }
    if (integerText.length > maximum.toString().length) {
      return false;
    }
    let integer = BigInt(integerText);
    if (negative) {
      integer = -integer;
    }
    return integer >= minimum && integer <= maximum;
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
    return new JsonNumber(match[0]);
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

function privateInputDescriptor() {
  const raw = process.env.FM_WORKGRAPH_PRIVATE_INPUT_FD;
  if (typeof raw !== "string" || !/^[1-9][0-9]*$/u.test(raw)) {
    fail("WG-E-CORRUPT", "captured private-input descriptor is invalid");
  }
  const descriptor = Number(raw);
  if (!Number.isSafeInteger(descriptor) || descriptor === 0) {
    fail("WG-E-CORRUPT", "captured private-input descriptor is invalid");
  }
  try {
    fs.fstatSync(descriptor);
  } catch (error) {
    fail("WG-E-CORRUPT", `captured private-input descriptor is unavailable: ${error.message}`);
  }
  return descriptor;
}

function capturedDescriptor(name) {
  const variable = {
    graph: "FM_WORKGRAPH_CAPTURED_GRAPH_FD",
    contract: "FM_WORKGRAPH_CAPTURED_CONTRACT_FD",
    registry: "FM_WORKGRAPH_CAPTURED_REGISTRY_FD",
    claims: "FM_WORKGRAPH_CAPTURED_GRAPH_FD",
  }[name];
  if (!variable || process.env[variable] === undefined) return undefined;
  const descriptor = Number(process.env[variable]);
  if (!Number.isInteger(descriptor) || descriptor < 0) {
    fail(command === "__lease-project" ? "WG-E-CAPTURE" : "WG-E-CORRUPT", name + " captured descriptor is invalid");
  }
  return descriptor;
}

const capturedInputCache = new Map();

function captureRegularFile(file, name) {
  let descriptor;
  let captured;
  let capturedError;
  const inherited = capturedDescriptor(name);
  const cacheKey = inherited === undefined ? null : String(inherited);
  if (cacheKey !== null && capturedInputCache.has(cacheKey)) {
    return capturedInputCache.get(cacheKey);
  }
  try {
    if (typeof fs.constants.O_NOFOLLOW !== "number") {
      throw new Error("platform does not support no-follow file opens");
    }
    descriptor = inherited === undefined
      ? fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
      : inherited;
    const stat = fs.fstatSync(descriptor);
    if (!stat.isFile()) {
      throw new Error(`${name} is not a regular file`);
    }
    captured = {bytes: fs.readFileSync(descriptor), stat};
  } catch (error) {
    capturedError = error;
  } finally {
    if (descriptor !== undefined && capturedDescriptor(name) === undefined) {
      try {
        fs.closeSync(descriptor);
      } catch {
        capturedError = capturedError || new Error(`cannot close ${name}`);
      }
    }
  }
  if (capturedError !== undefined) {
    fail(command === "__lease-project" ? "WG-E-CAPTURE" : "WG-E-CORRUPT", `cannot capture ${name}: ${capturedError.message}`);
  }
  if (cacheKey !== null) capturedInputCache.set(cacheKey, captured);
  return captured;
}

const RESOURCE_CONTROL_RE = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;
const RESOURCE_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._~+@=-]{0,127}$/u;
const RESOURCE_NAMESPACES = new Set(["path", "worktree", "branch", "docker", "port", "svc", "db", "ui", "lock"]);
const RESOURCE_WARNING_CODES = Object.freeze({
  malformed: "WG-W-RESOURCE-MALFORMED",
  unknown: "WG-W-RESOURCE-UNKNOWN",
  unregistered: "WG-W-RESOURCE-UNREGISTERED",
  alias: "WG-W-CLAIM-ALIAS",
  duplicate: "WG-W-CLAIM-DUPLICATE",
  conflict: "WG-W-CLAIM-CONFLICT",
  broadened: "WG-W-CLAIM-BROADENED",
});

function resourceFailure(code, message) {
  const error = new Error(message);
  error.resourceCode = code;
  throw error;
}

function rejectResourceText(value) {
  if (typeof value !== "string" || value.length === 0) {
    resourceFailure("WG-R-MALFORMED", "resource must be a non-empty string");
  }
  if (Buffer.byteLength(value, "utf8") > 4096) {
    resourceFailure("WG-R-LIMIT", "resource exceeds 4096 UTF-8 bytes");
  }
  for (const character of value) {
    const code = character.codePointAt(0);
    if (code >= 0xd800 && code <= 0xdfff) {
      resourceFailure("WG-R-MALFORMED", "resource contains a non-scalar Unicode value");
    }
  }
  if (RESOURCE_CONTROL_RE.test(value)) {
    resourceFailure("WG-R-MALFORMED", "resource contains a control character");
  }
  if (/[\\%?#]/u.test(value)) {
    resourceFailure("WG-R-MALFORMED", "resource contains an ambiguous separator or encoding");
  }
  if (value.trim() !== value) {
    resourceFailure("WG-R-MALFORMED", "resource has leading or trailing whitespace");
  }
}

function requireResourceName(value, label) {
  if (!RESOURCE_NAME_RE.test(value)) {
    resourceFailure("WG-R-MALFORMED", `${label} has a malformed identifier`);
  }
  return value;
}

function splitResource(raw) {
  rejectResourceText(raw);
  const match = /^([a-z][a-z0-9+.-]*):\/\/(.*)$/u.exec(raw);
  if (match === null) {
    resourceFailure("WG-R-MALFORMED", "resource must use namespace:// form");
  }
  const namespace = match[1];
  if (!RESOURCE_NAMESPACES.has(namespace)) {
    resourceFailure("WG-R-UNKNOWN", `unknown resource namespace '${namespace}'`);
  }
  const segments = match[2].split("/");
  if (segments.length > 1024) {
    resourceFailure("WG-R-LIMIT", "resource exceeds 1024 structural segments");
  }
  return {namespace, rest: match[2]};
}

function normalizePosixResourcePath(raw, namespace) {
  if (!raw.startsWith("/")) {
    resourceFailure("WG-R-MALFORMED", `${namespace} requires an absolute POSIX path`);
  }
  if (raw.startsWith("//") || raw.includes("//")) {
    resourceFailure("WG-R-MALFORMED", `${namespace} rejects ambiguous repeated separators`);
  }
  const parts = raw.split("/");
  const segments = [];
  for (let index = 1; index < parts.length; index += 1) {
    const segment = parts[index];
    if (segment === "" && index !== parts.length - 1) {
      resourceFailure("WG-R-MALFORMED", `${namespace} contains an empty path segment`);
    }
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      if (segments.length === 0) {
        resourceFailure("WG-R-TRAVERSAL", `${namespace} traverses above POSIX root`);
      }
      segments.pop();
      continue;
    }
    segments.push(segment);
  }

  let existingPrefix = "/";
  let prefixIndex = 0;
  for (let index = segments.length; index >= 0; index -= 1) {
    const candidate = index === 0 ? "/" : `/${segments.slice(0, index).join("/")}`;
    try {
      fs.lstatSync(candidate);
      existingPrefix = candidate;
      prefixIndex = index;
      break;
    } catch (error) {
      if (error && (error.code === "ENOENT" || error.code === "ENOTDIR")) continue;
      resourceFailure("WG-R-FS", `cannot inspect POSIX prefix: ${error.message}`);
    }
  }
  let resolvedPrefix;
  let resolvedStat;
  try {
    resolvedPrefix = fs.realpathSync(existingPrefix);
    resolvedStat = fs.statSync(existingPrefix);
  } catch (error) {
    resourceFailure("WG-R-FS", `cannot resolve existing POSIX prefix: ${error.message}`);
  }
  const suffix = segments.slice(prefixIndex);
  if (suffix.length > 0 && !resolvedStat.isDirectory()) {
    resourceFailure("WG-R-FS", "existing POSIX prefix is not a directory");
  }
  const resolved = suffix.length === 0
    ? path.posix.normalize(resolvedPrefix)
    : path.posix.join(resolvedPrefix, ...suffix);
  return `${namespace}://${resolved}`;
}

function splitNamedSegments(rest, label, expected) {
  if (rest.includes("//") || rest.endsWith("/")) {
    resourceFailure("WG-R-MALFORMED", `${label} has ambiguous separators`);
  }
  const segments = rest.split("/");
  if (segments.length !== expected || segments.some((segment) => segment.length === 0)) {
    resourceFailure("WG-R-MALFORMED", `${label} has the wrong authority/segment shape`);
  }
  segments.forEach((segment) => requireResourceName(segment, `${label} segment`));
  return segments;
}

function canonicalIPv4(host) {
  if (!/^[0-9.]+$/u.test(host)) return undefined;
  const parts = host.split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d+$/u.test(part))) {
    resourceFailure("WG-R-MALFORMED", "port host has malformed IPv4 authority");
  }
  parts.forEach((part) => {
    if ((part.length > 1 && part.startsWith("0")) || Number(part) > 255) {
      resourceFailure("WG-R-MALFORMED", "port host is not a canonical IPv4 literal");
    }
  });
  return parts.join(".");
}

function parseHextets(text) {
  if (text === "") return [];
  const parts = text.split(":");
  if (parts.some((part) => !/^[0-9A-Fa-f]{1,4}$/u.test(part))) {
    resourceFailure("WG-R-MALFORMED", "port host has malformed IPv6 hextets");
  }
  return parts.map((part) => Number.parseInt(part, 16));
}

function canonicalIPv6(host) {
  if (!host.startsWith("[") && !host.endsWith("]")) return undefined;
  if (!/^\[[0-9A-Fa-f:]+\]$/u.test(host)) {
    resourceFailure("WG-R-MALFORMED", "port host has malformed IPv6 authority");
  }
  const inner = host.slice(1, -1);
  const doubleCount = (inner.match(/::/g) || []).length;
  if (doubleCount > 1) resourceFailure("WG-R-MALFORMED", "IPv6 contains multiple compression markers");
  let groups;
  if (doubleCount === 1) {
    const [leftText, rightText] = inner.split("::");
    const left = parseHextets(leftText);
    const right = parseHextets(rightText);
    if (left.length + right.length >= 8) resourceFailure("WG-R-MALFORMED", "IPv6 compression marker does not compress");
    groups = left.concat(new Array(8 - left.length - right.length).fill(0), right);
  } else {
    groups = parseHextets(inner);
    if (groups.length !== 8) resourceFailure("WG-R-MALFORMED", "IPv6 requires eight hextets without compression");
  }
  let bestStart = -1;
  let bestLength = 1;
  for (let index = 0; index < groups.length;) {
    if (groups[index] !== 0) {
      index += 1;
      continue;
    }
    const start = index;
    while (index < groups.length && groups[index] === 0) index += 1;
    if (index - start > bestLength) {
      bestStart = start;
      bestLength = index - start;
    }
  }
  const hex = (value) => value.toString(16);
  if (bestStart < 0) return `[${groups.map(hex).join(":")}]`;
  const end = bestStart + bestLength;
  const left = groups.slice(0, bestStart).map(hex).join(":");
  const right = groups.slice(end).map(hex).join(":");
  if (bestStart === 0) return `[::${right}]`;
  if (end === groups.length) return `[${left}::]`;
  return `[${left}::${right}]`;
}

function normalizeHost(host) {
  const ipv6 = canonicalIPv6(host);
  if (ipv6 !== undefined) return ipv6;
  const ipv4 = canonicalIPv4(host);
  if (ipv4 !== undefined) return ipv4;
  if (host !== host.toLowerCase() || Buffer.byteLength(host, "utf8") > 253) {
    resourceFailure("WG-R-MALFORMED", "port host must be lowercase ASCII");
  }
  const labels = host.split(".");
  if (labels.some((label) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(label))) {
    resourceFailure("WG-R-MALFORMED", "port host is not an RFC-1123 DNS name");
  }
  return host;
}

function normalizeResource(raw) {
  const {namespace, rest} = splitResource(raw);
  if (namespace === "path" || namespace === "worktree") {
    return normalizePosixResourcePath(rest, namespace);
  }
  if (namespace === "branch") {
    const slash = rest.indexOf("/");
    if (slash <= 0 || slash === rest.length - 1) {
      resourceFailure("WG-R-MALFORMED", "branch requires repository and ref segments");
    }
    const repository = rest.slice(0, slash);
    const ref = rest.slice(slash + 1);
    requireResourceName(repository, "branch repository");
    const components = ref.split("/");
    if (components.some((component) => component.length === 0)) {
      resourceFailure("WG-R-MALFORMED", "branch ref has an empty component");
    }
    components.forEach((component) => {
      requireResourceName(component, "branch ref");
      if (component.startsWith(".") || component.startsWith("-") || component.endsWith(".") || component.endsWith(".lock")
        || component.includes("..") || component.includes("@{") || /[~^:?*\[]/u.test(component)) {
        resourceFailure("WG-R-MALFORMED", "branch ref violates Git ref restrictions");
      }
    });
    return `branch://${repository}/${ref}`;
  }
  if (namespace === "docker") {
    const segments = rest.split("/");
    if (segments.length < 1 || segments.length > 2 || segments.some((segment) => segment.length === 0)) {
      resourceFailure("WG-R-MALFORMED", "docker requires a kind and optional instance");
    }
    const kind = segments[0];
    if (!["project", "network", "volume", "container"].includes(kind)) {
      resourceFailure("WG-R-MALFORMED", "docker kind is not supported");
    }
    if (segments.length === 1) return `docker://${kind}`;
    if (!/^[a-z0-9][a-z0-9_.-]{0,127}$/u.test(segments[1])) {
      resourceFailure("WG-R-MALFORMED", "docker instance is not lowercase canonical form");
    }
    return `docker://${kind}/${segments[1]}`;
  }
  if (namespace === "port") {
    const separator = rest.indexOf("/");
    if (separator <= 0 || separator !== rest.lastIndexOf("/")) {
      resourceFailure("WG-R-MALFORMED", "port requires host and port segments");
    }
    const host = normalizeHost(rest.slice(0, separator));
    const portText = rest.slice(separator + 1);
    if (!/^\d+$/u.test(portText)) resourceFailure("WG-R-PORT", "port must be an ASCII decimal integer");
    const port = BigInt(portText);
    if (port < 1n || port > 65535n) resourceFailure("WG-R-PORT", "port must be between 1 and 65535");
    return `port://${host}/${port.toString()}`;
  }
  if (["svc", "db", "ui"].includes(namespace)) {
    const [authority, instance] = splitNamedSegments(rest, namespace, 2);
    return `${namespace}://${authority.toLowerCase()}/${instance}`;
  }
  if (namespace === "lock") {
    const [name] = splitNamedSegments(rest, namespace, 1);
    return `lock://${name}`;
  }
  resourceFailure("WG-R-UNKNOWN", `unknown resource namespace '${namespace}'`);
}

function warningCodeFor(error) {
  return error && error.resourceCode === "WG-R-UNKNOWN"
    ? RESOURCE_WARNING_CODES.unknown
    : RESOURCE_WARNING_CODES.malformed;
}

function canonicalIdJson(value) {
  return JSON.stringify(value).replace(/[^\x20-\x7e]/gu, (character) => {
    const code = character.codePointAt(0);
    if (code <= 0xffff) return `\\u${code.toString(16).padStart(4, "0")}`;
    const adjusted = code - 0x10000;
    const high = 0xd800 + (adjusted >> 10);
    const low = 0xdc00 + (adjusted & 0x3ff);
    return `\\u${high.toString(16)}\\u${low.toString(16)}`;
  });
}

function registryRoots(registry) {
  return registry.instances.filter((instance) => !registry.parentByChild.has(instance.id));
}

function registryCanContain(root, resource, namespace) {
  if (root.namespace !== namespace || root.resource === resource) return false;
  if (namespace === "path" || namespace === "worktree") {
    return resource.startsWith(`${root.resource}/`);
  }
  if (namespace === "branch") {
    const rootSlash = root.resource.indexOf("/");
    const targetSlash = resource.indexOf("/");
    return rootSlash > 0 && targetSlash > 0
      && root.resource.slice(0, rootSlash) === resource.slice(0, targetSlash)
      && resource.startsWith(`${root.resource}/`);
  }
  if (namespace === "docker") {
    const rootKind = root.resource.slice("docker://".length);
    if (!rootKind.includes("/")) {
      return resource.startsWith(`docker://${rootKind}/`);
    }
  }
  return false;
}

function validateRegistry(value) {
  const registry = strictObject(value, "registry", ["schema_version", "instances"]);
  if (required(registry, "schema_version", "registry") !== "resource-registry/v1") {
    fail("WG-E-REGISTRY", "unknown resource registry schema version");
  }
  const instances = array(required(registry, "instances", "registry"), "registry.instances");
  const byId = new Map();
  const byResource = new Map();
  const parentByChild = new Map();
  const entries = [];
  const bindResource = (canonical, instance, kind) => {
    const prior = byResource.get(canonical);
    if (prior !== undefined) {
      fail("WG-E-REGISTRY", `${kind} resolves to more than one instance`);
    }
    byResource.set(canonical, {instance, kind});
  };
  instances.forEach((instance, index) => {
    const item = strictObject(instance, `registry.instances[${index}]`, ["id", "namespace", "resource", "aliases", "contains"]);
    const id = required(item, "id", `registry.instances[${index}]`);
    safeId(id, `registry.instances[${index}].id`);
    if (byId.has(id)) fail("WG-E-REGISTRY", `duplicate registry instance id '${id}'`);
    const namespace = required(item, "namespace", `registry.instances[${index}]`);
    if (typeof namespace !== "string" || !RESOURCE_NAMESPACES.has(namespace)) fail("WG-E-REGISTRY", `registry.instances[${index}] has an unknown namespace`);
    const resource = required(item, "resource", `registry.instances[${index}]`);
    nonemptyString(resource, `registry.instances[${index}].resource`);
    let canonical;
    try {
      canonical = normalizeResource(resource);
    } catch (error) {
      fail("WG-E-REGISTRY", `registry.instances[${index}].resource is invalid: ${error.message}`);
    }
    if (canonical !== resource || canonical.slice(0, canonical.indexOf("://")) !== namespace) {
      fail("WG-E-REGISTRY", `registry.instances[${index}].resource must be canonical and match namespace`);
    }
    const aliases = array(required(item, "aliases", `registry.instances[${index}]`), `registry.instances[${index}].aliases`);
    const contains = array(required(item, "contains", `registry.instances[${index}]`), `registry.instances[${index}].contains`);
    const entry = {id, namespace, resource, aliases, contains};
    byId.set(id, entry);
    entries.push(entry);
    bindResource(resource, entry, "exact");
    const seenAliases = new Set();
    aliases.forEach((alias, aliasIndex) => {
      nonemptyString(alias, `registry.instances[${index}].aliases[${aliasIndex}]`);
      let aliasCanonical;
      try {
        aliasCanonical = normalizeResource(alias);
      } catch (error) {
        fail("WG-E-REGISTRY", `registry.instances[${index}].aliases[${aliasIndex}] is invalid: ${error.message}`);
      }
      if (aliasCanonical === resource || seenAliases.has(aliasCanonical)
        || aliasCanonical.slice(0, aliasCanonical.indexOf("://")) !== namespace) {
        fail("WG-E-REGISTRY", `registry.instances[${index}].aliases[${aliasIndex}] is not a unique same-namespace alias`);
      }
      seenAliases.add(aliasCanonical);
      bindResource(aliasCanonical, entry, "alias");
    });
  });
  entries.forEach((entry) => {
    const seenChildren = new Set();
    entry.contains.forEach((child, childIndex) => {
      if (typeof child !== "string" || !byId.has(child)) fail("WG-E-REGISTRY", `registry.instances[${entry.id}].contains[${childIndex}] is undefined`);
      if (seenChildren.has(child)) fail("WG-E-REGISTRY", `registry.instances[${entry.id}] contains a duplicate child`);
      if (child === entry.id) fail("WG-E-REGISTRY", `registry instance '${entry.id}' contains itself`);
      if (parentByChild.has(child)) fail("WG-E-REGISTRY", `registry instance '${child}' has more than one parent`);
      seenChildren.add(child);
      parentByChild.set(child, entry.id);
    });
  });
  const colors = new Map();
  const visit = (id) => {
    const color = colors.get(id) || 0;
    if (color === 1) fail("WG-E-REGISTRY", "registry containment contains a cycle");
    if (color === 2) return;
    colors.set(id, 1);
    byId.get(id).contains.forEach(visit);
    colors.set(id, 2);
  };
  entries.forEach((entry) => visit(entry.id));
  return {instances: entries, byResource, parentByChild, roots: registryRoots({instances: entries, parentByChild})};
}

function loadRegistry(argument) {
  if (argument === "") return undefined;
  const capture = captureRegularFile(path.resolve(argument), "registry");
  const validated = validateRegistry(parseStrictJson(capture.bytes, "registry"));
  validated.digest = crypto.createHash("sha256").update(capture.bytes).digest("hex");
  return validated;
}

function lintClaims(claims, registry, name = "claims") {
  const warnings = [];
  const projections = [];
  if (!Array.isArray(claims)) {
    warnings.push({index: 0, code: RESOURCE_WARNING_CODES.malformed});
    return {warnings, projections, claimCount: 0, resolvedCount: 0};
  }
  claims.forEach((claim, index) => {
    let resolution = "malformed";
    let canonical = null;
    let effectiveMode = "exclusive";
    let effectiveScope = "global";
    let requestedMode;
    if (claim === null || typeof claim !== "object" || Array.isArray(claim)
      || Object.keys(claim).some((key) => !["resource", "mode"].includes(key))
      || typeof claim.resource !== "string" || !["read", "write", "exclusive"].includes(claim.mode)) {
      warnings.push({index, code: RESOURCE_WARNING_CODES.malformed});
    } else {
      requestedMode = claim.mode;
      try {
        const normalized = normalizeResource(claim.resource);
        canonical = normalized;
        effectiveMode = requestedMode;
        if (registry === undefined) {
          resolution = "exact";
          effectiveScope = "exact";
        } else {
          const binding = registry.byResource.get(normalized);
          if (binding === undefined) {
            resolution = "unregistered";
            effectiveMode = "exclusive";
            const namespace = normalized.slice(0, normalized.indexOf("://"));
            warnings.push({index, code: RESOURCE_WARNING_CODES.unregistered});
            const roots = registry.roots.filter((root) => registryCanContain(root, normalized, namespace));
            if (roots.length === 1) {
              effectiveScope = `container:${roots[0].id}`;
              warnings.push({index, code: RESOURCE_WARNING_CODES.broadened});
            } else if (roots.length > 1) {
              resolution = "ambiguous";
              effectiveScope = "global";
              warnings.push({index, code: RESOURCE_WARNING_CODES.broadened});
            } else {
              effectiveScope = "global";
              warnings.push({index, code: RESOURCE_WARNING_CODES.broadened});
            }
          } else {
            resolution = binding.kind === "alias" ? "alias" : "exact";
            canonical = binding.instance.resource;
            effectiveScope = `exact:${canonical}`;
            if (resolution === "alias") warnings.push({index, code: RESOURCE_WARNING_CODES.alias});
          }
        }
      } catch (error) {
        resolution = error && error.resourceCode === "WG-R-UNKNOWN" ? "unknown" : "malformed";
        canonical = null;
        effectiveMode = "exclusive";
        effectiveScope = "global";
        warnings.push({index, code: resolution === "unknown" ? RESOURCE_WARNING_CODES.unknown : RESOURCE_WARNING_CODES.malformed});
      }
    }
    projections.push({index, resolution, canonical, effectiveMode, effectiveScope});
  });
  const seen = new Map();
  projections.forEach((projection) => {
    if (projection.canonical === null) return;
    const prior = seen.get(projection.canonical);
    if (prior === undefined) {
      seen.set(projection.canonical, projection);
      return;
    }
    warnings.push({
      index: projection.index,
      code: prior.effectiveMode === projection.effectiveMode ? RESOURCE_WARNING_CODES.duplicate : RESOURCE_WARNING_CODES.conflict,
    });
  });
  warnings.sort((left, right) => {
    if (left.index !== right.index) return left.index - right.index;
    return left.code < right.code ? -1 : left.code > right.code ? 1 : 0;
  });
  const resolvedCount = projections.filter((projection) => projection.resolution === "exact" || projection.resolution === "alias").length;
  return {warnings, projections, claimCount: claims.length, resolvedCount};
}

function emitLint(result) {
  console.log(`resource_lint=${result.warnings.length === 0 ? "pass" : "warn"}`);
  console.log(`resource_claim_count=${result.claimCount}`);
  console.log(`resource_resolved_count=${result.resolvedCount}`);
  console.log(`resource_warning_count=${result.warnings.length}`);
  const codes = [...new Set(result.warnings.map((warning) => warning.code))];
  console.log(`resource_warning_codes=${codes.length === 0 ? "none" : codes.join(",")}`);
  result.projections.forEach((projection) => {
    console.log(`claim[${projection.index}].resolution=${projection.resolution}`);
    console.log(`claim[${projection.index}].canonical_id_json=${projection.canonical === null ? "null" : canonicalIdJson(projection.canonical)}`);
    console.log(`claim[${projection.index}].effective_mode=${projection.effectiveMode}`);
    console.log(`claim[${projection.index}].effective_scope=${projection.effectiveScope}`);
  });
  result.warnings.forEach((warning, warningIndex) => {
    console.log(`resource_warning[${warningIndex}].code=${warning.code}`);
    console.log(`resource_warning[${warningIndex}].claim=${warning.index}`);
  });
}

function strictClaimsInput(value, name) {
  let claims = value;
  if (!Array.isArray(value)) {
    const input = strictObject(value, name, ["schema_version", "claims"]);
    if (Object.prototype.hasOwnProperty.call(input, "schema_version") && input.schema_version !== "resource-claims/v1") {
      fail("WG-E-SCHEMA", `${name}.schema_version is unknown`);
    }
    claims = required(input, "claims", name);
  }
  if (!Array.isArray(claims)) fail("WG-E-SCHEMA", `${name}.claims must be an array`);
  claims.forEach((claim, index) => {
    const item = strictObject(claim, `${name}[${index}]`, ["resource", "mode"]);
    nonemptyString(required(item, "resource", `${name}[${index}]`), `${name}[${index}].resource`);
    if (!["read", "write", "exclusive"].includes(required(item, "mode", `${name}[${index}]`))) {
      fail("WG-E-CLAIM", `${name}[${index}].mode must be read|write|exclusive`);
    }
  });
  return claims;
}

function validateContractShape(contract, goalId, sliceId) {
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
  if (dependencies.length !== 0) fail("WG-E-CORRUPT", "a one-node graph cannot have predecessors");
  array(required(contract, "immutable_inputs", "contract"), "contract.immutable_inputs").forEach((input, index) => {
    const item = strictObject(input, `contract.immutable_inputs[${index}]`, ["path", "sha256"]);
    nonemptyString(required(item, "path", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].path`);
    sha256(required(item, "sha256", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].sha256`);
  });
  stringArray(required(contract, "outputs", "contract"), "contract.outputs", false);
  const contractClaims = required(contract, "claims", "contract");
  if (!Array.isArray(contractClaims) || contractClaims.length === 0) fail("WG-E-SCHEMA", "contract.claims must be a non-empty array");
  contractClaims.forEach((claim, index) => {
    const item = strictObject(claim, `contract.claims[${index}]`, ["resource", "mode"]);
    nonemptyString(required(item, "resource", `contract.claims[${index}]`), `contract.claims[${index}].resource`);
    if (!["read", "write", "exclusive"].includes(required(item, "mode", `contract.claims[${index}]`))) {
      fail("WG-E-CLAIM", "claim mode must be read|write|exclusive");
    }
  });
  ["worktree", "harness", "model", "effort", "implementer"].forEach((field) => {
    nonemptyString(required(contract, field, "contract"), `contract.${field}`);
  });
  stringArray(required(contract, "acceptance", "contract"), "contract.acceptance", false);
  stringArray(required(contract, "validation_commands", "contract"), "contract.validation_commands", false);
  stringArray(required(contract, "expected_evidence", "contract"), "contract.expected_evidence", false);
  const contextBudget = strictObject(required(contract, "context_budget", "contract"), "contract.context_budget", ["source_tokens", "report_words"]);
  const maxContextInteger = 9007199254740991n;
  for (const field of ["source_tokens", "report_words"]) {
    const value = required(contextBudget, field, "contract.context_budget");
    if (!(value instanceof JsonNumber) || !value.isIntegerInRange(1n, maxContextInteger)) {
      fail("WG-E-CORRUPT", `contract.context_budget.${field} must be a positive integer`);
    }
  }
  stringArray(required(contract, "gates", "contract"), "contract.gates", false);
  stringArray(required(contract, "independent_validators", "contract"), "contract.independent_validators", false);
  stringArray(required(contract, "authorized_exceptions", "contract"), "contract.authorized_exceptions");
  return contract;
}

function validateGraphForLint(input) {
  const graph = strictObject(input, "graph", ["schema_version", "goal_id", "slices"]);
  if (required(graph, "schema_version", "graph") !== "workgraph/v1") fail("WG-E-SCHEMA", "unknown graph schema version");
  const goalId = required(graph, "goal_id", "graph");
  safeId(goalId, "graph.goal_id");
  const slices = array(required(graph, "slices", "graph"), "graph.slices", false);
  if (slices.length !== 1) fail("WG-E-NODES", `Slice 2 requires exactly one node; found ${slices.length}`);
  const reference = strictObject(slices[0], "graph.slices[0]", ["slice_id", "contract_path", "contract_sha256"]);
  const sliceId = required(reference, "slice_id", "graph.slices[0]");
  safeId(sliceId, "graph.slices[0].slice_id");
  const contractPath = nonemptyString(required(reference, "contract_path", "graph.slices[0]"), "graph.slices[0].contract_path");
  const pathParts = contractPath.split(/[\\/]/);
  if (path.isAbsolute(contractPath) || pathParts.some((part) => part === "" || part === "." || part === "..") || RESOURCE_CONTROL_RE.test(contractPath)) {
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
    if (relativeContract === ".." || relativeContract.startsWith(`..${path.sep}`) || path.isAbsolute(relativeContract)) fail("WG-E-ID", "contract must remain under the graph directory");
    const resolvedStat = fs.statSync(contractReal);
    if (resolvedStat.dev !== contractCapture.stat.dev || resolvedStat.ino !== contractCapture.stat.ino) fail("WG-E-CORRUPT", "contract path changed while it was captured");
  } catch (error) {
    if (error && typeof error.code === "string" && error.code.startsWith("WG-E-")) throw error;
    fail("WG-E-CORRUPT", `cannot resolve contract: ${error.message}`);
  }
  const actualDigest = crypto.createHash("sha256").update(contractCapture.bytes).digest("hex");
  if (actualDigest !== contractDigest) fail("WG-E-HASH", `contract SHA-256 mismatch; expected ${contractDigest}, got ${actualDigest}`);
  const contract = strictObject(parseStrictJson(contractCapture.bytes, "contract"), "contract", [
    "schema_version", "slice_id", "goal_id", "purpose", "type", "depends_on",
    "immutable_inputs", "outputs", "claims", "worktree", "harness", "model",
    "effort", "acceptance", "validation_commands", "expected_evidence",
    "context_budget", "gates", "implementer", "independent_validators",
    "authorized_exceptions",
  ]);
  return validateContractShape(contract, goalId, sliceId).claims;
}

const NEW_ERROR_MESSAGES = Object.freeze({
  "WG-E-NODES": "graph.slices must contain 1..256 entries",
  "WG-E-DEPENDENCY": "graph dependencies are invalid",
  "WG-E-CYCLE": "graph dependencies contain a cycle",
  "WG-E-DUPLICATE": "graph slice identifiers and contract paths must be unique",
  "WG-E-WORKTREE": "canonical worktrees must be unique",
  "WG-E-OUTPUT": "contract outputs are invalid",
  "WG-E-AUDIT-WRITE": "audit slices require read-only claims",
  "WG-E-INTEGRATION": "integration slice contract is invalid",
  "WG-E-MODE": "parallelism mode resolution failed",
  "WG-E-SELECTOR": "selectors must be distinct existing slice IDs",
  "WG-E-INTERNAL": "wave calculation made no progress",
  "WG-E-SELF": "selected claims cannot be represented by a durable lease scope",
});

function failNew(code) {
  console.error(`fm-workgraph: ${code}: ${NEW_ERROR_MESSAGES[code]}`);
  process.exit(1);
}

function safeRelativeContractPath(value) {
  const parts = value.split(/[\\/]/u);
  if (path.isAbsolute(value) || parts.some((part) => part === "" || part === "." || part === "..")
    || RESOURCE_CONTROL_RE.test(value)) {
    fail("WG-E-ID", "contract_path must be a safe relative path");
  }
}

function captureContractV4(graphPathValue, graphDirectoryReal, reference, referenceIndex) {
  const contractPath = nonemptyString(required(reference, "contract_path", `graph.slices[${referenceIndex}]`), `graph.slices[${referenceIndex}].contract_path`);
  safeRelativeContractPath(contractPath);
  const digest = required(reference, "contract_sha256", `graph.slices[${referenceIndex}]`);
  sha256(digest, `graph.slices[${referenceIndex}].contract_sha256`);
  const resolvedPath = path.resolve(path.dirname(graphPathValue), contractPath);
  let capture;
  let realPath;
  try {
    capture = captureRegularFile(resolvedPath, "contract");
    if (capturedDescriptor("contract") === undefined) {
      realPath = fs.realpathSync(resolvedPath);
    const relative = path.relative(graphDirectoryReal, realPath);
    if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
      fail("WG-E-ID", "contract must remain under the graph directory");
    }
    const resolvedStat = fs.statSync(realPath);
      if (resolvedStat.dev !== capture.stat.dev || resolvedStat.ino !== capture.stat.ino) {
        fail("WG-E-CORRUPT", "contract path changed while it was captured");
      }
    }
  } catch (error) {
    if (error && typeof error.code === "string" && error.code.startsWith("WG-E-")) throw error;
    fail("WG-E-CORRUPT", `cannot resolve contract: ${error.message}`);
  }
  const actualDigest = crypto.createHash("sha256").update(capture.bytes).digest("hex");
  if (actualDigest !== digest) {
    fail(command === "__lease-project" ? "WG-E-CAPTURE" : "WG-E-HASH", `contract SHA-256 mismatch; expected ${digest}, got ${actualDigest}`);
  }
  return {contractPath, digest, capture};
}

function validateContractShapeV4(contract, goalId, sliceId) {
  const allowed = [
    "schema_version", "slice_id", "goal_id", "purpose", "type", "depends_on",
    "immutable_inputs", "outputs", "claims", "worktree", "harness", "model",
    "effort", "acceptance", "validation_commands", "expected_evidence",
    "context_budget", "gates", "implementer", "independent_validators",
    "authorized_exceptions",
  ];
  strictObject(contract, "contract", allowed);
  if (required(contract, "schema_version", "contract") !== "slice-contract/v1") {
    fail("WG-E-SCHEMA", "unknown contract schema version");
  }
  if (required(contract, "slice_id", "contract") !== sliceId) {
    fail(command === "__lease-project" ? "WG-E-CAPTURE" : "WG-E-CORRUPT", "contract.slice_id does not match graph reference");
  }
  if (required(contract, "goal_id", "contract") !== goalId) {
    fail(command === "__lease-project" ? "WG-E-CAPTURE" : "WG-E-CORRUPT", "contract.goal_id does not match graph goal");
  }
  nonemptyString(required(contract, "purpose", "contract"), "contract.purpose");
  const type = required(contract, "type", "contract");
  if (!["ship", "scout", "audit", "integration"].includes(type)) {
    fail("WG-E-CORRUPT", "contract.type must be ship|scout|audit|integration");
  }
  const dependencies = array(required(contract, "depends_on", "contract"), "contract.depends_on");
  if (dependencies.length > 255) fail("WG-E-SCHEMA", "contract.depends_on has too many entries");
  dependencies.forEach((dependency, index) => safeId(dependency, `contract.depends_on[${index}]`));
  array(required(contract, "immutable_inputs", "contract"), "contract.immutable_inputs").forEach((input, index) => {
    const item = strictObject(input, `contract.immutable_inputs[${index}]`, ["path", "sha256"]);
    nonemptyString(required(item, "path", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].path`);
    sha256(required(item, "sha256", `contract.immutable_inputs[${index}]`), `contract.immutable_inputs[${index}].sha256`);
  });
  const outputs = array(required(contract, "outputs", "contract"), "contract.outputs", false);
  if (outputs.length > 64) fail("WG-E-SCHEMA", "contract.outputs has too many entries");
  outputs.forEach((output, index) => nonemptyString(output, `contract.outputs[${index}]`));
  const claimsValue = required(contract, "claims", "contract");
  if (!Array.isArray(claimsValue) || claimsValue.length === 0) fail("WG-E-SCHEMA", "contract.claims must be a non-empty array");
  const claims = claimsValue;
  if (claims.length > 64) fail("WG-E-SCHEMA", "contract.claims has too many entries");
  claims.forEach((claim, index) => {
    const item = strictObject(claim, `contract.claims[${index}]`, ["resource", "mode"]);
    nonemptyString(required(item, "resource", `contract.claims[${index}]`), `contract.claims[${index}].resource`);
    if (!["read", "write", "exclusive"].includes(required(item, "mode", `contract.claims[${index}]`))) {
      fail("WG-E-CLAIM", "claim mode must be read|write|exclusive");
    }
  });
  ["worktree", "harness", "model", "effort", "implementer"].forEach((field) => {
    nonemptyString(required(contract, field, "contract"), `contract.${field}`);
  });
  stringArray(required(contract, "acceptance", "contract"), "contract.acceptance", false);
  stringArray(required(contract, "validation_commands", "contract"), "contract.validation_commands", false);
  stringArray(required(contract, "expected_evidence", "contract"), "contract.expected_evidence", false);
  const contextBudget = strictObject(required(contract, "context_budget", "contract"), "contract.context_budget", ["source_tokens", "report_words"]);
  const maxContextInteger = 9007199254740991n;
  for (const field of ["source_tokens", "report_words"]) {
    const value = required(contextBudget, field, "contract.context_budget");
    if (!(value instanceof JsonNumber) || !value.isIntegerInRange(1n, maxContextInteger)) {
      fail("WG-E-CORRUPT", `contract.context_budget.${field} must be a positive integer`);
    }
  }
  stringArray(required(contract, "gates", "contract"), "contract.gates", false);
  stringArray(required(contract, "independent_validators", "contract"), "contract.independent_validators", false);
  stringArray(required(contract, "authorized_exceptions", "contract"), "contract.authorized_exceptions");
  return contract;
}

function pathValue(canonical) {
  return canonical.slice(canonical.indexOf("://") + 3);
}

function pathAncestorsOverlap(left, right) {
  const under = (child, parent) => parent === "/" ? child.startsWith("/") : child.startsWith(`${parent}/`);
  return left === right || under(left, right) || under(right, left);
}

function normalizeWorktreeV4(worktree) {
  try {
    if (!worktree.startsWith("/")) throw new Error("worktree must be absolute");
    return normalizeResource(`worktree://${worktree}`);
  } catch {
    failNew("WG-E-WORKTREE");
  }
}

function deriveOutputsV4(outputs, canonicalWorktree) {
  const worktreePath = pathValue(canonicalWorktree);
  const derived = [];
  outputs.forEach((output) => {
    let canonical;
    try {
      if (output.startsWith("path://")) {
        canonical = normalizeResource(output);
      } else if (output.startsWith("/")) {
        canonical = normalizeResource(`path://${output}`);
      } else {
        if (output.includes("\\") || output.includes("//") || output.includes("%") || output.includes("?")
          || output.includes("#") || RESOURCE_CONTROL_RE.test(output)) throw new Error("unsafe output path");
        const parts = output.split("/");
        if (parts.length === 0 || parts.some((part) => part.length === 0 || part === "." || part === "..")) {
          throw new Error("unsafe output path");
        }
        canonical = normalizeResource(`path://${path.posix.join(worktreePath, output)}`);
        if (!pathAncestorsOverlap(pathValue(canonical), worktreePath)) throw new Error("output escaped worktree");
      }
    } catch {
      failNew("WG-E-OUTPUT");
    }
    derived.push(canonical);
  });
  for (let left = 0; left < derived.length; left += 1) {
    for (let right = left + 1; right < derived.length; right += 1) {
      if (pathAncestorsOverlap(pathValue(derived[left]), pathValue(derived[right]))) failNew("WG-E-OUTPUT");
    }
  }
  return derived;
}

function validateIntegrationV4(contract, claims) {
  if (contract.type !== "integration") return;
  let integrationCount = 0;
  claims.forEach((claim) => {
    let canonical;
    try { canonical = normalizeResource(claim.resource); } catch { return; }
    if (canonical === "lock://FIRSTMATE-INTEGRATION") {
      integrationCount += 1;
      if (claim.mode !== "exclusive") failNew("WG-E-INTEGRATION");
    }
  });
  if (contract.implementer !== "Firstmate" || integrationCount !== 1) failNew("WG-E-INTEGRATION");
}

function validateSlice4Graph(graph, graphPathValue, graphCapture) {
  const strictGraph = strictObject(graph, "graph", ["schema_version", "goal_id", "slices"]);
  if (required(strictGraph, "schema_version", "graph") !== "workgraph/v1") fail("WG-E-SCHEMA", "unknown graph schema version");
  const goalIdValue = required(strictGraph, "goal_id", "graph");
  safeId(goalIdValue, "graph.goal_id");
  const references = required(strictGraph, "slices", "graph");
  if (!Array.isArray(references) || references.length < 1 || references.length > 256) failNew("WG-E-NODES");
  const graphDirectoryReal = command === "__lease-project"
    ? path.dirname(graphPathValue)
    : fs.realpathSync(path.dirname(graphPathValue));
  const seenSliceIds = new Set();
  const seenContractPaths = new Set();
  const nodes = [];
  references.forEach((reference, index) => {
    const item = strictObject(reference, `graph.slices[${index}]`, ["slice_id", "contract_path", "contract_sha256"]);
    const sliceIdValue = required(item, "slice_id", `graph.slices[${index}]`);
    safeId(sliceIdValue, `graph.slices[${index}].slice_id`);
    const contractPathValue = nonemptyString(required(item, "contract_path", `graph.slices[${index}]`), `graph.slices[${index}].contract_path`);
    safeRelativeContractPath(contractPathValue);
    const digestValue = required(item, "contract_sha256", `graph.slices[${index}]`);
    sha256(digestValue, `graph.slices[${index}].contract_sha256`);
    if (seenSliceIds.has(sliceIdValue) || seenContractPaths.has(contractPathValue)) failNew("WG-E-DUPLICATE");
    seenSliceIds.add(sliceIdValue);
    seenContractPaths.add(contractPathValue);
    if (command === "__lease-project" && sliceIdValue !== sliceAArgument) {
      nodes.push({
        index,
        sliceId: sliceIdValue,
        contractPath: contractPathValue,
        contractDigest: digestValue,
        contract: null,
        canonicalWorktree: null,
        canonicalOutputs: [],
        dependencies: [],
      });
      return;
    }
    const captured = captureContractV4(graphPathValue, graphDirectoryReal, item, index);
    const parsed = strictObject(parseStrictJson(captured.capture.bytes, "contract"), "contract", [
      "schema_version", "slice_id", "goal_id", "purpose", "type", "depends_on",
      "immutable_inputs", "outputs", "claims", "worktree", "harness", "model",
      "effort", "acceptance", "validation_commands", "expected_evidence",
      "context_budget", "gates", "implementer", "independent_validators",
      "authorized_exceptions",
    ]);
    const contract = validateContractShapeV4(parsed, goalIdValue, sliceIdValue);
    const canonicalWorktree = normalizeWorktreeV4(contract.worktree);
    const canonicalOutputs = deriveOutputsV4(contract.outputs, canonicalWorktree);
    nodes.push({
      index,
      sliceId: sliceIdValue,
      contractPath: contractPathValue,
      contractDigest: digestValue,
      contractBytes: captured.capture.bytes,
      contract,
      canonicalWorktree,
      canonicalOutputs,
      dependencies: [...contract.depends_on],
    });
  });
  const byId = new Map(nodes.map((node) => [node.sliceId, node]));
  if (command === "__lease-project") {
    const selected = byId.get(sliceAArgument);
    if (!selected || !selected.contract) failNew("WG-E-SELECTOR");
    const dependencies = new Set();
    selected.dependencies.forEach((dependency) => {
      if (dependency === selected.sliceId || dependencies.has(dependency) || !byId.has(dependency)) failNew("WG-E-DEPENDENCY");
      dependencies.add(dependency);
    });
    if (selected.contract.type === "audit" && selected.contract.claims.some((claim) => claim.mode !== "read")) failNew("WG-E-AUDIT-WRITE");
    validateIntegrationV4(selected.contract, selected.contract.claims);
    return {graph: strictGraph, graphCapture, graphPath: graphPathValue, goalId: goalIdValue, nodes, byId};
  }
  const worktrees = new Set();
  nodes.forEach((node) => {
    if (worktrees.has(node.canonicalWorktree)) failNew("WG-E-WORKTREE");
    worktrees.add(node.canonicalWorktree);
  });
  nodes.forEach((node) => {
    const unique = new Set();
    node.dependencies.forEach((dependency) => {
      if (dependency === node.sliceId || unique.has(dependency) || !byId.has(dependency)) failNew("WG-E-DEPENDENCY");
      unique.add(dependency);
    });
    if (node.contract.type === "audit" && node.contract.claims.some((claim) => claim.mode !== "read")) failNew("WG-E-AUDIT-WRITE");
    validateIntegrationV4(node.contract, node.contract.claims);
  });
  const colors = new Map();
  const visit = (node) => {
    const color = colors.get(node.sliceId) || 0;
    if (color === 1) failNew("WG-E-CYCLE");
    if (color === 2) return;
    colors.set(node.sliceId, 1);
    node.dependencies.forEach((dependency) => visit(byId.get(dependency)));
    colors.set(node.sliceId, 2);
  };
  nodes.forEach(visit);
  return {graph: strictGraph, graphCapture, graphPath: graphPathValue, goalId: goalIdValue, nodes, byId};
}

function registryContainsId(registry, ancestor, target) {
  if (ancestor === target) return true;
  const entry = registry.instances.find((instance) => instance.id === ancestor);
  if (!entry) return false;
  return entry.contains.some((child) => registryContainsId(registry, child, target));
}

function projectionScope(projection) {
  if (projection.effectiveScope === "exact") return `exact:${projection.canonical}`;
  return projection.effectiveScope;
}

function projectClaimsV4(claims, registry) {
  const lint = lintClaims(claims, registry);
  return {
    lint,
    claims: lint.projections.map((projection) => ({
      ...projection,
      scope: projectionScope(projection),
      mode: projection.effectiveMode,
    })),
  };
}

function projectionByteCompare(left, right) {
  const a = Buffer.from(left, "utf8");
  const b = Buffer.from(right, "utf8");
  const length = Math.min(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return a.length - b.length;
}

function registryScopeResources(registry, id) {
  const byId = new Map(registry.instances.map((item) => [item.id, item]));
  const seen = new Set();
  const resources = [];
  const visit = (current) => {
    if (seen.has(current)) return;
    seen.add(current);
    const entry = byId.get(current);
    if (!entry) failNew("WG-E-SELF");
    resources.push(entry.resource);
    entry.contains.forEach(visit);
  };
  visit(id);
  return resources.sort(projectionByteCompare);
}

function projectionLockScopesV5(projection, registry) {
  if (projection.effectiveScope === "global") return ["global://all"];
  if (projection.effectiveScope.startsWith("container:")) {
    const id = projection.effectiveScope.slice("container:".length);
    return registryScopeResources(registry, id);
  }
  return [projection.canonical];
}

function leaseProjectionV5(model, node, registry) {
  const rank = {read: 1, write: 2, exclusive: 3};
  const scopeRank = (scope) => scope === "global" ? 3 : scope.startsWith("container:") ? 2 : 1;
  const broader = (left, right) => {
    if (scopeRank(left.scope) !== scopeRank(right.scope)) return scopeRank(left.scope) > scopeRank(right.scope);
    const leftBinding = registry.byResource.get(left.resource);
    const rightBinding = registry.byResource.get(right.resource);
    return !!leftBinding && !!rightBinding && leftBinding.instance.id !== rightBinding.instance.id
      && registryContainsId(registry, leftBinding.instance.id, rightBinding.instance.id);
  };
  const rows = [];
  node.projected.claims.forEach((projection) => {
    if (projection.canonical === null) failNew("WG-E-SELF");
    let scope = projection.effectiveScope;
    let lockScope;
    if (scope === "exact") {
      lockScope = projection.canonical;
      scope = "exact:" + projection.canonical;
    } else if (scope.startsWith("exact:")) {
      lockScope = projection.canonical;
    } else if (scope.startsWith("container:")) {
      const entry = registry.instances.find((item) => item.id === scope.slice("container:".length));
      if (!entry) failNew("WG-E-SELF");
      lockScope = entry.resource;
    } else if (scope === "global") {
      lockScope = "global://all";
    } else {
      failNew("WG-E-SELF");
    }
    const resource = scope.startsWith("container:") ? lockScope : projection.canonical;
    rows.push({resource, mode: projection.effectiveMode, scope, lock_scopes: projectionLockScopesV5(projection, registry)});
  });
  if (rows.length === 0) failNew("WG-E-SELF");
  let changed = true;
  while (changed) {
    changed = false;
    const collapsed = [];
    rows.forEach((item) => {
      const prior = collapsed.find((candidate) => scopesOverlap(candidate, item, registry));
      if (!prior) {
        collapsed.push({...item});
        return;
      }
      prior.mode = rank[prior.mode] >= rank[item.mode] ? prior.mode : item.mode;
      if (broader(item, prior)) {
        prior.resource = item.resource;
        prior.scope = item.scope;
      }
      if (!broader(prior, item) && !broader(item, prior)
        && projectionByteCompare(prior.resource, item.resource) > 0) prior.resource = item.resource;
      prior.lock_scopes = [...new Set(prior.lock_scopes.concat(item.lock_scopes))];
      changed = true;
    });
    rows.splice(0, rows.length, ...collapsed);
  }
  rows.forEach((row) => row.lock_scopes.sort(projectionByteCompare));
  rows.sort((left, right) => projectionByteCompare(left.resource, right.resource));
  return {
    schema_version: "workgraph-slice4-lease-projection/v1",
    goal_id: model.goalId,
    slice_id: node.sliceId,
    graph_sha256: crypto.createHash("sha256").update(model.graphCapture.bytes).digest("hex"),
    contract_sha256: node.contractDigest,
    registry_sha256: registry.digest,
    registry: {schema_version: "resource-registry/v1", instances: registry.instances},
    resources: rows.map((row) => ({resource: row.resource, mode: row.mode, lock_scopes: row.lock_scopes})),
  };
}

function exactResourceOverlap(left, right, registry) {
  if (left === right) return true;
  const leftNamespace = left.slice(0, left.indexOf("://"));
  const rightNamespace = right.slice(0, right.indexOf("://"));
  if ((leftNamespace === "path" || leftNamespace === "worktree")
    && (rightNamespace === "path" || rightNamespace === "worktree")) {
    return pathAncestorsOverlap(pathValue(left), pathValue(right));
  }
  if (leftNamespace === "branch" && rightNamespace === "branch") {
    const leftRest = left.slice("branch://".length);
    const rightRest = right.slice("branch://".length);
    const leftSlash = leftRest.indexOf("/");
    const rightSlash = rightRest.indexOf("/");
    return leftRest.slice(0, leftSlash) === rightRest.slice(0, rightSlash)
      && (leftRest.slice(leftSlash + 1) === rightRest.slice(rightSlash + 1)
        || leftRest.slice(leftSlash + 1).startsWith(`${rightRest.slice(rightSlash + 1)}/`)
        || rightRest.slice(rightSlash + 1).startsWith(`${leftRest.slice(leftSlash + 1)}/`));
  }
  if (leftNamespace === "docker" && rightNamespace === "docker") {
    const leftRest = left.slice("docker://".length);
    const rightRest = right.slice("docker://".length);
    const leftKind = leftRest.split("/")[0];
    const rightKind = rightRest.split("/")[0];
    return leftKind === rightKind && (!leftRest.includes("/") || !rightRest.includes("/"));
  }
  if (registry) {
    const leftBinding = registry.byResource.get(left);
    const rightBinding = registry.byResource.get(right);
    if (leftBinding && rightBinding) {
      return leftBinding.instance.id === rightBinding.instance.id
        || registryContainsId(registry, leftBinding.instance.id, rightBinding.instance.id)
        || registryContainsId(registry, rightBinding.instance.id, leftBinding.instance.id);
    }
  }
  return false;
}

function scopesOverlap(left, right, registry) {
  if (left.scope === "global" || right.scope === "global") return true;
  const leftContainer = left.scope.startsWith("container:") ? left.scope.slice("container:".length) : null;
  const rightContainer = right.scope.startsWith("container:") ? right.scope.slice("container:".length) : null;
  const leftExact = left.scope.startsWith("exact:") ? left.scope.slice("exact:".length) : null;
  const rightExact = right.scope.startsWith("exact:") ? right.scope.slice("exact:".length) : null;
  if (registry && (leftContainer || rightContainer)) {
    const contains = (container, exact, otherContainer) => {
      if (container && exact) {
        const binding = registry.byResource.get(exact);
        return binding ? registryContainsId(registry, container, binding.instance.id) : false;
      }
      return container && otherContainer && (registryContainsId(registry, container, otherContainer)
        || registryContainsId(registry, otherContainer, container));
    };
    if (contains(leftContainer, rightExact, rightContainer) || contains(rightContainer, leftExact, leftContainer)) return true;
  }
  if (leftExact && rightExact) return exactResourceOverlap(leftExact, rightExact, registry);
  return left.scope === right.scope;
}

function reasonScope(left, right) {
  return canonicalIdJson(`${left}|${right}`);
}

function dependencyClosure(model) {
  const closure = new Map();
  model.nodes.forEach((node) => {
    const reached = new Set();
    const visit = (id) => {
      if (reached.has(id)) return;
      reached.add(id);
      model.byId.get(id).dependencies.forEach(visit);
    };
    node.dependencies.forEach(visit);
    closure.set(node.sliceId, reached);
  });
  return closure;
}

function pairReasons(left, right, model, projected) {
  const reasons = [];
  const closure = model.closure;
  if (closure.get(left.sliceId).has(right.sliceId) || closure.get(right.sliceId).has(left.sliceId)) {
    reasons.push({code: "WG-C-DEPENDENCY", leftClaim: "none", rightClaim: "none", scopeJson: "null"});
  }
  if (pathAncestorsOverlap(pathValue(left.canonicalWorktree), pathValue(right.canonicalWorktree))) {
    reasons.push({code: "WG-C-WORKTREE", leftClaim: "none", rightClaim: "none", scopeJson: reasonScope(left.canonicalWorktree, right.canonicalWorktree)});
  }
  left.canonicalOutputs.forEach((leftOutput) => right.canonicalOutputs.forEach((rightOutput) => {
    if (pathAncestorsOverlap(pathValue(leftOutput), pathValue(rightOutput))) {
      reasons.push({code: "WG-C-OUTPUT", leftClaim: "none", rightClaim: "none", scopeJson: reasonScope(leftOutput, rightOutput)});
    }
  }));
  projected.left.claims.forEach((leftClaim) => projected.right.claims.forEach((rightClaim) => {
    if (scopesOverlap(leftClaim, rightClaim, model.registry)
      && !(leftClaim.mode === "read" && rightClaim.mode === "read")) {
      reasons.push({
        code: "WG-C-RESOURCE",
        leftClaim: leftClaim.index,
        rightClaim: rightClaim.index,
        scopeJson: reasonScope(leftClaim.canonical || leftClaim.scope, rightClaim.canonical || rightClaim.scope),
      });
    }
  }));
  const order = new Map([["WG-C-DEPENDENCY", 0], ["WG-C-WORKTREE", 1], ["WG-C-OUTPUT", 2], ["WG-C-RESOURCE", 3]]);
  const claimOrder = (value) => value === "none" ? -1 : value;
  const key = (reason) => `${order.get(reason.code)}\u0000${String(claimOrder(reason.leftClaim)).padStart(4, "0")}\u0000${String(claimOrder(reason.rightClaim)).padStart(4, "0")}\u0000${reason.scopeJson}`;
  const unique = new Map();
  reasons.forEach((reason) => unique.set(`${reason.code}\u0000${reason.leftClaim}\u0000${reason.rightClaim}\u0000${reason.scopeJson}`, reason));
  return [...unique.values()].sort((a, b) => {
    const leftKey = key(a);
    const rightKey = key(b);
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  });
}

function resolveModeV4(goalIdValue, requested) {
  if (requested !== "") {
    if (requested === "auto") return "on";
    if (["off", "eco", "on", "max"].includes(requested)) return requested;
    failNew("WG-E-MODE");
  }
  const helper = path.join(process.env.FM_WORKGRAPH_SCRIPT_DIR || path.join(process.cwd(), "bin"), "fm-parallelism.sh");
  const result = require("node:child_process").spawnSync(helper, ["get", "--goal", goalIdValue], {encoding: "utf8"});
  if (result.error || result.status !== 0 || !/^(off|eco|on|max)\n$/u.test(result.stdout)) failNew("WG-E-MODE");
  return result.stdout.slice(0, -1);
}

function buildCompatibilityV4(model, registry) {
  model.registry = registry;
  model.nodes.forEach((node) => {
    const projected = projectClaimsV4(node.contract.claims, registry);
    node.projected = projected;
  });
  model.closure = dependencyClosure(model);
  model.conflicts = new Map();
  for (let leftIndex = 0; leftIndex < model.nodes.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < model.nodes.length; rightIndex += 1) {
      const left = model.nodes[leftIndex];
      const right = model.nodes[rightIndex];
      model.conflicts.set(`${left.sliceId}\u0000${right.sliceId}`, pairReasons(left, right, model, {left: left.projected, right: right.projected}));
    }
  }
}

function conflictReasons(model, left, right) {
  const direct = model.conflicts.get(`${left.sliceId}\u0000${right.sliceId}`);
  if (direct && left.index < right.index) return direct;
  const reverse = model.conflicts.get(`${right.sliceId}\u0000${left.sliceId}`);
  if (reverse && right.index < left.index) return pairReasons(left, right, model, {left: left.projected, right: right.projected});
  return direct || reverse || [];
}

function calculateWavesV4(model, mode) {
  const capacity = mode === "off" ? 1 : mode === "eco" ? 2 : Infinity;
  const scheduled = new Set();
  const waves = [];
  while (scheduled.size < model.nodes.length) {
    const completed = new Set(scheduled);
    const selected = [];
    for (const node of model.nodes) {
      if (scheduled.has(node.sliceId) || node.dependencies.some((dependency) => !completed.has(dependency))) continue;
      if (selected.length >= capacity) continue;
      if (selected.some((other) => conflictReasons(model, node, other).length > 0)) continue;
      selected.push(node);
    }
    if (selected.length === 0) failNew("WG-E-INTERNAL");
    selected.forEach((node) => scheduled.add(node.sliceId));
    waves.push(selected);
  }
  return waves;
}

function emitWaveOutput(model, mode, waves) {
  const lines = ["valid=true", "schema_version=workgraph/v1", `goal_id=${model.goalId}`, `mode=${mode}`,
    `slice_count=${model.nodes.length}`, `wave_count=${waves.length}`];
  waves.forEach((wave, waveIndex) => {
    lines.push(`wave[${waveIndex}].slice_count=${wave.length}`);
    wave.forEach((node, sliceIndex) => lines.push(`wave[${waveIndex}].slice[${sliceIndex}]=${node.sliceId}`));
  });
  lines.push("compatibility_source=workgraph-claims", "gates=enforcement-pending", "enforcement=disabled");
  process.stdout.write(`${lines.join("\n")}\n`);
}

function emitReadyOutput(model, mode) {
  const capacity = mode === "off" ? 1 : mode === "eco" ? 2 : Infinity;
  const selected = [];
  let dependencyBlocked = 0;
  let compatibilityBlocked = 0;
  let capacityBlocked = 0;
  for (const node of model.nodes) {
    if (node.dependencies.some((dependency) => !model.readyCompleted.has(dependency))) {
      dependencyBlocked += 1;
    } else if (selected.length >= capacity) {
      capacityBlocked += 1;
    } else if (selected.some((other) => conflictReasons(model, node, other).length > 0)) {
      compatibilityBlocked += 1;
    } else {
      selected.push(node);
    }
  }
  const lines = ["valid=true", "schema_version=workgraph/v1", `goal_id=${model.goalId}`, `mode=${mode}`,
    `slice_count=${model.nodes.length}`, `ready_count=${selected.length}`];
  selected.forEach((node, index) => lines.push(`ready[${index}]=${node.sliceId}`));
  lines.push(`dependency_blocked_count=${dependencyBlocked}`, `compatibility_blocked_count=${compatibilityBlocked}`,
    `capacity_blocked_count=${capacityBlocked}`, "compatibility_source=workgraph-claims", "gates=enforcement-pending", "enforcement=disabled");
  process.stdout.write(`${lines.join("\n")}\n`);
}

function emitConflictOutput(model, leftId, rightId) {
  if (leftId === rightId || !model.byId.has(leftId) || !model.byId.has(rightId)) failNew("WG-E-SELECTOR");
  const left = model.byId.get(leftId);
  const right = model.byId.get(rightId);
  const reasons = conflictReasons(model, left, right);
  const lines = [`slice_a=${leftId}`, `slice_b=${rightId}`, `compatible=${reasons.length === 0 ? "true" : "false"}`, `reason_count=${reasons.length}`];
  reasons.forEach((reason, index) => {
    lines.push(`reason[${index}].code=${reason.code}`);
    lines.push(`reason[${index}].left_claim=${reason.leftClaim}`);
    lines.push(`reason[${index}].right_claim=${reason.rightClaim}`);
    lines.push(`reason[${index}].scope_json=${reason.scopeJson}`);
  });
  lines.push("enforcement=disabled");
  process.stdout.write(`${lines.join("\n")}\n`);
}

function selectedDispatchNode(graphFilename, sliceIdValue, registryFilename) {
  const resolvedGraph = path.resolve(graphFilename);
  const capture = captureRegularFile(resolvedGraph, "graph");
  const parsed = strictObject(
    parseStrictJson(capture.bytes, "graph"),
    "graph",
    ["schema_version", "goal_id", "slices"],
  );
  const model = validateSlice4Graph(parsed, resolvedGraph, capture);
  const registry = loadRegistry(registryFilename);
  buildCompatibilityV4(model, registry);
  const node = model.byId.get(sliceIdValue);
  if (!node) failNew("WG-E-SELECTOR");
  return {model, node, registry};
}

function projectedScopesOverlap(left, leftRegistry, right, rightRegistry) {
  const leftScopes = projectionLockScopesV5(left, leftRegistry);
  const rightScopes = projectionLockScopesV5(right, rightRegistry);
  return leftScopes.some((leftScope) => rightScopes.some((rightScope) => {
    if (leftScope === "global://all" || rightScope === "global://all") return true;
    return exactResourceOverlap(leftScope, rightScope, undefined);
  }));
}

function crossGraphConflictReasons(leftSelected, rightSelected) {
  const left = leftSelected.node;
  const right = rightSelected.node;
  const reasons = [];
  if (pathAncestorsOverlap(pathValue(left.canonicalWorktree), pathValue(right.canonicalWorktree))) {
    reasons.push({
      code: "WG-C-WORKTREE",
      leftClaim: "none",
      rightClaim: "none",
      scopeJson: reasonScope(left.canonicalWorktree, right.canonicalWorktree),
    });
  }
  left.canonicalOutputs.forEach((leftOutput) => right.canonicalOutputs.forEach((rightOutput) => {
    if (pathAncestorsOverlap(pathValue(leftOutput), pathValue(rightOutput))) {
      reasons.push({
        code: "WG-C-OUTPUT",
        leftClaim: "none",
        rightClaim: "none",
        scopeJson: reasonScope(leftOutput, rightOutput),
      });
    }
  }));
  left.projected.claims.forEach((leftClaim) => right.projected.claims.forEach((rightClaim) => {
    if (!(leftClaim.mode === "read" && rightClaim.mode === "read")
      && projectedScopesOverlap(
        leftClaim,
        leftSelected.registry,
        rightClaim,
        rightSelected.registry,
      )) {
      reasons.push({
        code: "WG-C-RESOURCE",
        leftClaim: leftClaim.index,
        rightClaim: rightClaim.index,
        scopeJson: reasonScope(
          leftClaim.canonical || leftClaim.scope,
          rightClaim.canonical || rightClaim.scope,
        ),
      });
    }
  }));
  const order = new Map([["WG-C-WORKTREE", 0], ["WG-C-OUTPUT", 1], ["WG-C-RESOURCE", 2]]);
  const key = (reason) => `${order.get(reason.code)}\u0000${reason.leftClaim}\u0000${reason.rightClaim}\u0000${reason.scopeJson}`;
  const unique = new Map();
  reasons.forEach((reason) => unique.set(key(reason), reason));
  return [...unique.values()].sort((leftReason, rightReason) => {
    const leftKey = key(leftReason);
    const rightKey = key(rightReason);
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  });
}

function emitDispatchConflict() {
  const left = selectedDispatchNode(graphArgument, sliceAArgument, registryArgument);
  const right = selectedDispatchNode(otherGraphArgument, otherSliceArgument, otherRegistryArgument);
  const reasons = crossGraphConflictReasons(left, right);
  const lines = [
    `goal_a=${left.model.goalId}`,
    `slice_a=${left.node.sliceId}`,
    `contract_sha256_a=${left.node.contractDigest}`,
    `goal_b=${right.model.goalId}`,
    `slice_b=${right.node.sliceId}`,
    `contract_sha256_b=${right.node.contractDigest}`,
    `compatible=${reasons.length === 0 ? "true" : "false"}`,
    `reason_count=${reasons.length}`,
  ];
  reasons.forEach((reason, index) => {
    lines.push(`reason[${index}].code=${reason.code}`);
    lines.push(`reason[${index}].left_claim=${reason.leftClaim}`);
    lines.push(`reason[${index}].right_claim=${reason.rightClaim}`);
    lines.push(`reason[${index}].scope_json=${reason.scopeJson}`);
  });
  process.stdout.write(`${lines.join("\n")}\n`);
}

function emitMultiLintV4(model) {
  const claims = [];
  model.nodes.forEach((node) => node.contract.claims.forEach((claim) => claims.push(claim)));
  emitLint(lintClaims(claims, model.registry));
}

function emitMultiStatusV4(model, mode, waves) {
  const lines = ["valid=true", "schema_version=workgraph/v1", `goal_id=${model.goalId}`, `slice_count=${model.nodes.length}`];
  model.nodes.forEach((node, index) => {
    lines.push(`slice[${index}].slice_id=${node.sliceId}`);
    lines.push(`slice[${index}].contract_path_json=${canonicalIdJson(node.contractPath)}`);
    lines.push(`slice[${index}].contract_sha256=${node.contractDigest}`);
    lines.push(`slice[${index}].contract_verified=true`);
  });
  const claims = [];
  model.nodes.forEach((node) => node.contract.claims.forEach((claim) => claims.push(claim)));
  const lint = lintClaims(claims, model.registry);
  const lintLines = [];
  const originalLog = console.log;
  console.log = (line) => lintLines.push(line);
  emitLint(lint);
  console.log = originalLog;
  lines.push(...lintLines);
  lines.push(`mode=${mode}`, `wave_count=${waves.length}`);
  waves.forEach((wave, waveIndex) => {
    lines.push(`wave[${waveIndex}].slice_count=${wave.length}`);
    wave.forEach((node, sliceIndex) => lines.push(`wave[${waveIndex}].slice[${sliceIndex}]=${node.sliceId}`));
  });
  lines.push("compatibility_source=workgraph-claims", "gates=enforcement-pending", "enforcement=disabled");
  appendLeaseStatus(lines, model.goalId);
  appendGateStatus(lines, model.graphPath);
  process.stdout.write(`${lines.join("\n")}\n`);
}

function appendLeaseStatus(lines, goalIdValue) {
  const helper = path.join(process.env.FM_WORKGRAPH_SCRIPT_DIR || path.join(process.cwd(), "bin"), "fm-workgraph-lease-lib.sh");
  const result = require("node:child_process").spawnSync(helper, ["status", goalIdValue], {encoding: "utf8"});
  if (result.error || result.status !== 0) {
    if (result.stderr) process.stderr.write(result.stderr);
    process.exit(result.status || 1);
  }
  const suffix = result.stdout.replace(/\n$/u, "");
  if (suffix) lines.push(...suffix.split("\n"));
}

function appendGateStatus(lines, graphPathValue) {
  const scriptRoot = path.dirname(process.env.FM_WORKGRAPH_SCRIPT_DIR || path.join(process.cwd(), "bin"));
  const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || scriptRoot;
  const data = process.env.FM_DATA_OVERRIDE || path.join(home, "data");
  const goalValue = lines.find((line) => line.startsWith("goal_id="));
  if (!goalValue) return;
  const gateRoot = path.join(data, "workgraphs", goalValue.slice("goal_id=".length), "gates");
  if (!fs.existsSync(gateRoot)) return;
  const helper = path.join(process.env.FM_WORKGRAPH_SCRIPT_DIR || path.join(process.cwd(), "bin"), "fm-workgraph-gate-lib.sh");
  const result = require("node:child_process").spawnSync(helper, ["gate-status", graphPathValue], {encoding: "utf8"});
  if (result.error || result.status !== 0) {
    if (result.stderr) process.stderr.write(result.stderr);
    process.exit(result.status || 1);
  }
  const suffix = result.stdout.replace(/\n$/u, "");
  if (suffix) lines.push(...suffix.split("\n"));
}

function executeSlice4(graph, graphPathValue, graphCaptureValue) {
  const model = validateSlice4Graph(graph, graphPathValue, graphCaptureValue);
  if (command === "validate") process.exit(0);
  if (command === "contract") {
    const node = model.byId.get(sliceAArgument);
    if (!node) failNew("WG-E-SELECTOR");
    process.stdout.write(node.contractBytes);
    process.exit(0);
  }
  const registry = loadRegistry(registryArgument);
  if (command === "__lease-project") {
    const node = model.byId.get(sliceAArgument);
    if (!node) failNew("WG-E-SELECTOR");
    const selectedModel = {
      ...model,
      nodes: [node],
      byId: model.byId,
    };
    buildCompatibilityV4(selectedModel, registry);
    process.stdout.write(JSON.stringify(leaseProjectionV5(selectedModel, node, registry)) + "\n");
    process.exit(0);
  }
  buildCompatibilityV4(model, registry);
  if (command === "lint") {
    emitMultiLintV4(model);
    process.exit(0);
  }
  const mode = ["waves", "ready", "status"].includes(command) ? resolveModeV4(model.goalId, modeArgument) : "on";
  if (command === "explain-conflict") {
    emitConflictOutput(model, sliceAArgument, sliceBArgument);
    process.exit(0);
  }
  const waves = calculateWavesV4(model, mode);
  if (command === "waves") emitWaveOutput(model, mode, waves);
  else if (command === "ready") {
    model.readyCompleted = new Set();
    emitReadyOutput(model, mode);
  } else if (command === "status") {
    emitMultiStatusV4(model, mode, waves);
  }
  else fail("WG-E-COMMAND", `unsupported Slice 4 command '${command}'`);
  process.exit(0);
}

if (command === "normalize") {
  try {
    console.log(normalizeResource(graphArgument));
  } catch (error) {
    fail(error.resourceCode || "WG-R-MALFORMED", error.message);
  }
  process.exit(0);
}

if (command === "registry") {
  const capture = captureRegularFile(graphPath, "registry");
  const registry = parseStrictJson(capture.bytes, "registry");
  const validatedRegistry = validateRegistry(registry);
  console.log("valid=true");
  console.log("schema_version=resource-registry/v1");
  console.log(`instance_count=${validatedRegistry.instances.length}`);
  process.exit(0);
}

if (command === "lint") {
  const capture = captureRegularFile(graphPath, "claims");
  const input = parseStrictJson(capture.bytes, "claims");
  let claims;
  if (input && !Array.isArray(input) && input.slices !== undefined) {
    if (Array.isArray(input.slices) && input.slices.length !== 1) {
      executeSlice4(input, graphPath, capture);
    }
    claims = validateGraphForLint(input);
  } else {
    claims = strictClaimsInput(input, "claims");
  }
  emitLint(lintClaims(claims, loadRegistry(registryArgument)));
  process.exit(0);
}

if (command === "__lease-overlap") {
  let input;
  try {
    const inputFd = privateInputDescriptor();
    input = parseStrictJson(fs.readFileSync(inputFd), "captured overlap");
  } catch {
    fail("WG-E-CORRUPT", "captured overlap is invalid");
  }
  const overlapInput = strictObject(input, "captured overlap", ["registry", "left_scopes", "right_scopes"]);
  const overlapRegistry = validateRegistry(overlapInput.registry);
  const leftScopes = array(overlapInput.left_scopes, "captured overlap.left_scopes", false);
  const rightScopes = array(overlapInput.right_scopes, "captured overlap.right_scopes", false);
  const left = leftScopes.map((scope) => ({scope: scope === "global://all" ? "global" : "exact:" + scope}));
  const right = rightScopes.map((scope) => ({scope: scope === "global://all" ? "global" : "exact:" + scope}));
  const overlaps = left.some((leftScope) => right.some((rightScope) => scopesOverlap(leftScope, rightScope, overlapRegistry)));
  process.stdout.write(overlaps ? "true\n" : "false\n");
  process.exit(0);
}

if (command === "__lease-normalize") {
  let input;
  try {
    const inputFd = privateInputDescriptor();
    input = parseStrictJson(fs.readFileSync(inputFd), "captured resource");
  } catch {
    fail("WG-E-CORRUPT", "captured resource is invalid");
  }
  const resourceInput = strictObject(input, "captured resource", ["value"]);
  try {
    process.stdout.write(normalizeResource(resourceInput.value) + "\n");
  } catch (error) {
    fail(error.resourceCode || "WG-R-MALFORMED", error.message);
  }
  process.exit(0);
}

if (command === "__dispatch-conflict") {
  emitDispatchConflict();
  process.exit(0);
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
const rawSlices = required(graph, "slices", "graph");
const slices = Array.isArray(rawSlices) ? rawSlices : array(rawSlices, "graph.slices", false);
if (["waves", "ready", "explain-conflict", "contract", "__lease-project"].includes(command)
  || ((command === "validate" || command === "status") && slices.length !== 1)) {
  executeSlice4(graph, graphPath, graphCapture);
}
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
  || /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u.test(contractPath)
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

const contractClaims = required(contract, "claims", "contract");
if (!Array.isArray(contractClaims) || contractClaims.length === 0) fail("WG-E-SCHEMA", "contract.claims must be a non-empty array");
contractClaims.forEach((claim, index) => {
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
const maxContextInteger = 9007199254740991n;
for (const field of ["source_tokens", "report_words"]) {
  const value = required(contextBudget, field, "contract.context_budget");
  if (!(value instanceof JsonNumber) || !value.isIntegerInRange(1n, maxContextInteger)) {
    fail("WG-E-CORRUPT", `contract.context_budget.${field} must be a positive integer`);
  }
}
stringArray(required(contract, "gates", "contract"), "contract.gates", false);
stringArray(required(contract, "independent_validators", "contract"), "contract.independent_validators", false);
stringArray(required(contract, "authorized_exceptions", "contract"), "contract.authorized_exceptions");
const resourceLintResult = lintClaims(contract.claims, loadRegistry(registryArgument), "contract.claims");

if (command === "status") {
  const lines = ["valid=true", `schema_version=${graph.schema_version}`, `goal_id=${goalId}`, "slice_count=1",
    `slice_id=${sliceId}`, `contract_path=${contractPath}`, `contract_sha256=${contractDigest}`, "contract_verified=true"];
  const lintLines = [];
  const originalLog = console.log;
  console.log = (line) => lintLines.push(line);
  emitLint(resourceLintResult);
  console.log = originalLog;
  lines.push(...lintLines, "enforcement=disabled");
  const leaseLines = [];
  appendLeaseStatus(leaseLines, goalId);
  lines.push(...leaseLines);
  appendGateStatus(lines, graphPath);
  process.stdout.write(`${lines.join("\n")}\n`);
}
// WORKGRAPH_NODE_SOURCE_END
NODE

#!/usr/bin/env bash
# Durable WorkGraph gates, content-addressed evidence, and Git snapshots.
# Invoked by fm-workgraph.sh; use that public entrypoint.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_ROOT FM_HOME DATA STATE SCRIPT_DIR

exec node - "$@" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const child = require("node:child_process");

const argv = process.argv.slice(2);
const command = argv.shift() || "";
const root = process.env.FM_ROOT;
const dataRoot = path.resolve(process.env.DATA);
const stateRoot = path.resolve(process.env.STATE);
const workgraphTool = path.join(process.env.SCRIPT_DIR, "fm-workgraph.sh");
const maxCapture = 256 * 1024 * 1024;

function fail(code, message, status = 1) {
  process.stderr.write(`fm-workgraph: ${code}: ${message}\n`);
  process.exit(status);
}

function safeId(value, name) {
  if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(value)) {
    fail("WG-G-E-ID", `${name} is not a safe identifier`);
  }
  return value;
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function captureRegular(filename, name) {
  let descriptor;
  try {
    const before = fs.lstatSync(filename, {bigint: true});
    if (!before.isFile() || before.isSymbolicLink() || before.nlink !== 1n) {
      fail("WG-G-E-INPUT", `${name} must be a single-link regular file`);
    }
    if (before.size > BigInt(maxCapture)) fail("WG-G-E-LIMIT", `${name} exceeds the evidence size limit`);
    descriptor = fs.openSync(filename, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const opened = fs.fstatSync(descriptor, {bigint: true});
    if (!opened.isFile() || opened.dev !== before.dev || opened.ino !== before.ino
        || opened.nlink !== 1n || opened.size !== before.size) {
      fail("WG-G-E-INPUT", `${name} identity changed during capture`);
    }
    const bytes = fs.readFileSync(descriptor);
    const after = fs.fstatSync(descriptor, {bigint: true});
    const pathAfter = fs.lstatSync(filename, {bigint: true});
    if (after.dev !== opened.dev || after.ino !== opened.ino || after.size !== opened.size
        || pathAfter.dev !== opened.dev || pathAfter.ino !== opened.ino) {
      fail("WG-G-E-INPUT", `${name} changed during capture`);
    }
    return {bytes, stat: opened};
  } catch (error) {
    if (error && /^WG-G-E-/.test(error.message || "")) throw error;
    fail("WG-G-E-INPUT", `cannot capture ${name}`);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function runTool(args, name) {
  const result = child.spawnSync(workgraphTool, args, {
    encoding: null,
    env: process.env,
    maxBuffer: maxCapture,
  });
  if (result.error || result.status !== 0) {
    if (result.stderr) process.stderr.write(result.stderr);
    fail("WG-G-E-BINDING", `${name} validation failed`);
  }
  return result.stdout;
}

function strictObject(value, allowed, name) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    fail("WG-G-E-CORRUPT", `${name} is not an object`);
  }
  const keys = Object.keys(value);
  if (keys.some((key) => !allowed.includes(key))) {
    fail("WG-G-E-CORRUPT", `${name} has an unknown field`);
  }
  return value;
}

function loadGraph(graphFile) {
  runTool(["validate", graphFile], "graph");
  const first = captureRegular(graphFile, "graph");
  let graph;
  try { graph = JSON.parse(first.bytes); } catch { fail("WG-G-E-CORRUPT", "graph JSON is invalid"); }
  const secondDigest = sha256(runTool(["contract", graphFile, graph.slices[0].slice_id], "graph stability"));
  const after = captureRegular(graphFile, "graph");
  if (sha256(first.bytes) !== sha256(after.bytes) || secondDigest.length !== 64) {
    fail("WG-G-E-RACE", "graph changed during validation");
  }
  return {graph, bytes: first.bytes, digest: sha256(first.bytes), filename: path.resolve(graphFile)};
}

function contractBytes(graphFile, sliceId) {
  return runTool(["contract", graphFile, sliceId], `contract ${sliceId}`);
}

function loadContract(graphModel, sliceId) {
  safeId(sliceId, "slice_id");
  const reference = graphModel.graph.slices.find((item) => item.slice_id === sliceId);
  if (!reference) fail("WG-G-E-SELECTOR", `unknown slice ${sliceId}`);
  const bytes = contractBytes(graphModel.filename, sliceId);
  if (sha256(bytes) !== reference.contract_sha256) fail("WG-G-E-HASH", "selected contract digest changed");
  let contract;
  try { contract = JSON.parse(bytes); } catch { fail("WG-G-E-CORRUPT", "contract JSON is invalid"); }
  return {contract, bytes, digest: sha256(bytes)};
}

function ensureDirectory(directory) {
  const relative = path.relative(dataRoot, directory);
  if (relative.startsWith("..") || path.isAbsolute(relative)) fail("WG-G-E-PATH", "durable path escapes data root");
  if (!fs.existsSync(dataRoot)) fs.mkdirSync(dataRoot, {recursive: true, mode: 0o700});
  const base = fs.lstatSync(dataRoot);
  if (!base.isDirectory() || base.isSymbolicLink()) fail("WG-G-E-PATH", "data root is not a real directory");
  let current = dataRoot;
  for (const segment of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) fs.mkdirSync(current, {mode: 0o700});
    const stat = fs.lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail("WG-G-E-PATH", "durable path contains a non-directory");
  }
  return directory;
}

function fsyncDirectory(directory) {
  const fd = fs.openSync(directory, fs.constants.O_RDONLY | (fs.constants.O_DIRECTORY || 0));
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function publishImmutable(filename, bytes) {
  ensureDirectory(path.dirname(filename));
  if (fs.existsSync(filename)) {
    const existing = captureRegular(filename, "existing durable artifact").bytes;
    if (!existing.equals(bytes)) fail("WG-G-E-CONFLICT", `immutable artifact differs at ${filename}`);
    return;
  }
  const temporary = path.join(path.dirname(filename), `.${path.basename(filename)}.${process.pid}.${crypto.randomBytes(8).toString("hex")}`);
  let fd;
  try {
    fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | (fs.constants.O_NOFOLLOW || 0), 0o600);
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    try {
      fs.linkSync(temporary, filename);
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      const existing = captureRegular(filename, "concurrent durable artifact").bytes;
      if (!existing.equals(bytes)) fail("WG-G-E-CONFLICT", `concurrent artifact differs at ${filename}`);
    }
    fs.unlinkSync(temporary);
    fsyncDirectory(path.dirname(filename));
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    try { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); } catch {}
  }
}

function canonicalBytes(value) {
  return Buffer.from(JSON.stringify(value) + "\n");
}

function processIdentity(pid) {
  let bootId;
  let stat;
  try {
    bootId = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
    stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
  } catch {
    return null;
  }
  const close = stat.lastIndexOf(")");
  if (close < 0) return null;
  const fields = stat.slice(close + 2).split(" ");
  const startTicks = fields[19];
  if (!/^[1-9][0-9]*$/.test(startTicks)) return null;
  return {pid, boot_id: bootId, start_ticks: startTicks};
}

function acquireMutationLock(key) {
  if (!fs.existsSync(stateRoot)) fs.mkdirSync(stateRoot, {recursive: true, mode: 0o700});
  const stateStat = fs.lstatSync(stateRoot);
  if (!stateStat.isDirectory() || stateStat.isSymbolicLink()) fail("WG-G-E-LOCK", "state root is unsafe");
  const lock = path.join(stateRoot, `.workgraph-gate-${sha256(Buffer.from(key))}.lock`);
  const owner = processIdentity(process.pid);
  if (!owner) fail("WG-G-E-LOCK", "cannot establish process identity");
  const ownerBytes = canonicalBytes(owner);
  const writeOwner = () => {
    const ownerPath = path.join(lock, "owner.json");
    const fd = fs.openSync(ownerPath, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | (fs.constants.O_NOFOLLOW || 0), 0o600);
    try {
      fs.writeFileSync(fd, ownerBytes);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fsyncDirectory(lock);
  };
  const create = () => {
    fs.mkdirSync(lock, {mode: 0o700});
    writeOwner();
  };
  try {
    create();
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    const stat = fs.lstatSync(lock);
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail("WG-G-E-LOCK", "mutation lock is unsafe");
    let existing;
    try { existing = JSON.parse(captureRegular(path.join(lock, "owner.json"), "lock owner").bytes); }
    catch { fail("WG-G-E-LOCK", "mutation lock owner is ambiguous"); }
    const live = processIdentity(existing.pid);
    if (live && live.boot_id === existing.boot_id && live.start_ticks === existing.start_ticks) {
      fail("WG-G-E-BUSY", "gate mutation is already active");
    }
    const stale = `${lock}.stale.${process.pid}.${crypto.randomBytes(6).toString("hex")}`;
    try { fs.renameSync(lock, stale); } catch { fail("WG-G-E-BUSY", "gate mutation lock changed during recovery"); }
    create();
  }
  return () => {
    try {
      const current = captureRegular(path.join(lock, "owner.json"), "lock owner").bytes;
      if (!current.equals(ownerBytes)) return;
      fs.unlinkSync(path.join(lock, "owner.json"));
      fs.rmdirSync(lock);
    } catch {}
  };
}

function goalRoot(goalId, create = false) {
  const directory = path.join(dataRoot, "workgraphs", safeId(goalId, "goal_id"));
  if (create) ensureDirectory(directory);
  return directory;
}

function evidencePaths(goalId, digest, create = false) {
  const directory = path.join(goalRoot(goalId, create), "evidence", digest);
  if (create) ensureDirectory(directory);
  return {directory, content: path.join(directory, "content.bin")};
}

function recordEvidence(goalId, sliceId, kind, actorId, sourceFile) {
  safeId(sliceId, "slice_id");
  safeId(actorId, "actor_id");
  if (!["gate", "validation", "output", "audit", "snapshot"].includes(kind)) {
    fail("WG-G-E-ARG", "unknown evidence kind");
  }
  const captured = captureRegular(sourceFile, "evidence");
  const digest = sha256(captured.bytes);
  const paths = evidencePaths(goalId, digest, true);
  publishImmutable(paths.content, captured.bytes);
  const record = {
    schema_version: "workgraph-evidence-result/v1",
    goal_id: goalId,
    slice_id: sliceId,
    kind,
    actor_id: actorId,
    content_sha256: digest,
    content_bytes: captured.bytes.length,
    source_name: path.basename(sourceFile),
  };
  const recordName = `${sliceId}-${kind}-${actorId}.json`;
  publishImmutable(path.join(paths.directory, "records", recordName), canonicalBytes(record));
  return record;
}

function gateDirectory(goalId, sliceId, gateId, create = false) {
  const digest = sha256(Buffer.from(gateId));
  const directory = path.join(goalRoot(goalId, create), "gates", sliceId, digest);
  if (create) ensureDirectory(directory);
  return directory;
}

const gateFields = [
  "schema_version", "goal_id", "slice_id", "gate_id", "sequence",
  "status", "actor_id", "contract_sha256", "evidence_sha256",
];

function gateHistory(goalId, sliceId, gateId, create = false) {
  const directory = gateDirectory(goalId, sliceId, gateId, create);
  if (!fs.existsSync(directory)) return {directory, results: []};
  const directoryStat = fs.lstatSync(directory);
  if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) {
    fail("WG-G-E-CORRUPT", "gate history path is unsafe");
  }
  const names = fs.readdirSync(directory).sort();
  const results = [];
  for (const name of names) {
    if (!/^[0-9]{6}-[0-9a-f]{64}\.json$/.test(name)) fail("WG-G-E-CORRUPT", "gate history contains an unknown artifact");
    const bytes = captureRegular(path.join(directory, name), "gate record").bytes;
    if (name.slice(7, 71) !== sha256(bytes)) fail("WG-G-E-CORRUPT", "gate record filename digest mismatch");
    let record;
    try { record = JSON.parse(bytes); } catch { fail("WG-G-E-CORRUPT", "gate record JSON is invalid"); }
    strictObject(record, gateFields, "gate record");
    const expectedSequence = results.length + 1;
    if (record.schema_version !== "workgraph-gate-result/v1"
        || record.goal_id !== goalId || record.slice_id !== sliceId || record.gate_id !== gateId
        || record.sequence !== expectedSequence
        || !["passed", "failed"].includes(record.status)
        || !/^[0-9a-f]{64}$/.test(record.contract_sha256)
        || !/^[0-9a-f]{64}$/.test(record.evidence_sha256)) {
      fail("WG-G-E-CORRUPT", "gate record fields are invalid or out of sequence");
    }
    const evidence = evidencePaths(goalId, record.evidence_sha256).content;
    const evidenceBytes = captureRegular(evidence, "gate evidence").bytes;
    if (sha256(evidenceBytes) !== record.evidence_sha256) fail("WG-G-E-CORRUPT", "gate evidence digest mismatch");
    results.push({record, bytes});
  }
  return {directory, results};
}

function gateState(goalId, sliceId, gateId, contractDigest) {
  const history = gateHistory(goalId, sliceId, gateId).results;
  if (history.length === 0) return {state: "pending", sequence: 0};
  const latest = history[history.length - 1].record;
  if (latest.contract_sha256 !== contractDigest) return {state: "stale", sequence: latest.sequence};
  return {state: latest.status, sequence: latest.sequence, evidence_sha256: latest.evidence_sha256};
}

function allGates(graphModel, sliceId) {
  const selected = loadContract(graphModel, sliceId);
  return {
    selected,
    rows: selected.contract.gates.map((gateId) => ({
      gateId,
      ...gateState(selected.contract.goal_id, sliceId, gateId, selected.digest),
    })),
  };
}

function recordGate(graphFile, sliceId, gateId, status, actorId, evidenceFile) {
  const graphModel = loadGraph(graphFile);
  const selected = loadContract(graphModel, sliceId);
  const contract = selected.contract;
  if (!contract.gates.includes(gateId)) fail("WG-G-E-GATE", "gate is not declared by the selected contract");
  if (!contract.independent_validators.includes(actorId)) {
    fail("WG-G-E-ACTOR", "gate actor is not an independent validator declared by the contract");
  }
  if (!["passed", "failed"].includes(status)) fail("WG-G-E-ARG", "gate status must be passed or failed");
  const release = acquireMutationLock(`${contract.goal_id}\0${sliceId}\0${gateId}`);
  try {
    const evidence = recordEvidence(contract.goal_id, sliceId, "gate", actorId, evidenceFile);
    const history = gateHistory(contract.goal_id, sliceId, gateId, true);
    const latest = history.results[history.results.length - 1];
    if (latest && latest.record.status === status && latest.record.actor_id === actorId
        && latest.record.contract_sha256 === selected.digest
        && latest.record.evidence_sha256 === evidence.content_sha256) {
      process.stdout.write(latest.bytes);
      return;
    }
    const sequence = history.results.length + 1;
    if (sequence > 999999) fail("WG-G-E-LIMIT", "gate history is exhausted");
    const record = {
      schema_version: "workgraph-gate-result/v1",
      goal_id: contract.goal_id,
      slice_id: sliceId,
      gate_id: gateId,
      sequence,
      status,
      actor_id: actorId,
      contract_sha256: selected.digest,
      evidence_sha256: evidence.content_sha256,
    };
    const bytes = canonicalBytes(record);
    const filename = `${String(sequence).padStart(6, "0")}-${sha256(bytes)}.json`;
    publishImmutable(path.join(history.directory, filename), bytes);
    process.stdout.write(bytes);
  } finally {
    release();
  }
}

function transitiveDependencies(graphModel, sliceId) {
  const seen = new Set();
  const visit = (id) => {
    const selected = loadContract(graphModel, id);
    for (const dependency of selected.contract.depends_on) {
      if (!seen.has(dependency)) {
        seen.add(dependency);
        visit(dependency);
      }
    }
  };
  visit(sliceId);
  return [...seen];
}

function gateCheck(graphFile, sliceId) {
  const graphModel = loadGraph(graphFile);
  const own = allGates(graphModel, sliceId);
  if (own.rows.length > 0 && own.rows.every((row) => row.state === "passed")) {
    fail("WG-G-E-COMPLETE", "selected slice already has all gates passed");
  }
  for (const dependency of transitiveDependencies(graphModel, sliceId)) {
    const gates = allGates(graphModel, dependency);
    const blocked = gates.rows.filter((row) => row.state !== "passed");
    if (blocked.length > 0) {
      fail("WG-G-E-PENDING", `dependency ${dependency} has ${blocked.length} gate(s) not passed`);
    }
  }
  process.stdout.write(`dispatchable=true\ngoal_id=${own.selected.contract.goal_id}\nslice_id=${sliceId}\n`);
}

function completionCheck(graphFile, sliceId) {
  const graphModel = loadGraph(graphFile);
  const gates = allGates(graphModel, sliceId);
  const blocked = gates.rows.filter((row) => row.state !== "passed");
  if (blocked.length > 0) fail("WG-G-E-PENDING", `slice ${sliceId} has ${blocked.length} gate(s) not passed`);
  process.stdout.write(`complete=true\ngoal_id=${gates.selected.contract.goal_id}\nslice_id=${sliceId}\ngate_count=${gates.rows.length}\n`);
}

function gateStatus(graphFile, selector) {
  const graphModel = loadGraph(graphFile);
  const ids = selector ? [selector] : graphModel.graph.slices.map((item) => item.slice_id);
  const lines = [`gate_schema=workgraph-gate-result/v1`, `gate_slice_count=${ids.length}`];
  ids.forEach((id, sliceIndex) => {
    const gates = allGates(graphModel, id);
    lines.push(`gate_slice[${sliceIndex}].slice_id=${id}`);
    lines.push(`gate_slice[${sliceIndex}].gate_count=${gates.rows.length}`);
    gates.rows.forEach((row, gateIndex) => {
      lines.push(`gate_slice[${sliceIndex}].gate[${gateIndex}].id_json=${JSON.stringify(row.gateId)}`);
      lines.push(`gate_slice[${sliceIndex}].gate[${gateIndex}].state=${row.state}`);
      lines.push(`gate_slice[${sliceIndex}].gate[${gateIndex}].sequence=${row.sequence}`);
      if (row.evidence_sha256) lines.push(`gate_slice[${sliceIndex}].gate[${gateIndex}].evidence_sha256=${row.evidence_sha256}`);
    });
    lines.push(`gate_slice[${sliceIndex}].complete=${gates.rows.every((row) => row.state === "passed")}`);
  });
  process.stdout.write(lines.join("\n") + "\n");
}

function snapshot(graphFile, sliceId, actorId) {
  safeId(actorId, "actor_id");
  const graphModel = loadGraph(graphFile);
  const selected = loadContract(graphModel, sliceId);
  const worktree = selected.contract.worktree;
  const status = child.spawnSync("git", ["-C", worktree, "status", "--porcelain=v1", "--untracked-files=all"], {encoding: "utf8"});
  if (status.error || status.status !== 0 || status.stdout !== "") fail("WG-G-E-DIRTY", "snapshot worktree is not clean");
  const git = (args) => {
    const result = child.spawnSync("git", ["-C", worktree, ...args], {encoding: "utf8"});
    if (result.error || result.status !== 0) fail("WG-G-E-GIT", `git ${args[0]} failed`);
    return result.stdout.trim();
  };
  const commit = git(["rev-parse", "HEAD^{commit}"]);
  const tree = git(["rev-parse", "HEAD^{tree}"]);
  const archiveResult = child.spawnSync("git", ["-C", worktree, "archive", "--format=tar", "HEAD"], {
    encoding: null,
    maxBuffer: maxCapture,
  });
  if (archiveResult.error || archiveResult.status !== 0 || archiveResult.stdout.length === 0) {
    fail("WG-G-E-GIT", "git archive failed");
  }
  const archive = archiveResult.stdout;
  const digest = sha256(archive);
  const directory = ensureDirectory(path.join(goalRoot(selected.contract.goal_id, true), "snapshots", sliceId, digest));
  publishImmutable(path.join(directory, "candidate.tar"), archive);
  const manifest = {
    schema_version: "workgraph-snapshot-manifest/v1",
    goal_id: selected.contract.goal_id,
    slice_id: sliceId,
    actor_id: actorId,
    commit,
    tree,
    archive_sha256: digest,
    archive_bytes: archive.length,
    contract_sha256: selected.digest,
  };
  const manifestBytes = canonicalBytes(manifest);
  publishImmutable(path.join(directory, "manifest.json"), manifestBytes);
  const evidenceTemp = path.join(directory, ".snapshot-evidence");
  publishImmutable(evidenceTemp, archive);
  recordEvidence(selected.contract.goal_id, sliceId, "snapshot", actorId, evidenceTemp);
  fs.unlinkSync(evidenceTemp);
  process.stdout.write(manifestBytes);
}

function parseOptions(args, allowed) {
  const values = {};
  while (args.length > 0) {
    const flag = args.shift();
    if (!allowed.includes(flag) || values[flag] !== undefined || args.length === 0) {
      fail("WG-G-E-USAGE", "invalid or repeated option", 2);
    }
    const value = args.shift();
    if (value === "") fail("WG-G-E-USAGE", `${flag} requires a value`, 2);
    values[flag] = value;
  }
  return values;
}

if (command === "record-gate") {
  if (argv.length < 3) fail("WG-G-E-USAGE", "record-gate <graph> <slice> <gate> --status <passed|failed> --evidence <file> --actor <id>", 2);
  const [graph, slice, gate] = argv.splice(0, 3);
  const options = parseOptions(argv, ["--status", "--evidence", "--actor"]);
  if (!options["--status"] || !options["--evidence"] || !options["--actor"]) fail("WG-G-E-USAGE", "record-gate options are required", 2);
  recordGate(graph, slice, gate, options["--status"], options["--actor"], options["--evidence"]);
} else if (command === "record-evidence") {
  if (argv.length < 2) fail("WG-G-E-USAGE", "record-evidence <graph> <slice> --kind <kind> --evidence <file> --actor <id>", 2);
  const [graph, slice] = argv.splice(0, 2);
  const options = parseOptions(argv, ["--kind", "--evidence", "--actor"]);
  if (!options["--kind"] || !options["--evidence"] || !options["--actor"]) fail("WG-G-E-USAGE", "record-evidence options are required", 2);
  const graphModel = loadGraph(graph);
  const selected = loadContract(graphModel, slice);
  process.stdout.write(canonicalBytes(recordEvidence(selected.contract.goal_id, slice, options["--kind"], options["--actor"], options["--evidence"])));
} else if (command === "gate-status") {
  if (argv.length < 1 || argv.length > 2) fail("WG-G-E-USAGE", "gate-status <graph> [slice]", 2);
  gateStatus(argv[0], argv[1] || "");
} else if (command === "gate-check") {
  if (argv.length !== 2) fail("WG-G-E-USAGE", "gate-check <graph> <slice>", 2);
  gateCheck(argv[0], argv[1]);
} else if (command === "completion-check") {
  if (argv.length !== 2) fail("WG-G-E-USAGE", "completion-check <graph> <slice>", 2);
  completionCheck(argv[0], argv[1]);
} else if (command === "snapshot") {
  if (argv.length < 2) fail("WG-G-E-USAGE", "snapshot <graph> <slice> --actor <id>", 2);
  const [graph, slice] = argv.splice(0, 2);
  const options = parseOptions(argv, ["--actor"]);
  if (!options["--actor"]) fail("WG-G-E-USAGE", "snapshot --actor is required", 2);
  snapshot(graph, slice, options["--actor"]);
} else {
  fail("WG-G-E-USAGE", "unknown gate/evidence command", 2);
}
NODE

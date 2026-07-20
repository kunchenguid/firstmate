#!/usr/bin/env node

import { appendAudit, verifyAudit } from "./audit.mjs";
import { mintCapability } from "./capabilities.mjs";
import {
  BrokerDenied,
  PROTOCOL,
  allowedOperation,
  conciseError,
  ensureHomeDirs,
  normalizeOperation,
  readTaskMeta,
  requireHome,
  supportedLndevVersions,
} from "./common.mjs";
import { runClient } from "./client.mjs";
import { collectIdentityMetadata, shellList } from "./lndev.mjs";
import { serveBroker } from "./server.mjs";

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case "serve":
      await serveBroker(requireHome());
      return;
    case "mint":
      await mint(args);
      return;
    case "verify-audit":
      verify();
      return;
    case "request":
      await runClient(args);
      return;
    case "--help":
    case "help":
    case undefined:
      usage();
      process.exitCode = cmd ? 0 : 2;
      return;
    default:
      throw new BrokerDenied("usage", `unknown command ${cmd}`);
  }
}

async function mint(argv) {
  const started = Date.now();
  const home = requireHome();
  ensureHomeDirs(home);
  const opts = parseMintArgs(argv);
  let taskMeta = null;
  let identity = null;
  try {
    opts.operation = normalizeOperation(opts.operation);
    taskMeta = readTaskMeta(home, opts.taskId);
    identity = await collectIdentityMetadata();
    if (!allowedOperation(opts.operation)) {
      throw new BrokerDenied("operation-not-allowed", `operation ${opts.operation} is denied by v1 allowlist`);
    }
    if (opts.operation === "attach-existing" && !opts.sessionId) {
      throw new BrokerDenied("missing-session", "attach-existing capability requires --session");
    }
    if (opts.operation !== "attach-existing" && opts.sessionId) {
      throw new BrokerDenied("unexpected-session", "read-only capabilities must not name a session");
    }
    if (opts.operation === "shell-list") {
      await shellList();
    }
    const { record, handle } = await mintCapability(home, { ...opts, taskMeta });
    await appendAudit(home, {
      event: "capability_mint",
      task: { id: opts.taskId, meta: taskMeta },
      caller: localCaller(),
      operation: "capability-mint",
      normalized_args: {
        operation: opts.operation,
        sessionId: opts.sessionId || null,
        ttlSeconds: opts.ttlSeconds,
        expiresAt: record.expiresAt,
      },
      session_id: opts.sessionId || null,
      capability_id: record.id,
      lndev: identity,
      result: "allowed",
      duration_ms: Date.now() - started,
    });
    const output = {
      protocol: PROTOCOL,
      capabilityId: record.id,
      taskId: record.taskId,
      operation: record.operation,
      sessionId: record.sessionId,
      expiresAt: record.expiresAt,
      handle,
      handleFile: opts.outPath || null,
      supportedLndevVersions: supportedLndevVersions(),
    };
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
  } catch (error) {
    await appendAudit(home, {
      event: "capability_mint",
      task: opts.taskId ? { id: opts.taskId, meta: taskMeta } : null,
      caller: localCaller(),
      operation: "capability-mint",
      normalized_args: {
        operation: opts.operation || null,
        sessionId: opts.sessionId || null,
        ttlSeconds: opts.ttlSeconds || null,
      },
      session_id: opts.sessionId || null,
      capability_id: null,
      lndev: identity,
      result: error instanceof BrokerDenied ? "denied" : "error",
      reason: conciseError(error),
      duration_ms: Date.now() - started,
    });
    throw error;
  }
}

function parseMintArgs(argv) {
  const opts = {
    taskId: "",
    operation: "",
    sessionId: "",
    ttlSeconds: 0,
    expiresAt: "",
    approvalId: "",
    transcriptPolicy: "redacted-pty-jsonl",
    outPath: "",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--task") opts.taskId = requiredValue(argv, ++i, arg);
    else if (arg === "--operation") opts.operation = requiredValue(argv, ++i, arg);
    else if (arg === "--session") opts.sessionId = requiredValue(argv, ++i, arg);
    else if (arg === "--ttl-seconds") opts.ttlSeconds = Number(requiredValue(argv, ++i, arg));
    else if (arg === "--expires-at") opts.expiresAt = requiredValue(argv, ++i, arg);
    else if (arg === "--approval-id") opts.approvalId = requiredValue(argv, ++i, arg);
    else if (arg === "--transcript-policy") opts.transcriptPolicy = requiredValue(argv, ++i, arg);
    else if (arg === "--out") opts.outPath = requiredValue(argv, ++i, arg);
    else throw new BrokerDenied("usage", `unknown mint argument ${arg}`);
  }
  if (!opts.taskId) throw new BrokerDenied("usage", "mint requires --task");
  if (!opts.operation) throw new BrokerDenied("usage", "mint requires --operation");
  if (!Number.isFinite(opts.ttlSeconds) || opts.ttlSeconds === 0) {
    opts.ttlSeconds = opts.operation === "attach-existing" ? 600 : 3600;
  }
  if (opts.expiresAt && Number.isNaN(Date.parse(opts.expiresAt))) {
    throw new BrokerDenied("usage", "--expires-at must be an ISO timestamp");
  }
  return opts;
}

function verify() {
  const result = verifyAudit(requireHome());
  if (!result.ok) {
    process.stderr.write(`audit verify failed: ${result.reason}\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write(`audit verify ok: ${result.records} records\n`);
}

function localCaller() {
  return {
    pid: process.pid,
    ppid: process.ppid,
    exe: process.execPath,
    cwd: process.cwd(),
    tty: process.stdout.isTTY ? "stdout" : process.stderr.isTTY ? "stderr" : "none",
    envMarkers: [],
  };
}

function usage() {
  process.stdout.write(`usage:
  fm-lndev-captain-broker.sh serve
  fm-lndev-captain-broker.sh mint --task <id> --operation <status|shell-list|attach-existing> [--session <id>] [--ttl-seconds N] [--transcript-policy redacted-pty-jsonl|metadata-only] [--out file]
  fm-lndev-captain-broker.sh verify-audit
  fm-lndev-captain <status|shell-list|attach --session <id>> --task <id> [--handle-file file]
`);
}

function requiredValue(args, index, flag) {
  if (index >= args.length || !args[index]) throw new BrokerDenied("usage", `${flag} requires a value`);
  return args[index];
}

main().catch((error) => {
  process.stderr.write(`${conciseError(error)}\n`);
  process.exitCode = 1;
});

import { spawn } from "node:child_process";

import {
  BrokerDenied,
  containsSecretMaterial,
  normalizeOutput,
  nowMs,
  redactText,
  sha256,
  supportedLndevVersions,
} from "./common.mjs";

const VERSION_RE = /^lndev \d+\.\d+\.\d+ \([a-f0-9]{40}\)$/;
const ISO_RE = "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z";

export async function assertSupportedLndevVersion() {
  const result = await runLndev(["--version"], { timeoutMs: 5_000 });
  const output = strictSingleStdoutLine(result, "version");
  if (!VERSION_RE.test(output)) {
    throw new BrokerDenied("parse-mismatch", "lndev --version output did not match schema");
  }
  const supported = supportedLndevVersions();
  if (!supported.includes(output)) {
    throw new BrokerDenied(
      "unsupported-lndev-version",
      `unsupported lndev version ${output}, supported ${supported.join(", ")}`,
      { version: output, supported }
    );
  }
  return output;
}

export async function collectIdentityMetadata() {
  const version = await assertSupportedLndevVersion();
  const whoami = parseWhoami(await runLndev(["whoami"], { timeoutMs: 10_000 }));
  const auth = parseAuthList(await runLndev(["auth", "list"], { timeoutMs: 10_000 }));
  const matching = auth.tokens.filter((token) => token.tokenId === whoami.tokenId);
  if (matching.length !== 1) {
    throw new BrokerDenied("parse-mismatch", "whoami token id was absent or ambiguous in auth list");
  }
  if (Date.parse(matching[0].expiresAt) <= nowMs()) {
    throw new BrokerDenied("lndev-auth-expired", "lndev local auth token is expired");
  }
  const github = parseGithubStatus(await runLndev(["github", "status"], { timeoutMs: 10_000 }));
  return {
    version,
    credential: "present",
    identity: {
      name: whoami.name,
      email: whoami.email,
      identityId: whoami.identityId,
      tokenId: whoami.tokenId,
      expiresAt: matching[0].expiresAt,
      deviceLabel: matching[0].deviceLabel,
      createdAt: matching[0].createdAt,
      lastUsedAt: matching[0].lastUsedAt,
    },
    github,
  };
}

export async function shellList() {
  const result = await runLndev(["shell", "ls"], { timeoutMs: 10_000 });
  return parseShellList(result);
}

export async function runLndev(args, opts = {}) {
  const bin = process.env.FM_LNDEV_BINARY || "lndev";
  const timeoutMs = opts.timeoutMs || 10_000;
  const started = nowMs();
  const env = safeLndevEnv();
  return await new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      env,
      cwd: process.env.FM_LNDEV_BROKER_CWD || process.env.HOME || "/",
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new BrokerDenied("lndev-timeout", `lndev ${args.join(" ")} timed out`));
    }, timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (status, signal) => {
      clearTimeout(timer);
      resolve({
        args,
        status,
        signal,
        stdout,
        stderr,
        durationMs: nowMs() - started,
      });
    });
  });
}

export function safeLndevEnv() {
  const allowed = [
    "HOME",
    "PATH",
    "USER",
    "LOGNAME",
    "SHELL",
    "TMPDIR",
    "TERM",
    "LNDEV_API_HOST",
    "LNDEV_FRONTEND_HOST",
    "FM_LNDEV_FAKE_SCENARIO_FILE",
    "FM_LNDEV_FAKE_RECORD_DIR",
    "FM_LNDEV_FAKE_SECRET_FILE",
  ];
  const env = {};
  for (const key of allowed) {
    if (process.env[key]) env[key] = process.env[key];
  }
  env.LNDEV_SKIP_AUTO_UPDATE = "1";
  return env;
}

export function parseWhoami(result) {
  const lines = strictStdoutLines(result, "whoami");
  if (lines.length !== 2) {
    throw new BrokerDenied("parse-mismatch", "whoami expected exactly two output lines");
  }
  const first = lines[0].match(/^([^<>\n]+) <([^<>\s]+@[^<>\s]+)>  \(identity ([a-f0-9]{24})\)$/);
  const second = lines[1].match(/^token ([a-f0-9]{24})$/);
  if (!first || !second) {
    throw new BrokerDenied("parse-mismatch", "whoami output did not match schema");
  }
  return {
    name: first[1].trim(),
    email: first[2],
    identityId: first[3],
    tokenId: second[1],
  };
}

export function parseAuthList(result) {
  const lines = strictStdoutLines(result, "auth list");
  if (lines.length < 1) throw new BrokerDenied("parse-mismatch", "auth list was empty");
  const seen = new Set();
  const tokens = [];
  const re = new RegExp(
    `^([a-f0-9]{24})  ([A-Za-z0-9 ._-]+?)\\s{2,}created=(${ISO_RE})  last-used=(${ISO_RE})  expires=(${ISO_RE})$`
  );
  for (const line of lines) {
    const match = line.match(re);
    if (!match) throw new BrokerDenied("parse-mismatch", "auth list row did not match schema");
    if (seen.has(match[1])) throw new BrokerDenied("parse-mismatch", "auth list duplicated token id");
    seen.add(match[1]);
    tokens.push({
      tokenId: match[1],
      deviceLabel: match[2].trim(),
      createdAt: assertValidIso(match[3]),
      lastUsedAt: assertValidIso(match[4]),
      expiresAt: assertValidIso(match[5]),
    });
  }
  return { tokens };
}

export function parseGithubStatus(result) {
  const line = strictSingleStdoutLine(result, "github status");
  const re = new RegExp(`^connected as ([A-Za-z0-9_.-]+), scopes=<([^>]+)>, refresh-token expires (${ISO_RE})$`);
  const match = line.match(re);
  if (!match) throw new BrokerDenied("parse-mismatch", "github status output did not match schema");
  return {
    state: "connected",
    username: match[1],
    scopes: match[2] === "none" ? [] : match[2].split(",").map((scope) => scope.trim()),
    refreshTokenExpiresAt: assertValidIso(match[3]),
  };
}

export function parseShellList(result) {
  const lines = strictStdoutLines(result, "shell ls");
  if (
    lines.length === 2 &&
    lines[0] === "No active engineer shell sessions. Spawn one with: lndev shell new" &&
    lines[1] === "Pass --all to include destroyed sessions."
  ) {
    return { sessions: [] };
  }
  if (lines[0] !== "ID  STATUS  REPOSITORY  BRANCH  UPDATED") {
    throw new BrokerDenied("parse-mismatch", "shell ls header did not match schema");
  }
  const sessions = [];
  const re = new RegExp(`^([A-Za-z0-9._:-]+)  ([A-Za-z][A-Za-z0-9_-]*)  ([^\\s]+)  ([^\\s]+)  (${ISO_RE})$`);
  for (const line of lines.slice(1)) {
    const match = line.match(re);
    if (!match) throw new BrokerDenied("parse-mismatch", "shell ls row did not match schema");
    sessions.push({
      sessionId: match[1],
      status: match[2],
      repository: match[3],
      branch: match[4],
      updatedAt: assertValidIso(match[5]),
    });
  }
  return { sessions };
}

export function validateAttachTranscript(transcript, sessionId) {
  if (containsSecretMaterial(transcript)) {
    throw new BrokerDenied("secret-output", "lndev attach output contained credential-shaped material");
  }
  const lines = normalizeOutput(transcript)
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const startMarker = `Attached to engineer shell session ${sessionId}`;
  const endMarker = `Detached from engineer shell session ${sessionId}`;
  const startCount = lines.filter((line) => line === startMarker).length;
  const endCount = lines.filter((line) => line === endMarker).length;
  if (startCount !== 1 || endCount !== 1) {
    throw new BrokerDenied("parse-mismatch", "attach output lacked exact success markers");
  }
  return {
    startMarker,
    endMarker,
    transcriptDigest: sha256ForTranscript(transcript),
  };
}

function strictSingleStdoutLine(result, label) {
  const lines = strictStdoutLines(result, label);
  if (lines.length !== 1) {
    throw new BrokerDenied("parse-mismatch", `${label} expected exactly one output line`);
  }
  return lines[0];
}

function strictStdoutLines(result, label) {
  if (result.status !== 0 || result.signal) {
    throw new BrokerDenied("parse-mismatch", `${label} exited nonzero or by signal`);
  }
  if (result.stderr.trim() !== "") {
    throw new BrokerDenied("parse-mismatch", `${label} wrote unexpected stderr`);
  }
  if (containsSecretMaterial(result.stdout) || containsSecretMaterial(result.stderr)) {
    throw new BrokerDenied("secret-output", `${label} output contained credential-shaped material`);
  }
  const normalized = normalizeOutput(result.stdout);
  if (normalized === "") throw new BrokerDenied("parse-mismatch", `${label} produced no stdout`);
  const lines = normalized.split("\n");
  if (lines.some((line) => line === "")) {
    throw new BrokerDenied("parse-mismatch", `${label} contained blank output lines`);
  }
  if (redactText(normalized) !== normalized) {
    throw new BrokerDenied("secret-output", `${label} output required redaction`);
  }
  return lines;
}

function assertValidIso(value) {
  if (Number.isNaN(Date.parse(value))) {
    throw new BrokerDenied("parse-mismatch", `invalid timestamp ${value}`);
  }
  return value;
}

function sha256ForTranscript(text) {
  return sha256(redactText(text));
}

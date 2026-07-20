// Firstmate restricted DeepSeek-lane tool extension.
//
// Loaded via `-e` for a restricted Pi launch (bin/fm-spawn.sh, pi_restricted_model()).
// This file is static and tracked: nothing here is generated or interpolated per
// spawn. Per-task parameters (report path, status path, task id) arrive only
// through the FM_RESTRICTED_TASK_CONFIG environment variable, which
// fm-spawn.sh sets to a small JSON object of non-secret paths before launch.
//
// Threat model: the launching Pi process has --no-builtin-tools, --tools
// <this file's tool names>, --no-context-files, --no-skills,
// --no-prompt-templates, --no-extensions, and --no-session. This extension is
// the ONLY code path the model can reach. It must never expose the shell, the
// filesystem beyond the two fixed output paths, MCP, local config/auth, or any
// environment value beyond the three non-secret config fields it reads itself.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { StringEnum } from "@earendil-works/pi-ai";
import { appendFile, writeFile } from "node:fs/promises";
import { lookup } from "node:dns/promises";
import * as https from "node:https";
import { isIPv4, isIPv6 } from "node:net";

interface RestrictedTaskConfig {
  reportPath: string;
  statusPath: string;
  taskId: string;
}

const ALLOWED_STATUS_STATES = ["working", "needs-decision", "blocked", "paused", "done", "failed"] as const;
const MAX_STATUS_MESSAGE_CHARS = 500;
const MAX_REPORT_CHARS = 200_000;
const MAX_FETCH_BYTES = 1_000_000;
const MAX_REDIRECTS = 5;
const PER_REQUEST_TIMEOUT_MS = 15_000;
const TOTAL_FETCH_TIMEOUT_MS = 30_000;
const ALLOWED_CONTENT_TYPE_PREFIXES = ["text/", "application/json", "application/xml", "application/xhtml+xml"];

function loadConfig(): RestrictedTaskConfig {
  const raw = process.env.FM_RESTRICTED_TASK_CONFIG;
  if (!raw) {
    throw new Error("restricted task config is not set; refusing to run without a trusted destination");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("restricted task config is not valid JSON");
  }
  const cfg = parsed as Partial<RestrictedTaskConfig>;
  if (
    typeof cfg.reportPath !== "string" ||
    typeof cfg.statusPath !== "string" ||
    typeof cfg.taskId !== "string"
  ) {
    throw new Error("restricted task config is missing required fields");
  }
  return cfg as RestrictedTaskConfig;
}

function rejectNewline(label: string, value: string): void {
  if (/[\r\n]/.test(value)) {
    throw new Error(`${label} must not contain a newline`);
  }
}

async function appendStatusLine(config: RestrictedTaskConfig, state: string, message: string): Promise<void> {
  rejectNewline("status message", message);
  if (message.length > MAX_STATUS_MESSAGE_CHARS) {
    throw new Error(`status message exceeds ${MAX_STATUS_MESSAGE_CHARS} characters`);
  }
  await appendFile(config.statusPath, `${state}: ${message}\n`, "utf8");
}

// --- public_fetch: HTTPS-only, per-hop DNS/IP validated, no ambient auth ---

function ipv4ToUint(parts: number[]): number {
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

function isForbiddenIPv4(address: string): boolean {
  const parts = address.split(".").map((p) => Number(p));
  if (parts.length !== 4 || parts.some((p) => !Number.isInteger(p) || p < 0 || p > 255)) {
    return true;
  }
  const value = ipv4ToUint(parts);
  const inRange = (base: string, bits: number): boolean => {
    const baseParts = base.split(".").map((p) => Number(p));
    const baseValue = ipv4ToUint(baseParts);
    const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
    return (value & mask) === (baseValue & mask);
  };
  return (
    inRange("0.0.0.0", 8) || // "this network"
    inRange("10.0.0.0", 8) || // RFC1918
    inRange("100.64.0.0", 10) || // CGNAT
    inRange("127.0.0.0", 8) || // loopback
    inRange("169.254.0.0", 16) || // link-local incl. cloud metadata
    inRange("172.16.0.0", 12) || // RFC1918
    inRange("192.168.0.0", 16) || // RFC1918
    inRange("192.0.0.0", 24) || // IETF protocol assignments
    inRange("192.0.2.0", 24) || // documentation (TEST-NET-1)
    inRange("198.18.0.0", 15) || // benchmarking
    inRange("198.51.100.0", 24) || // documentation (TEST-NET-2)
    inRange("203.0.113.0", 24) || // documentation (TEST-NET-3)
    inRange("224.0.0.0", 4) || // multicast
    inRange("240.0.0.0", 4) || // reserved
    value === 0xffffffff // broadcast
  );
}

// Expands a textual IPv6 address (with optional "::" compression and a trailing
// dotted-quad group) into its eight 16-bit groups, or null if unparseable.
function expandIPv6Groups(address: string): number[] | null {
  const addr = address.split("%")[0];
  const halves = addr.split("::");
  if (halves.length > 2) return null;
  const parseSide = (side: string): number[] | null => {
    if (side === "") return [];
    const segs = side.split(":");
    const groups: number[] = [];
    for (let i = 0; i < segs.length; i++) {
      const seg = segs[i];
      if (seg.includes(".")) {
        if (i !== segs.length - 1) return null;
        const bytes = seg.split(".").map(Number);
        if (bytes.length !== 4 || bytes.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return null;
        groups.push((bytes[0] << 8) | bytes[1], (bytes[2] << 8) | bytes[3]);
      } else {
        if (!/^[0-9a-f]{1,4}$/.test(seg)) return null;
        groups.push(parseInt(seg, 16));
      }
    }
    return groups;
  };
  if (halves.length === 1) {
    const groups = parseSide(halves[0]);
    return groups && groups.length === 8 ? groups : null;
  }
  const head = parseSide(halves[0]);
  const tail = parseSide(halves[1]);
  if (head === null || tail === null) return null;
  const missing = 8 - head.length - tail.length;
  if (missing < 0) return null;
  return [...head, ...new Array(missing).fill(0), ...tail];
}

// Embedded-IPv4 prefixes to unwrap before re-checking the low 32 bits: IPv4-mapped
// (::ffff:0:0/96), IPv4-compatible (deprecated ::/96), and the NAT64 well-known
// prefix (64:ff9b::/96, RFC 6052) all carry a real IPv4 address in their low 32 bits.
const EMBEDDED_IPV4_PREFIXES: number[][] = [
  [0, 0, 0, 0, 0, 0xffff],
  [0, 0, 0, 0, 0, 0],
  [0x64, 0xff9b, 0, 0, 0, 0],
];

function isForbiddenIPv6(address: string): boolean {
  const normalized = address.toLowerCase();
  if (normalized === "::1" || normalized === "::") {
    return true;
  }
  const groups = expandIPv6Groups(normalized);
  if (groups) {
    const prefix = groups.slice(0, 6);
    const embedsIPv4 = EMBEDDED_IPV4_PREFIXES.some((p) => p.every((g, i) => prefix[i] === g));
    if (embedsIPv4) {
      const ipv4 = `${groups[6] >> 8}.${groups[6] & 0xff}.${groups[7] >> 8}.${groups[7] & 0xff}`;
      return isForbiddenIPv4(ipv4);
    }
  }
  if (normalized.startsWith("fe80:") || normalized.startsWith("fe8") || normalized.startsWith("fe9") || normalized.startsWith("fea") || normalized.startsWith("feb")) {
    return true; // link-local fe80::/10
  }
  if (normalized.startsWith("fc") || normalized.startsWith("fd")) {
    return true; // unique local fc00::/7
  }
  if (normalized.startsWith("ff")) {
    return true; // multicast ff00::/8
  }
  return false;
}

function isForbiddenAddress(address: string): boolean {
  if (isIPv4(address)) return isForbiddenIPv4(address);
  if (isIPv6(address)) return isForbiddenIPv6(address);
  return true; // unrecognized form: refuse rather than guess
}

async function resolveSafeAddress(hostname: string): Promise<string> {
  if (hostname.toLowerCase() === "localhost") {
    throw new Error("refusing to fetch localhost");
  }
  let addresses: Array<{ address: string }>;
  try {
    addresses = await lookup(hostname, { all: true, verbatim: true });
  } catch {
    throw new Error(`could not resolve host: ${hostname}`);
  }
  if (addresses.length === 0) {
    throw new Error(`could not resolve host: ${hostname}`);
  }
  for (const { address } of addresses) {
    if (isForbiddenAddress(address)) {
      throw new Error("refusing to fetch a private, loopback, link-local, or metadata address");
    }
  }
  return addresses[0].address;
}

interface FetchHop {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: Buffer;
}

function requestOnce(url: URL, ip: string, deadline: number): Promise<FetchHop> {
  return new Promise((resolve, reject) => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      reject(new Error("fetch deadline exceeded"));
      return;
    }
    const req = https.request(
      {
        hostname: ip,
        servername: url.hostname,
        port: url.port ? Number(url.port) : 443,
        path: `${url.pathname}${url.search}`,
        method: "GET",
        headers: { Host: url.hostname, "User-Agent": "firstmate-restricted-scout/1.0" },
        timeout: Math.min(PER_REQUEST_TIMEOUT_MS, remaining),
        rejectUnauthorized: true,
      },
      (res) => {
        const chunks: Buffer[] = [];
        let total = 0;
        res.on("data", (chunk: Buffer) => {
          total += chunk.length;
          if (total > MAX_FETCH_BYTES) {
            req.destroy();
            reject(new Error(`response exceeds ${MAX_FETCH_BYTES} bytes`));
            return;
          }
          chunks.push(chunk);
        });
        res.on("end", () => {
          resolve({ status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(chunks) });
        });
        res.on("error", reject);
      },
    );
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("fetch timed out"));
    });
    req.on("error", () => reject(new Error("fetch failed")));
    req.end();
  });
}

async function safeFetch(rawUrl: string): Promise<{ status: number; contentType: string; body: string }> {
  let current: URL;
  try {
    current = new URL(rawUrl);
  } catch {
    throw new Error("invalid URL");
  }
  const deadline = Date.now() + TOTAL_FETCH_TIMEOUT_MS;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    if (current.protocol !== "https:") {
      throw new Error("only https URLs are allowed");
    }
    const ip = await resolveSafeAddress(current.hostname);
    const result = await requestOnce(current, ip, deadline);
    if (result.status >= 300 && result.status < 400) {
      const location = result.headers.location;
      if (!location || Array.isArray(location)) {
        throw new Error("redirect without a usable location");
      }
      if (hop === MAX_REDIRECTS) {
        throw new Error("too many redirects");
      }
      current = new URL(location, current);
      continue;
    }
    const contentType = Array.isArray(result.headers["content-type"])
      ? result.headers["content-type"][0]
      : result.headers["content-type"] ?? "";
    if (!ALLOWED_CONTENT_TYPE_PREFIXES.some((prefix) => contentType.startsWith(prefix))) {
      throw new Error(`unsupported content type: ${contentType || "(none)"}`);
    }
    return { status: result.status, contentType, body: result.body.toString("utf8") };
  }
  throw new Error("too many redirects");
}

export default function (pi: ExtensionAPI) {
  const config = loadConfig();

  pi.registerTool({
    name: "public_fetch",
    label: "Public Fetch",
    description: "Fetch a public HTTPS URL. Rejects private, loopback, link-local, and metadata addresses on every request and redirect hop.",
    promptSnippet: "Fetch a public HTTPS URL for research",
    promptGuidelines: ["Use public_fetch only for public, non-sensitive HTTPS URLs needed to answer the task."],
    parameters: Type.Object({ url: Type.String() }),
    async execute(_toolCallId, params) {
      const result = await safeFetch(params.url);
      return {
        content: [{ type: "text", text: result.body }],
        details: { status: result.status, contentType: result.contentType },
      };
    },
  });

  pi.registerTool({
    name: "write_report",
    label: "Write Report",
    description: "Overwrite the task's report with the given content.",
    promptSnippet: "Write the final task report",
    promptGuidelines: ["Use write_report once, with the complete report content, before calling complete_scout."],
    parameters: Type.Object({ content: Type.String() }),
    async execute(_toolCallId, params) {
      if (params.content.length > MAX_REPORT_CHARS) {
        throw new Error(`report exceeds ${MAX_REPORT_CHARS} characters`);
      }
      await writeFile(config.reportPath, params.content, "utf8");
      return { content: [{ type: "text", text: "Report written." }], details: {} };
    },
  });

  pi.registerTool({
    name: "append_status",
    label: "Append Status",
    description: "Append one supervisor-actionable status line.",
    promptSnippet: "Report task progress to the supervisor",
    promptGuidelines: [
      "Use append_status with state working to report progress, blocked or paused for a bounded wait, and failed if the task cannot be completed.",
    ],
    parameters: Type.Object({
      state: StringEnum(ALLOWED_STATUS_STATES),
      message: Type.String(),
    }),
    async execute(_toolCallId, params) {
      await appendStatusLine(config, params.state, params.message);
      return { content: [{ type: "text", text: "Status recorded." }], details: {} };
    },
  });

  pi.registerTool({
    name: "complete_scout",
    label: "Complete Scout",
    description:
      "Declare whether the task surfaced an unresolved decision that needs the captain's input. This is the required last step before finishing.",
    promptSnippet: "Declare completion or an unresolved decision",
    promptGuidelines: [
      "Call complete_scout exactly once when the task is finished, after write_report for a normal completion.",
      "Set unresolvedDecision to true and stop immediately if the task surfaced a choice only the captain can make; do not resolve it yourself.",
    ],
    parameters: Type.Object({
      unresolvedDecision: Type.Boolean(),
      summary: Type.String(),
    }),
    async execute(_toolCallId, params) {
      if (params.unresolvedDecision) {
        await appendStatusLine(config, "needs-decision", params.summary);
        return {
          content: [{ type: "text", text: "Recorded needs-decision. Stopping for firstmate." }],
          details: {},
          terminate: true,
        };
      }
      rejectNewline("summary", params.summary);
      return {
        content: [
          {
            type: "text",
            text: "No unresolved decision confirmed. Call write_report, then append_status with state done, to finish.",
          },
        ],
        details: {},
      };
    },
  });
}

import { createHash } from "node:crypto";

export const HISTORY_TYPE = "fm-read-repetition-state-v1";
export const NOTICE_TYPE = "fm-read-repetition-stopped";
export const WINDOW_MS = 15 * 60 * 1000;
const MAX_KEYS = 128;
const MAX_IDS = 512;
export type ReadLimits = { enabled: boolean; repeatLimit: number; windowMs: number };
export const DEFAULT_LIMITS: Readonly<ReadLimits> = Object.freeze({
  enabled: false, repeatLimit: 3, windowMs: WINDOW_MS,
});

// Operator configuration only, never model/tool input. Keep both cost and
// persisted history bounded even when an operator raises the repetition limit.
export function readLimits(value: unknown = {}): Readonly<ReadLimits> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("read-repetition.json must contain an object");
  }
  const config = value as Record<string, unknown>;
  if (Object.keys(config).some((key) => !["enabled", "repeatLimit", "windowMs"].includes(key))) {
    throw new Error("read-repetition.json accepts only enabled, repeatLimit and windowMs");
  }
  const limits = { ...DEFAULT_LIMITS, ...config };
  if (typeof limits.enabled !== "boolean" ||
      !Number.isSafeInteger(limits.repeatLimit) || Number(limits.repeatLimit) < 2 || Number(limits.repeatLimit) > 32 ||
      !Number.isSafeInteger(limits.windowMs) || Number(limits.windowMs) < 1000 || Number(limits.windowMs) > 86_400_000) {
    throw new Error("read-repetition.json requires enabled boolean, repeatLimit integer 2..32 and windowMs integer 1000..86400000");
  }
  return Object.freeze(limits) as Readonly<ReadLimits>;
}

export const digest = (value: unknown): string =>
  createHash("sha256").update(stable(value)).digest("hex");

function stable(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stable).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.entries(value).sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${JSON.stringify(k)}:${stable(v)}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

type Token = { word: string } | { op: string };

// Deliberately a small recognizer, never a shell/interpreter. Unknown syntax
// is uncounted, not denied. This is a loop detector, not a security boundary.
function tokenize(command: string, grouped: boolean): Token[] | undefined {
  if (command.length > 32_768) return;
  const tokens: Token[] = [];
  let word = "", started = false;
  const flush = (): void => {
    if (started) tokens.push({ word });
    word = ""; started = false;
  };
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (grouped && ch === "\\" && command[i + 1] === "\n") { i++; continue; }
    if (ch === "\r") return;
    if (ch === "\n") {
      if (!grouped) return;
      flush();
      // In the one supported outer group, newline separates commands unless
      // the preceding operator already supplies the separator/continuation.
      const last = tokens[tokens.length - 1];
      if (last && ("word" in last || last.op === "2>&1")) tokens.push({ op: ";" });
      continue;
    }
    if (/\s/.test(ch)) { flush(); continue; }
    if (ch === "'" || ch === '"') {
      started = true;
      const quote = ch;
      let closed = false;
      while (++i < command.length) {
        const next = command[i];
        if (next === quote) { closed = true; break; }
        if (next === "\n" || next === "\r") return;
        if (quote === '"' && (next === "$" || next === "`" || next === "\\")) return;
        word += next;
      }
      if (!closed) return;
      continue;
    }
    if (command.startsWith("2>&1", i) && !started &&
        (i + 4 === command.length || /[\s|;]/.test(command[i + 4]))) {
      tokens.push({ op: "2>&1" }); i += 3; continue;
    }
    if (command.startsWith("&&", i)) {
      flush(); tokens.push({ op: "&&" }); i++; continue;
    }
    if (ch === ";" || ch === "|") {
      if (ch === "|" && command[i + 1] === "|") return;
      flush(); tokens.push({ op: ch }); continue;
    }
    if (/[&<>$`(){}\\#]/.test(ch)) return;
    word += ch; started = true;
  }
  flush();
  return tokens;
}

function simpleRead(words: string[], root: string, remote: boolean): boolean {
  const [name, ...args] = words;
  const path = (s: string): boolean => Boolean(s) && !s.startsWith("-");
  if (name === "echo") return true;
  if (name === "cd") return args.length === 1 && args[0].startsWith("/");
  if (name === "sleep") return args.length === 1 && /^(?:[1-9]|[1-5][0-9]|60)(?:s)?$/.test(args[0]);
  if (name === "cat") return args.length > 0 && args.every(path);
  if (name === "head" || name === "tail") {
    return args.length > 0 && args.every((arg, i) =>
      /^-\d+$/.test(arg) || /^-[nc]\d+$/.test(arg) ||
      (/^-[nc]$/.test(arg) && /^\d+$/.test(args[i + 1] ?? "")) || path(arg));
  }
  if (name === "sed") {
    return args[0] === "-n" && /^\d+(?:,\d+)?p$/.test(args[1] ?? "") && args.slice(2).every(path);
  }
  if (name === "cut") return args.length === 1 && /^-c[1-9]\d*-[1-9]\d*$/.test(args[0]);
  if (name === "nl") return args.every((arg) => /^-b[atn]$/.test(arg) || path(arg));
  if (name === "wc") return args.every((arg) => /^-[clmwL]+$/.test(arg) || path(arg));
  if (name === "od") {
    return args.every((arg) => /^-A[nodx]$/.test(arg) || /^-t(?:x[1248]|[cu])+$/.test(arg) || path(arg));
  }
  if (name === "grep") {
    // GNU grep's options read/filter only; refuse unfamiliar options anyway.
    let i = 0;
    while (i < args.length && /^-[nEiFivHhocl]+$/.test(args[i])) i++;
    return i < args.length && path(args[i]) && args.slice(i + 1).every(path);
  }
  if (name === "git") {
    return args[0] === "diff" && args[1] === "--stat" && args.length === 3 &&
      /^[a-f0-9]{7,40}\.\.HEAD$/.test(args[2]);
  }
  if (!remote) {
    let i = 0;
    if (words[0]?.startsWith("FM_HOME=")) {
      if (!/^FM_HOME=\/[\w./-]+$/.test(words[0])) return false;
      i++;
    }
    return words[i] === `${root}/bin/fm-tasks-axi.sh` && words[i + 1] === "show" &&
      /^[a-zA-Z0-9][\w.-]*$/.test(words[i + 2] ?? "") &&
      (words.length === i + 3 || (words.length === i + 4 && words[i + 3] === "--full"));
  }
  return false;
}

function readonlyShell(command: string, root: string, remote = false): boolean {
  if (command.length > 32_768) return false;
  let body = command.trim();
  // Exactly one outer subshell around a recognized sequence, never nested
  // groups, functions or general shell parsing. Interior metacharacters still
  // pass through the same conservative tokenizer and per-stage allowlist.
  const grouped = body.startsWith("(") && body.endsWith(")");
  if (grouped) body = body.slice(1, -1);
  const tokens = tokenize(body, grouped);
  if (!tokens?.length) return false;
  let words: string[] = [];
  const finish = (): boolean => {
    if (!words.length) return false;
    let ok: boolean;
    if (!remote && words[0] === "ssh") {
      // Exact observed transport options; no -F, ProxyCommand, local forwarding,
      // arbitrary remote executables, or a second shell hidden in the payload.
      ok = words.length === 7 && words[1] === "-o" && words[2] === "BatchMode=yes" &&
        words[3] === "-o" && words[4] === "ConnectTimeout=10" && /^[a-zA-Z0-9][\w.@:-]*$/.test(words[5]) &&
        readonlyShell(words[6], root, true);
    } else ok = simpleRead(words, root, remote);
    words = [];
    return ok;
  };
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if ("word" in token) words.push(token.word);
    else if (token.op === "2>&1") { if (!words.length) return false; }
    else {
      if (!finish()) return false;
      // A terminating separator is allowed only in the outer grouped form.
      if (i === tokens.length - 1) return grouped && token.op === ";";
    }
  }
  return finish();
}

export type ReadIdentity = { key: string; label: string };
export function identifyRead(toolName: string, input: Record<string, unknown>, root: string): ReadIdentity | undefined {
  if (toolName === "bash") {
    if (typeof input.command !== "string" || !readonlyShell(input.command, root)) return;
    return { key: digest([toolName, input.command]), label: input.command.startsWith("ssh ") ? "ssh read" : "bash read" };
  }
  if (["read", "grep", "find", "ls"].includes(toolName)) {
    return { key: digest([toolName, input]), label: `${toolName} read` };
  }
  // Polling tools and bounded watch commands stay outside the read allowlist.
  // No text marker, timeout flag, or appended sleep grants a polling exemption.
}

type Row = ReadIdentity & { output: string; times: number[] };
export type Snapshot = { version: 1; epoch: number; rows: Row[]; ids: string[]; stopped?: string };
export class ReadRepetition {
  private rows = new Map<string, Row>();
  private ids = new Set<string>();
  private pending = new Map<string, { identity: ReadIdentity; epoch: number }>();
  private epoch = 0;
  stopped: string | undefined;

  private readonly limits: Readonly<ReadLimits>;
  private readonly root: string;
  private readonly now: () => number;
  constructor(root: string, now = Date.now, limits: Readonly<ReadLimits> = DEFAULT_LIMITS) {
    this.root = root;
    this.now = now;
    this.limits = readLimits(limits);
  }

  reset(): void {
    this.rows.clear(); this.ids.clear(); this.pending.clear(); this.stopped = undefined; this.epoch++;
  }

  discardPending(id: string): void {
    // A result observed without ownership cannot count as a success, but it
    // still retires the volatile in-flight veto. Preserve history and latch.
    this.pending.delete(id);
  }

  snapshot(): Snapshot {
    return { version: 1, epoch: this.epoch, rows: [...this.rows.values()], ids: [...this.ids], stopped: this.stopped };
  }

  restore(value: unknown): void {
    const s = value as Snapshot | undefined;
    if (s?.version !== 1 || !Number.isSafeInteger(s.epoch) || !Array.isArray(s.rows) || !Array.isArray(s.ids)) return;
    this.epoch = s.epoch;
    this.stopped = typeof s.stopped === "string" ? s.stopped : undefined;
    this.ids = new Set(s.ids.filter((id) => typeof id === "string").slice(-MAX_IDS));
    this.rows.clear(); this.pending.clear();
    for (const row of s.rows.slice(-MAX_KEYS)) {
      if (!row || !/^[a-f0-9]{64}$/.test(row.key) || !/^[a-f0-9]{64}$/.test(row.output) ||
          !/^(?:bash|ssh|read|grep|find|ls) read$/.test(row.label) || !Array.isArray(row.times)) continue;
      this.rows.set(row.key, { key: row.key, label: row.label, output: row.output,
        times: row.times.filter((t) => Number.isFinite(t)).slice(-this.limits.repeatLimit) });
    }
    this.prune();
  }

  private prune(): void {
    const now = this.now();
    for (const [key, row] of this.rows) {
      row.times = row.times.filter((t) => t <= now && now - t <= this.limits.windowMs);
      if (!row.times.length) this.rows.delete(key);
    }
  }

  before(id: string, name: string, input: Record<string, unknown>): string | undefined {
    if (!this.limits.enabled) return;
    if (this.stopped) return this.stopped;
    this.prune();
    const identity = identifyRead(name, input, this.root);
    if (!identity) return;
    const row = this.rows.get(identity.key);
    if (row && row.times.length >= this.limits.repeatLimit) {
      this.stopped = `Stopped repeated reads: ${identity.label} #${identity.key.slice(0, 12)} ` +
        `returned the same successful output ${this.limits.repeatLimit} times within ${this.limits.windowMs} ms. The next call was blocked before execution. ` +
        `New user input is required to resume; no work was replayed and no model was changed.`;
      return this.stopped;
    }
    // Pi 1.4 prepares a parallel batch before executing any of it. Do not
    // authorize two identical reads in flight: the later one cannot yet use
    // the earlier result. This is a temporary veto, never success evidence or
    // an abort. Distinct A/B reads still run together.
    if ([...this.pending.values()].some((call) => call.identity.key === identity.key)) {
      return `Read #${identity.key.slice(0, 12)} is already pending; use its completed result before repeating it.`;
    }
    this.pending.set(id, { identity, epoch: this.epoch });
    if (this.pending.size > MAX_IDS) this.pending.delete(this.pending.keys().next().value!);
  }

  complete(event: {
    toolCallId: string; toolName: string; input: Record<string, unknown>;
    isError: boolean; content: unknown; structuredContent?: unknown; details?: unknown;
  }): boolean {
    const pending = this.pending.get(event.toolCallId);
    this.pending.delete(event.toolCallId);
    if (!pending || pending.epoch !== this.epoch || this.ids.has(event.toolCallId)) return false;
    const identity = identifyRead(event.toolName, event.input, this.root);
    if (identity?.key !== pending.identity.key) return false;
    this.ids.add(event.toolCallId);
    if (this.ids.size > MAX_IDS) this.ids.delete(this.ids.values().next().value!);
    const structured = event.structuredContent as { exit_code?: unknown } | undefined;
    const details = event.details as { exitCode?: unknown; exit_code?: unknown } | undefined;
    const codes = [structured?.exit_code, details?.exitCode, details?.exit_code];
    if (event.isError === true || codes.some((code) => code !== undefined && code !== 0)) {
      this.rows.delete(identity.key);
      return true;
    }
    if (event.isError !== false || !Array.isArray(event.content)) return false;
    this.prune();
    // Pi appends a fresh temporary file path to truncated Bash content as well
    // as details. Remove only that terminal SDK footer's matching path, keeping
    // the displayed read data, truncation counts and structured output intact.
    const truncation = event.details as { fullOutputPath?: unknown; truncation?: { truncated?: unknown } } | undefined;
    const content = event.content.map((part: unknown) => {
      const block = part as { type?: unknown; text?: unknown } | null;
      if (event.toolName !== "bash" || block?.type !== "text" || typeof block.text !== "string" ||
          truncation?.truncation?.truncated !== true || typeof truncation.fullOutputPath !== "string") return part;
      const suffix = `Full output: ${truncation.fullOutputPath}]`;
      if (!block.text.includes("\n\n[Showing ") || !block.text.endsWith(suffix)) return part;
      return { ...block, text: block.text.slice(0, -suffix.length) + "Full output: <temporary file>]" };
    });
    const output = digest([content, (event.structuredContent as { output?: unknown } | undefined)?.output]);
    const previous = this.rows.get(identity.key);
    const times = previous?.output === output ? previous.times : [];
    const row: Row = { ...identity, output, times: [...times, this.now()].slice(-this.limits.repeatLimit) };
    this.rows.delete(identity.key); this.rows.set(identity.key, row);
    if (this.rows.size > MAX_KEYS) this.rows.delete(this.rows.keys().next().value!);
    return true;
  }
}

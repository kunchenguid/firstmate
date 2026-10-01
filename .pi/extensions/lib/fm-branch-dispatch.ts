import { lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { runCommandAsync } from "./fm-async-exec.ts";

// Shared wake-dispatch handshake between the Pi watcher extension (the
// dispatcher) and the supervision-branch extension (the handler), carried over
// pi.events so neither extension imports the other.
//
// Contract: the watcher builds one offer per actionable wake and emits it on
// FM_BRANCH_DISPATCH_EVENT. A live, enabled branch extension calls accept()
// SYNCHRONOUSLY inside its handler (the event bus invokes handlers
// synchronously up to their first await), so after emit returns the watcher
// reads `accepted`: true means the branch owns handling the wake, and its
// settlement promise keeps the watcher outcome pending until handling finishes
// or rejects back to the watcher's main path (docs/watcher-continuity.md); false
// means no branch took it and the watcher delivers to main exactly as it did
// before the branch existed. Watcher-failure alarms are never offered - only
// main can repair the watcher cycle (fm_watch_arm_pi lives on main).

export const FM_BRANCH_DISPATCH_EVENT = "fm-branch-supervision:dispatch";

export type UnreadWakeScopeStatus = "safe" | "empty" | "unsafe";

export interface UnreadWakeScope {
  status: UnreadWakeScopeStatus;
  eligible: boolean;
  /** Exact project values touched by the currently eligible rows (context only). */
  projects: string[];
  /**
   * The exact durable-queue sequence numbers this scan proved safe for the
   * branch to drain and acknowledge right now (docs/watcher-continuity.md
   * "Per-actor acknowledgement" - the single owner of the consume contract
   * bin/fm-wake-drain.sh implements against this list). Empty whenever
   * `eligible` is false.
   */
  eligibleSeqs: string[];
  /**
   * The exact task ids the eligible signal/stale rows name (a signal row by
   * its status-log key, a stale row through the task metadata recording that
   * endpoint). The branch may report only these tasks while it handles the
   * wake; `fleet` or a task it merely remembers is refused (docs/
   * pi-supervision-branch.md "Components and their owners"). Empty for a
   * heartbeat, which is not scoped by task.
   */
  eligibleTasks: string[];
  /** Exact resolved task identity for each eligible queue row. */
  taskBySeq: Record<string, string>;
  /**
   * True only when this scan itself is untrustworthy: the queue or its
   * metadata could not be read, a line fails the structural tab-field check,
   * or an unresolvable signal/stale row was found. False whenever the scan
   * completed cleanly and simply found nothing (or nothing further) eligible
   * for the branch right now: status "unsafe" with corrupted false is the
   * ordinary "ordinary main-only content, nothing here for the branch" case,
   * not a fault, and callers should treat it as ordinary absence rather than
   * escalating. A main-owned check row is never a source of corruption in
   * either mode.
   */
  corrupted: boolean;
  /**
   * The exact "key" field of every decision-owned signal or stale row this
   * scan excluded. Signal rows are marked by bin/fm-watch.sh; stale rows are
   * decision-owned when their task has an open needs-decision or its current
   * declaration is captain-held. fm-primary-pi-watch.ts cross-references these
   * keys against the current trigger so its entire coalesced batch is forced
   * to main.
   */
  needsDecisionKeys: string[];
  /** Structurally valid rows whose current task identity cannot be resolved. */
  unresolvedRows: Array<{ seq: string; kind: "signal" | "stale"; key: string }>;
  /**
   * Exact check payloads whose captured iDA result identity was proved to
   * belong to this home's recorded remote-agent task. The watcher uses this
   * set to distinguish the one branch-owned check trigger from every other
   * check class, which remains main-owned.
   */
  eligibleIdaResults: Array<{ trigger: string; row: string; task: string }>;
  taskByWakeKey: Record<string, string>;
  /** Exact queued rows already claimed by MAIN; never branch candidates. */
  mainOwnedRows: Array<{ seq: string; kind: string; key: string; payload: string }>;
}

const EMPTY_SCOPE: UnreadWakeScope = {
  status: "empty",
  eligible: false,
  projects: [],
  eligibleSeqs: [],
  eligibleTasks: [],
  taskBySeq: {},
  corrupted: false,
  needsDecisionKeys: [],
  unresolvedRows: [],
  eligibleIdaResults: [],
  taskByWakeKey: {},
  mainOwnedRows: [],
};
const UNSAFE_SCOPE: UnreadWakeScope = {
  status: "unsafe",
  eligible: false,
  projects: [],
  eligibleSeqs: [],
  eligibleTasks: [],
  taskBySeq: {},
  corrupted: true,
  needsDecisionKeys: [],
  unresolvedRows: [],
  eligibleIdaResults: [],
  taskByWakeKey: {},
  mainOwnedRows: [],
};

// scopeForUnreadWake is the single owner of branch-eligibility classification
// (docs/pi-supervision-branch.md "Autonomy"; docs/watcher-continuity.md
// "Per-actor acknowledgement"). bin/fm-wake-drain.sh never reclassifies a row
// itself - it only consumes the exact sequence-number snapshot this function
// (via writeEligibleRowsSnapshot) hands it.
//
// The one branch-owned check class is a fully identity-bound task-scoped iDA
// process result. Merge-confirmation polls, Relay mentions, credential/auth
// failures, malformed iDA-looking rows, and every other check class never veto
// a scan in either mode. They are excluded from eligibleSeqs and left queued
// for main, which is woken for each on that check's own watcher cycle, so
// nothing starves by being left behind.
//
// A signal row whose payload is "needs-decision:"-prefixed, or a stale row
// for a task with an open needs-decision or a current captain-held declaration,
// gets the identical treatment: excluded from eligibleSeqs, never a scan veto,
// and forced to main on its own triggering close (fm-primary-pi-watch.ts's
// offerWakeToBranch). Heartbeat handling remains independent.
//
// That applies to a heartbeat review too, and it is the whole point: a
// heartbeat used to be deferred to main merely because some unrelated check
// row happened to be sitting unread, which put a routine fleet review in the
// captain's chat for a reason that had nothing to do with the fleet. A
// permanently main-owned row is not fleet context the branch is missing, so it
// no longer rides the heartbeat into main (docs/pi-supervision-branch.md
// "Heartbeat routing").
//
// A structurally valid signal/stale row whose task metadata has already been
// retired is main-only evidence, not corruption of every unrelated row in the
// scan. It remains durable and its own trigger stays on main. A row this repo's
// fm_wake_append could never have produced (an unknown kind, or a line that
// fails the structural tab-field check) still vetoes the whole scan - that is
// queue corruption, not an everyday mixed queue.
function statusLineVerb(line: string): string {
  const beforeColon = line.split(":", 1)[0].split("[", 1)[0].trim();
  const words = beforeColon.split(/\s+/);
  if (!words.some((word) => word.startsWith("corr="))) return beforeColon;
  return words.filter((word, index) => index === 0 || !/^corr=[0-9a-f]{16}$/i.test(word)).join(" ");
}

function decisionKey(line: string): string | null {
  const colon = line.indexOf(":");
  const beforeColon = colon < 0 ? line : line.slice(0, colon);
  const beforeMatch = beforeColon.match(/\[key=([^\]]*)\]/);
  const noteMatch = beforeMatch || colon < 0 ? null : line.slice(colon + 1).trimStart().match(/^\[key=([^\]]*)\]/);
  const key = (beforeMatch ?? noteMatch)?.[1] ?? "default";
  return /^[A-Za-z0-9._-]+$/.test(key) ? key : null;
}

function statusLineNote(line: string): string {
  const colon = line.indexOf(":");
  if (colon < 0) return line;
  const note = line.slice(colon + 1).trimStart();
  if (/\[key=[^\]]*\]/.test(line.slice(0, colon))) return note;
  const match = note.match(/^\[key=([A-Za-z0-9._-]+)\]/);
  return match ? note.slice(match[0].length).trimStart() : note;
}

interface StaleDecisionCacheEntry {
  version: string;
  config: string;
  decisionOwned: boolean;
}

const staleDecisionCache = new Map<string, StaleDecisionCacheEntry>();

function statusFileVersion(path: string): string | null {
  try {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) throw new Error("status path is a symbolic link");
    return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}

function privateRegularFile(path: string): boolean {
  try {
    const stat = lstatSync(path);
    return stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1 &&
      (stat.mode & 0o777) === 0o600 &&
      (typeof process.getuid !== "function" || stat.uid === process.getuid());
  } catch {
    return false;
  }
}

function parseUniqueFields(raw: string): Map<string, string> | null {
  const fields = new Map<string, string>();
  for (const line of raw.split(/\r?\n/)) {
    if (!line) continue;
    const split = line.indexOf("=");
    if (split < 1) return null;
    const key = line.slice(0, split);
    if (fields.has(key)) return null;
    fields.set(key, line.slice(split + 1));
  }
  return fields;
}

function stringField(value: unknown, key: string): string {
  if (!value || typeof value !== "object") return "";
  const candidate = (value as Record<string, unknown>)[key];
  return typeof candidate === "string" ? candidate : "";
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function nullableString(value: unknown, maxLength?: number): boolean {
  return value == null || (typeof value === "string" && (maxLength === undefined || value.length <= maxLength));
}

function validRemoteTaskState(value: unknown, task: string): boolean {
  const state = recordValue(value);
  if (!state) return false;
  const phases = new Set([
    "submission-not-started", "submission-unknown", "submitted", "running", "result-unavailable",
    "ambiguous", "terminal-success", "terminal-failure", "terminal-cancelled",
  ]);
  const waiters = new Set(["not-armed", "armed", "rearming", "interrupted", "terminal"]);
  const availability = new Set([null, "available", "zero", "unavailable", "error"]);
  return state.schema === "fm-remote-agent-task-state.v1" && state.task_id === task &&
    state.executor === "remote-agent" && state.provider === "ida" && state.task_type === "research" &&
    typeof state.phase === "string" && phases.has(state.phase) &&
    typeof state.revision === "number" && Number.isSafeInteger(state.revision) && state.revision >= 1 &&
    typeof state.instruction_file === "string" && state.instruction_file.length > 0 &&
    typeof state.instruction_sha256 === "string" && /^[0-9a-f]{64}$/.test(state.instruction_sha256) &&
    (!("bytedcli_version" in state) || typeof state.bytedcli_version === "string") &&
    nullableString(state.outcome) && nullableString(state.error_class) &&
    typeof state.waiter === "string" && waiters.has(state.waiter) &&
    (state.result_availability == null ||
      (typeof state.result_availability === "string" && availability.has(state.result_availability))) &&
    nullableString(state.result_path) &&
    nullableString(state.report_path) && recordValue(state.provider_state) !== null;
}

function validArtifactReference(value: unknown): boolean {
  if (value === null || value === undefined) return true;
  const artifact = recordValue(value);
  if (!artifact) return false;
  const keys = Object.keys(artifact).sort().join(",");
  return keys === "artifact_count,kind,part_count,part_kinds,readback,schema" &&
    artifact.schema === "fm-ida-artifact-reference.v1" && artifact.kind === "deep-research-final-answer" &&
    artifact.readback === "session-get" && Number.isSafeInteger(artifact.artifact_count) &&
    (artifact.artifact_count as number) >= 1 && Number.isSafeInteger(artifact.part_count) &&
    (artifact.part_count as number) >= 1 && Array.isArray(artifact.part_kinds) && artifact.part_kinds.length >= 1 &&
    artifact.part_kinds.every((kind) => kind === "file" || kind === "data");
}

function validIdaObservation(value: unknown, task: string, marker: string): boolean {
  const observation = recordValue(value);
  if (!observation) return false;
  const resultKind = "result_kind" in observation ? observation.result_kind : undefined;
  if (observation.schema !== "fm-ida-observation.v1" || observation.task_id !== task ||
    observation.provider !== "ida" || observation.region !== "sg" || observation.session_marker !== marker ||
    !["submission", "reconcile", "session"].includes(String(observation.kind)) ||
    typeof observation.terminal !== "boolean" || typeof observation.ambiguous !== "boolean" ||
    !(observation.session_id === null || (typeof observation.session_id === "string" && /^[0-9]+$/.test(observation.session_id))) ||
    !(observation.task_id_remote === null || (typeof observation.task_id_remote === "string" && observation.task_id_remote.length > 0)) ||
    !nullableString(observation.provider_status, 120) ||
    !["available", "zero", "unavailable", "error"].includes(String(observation.result_availability)) ||
    !nullableString(observation.answer) || !nullableString(observation.error_class, 120) ||
    !(resultKind === undefined || resultKind === null || resultKind === "text" || resultKind === "artifact") ||
    !validArtifactReference(observation.artifact_reference)) return false;
  if (resultKind === "text") {
    return typeof observation.answer === "string" && observation.answer.length > 0 && observation.artifact_reference == null;
  }
  if (resultKind === "artifact") return observation.answer === null && recordValue(observation.artifact_reference) !== null;
  return resultKind === undefined || (observation.answer === null && observation.artifact_reference === null);
}

function validIdaResultWake(
  state: string,
  key: string,
  payload: string,
): { task: string; trigger: string } | null {
  const match = payload.match(/^check: procevent ida (ida-([A-Za-z0-9][A-Za-z0-9._-]{0,58})) ([0-9]+)$/);
  if (!match) return null;
  const [, source, task, captureSeq] = match;
  if (key !== `procevent:${source}:${captureSeq}`) return null;

  const metaPath = `${state}/${task}.meta`;
  const remoteDir = `${state}/remote-tasks/${task}`;
  const remoteStatePath = `${remoteDir}/state.json`;
  const resultPath = `${state}/procevent-inbox/${source}.${captureSeq}.result`;
  const adapterPath = `${state}/procevent-inbox/${source}.${captureSeq}.adapter`;
  if (![metaPath, remoteStatePath, resultPath, adapterPath].every(privateRegularFile)) return null;

  try {
    const canonicalState = realpathSync(state);
    if (realpathSync(metaPath) !== `${canonicalState}/${task}.meta` ||
      realpathSync(remoteStatePath) !== `${canonicalState}/remote-tasks/${task}/state.json` ||
      realpathSync(resultPath) !== `${canonicalState}/procevent-inbox/${source}.${captureSeq}.result` ||
      realpathSync(adapterPath) !== `${canonicalState}/procevent-inbox/${source}.${captureSeq}.adapter`) return null;
    const meta = parseUniqueFields(readFileSync(metaPath, "utf8"));
    if (!meta || meta.get("kind") !== "scout" || meta.get("executor") !== "remote-agent" ||
      meta.get("provider") !== "ida" || meta.get("task_type") !== "research" ||
      meta.get("remote_state") !== remoteDir) return null;
    if (readFileSync(adapterPath, "utf8") !== "ida\n") return null;

    const remoteState = JSON.parse(readFileSync(remoteStatePath, "utf8")) as unknown;
    const observation = JSON.parse(readFileSync(resultPath, "utf8")) as unknown;
    if (!validRemoteTaskState(remoteState, task)) return null;

    const providerState = (remoteState as Record<string, unknown>).provider_state;
    const marker = stringField(providerState, "session_marker");
    if (!marker || !validIdaObservation(observation, task, marker)) return null;
    for (const [stateKey, observationKey] of [["session_id", "session_id"], ["task_id", "task_id_remote"]] as const) {
      const recorded = stringField(providerState, stateKey);
      const observed = stringField(observation, observationKey);
      if (recorded && observed && recorded !== observed) return null;
    }
    return { task, trigger: payload };
  } catch {
    return null;
  }
}

function hasOpenNeedsDecision(
  lines: readonly string[],
  resolveVerb: string,
  heldVerb: string,
  reservedPrefixes: readonly string[],
): boolean {
  const open = new Map<string, "needs-decision" | "blocked">();
  for (const line of lines) {
    const verb = statusLineVerb(line);
    if (!["needs-decision", "blocked", resolveVerb, heldVerb].includes(verb)) continue;
    const key = decisionKey(line);
    if (!key) continue;
    const note = statusLineNote(line);
    const reservedPrefix = reservedPrefixes.find((prefix) => key.startsWith(prefix));
    if (reservedPrefix && !(note.startsWith(reservedPrefix) && note.slice(reservedPrefix.length).includes(":"))) continue;
    if (verb === "needs-decision" || verb === "blocked") open.set(key, verb);
    else open.delete(key);
  }
  return [...open.values()].includes("needs-decision");
}

// Same record grammar as fm_wake_grant_rows_valid: a present claim is a
// nonempty set of distinct decimal rows. Absence means no MAIN claim; malformed
// or changing evidence fails closed. The locked publish remains the authority
// for claims that race this observational read.
function mainClaimRows(state: string): Set<string> {
  const path = `${state}/.main-eligible-rows`;
  let stat;
  try { stat = lstatSync(path); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return new Set();
    throw error;
  }
  if (!stat.isFile()) throw new Error("invalid MAIN claim file");
  const text = readFileSync(path, "utf8");
  const after = lstatSync(path);
  if (!after.isFile() || stat.dev !== after.dev || stat.ino !== after.ino ||
    stat.size !== after.size || stat.mtimeMs !== after.mtimeMs || stat.ctimeMs !== after.ctimeMs) {
    throw new Error("MAIN claim changed during read");
  }
  const rows = (text.endsWith("\n") ? text.slice(0, -1) : text).split("\n");
  if (rows.some((row) => !/^[0-9]+$/.test(row)) || new Set(rows).size !== rows.length) {
    throw new Error("invalid MAIN claim rows");
  }
  return new Set(rows);
}

// One shell/Python reader owns schema and generation validation. This adapter
// only batches existing records off the TUI thread; it never interprets JSON
// disposition files independently. Failure routes the affected tasks to main.
export async function lifecycleModesForWake(root: string, home: string, state: string): Promise<Record<string, string>> {
  let tasks: string[];
  try {
    const data = process.env.FM_DATA_OVERRIDE || `${home}/data`;
    tasks = readdirSync(state).filter((name) => name.endsWith(".meta"))
      .map((name) => name.slice(0, -5))
      .filter((task) => {
        try { lstatSync(`${data}/${task}/lifecycle.json`); return true; }
        catch (error) { return (error as NodeJS.ErrnoException).code !== "ENOENT"; }
      });
  } catch { return { "*": "unknown" }; }
  if (tasks.length === 0) return {};
  const failed = Object.fromEntries(tasks.map((task) => [task, "unknown"]));
  const result = await runCommandAsync("bash", [`${root}/bin/fm-task-state.sh`, "modes", JSON.stringify(tasks)], {
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state },
  });
  if (result.status !== 0) return failed;
  try {
    const modes = JSON.parse(result.stdout);
    if (!tasks.every((task) => ["open", "accepted", "archived", "unknown", "legacy"].includes(modes[task]))) return failed;
    return modes;
  } catch { return failed; }
}

export async function scopeForUnreadWakeWithLifecycle(
  root: string,
  home: string,
  state: string,
  heartbeat: boolean,
): Promise<{ modes: Record<string, string>; routineDecisionTasks: string[]; scope: UnreadWakeScope }> {
  const modes = await lifecycleModesForWake(root, home, state);
  const initial = scopeForUnreadWake(state, heartbeat, modes);
  const candidates = [...new Set(initial.needsDecisionKeys
    .map((key) => initial.taskByWakeKey[key] ?? initial.taskByWakeKey[key.replace(/^fm-/, "")])
    .filter((task): task is string => Boolean(task)))];
  const routineDecisionTasks: string[] = [];
  for (const task of candidates) {
    const result = await runCommandAsync("bash", [`${root}/bin/fm-task-state.sh`, "progress", task], {
      env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state,
        FM_DATA_OVERRIDE: process.env.FM_DATA_OVERRIDE || `${home}/data` },
    });
    if (result.status !== 0) continue;
    try {
      const progress = JSON.parse(result.stdout);
      if (progress.recorded && progress.task_state === "in_flight" && progress.remaining_gap && progress.next_step) {
        routineDecisionTasks.push(task);
      }
    } catch { /* An unreadable progress record remains MAIN-owned. */ }
  }
  return { modes, routineDecisionTasks,
    scope: scopeForUnreadWake(state, heartbeat, modes, new Set(routineDecisionTasks)) };
}

export function scopeForUnreadWake(state: string, heartbeat: boolean, lifecycleModes: Record<string, string> = {},
  routineDecisionTasks: ReadonlySet<string> = new Set()): UnreadWakeScope {
  let queue = "";
  try {
    queue = readFileSync(`${state}/.wake-queue`, "utf8");
  } catch {
    return UNSAFE_SCOPE;
  }

  let mainClaims: Set<string>;
  try { mainClaims = mainClaimRows(state); } catch { return UNSAFE_SCOPE; }

  const rows = queue.split(/\r?\n/).filter((line) => line.length > 0);
  if (rows.length === 0) return EMPTY_SCOPE;

  const projects = new Set<string>();
  const metadata = new Map<string, string>();
  // The task id behind each key a signal or stale row may carry: the task id
  // itself, or the endpoint its metadata records.
  const taskByKey = new Map<string, string>();
  const bind = (key: string, task: string, project: string) => {
    // An endpoint is opaque, including its colons. Multiple claims remain
    // unowned instead of depending on directory iteration order.
    if (taskByKey.has(key) && taskByKey.get(key) !== task) {
      taskByKey.set(key, "");
      metadata.set(key, "");
    } else {
      taskByKey.set(key, task);
      if (project) metadata.set(key, project);
    }
  };
  try {
    for (const name of readdirSync(state)) {
      if (!name.endsWith(".meta")) continue;
      const task = name.slice(0, -5);
      const path = `${state}/${name}`;
      const stat = lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 ||
          (typeof process.getuid === "function" && stat.uid !== process.getuid())) continue;
      const fields = readFileSync(path, "utf8").split(/\r?\n/);
      const projectFields = fields.filter((line) => line.startsWith("project="));
      const windows = fields.filter((line) => line.startsWith("window="));
      if (projectFields.length !== 1 || windows.length > 1) continue;
      const project = projectFields[0].slice(8);
      const window = windows[0]?.slice(7) ?? "";
      if (project) {
        bind(task, task, project);
        bind(`${task}.status`, task, "");
        bind(`${task}.turn-ended`, task, "");
        if (window) bind(window, task, project);
      }
    }
  } catch {
    return UNSAFE_SCOPE;
  }

  const mainOwnedRows: UnreadWakeScope["mainOwnedRows"] = [];
  const eligibleSeqs: string[] = [];
  const eligibleTasks = new Set<string>();
  const taskBySeq = new Map<string, string>();
  const needsDecisionKeys: string[] = [];
  const unresolvedRows: Array<{ seq: string; kind: "signal" | "stale"; key: string }> = [];
  const eligibleIdaResults: Array<{ trigger: string; row: string; task: string }> = [];
  const staleDecisionOwnership = new Map<string, boolean>();
  const resolveVerb = process.env.FM_CLASSIFY_RESOLVE_VERB || "resolved";
  const heldVerb = process.env.FM_CLASSIFY_CAPTAIN_HELD_VERB || "captain-held";
  const reservedPrefixes = (process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES || "pending-reply-")
    .split(/\s+/)
    .filter(Boolean);
  const decisionConfig = `${resolveVerb}\0${heldVerb}\0${reservedPrefixes.join("\0")}`;
  for (const line of rows) {
    const fields = line.split("\t");
    if (fields.length < 5 || !/^[0-9]+$/.test(fields[1])) return UNSAFE_SCOPE;
    const seq = fields[1];
    const kind = fields[2];
    const key = fields[3];
    // Validate even excluded rows: a claim cannot hide queue corruption.
    if (!["heartbeat", "check", "signal", "stale"].includes(kind)) return UNSAFE_SCOPE;
    if (mainClaims.has(seq)) {
      mainOwnedRows.push({ seq, kind, key, payload: fields.slice(4).join("\t") });
      continue;
    }
    if (kind === "heartbeat") {
      if (heartbeat) eligibleSeqs.push(seq);
      continue;
    }
    if (kind === "check") {
      // The sole branch-owned check class is a fully identity-bound iDA
      // process result. Everything else remains main-owned and excluded from
      // the claim without vetoing unrelated eligible rows.
      const idaResult = fields.length === 5 ? validIdaResultWake(state, key, fields[4] ?? "") : null;
      if (idaResult) {
        eligibleSeqs.push(seq);
        eligibleTasks.add(idaResult.task);
        taskBySeq.set(seq, idaResult.task);
        eligibleIdaResults.push({ trigger: idaResult.trigger, row: seq, task: idaResult.task });
      }
      continue;
    }
    let project = "";
    let task = "";
    if (kind === "signal") {
      const payload = fields[4] ?? "";
      if (/^needs-decision:/.test(payload)) {
        // Main-owned exactly like a check-kind row above: a needs-decision
        // status append surfaced through the actionable signal path is
        // excluded from what the branch may claim without vetoing the scan
        // (docs/pi-supervision-branch.md "Autonomy").
        const decisionTask = taskByKey.get(key) ?? taskByKey.get(key.replace(/\.(?:status|turn-ended)$/, "")) ?? "";
        if (!routineDecisionTasks.has(decisionTask)) {
          needsDecisionKeys.push(key);
          continue;
        }
      }
      task = key.replace(/\.(?:status|turn-ended)$/, "");
      project = metadata.get(task) ?? "";
    } else if (kind === "stale") {
      task = taskByKey.get(key) ?? taskByKey.get(key.replace(/^fm-/, "")) ?? "";
      project = metadata.get(key) ?? metadata.get(key.replace(/^fm-/, "")) ?? "";
      const mode = lifecycleModes[task] ?? lifecycleModes["*"] ?? "legacy";
      if (mode !== "open" && mode !== "legacy") {
        // The row remains durable and main handles it as disposition/cleanup,
        // never as a branch recovery. Late signal/provider results still flow.
        needsDecisionKeys.push(key);
        continue;
      }
      if (task) {
        const statusPath = `${state}/${task}.status`;
        if (!staleDecisionOwnership.has(statusPath)) {
          let version: string | null;
          try {
            version = statusFileVersion(statusPath);
          } catch {
            return UNSAFE_SCOPE;
          }
          let decisionOwned = false;
          if (version) {
            const cached = staleDecisionCache.get(statusPath);
            if (cached?.version === version && cached.config === decisionConfig) {
              decisionOwned = cached.decisionOwned;
            } else {
              let statusLines: string[];
              try {
                statusLines = readFileSync(statusPath, "utf8").split(/\r?\n/).filter((line) => /\S/.test(line));
                if (statusFileVersion(statusPath) !== version) return UNSAFE_SCOPE;
              } catch {
                return UNSAFE_SCOPE;
              }
              decisionOwned = hasOpenNeedsDecision(statusLines, resolveVerb, heldVerb, reservedPrefixes) ||
                statusLineVerb(statusLines.at(-1) ?? "") === heldVerb;
              staleDecisionCache.set(statusPath, { version, config: decisionConfig, decisionOwned });
              if (staleDecisionCache.size > 512) {
                staleDecisionCache.delete(staleDecisionCache.keys().next().value!);
              }
            }
          } else {
            staleDecisionCache.delete(statusPath);
          }
          staleDecisionOwnership.set(statusPath, decisionOwned);
        }
        if (staleDecisionOwnership.get(statusPath) && !routineDecisionTasks.has(task)) {
          needsDecisionKeys.push(key);
          continue;
        }
      }
    } else {
      // A kind fm_wake_append never emits: structural corruption, not an
      // ordinary main-only row.
      return UNSAFE_SCOPE;
    }
    if (!project || !task) {
      unresolvedRows.push({ seq, kind, key });
      continue;
    }
    projects.add(project);
    eligibleTasks.add(task);
    taskBySeq.set(seq, task);
    eligibleSeqs.push(seq);
  }
  const eligible = eligibleSeqs.length > 0;
  // Reached only after every row passed classification without a veto. A scan
  // that ends up ineligible simply found nothing the branch may claim - a
  // queue of purely main-only content, not a fault. (Before check rows stopped
  // vetoing a heartbeat, this point was unreachable for a heartbeat with an
  // empty eligible set, so reading eligibility off the claim set rather than
  // off the heartbeat flag changes no pre-existing outcome and keeps a
  // heartbeat from being offered with nothing to hand over.)
  return {
    status: eligible ? "safe" : "unsafe",
    eligible,
    projects: [...projects],
    eligibleSeqs,
    eligibleTasks: [...eligibleTasks],
    taskBySeq: Object.fromEntries(taskBySeq),
    corrupted: false,
    needsDecisionKeys,
    unresolvedRows,
    eligibleIdaResults,
    taskByWakeKey: Object.fromEntries(taskByKey),
    mainOwnedRows,
  };
}

export type WakeTriggerDisposition = {
  eligible: boolean;
  reason: "eligible" | "no-eligible-rows" | "check-main-only" | "decision-owned" | "unresolved-task" | "corrupt-queue" | "main-owned-trigger";
};

function triggerKeys(message: string): string[] {
  if (/^signal:/.test(message)) {
    return message.slice("signal:".length).split(/\s+/).filter(Boolean).map((path) => path.split("/").pop() ?? path);
  }
  if (/^stale:/.test(message)) return [message.slice("stale:".length).trim().split(/\s+/, 1)[0]].filter(Boolean);
  return [];
}

function taskIdentity(scope: UnreadWakeScope, key: string): string {
  return scope.taskByWakeKey[key] ?? scope.taskByWakeKey[key.replace(/^fm-/, "")] ?? key;
}

/** Shared watcher/admission verdict for the exact actionable close. */
export function dispositionForWakeTrigger(message: string, scope: UnreadWakeScope): WakeTriggerDisposition {
  if (scope.corrupted) return { eligible: false, reason: "corrupt-queue" };
  const keys = triggerKeys(message);
  // Watcher messages do not carry seqs. If a signal/stale task alias can refer
  // to a MAIN claim, conservatively keep that whole trigger on MAIN; unrelated
  // new tasks remain eligible. Check payloads retain their exact identity.
  if (scope.mainOwnedRows.some((row) =>
    (["signal", "stale"].includes(row.kind) && keys.some((key) => taskIdentity(scope, key) === taskIdentity(scope, row.key))) ||
    (row.kind === "check" && message === row.payload) ||
    (row.kind === "heartbeat" && /^heartbeat($|:)/.test(message)))) {
    return { eligible: false, reason: "main-owned-trigger" };
  }
  const unresolved = new Set(scope.unresolvedRows.map((row) => row.key));
  if (keys.some((key) => unresolved.has(key) || unresolved.has(key.replace(/^fm-/, "")))) {
    return { eligible: false, reason: "unresolved-task" };
  }
  const decisionTasks = new Set(scope.needsDecisionKeys.map((key) => taskIdentity(scope, key)));
  if (keys.some((key) => decisionTasks.has(taskIdentity(scope, key)))) {
    return { eligible: false, reason: "decision-owned" };
  }
  if (/^check:/.test(message)) {
    const matched = scope.eligibleIdaResults.some((result) => result.trigger === message);
    if (!matched) return { eligible: false, reason: "check-main-only" };
  }
  return scope.eligible
    ? { eligible: true, reason: "eligible" }
    : { eligible: false, reason: "no-eligible-rows" };
}

export const BRANCH_ROUTING_TRACE_FILE = ".supervision-routing.jsonl";
// Observational events only: subscribers cannot acquire or settle an offer.
export const BRANCH_ACTIVITY_EVENT = "firstmate:branch-activity";
export const BRANCH_HEALTH_EVENT = "firstmate:branch-health";
export const BRANCH_HEALTH_REQUEST = "firstmate:branch-health-request";
let traceWriteId = 0;

export type BranchRoutingTrace = {
  token: string;
  actor: "watcher" | "branch";
  stage: string;
  reason: string;
  trigger?: string;
  seqs?: readonly string[];
  excluded?: ReadonlyArray<{ seq: string; reason: "decision-owned" | "unresolved-task" }>;
  generation?: number | string;
  selectionRevision?: number;
  elapsedMs?: number;
};

/** Best-effort, bounded, privacy-safe diagnostics; never an ownership input. */
export function appendBranchRoutingTrace(state: string, event: BranchRoutingTrace,
  events?: { emit(channel: string, data: unknown): void }): void {
  try { events?.emit(BRANCH_ACTIVITY_EVENT, { ...event, time: new Date().toISOString() }); } catch {}
  try {
    mkdirSync(state, { recursive: true });
    const path = `${state}/${BRANCH_ROUTING_TRACE_FILE}`;
    let lines: string[] = [];
    try {
      lines = readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
    } catch {}
    const safe = {
      time: new Date().toISOString(),
      token: /^[A-Za-z0-9._:-]{1,96}$/.test(event.token) ? event.token : "invalid",
      actor: event.actor,
      stage: event.stage.slice(0, 48),
      reason: event.reason.slice(0, 80),
      ...(event.trigger ? { trigger: event.trigger.slice(0, 24) } : {}),
      ...(event.seqs ? { seqs: event.seqs.filter((seq) => /^[0-9]+$/.test(seq)).slice(0, 64) } : {}),
      ...(event.excluded ? { excluded: event.excluded.filter((row) => /^[0-9]+$/.test(row.seq)).slice(0, 64) } : {}),
      ...(event.generation !== undefined ? { generation: event.generation } : {}),
      ...(event.selectionRevision !== undefined ? { selectionRevision: event.selectionRevision } : {}),
      ...(event.elapsedMs !== undefined ? { elapsedMs: Math.max(0, Math.floor(event.elapsedMs)) } : {}),
    };
    lines.push(JSON.stringify(safe));
    lines = lines.slice(-200);
    while (Buffer.byteLength(lines.join("\n"), "utf8") > 256 * 1024 && lines.length > 1) lines.shift();
    const temporary = `${path}.tmp-${process.pid}-${++traceWriteId}`;
    try {
      writeFileSync(temporary, `${lines.join("\n")}\n`, { mode: 0o600 });
      renameSync(temporary, path);
    } catch (error) {
      try { unlinkSync(temporary); } catch {}
      throw error;
    }
  } catch {
    // Diagnostics are intentionally outside the routing authority path.
  }
}

// The exact state-relative filename bin/fm-wake-drain.sh reads for a
// FM_SUPERVISION_ACTOR=branch drain or ack (its header is the single owner of
// the consume-side contract). Written atomically, immediately before every
// branch prompt, by writeEligibleRowsSnapshot below.
export const BRANCH_ELIGIBLE_ROWS_FILE = ".branch-eligible-rows";

// Read the live grant rows without taking the queue lock. Every writer
// replaces or removes the file atomically under that lock, so an unlocked
// read still observes one whole consistent file; null (absent or
// structurally invalid) means no live grant and must never be mistaken for
// an empty one. While the branch's own unsettled work exists, the file names
// exactly the rows that in-flight turn still owns and will drain:
// publication verified them against the queue and this generation's owner
// record, and a branch acknowledgement shrinks the file as it consumes rows
// (bin/fm-wake-drain.sh consume_actor_rows_locked).
export function readLiveEligibleRows(state: string): string[] | null {
  let raw: string;
  try {
    raw = readFileSync(`${state}/${BRANCH_ELIGIBLE_ROWS_FILE}`, "utf8");
  } catch {
    return null;
  }
  const seqs = raw.split(/\r?\n/).filter((line) => line.length > 0);
  if (seqs.length === 0 || seqs.some((seq) => !/^[0-9]+$/.test(seq))) return null;
  return seqs;
}

// Atomically publish the exact row set a branch turn may drain and
// acknowledge. One sequence number per line - an opaque handoff, never
// reclassified by the consumer. A main-owned result means the competing main
// turn won the queue-lock claim and already owns presentation; error means no
// actor acquired the requested rows.
export type EligibleRowsSnapshotResult = "published" | "main-owned" | "error";

// Awaited rather than synchronous because every caller runs on the Pi thread
// that draws the captain's TUI (lib/fm-async-exec.ts). The grant script itself
// is unchanged, and so is each result: a null status still means the script
// could not be run at all.
async function runGrantScript(
  state: string,
  grantScript: string,
  args: readonly string[],
): Promise<number | null> {
  const result = await runCommandAsync("bash", [grantScript, ...args], {
    env: {
      ...process.env,
      FM_STATE_OVERRIDE: state,
      FM_WAKE_QUEUE: `${state}/.wake-queue`,
      FM_WAKE_QUEUE_LOCK: `${state}/.wake-queue.lock`,
    },
  });
  return result.status;
}

export async function activateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["activate", String(ownerPid), generation])) === 0;
}

export async function writeEligibleRowsSnapshot(
  state: string,
  seqs: readonly string[],
  grantScript: string,
  generation: string,
): Promise<EligibleRowsSnapshotResult> {
  if (seqs.length === 0 || seqs.some((seq) => !/^[0-9]+$/.test(seq))) return "error";
  const status = await runGrantScript(state, grantScript, ["publish", generation, ...seqs]);
  if (status === 0) return "published";
  if (status === 3) return "main-owned";
  return "error";
}

export async function releaseEligibleRowsSnapshot(
  state: string,
  grantScript: string,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["release", generation])) === 0;
}

export async function deactivateEligibleRowsOwner(
  state: string,
  grantScript: string,
  ownerPid: number,
  generation: string,
): Promise<boolean> {
  return (await runGrantScript(state, grantScript, ["deactivate", String(ownerPid), generation])) === 0;
}

export interface BranchDispatchOffer {
  /** Correlation id shared by watcher classification, branch handling and fallback. */
  token: string;
  /** The watcher's actionable close message (the wake reason line(s)). */
  message: string;
  /**
   * Exact project values from the unread task metadata this wake will drain.
   * Empty means the wake is fleet-wide or could not be scoped safely.
   */
  projects: readonly string[];
  /** True when the watcher classified this wake as a fleet-wide heartbeat scan. */
  heartbeat: boolean;
  /** True only when at least one currently unread row is safe for branch handling. */
  eligible: boolean;
  /** Exact iDA-result queue rows that caused this check trigger, if any. */
  idaResultRows: readonly string[];
  /** Admission-time identities rechecked after asynchronous queueing. */
  eligibleSeqs: readonly string[];
  eligibleTasks: readonly string[];
  taskBySeq: Readonly<Record<string, string>>;
  /** Fixed decline category supplied synchronously by the branch listener. */
  declineReason: string;
  /** Set by accept(); read by the watcher after emit returns. */
  accepted: boolean;
  settlement: Promise<void>;
  accept(settlement?: Promise<void>): void;
  decline(reason: string): void;
}

export function createBranchDispatchOffer(
  message: string,
  projects: readonly string[] = [],
  heartbeat = false,
  eligible = false,
  idaResultRows: readonly string[] = [],
  token = `offer-${process.pid}-${Date.now()}`,
  eligibleSeqs: readonly string[] = [],
  eligibleTasks: readonly string[] = [],
  taskBySeq: Readonly<Record<string, string>> = {},
): BranchDispatchOffer {
  const offer: BranchDispatchOffer = {
    token,
    message,
    projects: [...projects],
    heartbeat,
    eligible,
    idaResultRows: [...idaResultRows],
    eligibleSeqs: [...eligibleSeqs],
    eligibleTasks: [...eligibleTasks],
    taskBySeq: { ...taskBySeq },
    declineReason: "no-listener",
    accepted: false,
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.declineReason = "";
      offer.settlement = settlement;
    },
    decline(reason) {
      if (!offer.accepted) offer.declineReason = reason;
    },
  };
  return offer;
}

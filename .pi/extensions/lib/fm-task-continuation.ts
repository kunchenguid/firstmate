// Live-Pi consumer of the canonical task assessment owner. Never executes an
// action: main coordinates, and the existing executor/lease/inbox owners act.
import { createHash, randomUUID } from "node:crypto";
import { closeSync, existsSync, lstatSync, openSync, readSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { runCommandAsync } from "./fm-async-exec.ts";
import { registerFirstmateTool } from "./fm-native-contract.ts";
import { encodeFirstmateOperationalInputWith } from "./fm-operational-input.ts";

type Observation = { task_id: string; state: string; reason: string; key: string; revision?: number; delegated?: boolean };
type Reconciliation = { task_id: string; reason: string; key: string };
type OwnershipDeferral = { task_id: string; reason: string; key: string };
type InputReceipt = { id: string; text: string; task?: string; answer?: string };
type Admission = { content: string; admissions: string[]; escalations: { id: string; task: string; reason: string; recovery?: boolean; reconciliation?: boolean }[];
  canNotify: () => boolean; canContinue: () => boolean };
type InputPacing = { key: string; attempts: number; after: number; reserved?: string; escalatedAt?: number;
  recoveryAttempts?: number; recoveryAfter?: number; recoveryReserved?: string };
const INPUT_ENTRY = "fm-continuation-input";
const PACING_ENTRY = "fm-continuation-input-pacing";
const RECEIPT_ENTRY = "fm-continuation-receipt";
const MESSAGE = "fm-task-continuation";
const ESCALATION = "fm-task-continuation-escalation";
const INTERVAL_MS = 30_000;
const ATTEMPTS = 2;
const BATCH = 8;
const atom = (s: string) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/.test(s);

function temporaryOwnershipRefusal(error: unknown, task: string): string | undefined {
  const reason = String(error instanceof Error ? error.message : error).trim();
  const prefix = reason.startsWith("error: ") ? reason.slice(7) : reason;
  const action = `goal reconciliation refused - task '${task}'`;
  if (prefix === `${action} has a pending short-operation receipt` ||
      prefix === `${action} acquired a pending short-operation receipt while waiting` ||
      ["main", "branch", "short"].some((actor) => prefix ===
        `${action} is leased to the ${actor} supervision actor (state/.lease-${task}); retry after that actor releases it`)) return prefix;
}

// The existing heartbeat owner accepts and starts a bounded public readback.
// Its receipt permits only logical-run release, not semantic task completion.
export type ContinuationReceiver = {
  generation: string; sessionId: string; sessionFile: string; recheckMs: number;
  current: () => boolean; canNotify: () => boolean; canContinue: () => boolean;
};
export type ContinuationReadbackOffer = {
  ctx: ExtensionContext; accept: (receiver: ContinuationReceiver) => void;
};

export type TaskContinuationOffer = {
  task: string; admission: string; observation: Observation; record: Record<string, any>;
  delivered: (proof: { sessionFile: string; entryId: string; generation: number }) => void;
  settled: () => void;
};

export function installTaskContinuation(pi: ExtensionAPI, options: {
  root: string; home: string; state: string; owns: () => boolean;
  offer?: (offer: TaskContinuationOffer) => boolean;
}) {
  const { root, home, state, owns } = options;
  const data = process.env.FM_DATA_OVERRIDE || join(home, "data");
  const inputs = new Map<string, InputReceipt>();
  // Unrouted input pacing is session-owned. Task admission and semantic truth
  // remain in the canonical lifecycle owner, independent of this runtime.
  const pacing = new Map<string, InputPacing>();
  const submitted = new Set<string>();
  const delivered = new Map<string, number>();
  let generation = 0;
  let checking: Promise<Admission | undefined> | null = null;
  let context: ExtensionContext | undefined;
  let cursor = 0;
  let inputCursor = 0;
  let scanScope: string[] = [];

  async function command(args: string[]) {
    const epoch = generation;
    if (!owns()) throw new Error("this session does not own the fleet lock");
    const result = await runCommandAsync("bash", [join(root, "bin/fm-task-state.sh"), ...args], {
      env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state, FM_DATA_OVERRIDE: data,
        FM_SUPERVISION_ACTOR: "main" }, maxBuffer: 1024 * 1024,
    });
    if (epoch !== generation || !owns()) throw new Error("continuation generation changed");
    if (result.status !== 0) throw new Error(result.stderr.trim() || "lifecycle operation failed");
    return JSON.parse(result.stdout);
  }

  async function enroll(task: string) {
    if (!atom(task)) throw new Error("invalid task identity");
    const retained = await command(["lifecycle", task]);
    return retained ?? command(["enroll", task]);
  }

  // Durable presentation may advance after enrollment even when a continuation
  // is pending: subsequent checks read lifecycle, never the presentation cursor.
  async function preserve(tasks: string[]) {
    for (const task of new Set(tasks)) {
      if (task === "fleet") continue;
      if (!atom(task)) throw new Error("unresolved outcome task identity");
      if (existsSync(join(data, task, "brief.md"))) {
        await enroll(task);
      }
      // Legacy non-task outcome labels have no execution contract to invent.
    }
  }

  function capture(text: string, key?: string): string {
    if (!owns()) return "";
    const id = key || randomUUID();
    if (!inputs.has(id)) {
      const receipt = { id, text };
      pi.appendEntry(INPUT_ENTRY, receipt);
      inputs.set(id, receipt);
    }
    return id;
  }

  function instruction(lines: string[]): string {
    return "Live task continuation obligations (presentation acknowledgements do not close these):\n" +
      lines.join("\n") + "\nUse fm_task_continuation to inspect/enroll and reconcile through bin/fm-task-state.sh. " +
      "For each input receipt, route every requested task to its durable brief with action=route (task), " +
      "or record a substantive informational answer with action=answer (answer). " +
      "Main coordinates and judges acceptance; executors perform the operation chain. " +
      "Observe exact handled inbox receipt/current state; queued handoffs stay pending and use only their existing retry id. " +
      "Uncertain effects require readback, never blind replay. Genuine blockers need owner, dependency, " +
      "bound release evidence, deadline and recovery trigger. Do not revive archived work or bypass authority.";
  }

  function deferOwnership(item: OwnershipDeferral) {
    const id = `ownership:${item.task_id}`;
    let pace = pacing.get(id);
    if (!pace || pace.key !== item.key) pace = { key: item.key, attempts: 0, after: 0 };
    pace.attempts = Math.min(Number.MAX_SAFE_INTEGER, pace.attempts + 1);
    pace.after = Date.now() + Math.min(900_000, INTERVAL_MS * 2 ** Math.min(pace.attempts - 1, 5));
    pacing.set(id, pace);
    pi.appendEntry(PACING_ENTRY, { id, ...pace });
  }

  function clearOwnershipDeferral(task: string) {
    const id = `ownership:${task}`;
    if (!pacing.get(id)?.key) return;
    pacing.delete(id);
    pi.appendEntry(PACING_ENTRY, { id, key: "", attempts: 0, after: 0 });
  }

  async function collect(): Promise<{ observations: Observation[]; reconciliations: Reconciliation[];
    deferrals: OwnershipDeferral[] }> {
    const epoch = generation;
    const observations: Observation[] = [];
    const reconciliations: Reconciliation[] = [];
    const deferrals: OwnershipDeferral[] = [];
    const unrouted = [...inputs.values()].filter((value) => !value.task && !value.answer);
    for (let i = 0; i < Math.min(BATCH, unrouted.length); i++) {
      const value = unrouted[(inputCursor + i) % unrouted.length];
      observations.push({ task_id: `input:${value.id}`,
        state: "pending", reason: value.text.slice(0, 1200), key: value.id });
    }
    inputCursor = unrouted.length ? (inputCursor + BATCH) % unrouted.length : 0;
    const ids = existsSync(data) ? readdirSync(data).filter((id) => atom(id) &&
      existsSync(join(data, id, "lifecycle.json"))).sort() : [];
    scanScope = ids;
    for (let i = 0; i < Math.min(BATCH, ids.length); i++) {
      const id = ids[(cursor + i) % ids.length];
      const ownership = pacing.get(`ownership:${id}`);
      if (ownership?.key && Date.now() < ownership.after) continue;
      try {
        if (lstatSync(join(data, id)).isSymbolicLink()) throw new Error("unsafe task directory");
        observations.push(await command(["observe", id]));
      } catch (error) {
        if (epoch !== generation || !owns()) throw error;
        const reason = String(error instanceof Error ? error.message : error).slice(0, 1200);
        const key = createHash("sha256").update(`${id}\0${reason}`).digest("hex");
        const temporary = temporaryOwnershipRefusal(error, id);
        if (temporary) deferrals.push({ task_id: id, reason: temporary, key });
        else reconciliations.push({ task_id: id, reason, key });
      }
    }
    cursor = ids.length ? (cursor + BATCH) % ids.length : 0;
    return { observations, reconciliations, deferrals };
  }

  function readDelivery(entry: { customType?: string; details?: unknown; timestamp?: string | number }) {
    if (entry.customType !== MESSAGE && entry.customType !== ESCALATION && entry.customType !== "fm-continuation-branch-delivery") return;
    const ids = (entry.details as { admissions?: unknown })?.admissions;
    const at = typeof entry.timestamp === "number" ? entry.timestamp : Date.parse(entry.timestamp || "");
    if (!Array.isArray(ids) || !Number.isFinite(at)) return;
    for (const id of ids) if (typeof id === "string") delivered.set(id, at);
  }

  async function receive(ctx: ExtensionContext, owner: ContinuationReceiver): Promise<Admission | undefined> {
    const epoch = generation;
    const current = () => epoch === generation && owns() && owner.current();
    if (!current()) throw new Error("readback receiver generation changed");
    const started = Date.now();
    // The receiver has actually begun and executed readback before this receipt.
    const { observations, reconciliations, deferrals } = await collect();
    if (!current()) throw new Error("readback receiver generation changed");
    const pending = observations.filter((item) => !["accepted", "archived", "running", "blocked"].includes(item.state));
    if (!scanScope.length && !pending.length && !reconciliations.length && !deferrals.length) return;
    // Boundary drafts are persisted without message_end. Read the actual
    // session branch before acknowledging their reserved admission.
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom_message") readDelivery(entry);
      if (entry.type === "custom" && entry.customType === "fm-continuation-branch-delivery") {
        readDelivery({ customType: entry.customType, details: entry.data, timestamp: entry.timestamp });
      }
    }
    const receipt = {
      owner: "fm-periodic-stow", generation: owner.generation, session_id: owner.sessionId,
      pid: process.pid, started_at_ms: started,
      recheck_at_ms: Date.now() + Math.max(30_000, owner.recheckMs * Math.max(1, Math.ceil(scanScope.length / BATCH))),
      scan_scope: scanScope, next_cursor: cursor,
      recovery_trigger: "existing-heartbeat-clock: readback and persistent paced recovery until verified continuation; effects use existing executor/handoff owners",
      observations: pending.map(({ task_id, key, revision }) => ({ task_id, key, revision })),
      delivered_admissions: Object.fromEntries(pending.flatMap((item) =>
        [`n.${item.key}.1`, `n.${item.key}.2`, `e.${item.key}`,
          ...[...delivered.keys()].filter((id) => id.startsWith(`r.${item.key}.`))
            .sort((a, b) => Number(b.split(".").at(-1)) - Number(a.split(".").at(-1))).slice(0, 1)].flatMap((id) => {
        return delivered.has(id) ? [[id, delivered.get(id)]] : [];
      }))),
    };
    const offset = lstatSync(owner.sessionFile).size;
    pi.appendEntry(RECEIPT_ENTRY, receipt);
    const length = lstatSync(owner.sessionFile).size - offset;
    if (length <= 0 || length > 32768) throw new Error("native readback receipt was not durably appended");
    const fd = openSync(owner.sessionFile, "r");
    const raw = Buffer.alloc(length);
    try { if (readSync(fd, raw, 0, length, offset) !== length) throw new Error("short native receipt readback"); }
    finally { closeSync(fd); }
    const entry = JSON.parse(raw.toString("utf8"));
    if (entry.customType !== RECEIPT_ENTRY || entry.data?.generation !== owner.generation) throw new Error("native receipt identity mismatch");
    const proof = { session_file: owner.sessionFile, entry_id: entry.id, offset, length,
      sha256: createHash("sha256").update(raw).digest("hex") };
    const proofFile = join(data, `.continuation-${randomUUID()}.json`);
    writeFileSync(proofFile, JSON.stringify(proof), { mode: 0o600, flag: "wx" });
    const lines: string[] = [];
    const admissions: string[] = [];
    const escalations: Admission["escalations"] = [];
    try {
      for (const item of deferrals) deferOwnership(item);
      for (const item of reconciliations) {
        const paceId = `reconcile:${item.task_id}`;
        let pace = pacing.get(paceId);
        if (!pace || pace.key !== item.key) pace = { key: item.key, attempts: ATTEMPTS, after: 0 };
        const id = `q.${item.key}`;
        pace.escalatedAt ??= delivered.get(id);
        if (pace.escalatedAt === undefined && !submitted.has(id)) {
          escalations.push({ id, task: item.task_id,
            reason: `lifecycle observation refused; explicit reconciliation required: ${item.reason}`, reconciliation: true });
        } else if (pace.escalatedAt !== undefined) {
          pace.recoveryAttempts ??= 0;
          pace.recoveryAfter ??= pace.escalatedAt + 60_000;
          const at = pace.recoveryReserved ? delivered.get(pace.recoveryReserved) : undefined;
          if (at !== undefined) {
            pace.recoveryReserved = undefined;
            pace.recoveryAfter = Math.max(pace.recoveryAfter, at + Math.min(900_000, 60_000 * 2 ** Math.min(pace.recoveryAttempts, 4)));
          }
          if (!pace.recoveryReserved && Date.now() >= pace.recoveryAfter) {
            if (pace.recoveryAttempts >= Number.MAX_SAFE_INTEGER) throw new Error("reconciliation recovery counter exhausted");
            pace.recoveryReserved = `r.${item.key}.${++pace.recoveryAttempts}`;
          }
          if (pace.recoveryReserved && !submitted.has(pace.recoveryReserved)) {
            escalations.push({ id: pace.recoveryReserved, task: item.task_id,
              reason: `lifecycle observation still refuses explicit reconciliation: ${item.reason}`,
              recovery: true, reconciliation: true });
          }
        }
        pacing.set(paceId, pace);
        pi.appendEntry(PACING_ENTRY, { id: paceId, ...pace });
      }
      for (const item of pending) {
        if (!current()) throw new Error("readback receiver generation changed");
        let admission: string | undefined;
        if (item.task_id.startsWith("input:")) {
          // Unrouted input is session-owned; tasks use only canonical CAS below.
          let pace = pacing.get(item.task_id);
          if (!pace || pace.key !== item.key) pace = { key: item.key, attempts: 0, after: 0 };
          const at = pace.reserved ? delivered.get(pace.reserved) : undefined;
          if (at !== undefined) {
            pace.reserved = undefined;
            pace.after = Math.max(pace.after, at + INTERVAL_MS * 2 ** (pace.attempts - 1));
          }
          if (!pace.reserved && pace.attempts < ATTEMPTS && Date.now() >= pace.after) {
            pace.attempts++;
            pace.after = Date.now() + INTERVAL_MS * 2 ** (pace.attempts - 1);
            pace.reserved = `input.${item.key}.${pace.attempts}`;
          }
          if (!pace.reserved && pace.attempts === ATTEMPTS) {
            const id = `e.${item.key}`;
            pace.escalatedAt ??= delivered.get(id);
            if (pace.escalatedAt === undefined && !submitted.has(id)) {
              escalations.push({ id, task: item.task_id, reason: "input has not been routed to a task or substantively answered" });
            } else if (pace.escalatedAt !== undefined) {
              pace.recoveryAttempts ??= 0;
              pace.recoveryAfter ??= pace.escalatedAt + 60_000;
              const at = pace.recoveryReserved ? delivered.get(pace.recoveryReserved) : undefined;
              if (at !== undefined) {
                pace.recoveryReserved = undefined;
                pace.recoveryAfter = Math.max(pace.recoveryAfter, at + Math.min(900_000, 60_000 * 2 ** Math.min(pace.recoveryAttempts, 4)));
              }
              if (!pace.recoveryReserved && Date.now() >= pace.recoveryAfter) {
                if (pace.recoveryAttempts >= Number.MAX_SAFE_INTEGER) throw new Error("input recovery counter exhausted");
                pace.recoveryReserved = `r.${item.key}.${++pace.recoveryAttempts}`;
              }
              if (pace.recoveryReserved && !submitted.has(pace.recoveryReserved)) {
                escalations.push({ id: pace.recoveryReserved, task: item.task_id,
                  reason: "input remains unrouted after exhausted coordination", recovery: true });
              }
            }
          }
          pacing.set(item.task_id, pace);
          pi.appendEntry(PACING_ENTRY, { id: item.task_id, ...pace });
          admission = pace.reserved;
        } else {
          try {
            const coordinated = await command(["coordinate", item.task_id, "--expected-revision", String(item.revision), "--record", proofFile]);
            clearOwnershipDeferral(item.task_id);
            // Read the canonical receiver back before releasing this logical run.
            const retained = await command(["lifecycle", item.task_id]);
            if (retained?.coordination?.receipt?.entry_id !== entry.id ||
                retained.coordination.receiver.generation !== owner.generation) throw new Error("coordinator receipt readback changed");
            admission = coordinated.admission;
            if (admission && item.delegated && !submitted.has(admission) && !delivered.has(admission) && options.offer) {
              const id = admission;
              if (options.offer({ task: item.task_id, admission: id, observation: item, record: retained,
                delivered(proof) {
                  if (!current()) return;
                  pi.appendEntry("fm-continuation-branch-delivery", { admissions: [id], ...proof });
                  delivered.set(id, Date.now());
                },
                settled() { submitted.delete(id); },
              })) {
                submitted.add(id);
                admission = undefined;
              }
            } else if (admission && submitted.has(admission)) {
              admission = undefined;
            }
            if (coordinated.escalation && !submitted.has(coordinated.escalation) && !delivered.has(coordinated.escalation)) {
              escalations.push({ id: coordinated.escalation, task: item.task_id, reason: item.reason });
            }
            if (coordinated.recovery && !submitted.has(coordinated.recovery) && !delivered.has(coordinated.recovery)) {
              escalations.push({ id: coordinated.recovery, task: item.task_id, reason: item.reason, recovery: true });
            }
          } catch (error) {
            if (!current()) throw error;
            const reason = temporaryOwnershipRefusal(error, item.task_id);
            if (reason) deferOwnership({ task_id: item.task_id, reason,
              key: createHash("sha256").update(`${item.task_id}\0${reason}`).digest("hex") });
            // A task-local CAS/lease/readback refusal retains its own debt.
            // Other tasks in this bounded batch still receive coordination.
            continue;
          }
        }
        if (admission && !submitted.has(admission) && !delivered.has(admission)) {
          lines.push(`${item.task_id}: ${item.state}: ${item.reason}`);
          admissions.push(admission);
        }
      }
    } finally { unlinkSync(proofFile); }
    if (!current()) throw new Error("readback receiver generation changed");
    if (lines.length || escalations.length) {
      const content = lines.length
        ? await encodeFirstmateOperationalInputWith(runCommandAsync, "branch-outcome", instruction(lines)) : "";
      if (!current()) throw new Error("readback receiver generation changed");
      return { content, admissions, escalations, canNotify: () => current() && owner.canNotify(),
        canContinue: () => current() && owner.canContinue() };
    }
  }

  function escalationEntry(admission: Admission, includeRecovery = true) {
    const items = admission.escalations.filter((item) => includeRecovery || !item.recovery);
    if (!items.length) return;
    const lines = items.map(({ task, reason }) =>
      `${task}: ${reason.startsWith("lifecycle observation refused;") ? reason : `two automatic coordination requests produced no verified continuation: ${reason}`}.`);
    return {
      type: "custom_message" as const, customType: ESCALATION, display: true,
      content: "Continuation needs executable main coordination:\n" + lines.join("\n") + "\n" +
        (items.some((item) => item.recovery) ? "Persistent recovery: prior coordination returned without a verified next action. Perform the authorized next tool/handoff action now; another observation-only response leaves responsibility pending.\n" : "") +
        (items.some((item) => item.reconciliation) ? "Lifecycle refusals require explicit reconciliation; no receiver or execution state was inferred. " : "") +
        (items.some((item) => !item.reconciliation) ? "Initial request budgets stay exhausted; later recovery is counted separately. " : "") +
        "These tasks remain open. This is not completion or a task blocker. " +
        "Assign an authorized executor and verify receipt/start, reconcile a real dependency, or provide acceptance evidence. " +
        "If an effect may already have happened, read it back before any retry. Unrelated input does not reset the budget.",
      details: { admissions: items.map(({ id }) => id),
        task: items.length === 1 ? items[0].task : undefined,
        tasks: items.map(({ task }) => task), owner: "main",
        kind: items.every((item) => item.reconciliation) ? "lifecycle-reconciliation" : "coordination-failure" },
    };
  }

  async function check(ctx: ExtensionContext): Promise<Admission | undefined> {
    while (checking) await checking;
    if (!owns()) return;
    let received: Promise<Admission | undefined> | undefined;
    pi.events.emit("firstmate:continuation-readback", { ctx,
      accept(owner: ContinuationReceiver) {
        if (received) throw new Error("duplicate continuation receiver");
        received = receive(ctx, owner);
      },
    } satisfies ContinuationReadbackOffer);
    if (!received) throw new Error("existing heartbeat owner did not receive continuation readback");
    checking = received;
    try { return await received; }
    finally { if (checking === received) checking = null; }
  }

  // The existing periodic coordinator is the sole clock, even while its
  // optional full maintenance pass is disabled. No parallel timer is created.
  pi.events.on("firstmate:heartbeat-tick", () => {
    if (!context || checking) return;
    const epoch = generation;
    const ctx = context;
    void check(ctx).then((admission) => {
      // No await between the safety owner's complete judgment and submission.
      // If unsafe, canonical reserved admission survives the next tick/reload.
      if (admission && epoch === generation && admission.canNotify()) {
        const escalation = escalationEntry(admission);
        if (escalation) {
          try { pi.sendMessage(escalation, { triggerTurn: true, deliverAs: "followUp" }); }
          catch (error) {
            for (const entry of ctx.sessionManager.getBranch()) {
              if (entry.type === "custom_message") readDelivery(entry);
      if (entry.type === "custom" && entry.customType === "fm-continuation-branch-delivery") {
        readDelivery({ customType: entry.customType, details: entry.data, timestamp: entry.timestamp });
      }
            }
            throw error;
          }
          for (const id of escalation.details.admissions) submitted.add(id);
          return; // One batch per tick; ordinary reservations remain durable.
        }
        if (!admission.admissions.length) return;
        try {
          pi.sendMessage({ customType: MESSAGE, content: admission.content, display: false,
            details: { admissions: admission.admissions } }, { triggerTurn: true, deliverAs: "followUp" });
        } catch (error) {
          for (const entry of ctx.sessionManager.getBranch()) {
            if (entry.type === "custom_message") readDelivery(entry);
      if (entry.type === "custom" && entry.customType === "fm-continuation-branch-delivery") {
        readDelivery({ customType: entry.customType, details: entry.data, timestamp: entry.timestamp });
      }
          }
          throw error;
        }
        for (const id of admission.admissions) submitted.add(id);
      }
    }).catch(() => { /* Pending evidence remains available at the next tick. */ });
  });

  pi.on("session_start", (_event, ctx) => {
    generation++;
    context = ctx;
    inputs.clear();
    pacing.clear();
    delivered.clear();
    const entries = ctx?.sessionManager?.getBranch?.() ?? ctx?.sessionManager?.getEntries?.() ?? [];
    for (const entry of entries) {
      if (entry.type === "custom_message") readDelivery(entry);
      if (entry.type === "custom" && entry.customType === "fm-continuation-branch-delivery") {
        readDelivery({ customType: entry.customType, details: entry.data, timestamp: entry.timestamp });
      }
      if (entry.type === "custom" && entry.customType === PACING_ENTRY) {
        const pace = entry.data as InputPacing & { id: string };
        if (typeof pace?.id === "string") pacing.set(pace.id, pace);
      }
      if (entry.type !== "custom" || entry.customType !== INPUT_ENTRY) continue;
      const value = entry.data as InputReceipt;
      if (typeof value?.id === "string" && typeof value.text === "string") inputs.set(value.id, value);
    }
  });
  pi.on("session_shutdown", () => {
    generation++;
    context = undefined;
  });
  pi.on("message_end", (event) => {
    if (event.message.role === "custom") readDelivery(event.message);
  });
  pi.on("agent_before_settle", async (_event, ctx) => {
    context = ctx;
    const admission = await check(ctx);
    if (admission && admission.canContinue()) {
      const escalation = escalationEntry(admission, false);
      if (escalation) for (const id of escalation.details.admissions) submitted.add(id);
      for (const id of admission.admissions) submitted.add(id);
      return { entries: [...(escalation ? [escalation] : []), ...(admission.admissions.length ? [{ type: "custom_message" as const, customType: MESSAGE,
        content: admission.content, display: false, details: { admissions: admission.admissions } }] : [])],
        continue: admission.admissions.length > 0 || Boolean(escalation) };
    }
  });

  registerFirstmateTool(pi, {
    name: "fm_task_continuation", label: "Task continuation",
    description: "Preserve and inspect live task obligations. Route an input receipt to an enrolled task with a durable brief, or attest that an informational input was answered. Task assessment/action CAS uses bin/fm-task-state.sh reconcile/action; no tool here executes or grants authority for an action.",
    parameters: Type.Object({ action: Type.Union([Type.Literal("list"), Type.Literal("enroll"), Type.Literal("route"), Type.Literal("answer")]),
      task: Type.Optional(Type.String()), input: Type.Optional(Type.String()), answer: Type.Optional(Type.String()) }),
    async execute(_id, params, _signal, _update, _ctx: ExtensionContext) {
      try {
        if (!owns()) throw new Error("this session does not own the fleet lock");
        let result: unknown;
        if (params.action === "list") {
          result = { inputs: [...inputs.values()], tasks: existsSync(data) ? readdirSync(data).filter((id) => atom(id) && existsSync(join(data, id, "lifecycle.json"))) : [], instructions: "Use lifecycle/observe/reconcile/action via bin/fm-task-state.sh. A report or provider terminal state is not acceptance." };
        } else if (params.action === "enroll") {
          result = await enroll(params.task || "");
        } else {
          const input = inputs.get(params.input || "");
          if (!input || input.task || input.answer) throw new Error("input is absent or already routed/answered");
          if (params.action === "route") {
            await enroll(params.task || "");
            result = { ...input, task: params.task };
          } else {
            if (!params.answer?.trim()) throw new Error("substantive informational answer required; task work must be routed");
            result = { ...input, answer: params.answer };
          }
          pi.appendEntry(INPUT_ENTRY, result);
          inputs.set(input.id, result as InputReceipt);
        }
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }], details: undefined };
      } catch (error) {
        return { content: [{ type: "text" as const, text: String(error) }], details: undefined, isError: true };
      }
    },
  });
  return { preserve, capture, sessionFile: () => context?.sessionManager.getSessionFile(), inputBarrier: () => [...inputs.values()].some((input) => !input.task && !input.answer) };
}

// Live-Pi reminder over the original task record. MAIN owns material progress
// updates; existing executor, effect, lease, inbox, merge and cleanup owners act.
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { runCommandAsync } from "./fm-async-exec.ts";
import { registerFirstmateTool } from "./fm-native-contract.ts";
import { encodeFirstmateOperationalInputWith } from "./fm-operational-input.ts";

type Observation = { task_id: string; state: string; reason: string; key: string; record_token: string;
  goal: string; acceptance: string; current_state: string; remaining_gap: string; next_step: string;
  task_state: string; task_held: string; task_blocked: string; executor_state: string };
type Reconciliation = { task_id: string; reason: string; key: string };
type Admission = { content: string; admissions: string[]; escalations: { id: string; task: string; reason: string; reconciliation: true }[];
  canNotify: () => boolean; canContinue: () => boolean };
type InputPacing = { key: string; attempts: number; after: number; reserved?: string };
const PACING_ENTRY = "fm-continuation-input-pacing";
const MESSAGE = "fm-task-continuation";
const ESCALATION = "fm-task-continuation-escalation";
const INTERVAL_MS = 30_000;
const MAX_REMINDER_INTERVALS = 10;
const BATCH = 8;
const atom = (s: string) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/.test(s);

function processedRequirement(value: unknown): string {
  if (typeof value !== "string") throw new Error("intent update requires processed requirement text in input");
  if (!value.trim()) throw new Error("intent update input must contain non-whitespace processed requirement text");
  if (value.length > 8192) throw new Error("intent update input exceeds the 8192-character limit");
  if (value.includes("\0")) throw new Error("intent update input must not contain NUL characters");
  if (/^#{1,2}(?:[ \t]+|$)/m.test(value)) {
    throw new Error("intent update input must keep structure inside the Intent subsection; use Markdown heading level 3 or deeper");
  }
  return value;
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
  task: string;
  admission: string;
  progress: Observation;
  delivered: (proof: { sessionFile: string; entryId: string; generation: number }) => void;
  settled: () => void;
};

export function installTaskContinuation(pi: ExtensionAPI, options: {
  root: string; home: string; state: string; owns: () => boolean;
  offer?: (offer: TaskContinuationOffer) => boolean;
}) {
  const { root, home, state, owns } = options;
  const data = process.env.FM_DATA_OVERRIDE || join(home, "data");
  const pacing = new Map<string, InputPacing>();
  const submitted = new Set<string>();
  const delivered = new Map<string, number>();
  let generation = 0;
  let checking: Promise<Admission | undefined> | null = null;
  let context: ExtensionContext | undefined;
  let cursor = 0;

  async function command(args: string[]) {
    const epoch = generation;
    if (!owns()) throw new Error("this session does not own the fleet lock");
    const result = await runCommandAsync("bash", [join(root, "bin/fm-task-state.sh"), ...args], {
      env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state, FM_DATA_OVERRIDE: data,
        FM_SUPERVISION_ACTOR: "main" }, maxBuffer: 1024 * 1024,
    });
    if (epoch !== generation || !owns()) throw new Error("continuation generation changed");
    if (result.status !== 0) throw new Error(result.stderr.trim() || "task continuation operation failed");
    return JSON.parse(result.stdout);
  }

  // Outcome delivery never creates continuation state.  MAIN writes progress
  // into the already-existing task record only after reviewing the result.
  async function preserve(tasks: string[]) {
    for (const task of new Set(tasks)) {
      if (task === "fleet") continue;
      if (!atom(task)) throw new Error("unresolved outcome task identity");
    }
  }

  // Compatibility for dialog adapters: the native transcript owns chat evidence.
  // Capturing a message does not enroll work or create an input obligation.
  function capture(_text: string, _key?: string): string { return ""; }

  function instruction(lines: string[]): string {
    return "Unfinished task records require goal-directed MAIN follow-through:\n" +
      lines.join("\n") + "\nUse fm_task_continuation read/update for the task goal, acceptance method, current state, remaining gap and next step. " +
      "Update only after a material change; do not write after each command or unchanged wait. " +
      "Take the authorized next step through its existing owner, review actual artifacts, and clear the gap only when the requested goal is satisfied. " +
      "A worker return, report, PR, empty inbox or provider success is not acceptance. " +
      "Existing leases, inbox/handoff acknowledgements, uncertain-effect readback, merge and cleanup guards remain authoritative.";
  }

  async function collect(): Promise<{ observations: Observation[]; reconciliations: Reconciliation[] }> {
    const epoch = generation;
    const observations: Observation[] = [];
    const reconciliations: Reconciliation[] = [];
    const listed = await command(["progress-list"]);
    const ids = Array.isArray(listed?.tasks) ? listed.tasks.filter((id: unknown) => typeof id === "string" && atom(id)).sort() : [];
    for (let i = 0; i < Math.min(BATCH, ids.length); i++) {
      const id = ids[(cursor + i) % ids.length];
      try {
        const progress = await command(["progress", id]);
        if (!progress?.remaining_gap || !progress.next_step) continue;
        if (!progress.recorded) {
          const reason = progress.task_state === "done"
            ? "Done row retains a nonempty compact gap; MAIN must reopen/start it before routing the recorded next step"
            : "authenticated intent, executor generation, hold, block, or disposition changed; MAIN must refresh compact progress before continuation";
          const key = createHash("sha256").update(`${id}\0${progress.record_token}\0${reason}`).digest("hex");
          reconciliations.push({ task_id: id, reason, key });
          continue;
        }
        const current = await runCommandAsync("bash", [join(root, "bin/fm-task-state.sh"), "--durable-only", id], {
          env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state, FM_DATA_OVERRIDE: data }, maxBuffer: 64 * 1024,
        });
        const executorState = current.stdout.trim();
        const match = executorState.match(/(?:^|\n)state: ([a-z-]+)/);
        const taskState = current.status === 0 && match ? match[1] : "unknown";
        if (["running", "working", "pending", "paused", "parked"].includes(taskState)) continue;
        const reason = `goal: ${progress.goal}; acceptance: ${progress.acceptance}; current state: ${progress.current_state}; remaining gap: ${progress.remaining_gap}; next step: ${progress.next_step}`;
        // The task row deliberately changes only when MAIN records semantic
        // progress. Executor detail is therefore part of the admission key:
        // a new terminal result can receive a fresh bounded Branch turn even
        // while the compact row still names the original checkpoint.
        const key = createHash("sha256").update(JSON.stringify([id, progress.record_token, executorState])).digest("hex");
        observations.push({ task_id: id, state: taskState, reason, key, record_token: progress.record_token,
          goal: progress.goal, acceptance: progress.acceptance, current_state: progress.current_state,
          remaining_gap: progress.remaining_gap, next_step: progress.next_step, task_state: progress.task_state,
          task_held: progress.task_held, task_blocked: progress.task_blocked,
          executor_state: executorState });
      } catch (error) {
        if (epoch !== generation || !owns()) throw error;
        const reason = String(error instanceof Error ? error.message : error).slice(0, 1200);
        const key = createHash("sha256").update(`${id}\0${reason}`).digest("hex");
        reconciliations.push({ task_id: id, reason, key });
      }
    }
    cursor = ids.length ? (cursor + BATCH) % ids.length : 0;
    return { observations, reconciliations };
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
    const { observations, reconciliations } = await collect();
    if (!current()) throw new Error("readback receiver generation changed");
    if (!observations.length && !reconciliations.length) return;
    // A persisted native delivery is only a pacing receipt.  Progress remains
    // in the original task record and changes only through MAIN's update.
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom_message") readDelivery(entry);
      if (entry.type === "custom" && entry.customType === "fm-continuation-branch-delivery") {
        readDelivery({ customType: entry.customType, details: entry.data, timestamp: entry.timestamp });
      }
    }
    const lines: string[] = [];
    const admissions: string[] = [];
    const escalations: Admission["escalations"] = [];
    for (const item of reconciliations) {
      const id = `q.${item.key}`;
      if (!submitted.has(id) && !delivered.has(id)) escalations.push({ id, task: item.task_id,
        reason: `task progress read refused; inspect the original task record: ${item.reason}`, reconciliation: true });
    }
    for (const item of observations) {
      const paceId = `progress:${item.task_id}`;
      let pace = pacing.get(paceId);
      if (!pace || pace.key !== item.key) pace = { key: item.key, attempts: 0, after: 0 };
      if (pace.reserved && delivered.has(pace.reserved)) {
        const at = delivered.get(pace.reserved)!;
        pace.attempts += 1;
        pace.after = at + INTERVAL_MS * Math.min(pace.attempts, MAX_REMINDER_INTERVALS);
        pace.reserved = undefined;
      }
      if (!pace.reserved && Date.now() >= pace.after) {
        pace.reserved = `n.${item.key}.${pace.attempts + 1}`;
      }
      if (pace.reserved && !submitted.has(pace.reserved) && !delivered.has(pace.reserved)) {
        const id = pace.reserved;
        if (options.offer?.({
          task: item.task_id,
          admission: id,
          progress: item,
          delivered(proof) {
            if (!current()) return;
            pi.appendEntry("fm-continuation-branch-delivery", { admissions: [id], ...proof });
            delivered.set(id, Date.now());
          },
          settled() { submitted.delete(id); },
        })) {
          submitted.add(id);
        } else {
          lines.push(`${item.task_id}: ${item.reason}`);
          admissions.push(id);
        }
      }
      pacing.set(paceId, pace);
      pi.appendEntry(PACING_ENTRY, { id: paceId, ...pace });
    }
    if (!current()) throw new Error("readback receiver generation changed");
    if (lines.length || escalations.length) {
      const content = lines.length
        ? await encodeFirstmateOperationalInputWith(runCommandAsync, "branch-outcome", instruction(lines)) : "";
      if (!current()) throw new Error("readback receiver generation changed");
      return { content, admissions, escalations, canNotify: () => current() && owner.canNotify(),
        canContinue: () => current() && owner.canContinue() };
    }
  }

  function escalationEntry(admission: Admission) {
    const items = admission.escalations;
    if (!items.length) return;
    const lines = items.map(({ task, reason }) => `${task}: ${reason}.`);
    return {
      type: "custom_message" as const, customType: ESCALATION, display: true,
      content: "Continuation needs executable main coordination:\n" + lines.join("\n") + "\n" +
        "Task-record read refusals require explicit reconciliation; no receiver or execution state was inferred. " +
        "These tasks remain open. This is not completion or a task blocker. " +
        "Assign an authorized executor and verify receipt/start, reconcile a real dependency, or provide acceptance evidence. " +
        "If an effect may already have happened, read it back before any retry. Unrelated input does not close these tasks.",
      details: { admissions: items.map(({ id }) => id),
        task: items.length === 1 ? items[0].task : undefined,
        tasks: items.map(({ task }) => task), owner: "main",
        kind: "task-record-reconciliation" },
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
    }).catch(() => { /* Pending task-record progress remains available at the next tick. */ });
  });

  const restoreSession = (_event: unknown, ctx: ExtensionContext) => {
    generation++;
    context = ctx;
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
        if (typeof pace?.id === "string" && /^(progress|reconcile):/.test(pace.id)) pacing.set(pace.id, pace);
      }
    }
  };
  pi.on("session_start", restoreSession);
  pi.on("session_tree", restoreSession);
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
      const escalation = escalationEntry(admission);
      if (escalation) for (const id of escalation.details.admissions) submitted.add(id);
      for (const id of admission.admissions) submitted.add(id);
      return { entries: [...(escalation ? [escalation] : []), ...(admission.admissions.length ? [{ type: "custom_message" as const, customType: MESSAGE,
        content: admission.content, display: false, details: { admissions: admission.admissions } }] : [])],
        continue: admission.admissions.length > 0 || Boolean(escalation) };
    }
  });

  registerFirstmateTool(pi, {
    name: "fm_task_continuation", label: "Task continuation",
    description: "Read or materially update compact MAIN-owned continuation fields in the original task record. The task title is its goal; update records the acceptance method, current state, remaining gap and next step with the record_token returned by read. Unchanged waits and individual commands need no update. This tool neither discovers tasks nor edits intent, reads history, executes work, or accepts a goal from process success.",
    executionMode: "sequential",
    parameters: Type.Object({ action: Type.Union([Type.Literal("read"), Type.Literal("update")]),
      task: Type.String(), record_token: Type.Optional(Type.String()),
      progress: Type.Optional(Type.Object({ acceptance: Type.String(), current_state: Type.String(),
        remaining_gap: Type.String(), next_step: Type.String() })) }),
    async execute(_id, params, _signal, _update, _ctx: ExtensionContext) {
      try {
        if (!owns()) throw new Error("this session does not own the fleet lock");
        let result: unknown;
        if (params.action === "read") {
          if (!atom(params.task)) throw new Error("read requires an existing canonical task id");
          result = await command(["progress", params.task]);
        } else if (params.action === "update") {
          if (!atom(params.task) || !params.record_token || !params.progress) {
            throw new Error("update requires task, the record_token returned by read, and compact progress fields");
          }
          result = await command(["update-progress", params.task, "--expected-token", params.record_token,
            "--progress", JSON.stringify(params.progress)]);
        } else {
          throw new Error("unsupported compact continuation action");
        }
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }], details: undefined };
      } catch (error) {
        return { content: [{ type: "text" as const, text: String(error) }], details: undefined, isError: true };
      }
    },
  });
  // Intent updates are a thin MAIN-only write into the canonical brief.
  // The brief remains the sole intent record; no transcript source, receipt,
  // mapping, or parallel history is created here.
  registerFirstmateTool(pi, {
    name: "fm_task_intent_update", label: "Update task intent",
    description: "Replace the existing task's final Intent with explicitly supplied processed requirement text. input is the complete requirement text itself. This does not create intent history, update progress, execute work, or accept the goal.",
    executionMode: "sequential",
    parameters: Type.Object({ task: Type.String(),
      input: Type.String({ description: "Complete processed requirement text that replaces the existing final Intent." }) }),
    async execute(_id, params, _signal, _update, _ctx: ExtensionContext) {
      try {
        if (!owns()) throw new Error("this session does not own the fleet lock");
        if (!atom(params.task)) throw new Error("intent update requires an existing canonical task id");
        const requirement = processedRequirement(params.input);
        const result = await command(["update-brief", params.task, `--requirement=${requirement}`]);
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }], details: undefined };
      } catch (error) {
        return { content: [{ type: "text" as const, text: String(error) }], details: undefined, isError: true };
      }
    },
  });
  return { preserve, capture, sessionFile: () => context?.sessionManager.getSessionFile(), inputBarrier: (_task?: string) => false };
}

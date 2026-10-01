// Live-Pi reminder over the original task record. MAIN owns material progress
// updates; existing executor, effect, lease, inbox, merge and cleanup owners act.
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { runCommandAsync } from "./fm-async-exec.ts";
import { registerFirstmateTool } from "./fm-native-contract.ts";
import { classifyFirstmateOperationalText, encodeFirstmateOperationalInputWith } from "./fm-operational-input.ts";
import { NATIVE_FEISHU_CUSTOM_TYPE, verifyFeishuSessionMessage } from "../../../bin/fm-feishu-state.mjs";

type Observation = { task_id: string; state: string; reason: string; key: string; record_token: string;
  goal: string; acceptance: string; current_state: string; remaining_gap: string; next_step: string;
  task_state: string };
type Reconciliation = { task_id: string; reason: string; key: string };
type InputReceipt = { id: string; text: string; task?: string; answer?: string;
  update_brief?: boolean; pending?: boolean; route_entry_id?: string; source_entry_id?: string };
type Admission = { content: string; admissions: string[]; escalations: { id: string; task: string; reason: string; recovery?: boolean; reconciliation?: boolean }[];
  canNotify: () => boolean; canContinue: () => boolean };
type InputPacing = { key: string; attempts: number; after: number; reserved?: string; escalatedAt?: number;
  recoveryAttempts?: number; recoveryAfter?: number; recoveryReserved?: string };
const INPUT_ENTRY = "fm-continuation-input";
const PACING_ENTRY = "fm-continuation-input-pacing";
const MESSAGE = "fm-task-continuation";
const ESCALATION = "fm-task-continuation-escalation";
const INTERVAL_MS = 30_000;
const ATTEMPTS = 2;
const BATCH = 8;
const atom = (s: string) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/.test(s);

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
  const inputs = new Map<string, InputReceipt>();
  // Only explicitly assigned intent transactions are recovered from the session.
  // Chat remains in the native transcript, never a separately supervised goal.
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

  async function enroll(task: string) {
    if (!atom(task)) throw new Error("invalid task identity");
    return command(["enroll", task]);
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

  function originalInput(ctx: ExtensionContext, id?: string): InputReceipt {
    const entries = ctx.sessionManager.getBranch();
    for (const entry of [...entries].reverse()) {
      if (id && entry.id !== id && !(entry.type === "custom" && entry.customType === INPUT_ENTRY && (entry.data as InputReceipt)?.id === id)) continue;
      // Historical unassigned capture is selectable only by exact receipt id
      // after ordinary intake has supplied the task. It gains no clock or goal.
      if (id && entry.type === "custom" && entry.customType === INPUT_ENTRY) {
        const value = entry.data as InputReceipt;
        if (value.id === id && !value.task && !value.answer && value.text?.trim()) return { id, text: value.text };
      }
      let content: unknown;
      if (entry.type === "message" && entry.message.role === "user") content = entry.message.content;
      else if (entry.type === "custom_message" && entry.customType === NATIVE_FEISHU_CUSTOM_TYPE) {
        if (!verifyFeishuSessionMessage(home, entry)) throw new Error("original Feishu message needs immutable delivery proof; retain the task update for exact readback");
        content = entry.content;
      } else continue;
      const text = typeof content === "string" ? content : Array.isArray(content)
        ? content.filter(part => part?.type === "text" && typeof part.text === "string").map(part => part.text).join("") : "";
      if (!text.trim() || classifyFirstmateOperationalText(text)) continue;
      return { id: entry.id, source_entry_id: entry.id, text };
    }
    throw new Error("Select an original user message from the current session; ambiguous task routing requires clarification through ordinary intake.");
  }

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
        if (!progress?.recorded || !progress.remaining_gap || !progress.next_step) continue;
        const current = await runCommandAsync("bash", [join(root, "bin/fm-task-state.sh"), "--durable-only", id], {
          env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state, FM_DATA_OVERRIDE: data }, maxBuffer: 64 * 1024,
        });
        const match = current.stdout.match(/(?:^|\n)state: ([a-z-]+)/);
        const taskState = current.status === 0 && match ? match[1] : "unknown";
        if (["running", "working", "pending", "paused", "parked"].includes(taskState)) continue;
        const reason = `goal: ${progress.goal}; acceptance: ${progress.acceptance}; current state: ${progress.current_state}; remaining gap: ${progress.remaining_gap}; next step: ${progress.next_step}`;
        const key = createHash("sha256").update(JSON.stringify([id, progress.record_token, taskState])).digest("hex");
        observations.push({ task_id: id, state: taskState, reason, key, record_token: progress.record_token,
          goal: progress.goal, acceptance: progress.acceptance, current_state: progress.current_state,
          remaining_gap: progress.remaining_gap, next_step: progress.next_step, task_state: progress.task_state });
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
        pace.attempts = Math.min(ATTEMPTS, pace.attempts + 1);
        pace.after = at + INTERVAL_MS * pace.attempts;
        pace.reserved = undefined;
      }
      if (!pace.reserved && pace.attempts < ATTEMPTS && Date.now() >= pace.after) {
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
      } else if (pace.attempts >= ATTEMPTS) {
        const escalation = `e.${item.key}`;
        if (!submitted.has(escalation) && !delivered.has(escalation)) {
          escalations.push({ id: escalation, task: item.task_id,
            reason: `two bounded branch continuations did not materially advance the recorded next step: ${item.reason}` });
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

  function escalationEntry(admission: Admission, includeRecovery = true) {
    const items = admission.escalations.filter((item) => includeRecovery || !item.recovery);
    if (!items.length) return;
    const lines = items.map(({ task, reason }) =>
      `${task}: ${reason.startsWith("task progress read refused;") ? reason : `two automatic coordination requests produced no verified continuation: ${reason}`}.`);
    return {
      type: "custom_message" as const, customType: ESCALATION, display: true,
      content: "Continuation needs executable main coordination:\n" + lines.join("\n") + "\n" +
        (items.some((item) => item.recovery) ? "Persistent recovery: prior coordination returned without a verified next action. Perform the authorized next tool/handoff action now; another observation-only response leaves responsibility pending.\n" : "") +
        (items.some((item) => item.reconciliation) ? "Task-record read refusals require explicit reconciliation; no receiver or execution state was inferred. " : "") +
        (items.some((item) => !item.reconciliation) ? "Initial request budgets stay exhausted; later recovery is counted separately. " : "") +
        "These tasks remain open. This is not completion or a task blocker. " +
        "Assign an authorized executor and verify receipt/start, reconcile a real dependency, or provide acceptance evidence. " +
        "If an effect may already have happened, read it back before any retry. Unrelated input does not reset the budget.",
      details: { admissions: items.map(({ id }) => id),
        task: items.length === 1 ? items[0].task : undefined,
        tasks: items.map(({ task }) => task), owner: "main",
        kind: items.every((item) => item.reconciliation) ? "task-record-reconciliation" : "coordination-failure" },
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
        if (typeof pace?.id === "string" && /^(progress|reconcile):/.test(pace.id)) pacing.set(pace.id, pace);
      }
      if (entry.type !== "custom" || entry.customType !== INPUT_ENTRY) continue;
      const value = entry.data as InputReceipt;
      if (value?.task && typeof value?.id === "string" && typeof value.text === "string") inputs.set(value.id,
        value.update_brief && !value.route_entry_id ? { ...value, route_entry_id: entry.id } : value);
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
    description: "Read or materially update compact MAIN-owned continuation fields in the original task record. The task title is its goal; update records the acceptance method, current state, remaining gap and next step with the record_token returned by read. Unchanged waits and individual commands need no update. route appends a selected original user message through the existing authenticated intent owner. legacy reads a historical rich lifecycle record but never makes it active progress. No operation executes work or accepts a goal from process success.",
    executionMode: "sequential",
    parameters: Type.Object({ action: Type.Union([Type.Literal("list"), Type.Literal("route"), Type.Literal("read"), Type.Literal("update"), Type.Literal("legacy")]),
      task: Type.Optional(Type.String()), input: Type.Optional(Type.String()),
      update_brief: Type.Optional(Type.Boolean()), record_token: Type.Optional(Type.String()),
      progress: Type.Optional(Type.Object({ acceptance: Type.String(), current_state: Type.String(),
        remaining_gap: Type.String(), next_step: Type.String() })) }),
    async execute(_id, params, _signal, _update, _ctx: ExtensionContext) {
      try {
        if (!owns()) throw new Error("this session does not own the fleet lock");
        let result: unknown;
        if (params.action === "list") {
          // Recover presentation after a successful canonical commit followed by
          // interruption. This acknowledges persistence, never goal acceptance.
          for (const routed of [...inputs.values()].filter(value => value.pending)) {
            try {
              const readback = await command(["lifecycle", routed.task!]);
              const update = Object.values(readback.intent_updates || {}).find((value: any) =>
                value.phase === "confirmed" && value.proof?.input === routed.id &&
                value.proof?.entry_id === routed.route_entry_id &&
                value.proof?.session_file === _ctx.sessionManager.getSessionFile());
              if (update) {
                const confirmed = { ...routed, pending: false };
                pi.appendEntry(INPUT_ENTRY, confirmed);
                inputs.set(routed.id, confirmed);
              }
            } catch { /* Exact recovery stays pending until its owner can read it. */ }
          }
          const listed = await command(["progress-list"]);
          result = { tasks: listed.tasks || [], pending_updates: [...inputs.values()].filter(value => value.task && value.pending),
            instructions: "Use read, then update only after a material change. The original task title is the goal; acceptance, current state, remaining gap and next step stay in that task record. A report or provider terminal state is not acceptance. Unchanged healthy waits need no write." };
        } else if (params.action === "read") {
          if (!atom(params.task || "")) throw new Error("read requires an existing canonical task id");
          result = await command(["progress", params.task!]);
        } else if (params.action === "update") {
          if (!atom(params.task || "") || !params.record_token || !params.progress) {
            throw new Error("update requires task, the record_token returned by read, and compact progress fields");
          }
          result = await command(["update-progress", params.task!, "--expected-token", params.record_token,
            "--progress", JSON.stringify(params.progress)]);
        } else if (params.action === "legacy") {
          if (!atom(params.task || "")) throw new Error("legacy requires a canonical task id");
          result = await command(["lifecycle", params.task!]);
        } else {
          if (params.action !== "route" || !atom(params.task || "") || params.update_brief !== true) {
            throw new Error("Task updates require an explicit existing task and update_brief:true; chat is answered normally.");
          }
          const input = params.input && inputs.get(params.input) || originalInput(_ctx, params.input);
          const sessionFile = _ctx.sessionManager.getSessionFile();
          if (!sessionFile) throw new Error("task update requires a persisted original session");
          // Existing prepared updates must reach their owner before normal reads,
          // which deliberately refuse while the atomic intent transaction is pending.
          if (!inputs.has(input.id)) await enroll(params.task!);
          let routed = inputs.get(input.id);
          if (routed && routed.task !== params.task) throw new Error("original intent update belongs to another task");
          if (!routed) {
            routed = { ...input, task: params.task, update_brief: true, pending: true };
            pi.appendEntry(INPUT_ENTRY, routed);
            const entry = _ctx.sessionManager.getBranch().at(-1);
            if (entry?.type !== "custom" || entry.customType !== INPUT_ENTRY) throw new Error("task intent receipt was not persisted");
            routed = { ...routed, route_entry_id: entry.id };
            inputs.set(input.id, routed);
          }
          result = await command(["update-brief", params.task!, "--session-file", sessionFile,
            "--entry-id", routed.route_entry_id!, "--input", input.id]);
          if (routed.pending) {
            routed = { ...routed, pending: false };
            pi.appendEntry(INPUT_ENTRY, routed);
            inputs.set(input.id, routed);
          }
        }
        return { content: [{ type: "text" as const, text: JSON.stringify(result) }], details: undefined };
      } catch (error) {
        return { content: [{ type: "text" as const, text: String(error) }], details: undefined, isError: true };
      }
    },
  });
  return { preserve, capture, sessionFile: () => context?.sessionManager.getSessionFile(), inputBarrier: (task?: string) => [...inputs.values()].some((input) => input.task === task && input.pending) };
}

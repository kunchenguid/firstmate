// Live-Pi consumer of the canonical task assessment owner. Never executes an
// action: main coordinates, and the existing executor/lease/inbox owners act.
import { randomUUID } from "node:crypto";
import { existsSync, lstatSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { runCommandAsync } from "./fm-async-exec.ts";
import { registerFirstmateTool } from "./fm-native-contract.ts";
import { encodeFirstmateOperationalInputWith } from "./fm-operational-input.ts";

type Observation = { task_id: string; state: string; reason: string; key: string };
type InputReceipt = { id: string; text: string; task?: string; answer?: string };
const INPUT_ENTRY = "fm-continuation-input";
const MESSAGE = "fm-task-continuation";
const INTERVAL_MS = 30_000;
const ATTEMPTS = 2;
const BATCH = 8;
const atom = (s: string) => /^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$/.test(s);

export function installTaskContinuation(pi: ExtensionAPI, options: {
  root: string; home: string; state: string; owns: () => boolean;
}) {
  const { root, home, state, owns } = options;
  const data = process.env.FM_DATA_OVERRIDE || join(home, "data");
  const inputs = new Map<string, InputReceipt>();
  // Notification pacing only. Goal truth is exclusively lifecycle.json. No
  // unchanged report, marker acknowledgement or session compaction resets it.
  const pacing = new Map<string, { key: string; attempts: number; after: number; queued: boolean }>();
  let generation = 0;
  let busy = false;
  let streaming = false;
  let cursor = 0;
  let inputCursor = 0;
  let deferred: string[] = [];

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

  async function collect(): Promise<string[]> {
    deferred = [];
    const observations: Observation[] = [];
    const unrouted = [...inputs.values()].filter((value) => !value.task && !value.answer);
    for (let i = 0; i < Math.min(BATCH, unrouted.length); i++) {
      const value = unrouted[(inputCursor + i) % unrouted.length];
      observations.push({ task_id: `input:${value.id}`,
        state: "pending", reason: value.text.slice(0, 1200), key: value.id });
    }
    inputCursor = unrouted.length ? (inputCursor + BATCH) % unrouted.length : 0;
    const ids = existsSync(data) ? readdirSync(data).filter((id) => atom(id) &&
      existsSync(join(data, id, "lifecycle.json"))).sort() : [];
    for (let i = 0; i < Math.min(BATCH, ids.length); i++) {
      const id = ids[(cursor + i) % ids.length];
      try {
        if (lstatSync(join(data, id)).isSymbolicLink()) throw new Error("unsafe task directory");
        observations.push(await command(["observe", id]));
      } catch (error) {
        const reason = String(error);
        observations.push({ task_id: id, state: "unknown", reason, key: reason });
      }
    }
    cursor = ids.length ? (cursor + BATCH) % ids.length : 0;
    const lines: string[] = [];
    for (const item of observations) {
      if (["accepted", "archived", "running", "blocked"].includes(item.state)) {
        // Keep the fingerprint budget across transient healthy observations.
        continue;
      }
      let pace = pacing.get(item.task_id);
      if (!pace || pace.key !== item.key) {
        pace = { key: item.key, attempts: 0, after: 0, queued: false };
        pacing.set(item.task_id, pace);
      }
      if (Date.now() < pace.after) continue;
      if (pace.attempts >= ATTEMPTS) {
        if (!pace.queued) {
          deferred.push(`${item.task_id}: ${item.state}: ${item.reason} [automatic retries exhausted; this obligation still requires an executor, evidenced blocker or semantic acceptance]`);
          pace.queued = true;
        }
        continue;
      }
      pace.attempts++;
      pace.after = Date.now() + INTERVAL_MS * 2 ** (pace.attempts - 1);
      lines.push(`${item.task_id}: ${item.state}: ${item.reason}` +
        (pace.attempts === ATTEMPTS ? " [bounded continuation attempts exhausted for unchanged evidence; resolve or escalate the concrete gap]" : ""));
    }
    return lines;
  }

  async function check(): Promise<string | undefined> {
    if (busy || !owns()) return;
    busy = true;
    const epoch = generation;
    const prior = new Map([...pacing].map(([id, pace]) => [id, { ...pace }]));
    const restore = () => { pacing.clear(); for (const [id, pace] of prior) pacing.set(id, pace); };
    try {
      const lines = await collect();
      if (epoch !== generation || !owns()) { restore(); return; }
      if (!lines.length && !deferred.length) return;
      const content = await encodeFirstmateOperationalInputWith(runCommandAsync, "branch-outcome", instruction([...lines, ...deferred]));
      if (epoch !== generation || !owns()) { restore(); return; }
      if (lines.length) return content;
      // One context reminder survives into the next ordinary turn after the
      // automatic budget. It does not reopen presentation or spin a new run.
      pi.sendMessage({ customType: MESSAGE, content, display: false }, { deliverAs: "nextTurn" });
    } catch (error) { restore(); throw error; }
    finally { busy = false; }
  }

  // The existing periodic coordinator is the sole clock, even while its
  // optional full maintenance pass is disabled. No parallel timer is created.
  pi.events.on("firstmate:heartbeat-tick", () => {
    if (streaming) return;
    const epoch = generation;
    void check().then((content) => {
      if (content && epoch === generation && owns()) pi.sendMessage(
        { customType: MESSAGE, content, display: false }, { triggerTurn: true, deliverAs: "followUp" });
    }).catch(() => { /* Pending evidence remains available at the next tick. */ });
  });

  pi.on("session_start", (_event, ctx) => {
    generation++;
    const entries = ctx?.sessionManager?.getBranch?.() ?? ctx?.sessionManager?.getEntries?.() ?? [];
    for (const entry of entries) {
      if (entry.type !== "custom" || entry.customType !== INPUT_ENTRY) continue;
      const value = entry.data as InputReceipt;
      if (typeof value?.id === "string" && typeof value.text === "string") inputs.set(value.id, value);
    }
  });
  pi.on("session_shutdown", () => {
    generation++;
    streaming = false;
  });
  pi.on("agent_start", () => {
    streaming = true;
    for (const pace of pacing.values()) pace.queued = false;
  });
  pi.on("agent_settled", () => { streaming = false; });
  pi.on("agent_before_settle", async () => {
    const content = await check();
    if (content) return { entries: [{ type: "custom_message" as const, customType: MESSAGE,
      content, display: false }], continue: true };
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
  return { preserve, capture };
}

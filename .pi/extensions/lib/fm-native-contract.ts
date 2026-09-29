import { randomUUID } from "node:crypto";
import type { ExtensionAPI, ExtensionContext, ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { TSchema } from "typebox";

// Public Pi event-bus boundary for native-harness adapters. FirstMate owns the
// operational message allowlist and these tools; the adapter owns transport.
// Discovery is synchronous: emit { register(tool), allowMessageType(type) } on
// firstmate:native-tools. Only explicitly registered FirstMate controls cross
// this boundary, with the SAME execute callback and ownership checks as Pi.
// The native adapter supplies its current ExtensionContext when executing.
// Pi owns subscription cleanup with the extension runtime, including reload.
export function registerFirstmateTool<TParams extends TSchema, TDetails, TState>(
  pi: ExtensionAPI,
  tool: ToolDefinition<TParams, TDetails, TState>,
): void {
  pi.registerTool?.(tool);
  pi.events?.on?.("firstmate:native-tools", (request: unknown) => {
    if (!request || typeof request !== "object") return;
    const discovery = request as {
      register?: (tool: unknown) => void;
      allowMessageType?: (type: string) => void;
    };
    if (typeof discovery.register === "function") {
      discovery.register({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.parameters,
        execute: tool.execute,
      });
    }
    if (typeof discovery.allowMessageType === "function") {
      for (const type of ["firstmate-sessionstart-nudge", "fm-branch-merge", "fm-branch-process"]) {
        discovery.allowMessageType(type);
      }
    }
  });
}

// Pi owns tool execution and session replacement; Herdr's installed Pi
// integration owns pane state. This helper contributes ONE balanced attention
// hold to that integration, never a busy-state record or a second reporter.
// Only validated named question tools in this primary's exact TUI runtime
// acquire it. Native progress/child events on the shared bus are not root tool
// events and must not be translated into this hold.
//
// A result closes a tool, not a processing run: answered/failed calls release
// on turn_start or confirmed agent_settled. Cancelled questions remain held
// through automatic continuations until those questions are answered or this
// runtime shuts down. Unrelated input cannot resolve a decision. A tab or
// Escape inside an editor emits no result and therefore cannot release a hold.
// Session-manager identity plus an incarnation token isolates reloads/forks;
// all output retains the exact root session, pane, socket, and generation.
export function registerFirstmateDecisionAttention(
  pi: ExtensionAPI,
  ownsPrimary: () => boolean,
): void {
  const paneId = process.env.HERDR_PANE_ID;
  const socketPath = process.env.HERDR_SOCKET_PATH;
  if (process.env.HERDR_ENV !== "1" || !paneId || !socketPath) return;

  type Call = {
    tool: string;
    questions: string[];
    phase: "open" | "answered" | "cancelled" | "closed" | "retired";
  };
  let owner: {
    manager: ExtensionContext["sessionManager"];
    identity: { kind: "root"; sessionId: string; paneId: string; socketPath: string; generation: string };
  } | undefined;
  const calls = new Map<string, Call>();
  let held = false;
  const questionTool = (name: string): boolean =>
    name === "ask_user_question" || name === "plan_mode_question";
  const sameOwner = (ctx: ExtensionContext): boolean => {
    try {
      return !!owner &&
        ctx.sessionManager === owner.manager &&
        ctx.sessionManager.getSessionId() === owner.identity.sessionId &&
        process.env.HERDR_PANE_ID === paneId && process.env.HERDR_SOCKET_PATH === socketPath;
    } catch {
      // Pi deliberately throws from contexts belonging to a retired runtime.
      return false;
    }
  };
  const current = (ctx: ExtensionContext): boolean => {
    try {
      return ctx.mode === "tui" && ctx.hasUI && ownsPrimary() && sameOwner(ctx);
    } catch {
      return false;
    }
  };
  const publish = (active: boolean): void => {
    if (!owner || active === held) return;
    held = active;
    pi.events.emit("herdr:blocked", {
      active,
      label: "Firstmate decision",
      identity: owner.identity,
    });
  };
  const finish = (): void => {
    const answered = new Set([...calls.values()]
      .filter((call) => call.phase === "answered").flatMap((call) => call.questions));
    for (const call of calls.values()) {
      if (call.phase === "answered" || call.phase === "closed" ||
          (call.phase === "cancelled" && call.questions.every((question) => answered.has(question)))) {
        call.phase = "retired";
      }
    }
    publish([...calls.values()].some((call) => call.phase !== "retired"));
  };
  const result = (id: string, tool: string, details: unknown, error: boolean): void => {
    const call = calls.get(id);
    if (!call || call.tool !== tool || call.phase !== "open") return;
    const value = details as { cancelled?: unknown; reason?: unknown } | undefined;
    const noForm = tool === "plan_mode_question" &&
      ["invalid_input", "ui_unavailable", "plan_mode_inactive"].includes(String(value?.reason));
    call.phase = error || noForm ? "closed" : value?.cancelled === true ? "cancelled" : "answered";
  };

  pi.on("session_start", (_event, ctx) => {
    // Startup may acquire the home lock later in before_agent_start. Capture
    // identity now; current() still requires ownership for every tool event.
    if (ctx.mode !== "tui" || !ctx.hasUI) return;
    const sessionId = ctx.sessionManager.getSessionId();
    if (!sessionId || sameOwner(ctx)) return;
    publish(false);
    calls.clear();
    owner = {
      manager: ctx.sessionManager,
      identity: { kind: "root", sessionId, paneId, socketPath, generation: randomUUID() },
    };
  });
  pi.on("tool_call", (event, ctx) => {
    if (!current(ctx) || !questionTool(event.toolName) || calls.has(event.toolCallId)) return;
    const questions = (event.input as { questions?: unknown }).questions;
    if (!Array.isArray(questions) || questions.length === 0) return;
    calls.set(event.toolCallId, {
      tool: event.toolName,
      questions: questions.map((question) => JSON.stringify([question?.id ?? "", question?.question])),
      phase: "open",
    });
    publish(true);
  });
  pi.on("tool_result", (event, ctx) => {
    if (current(ctx)) result(event.toolCallId, event.toolName, event.details, event.isError);
  });
  pi.on("tool_execution_end", (event, ctx) => {
    // A pretool refusal or thrown execute can bypass tool_result.
    if (current(ctx)) result(event.toolCallId, event.toolName, event.result?.details, event.isError);
  });
  pi.on("turn_start", (_event, ctx) => {
    if (current(ctx) && !ctx.isIdle()) finish();
  });
  pi.on("agent_settled", (_event, ctx) => {
    if (current(ctx) && ctx.isIdle()) finish();
  });
  pi.on("session_shutdown", (_event, ctx) => {
    if (!sameOwner(ctx)) return;
    publish(false);
    owner = undefined;
    calls.clear();
  });
}

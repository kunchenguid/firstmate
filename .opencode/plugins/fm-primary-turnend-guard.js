import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

// Only the current turn of a bounded number of live sessions is ever needed, so
// every retained map is pruned rather than grown for the plugin's lifetime.
const MAX_TRACKED_SESSIONS = 32;

const skipNextIdleSessions = new Set();
const sessions = new Map();

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root, reply = {}) {
  if (!root) return Promise.resolve({ code: 0, stdout: "", stderr: "" });
  return runProcess(
    `${root}/bin/fm-turnend-guard.sh`,
    [],
    JSON.stringify({ stop_hook_active: false, ...reply }),
  );
}

function sessionState(sessionID) {
  let state = sessions.get(sessionID);
  if (!state) {
    state = { roles: new Map(), triggerID: "", triggerParts: new Map(), replyID: "", replyParts: new Map() };
    sessions.set(sessionID, state);
  }
  while (sessions.size > MAX_TRACKED_SESSIONS) {
    const oldest = sessions.keys().next().value;
    if (oldest === sessionID) break;
    sessions.delete(oldest);
  }
  return state;
}

// A single assistant message can interleave text and tool parts, so each text
// part is kept under its own key and joined in arrival order. Overwriting would
// measure only the last fragment of a split reply, and would drop the typed
// operational prefix from a split input.
function partKey(part) {
  if (typeof part.id === "string" && part.id) return part.id;
  if (typeof part.index === "number") return `index:${part.index}`;
  return "single";
}

function joinParts(parts) {
  return Array.from(parts.values()).join("");
}

function observeMessage(event) {
  const info = event.properties?.info;
  if (!info || typeof info.sessionID !== "string" || typeof info.id !== "string") return;
  if (info.role !== "user" && info.role !== "assistant") return;
  const state = sessionState(info.sessionID);
  if (info.role === "user" && state.triggerID !== info.id) {
    // A new captain input opens a new turn: drop the previous turn's retained
    // text and message roles rather than accumulating them for the session.
    state.roles.clear();
    state.triggerID = info.id;
    state.triggerParts.clear();
    state.replyID = "";
    state.replyParts.clear();
  } else if (info.role === "assistant" && state.replyID !== info.id) {
    state.replyID = info.id;
    state.replyParts.clear();
  }
  state.roles.set(info.id, info.role);
}

function observePart(event) {
  const part = event.properties?.part;
  if (!part || part.type !== "text" || typeof part.text !== "string") return;
  if (typeof part.sessionID !== "string" || typeof part.messageID !== "string") return;
  const state = sessions.get(part.sessionID);
  const role = state?.roles.get(part.messageID);
  if (role === "user") {
    state.triggerParts.set(partKey(part), part.text);
  } else if (role === "assistant") {
    if (state.replyID !== part.messageID) {
      state.replyID = part.messageID;
      state.replyParts.clear();
    }
    state.replyParts.set(partKey(part), part.text);
  }
}

function guardPayload(sessionID) {
  const state = sessions.get(sessionID);
  if (!state) return {};
  const replyText = joinParts(state.replyParts);
  if (!replyText || !state.replyID) return {};
  return {
    fm_reply_text: replyText,
    fm_reply_id: state.replyID,
    fm_trigger_text: joinParts(state.triggerParts),
    session_id: sessionID,
  };
}

// The guard's stderr carries the supervision banner plus advisory diagnostics
// that are delivered on their own channel. Only the banner belongs in a forced
// continuation, so everything else is dropped here.
function bannerOnly(stderr) {
  return (stderr ?? "")
    .split("\n")
    .filter((line) => line.startsWith("\u25cf"))
    .join("\n");
}

// The toast is a TUI rendering with no headless equivalent, so a request that
// waits for an attached TUI must never be able to hold up anything else. Every
// dispatch is bounded and its failure contained; the advisory is best-effort.
const TOAST_TIMEOUT_MS = 5000;

function withTimeout(promise, ms) {
  return new Promise((settle) => {
    const timer = setTimeout(settle, ms);
    if (typeof timer.unref === "function") timer.unref();
    Promise.resolve(promise).then(
      () => { clearTimeout(timer); settle(); },
      () => { clearTimeout(timer); settle(); },
    );
  });
}

async function showSystemMessages(client, stdout) {
  if (!stdout || !client.tui?.showToast) return;
  for (const line of stdout.split("\n")) {
    if (!line.trim()) continue;
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof parsed.systemMessage !== "string" || !parsed.systemMessage) continue;
    await withTimeout(
      (async () => client.tui.showToast({
        body: { title: "Firstmate", message: parsed.systemMessage, variant: "warning" },
      }))(),
      TOAST_TIMEOUT_MS,
    );
  }
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type === "message.updated") {
        observeMessage(event);
        return;
      }
      if (event.type === "message.part.updated") {
        observePart(event);
        return;
      }
      if (event.type !== "session.idle") return;

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (skipNextIdleSessions.delete(sessionID)) return;

      const coordinatorHandled = await letWatchArmRun(sessionID, client);
      const result = await runGuard(root, guardPayload(sessionID));

      // Supervision recovery goes first and is never gated on the advisory
      // display, which is dispatched afterwards without being awaited.
      if (!coordinatorHandled && result.code === 2) {
        try {
          const text = await encodeFirstmateOperationalInput(
            root,
            "turn-end-guard",
            "TURN WOULD END BLIND - supervision is off. " +
              "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
              bannerOnly(result.stderr),
          );
          await client.session.promptAsync({
            path: { id: sessionID },
            body: {
              parts: [{ type: "text", text }],
            },
          });
          skipNextIdleSessions.add(sessionID);
        } catch {
          skipNextIdleSessions.delete(sessionID);
        }
      }

      showSystemMessages(client, result.stdout).catch(() => {});
    },
  };
};

import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { contextDirectory, eventProperties, eventSessionID, eventType, promptSession, setupEventSubscription } from "./lib/fm-opencode2.js";

const handledSessions = new Set();

function runProcess(command, args) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stdout: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stdout }));
  });
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

export const FmPrimarySessionstartNudge = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.created") return;
      const sessionID = event.properties?.info?.id ?? event.properties?.sessionID;
      if (!sessionID || handledSessions.has(sessionID) || !root) return;
      handledSessions.add(sessionID);

      const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
      const nudge = result.code === 0 ? result.stdout.trim() : "";
      if (!nudge) return;

      try {
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text: nudge }],
          },
        });
      } catch {
      }
    },
  };
};

function installSessionstartNudge(ctx) {
  const anchor = contextDirectory(ctx);
  let rootPromise = null;
  const getRoot = () => (rootPromise ??= resolveRoot(anchor));
  setupEventSubscription(ctx, async (event) => {
    if (eventType(event) !== "session.created") return;
    const sessionID = eventSessionID(event) || eventProperties(event).info?.id;
    if (!sessionID || handledSessions.has(sessionID)) return;
    const root = await getRoot();
    if (!root) return;
    handledSessions.add(sessionID);

    const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
    const nudge = result.code === 0 ? result.stdout.trim() : "";
    if (!nudge) return;

    try {
      await promptSession(ctx, null, sessionID, nudge);
    } catch {
    }
  });
}

export default {
  id: "fm.primary.sessionstart-nudge",
  server: FmPrimarySessionstartNudge,
  setup(ctx) {
    installSessionstartNudge(ctx);
  },
};

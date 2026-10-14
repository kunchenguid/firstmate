import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

// Session-start nudge for OpenCode: on a new session in the primary checkout,
// run bin/fm-sessionstart-nudge.sh and inject its one-line instruction so the
// session runs the session-start digest before doing anything else.
// OpenCode 2 loads a local plugin only from a default export carrying an `id`
// plus `setup(ctx)`; `setup` subscribes to the server event stream with
// ctx.event.subscribe() and returns the cleanup that aborts it. V2 event
// payloads carry their fields under `data`, so a new session's id is
// event.data.sessionID. Only plugin load was verified live against OpenCode
// 2.0.28 (2026-10-13); event delivery and the prompt call are covered by
// tests/opencode-plugin-host.mjs. The server is shared across locations, so a
// session created in another location is ignored. The owner script is itself inert outside the real primary checkout and when the
// home lock is already held, so a crewmate/scout worktree or a nested session
// is never nudged.

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

async function eventDirectory(ctx, event) {
  const directory = event.location?.directory ?? event.data?.location?.directory;
  if (directory) return directory;
  try {
    const session = await ctx.session.get({ sessionID: event.data?.sessionID });
    return session?.location?.directory ?? "";
  } catch {
    return "";
  }
}

async function handleEvents(ctx, signal, handle) {
  for (;;) {
    try {
      for await (const event of ctx.event.subscribe({ signal })) {
        try {
          await handle(event);
        } catch (error) {
          console.error(`fm-primary-sessionstart-nudge: event handling failed: ${error?.stack ?? error}`);
        }
      }
      return;
    } catch (error) {
      if (signal.aborted) return;
      console.error(`fm-primary-sessionstart-nudge: event stream failed, re-subscribing: ${error?.stack ?? error}`);
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 1000));
    }
  }
}

export default {
  id: "fm-primary-sessionstart-nudge",
  async setup(ctx) {
    const root = await resolveRoot(ctx.location.directory);
    const handledSessions = new Set();
    const controller = new AbortController();

    void handleEvents(ctx, controller.signal, async (event) => {
      if (event.type !== "session.created") return;
      const sessionID = event.data?.sessionID;
      if (!sessionID || handledSessions.has(sessionID) || !root) return;
      if ((await resolveRoot(await eventDirectory(ctx, event))) !== root) return;
      handledSessions.add(sessionID);

      const result = await runProcess(`${root}/bin/fm-sessionstart-nudge.sh`, []);
      const nudge = result.code === 0 ? result.stdout.trim() : "";
      if (!nudge) return;

      try {
        await ctx.session.prompt({ sessionID, text: nudge });
      } catch {
      }
    });

    return () => controller.abort();
  },
};

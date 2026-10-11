import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

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

// OpenCode v2 default export. The v2 loader requires `{ id, setup(ctx) }`, v2
// events arrive from `ctx.event.subscribe()`, and a follow-up turn is forced
// with `ctx.session.prompt`. The v1 hook object above is reused through a
// `client` shim so both APIs share one implementation.
function clientFromCtx(ctx) {
  return {
    session: {
      promptAsync: ({ path, body }) =>
        ctx.session.prompt({ sessionID: path?.id, text: body?.parts?.[0]?.text ?? "" }),
    },
  };
}

export default {
  id: "fm-primary-sessionstart-nudge",
  async setup(ctx) {
    const hooks = await FmPrimarySessionstartNudge({
      client: clientFromCtx(ctx),
      directory: ctx.location?.directory,
    });
    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        // v2 events carry their payload under `data`; the v1 hooks read `properties`.
        try {
          await hooks.event({ event: { type: event.type, properties: event.data } });
        } catch {}
      }
    })().catch(() => {});
    return () => controller.abort();
  },
};

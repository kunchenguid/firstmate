import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

let skipNextIdle = false;

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

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
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
      if (event.type !== "session.idle") return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (await letWatchArmRun(sessionID, client)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
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

// v2 events carry their payload under `data`; the v1 hooks read `properties`.
// v2 publishes no `session.idle`: a turn ends with a terminal
// `session.execution.*` event, which is mapped onto the v1 idle event.
const V2_TURN_END = ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"];
function v1Event(event) {
  const properties = event.data ?? {};
  if (V2_TURN_END.includes(event.type)) return { type: "session.idle", properties };
  return { type: event.type, properties };
}

export default {
  id: "fm-primary-turnend-guard",
  async setup(ctx) {
    const hooks = await FmPrimaryTurnendGuard({
      client: clientFromCtx(ctx),
      directory: ctx.location?.directory,
    });
    const controller = new AbortController();
    void (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
        try {
          await hooks.event({ event: v1Event(event) });
        } catch {}
      }
    })().catch(() => {});
    return () => controller.abort();
  },
};

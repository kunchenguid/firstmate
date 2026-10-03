import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// The OpenCode shell tool is `bash` on the v1 hook API and `shell` on the v2
// hook API; the same command-guard owner handles both.
const SHELL_TOOL_NAMES = new Set(["bash", "shell"]);

// PreToolUse seatbelt for OpenCode: block a stray persistent top-level `cd` in
// the primary firstmate checkout before the agent's bash tool relocates the
// shell out of the home (see bin/fm-cd-pretool-check.sh and docs/cd-guard.md).
// This mirrors fm-primary-pretool-check.js, calling the cd-guard owner instead
// of the watcher-arm one. tool.execute.before can block by throwing (verified
// 2026-07-09 against OpenCode 1.17.15 for the watcher-arm plugin; the same
// mechanism carries this guard). The owner script is itself inert outside the
// real primary checkout, so a crewmate/scout worktree is never affected.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryCdCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || !SHELL_TOOL_NAMES.has(input?.tool)) return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${root}/bin/fm-cd-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};

// OpenCode v2 default export: the loader requires `{ id, setup(ctx) }` and the
// v2 `ctx.tool.hook("execute.before", event)` event carrying `event.tool` and
// `event.input`, so it is adapted onto the shared v1 hook object above.
export default {
  id: "fm-primary-cd-check",
  async setup(ctx) {
    const hooks = await FmPrimaryCdCheck({ directory: ctx.location?.directory });
    await ctx.tool.hook("execute.before", (event) =>
      hooks["tool.execute.before"]({ tool: event?.tool }, { args: event?.input ?? {} }),
    );
  },
};

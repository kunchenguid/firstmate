import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// The OpenCode shell tool is `bash` on the v1 hook API and `shell` on the v2
// hook API; the same command-guard owner handles both.
const SHELL_TOOL_NAMES = new Set(["bash", "shell"]);

// PreToolUse seatbelt for OpenCode: the arm mechanism itself lives entirely in
// fm-primary-watch-arm.js (a plugin-owned child process, never a model tool
// call), so the residual risk here is the AGENT shelling `bin/fm-watch-arm.sh`
// wrong through its own bash tool - the anti-pattern bin/fm-arm-pretool-check.sh
// guards against (see that script's header and docs/arm-pretool-check.md).
// tool.execute.before can block by throwing (verified 2026-07-09 against
// OpenCode 1.17.15: throwing here prevents the bash command from running and
// surfaces the thrown message as the failed tool result).

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

export const FmPrimaryPretoolCheck = async ({ directory, worktree }) => {
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

      const result = await runProcess(`${root}/bin/fm-arm-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};

// OpenCode v2 default export: the loader requires `{ id, setup(ctx) }` and the
// v2 `ctx.tool.hook("execute.before", event)` event carrying `event.tool` and
// `event.input`, so it is adapted onto the shared v1 hook object above.
export default {
  id: "fm-primary-pretool-check",
  async setup(ctx) {
    const hooks = await FmPrimaryPretoolCheck({ directory: ctx.location?.directory });
    await ctx.tool.hook("execute.before", (event) =>
      hooks["tool.execute.before"]({ tool: event?.tool }, { args: event?.input ?? {} }),
    );
  },
};

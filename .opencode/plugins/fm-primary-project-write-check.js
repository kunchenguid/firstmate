import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// Primary-session project-write seatbelt for OpenCode. The shared policy owns
// classification; this plugin forwards every tool's input so shell commands
// and native file edits use the same decision.

function runProcess(command, args, input = "") {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["pipe", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await new Promise((resolvePromise) => {
    const child = spawn("git", ["-C", anchor, "rev-parse", "--show-toplevel"], { stdio: ["ignore", "pipe", "ignore"] });
    let stdout = "";
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.on("error", () => resolvePromise({ code: 1, stdout: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 1, stdout }));
  });
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryProjectWriteCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || !input?.tool) return;
      const payload = JSON.stringify({ tool_name: input.tool, tool_input: output?.args || {} });
      const result = await runProcess(`${root}/bin/fm-project-write-pretool-check.sh`, [], payload);
      if (result.code !== 2) return;
      throw new Error(result.stderr.trim() || "denied by the project-write PreToolUse guard");
    },
  };
};

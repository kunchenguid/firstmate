import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// OpenCode adapter for the decision gate owned by
// bin/fm-decision-pretool-check.sh and docs/decision-pretool-check.md.
// Exact tool identity is the only policy input.

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
  if (result.code === 0) {
    const root = result.stdout.trim();
    if (root) return root;
  }
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryDecisionCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input) => {
      if (!root || input?.tool !== "question") return;
      const result = await runProcess(`${root}/bin/fm-decision-pretool-check.sh`, ["--tool-name", input.tool]);
      if (result.code !== 2) return;
      throw new Error(result.stderr.trim() || "built-in structured questions are disabled; use Lavish or plain chat");
    },
  };
};

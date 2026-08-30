import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: block Jala direct project writes.
// See bin/fm-selfdo-pretool-check.sh and bin/fm-selfdo-policy.mjs.
// Inert outside real primary checkout so workers in worktrees can write.

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

export const FmPrimarySelfdoCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root) return;
      const tool = input?.tool ?? "";
      // Check path-based tools (edit, write, etc.)
      const pathCandidate = output?.args?.path || output?.args?.file_path || output?.args?.filePath || output?.args?.file || "";
      if (typeof pathCandidate === "string" && pathCandidate) {
        const result = await runProcess(`${root}/bin/fm-selfdo-pretool-check.sh`, ["--path", pathCandidate]);
        if (result.code === 2) {
          const reason = result.stderr.trim() || "denied by the selfdo-guard PreToolUse seatbelt";
          throw new Error(reason);
        }
      }
      // Check bash command
      if (tool === "bash") {
        const command = output?.args?.command;
        if (!command || typeof command !== "string") return;
        const result = await runProcess(`${root}/bin/fm-selfdo-pretool-check.sh`, ["--command", command]);
        if (result.code !== 2) return;
        const reason = result.stderr.trim() || "denied by the selfdo-guard PreToolUse seatbelt";
        throw new Error(reason);
      }
      // For edit/write tools, also check if still not caught (tool name heuristic)
      if (["edit", "write", "apply_patch"].includes(tool) && typeof pathCandidate === "string" && pathCandidate.includes("projects/")) {
        const result = await runProcess(`${root}/bin/fm-selfdo-pretool-check.sh`, ["--path", pathCandidate]);
        if (result.code === 2) {
          const reason = result.stderr.trim() || "denied by the selfdo-guard PreToolUse seatbelt";
          throw new Error(reason);
        }
      }
    },
  };
};

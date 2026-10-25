import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: deny the structured question picker in a
// primary or secondmate session. The name list and the scope check live in
// bin/fm-question-tool-pretool-check.sh. This gate only skips the process for
// unrelated tools. tool.execute.before blocks by throwing, the same mechanism
// the cd-guard plugin uses. The owner script is inert outside a real primary
// home, so a worker copy is never affected.

const PICKER = new Set([
  "askuserquestion",
  "question",
  "functionsrequestuserinput",
]);

function normalize(name) {
  return String(name || "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

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

export const FmPrimaryQuestionTool = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input) => {
      if (!root || !PICKER.has(normalize(input?.tool))) return;

      const result = await runProcess(`${root}/bin/fm-question-tool-pretool-check.sh`, [
        "--tool",
        String(input.tool),
      ]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the question-picker PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};

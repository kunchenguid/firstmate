import { spawn } from "node:child_process";

// The shell predicate owns primary-home detection so tracked adapters cannot
// drift into treating a linked task worktree as a primary session.
export function fmPrimaryScopeMatches(root, state) {
  return new Promise((resolve) => {
    const child = spawn("bash", [`${root}/bin/fm-primary-scope.sh`, "--root", root, "--state", state], {
      stdio: "ignore",
    });
    child.on("error", () => resolve(false));
    child.on("close", (code) => resolve(code === 0));
  });
}

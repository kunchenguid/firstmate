import { spawnSync } from "node:child_process";

// The shell predicate owns primary-home detection so tracked adapters cannot
// drift into treating a linked task worktree as a primary session.
export function fmPrimaryScopeMatches(root: string, state: string): boolean {
  const result = spawnSync("bash", [`${root}/bin/fm-primary-scope.sh`, "--root", root, "--state", state], {
    encoding: "utf8",
  });
  return result.status === 0;
}

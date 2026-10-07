// PreToolUse seatbelt for OpenCode: block a stray persistent top-level `cd` in
// the primary firstmate checkout before the agent's shell tool relocates the
// shell out of the home (see bin/fm-cd-pretool-check.sh and docs/cd-guard.md).
// This mirrors fm-primary-pretool-check.js, calling the cd-guard owner instead
// of the watcher-arm one. Throwing from the pre-execution hook blocks the call
// and surfaces the thrown message as the failed tool result (verified
// 2026-09-30 against OpenCode 2.0.20: the denied call produced
// session.tool.failed carrying the thrown text and never ran). The owner script
// is itself inert outside the real primary checkout, so a crewmate/scout
// worktree is never affected.
//
// OpenCode 2 changed this hook's contract, so the shape below is re-derived
// rather than transliterated. `execute.before` is registered on the tool domain
// and receives ONE owned event instead of the v1 (input, output) pair: the tool
// name is `event.tool` and the parsed arguments are `event.input`, so the v1
// `output.args.command` is now `event.input.command`. The polled tool name
// changed too - see SHELL_TOOL in lib/fm-opencode-contract.js.

import { SHELL_TOOL, resolvePluginRoot, runProcess } from "./lib/fm-opencode-contract.js";

export default {
  id: "firstmate.primary.cd-check",
  async setup(ctx) {
    const root = await resolvePluginRoot(ctx);
    if (!root) return;

    await ctx.tool.hook("execute.before", async (event) => {
      if (event?.tool !== SHELL_TOOL) return;
      const command = event.input?.command;
      if (typeof command !== "string" || !command) return;

      const result = await runProcess(`${root}/bin/fm-cd-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt";
      throw new Error(reason);
    });
  },
};

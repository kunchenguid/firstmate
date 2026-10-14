// PreToolUse seatbelt for OpenCode: the arm mechanism itself lives entirely in
// fm-primary-watch-arm.js (a plugin-owned child process, never a model tool
// call), so the residual risk here is the AGENT shelling `bin/fm-watch-arm.sh`
// wrong through its own shell tool - the anti-pattern
// bin/fm-arm-pretool-check.sh guards against (see that script's header and
// docs/arm-pretool-check.md).
//
// OpenCode 2 changed this hook's contract, so the shape below is re-derived
// rather than transliterated, because a wrong port of a seatbelt leaves it
// installed and inert. `execute.before` is registered on the tool domain and
// receives ONE owned event instead of the v1 (input, output) pair: the tool name
// is `event.tool` and the parsed arguments are `event.input`, so the v1
// `output.args.command` is now `event.input.command`. The polled tool name
// changed too - see SHELL_TOOL in lib/fm-opencode-contract.js. Throwing from
// this callback blocks the call and surfaces the thrown message as the failed
// tool result (verified 2026-09-30 against OpenCode 2.0.20: the denied call
// produced session.tool.failed carrying the thrown text and never ran).

import { SHELL_TOOL, resolvePluginRoot, runProcess } from "./lib/fm-opencode-contract.js";

export default {
  id: "firstmate.primary.pretool-check",
  async setup(ctx) {
    const root = await resolvePluginRoot(ctx);
    if (!root) return;

    await ctx.tool.hook("execute.before", async (event) => {
      if (event?.tool !== SHELL_TOOL) return;
      const command = event.input?.command;
      if (typeof command !== "string" || !command) return;

      const result = await runProcess(`${root}/bin/fm-arm-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt";
      throw new Error(reason);
    });
  },
};

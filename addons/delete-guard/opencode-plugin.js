// Fleet delete guard for OpenCode (installed by firstmate-addons delete-guard/install.sh); throwing stops the bash call.
import { guard } from "__GUARD__";

export const FmDeleteGuard = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (input?.tool !== "bash") return;
    const reason = guard(output?.args?.command, { cwd: output?.args?.workdir || directory, runtime: "opencode" });
    if (reason !== null) throw new Error(reason);
  },
});

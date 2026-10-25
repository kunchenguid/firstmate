// Fleet kill guard for OpenCode (installed by firstmate-addons kill-guard/install.sh); throwing stops the bash call.
import { guard } from "__GUARD__";

export const FmKillGuard = async () => ({
  "tool.execute.before": async (input, output) => {
    if (input?.tool !== "bash") return;
    const reason = guard(output?.args?.command);
    if (reason !== null) throw new Error(reason);
  },
});

import { guardTool } from "__GUARD__";

export const FmReadGuard = async () => ({
  "tool.execute.before": async (input, output) => {
    const reason = guardTool(input?.tool, output?.args ?? {});
    if (reason) throw new Error(reason);
  },
});

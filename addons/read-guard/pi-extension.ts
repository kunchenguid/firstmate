import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { guardTool } from "__GUARD__";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event) => {
    const reason = guardTool(event.toolName, event.input);
    return reason ? { block: true, reason } : undefined;
  });
}

// Firstmate's Pi footer meter for remaining Rippling personal LLM-gateway budget.
//
// Uses a dedicated setStatus key so it does not share Calm's firstmate-calm slot.
// bin/fm-llm-budget.sh owns the cache, query, and printed line. This adapter only
// decides whether the active Pi provider is a Rippling gateway family and then
// calls that command. docs/llm-budget.md points here and at the command header.
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionUIContext } from "@earendil-works/pi-coding-agent";

export const LLM_BUDGET_STATUS_KEY = "firstmate-llm-budget";

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const budgetCommand = resolve(root, "bin/fm-llm-budget.sh");

type GatewayModel = {
  provider?: string;
  id?: string;
};

export function isRipplingGatewayModel(
  model: GatewayModel | null | undefined,
): boolean {
  const provider = (model?.provider || "").toLowerCase();
  const id = (model?.id || "").toLowerCase();
  if (provider === "rippling-bedrock" || provider === "rippling-openai") return true;
  if (provider.startsWith("rippling-")) return true;
  if (id.startsWith("rippling-")) return true;
  return false;
}

function applyMeter(ui: ExtensionUIContext, model: GatewayModel | null | undefined): void {
  if (!isRipplingGatewayModel(model)) {
    ui.setStatus(LLM_BUDGET_STATUS_KEY, undefined);
    return;
  }
  const result = spawnSync(
    budgetCommand,
    [
      "print",
      "--if-gateway",
      "--kick-refresh",
      "--provider",
      model?.provider || "",
      "--model",
      model?.id || "",
    ],
    {
      encoding: "utf8",
      timeout: 1500,
      env: process.env,
    },
  );
  const line = (result.stdout || "").trim();
  ui.setStatus(LLM_BUDGET_STATUS_KEY, line || undefined);
}

export default function (pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    applyMeter(ctx.ui, ctx.model);
  });
  pi.on("model_select", (event, ctx) => {
    applyMeter(ctx.ui, event.model);
  });
  pi.on("turn_start", (_event, ctx) => {
    applyMeter(ctx.ui, ctx.model);
  });
}

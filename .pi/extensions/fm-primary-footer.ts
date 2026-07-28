import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { formatFooterLines, type FooterData } from "./lib/fm-primary-footer-layout.ts";

const shortNumber = (value: number): string =>
  value < 1000 ? String(value) : `${(value / 1000).toFixed(value < 10000 ? 1 : 0)}k`;

const projectName = (cwd: string): string => cwd.split(/[\\/]/).filter(Boolean).pop() || cwd;

type SessionEntries = ReturnType<ExtensionContext["sessionManager"]["getEntries"]>;

export const aggregateSessionUsage = (entries: SessionEntries): { input: number; output: number; cost: number } => {
  let input = 0;
  let output = 0;
  let cost = 0;
  for (const entry of entries) {
    let usage;
    if (entry.type === "message" && entry.message.role === "assistant") {
      usage = entry.message.usage;
    } else if (entry.type === "message" && entry.message.role === "toolResult") {
      usage = entry.message.usage;
    } else if (entry.type === "branch_summary" || entry.type === "compaction") {
      usage = entry.usage;
    }
    if (!usage) continue;
    input += usage.input;
    output += usage.output;
    cost += usage.cost.total;
  }
  return { input, output, cost };
};

export default function (pi: ExtensionAPI) {
  let requestRender: (() => void) | undefined;
  let currentBranch = "";
  let currentContext: ExtensionContext | undefined;
  let refreshTitleOnNextRender = false;

  const refreshTitle = (ctx: typeof currentContext): void => {
    if (!ctx) return;
    const model = ctx.model?.id || "no-model";
    const branch = currentBranch || "no-branch";
    ctx.ui.setTitle(`Firstmate · ${projectName(ctx.cwd)} · ${branch} · ${model}`);
  };

  const stats = (ctx: NonNullable<typeof currentContext>): FooterData => {
    const totals = aggregateSessionUsage(ctx.sessionManager.getEntries());
    const usage = ctx.getContextUsage();
    return {
      state: ctx.isIdle() ? "idle" : "running",
      model: ctx.model?.id || "no-model",
      thinking: ctx.thinkingLevel || "off",
      project: projectName(ctx.cwd),
      branch: currentBranch,
      context: usage?.tokens == null ? "?" : `${shortNumber(usage.tokens)}${usage.percent == null ? "" : ` (${Math.round(usage.percent)}%)`}`,
      input: shortNumber(totals.input),
      output: shortNumber(totals.output),
      cost: totals.cost.toFixed(3),
      statuses: [],
    };
  };

  const redraw = (_event: unknown, ctx: ExtensionContext) => {
    currentContext = ctx;
    refreshTitle(ctx);
    requestRender?.();
  };
  pi.on("agent_start", redraw);
  pi.on("agent_end", redraw);
  pi.on("agent_settled", redraw);
  pi.on("message_update", redraw);
  pi.on("message_end", redraw);
  pi.on("model_select", redraw);
  pi.on("thinking_level_select", redraw);
  pi.on("session_info_changed", redraw);

  pi.on("session_start", (_event, ctx) => {
    currentContext = ctx;
    ctx.ui.setTheme("firstmate-dark");
    ctx.ui.setFooter((tui, theme, footerData) => {
      currentBranch = footerData.getGitBranch() || "";
      const unsubscribe = footerData.onBranchChange(() => {
        currentBranch = footerData.getGitBranch() || "";
        refreshTitle(currentContext);
        tui.requestRender();
      });
      requestRender = () => tui.requestRender();
      refreshTitleOnNextRender = true;
      return {
        dispose() {
          unsubscribe();
          requestRender = undefined;
          refreshTitleOnNextRender = false;
        },
        invalidate() {},
        render(width: number) {
          if (refreshTitleOnNextRender) {
            refreshTitleOnNextRender = false;
            refreshTitle(ctx);
          }
          const data = stats(ctx);
          data.statuses = [...footerData.getExtensionStatuses()].map(([key, value]) => ({ key, value }));
          return formatFooterLines(data, width, theme);
        },
      };
    });
  });
}

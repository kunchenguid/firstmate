// Replace Pi's abbreviation-heavy footer with labelled session metrics in trusted Firstmate TUIs.
import { homedir } from "node:os";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { Usage } from "@earendil-works/pi-ai";
import {
  SettingsManager,
  type ExtensionAPI,
  type SessionEntry,
} from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export interface UsageTotals {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
  latestCacheHit?: number;
}

export interface FooterValues extends UsageTotals {
  cwd: string;
  branch?: string | null;
  sessionName?: string;
  model?: string;
  contextWindow?: number;
  contextPercent?: number | null;
  subscription: boolean;
  automaticCompaction: boolean;
  statuses?: readonly string[];
}

type FooterTheme = {
  fg(color: "dim" | "error" | "warning", text: string): string;
};

export function formatTokens(count: number): string {
  if (count < 1_000) return String(count);
  if (count < 10_000) return `${(count / 1_000).toFixed(1)}k`;
  if (count < 1_000_000) return `${Math.round(count / 1_000)}k`;
  if (count < 10_000_000) return `${(count / 1_000_000).toFixed(1)}M`;
  return `${Math.round(count / 1_000_000)}M`;
}

function addUsage(totals: UsageTotals, usage: Usage): void {
  totals.input += usage.input;
  totals.output += usage.output;
  totals.cacheRead += usage.cacheRead;
  totals.cacheWrite += usage.cacheWrite;
  totals.cost += usage.cost.total;
}

export function aggregateUsage(entries: readonly SessionEntry[]): UsageTotals {
  const totals: UsageTotals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
  for (const entry of entries) {
    if (entry.type === "message" && entry.message.role === "assistant") {
      const usage = entry.message.usage;
      addUsage(totals, usage);
      const promptTokens = usage.input + usage.cacheRead + usage.cacheWrite;
      totals.latestCacheHit = promptTokens > 0 ? (usage.cacheRead / promptTokens) * 100 : undefined;
    } else if (entry.type === "message" && entry.message.role === "toolResult" && entry.message.usage) {
      addUsage(totals, entry.message.usage);
    } else if ((entry.type === "branch_summary" || entry.type === "compaction") && entry.usage) {
      addUsage(totals, entry.usage);
    }
  }
  return totals;
}

function displayCwd(cwd: string): string {
  const home = homedir();
  const relativeToHome = relative(resolve(home), resolve(cwd));
  return relativeToHome === ""
    ? "~"
    : relativeToHome !== ".." && !relativeToHome.startsWith(`..${sep}`) && !isAbsolute(relativeToHome)
      ? `~${sep}${relativeToHome}`
      : cwd;
}

function align(left: string, right: string, width: number): string {
  if (width <= 0) return "";
  const gap = width - visibleWidth(left) - visibleWidth(right);
  if (gap >= 2) return left + " ".repeat(gap) + right;
  return truncateToWidth(left, width, "...");
}

function sanitizeStatus(text: string): string {
  return text.replace(/[\r\n\t]/g, " ").replace(/ +/g, " ").trim();
}

export function renderFooter(values: FooterValues, width: number, theme: FooterTheme): string[] {
  if (width <= 0) return [];
  const location = [
    `Directory ${displayCwd(values.cwd)}${values.branch ? ` (${values.branch})` : ""}`,
    values.sessionName ? `Session ${values.sessionName}` : undefined,
  ].filter(Boolean).join(" • ");
  const identity = values.model ? `Model ${values.model}` : "Model unavailable";

  const contextAmount = values.contextPercent == null
    ? `unknown of ${formatTokens(values.contextWindow ?? 0)}`
    : `${values.contextPercent.toFixed(1)}% of ${formatTokens(values.contextWindow ?? 0)}`;
  const contextSuffix = values.automaticCompaction ? " (automatic compaction)" : "";
  const context = `Context ${contextAmount}${contextSuffix}`;
  const shown = [
    values.input ? { key: "input", part: `Input ${formatTokens(values.input)}` } : undefined,
    values.output ? { key: "output", part: `Output ${formatTokens(values.output)}` } : undefined,
    values.cacheRead ? { key: "cacheRead", part: `Cache read ${formatTokens(values.cacheRead)}` } : undefined,
    values.cacheWrite ? { key: "cacheWrite", part: `Cache write ${formatTokens(values.cacheWrite)}` } : undefined,
    values.latestCacheHit !== undefined ? { key: "cacheHit", part: `Cache hit ${values.latestCacheHit.toFixed(1)}%` } : undefined,
    values.cost || values.subscription
      ? { key: "cost", part: `Cost $${values.cost.toFixed(3)} (${values.subscription ? "subscription" : "metered usage"})` }
      : undefined,
    { key: "context", part: context },
  ].filter((item): item is { key: string; part: string } => Boolean(item));

  const removable = ["cacheWrite", "cacheHit", "cacheRead", "cost", "output", "input"];
  while (visibleWidth(shown.map(({ part }) => part).join(" • ")) > width && removable.length) {
    const key = removable.shift();
    const found = shown.findIndex((item) => item.key === key);
    if (found >= 0) shown.splice(found, 1);
  }
  const metricText = truncateToWidth(shown.map(({ part }) => part).join(" • "), width, "...");
  const contextPercent = values.contextPercent ?? 0;
  const metricColor = contextPercent > 90 ? "error" : contextPercent > 70 ? "warning" : "dim";
  const lines = [
    theme.fg("dim", align(location, identity, width)),
    theme.fg(metricColor, metricText),
  ];

  if (values.statuses?.length) {
    lines.push(truncateToWidth(values.statuses.map(sanitizeStatus).join(" "), width, "..."));
  }
  return lines;
}

export default function (pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui" || !ctx.isProjectTrusted()) return;
    const automaticCompaction = SettingsManager.create(ctx.cwd).getCompactionEnabled();
    ctx.ui.setFooter((tui, theme, footerData) => ({
      dispose: footerData.onBranchChange(() => tui.requestRender()),
      invalidate() {},
      render(width: number): string[] {
        const usage = aggregateUsage(ctx.sessionManager.getEntries());
        const context = ctx.getContextUsage();
        const model = ctx.model;
        return renderFooter({
          ...usage,
          cwd: ctx.sessionManager.getCwd(),
          branch: footerData.getGitBranch(),
          sessionName: ctx.sessionManager.getSessionName(),
          model: model?.id,
          contextWindow: context?.contextWindow ?? model?.contextWindow,
          contextPercent: context?.percent,
          subscription: Boolean(model && (model.provider === "kimi-coding" || ctx.modelRegistry.isUsingOAuth(model))),
          automaticCompaction,
          statuses: [...footerData.getExtensionStatuses().values()],
        }, width, theme);
      },
    }));
  });
}

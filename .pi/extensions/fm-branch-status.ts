// Read-only Pi TUI activity, fed by existing branch/watcher lifecycle boundaries.
// /supervision-status toggles detail; no queue, lease, session or model mutation.
import { open } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";
import { BranchActivity, ACTIVITY_STALE_MS, type ActivityHealth, type ActivityRow } from "./lib/fm-branch-activity.ts";
import { BRANCH_ACTIVITY_EVENT, BRANCH_HEALTH_EVENT, BRANCH_HEALTH_REQUEST, BRANCH_ROUTING_TRACE_FILE } from "./lib/fm-branch-dispatch.ts";
const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const state = process.env.FM_STATE_OVERRIDE || `${process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root}/state`;

export default function branchStatus(pi: ExtensionAPI) {
  let model = new BranchActivity();
  let context: ExtensionContext | null = null;
  let detail = false;
  let revision = 0;
  let refresh: ReturnType<typeof setTimeout> | undefined;
  let stale: ReturnType<typeof setTimeout> | undefined;
  let subscriptions: Array<() => void> = [];
  const paint = () => {
    refresh = undefined;
    const ctx = context;
    if (!ctx || ctx.mode !== "tui") return;
    ctx.ui.setWidget("fm-branch-status", (_tui, theme) => ({
      invalidate() {},
      render(width) {
        const view = model.view();
        const color = view.state === "error" ? "error" : ["unknown", "degraded"].includes(view.state) ? "warning" : "muted";
        return (detail ? view.lines : view.lines.slice(0, 1)).map((line) => truncateToWidth(theme.fg(color, line), width));
      },
    }));
    if (stale) clearTimeout(stale);
    const observed = Math.max(model.health?.time ?? 0, model.pulseAt);
    const remaining = ACTIVITY_STALE_MS - (Date.now() - observed);
    // One expiry notification, never a polling loop or history rescan.
    if (remaining >= 0) { stale = setTimeout(paint, remaining + 1); stale.unref?.(); }
  };
  const schedule = () => {
    if (!context || refresh) return;
    refresh = setTimeout(paint, 100);
    refresh.unref?.();
  };
  const dispose = () => {
    revision += 1;
    if (refresh) clearTimeout(refresh);
    if (stale) clearTimeout(stale);
    refresh = stale = undefined;
    for (const unsubscribe of subscriptions) unsubscribe();
    subscriptions = [];
    context?.ui.setWidget("fm-branch-status", undefined);
    context = null;
  };
  pi.on("session_start", async (_event, ctx) => {
    dispose();
    if (ctx.mode !== "tui") return;
    context = ctx;
    model = new BranchActivity();
    const current = revision;
    // One bounded asynchronous tail on start. No transcript, outcome bodies,
    // process sweep, shell command, full-history read or persistent write.
    try {
      const file = await open(`${state}/${BRANCH_ROUTING_TRACE_FILE}`, "r");
      try {
        const size = (await file.stat()).size;
        const bytes = Buffer.alloc(Math.min(size, 256 * 1024));
        const { bytesRead } = await file.read(bytes, 0, bytes.length, Math.max(0, size - bytes.length));
        if (current !== revision) return;
        const lines = bytes.subarray(0, bytesRead).toString("utf8").split("\n");
        if (size > bytes.length) lines.shift();
        for (const line of lines.slice(-200)) { try { model.observe(JSON.parse(line), true); } catch {} }
      } finally { await file.close(); }
    } catch { /* Missing/unreadable history is explicitly result-unknown. */ }
    if (current !== revision) return;
    subscriptions = [
      pi.events.on(BRANCH_ACTIVITY_EVENT, (row: unknown) => { model.observe(row as ActivityRow); schedule(); }),
      pi.events.on(BRANCH_HEALTH_EVENT, (value: unknown) => { model.observeHealth(value as ActivityHealth); schedule(); }),
    ];
    pi.events.emit(BRANCH_HEALTH_REQUEST, {});
    schedule();
  });
  pi.on("session_shutdown", dispose);
  pi.registerCommand("supervision-status", {
    description: "Show/hide read-only branch activity and refresh its health observation.",
    handler: async (_args, ctx) => {
      if (ctx.mode !== "tui" || !context) return;
      detail = !detail;
      pi.events.emit(BRANCH_HEALTH_REQUEST, {});
      schedule();
    },
  });
}

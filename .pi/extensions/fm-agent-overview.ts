// Read-only overview and guarded task actions for Firstmate's Pi primary.
// Current activity and keyed waits come from fm-fleet-snapshot's structured
// contract; this extension never scrapes worker terminals or status history.
import type { ExtensionAPI, ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import {
  Container,
  matchesKey,
  SelectList,
  stripTerminalSequences,
  Text,
  type Component,
  type TuiMouseEvent,
  type TuiMouseEventResult,
  type TUI,
} from "@earendil-works/pi-tui";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { runCommandAsync } from "./lib/fm-async-exec.ts";

type OpenDecision = {
  key: string;
  verb: string;
  summary: string;
};

type AgentRecord = {
  id: string;
  kind?: string;
  project?: string;
  spawn_gen?: string | null;
  remote?: { host?: string | null } | null;
  current_state?: {
    state?: string;
    source?: string;
    detail?: string;
  };
  hints?: {
    open_decisions?: OpenDecision[];
  };
  pr?: { url?: string | null };
  paths?: { report?: { path?: string | null; present?: boolean } };
};

type FleetSnapshot = {
  schema: "fm-agent-overview.v1";
  generated?: string;
  tasks: AgentRecord[];
};

type AgentAction = { kind: "message"; key?: string } | { kind: "back" };

const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const fmRoot = process.env.FM_ROOT_OVERRIDE || extensionRoot;
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || extensionRoot;
const fleetSnapshotScript = join(fmRoot, "bin", "fm-fleet-snapshot.sh");
const sendScript = join(fmRoot, "bin", "fm-send.sh");
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const MAX_VISIBLE_WAITS = 4;
const MAX_LIST_ROWS = 10;
const MAX_ACTION_ROWS = 8;

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function cleanText(value: unknown, limit = 240): string {
  if (typeof value !== "string") return "";
  const plain = stripTerminalSequences(value)
    .replace(/[\u0000-\u001f\u007f-\u009f]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
  return plain.length > limit ? `${plain.slice(0, Math.max(0, limit - 1))}…` : plain;
}

function taskDecisions(task: AgentRecord): OpenDecision[] {
  return (task.hints?.open_decisions ?? []).filter((decision) =>
    typeof decision.key === "string" &&
    typeof decision.verb === "string" &&
    typeof decision.summary === "string",
  );
}

function taskState(task: AgentRecord): string {
  return cleanText(task.current_state?.state || "unknown", 40).toLowerCase();
}

function taskActivity(task: AgentRecord): string {
  const state = taskState(task);
  const detail = cleanText(task.current_state?.detail, 100);
  const decisions = taskDecisions(task);
  const result = state === "done"
    ? cleanText(task.pr?.url || (task.paths?.report?.present ? "report ready" : ""), 100)
    : "";
  const wait = decisions[0]
    ? `${cleanText(decisions[0].verb, 32)}: ${cleanText(decisions[0].summary, 72)}`
    : "";
  const parts = [state, detail || result, wait];
  if (decisions.length > 1) parts.push(`+${decisions.length - 1} more waits`);
  return parts.filter(Boolean).join(" · ");
}

function orderedTasks(tasks: AgentRecord[]): AgentRecord[] {
  const priority = (task: AgentRecord): number => {
    const state = taskState(task);
    if (taskDecisions(task).length > 0) return 0;
    if (state === "working") return 1;
    if (state === "parked" || state === "paused" || state === "blocked") return 2;
    if (state === "unknown") return 3;
    return 4;
  };
  return [...tasks].sort((left, right) =>
    priority(left) - priority(right) || left.id.localeCompare(right.id),
  );
}

async function loadSnapshot(): Promise<FleetSnapshot> {
  const result = await runCommandAsync(fleetSnapshotScript, ["--agent-overview"], {
    env: {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
    },
    maxBuffer: MAX_OUTPUT_BYTES,
  });
  if (result.status !== 0) {
    const error = cleanText(result.stderr || "fleet snapshot command failed", 300);
    throw new Error(error);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    throw new Error("fleet snapshot returned invalid JSON");
  }
  const snapshot = asRecord(parsed);
  if (snapshot?.schema !== "fm-agent-overview.v1" || !Array.isArray(snapshot.tasks)) {
    throw new Error("fleet snapshot returned an unsupported record");
  }
  const tasks: AgentRecord[] = [];
  const ids = new Set<string>();
  for (const value of snapshot.tasks) {
    const task = asRecord(value);
    if (typeof task?.id !== "string" || asRecord(task.current_state) === null) {
      throw new Error("fleet overview contains a malformed agent record");
    }
    if (ids.has(task.id)) throw new Error("fleet overview contains duplicate agent ids");
    ids.add(task.id);
    tasks.push(task as unknown as AgentRecord);
  }
  return {
    schema: "fm-agent-overview.v1",
    generated: typeof snapshot.generated === "string" ? snapshot.generated : undefined,
    tasks: orderedTasks(tasks),
  };
}

function listTheme(theme: Theme) {
  return {
    selectedPrefix: (text: string) => theme.fg("accent", text),
    selectedText: (text: string) => theme.fg("accent", text),
    description: (text: string) => theme.fg("muted", text),
    scrollInfo: (text: string) => theme.fg("dim", text),
    noMatch: (text: string) => theme.fg("dim", text),
  };
}

function selectItems(tasks: AgentRecord[]) {
  return tasks.map((task) => ({
    value: task.id,
    label: `${cleanText(task.id, 56)}  ${taskState(task)}`,
    description: taskActivity(task),
  }));
}

function footerText(theme: Theme): string {
  return theme.fg("dim", "↑↓ navigate · Enter open · r refresh · Esc close · click rows in fullscreen");
}

class AgentOverviewPanel implements Component {
  private container = new Container();
  private list: SelectList | null = null;
  private tasks: AgentRecord[] = [];
  private loading = true;
  private error = "";
  private disposed = false;
  private refreshGeneration = 0;

  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly keybindings: { matches(data: string, action: string): boolean };
  private readonly done: (task: AgentRecord | null) => void;

  constructor(
    tui: TUI,
    theme: Theme,
    keybindings: { matches(data: string, action: string): boolean },
    done: (task: AgentRecord | null) => void,
  ) {
    this.tui = tui;
    this.theme = theme;
    this.keybindings = keybindings;
    this.done = done;
    this.rebuild();
    void this.refresh();
  }

  private rebuild(): void {
    this.container = new Container();
    this.list = null;
    const title = this.theme.fg("accent", this.theme.bold("Firstmate agents"));
    this.container.addChild(new Text(title, 1, 0));
    this.container.addChild(new Text(
      this.loading ? this.theme.fg("muted", "Reading current agent activity…") :
        this.error ? this.theme.fg("error", `Could not load agents: ${this.error}`) :
          this.theme.fg("muted", `${this.tasks.length} recorded agent${this.tasks.length === 1 ? "" : "s"}`),
      1,
      0,
    ));

    if (!this.loading && !this.error && this.tasks.length === 0) {
      this.container.addChild(new Text(this.theme.fg("muted", "No agents are currently recorded."), 1, 0));
    } else if (!this.loading && !this.error && this.tasks.length > 0) {
      this.list = new SelectList(selectItems(this.tasks), MAX_LIST_ROWS, listTheme(this.theme));
      this.list.onSelect = (item) => {
        const selected = this.tasks.find((task) => task.id === item.value);
        if (selected) this.done(selected);
      };
      this.list.onCancel = () => this.done(null);
      const listContainer = new Container();
      listContainer.addChild(this.list);
      this.container.addChild(listContainer);
    }
    this.container.addChild(new Text(footerText(this.theme), 1, 0));
  }

  private async refresh(): Promise<void> {
    const generation = ++this.refreshGeneration;
    this.loading = true;
    this.error = "";
    this.rebuild();
    this.tui.requestRender();
    try {
      const snapshot = await loadSnapshot();
      if (this.disposed || generation !== this.refreshGeneration) return;
      this.tasks = snapshot.tasks;
      this.loading = false;
    } catch (error) {
      if (this.disposed || generation !== this.refreshGeneration) return;
      this.loading = false;
      this.error = cleanText(error instanceof Error ? error.message : String(error), 180);
    }
    this.rebuild();
    this.tui.requestRender();
  }

  render(width: number): string[] {
    return this.container.render(width);
  }

  invalidate(): void {
    this.container.invalidate();
  }

  handleInput(data: string): void {
    if (this.keybindings.matches(data, "tui.select.cancel")) {
      this.done(null);
      return;
    }
    if (matchesKey(data, "r")) {
      void this.refresh();
      return;
    }
    this.list?.handleInput(data);
    this.tui.requestRender();
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    const result = this.container.handleMouse(event);
    if (result?.handled) this.tui.requestRender();
    return result;
  }

  dispose(): void {
    this.disposed = true;
    this.refreshGeneration += 1;
  }
}

function buildActionItems(task: AgentRecord): { value: string; label: string; description?: string }[] {
  const items: { value: string; label: string; description?: string }[] = [];
  if (taskState(task) !== "done" && taskState(task) !== "failed") {
    items.push({ value: "message", label: "Send a message…", description: "Use Firstmate's guarded steering inbox." });
  }
  for (const decision of taskDecisions(task)) {
    if (!/^[A-Za-z0-9._-]+$/u.test(decision.key)) continue;
    const verb = decision.verb === "needs-decision" ? "answer" : "reply";
    items.push({
      value: `resolve:${decision.key}`,
      label: `${cleanText(decision.key, 40)} · ${verb}`,
      description: cleanText(decision.summary, 100),
    });
  }
  items.push({ value: "back", label: "Back to agents" });
  return items;
}

function detailLines(task: AgentRecord, theme: Theme): string[] {
  const state = taskState(task);
  const source = cleanText(task.current_state?.source, 40);
  const detail = cleanText(task.current_state?.detail, 180) || "No additional activity detail is available.";
  const project = cleanText(task.project, 80) || "not recorded";
  const kind = cleanText(task.kind, 40) || "agent";
  const decisions = taskDecisions(task);
  const lines = [
    theme.fg("accent", `${cleanText(task.id, 72)} · ${kind} · ${project}`),
    `Current: ${state}${source ? ` · ${source}` : ""}`,
    `Activity/result: ${detail}`,
  ];
  if (task.pr?.url) lines.push(`PR: ${cleanText(task.pr.url, 140)}`);
  if (task.paths?.report?.present && task.paths.report.path) {
    lines.push(`Report: ${cleanText(task.paths.report.path, 140)}`);
  }
  if (decisions.length === 0) {
    lines.push("Actionable waits: none currently recorded.");
  } else {
    lines.push("Actionable waits:");
    for (const decision of decisions.slice(0, MAX_VISIBLE_WAITS)) {
      lines.push(`  ${cleanText(decision.verb, 32)} [${cleanText(decision.key, 56)}]: ${cleanText(decision.summary, 110)}`);
    }
    if (decisions.length > MAX_VISIBLE_WAITS) {
      lines.push(`  ${decisions.length - MAX_VISIBLE_WAITS} additional waits are not shown here.`);
    }
  }
  return lines;
}

class AgentDetailPanel implements Component {
  private container = new Container();
  private list: SelectList;

  private readonly tui: TUI;
  private readonly theme: Theme;
  private readonly keybindings: { matches(data: string, action: string): boolean };
  private readonly task: AgentRecord;
  private readonly done: (action: AgentAction) => void;

  constructor(
    tui: TUI,
    theme: Theme,
    keybindings: { matches(data: string, action: string): boolean },
    task: AgentRecord,
    done: (action: AgentAction) => void,
  ) {
    this.tui = tui;
    this.theme = theme;
    this.keybindings = keybindings;
    this.task = task;
    this.done = done;
    this.list = new SelectList(buildActionItems(task), MAX_ACTION_ROWS, listTheme(theme));
    this.list.onSelect = (item) => {
      if (item.value === "back") {
        this.done({ kind: "back" });
      } else if (item.value === "message") {
        this.done({ kind: "message" });
      } else if (item.value.startsWith("resolve:")) {
        this.done({ kind: "message", key: item.value.slice("resolve:".length) });
      }
    };
    this.list.onCancel = () => this.done({ kind: "back" });
    this.rebuild();
  }

  private rebuild(): void {
    this.container = new Container();
    this.container.addChild(new Text(
      this.theme.fg("accent", this.theme.bold("Agent details and actions")),
      1,
      0,
    ));
    for (const line of detailLines(this.task, this.theme)) {
      this.container.addChild(new Text(line, 1, 0));
    }
    const listContainer = new Container();
    listContainer.addChild(this.list);
    this.container.addChild(listContainer);
    this.container.addChild(new Text(
      this.theme.fg("dim", "↑↓ navigate · Enter select · Esc back · click rows in fullscreen"),
      1,
      0,
    ));
  }

  render(width: number): string[] {
    return this.container.render(width);
  }

  invalidate(): void {
    this.container.invalidate();
  }

  handleInput(data: string): void {
    if (this.keybindings.matches(data, "tui.select.cancel")) {
      this.done({ kind: "back" });
      return;
    }
    this.list.handleInput(data);
    this.tui.requestRender();
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    const result = this.container.handleMouse(event);
    if (result?.handled) this.tui.requestRender();
    return result;
  }
}

function overlayOptions() {
  return {
    overlay: true,
    overlayOptions: { anchor: "center" as const, width: "90%" as const, maxHeight: "85%" as const, margin: 1 },
  };
}

function commandEnvironment(task?: AgentRecord): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    FM_HOME: fmHome,
    FM_ROOT_OVERRIDE: fmRoot,
  };
  delete env.FM_SEND_EXPECTED_SPAWN_GEN;
  delete env.FM_SEND_EXPECTED_REMOTE_HOST;
  if (task?.spawn_gen) env.FM_SEND_EXPECTED_SPAWN_GEN = task.spawn_gen;
  if (task?.remote?.host) env.FM_SEND_EXPECTED_REMOTE_HOST = task.remote.host;
  return env;
}

async function sendMessage(
  ctx: ExtensionCommandContext,
  task: AgentRecord,
  key?: string,
): Promise<boolean> {
  const title = key ? `Reply to ${cleanText(task.id, 48)} · ${cleanText(key, 56)}` : `Message to ${cleanText(task.id, 48)}`;
  const message = await ctx.ui.editor(title);
  if (message === undefined || message.trim() === "") return false;
  const args = [task.id];
  if (key) args.push("--resolve-key", key);
  args.push(message);
  const result = await runCommandAsync(sendScript, args, {
    env: commandEnvironment(task),
    maxBuffer: 64 * 1024,
  });
  if (result.status !== 0) {
    const reason = cleanText(result.stderr || result.stdout || "Firstmate could not confirm the message was recorded.", 220);
    ctx.ui.notify(`Message not confirmed: ${reason}`, "warning");
    return false;
  }
  ctx.ui.notify(key ? "Reply recorded through Firstmate's guarded message path." : "Message recorded through Firstmate's guarded message path.", "info");
  return true;
}

async function openAgentOverview(ctx: ExtensionCommandContext): Promise<void> {
  while (true) {
    const task = await ctx.ui.custom<AgentRecord | null>(
      (tui, theme, keybindings, done) => new AgentOverviewPanel(tui, theme, keybindings, done),
      overlayOptions(),
    );
    if (!task) return;
    const action = await ctx.ui.custom<AgentAction>(
      (tui, theme, keybindings, done) => new AgentDetailPanel(tui, theme, keybindings, task, done),
      overlayOptions(),
    );
    if (action.kind === "back") continue;
    if (await sendMessage(ctx, task, action.key)) continue;
  }
}

export default function fmAgentOverviewExtension(pi: ExtensionAPI): void {
  pi.registerCommand("fm-agents", {
    description: "View Firstmate agent activity and open its guarded action menu",
    handler: async (_args, ctx) => {
      if (ctx.mode !== "tui" || !ctx.hasUI || typeof ctx.ui.custom !== "function") {
        ctx.ui.notify("/fm-agents requires Pi's interactive TUI.", "warning");
        return;
      }
      await openAgentOverview(ctx);
    },
  });
}

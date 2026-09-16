// Firstmate's session-local live task table for Pi.
//
// /tasks is an extension command rather than a skill invocation: it changes only
// one keyed TUI widget, never sends a user message, invokes the model, notifies the
// transcript, or persists display state. Every session_start (including reload)
// starts hidden. Calm owns above-editor transient steps and its sailing animation;
// this table deliberately lives below the editor, so neither extension removes,
// reorders, or recreates the other's components during toggles.
//
// bin/fm-tasks.sh --json owns task selection, ordering, normalized state, current
// outcome, and authoritative started_at projection. This extension only renders
// that model, refreshes it on relevant Pi events plus one bounded fallback, and
// advances elapsed labels locally once per second without rediscovering the fleet.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionContext,
  ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";
import {
  truncateToWidth,
  visibleWidth,
  type Component,
  type TUI,
} from "@earendil-works/pi-tui";

export const TASKS_WIDGET_KEY = "firstmate-live-tasks";
export const TASKS_WIDGET_PLACEMENT = "belowEditor" as const;
const TICK_MS = 1000;
const DEFAULT_REFRESH_MS = 10_000;
const DEFAULT_EVENT_REFRESH_MIN_MS = 2_000;
const COMMAND_TIMEOUT_MS = 15_000;
const HORIZONTAL_MIN_WIDTH = 43;

export type TaskWidgetRow = {
  id: string;
  ref: string;
  name: string;
  status: string;
  outcome: string;
  started_at: string | null;
};

type DisplayState =
  | { kind: "loading" }
  | { kind: "ready"; rows: TaskWidgetRow[] }
  | { kind: "error"; message: string };

type LiveSession = {
  generation: number;
  ui: ExtensionUIContext;
  visible: boolean;
  component?: TaskTableComponent;
  refreshController?: AbortController;
  refreshPromise?: Promise<void>;
  fallbackTimer?: ReturnType<typeof setInterval>;
  eventTimer?: ReturnType<typeof setTimeout>;
  lastRefreshStartedAt: number;
  refreshQueued: boolean;
};

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}

function oneLine(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function cell(value: string, width: number): string {
  if (width <= 0) return "";
  const compact = oneLine(value);
  const clipped = truncateToWidth(compact, width, "…");
  return clipped + " ".repeat(Math.max(0, width - visibleWidth(clipped)));
}

export function formatTaskElapsed(row: TaskWidgetRow, now = Date.now()): string {
  if (row.status !== "working" || !row.started_at) return "—";
  const started = Date.parse(row.started_at);
  if (!Number.isFinite(started) || started > now) return "—";
  const totalSeconds = Math.floor((now - started) / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

function stateRows(state: DisplayState): TaskWidgetRow[] {
  if (state.kind === "ready" && state.rows.length > 0) return state.rows;
  if (state.kind === "error") {
    return [{
      id: "",
      ref: "—",
      name: "—",
      status: "error",
      started_at: null,
      outcome: state.message,
    }];
  }
  return [{
    id: "",
    ref: "—",
    name: "—",
    status: state.kind === "loading" ? "loading" : "empty",
    started_at: null,
    outcome: state.kind === "loading" ? "Refreshing task list…" : "No current tasks",
  }];
}

function renderHorizontal(rows: TaskWidgetRow[], width: number, now: number): string[] {
  const contentWidth = width - 16;
  const widths = { ref: 3, name: 4, status: 6, elapsed: 7, outcome: 7 };
  let spare = contentWidth - Object.values(widths).reduce((sum, value) => sum + value, 0);
  for (const [key, wanted] of [
    ["status", 9],
    ["elapsed", 9],
    ["name", 20],
  ] as const) {
    const add = Math.min(spare, wanted - widths[key]);
    widths[key] += add;
    spare -= add;
  }
  widths.outcome += spare;

  const border = (left: string, middle: string, right: string): string =>
    left + [widths.ref, widths.name, widths.status, widths.elapsed, widths.outcome]
      .map((value) => "─".repeat(value + 2))
      .join(middle) + right;
  const row = (values: readonly string[]): string =>
    `│ ${cell(values[0] ?? "", widths.ref)} │ ${cell(values[1] ?? "", widths.name)} │ ${cell(values[2] ?? "", widths.status)} │ ${cell(values[3] ?? "", widths.elapsed)} │ ${cell(values[4] ?? "", widths.outcome)} │`;

  return [
    border("┌", "┬", "┐"),
    row(["Ref", "Name", "Status", "Elapsed", "Current outcome"]),
    border("├", "┼", "┤"),
    ...rows.map((task) => row([
      task.ref,
      task.name,
      task.status,
      formatTaskElapsed(task, now),
      task.outcome,
    ])),
    border("└", "┴", "┘"),
  ];
}

function renderNarrow(rows: TaskWidgetRow[], width: number, now: number): string[] {
  if (width <= 0) return [];
  if (width < 4) return ["─".repeat(width)];
  const innerWidth = width - 4;
  const border = (left: string, right: string): string => `${left}${"─".repeat(width - 2)}${right}`;
  const line = (label: string, value: string): string =>
    `│ ${cell(`${label}: ${value}`, innerWidth)} │`;
  const lines = [border("┌", "┐")];
  rows.forEach((task, index) => {
    if (index > 0) lines.push(border("├", "┤"));
    lines.push(line("Ref", task.ref));
    lines.push(line("Name", task.name));
    lines.push(line("Status", task.status));
    lines.push(line("Elapsed", formatTaskElapsed(task, now)));
    lines.push(line("Current outcome", task.outcome));
  });
  lines.push(border("└", "┘"));
  return lines;
}

function capRows(rows: TaskWidgetRow[], maxRows: number): TaskWidgetRow[] {
  if (rows.length <= maxRows) return rows;
  if (maxRows <= 1) {
    return [{ id: "", ref: "…", name: "…", status: "", started_at: null, outcome: `+${rows.length} more` }];
  }
  const visible = rows.slice(0, maxRows - 1);
  visible.push({
    id: "",
    ref: "…",
    name: "…",
    status: "",
    started_at: null,
    outcome: `+${rows.length - visible.length} more`,
  });
  return visible;
}

export class TaskTableComponent implements Component {
  private state: DisplayState = { kind: "loading" };
  private disposed = false;
  private readonly tickTimer: ReturnType<typeof setInterval>;
  private readonly requestRender: () => void;
  private readonly now: () => number;
  private readonly height: () => number;

  constructor(
    requestRender: () => void,
    now: () => number = Date.now,
    height: () => number = () => Number.POSITIVE_INFINITY,
  ) {
    this.requestRender = requestRender;
    this.now = now;
    this.height = height;
    this.tickTimer = setInterval(() => {
      if (!this.disposed) this.requestRender();
    }, TICK_MS);
    this.tickTimer.unref?.();
  }

  setRows(rows: TaskWidgetRow[]): void {
    if (this.disposed) return;
    this.state = { kind: "ready", rows };
    this.requestRender();
  }

  setError(message: string): void {
    if (this.disposed) return;
    this.state = { kind: "error", message: oneLine(message) || "Task refresh failed" };
    this.requestRender();
  }

  render(width: number): string[] {
    if (this.disposed || width <= 0) return [];
    const rawRows = stateRows(this.state);
    const terminalHeight = this.height();
    const maxRows = width >= HORIZONTAL_MIN_WIDTH
      ? Math.max(1, terminalHeight - 4)
      : Math.max(1, Math.floor((terminalHeight - 4) / 6));
    const rows = capRows(rawRows, maxRows);
    return width >= HORIZONTAL_MIN_WIDTH
      ? renderHorizontal(rows, width, this.now())
      : renderNarrow(rows, width, this.now());
  }

  invalidate(): void {
    // Rendering is derived from current width and data, with no themed cache.
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    clearInterval(this.tickTimer);
  }
}

function parseRows(stdout: string): TaskWidgetRow[] {
  const value: unknown = JSON.parse(stdout);
  if (!Array.isArray(value)) throw new Error("task command returned non-array JSON");
  return value.map((candidate, index) => {
    if (typeof candidate !== "object" || candidate === null) {
      throw new Error(`task row ${index + 1} is not an object`);
    }
    const row = candidate as Record<string, unknown>;
    for (const key of ["id", "ref", "name", "status", "outcome"] as const) {
      if (typeof row[key] !== "string") throw new Error(`task row ${index + 1} has invalid ${key}`);
    }
    if (row.started_at !== null && row.started_at !== undefined && typeof row.started_at !== "string") {
      throw new Error(`task row ${index + 1} has invalid started_at`);
    }
    return {
      id: row.id as string,
      ref: row.ref as string,
      name: row.name as string,
      status: row.status as string,
      outcome: row.outcome as string,
      started_at: (row.started_at as string | null | undefined) ?? null,
    };
  });
}

const extensionDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(extensionDir, "../..");
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const taskScript = `${fmRoot}/bin/fm-tasks.sh`;

export default function (pi: ExtensionAPI) {
  const refreshMs = positiveInteger("FM_PI_TASKS_REFRESH_MS", DEFAULT_REFRESH_MS);
  const eventRefreshMinMs = positiveInteger(
    "FM_PI_TASKS_EVENT_REFRESH_MIN_MS",
    DEFAULT_EVENT_REFRESH_MIN_MS,
  );
  let nextGeneration = 0;
  let live: LiveSession | undefined;

  const isCurrent = (session: LiveSession): boolean => live === session && session.visible;

  const clearSessionResources = (session: LiveSession): void => {
    session.visible = false;
    session.refreshController?.abort();
    session.refreshController = undefined;
    if (session.fallbackTimer) clearInterval(session.fallbackTimer);
    if (session.eventTimer) clearTimeout(session.eventTimer);
    session.fallbackTimer = undefined;
    session.eventTimer = undefined;
    session.component = undefined;
    session.ui.setWidget(TASKS_WIDGET_KEY, undefined);
  };

  const refresh = (session: LiveSession): void => {
    if (!isCurrent(session)) return;
    if (session.refreshPromise) {
      session.refreshQueued = true;
      return;
    }
    session.lastRefreshStartedAt = Date.now();
    const controller = new AbortController();
    session.refreshController = controller;
    const promise = (async () => {
      try {
        const result = await pi.exec("bash", [taskScript, "--json"], {
          cwd: fmRoot,
          signal: controller.signal,
          timeout: COMMAND_TIMEOUT_MS,
        });
        if (!isCurrent(session) || session.refreshController !== controller) return;
        if (result.code !== 0) {
          const detail = oneLine(result.stderr) || `fm-tasks.sh exited ${result.code}`;
          session.component?.setError(detail);
          return;
        }
        session.component?.setRows(parseRows(result.stdout));
      } catch (error) {
        if (!controller.signal.aborted && isCurrent(session)) {
          session.component?.setError(error instanceof Error ? error.message : String(error));
        }
      } finally {
        if (session.refreshController === controller) {
          session.refreshController = undefined;
          session.refreshPromise = undefined;
        }
        if (isCurrent(session) && session.refreshQueued) {
          session.refreshQueued = false;
          requestRefresh(session);
        }
      }
    })();
    session.refreshPromise = promise;
  };

  const requestRefresh = (session: LiveSession): void => {
    if (!isCurrent(session)) return;
    const wait = eventRefreshMinMs - (Date.now() - session.lastRefreshStartedAt);
    if (wait <= 0) {
      refresh(session);
      return;
    }
    if (session.eventTimer) return;
    session.eventTimer = setTimeout(() => {
      session.eventTimer = undefined;
      refresh(session);
    }, wait);
    session.eventTimer.unref?.();
  };

  const show = (ctx: ExtensionContext): void => {
    const session = live;
    if (!session || session.visible || ctx.mode !== "tui") return;
    session.visible = true;
    session.ui = ctx.ui;
    ctx.ui.setWidget(
      TASKS_WIDGET_KEY,
      (tui: TUI) => {
        const component = new TaskTableComponent(
          () => tui.requestRender(),
          Date.now,
          () => tui.terminal.rows,
        );
        if (isCurrent(session)) session.component = component;
        return component;
      },
      { placement: TASKS_WIDGET_PLACEMENT },
    );
    session.fallbackTimer = setInterval(() => requestRefresh(session), refreshMs);
    session.fallbackTimer.unref?.();
    refresh(session);
  };

  const hide = (): void => {
    if (live?.visible) clearSessionResources(live);
  };

  const refreshOnEvent = (): void => {
    if (live?.visible) requestRefresh(live);
  };

  pi.on("session_start", (_event, ctx) => {
    if (live) clearSessionResources(live);
    live = {
      generation: ++nextGeneration,
      ui: ctx.ui,
      visible: false,
      lastRefreshStartedAt: 0,
      refreshQueued: false,
    };
    // Pi normally clears extension widgets before rebinding. Keep startup hidden
    // explicit so a same-process reload or replacement cannot retain stale UI.
    ctx.ui.setWidget(TASKS_WIDGET_KEY, undefined);
  });
  pi.on("session_shutdown", (_event, ctx) => {
    if (live) clearSessionResources(live);
    else ctx.ui.setWidget(TASKS_WIDGET_KEY, undefined);
    live = undefined;
  });

  // These events can change local task state or expose a newly delivered fleet
  // notification. Bursts coalesce behind eventRefreshMinMs; the fallback remains
  // the only polling cadence when Pi itself is otherwise idle.
  pi.on("agent_start", refreshOnEvent);
  pi.on("agent_settled", refreshOnEvent);
  pi.on("tool_execution_end", refreshOnEvent);
  pi.on("message_end", refreshOnEvent);

  pi.registerCommand("tasks", {
    description: "Toggle Firstmate's live current-task table.",
    handler: async (_args, ctx) => {
      if (live?.visible) hide();
      else show(ctx);
    },
  });
}

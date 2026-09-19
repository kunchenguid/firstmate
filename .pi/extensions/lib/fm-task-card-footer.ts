import { runCommandAsync, type AsyncExecResult } from "./fm-async-exec.ts";
import {
  cardsForView,
  pageCount,
  projectSnapshot,
  projectionForError,
  type FooterProjection,
  type FooterStatus,
  type FooterView,
} from "./fm-task-card-footer-state.ts";

export type { FooterView } from "./fm-task-card-footer-state.ts";

export type FooterStyle = (kind: "status" | "separator" | "name" | "summary" | "next" | "header" | "hint", text: string) => string;

const plainStyle: FooterStyle = (_kind, text) => {
  const separator = text.indexOf("\u0000");
  return separator < 0 ? text : text.slice(separator + 1);
};

const PAGE_SIZE = 6;
const GRID_GAP = "  ";
const DEBOUNCE_MS = 120;

export type FooterStoreOptions = {
  snapshotCommand: string;
  cwd: string;
  env: NodeJS.ProcessEnv;
  exec?: (command: string, args: readonly string[], options: { cwd: string; env: NodeJS.ProcessEnv; maxBuffer: number }) => Promise<AsyncExecResult>;
};

export class TaskCardFooterStore {
  private readonly options: FooterStoreOptions;
  private readonly listeners = new Set<() => void>();
  private debounceTimer: ReturnType<typeof setTimeout> | undefined;
  private disposed = false;
  private inFlight = false;
  private queued = false;
  private projection: FooterProjection = projectionForError("Reading fleet state…");

  constructor(options: FooterStoreOptions) {
    this.options = options;
  }

  get value(): FooterProjection {
    return this.projection;
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private publish(projection: FooterProjection): void {
    if (this.disposed) return;
    this.projection = projection;
    for (const listener of this.listeners) listener();
  }

  schedule(): void {
    if (this.disposed) return;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = undefined;
      void this.refresh();
    }, DEBOUNCE_MS);
    this.debounceTimer.unref?.();
  }

  async refresh(): Promise<void> {
    if (this.disposed) return;
    if (this.inFlight) {
      this.queued = true;
      return;
    }
    this.inFlight = true;
    try {
      const exec = this.options.exec ?? runCommandAsync;
      const result = await exec("bash", [this.options.snapshotCommand, "--json"], {
        cwd: this.options.cwd,
        env: this.options.env,
        maxBuffer: 8 * 1024 * 1024,
      });
      if (this.disposed) return;
      if (result.status !== 0) {
        this.publish(projectionForError("Fleet state could not be read."));
      } else {
        try {
          this.publish(projectSnapshot(JSON.parse(result.stdout)));
        } catch {
          this.publish(projectionForError("Fleet state could not be understood."));
        }
      }
    } catch {
      this.publish(projectionForError("Fleet state could not be read."));
    } finally {
      this.inFlight = false;
      if (this.queued && !this.disposed) {
        this.queued = false;
        this.schedule();
      }
    }
  }

  stop(): void {
    this.disposed = true;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = undefined;
    this.listeners.clear();
  }
}

function fit(text: string, width: number): string {
  if (width <= 0) return "";
  const chars = Array.from(text);
  if (chars.length > width) return chars.slice(0, Math.max(0, width - 1)).join("") + (width > 1 ? "…" : "");
  return text + " ".repeat(width - chars.length);
}

function center(text: string, width: number): string {
  const clipped = fit(text, width).trimEnd();
  const left = Math.max(0, Math.floor((width - Array.from(clipped).length) / 2));
  return " ".repeat(left) + clipped + " ".repeat(Math.max(0, width - left - Array.from(clipped).length));
}

function cellLines(card: ReturnType<typeof cardsForView>[number], width: number, style: FooterStyle): string[] {
  const raw = [
    center(card.status, width),
    "─".repeat(width),
    fit(`${card.ref} · ${card.name}`, width),
    "─".repeat(width),
    fit(card.summary[0], width),
    fit(card.summary[1], width),
    "─".repeat(width),
    fit(card.next, width),
  ];
  return [
    style("status", raw[0]),
    style("separator", raw[1]),
    style("name", raw[2]),
    style("separator", raw[3]),
    style("summary", raw[4]),
    style("summary", raw[5]),
    style("separator", raw[6]),
    style("next", raw[7]),
  ];
}

function statusStyle(status: FooterStatus, style: FooterStyle): FooterStyle {
  return (kind, text) => kind === "status" ? style("status", `${status}\u0000${text}`) : style(kind, text);
}

function headerLines(projection: FooterProjection, width: number, style: FooterStyle): string[] {
  const tokens = Object.entries(projection.counts).map(([label, count]) => `${label} ${count}`);
  const lines: string[] = [];
  let current = "";
  for (const token of tokens) {
    const candidate = current ? `${current} · ${token}` : token;
    if (current && Array.from(candidate).length > width) {
      lines.push(style("header", fit(current, width)));
      current = token;
    } else {
      current = candidate;
    }
  }
  if (current || lines.length === 0) lines.push(style("header", fit(current, width)));
  return lines;
}

export function renderTaskCardFooter(
  width: number,
  projection: FooterProjection,
  view: FooterView,
  page: number,
  style: FooterStyle = plainStyle,
  hints = "",
): string[] {
  const safeWidth = Math.max(1, Math.floor(width));
  const columns = safeWidth >= 112 ? 3 : safeWidth >= 76 ? 2 : 1;
  const cardWidth = Math.max(1, Math.floor((safeWidth - (columns - 1) * GRID_GAP.length) / columns));
  const cards = cardsForView(projection, view);
  const pages = pageCount(projection, view, PAGE_SIZE);
  const activePage = Math.max(0, page);
  const visible = cards.slice(activePage * PAGE_SIZE, (activePage + 1) * PAGE_SIZE);
  const lines = headerLines(projection, safeWidth, style);
  const displayPages = Math.max(pages, activePage + 1);
  const hint = hints || `${view === "action" ? "Action" : "Work"} · page ${activePage + 1}/${displayPages}`;
  lines.push(style("hint", fit(hint, safeWidth)));
  for (let offset = 0; offset < visible.length; offset += columns) {
    const row = visible.slice(offset, offset + columns).map((card) => cellLines(card, cardWidth, statusStyle(card.status, style)));
    while (row.length < columns) row.push(Array.from({ length: 8 }, () => " ".repeat(cardWidth)));
    for (let line = 0; line < 8; line += 1) {
      lines.push(row.map((cardLines) => cardLines[line]).join(GRID_GAP));
    }
  }
  if (visible.length === 0) lines.push(style("summary", fit(`No ${view} tasks.`, safeWidth)));
  return lines;
}

export type TaskCardFooterComponentOptions = {
  tui: { requestRender(): void };
  theme: {
    fg(color: string, text: string): string;
  };
  store: TaskCardFooterStore;
  view: FooterView;
  page: number;
  setPage(page: number): void;
  hints: string;
};

export class TaskCardFooterComponent {
  private readonly tui: TaskCardFooterComponentOptions["tui"];
  private readonly theme: TaskCardFooterComponentOptions["theme"];
  private readonly store: TaskCardFooterStore;
  private view: FooterView;
  private page: number;
  private readonly setPage: (page: number) => void;
  private readonly hints: string;
  private unsubscribe: (() => void) | undefined;

  constructor(options: TaskCardFooterComponentOptions) {
    this.tui = options.tui;
    this.theme = options.theme;
    this.store = options.store;
    this.view = options.view;
    this.page = options.page;
    this.setPage = options.setPage;
    this.hints = options.hints;
    this.unsubscribe = this.store.subscribe(() => {
      this.invalidate();
      this.tui.requestRender();
    });
  }

  setView(view: FooterView): void {
    this.view = view;
    this.page = 0;
    this.setPage(0);
    this.invalidate();
    this.tui.requestRender();
  }

  shiftPage(delta: number): void {
    const next = Math.min(Math.max(0, this.page + delta), pageCount(this.store.value, this.view) - 1);
    if (next === this.page) return;
    this.page = next;
    this.setPage(next);
    this.invalidate();
    this.tui.requestRender();
  }

  render(width: number): string[] {
    const styles: FooterStyle = (kind, text) => {
      if (kind === "separator" || kind === "hint") return this.theme.fg("dim", text);
      if (kind === "header") return this.theme.fg("muted", text);
      if (kind === "name") return this.theme.fg("text", text);
      if (kind === "next") return this.theme.fg("dim", text);
      return this.theme.fg("muted", text);
    };
    const styled = (kind: Parameters<FooterStyle>[0], text: string): string => {
      if (kind === "status") {
        const separator = text.indexOf("\u0000");
        const status = separator < 0 ? "" : text.slice(0, separator);
        const body = separator < 0 ? text : text.slice(separator + 1);
        return this.theme.fg(status === "Attention" || status === "Unknown" ? "warning" : status === "Done" ? "success" : "muted", body);
      }
      return styles(kind, text);
    };
    const pages = Math.max(pageCount(this.store.value, this.view), this.page + 1);
    return renderTaskCardFooter(width, this.store.value, this.view, this.page, styled, `${this.hints} · page ${this.page + 1}/${pages}`);
  }

  invalidate(): void {}

  dispose(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }
}

export { PAGE_SIZE, DEBOUNCE_MS };

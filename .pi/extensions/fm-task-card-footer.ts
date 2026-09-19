// Live flat task-card footer prototype for Pi.
//
// The footer consumes only fm-fleet-snapshot.sh's structured projection. It never
// parses status-log tails, starts work, moves tasks, or writes transcript entries.
import { existsSync, watch, type FSWatcher } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Key } from "@earendil-works/pi-tui";
import {
  TaskCardFooterComponent,
  TaskCardFooterStore,
  type FooterView,
} from "./lib/fm-task-card-footer.ts";

const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || extensionRoot;
const fmRoot = process.env.FM_ROOT_OVERRIDE || extensionRoot;
const stateDir = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const dataDir = process.env.FM_DATA_OVERRIDE || join(fmHome, "data");
const snapshotCommand = join(fmRoot, "bin", "fm-fleet-snapshot.sh");
const shortcut = (key: string): Parameters<ExtensionAPI["registerShortcut"]>[0] => key as Parameters<ExtensionAPI["registerShortcut"]>[0];
const compactKey = (key: string): string => key.replace("ctrl+alt+", "C-A+").replace("left", "←").replace("right", "→").replace("up", "↑").replace("down", "↓");

function watchRelevant(directory: string, filename: string | Buffer | null): boolean {
  const name = filename?.toString() ?? "";
  if (directory === dataDir) return name === "backlog.md" || name === "secondmates.md";
  return /(?:\.status|\.meta|\.pr-poll(?:$|\.)|\.merge-authority$|\.backlog-close$)/.test(name);
}

function watchDirectory(directory: string, store: TaskCardFooterStore): FSWatcher | undefined {
  if (!existsSync(directory)) return undefined;
  try {
    const watcher = watch(directory, { persistent: false }, (_event, filename) => {
      if (watchRelevant(directory, filename)) store.schedule();
    });
    watcher.on("error", () => {
      // A missing or unreadable watcher only loses push refreshes. The next Pi
      // lifecycle event still performs the bounded asynchronous read.
    });
    return watcher;
  } catch {
    return undefined;
  }
}

export default function (pi: ExtensionAPI): void {
  let store: TaskCardFooterStore | undefined;
  let component: TaskCardFooterComponent | undefined;
  let watchers: FSWatcher[] = [];
  let view: FooterView = "action";
  let page = 0;

  const dispose = (ctx?: ExtensionContext): void => {
    component?.dispose();
    component = undefined;
    for (const watcher of watchers) watcher.close();
    watchers = [];
    store?.stop();
    store = undefined;
    if (ctx?.mode === "tui") ctx.ui.setFooter(undefined);
  };

  const selectView = (next: FooterView): void => {
    view = next;
    page = 0;
    component?.setView(next);
  };

  pi.registerShortcut(shortcut(Key.ctrlAlt("left")), {
    description: "Show task-card Action view",
    handler: () => selectView("action"),
  });
  pi.registerShortcut(shortcut(Key.ctrlAlt("right")), {
    description: "Show task-card Work view",
    handler: () => selectView("work"),
  });
  pi.registerShortcut(shortcut(Key.ctrlAlt("up")), {
    description: "Show the previous task-card page",
    handler: () => component?.shiftPage(-1),
  });
  pi.registerShortcut(shortcut(Key.ctrlAlt("down")), {
    description: "Show the next task-card page",
    handler: () => component?.shiftPage(1),
  });

  pi.on("session_start", (_event, ctx) => {
    dispose();
    if (ctx.mode !== "tui") return;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_STATE_OVERRIDE: stateDir,
      FM_DATA_OVERRIDE: dataDir,
    };
    store = new TaskCardFooterStore({
      snapshotCommand,
      cwd: fmRoot,
      env,
    });
    const currentStore = store;
    ctx.ui.setFooter((tui, theme, _footerData) => {
      component = new TaskCardFooterComponent({
        tui,
        theme,
        store: currentStore,
        view,
        page,
        setPage: (nextPage) => { page = nextPage; },
        hints: `${compactKey(Key.ctrlAlt("left"))}/${compactKey(Key.ctrlAlt("right"))} view · ${compactKey(Key.ctrlAlt("up"))}/${compactKey(Key.ctrlAlt("down"))} page`,
      });
      return component;
    });
    watchers = [stateDir, dataDir]
      .map((directory) => watchDirectory(directory, currentStore))
      .filter((watcher): watcher is FSWatcher => watcher !== undefined);
    void currentStore.refresh();
  });

  const scheduleRefresh = (): void => store?.schedule();
  pi.on("turn_end", scheduleRefresh);
  pi.on("agent_settled", scheduleRefresh);
  pi.on("session_shutdown", (_event, ctx) => dispose(ctx));

  // The four bindings are intentionally outside Pi's documented defaults:
  // Ctrl+Alt+arrows do not replace editor, transcript, model, or application keys.
}

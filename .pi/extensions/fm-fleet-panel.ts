// Firstmate fleet side panel for Pi.
//
// A `/fleet` slash command toggles a persistent widget showing every fleet
// project clone's branch and clean/dirty state plus each live fleet server with
// a clickable preview URL. The panel refreshes from a fresh
// `bin/fm-bearings-snapshot.sh --json` run on every toggle-on and on a bounded
// interval while visible; the snapshot owns the data contract (servers[] and
// project_branches[]), this file owns only the panel. Preview links render
// through Pi's Markdown component, which emits OSC 8 hyperlinks on capable
// terminals and falls back to printing the URL beside the label otherwise.
//
// Verified against the Pi extension API surface this file probes at load:
// ExtensionAPI.registerCommand() with a description and handler, and
// ExtensionUIContext.setWidget() with a component factory and disposal by
// passing undefined under the same key (see the widget-placement and commands
// examples in the Pi package). Anything else degrades to a chat notice.
import { execFile } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type {
  ExtensionAPI,
  ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";
import { getMarkdownTheme } from "@earendil-works/pi-coding-agent";
import { Markdown, type Component } from "@earendil-works/pi-tui";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

export const FLEET_PANEL_WIDGET_KEY = "firstmate-fleet-panel";
const REFRESH_MS = 60_000;
const SNAPSHOT_TIMEOUT_MS = 30_000;

type FleetServer = {
  project?: unknown;
  port?: unknown;
  pid?: unknown;
  uptime?: unknown;
  dir?: unknown;
};

type FleetBranch = {
  project?: unknown;
  branch?: unknown;
  clean?: unknown;
};

type FleetSnapshot = {
  servers?: FleetServer[];
  project_branches?: FleetBranch[];
};

const asText = (value: unknown, fallback: string): string =>
  typeof value === "string" && value !== "" ? value : fallback;

const asPort = (value: unknown): number | null =>
  typeof value === "number" && Number.isInteger(value) ? value : null;

const escapeMarkdown = (value: string): string =>
  value.replace(/\n/g, " ").replace(/([`*_{}[\]()#+\-.!|])/g, "\\$1");

function runSnapshot(): Promise<FleetSnapshot> {
  return new Promise((resolveSnapshot, rejectSnapshot) => {
    execFile(
      "bash",
      [resolve(root, "bin/fm-bearings-snapshot.sh"), "--json"],
      { cwd: root, timeout: SNAPSHOT_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 },
      (error, stdout) => {
        if (error) {
          rejectSnapshot(error);
          return;
        }
        try {
          resolveSnapshot(JSON.parse(stdout) as FleetSnapshot);
        } catch (parseError) {
          rejectSnapshot(parseError);
        }
      },
    );
  });
}

function renderPanel(snapshot: FleetSnapshot): string {
  const branches = Array.isArray(snapshot.project_branches)
    ? snapshot.project_branches
    : [];
  const servers = Array.isArray(snapshot.servers) ? snapshot.servers : [];
  const byProject = new Map<string, FleetServer[]>();
  for (const server of servers) {
    const port = asPort(server.port);
    if (port === null) continue;
    const project = asText(server.project, "-");
    const rows = byProject.get(project) ?? [];
    rows.push(server);
    byProject.set(project, rows);
  }
  const lines = ["## Fleet"];
  if (branches.length === 0 && servers.length === 0) {
    lines.push("No fleet clones or running servers reported.");
    return lines.join("\n");
  }
  for (const row of branches) {
    const project = asText(row.project, "-");
    const branch = asText(row.branch, "-");
    const projectLabel = escapeMarkdown(project);
    const branchLabel = escapeMarkdown(branch);
    const dirty = row.clean === false ? " dirty" : "";
    const projectServers = (byProject.get(project) ?? [])
      .filter((server) => asPort(server.port) !== null)
      .sort((a, b) => (asPort(a.port) ?? 0) - (asPort(b.port) ?? 0));
    if (projectServers.length === 0) {
      lines.push(`- **${projectLabel}** @ ${branchLabel}${dirty}`);
      continue;
    }
    const links = projectServers.map((server) => {
      const port = asPort(server.port) ?? 0;
      const url = `http://localhost:${port}`;
      const pid =
        typeof server.pid === "number" ? ` (pid ${server.pid})` : "";
      return `[${port}](${url})${pid}`;
    });
    lines.push(`- **${projectLabel}** @ ${branchLabel}${dirty} - ${links.join(" ")}`);
  }
  const orphaned = servers.filter(
    (server) =>
      asPort(server.port) !== null &&
      !branches.some(
        (row) => asText(row.project, "-") === asText(server.project, "-"),
      ),
  );
  for (const server of orphaned) {
    const port = asPort(server.port) ?? 0;
    lines.push(
      `- **${escapeMarkdown(asText(server.project, "-"))}** - [${port}](http://localhost:${port})`,
    );
  }
  return lines.join("\n");
}

class FleetPanelComponent implements Component {
  private md: Markdown;

  constructor(initial: string) {
    this.md = new Markdown(initial, 0, 0, getMarkdownTheme());
  }

  setText(text: string): void {
    this.md.setText(text);
    this.md.invalidate();
  }

  invalidate(): void {
    this.md.invalidate();
  }

  render(width: number): string[] {
    return this.md.render(width);
  }
}

export default function fleetPanelExtension(pi: ExtensionAPI): void {
  let panel: FleetPanelComponent | null = null;
  let refreshTimer: ReturnType<typeof setInterval> | null = null;
  let fetching = false;

  const stopRefresh = (): void => {
    if (refreshTimer !== null) {
      clearInterval(refreshTimer);
      refreshTimer = null;
    }
  };

  const hide = (ui: ExtensionUIContext): void => {
    stopRefresh();
    panel = null;
    ui.setWidget(FLEET_PANEL_WIDGET_KEY, undefined);
  };

  const refresh = async (ui: ExtensionUIContext): Promise<void> => {
    if (fetching || panel === null) return;
    fetching = true;
    const active = panel;
    try {
      const text = renderPanel(await runSnapshot());
      if (panel !== active) return;
      active.setText(text);
    } catch {
      if (panel !== active) return;
      active.setText("## Fleet\nSnapshot refresh failed; showing last good read.");
    } finally {
      fetching = false;
    }
  };

  const show = async (ui: ExtensionUIContext): Promise<void> => {
    const component = new FleetPanelComponent("## Fleet\nLoading fleet state...");
    panel = component;
    ui.setWidget(FLEET_PANEL_WIDGET_KEY, () => component);
    let text: string;
    try {
      text = renderPanel(await runSnapshot());
    } catch {
      if (panel !== component) return;
      hide(ui);
      ui.notify("Fleet panel: the fleet snapshot failed to run.", "error");
      return;
    }
    if (panel !== component) return;
    component.setText(text);
    stopRefresh();
    refreshTimer = setInterval(() => {
      void refresh(ui);
    }, REFRESH_MS);
  };

  pi.on("session_shutdown", (_event, ctx) => {
    hide(ctx.ui);
  });

  pi.registerCommand("fleet", {
    description:
      "Toggle Firstmate's fleet side panel: per-project branch plus live preview links.",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) {
        ctx.ui.notify("Fleet panel needs Pi's interactive UI.", "warning");
        return;
      }
      if (args.trim() === "refresh") {
        if (panel === null) {
          await show(ctx.ui);
        } else {
          await refresh(ctx.ui);
        }
        return;
      }
      if (panel === null) {
        await show(ctx.ui);
      } else {
        hide(ctx.ui);
      }
    },
  });
}

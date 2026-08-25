import { readdirSync, readFileSync } from "node:fs";

// Shared wake-dispatch handshake between the Pi watcher extension (the
// dispatcher) and the supervision-branch extension (the handler), carried over
// pi.events so neither extension imports the other.
//
// Contract: the watcher builds one offer per actionable wake and emits it on
// FM_BRANCH_DISPATCH_EVENT. A live, enabled branch extension calls accept()
// SYNCHRONOUSLY inside its handler (the event bus invokes handlers
// synchronously up to their first await), so after emit returns the watcher
// reads `accepted`: true means the branch now owns delivering and handling the
// wake (including its own fallback back to main on a later failure); false
// means no branch took it and the watcher delivers to main exactly as it did
// before the branch existed. Watcher-failure alarms are never offered - only
// main can repair the watcher cycle (fm_watch_arm_pi lives on main).

export const FM_BRANCH_DISPATCH_EVENT = "fm-branch-supervision:dispatch";

export type UnreadWakeScopeStatus = "safe" | "empty" | "unsafe";

export function scopeForUnreadWake(state: string, heartbeat: boolean): {
  status: UnreadWakeScopeStatus;
  eligible: boolean;
  projects: string[];
} {
  let queue = "";
  try {
    queue = readFileSync(`${state}/.wake-queue`, "utf8");
  } catch {
    return { status: "unsafe", eligible: false, projects: [] };
  }

  const rows = queue.split(/\r?\n/).filter((line) => line.length > 0);
  if (rows.length === 0) return { status: "empty", eligible: false, projects: [] };

  const projects = new Set<string>();
  const metadata = new Map<string, string>();
  try {
    for (const name of readdirSync(state)) {
      if (!name.endsWith(".meta")) continue;
      const task = name.slice(0, -5);
      const fields = readFileSync(`${state}/${name}`, "utf8").split(/\r?\n/);
      const project = fields.find((line) => line.startsWith("project="))?.slice(8) ?? "";
      const window = fields.find((line) => line.startsWith("window="))?.slice(7) ?? "";
      if (project) {
        metadata.set(task, project);
        if (window) metadata.set(window, project);
      }
    }
  } catch {
    return { status: "unsafe", eligible: false, projects: [] };
  }

  for (const line of rows) {
    const fields = line.split("\t");
    if (fields.length < 4 || !/^[0-9]+$/.test(fields[1])) return { status: "unsafe", eligible: false, projects: [] };
    const kind = fields[2];
    const key = fields[3];
    if (kind === "heartbeat") continue;
    let project = "";
    if (kind === "signal") {
      const task = key.replace(/\.(?:status|turn-ended)$/, "");
      project = metadata.get(task) ?? "";
    } else if (kind === "stale") {
      project = metadata.get(key) ?? metadata.get(key.replace(/^fm-/, "")) ?? "";
    } else {
      return { status: "unsafe", eligible: false, projects: [] };
    }
    if (!project) return { status: "unsafe", eligible: false, projects: [] };
    projects.add(project);
  }
  const eligible = heartbeat || projects.size > 0;
  return { status: eligible ? "safe" : "unsafe", eligible, projects: [...projects] };
}

export interface BranchDispatchOffer {
  /** The watcher's actionable close message (the wake reason line(s)). */
  message: string;
  /**
   * Exact project values from the unread task metadata this wake will drain.
   * Empty means the wake is fleet-wide or could not be scoped safely.
   */
  projects: readonly string[];
  /** True when the watcher classified this wake as a fleet-wide heartbeat scan. */
  heartbeat: boolean;
  /** True only when every unread queue row is safe for branch handling. */
  eligible: boolean;
  /** Set by accept(); read by the watcher after emit returns. */
  accepted: boolean;
  accept(): void;
}

export function createBranchDispatchOffer(
  message: string,
  projects: readonly string[] = [],
  heartbeat = false,
  eligible = false,
): BranchDispatchOffer {
  const offer: BranchDispatchOffer = {
    message,
    projects: [...projects],
    heartbeat,
    eligible,
    accepted: false,
    accept() {
      offer.accepted = true;
    },
  };
  return offer;
}

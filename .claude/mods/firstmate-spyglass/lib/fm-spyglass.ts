// Firstmate Spyglass fleet view policy for the Claude Code mod, kept free of the engine.
//
// This module owns the decisions ../hooks/register.tsx applies through `$`: where the
// Firstmate code root, home, and state directory live, how the fleet snapshot is trimmed
// to what the captain looks at, the status-line summary, how the update check compares
// this checkout with origin, and how a worker's terminal capture is made safe to show.
// docs/spyglass.md owns the captain-facing contract. Everything here is pure so tests run
// it under Node.

import type { Fleet, Session, Update } from "./fm-spyglass-types.d.ts";

export type { CaptainCall, Fleet, Queued, Session, UnderWay, Update } from "./fm-spyglass-types.d.ts";

/** The environment variables that select the effective Firstmate home, as the mod reads them. */
export type SpyglassHomeEnvironment = {
  readonly FM_HOME?: string | undefined;
  readonly FM_ROOT_OVERRIDE?: string | undefined;
  readonly FM_STATE_OVERRIDE?: string | undefined;
};

/** The parts of an `fm-fleet-snapshot.v1` object the mod reads. */
type SnapshotJson = {
  generated?: string;
  tasks?: {
    id: string;
    kind?: string;
    project?: string;
    current_state?: { state?: string };
    backlog?: { repo?: string };
    pr?: { url?: string };
    backend?: string;
    remote?: unknown;
    endpoint?: { target?: string };
  }[];
  backlog?: {
    records?: {
      id: string;
      title?: string;
      raw?: string;
      state?: string;
      hold_reason?: string;
      captain_actionable?: boolean;
    }[];
  };
};

/** The parent of a path, with either separator; a bare name resolves to itself. */
function parentDirectory(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const cut = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return cut > 0 ? trimmed.slice(0, cut) : trimmed;
}

/**
 * The tracked Firstmate code root the mod belongs to, where the `bin/` scripts live:
 * `FM_ROOT_OVERRIDE`, else three levels above the plugin folder, whether Claude Code
 * names it through `.claude/skills/<name>`, `.agents/skills/<name>`, or its physical
 * `.claude/mods/<name>` home, which all sit at that same depth.
 */
export function spyglassCodeRoot(env: SpyglassHomeEnvironment, pluginRoot: string): string {
  return env.FM_ROOT_OVERRIDE || parentDirectory(parentDirectory(parentDirectory(pluginRoot)));
}

/** The effective Firstmate home, resolved as the `bin/` scripts and Calm resolve it: `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the code root. */
export function spyglassHome(env: SpyglassHomeEnvironment, pluginRoot: string): string {
  return env.FM_HOME || env.FM_ROOT_OVERRIDE || spyglassCodeRoot(env, pluginRoot);
}

/** The home's runtime state directory, where each worker's `<id>.meta` lives. */
export function spyglassStateDirectory(env: SpyglassHomeEnvironment, pluginRoot: string): string {
  return env.FM_STATE_OVERRIDE || `${spyglassHome(env, pluginRoot)}/state`;
}

/**
 * Reduce an `fm-fleet-snapshot.v1` object to what the captain looks at. A worker keeps its
 * target only when it is a local tmux one, the only kind `tmux attach` can reach.
 */
export function trimSnapshot(snapshot: SnapshotJson): Fleet {
  const tasks = snapshot.tasks ?? [];
  const records = snapshot.backlog?.records ?? [];

  return {
    generated: snapshot.generated ?? "",
    underWay: tasks.map((task) => ({
      id: task.id,
      kind: task.kind ?? "-",
      state: task.current_state?.state ?? "?",
      project: task.backlog?.repo ?? task.project ?? "-",
      pr: task.pr?.url ?? null,
      target: (task.backend === "tmux" && !task.remote && task.endpoint?.target) || null,
      model: null,
      effort: null,
    })),
    calls: records
      .filter((record) => record.captain_actionable)
      .map((record) => ({ id: record.id, title: record.title ?? record.raw ?? record.id, reason: record.hold_reason ?? "" })),
    // A PR is ready only once its worker reports done; a URL alone can be an open draft.
    prs: tasks.flatMap((task) => (task.pr?.url && task.current_state?.state === "done" ? [{ id: task.id, url: task.pr.url }] : [])),
    queued: records
      .filter((record) => record.state === "queued" && !record.captain_actionable)
      .map((record) => ({ id: record.id, title: record.title ?? record.raw ?? record.id })),
  };
}

/** A worker's model and effort, from the `model=` and `effort=` lines of its `<id>.meta` record. */
export function parseWorkerMeta(meta: string): { model: string | null; effort: string | null } {
  return {
    model: /^model=(.*)$/m.exec(meta)?.[1] || null,
    effort: /^effort=(.*)$/m.exec(meta)?.[1] || null,
  };
}

/** The status-line text, or undefined when there is nothing to say. */
export function summary(fleet: Fleet, update: Update | null): string | undefined {
  const parts = [
    fleet.underWay.length && `${fleet.underWay.length} under way`,
    fleet.calls.length && `${fleet.calls.length} signal${fleet.calls.length > 1 ? "s" : ""}`,
    fleet.prs.length && `${fleet.prs.length} PR${fleet.prs.length > 1 ? "s" : ""} ready`,
    update && update.behind > 0 && "⬆ update",
  ].filter(Boolean);

  return parts.length ? `⚓ ${parts.join(" · ")}` : undefined;
}

/** The ids the toast follows: a signal the captain has not seen yet is one not in the previous set. */
export function signalIds(fleet: Fleet): Set<string> {
  return new Set([...fleet.calls.map((call) => `call:${call.id}`), ...fleet.prs.map((pr) => `pr:${pr.id}`)]);
}

/** Ship's watches by local hour of the snapshot's UTC time. */
export function watchName(iso: string): string {
  const date = new Date(iso);
  if (isNaN(date.getTime())) return "On watch";
  const hour = date.getHours();
  if (hour < 4) return "Middle Watch";
  if (hour < 8) return "Morning Watch";
  if (hour < 12) return "Forenoon Watch";
  if (hour < 16) return "Afternoon Watch";
  if (hour < 20) return "Dog Watch";
  return "First Watch";
}

/** The local `HH:MM` of a time, or the text itself when it is not one. */
export function clockTime(iso: string): string {
  const date = new Date(iso);
  return isNaN(date.getTime()) ? iso : date.toTimeString().slice(0, 5);
}

/**
 * The GitHub `owner/name` an origin remote URL names, or undefined for any other host
 * or shape. Covers the https, scp-like ssh, and ssh:// forms git prints.
 */
export function githubRepoFromRemote(remote: string): string | undefined {
  const match = /^(?:https?:\/\/(?:[^@/]+@)?github\.com\/|ssh:\/\/git@github\.com\/|git@github\.com:)([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/.exec(remote.trim());
  return match ? `${match[1]}/${match[2]}` : undefined;
}

/** Origin's default branch and its commit, from `git ls-remote --symref origin HEAD`, or undefined when either is missing. */
export function originHead(lsRemote: string): { branch: string; commit: string } | undefined {
  const branch = /^ref: refs\/heads\/(\S+)\tHEAD$/m.exec(lsRemote)?.[1];
  const commit = /^([0-9a-f]+)\tHEAD$/m.exec(lsRemote)?.[1];
  return branch && commit ? { branch, commit } : undefined;
}

/** The update state from one comparison of this checkout with origin's default branch, `compare` being the GitHub compare answer when the commits differ. */
export function updateFrom(
  remote: string,
  local: string[],
  compare: { n?: number; files?: string[] } | undefined,
  checkedAt: string,
): Update {
  const behind = compare?.n ?? 0;
  const incoming = compare?.files ?? [];
  return { remote, behind, local, conflicts: local.filter((file) => incoming.includes(file)), checkedAt, error: null };
}

/**
 * Whether a worker's tmux target is safe to hand to a terminal launcher: the
 * `session:window` shapes the backends record, never quotes or whitespace.
 */
export function isSafeTarget(target: string): boolean {
  return /^[\w.:@%/+-]+$/.test(target);
}

/**
 * Make a worker's terminal capture showable. Claude Code accepts tab and newline only,
 * so escape sequences and every other control character go; the newest 10000 characters stay.
 */
export function sanitizeCapture(text: string): string {
  return text
    .replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
    .replace(/[^\S\n\t ]|[\x00-\x08\x0b-\x1f\x7f]/g, "")
    .trimEnd()
    .slice(-10_000);
}

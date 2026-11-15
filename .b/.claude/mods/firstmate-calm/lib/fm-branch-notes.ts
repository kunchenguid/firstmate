// Firstmate supervision notes for the Claude Code mod, kept free of the engine.
//
// Pi renders each supervision outcome in the transcript: a sailboat note for a visible
// routine outcome and a sequence-keyed anchor entry for a captain outcome
// (.pi/extensions/fm-branch-supervision.ts). This module owns the same lines for
// Claude Code, read from the display tail copy of the one outcome store
// (bin/fm-branch-outcome.sh owns every file format read here) and from the supervision
// host's latch (bin/fm-supervision-host.sh). It only renders: nothing here marks an
// outcome read or processed. Everything is pure so tests run it under Node.
import { calmCodeRootFromPluginRoot } from "./fm-calm-presentation.ts";

export const BRANCH_NOTE_BOAT = "⛵";
export const BRANCH_NOTE_ANCHOR = "⚓";
/** At most this many lines replay at session start, newest kept. */
export const BRANCH_NOTES_REPLAY_LIMIT = 20;
/** How many sessions' last shown sequence the mod's store keeps, newest kept. */
export const BRANCH_NOTES_SESSIONS_KEPT = 20;

export type FirstmateStateEnvironment = {
  readonly FM_HOME?: string | undefined;
  readonly FM_ROOT_OVERRIDE?: string | undefined;
  readonly FM_STATE_OVERRIDE?: string | undefined;
};

export type OutcomeRow = {
  readonly seq: number;
  readonly epoch: number;
  readonly task: string;
  readonly verdict: "routine" | "captain";
  readonly summary: string;
  readonly silent: boolean;
};

/** The home's state directory, resolved as the Pi extension resolves it. */
export function firstmateStateDirectory(env: FirstmateStateEnvironment, pluginRoot: string): string {
  return env.FM_STATE_OVERRIDE || `${env.FM_HOME || env.FM_ROOT_OVERRIDE || calmCodeRootFromPluginRoot(pluginRoot)}/state`;
}

function parseOutcomeRow(value: unknown): OutcomeRow | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const row = value as Record<string, unknown>;
  if (typeof row.seq !== "number" || !Number.isSafeInteger(row.seq) || row.seq < 1) return undefined;
  if (typeof row.epoch !== "number" || !Number.isSafeInteger(row.epoch) || row.epoch < 0) return undefined;
  if (typeof row.task !== "string" || row.task === "") return undefined;
  if (row.verdict !== "routine" && row.verdict !== "captain") return undefined;
  if (typeof row.summary !== "string" || row.summary === "") return undefined;
  if (row.silent !== undefined && typeof row.silent !== "boolean") return undefined;
  const silent = row.silent === true;
  if (silent && row.verdict !== "routine") return undefined;
  return { seq: row.seq, epoch: row.epoch, task: row.task, verdict: row.verdict, summary: row.summary, silent };
}

/** The valid rows of the tail copy in ascending sequence; a line that breaks the contract is skipped. */
export function parseOutcomeTail(text: string | undefined): OutcomeRow[] {
  const rows: OutcomeRow[] = [];
  for (const line of (text ?? "").split("\n")) {
    if (line.trim() === "") continue;
    let row: OutcomeRow | undefined;
    try {
      row = parseOutcomeRow(JSON.parse(line));
    } catch {
      row = undefined;
    }
    if (row !== undefined && (rows.length === 0 || row.seq > rows[rows.length - 1]!.seq)) rows.push(row);
  }
  return rows;
}

/** A sidecar marker's sequence: absent or unreadable reads as 0, as the store owner reads it. */
export function parseOutcomeMarker(text: string | undefined): number {
  const value = (text ?? "").trim();
  return /^(0|[1-9][0-9]*)$/.test(value) && Number.isSafeInteger(Number(value)) ? Number(value) : 0;
}

/** Pi's transcript line for one row, on one line; a silent row has none. */
export function outcomeNoteLine(row: OutcomeRow): string | undefined {
  if (row.silent) return undefined;
  const summary = row.summary.replace(/\s*\n\s*/g, " ");
  return row.verdict === "captain"
    ? `${BRANCH_NOTE_ANCHOR} [seq ${row.seq}] ${row.task}: ${summary}`
    : `${BRANCH_NOTE_BOAT} ${row.task}: ${summary}`;
}

/**
 * The session-start replay, as Pi's startup replay presents the store: every captain row
 * main has not acknowledged as processed and every unread visible routine row, bounded
 * to the newest few with one line counting any that were left out. Rows through
 * `shownThrough` are already in this session's restored transcript and are skipped,
 * unless the tail ends below it (a replaced store).
 */
export function replayOutcomeNotes(
  rows: readonly OutcomeRow[],
  cursor: number,
  processed: number,
  shownThrough = 0,
): string[] {
  const shown = shownThrough > (rows[rows.length - 1]?.seq ?? 0) ? 0 : shownThrough;
  const due = rows.filter(
    (row) => row.seq > shown && (row.verdict === "captain" ? row.seq > processed : row.seq > cursor),
  );
  const lines = due.map(outcomeNoteLine).filter((line): line is string => line !== undefined);
  if (lines.length <= BRANCH_NOTES_REPLAY_LIMIT) return lines;
  const omitted = lines.length - BRANCH_NOTES_REPLAY_LIMIT;
  return [
    `${BRANCH_NOTE_BOAT} ${omitted} earlier supervision ${omitted === 1 ? "note" : "notes"} not replayed; bin/fm-branch-outcome.sh list shows them`,
    ...lines.slice(-BRANCH_NOTES_REPLAY_LIMIT),
  ];
}

/**
 * The lines for rows appended since `lastSeen`, and the new last seen sequence. Rows that
 * arrived faster than the tail copy holds are counted in one line rather than dropped
 * silently. A tail that ends below the anchor is a replaced store: re-anchor there
 * without replaying it.
 */
export function newOutcomeNotes(rows: readonly OutcomeRow[], lastSeen: number): { lines: string[]; lastSeen: number } {
  const last = rows.length === 0 ? lastSeen : rows[rows.length - 1]!.seq;
  if (last < lastSeen) return { lines: [], lastSeen: last };
  const fresh = rows.filter((row) => row.seq > lastSeen);
  const lines = fresh.map(outcomeNoteLine).filter((line): line is string => line !== undefined);
  const missed = (fresh[0]?.seq ?? lastSeen + 1) - lastSeen - 1;
  if (missed > 0) {
    lines.unshift(
      `${BRANCH_NOTE_BOAT} ${missed} earlier supervision ${missed === 1 ? "outcome" : "outcomes"} not shown; bin/fm-branch-outcome.sh list shows them`,
    );
  }
  return { lines, lastSeen: last };
}

/** The last sequence a session has followed the store through, from the mod's store value; 0 when unknown. */
export function sessionShownThrough(stored: unknown, sessionId: string): number {
  if (!Array.isArray(stored)) return 0;
  const entry = stored.find((item) => Array.isArray(item) && item[0] === sessionId);
  return entry !== undefined && Number.isSafeInteger(entry[1]) && entry[1] > 0 ? entry[1] : 0;
}

/** The store value with this session's last followed sequence recorded as its newest entry. */
export function recordSessionShownThrough(stored: unknown, sessionId: string, seq: number): [string, number][] {
  const others = (Array.isArray(stored) ? stored : []).filter(
    (item): item is [string, number] =>
      Array.isArray(item) && typeof item[0] === "string" && item[0] !== sessionId && Number.isSafeInteger(item[1]),
  );
  return [...others, [sessionId, seq] as [string, number]].slice(-BRANCH_NOTES_SESSIONS_KEPT);
}

export type HostHealth = { readonly key: string; readonly cooling: boolean };

/** The supervision host's latch, or undefined when the file is absent or has no key. */
export function parseHostHealth(text: string | undefined): HostHealth | undefined {
  const field = (name: string) => new RegExp(`^${name}=(.*)$`, "m").exec(text ?? "")?.[1];
  const key = field("key");
  if (key === undefined || key === "") return undefined;
  const cooldown = field("cooldown") ?? "";
  return { key, cooling: /^[0-9]+$/.test(cooldown) && Number(cooldown) > 0 };
}

/** The note a latch change owes, as Pi's two health notes: a trip, or a recovery under the same key. */
export function hostHealthNote(previous: HostHealth | undefined, next: HostHealth | undefined): string | undefined {
  if (next === undefined) return undefined;
  const wasCooling = previous !== undefined && previous.key === next.key && previous.cooling;
  if (next.cooling && !wasCooling) {
    return `${BRANCH_NOTE_BOAT} Supervision session paused after repeated engine errors; main will handle wakes while it cools down.`;
  }
  if (!next.cooling && wasCooling) return `${BRANCH_NOTE_BOAT} Supervision session recovered after a successful cooldown probe.`;
  return undefined;
}

// Thin wrapper over the canonical shared fold core: re-exports the pure
// core and adds the node:fs default bindings that plain callers need. The
// canonical core lives under the Claude Code mod
// (.claude/mods/fm-branch-mod/lib/fm-branch-eligibility.ts) because a hooks
// module may import only its own files, so this repo side points at it
// instead (the Calm-mod pattern, inverted; the mod binds its own host seam
// itself). The import goes through the sibling symlink
// lib/fm-branch-eligibility-core.ts so a plain file copy of lib/ keeps the
// pair resolvable.
// tests/fm-branch-eligibility.test.sh pins the fold through this wrapper
// against the bash fold on one fixture set, so wherever this module and bash
// disagree, the test fails.

import { foldStatusLines, foldVocabularyFromEnv, scopeForUnreadWake, serializeOpenDecisions, statusKindFromMetaText } from "./fm-branch-eligibility-core.ts";
import type { DecisionVerdictCache, QueueMeta, StatusStat, StatusText, UnreadWakeScope } from "./fm-branch-eligibility-core.ts";
export * from "./fm-branch-eligibility-core.ts";
import { lstatSync, readdirSync, readFileSync } from "node:fs";

// ---- thin default bindings over node:fs ------------------------------------
// What the equivalence test and a plain caller need: bind the pure core to
// one state directory with lstat-based symlink refusal (bash truth), the
// FM_CLASSIFY_* environment, and one module-level verdict cache (Pi's
// posture: one state directory per runtime, so task ids are stable keys).

const defaultVerdictCache: DecisionVerdictCache = new Map();

/** The lstat answer for one path: the version string for a plain file,
 * "absent" for a missing path (ENOENT - bash folds whatever its read
 * captured, which is nothing), or "refused" for a symlinked or otherwise
 * unstattable path. A present-but-unreadable file stats fine here; its
 * refusal surfaces at read time. */
function statVersion(path: string): string | "absent" | "refused" {
  try {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) return "refused";
    return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
  } catch (error) {
    return (error as NodeJS.ErrnoException)?.code === "ENOENT" ? "absent" : "refused";
  }
}

function statStatusOnDisk(state: string, task: string): StatusStat {
  const version = statVersion(`${state}/${task}.status`);
  return version === "absent" ? { state: "absent" } : version === "refused" ? { state: "refused" } : { state: "ok", version };
}

function readStatusTextOnDisk(state: string, task: string): StatusText {
  const path = `${state}/${task}.status`;
  const presence = statVersion(path);
  if (presence === "absent") return { state: "absent" };
  if (presence === "refused") return { state: "refused" };
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (error) {
    // Vanished between stat and read reads as absent (bash's empty fold);
    // a present log that will not read vetoes the scan instead.
    return (error as NodeJS.ErrnoException)?.code === "ENOENT" ? { state: "absent" } : { state: "refused" };
  }
  const version = statVersion(path);
  return version !== presence ? { state: "torn" } : { state: "ok", text, version };
}

function readMetaKindOnDisk(state: string, task: string): string {
  const path = `${state}/${task}.meta`;
  try {
    if (lstatSync(path).isSymbolicLink()) return "unknown";
  } catch {
    return "unknown";
  }
  try {
    return statusKindFromMetaText(readFileSync(path, "utf8"));
  } catch {
    return "unknown";
  }
}

function listQueueMetas(state: string): QueueMeta[] | null {
  try {
    const metas: QueueMeta[] = [];
    for (const entry of readdirSync(state, { withFileTypes: true })) {
      if (!entry.name.endsWith(".meta")) continue;
      const task = entry.name.slice(0, -5);
      const fields = readFileSync(`${state}/${entry.name}`, "utf8").split("\n");
      metas.push({
        task,
        project: fields.find((line) => line.startsWith("project="))?.slice(8) ?? "",
        window: fields.find((line) => line.startsWith("window="))?.slice(7) ?? "",
      });
    }
    return metas;
  } catch {
    return null;
  }
}

export interface StateDirectoryScanOptions {
  heartbeat?: boolean;
  afk?: boolean;
  /** The attended-host recheck, passed through to the shared fold. */
  attendedHost?: boolean;
  cache?: DecisionVerdictCache;
}

/** The scan bound to one state directory over node:fs, with the
 * FM_CLASSIFY_* environment and the module-level verdict cache. */
export function scanStateDirectory(state: string, options: StateDirectoryScanOptions = {}): UnreadWakeScope {
  let queueText: string | null;
  try {
    queueText = readFileSync(`${state}/.wake-queue`, "utf8");
  } catch {
    queueText = null;
  }
  return scopeForUnreadWake({
    queueText,
    metas: listQueueMetas(state),
    statStatus: (task) => statStatusOnDisk(state, task),
    readStatusText: (task) => readStatusTextOnDisk(state, task),
    readKind: (task) => readMetaKindOnDisk(state, task),
    env: foldVocabularyFromEnv((name) => process.env[name]),
    heartbeat: options.heartbeat ?? false,
    afk: options.afk ?? false,
    attendedHost: options.attendedHost ?? false,
    cache: options.cache ?? defaultVerdictCache,
  });
}

/** The bash fold bound to one status log on disk: bash's empty-fold outcome
 * for an absent, unreadable, or symlinked log, the sibling `.meta` kind, and
 * the FM_CLASSIFY_* environment. Emits serializeOpenDecisions bytes - the
 * exact bytes `status_open_decisions` prints. One read pass, bash's own
 * shape - no torn check, since bash folds whatever bytes its single read
 * captured. (The scan vetoes a refused log before the fold ever runs, so
 * fold-level parity with bash holds while rows for unreadable logs stay
 * with main.) */
export function foldStatusLog(dir: string, task: string): string {
  const read = readStatusTextOnDisk(dir, task);
  if (read.state !== "ok") return "";
  const lines = read.text.split("\n");
  const vocab = foldVocabularyFromEnv((name) => process.env[name]);
  return serializeOpenDecisions(foldStatusLines(lines, vocab, readMetaKindOnDisk(dir, task)));
}

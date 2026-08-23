/**
 * Ollama Cloud reserve segment for a Pi worker's footer.
 *
 * Pi's own footer already renders the working directory, the branch, context
 * consumed against its ceiling, tokens exchanged, and the model. This module
 * adds ONLY the one thing Pi cannot know: how much Ollama Cloud headroom is
 * left. It never reproduces a segment Pi already owns.
 *
 * The reserve is read from the fleet's existing probe output, whose contract is
 * owned by the private `srv-ollama-usage-watch` check: a JSON object carrying
 * `fetched_at` (ISO 8601 UTC), `session_free`, and `weekly_free` (fractions in
 * 0..1). This module is a reader of that file, never a second measurement.
 *
 * The displayed number is the SMALLER of the two free fractions, because the
 * tighter window is the one that actually stops work.
 *
 * A reserve that cannot be trusted is rendered as an explicit unknown rather
 * than as a number: a stale figure presented as current is worse than no
 * figure at all.
 */

/** Age past which a probe reading is no longer presented as current. */
export const OLLAMA_RESERVE_MAX_AGE_MS = 60 * 60 * 1000;

/** Footer key this segment owns; Pi sorts extension statuses by key. */
export const OLLAMA_RESERVE_STATUS_KEY = "fm-ollama";

export type OllamaReserveUnknownReason =
  | "absent"
  | "unreadable"
  | "malformed"
  | "stale";

export type OllamaReserve =
  | { readonly kind: "known"; readonly freePercent: number }
  | { readonly kind: "unknown"; readonly reason: OllamaReserveUnknownReason };

const isFiniteFraction = (value: unknown): value is number =>
  typeof value === "number" && Number.isFinite(value);

/**
 * Interpret one raw probe payload.
 *
 * `raw` is the file's contents, or null when the file does not exist.
 * Staleness is judged in BOTH directions: a reading timestamped far in the
 * future is a clock disagreement, and trusting it would let an arbitrarily old
 * number keep looking current forever.
 */
export function parseOllamaReserve(
  raw: string | null,
  nowMs: number,
  maxAgeMs: number = OLLAMA_RESERVE_MAX_AGE_MS,
): OllamaReserve {
  if (raw === null) return { kind: "unknown", reason: "absent" };

  let payload: unknown;
  try {
    payload = JSON.parse(raw);
  } catch {
    return { kind: "unknown", reason: "malformed" };
  }
  if (typeof payload !== "object" || payload === null) {
    return { kind: "unknown", reason: "malformed" };
  }

  const record = payload as Record<string, unknown>;
  const { fetched_at: fetchedAt, session_free: sessionFree, weekly_free: weeklyFree } = record;

  if (!isFiniteFraction(sessionFree) || !isFiniteFraction(weeklyFree)) {
    return { kind: "unknown", reason: "malformed" };
  }
  if (typeof fetchedAt !== "string") {
    return { kind: "unknown", reason: "malformed" };
  }

  const fetchedMs = Date.parse(fetchedAt);
  if (!Number.isFinite(fetchedMs)) {
    return { kind: "unknown", reason: "malformed" };
  }
  if (Math.abs(nowMs - fetchedMs) > maxAgeMs) {
    return { kind: "unknown", reason: "stale" };
  }

  // Floor rather than round: a reserve must never be reported larger than it is.
  const tightest = Math.min(sessionFree, weeklyFree);
  const freePercent = Math.max(0, Math.min(100, Math.floor(tightest * 100)));
  return { kind: "known", freePercent };
}

/** Compact footer text; the footer line is already dense. */
export function formatOllamaReserve(reserve: OllamaReserve): string {
  return reserve.kind === "known" ? `olla ${reserve.freePercent}%` : "olla ?";
}

/**
 * Read and interpret the probe file.
 *
 * A missing file is an ordinary, expected state (the probe only writes once it
 * has credentials and a successful fetch), so it reports "absent" rather than
 * throwing. Any other read failure reports "unreadable". This never throws:
 * a footer segment must not be able to take down a worker's session.
 */
export function readOllamaReserve(
  readFile: (path: string) => string,
  path: string,
  nowMs: number,
  maxAgeMs: number = OLLAMA_RESERVE_MAX_AGE_MS,
): OllamaReserve {
  let raw: string;
  try {
    raw = readFile(path);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException | undefined)?.code;
    if (code === "ENOENT") return { kind: "unknown", reason: "absent" };
    return { kind: "unknown", reason: "unreadable" };
  }
  return parseOllamaReserve(raw, nowMs, maxAgeMs);
}

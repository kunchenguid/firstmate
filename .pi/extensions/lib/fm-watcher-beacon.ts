import { statSync } from "node:fs";
import { join } from "node:path";

export function parseGuardGraceSeconds(raw: string | undefined): number {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) return 300;
  return Math.floor(parsed);
}

export function watcherBeaconAgeMs(stateDir: string, now = Date.now()): number | null {
  try {
    const stat = statSync(join(stateDir, ".last-watcher-beat"));
    return now - stat.mtimeMs;
  } catch {
    return null;
  }
}

// An owned arm child is healthy when its process is alive and either the beacon
// has not been written yet or it is still within FM_GUARD_GRACE.
export function ownedArmChildBeaconIsStale(
  stateDir: string,
  now = Date.now(),
  graceSeconds = parseGuardGraceSeconds(process.env.FM_GUARD_GRACE),
): boolean {
  const age = watcherBeaconAgeMs(stateDir, now);
  if (age === null) return false;
  return age >= graceSeconds * 1000;
}

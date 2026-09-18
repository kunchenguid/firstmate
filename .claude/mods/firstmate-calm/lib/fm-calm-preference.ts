// Shared Calm preference path and persistence for every harness that reads
// gitignored config/calm. docs/configuration.md owns the schema; this module
// owns the atomic write and the on/off/max parse shared by Pi, OMP, and the
// Claude Code mod's presentation helpers.
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";

export type CalmHomeEnvironment = {
  readonly FM_HOME?: string | undefined;
  readonly FM_ROOT_OVERRIDE?: string | undefined;
  readonly FM_CONFIG_OVERRIDE?: string | undefined;
};

/** Resolve the config directory the same way every Calm surface does. */
export function calmConfigDirectory(
  env: CalmHomeEnvironment,
  codeRoot: string,
): string {
  return env.FM_CONFIG_OVERRIDE || resolve(env.FM_HOME || env.FM_ROOT_OVERRIDE || codeRoot, "config");
}

/** Absolute path of the home-local Calm preference file. */
export function calmPreferencePath(
  env: CalmHomeEnvironment,
  codeRoot: string,
): string {
  return resolve(calmConfigDirectory(env, codeRoot), "calm");
}

/**
 * Whether stored preference text reads as Calm on.
 * `max` is the legacy third level whose behavior is now ordinary Calm.
 * Absent, unreadable, or unrecognized values read as off.
 */
export function parseCalmPreference(stored: string | undefined): boolean {
  if (stored === undefined) return false;
  const value = stored.trim();
  return value === "on" || value === "max";
}

/** Exact file content every harness writes for the same choice. */
export function serializeCalmPreference(active: boolean): string {
  return active ? "on\n" : "off\n";
}

/** Read the preference file; missing or unreadable files default to off. */
export function loadCalmPreference(path: string): boolean {
  let stored: string;
  try {
    stored = readFileSync(path, "utf8");
  } catch {
    return false;
  }
  return parseCalmPreference(stored);
}

/**
 * Persist the preference atomically at mode 0600.
 * A failed write leaves the previous file untouched.
 */
export function persistCalmPreference(path: string, active: boolean): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporaryPath, serializeCalmPreference(active), {
      encoding: "utf8",
      flag: "wx",
      mode: 0o600,
    });
    renameSync(temporaryPath, path);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

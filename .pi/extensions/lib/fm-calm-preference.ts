// Firstmate's home-local Calm preference, read and written by the Pi Calm
// extension (.pi/extensions/fm-calm.ts) and the omp Calm extension
// (.omp/extensions/fm-calm-omp.ts). docs/configuration.md owns the contract:
// the effective home is FM_HOME, then FM_ROOT_OVERRIDE, then the tracked code
// root this file sits under, unless FM_CONFIG_OVERRIDE names the config
// directory outright; the persisted values are `on` and `off`, an absent,
// unreadable, or unrecognized value reads as off, and `max`, the legacy value of
// a removed third presentation level whose behavior is now ordinary Calm, still
// reads as on. The environment is resolved on every call so one loaded module
// follows the process environment in effect when each extension uses it.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

function calmPreferencePath(): string {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const configDirectory = process.env.FM_CONFIG_OVERRIDE || resolve(fmHome, "config");
  return resolve(configDirectory, "calm");
}

export function loadCalmPreference(): boolean {
  let stored: string;
  try {
    stored = readFileSync(calmPreferencePath(), "utf8").trim();
  } catch {
    return false;
  }
  return stored === "on" || stored === "max";
}

export function persistCalmPreference(active: boolean): void {
  const path = calmPreferencePath();
  mkdirSync(dirname(path), { recursive: true });
  const temporaryPath = `${path}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporaryPath, active ? "on\n" : "off\n", { encoding: "utf8", flag: "wx", mode: 0o600 });
    renameSync(temporaryPath, path);
  } finally {
    rmSync(temporaryPath, { force: true });
  }
}

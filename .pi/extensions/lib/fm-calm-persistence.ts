// Node persistence for the shared Calm preference contract.
//
// The path, parse, and serialize rules live with the Claude Code mod in
// .claude/mods/firstmate-calm/lib/fm-calm-preference.ts, which stays free of
// Node builtins so Claude Code's hooks-module linker can load it. Pi and OMP do
// their filesystem and crypto work here, importing those rules through the
// tracked .pi symlink. docs/configuration.md owns the persisted schema.
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";
import {
  parseCalmPreference,
  serializeCalmPreference,
} from "./fm-calm-preference.ts";

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

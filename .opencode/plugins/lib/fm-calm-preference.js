import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";

function nonempty(value) {
  if (value === undefined || value === null) return undefined;
  const text = String(value);
  return text === "" ? undefined : text;
}

export function calmCodeRootFromPluginFile(pluginFile) {
  return resolve(dirname(pluginFile), "../..");
}

export function calmPreferencePath(env, pluginFile) {
  const configDirectory =
    nonempty(env?.FM_CONFIG_OVERRIDE) ||
    resolve(
      nonempty(env?.FM_HOME) || nonempty(env?.FM_ROOT_OVERRIDE) || calmCodeRootFromPluginFile(pluginFile),
      "config",
    );
  return resolve(configDirectory, "calm");
}

export function parseCalmPreference(stored) {
  if (stored === undefined || stored === null) return false;
  const value = String(stored).trim();
  return value === "on" || value === "max";
}

export function serializeCalmPreference(active) {
  return active ? "on\n" : "off\n";
}

export function loadCalmPreference(path) {
  try {
    return parseCalmPreference(readFileSync(path, "utf8"));
  } catch {
    return false;
  }
}

export function persistCalmPreference(path, active) {
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

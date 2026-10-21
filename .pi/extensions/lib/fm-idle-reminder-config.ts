import { existsSync, lstatSync, readFileSync } from "node:fs";

export type ProactiveReportingScope = "unfinished-and-decisions" | "decisions-only";

export type IdleReminderConfig = {
  version: 1;
  enabled: boolean;
  interval_seconds: number;
  reporting_scope: ProactiveReportingScope;
  enabledAtMs: number;
};

export function readIdleReminderConfig(configFile: string): { config?: IdleReminderConfig; error?: string } {
  if (!existsSync(configFile)) return {};
  try {
    const info = lstatSync(configFile);
    if (info.isSymbolicLink() || !info.isFile()) {
      return { error: "config/idle-reminder.json must be a regular non-symlink file" };
    }
    const raw: unknown = JSON.parse(readFileSync(configFile, "utf8"));
    if (!raw || typeof raw !== "object") return { error: "idle reminder config must be a JSON object" };
    const value = raw as Record<string, unknown>;
    const keys = Object.keys(value).sort().join(",");
    if (keys !== "enabled,interval_seconds,version" && keys !== "enabled,interval_seconds,reporting_scope,version") {
      return { error: "idle reminder config has unknown or missing fields" };
    }
    const reportingScope = value.reporting_scope ?? "unfinished-and-decisions";
    if (value.version !== 1 || typeof value.enabled !== "boolean" ||
        !Number.isSafeInteger(value.interval_seconds) || Number(value.interval_seconds) < 1800 ||
        (reportingScope !== "unfinished-and-decisions" && reportingScope !== "decisions-only")) {
      return { error: "idle reminder config requires version 1, a boolean enabled value, interval_seconds >=1800, and a supported reporting_scope" };
    }
    return { config: { version: 1, enabled: value.enabled,
      interval_seconds: Number(value.interval_seconds), reporting_scope: reportingScope,
      enabledAtMs: info.mtimeMs } };
  } catch (error) {
    return { error: `cannot read idle reminder config: ${String(error)}` };
  }
}

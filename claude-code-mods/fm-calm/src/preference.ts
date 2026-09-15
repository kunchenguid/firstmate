export type CalmPreference = "on" | "off";

const CALM_ON_VALUES = ["on", "max"];

export function parseCalmPreference(stored: string | undefined): CalmPreference {
  if (typeof stored !== "string") return "off";
  return CALM_ON_VALUES.includes(stored.trim()) ? "on" : "off";
}

export function formatCalmPreference(active: boolean): string {
  return active ? "on\n" : "off\n";
}

export type CalmHomeEnvironment = {
  configOverride?: string | undefined;
  home?: string | undefined;
  rootOverride?: string | undefined;
};

export function resolveCalmConfigPath(environment: CalmHomeEnvironment): string | undefined {
  const nonEmpty = (value: string | undefined): string | undefined =>
    typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;

  const override = nonEmpty(environment.configOverride);
  if (override !== undefined) return `${override.replace(/[\\/]+$/, "")}/calm`;

  const home = nonEmpty(environment.home) ?? nonEmpty(environment.rootOverride);
  if (home !== undefined) return `${home.replace(/[\\/]+$/, "")}/config/calm`;

  return undefined;
}
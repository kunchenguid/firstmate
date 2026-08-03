// Shared environment parsing for the tracked Firstmate Pi extensions.
// docs/configuration.md owns the meaning and default of every variable read
// through this helper.

/** Read `name` as a positive integer, falling back on anything unusable. */
export function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

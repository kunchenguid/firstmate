// Shared Calm preference path and value rules for every harness that reads
// gitignored config/calm. docs/configuration.md owns the schema; this module
// owns the on/off/max parse and the per-home path shared by Pi, OMP, and the
// Claude Code mod's presentation helpers. It stays free of Node builtins so the
// Claude Code hooks-module linker can reach it through fm-calm-presentation.ts;
// the Node fs/crypto persistence lives in .pi/extensions/lib/fm-calm-persistence.ts.

export type CalmHomeEnvironment = {
  readonly FM_HOME?: string | undefined;
  readonly FM_ROOT_OVERRIDE?: string | undefined;
  readonly FM_CONFIG_OVERRIDE?: string | undefined;
};

/** Join a base directory and one child segment with a single forward slash. */
function joinConfigPath(base: string, child: string): string {
  return `${base.replace(/[\\/]+$/, "")}/${child}`;
}

/** Resolve the config directory the same way every Calm surface does. */
export function calmConfigDirectory(
  env: CalmHomeEnvironment,
  codeRoot: string,
): string {
  if (env.FM_CONFIG_OVERRIDE) {
    return env.FM_CONFIG_OVERRIDE.replace(/[\\/]+$/, "");
  }
  return joinConfigPath(env.FM_HOME || env.FM_ROOT_OVERRIDE || codeRoot, "config");
}

/** Absolute path of the home-local Calm preference file. */
export function calmPreferencePath(
  env: CalmHomeEnvironment,
  codeRoot: string,
): string {
  return joinConfigPath(calmConfigDirectory(env, codeRoot), "calm");
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

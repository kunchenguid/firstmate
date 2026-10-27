import { lstatSync, realpathSync, statSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";

const bindingType = "firstmate-pi-home-binding";
const bindingSchema = "firstmate.pi-home-binding.v1";

type SessionEntry = {
  type?: unknown;
  customType?: unknown;
  data?: unknown;
};

type SessionManager = {
  getHeader?: () => { timestamp?: unknown } | null | undefined;
  getSessionFile?: () => string | undefined;
  getEntries?: () => readonly SessionEntry[];
  appendCustomEntry?: (customType: string, data?: unknown) => string;
};

export type PiHomeContext = {
  sessionManager?: SessionManager;
};

export type PiHomeResolution =
  | { ok: true; home: string; state: string; config: string; recorded: boolean }
  | { ok: false; reason: string };

type Binding = {
  schema: typeof bindingSchema;
  home: string;
};

function canonicalHome(value: string): string | undefined {
  if (!value || !value.startsWith("/") || value.includes("\0") || value.includes("\n")) return undefined;
  try {
    const canonical = realpathSync(value);
    const stat = statSync(canonical);
    if (!stat.isDirectory()) return undefined;
    if (typeof process.getuid === "function" && stat.uid !== process.getuid()) return undefined;
    if ((stat.mode & 0o022) !== 0) return undefined;
    return canonical;
  } catch {
    return undefined;
  }
}

type SessionAge = "fresh" | "restored" | "ambiguous";

function sessionAge(ctx: PiHomeContext, reason: string | undefined): SessionAge {
  if (["resume", "reload"].includes(reason ?? "")) return "restored";
  if (["new", "fork"].includes(reason ?? "")) return "fresh";
  try {
    const timestamp = ctx.sessionManager?.getHeader?.()?.timestamp;
    const createdAt = typeof timestamp === "string" ? Date.parse(timestamp) : Number.NaN;
    if (!Number.isFinite(createdAt)) return "ambiguous";
    const now = Date.now();
    if (createdAt > now + 5 * 60 * 1000) return "ambiguous";
    if (createdAt < performance.timeOrigin - 60 * 1000) return "restored";
    return "fresh";
  } catch {
    return "ambiguous";
  }
}

function safeSessionFile(path: string): boolean {
  if (!path.startsWith("/") || path.includes("\0") || path.includes("\n")) return false;
  if (resolve(path) !== path) return false;
  const parentPath = dirname(path);
  try {
    const parent = lstatSync(parentPath);
    if (!parent.isDirectory() || parent.isSymbolicLink()) return false;
    if (typeof process.getuid === "function" && parent.uid !== process.getuid()) return false;
    if ((parent.mode & 0o022) !== 0 || realpathSync(parentPath) !== parentPath) return false;
  } catch {
    return false;
  }
  try {
    const file = lstatSync(path);
    if (!file.isFile() || file.isSymbolicLink()) return false;
    if (typeof process.getuid === "function" && file.uid !== process.getuid()) return false;
    if ((file.mode & 0o022) !== 0) return false;
    return realpathSync(path) === path;
  } catch (error) {
    // Pi's native SessionManager exposes the canonical future path before it
    // materializes the JSONL file. This is safe only under the validated,
    // canonical session directory above; a broken symlink is rejected by
    // lstatSync rather than treated as an absent file.
    return (error as NodeJS.ErrnoException).code === "ENOENT";
  }
}

function safeOverride(home: string, value: string | undefined, label: string): string | undefined {
  if (!value) return undefined;
  const candidate = resolve(value);
  const isWithinHome = (path: string): boolean => {
    const fromHome = relative(home, path);
    return fromHome === "" || (!fromHome.startsWith("..") && !isAbsolute(fromHome));
  };
  if (!isWithinHome(candidate)) {
    throw new Error(`${label} points outside the bound Pi home`);
  }

  // Resolve the nearest existing ancestor before accepting a path with a
  // not-yet-created suffix. This catches an existing symlink ancestor that
  // redirects outside the bound home.
  let existing = candidate;
  while (true) {
    try {
      const canonicalExisting = realpathSync(existing);
      if (!isWithinHome(canonicalExisting)) {
        throw new Error(`${label} resolves outside the bound Pi home`);
      }
      const suffix = relative(existing, candidate);
      const resolvedCandidate = suffix ? resolve(canonicalExisting, suffix) : canonicalExisting;
      if (!isWithinHome(resolvedCandidate)) {
        throw new Error(`${label} resolves outside the bound Pi home`);
      }
      return resolvedCandidate;
    } catch (error) {
      if (error instanceof Error && error.message.includes("resolves outside")) throw error;
      const parent = dirname(existing);
      if (parent === existing) throw new Error(`${label} cannot be resolved safely`);
      existing = parent;
    }
  }
}

function boundPaths(home: string): { state: string; config: string } {
  const state = safeOverride(home, process.env.FM_STATE_OVERRIDE || `${home}/state`, "FM_STATE_OVERRIDE");
  const config = safeOverride(home, process.env.FM_CONFIG_OVERRIDE || `${home}/config`, "FM_CONFIG_OVERRIDE");
  if (!state || !config) throw new Error("Pi home state/config paths could not be resolved safely");
  return { state, config };
}

function sessionBindings(ctx: PiHomeContext): Binding[] {
  const entries = ctx.sessionManager?.getEntries?.() ?? [];
  const bindings: Binding[] = [];
  for (const entry of entries) {
    if (entry.type !== "custom" || entry.customType !== bindingType) continue;
    const data = entry.data;
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw new Error("Pi session home binding is malformed");
    }
    const candidate = data as { schema?: unknown; home?: unknown };
    if (candidate.schema !== bindingSchema || typeof candidate.home !== "string") {
      throw new Error("Pi session home binding is malformed");
    }
    const home = canonicalHome(candidate.home);
    if (!home) throw new Error("Pi session home binding points at an unsafe home");
    bindings.push({ schema: bindingSchema, home });
  }
  return bindings;
}

export function resolvePiHome(
  ctx: PiHomeContext | undefined,
  fallbackHome: string,
  reason: string | undefined,
  sourceRoot?: string,
  appendEntry?: (customType: string, data?: unknown) => void,
): PiHomeResolution {
  const fallback = canonicalHome(fallbackHome);
  if (!fallback) return { ok: false, reason: "the configured FM_HOME is not a safe owned directory" };
  if (process.env.FM_ROOT_OVERRIDE && sourceRoot) {
    try {
      if (realpathSync(process.env.FM_ROOT_OVERRIDE) !== realpathSync(sourceRoot)) {
        return { ok: false, reason: "FM_ROOT_OVERRIDE does not identify this Firstmate source root" };
      }
    } catch {
      return { ok: false, reason: "FM_ROOT_OVERRIDE is not a resolvable Firstmate source root" };
    }
  }

  const sessionManager = ctx?.sessionManager;
  const sessionFile = sessionManager?.getSessionFile?.();
  if (!sessionManager || !sessionFile) {
    if (["new", "fork"].includes(reason ?? "")) {
      // Explicitly fresh sessions may operate in ephemeral mode when Pi does
      // not expose a persistent session identity. They cannot be restored
      // safely, so no binding is claimed or written.
      const paths = boundPaths(fallback);
      return { ok: true, home: fallback, ...paths, recorded: false };
    }
    return { ok: false, reason: "persistent Pi session identity is unavailable for this session reason" };
  }
  if (!safeSessionFile(sessionFile)) {
    return { ok: false, reason: "Pi session file or its parent is not owned, regular, and non-symlink storage" };
  }

  let bindings: Binding[];
  try {
    bindings = sessionBindings(ctx!);
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message : String(error) };
  }
  const homes = [...new Set(bindings.map((binding) => binding.home))];
  if (homes.length > 1) return { ok: false, reason: "Pi session has conflicting home bindings" };
  const boundHome = homes[0];
  if (boundHome) {
    try {
      const paths = boundPaths(boundHome);
      return { ok: true, home: boundHome, ...paths, recorded: true };
    } catch (error) {
      return { ok: false, reason: error instanceof Error ? error.message : String(error) };
    }
  }

  // A restored session without an identity cannot safely be upgraded from the
  // process environment: after Herdr recovery that environment may belong to a
  // sibling home. Fresh sessions can establish their identity once.
  const age = sessionAge(ctx, reason);
  if (age !== "fresh") {
    return { ok: false, reason: age === "restored"
      ? "restored Pi session has no durable Firstmate home binding"
      : "Pi session age is ambiguous; refusing to infer its Firstmate home" };
  }
  const persistEntry = appendEntry ?? sessionManager.appendCustomEntry;
  if (!persistEntry) {
    return { ok: false, reason: "Pi session manager cannot persist a Firstmate home binding" };
  }
  let paths: { state: string; config: string };
  try {
    paths = boundPaths(fallback);
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message : String(error) };
  }
  try {
    persistEntry(bindingType, { schema: bindingSchema, home: fallback });
  } catch (error) {
    return { ok: false, reason: `could not persist Pi session home binding: ${error instanceof Error ? error.message : String(error)}` };
  }
  return { ok: true, home: fallback, ...paths, recorded: true };
}

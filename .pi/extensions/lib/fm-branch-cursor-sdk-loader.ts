// Fleet overlay: load pi-cursor-sdk for the supervision branch without project extensions.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

export type AgentSettings = { defaultProvider?: string; defaultModel?: string };

export function readAgentSettings(agentDir: string): AgentSettings {
  try {
    return JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8")) as AgentSettings;
  } catch {
    return {};
  }
}

export function providerFromSettings(settings: AgentSettings): string {
  if (settings.defaultProvider) return settings.defaultProvider;
  const model = settings.defaultModel ?? "";
  const slash = model.indexOf("/");
  if (slash > 0) return model.slice(0, slash);
  return "";
}

export function resolvePiCursorSdkExtensionPath(agentDir: string): string | null {
  const pkgCandidates = [join(agentDir, "npm/node_modules/pi-cursor-sdk/package.json")];
  const npmRoot = spawnSync("npm", ["root", "-g"], { encoding: "utf8" });
  if (npmRoot.status === 0) {
    const root = npmRoot.stdout.trim();
    if (root) pkgCandidates.push(join(root, "pi-cursor-sdk/package.json"));
  }
  for (const pkgJson of pkgCandidates) {
    if (!existsSync(pkgJson)) continue;
    try {
      const pkg = JSON.parse(readFileSync(pkgJson, "utf8")) as {
        pi?: { extensions?: string[] };
      };
      const rel = pkg.pi?.extensions?.[0] ?? "./src/index.ts";
      const extPath = resolve(dirname(pkgJson), rel);
      if (existsSync(extPath)) return extPath;
    } catch {
      // Try the next install location.
    }
  }
  return null;
}

export function resolveCursorSdkLoaderPaths(
  agentDir: string,
  targetProvider: string,
): string[] {
  if (targetProvider !== "cursor") return [];
  const sdkPath = resolvePiCursorSdkExtensionPath(agentDir);
  if (!sdkPath) {
    throw new Error(
      "supervision branch requires pi-cursor-sdk because the configured branch model uses the Cursor provider, but the package extension could not be resolved from the Pi agent dir (install pi-cursor-sdk via settings packages or pi update --extensions)",
    );
  }
  if (sdkPath.endsWith("fm-branch-supervision.ts")) {
    throw new Error("supervision branch refused a recursive fm-branch-supervision extension path");
  }
  return [sdkPath];
}

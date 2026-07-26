export type CalmCompatibilitySurfaces = {
  assistantLayout: boolean;
  operationalUserLayout: boolean;
  builtInRenderers: readonly string[];
};

export const CALM_COMPATIBLE_PI_VERSIONS = ["0.81.1", "0.82.0", "0.82.1"] as const;
const REQUIRED_BUILT_INS = ["read", "bash", "edit", "write", "grep", "find", "ls"] as const;

export function calmCompatibilityFailure(
  version: string,
  surfaces: CalmCompatibilitySurfaces,
): string | undefined {
  if (!(CALM_COMPATIBLE_PI_VERSIONS as readonly string[]).includes(version)) {
    return `unsupported Pi ${version}`;
  }
  if (!surfaces.assistantLayout) {
    return "Pi AssistantMessageComponent.updateContent is unavailable";
  }
  if (!surfaces.operationalUserLayout) {
    return "Pi InteractiveMode.addMessageToChat is unavailable";
  }
  const renderers = new Set(surfaces.builtInRenderers);
  const missing = REQUIRED_BUILT_INS.filter((name) => !renderers.has(name));
  if (missing.length > 0) {
    return `Pi built-in renderer slots are unavailable for: ${missing.join(", ")}`;
  }
  return undefined;
}

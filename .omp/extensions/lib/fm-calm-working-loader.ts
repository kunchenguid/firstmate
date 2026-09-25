// omp has no ExtensionUIContext.setWorkingVisible.
// Calm hides the stock working spinner by gating InteractiveMode.ensureLoadingAnimation
// while Calm is active, and clears any already-mounted loader on the live instance when
// a session UI context is available. It probes that exact method and throws if it is
// missing; fm-calm.ts catches that and skips only this adapter with a diagnostic.
// ./fm-calm-visibility.ts owns the Calm on/off policy.
import * as OmpCodingAgent from "@oh-my-pi/pi-coding-agent";
import { calmPresentationIsActive } from "./fm-calm-visibility.ts";

type LoadingAnimation = {
  stop?: () => void;
};

type InteractiveModeLoaderHost = {
  loadingAnimation?: LoadingAnimation;
  statusContainer?: {
    disposeChildren?: () => void;
    clear?: () => void;
  };
  ensureLoadingAnimation?: () => void;
};

type InteractiveModeLoaderPrototype = {
  ensureLoadingAnimation: (this: InteractiveModeLoaderHost) => void;
};

type CalmWorkingLoaderPatch = {
  calmBlocksLoader: () => boolean;
};

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_WORKING_LOADER_PATCH = Symbol.for(
  "firstmate:calm-working-loader:omp-18",
);

function clearMountedLoader(host: InteractiveModeLoaderHost): void {
  if (host.loadingAnimation?.stop) {
    try {
      host.loadingAnimation.stop();
    } catch {
      // Best-effort: a disposed animation must not break Calm.
    }
  }
  host.loadingAnimation = undefined;
  host.statusContainer?.disposeChildren?.();
  host.statusContainer?.clear?.();
}

export function installCalmWorkingLoaderGate(): void {
  const registry = globalThis as typeof globalThis & {
    [key: symbol]: CalmWorkingLoaderPatch | undefined;
  };
  const calmBlocksLoader = (): boolean => calmPresentationIsActive();
  const installed = registry[CALM_WORKING_LOADER_PATCH];
  if (installed) {
    installed.calmBlocksLoader = calmBlocksLoader;
    return;
  }

  const patch: CalmWorkingLoaderPatch = { calmBlocksLoader };
  if (typeof OmpCodingAgent.InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires omp InteractiveMode");
  }
  // omp ships no type package; assert the runtime prototype shape probed below.
  const prototype = OmpCodingAgent.InteractiveMode.prototype as unknown as InteractiveModeLoaderPrototype;
  const original = prototype.ensureLoadingAnimation;
  if (typeof original !== "function") {
    throw new Error("Firstmate Calm requires omp InteractiveMode.ensureLoadingAnimation");
  }

  prototype.ensureLoadingAnimation = function (this: InteractiveModeLoaderHost): void {
    if (patch.calmBlocksLoader()) {
      clearMountedLoader(this);
      return;
    }
    original.call(this);
  };

  registry[CALM_WORKING_LOADER_PATCH] = patch;
}

// Clear a live InteractiveMode loader when Calm turns on mid-run. The InteractiveMode
// instance is not directly exposed, so walk the known private host field on ui.ctx only
// when present.
export function clearLiveWorkingLoader(ui: { ctx?: unknown }): void {
  const host = ui.ctx;
  if (host && typeof host === "object") {
    // ui.ctx is omp's private InteractiveMode host; the cleared fields are optional-chained.
    clearMountedLoader(host as InteractiveModeLoaderHost);
  }
}

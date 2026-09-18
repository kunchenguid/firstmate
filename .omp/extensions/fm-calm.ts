// Firstmate's home-persistent OMP transcript presentation toggle (hide-ceremony).
//
// Verified against omp 18.1.17 public ExtensionAPI seams:
// registerMessageRenderer, registerAssistantThinkingRenderer, and registerCommand.
// Each seam is probed at load; a missing seam degrades only that adapter with a
// diagnostic. OMP-native InteractiveMode / AssistantMessageComponent adapters in
// ./lib fill the user-row and thinking gaps those public seams cannot cover alone
// (omp's registerMessageRenderer is customType-keyed; its thinking renderer is
// supplemental below visible thinking). Do not load .pi/extensions/fm-calm.ts
// from OMP, and do not port the working-ship / boat path - that stays Pi-only.
// docs/configuration.md owns the shared config/calm preference contract.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  loadCalmPreference,
  persistCalmPreference,
  calmPreferencePath,
} from "../../.pi/extensions/lib/fm-calm-preference.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  setCalmPresentation,
} from "../../.pi/extensions/lib/fm-calm-visibility-core.ts";
import {
  applyOmpCalmThinkingToRememberedRows,
  installOmpCalmAssistantThinking,
  resetOmpCalmThinkingRememberedRows,
} from "./lib/fm-calm-assistant-thinking.ts";
import { installOmpCalmOperationalUserLayout } from "./lib/fm-calm-operational-user.ts";

type ExtensionAPI = {
  on?: (event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => void;
  events?: { emit?: (name: string, payload: unknown) => void };
  registerCommand?: (
    name: string,
    command: {
      description: string;
      handler: (args: string, ctx: ExtensionContext) => Promise<void> | void;
    },
  ) => void;
  registerMessageRenderer?: (
    customType: string,
    renderer: (message: unknown, options: { expanded: boolean }, theme: unknown) => unknown,
  ) => void;
  registerAssistantThinkingRenderer?: (
    renderer: (
      context: {
        contentIndex: number;
        thinkingIndex: number;
        text: string;
        requestRender: () => void;
      },
      theme: unknown,
    ) => unknown,
  ) => void;
  pi?: { Container?: new () => { addChild?(child: unknown): void } };
};

type ExtensionContext = {
  ui?: {
    notify?: (message: string, level?: string) => void;
    getToolsExpanded?: () => boolean;
    setToolsExpanded?: (expanded: boolean) => void;
    setStatus?: (key: string, text: string | undefined) => void;
  };
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");

// Custom message types Firstmate may show in the OMP transcript. Session-start
// already uses display:false; these renderers hide any displayed siblings when
// Calm is on without touching model context or session storage.
const FIRSTMATE_CUSTOM_MESSAGE_TYPES = [
  "firstmate-sessionstart-nudge",
  "firstmate-synthetic-input-presentation",
] as const;

function installCalmPresentationAdapter(name: string, install: () => void): void {
  try {
    install();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    console.error(`Firstmate Calm: ${name} presentation adapter unavailable, skipping. ${reason}`);
  }
}

function emptyComponent(pi: ExtensionAPI): unknown {
  const Container = pi.pi?.Container;
  if (typeof Container === "function") return new Container();
  return {
    render() {
      return [] as string[];
    },
  };
}

function redrawTranscript(ui: ExtensionContext["ui"]): void {
  if (!ui?.getToolsExpanded || !ui.setToolsExpanded) return;
  const expanded = ui.getToolsExpanded();
  ui.setToolsExpanded(!expanded);
  ui.setToolsExpanded(expanded);
}

export default function (pi: ExtensionAPI) {
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
  const preferencePath = calmPreferencePath(
    {
      FM_HOME: process.env.FM_HOME,
      FM_ROOT_OVERRIDE: process.env.FM_ROOT_OVERRIDE,
      FM_CONFIG_OVERRIDE: process.env.FM_CONFIG_OVERRIDE,
    },
    root,
  );

  const publishPresentationState = (): void => {
    pi.events?.emit?.(FIRSTMATE_CALM_PRESENTATION_EVENT, {
      active: calmPresentationIsActive(),
      stockExportRendering: false,
    });
  };

  const applyLivePresentation = (ui?: ExtensionContext["ui"]): void => {
    applyOmpCalmThinkingToRememberedRows();
    redrawTranscript(ui);
    ui?.setStatus?.("firstmate-calm", undefined);
  };

  // Public ExtensionAPI seams - probe each independently.
  installCalmPresentationAdapter("message-renderer", () => {
    if (typeof pi.registerMessageRenderer !== "function") {
      throw new Error("Firstmate Calm requires OMP registerMessageRenderer");
    }
    for (const customType of FIRSTMATE_CUSTOM_MESSAGE_TYPES) {
      pi.registerMessageRenderer(customType, (_message, _options, _theme) => {
        if (calmPresentationHides("synthetic-user") || calmPresentationHides("custom-message")) {
          return emptyComponent(pi);
        }
        return undefined;
      });
    }
  });

  installCalmPresentationAdapter("assistant-thinking-renderer", () => {
    if (typeof pi.registerAssistantThinkingRenderer !== "function") {
      throw new Error("Firstmate Calm requires OMP registerAssistantThinkingRenderer");
    }
    // Supplemental only: when Calm hides thinking the OMP assistant adapter has
    // already collapsed the block, so this returns no extra UI beneath it.
    pi.registerAssistantThinkingRenderer((_context, _theme) => {
      if (calmPresentationHides("assistant-thinking")) return undefined;
      return undefined;
    });
  });

  installCalmPresentationAdapter("operational-user-row", installOmpCalmOperationalUserLayout);
  installCalmPresentationAdapter("collapsed-thinking", installOmpCalmAssistantThinking);

  if (typeof pi.registerCommand !== "function") {
    console.error(
      "Firstmate Calm: registerCommand presentation adapter unavailable, skipping. Firstmate Calm requires OMP registerCommand",
    );
  } else {
    pi.registerCommand("calm", {
      description: "Toggle Firstmate's supported conversation-only transcript presentation.",
      handler: async (_args, ctx) => {
        const active = !calmPresentationIsActive();
        try {
          persistCalmPreference(preferencePath, active);
        } catch (error) {
          const reason = error instanceof Error ? error.message : String(error);
          ctx.ui?.notify?.(`Calm preference could not be saved: ${reason}`, "error");
          return;
        }
        setCalmPresentation(active);
        publishPresentationState();
        applyLivePresentation(ctx.ui);
      },
    });
  }

  pi.on?.("session_start", (_event, ctx) => {
    resetOmpCalmThinkingRememberedRows();
    setCalmPresentation(loadCalmPreference(preferencePath));
    publishPresentationState();
    applyLivePresentation(ctx.ui);
  });

  // Load-time preference so restored rows see Calm before the first paint when
  // the home already has config/calm on. session_start reloads it for replacements.
  setCalmPresentation(loadCalmPreference(preferencePath));
  publishPresentationState();
}

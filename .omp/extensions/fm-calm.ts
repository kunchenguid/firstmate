// Firstmate's home-persistent OMP transcript presentation toggle (hide-ceremony).
//
// Verified against omp 18.1.17 public ExtensionAPI seams:
// registerMessageRenderer and registerCommand. Each seam is probed at load; a
// missing seam degrades only that adapter with a diagnostic. OMP-native
// InteractiveMode / AssistantMessageComponent / ToolExecutionComponent adapters
// in ./lib fill the user-row, thinking, working-note, and operational-tool gaps
// those public seams cannot cover alone (omp's registerMessageRenderer is
// customType-keyed). Do not load .pi/extensions/fm-calm.ts from OMP, and do not
// port the working-ship / boat path - that stays Pi-only.
// docs/configuration.md owns the shared config/calm preference contract.
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { calmPreferencePath } from "../../.pi/extensions/lib/fm-calm-preference.ts";
import {
  loadCalmPreference,
  persistCalmPreference,
} from "../../.pi/extensions/lib/fm-calm-persistence.ts";
import {
  calmPresentationHides,
  calmPresentationIsActive,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  setCalmPresentation,
} from "../../.pi/extensions/lib/fm-calm-visibility-core.ts";
import {
  applyOmpCalmThinkingToRememberedRows,
  installOmpCalmAssistantThinking,
  rememberOmpCalmAssistantMessage,
  resetOmpCalmThinkingRememberedRows,
} from "./lib/fm-calm-assistant-thinking.ts";
import { installOmpCalmOperationalUserLayout } from "./lib/fm-calm-operational-user.ts";
import {
  installOmpCalmOperationalToolLayout,
  rememberOmpCalmToolCalls,
} from "./lib/fm-calm-operational-tool.ts";

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

  installCalmPresentationAdapter("operational-user-row", installOmpCalmOperationalUserLayout);
  installCalmPresentationAdapter("operational-tool-row", installOmpCalmOperationalToolLayout);
  installCalmPresentationAdapter("collapsed-thinking", installOmpCalmAssistantThinking);

  // OMP splits every assistant message at its first tool call before feeding it
  // to AssistantMessageComponent, so the component only ever receives a derived
  // before-tools message. OMP's own assistant message events carry the
  // unfiltered message; remember its tool-call state there, and in
  // InteractiveMode.addMessageToChat for restored transcripts, so Calm can still
  // collapse a short mid-turn working note and recover an operational tool
  // row's constructor-supplied invocation by toolCallId.
  for (const event of ["message_start", "message_update", "message_end"]) {
    pi.on?.(event, (payload) => {
      const message = (payload as { message?: unknown } | undefined)?.message;
      if (message && typeof message === "object") {
        rememberOmpCalmAssistantMessage(
          message as Parameters<typeof rememberOmpCalmAssistantMessage>[0],
        );
        rememberOmpCalmToolCalls(message);
      }
    });
  }

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

  const resetForSessionReplacement = (_event: unknown, ctx: ExtensionContext): void => {
    resetOmpCalmThinkingRememberedRows();
    setCalmPresentation(loadCalmPreference(preferencePath));
    publishPresentationState();
    applyLivePresentation(ctx.ui);
  };
  for (const event of [
    "session_start",
    "session_switch",
    "session_branch",
    "session_tree",
  ]) {
    pi.on?.(event, resetForSessionReplacement);
  }

  // Load-time preference so restored rows see Calm before the first paint when
  // the home already has config/calm on. The session-start and in-process
  // replacement events reload it.
  setCalmPresentation(loadCalmPreference(preferencePath));
  publishPresentationState();
}

import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import {
  calmPresentationHides,
  FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
  type FirstmateSyntheticKind,
} from "./fm-calm-visibility-core.ts";

export {
  CALM_TRANSCRIPT_CLASSES,
  FIRSTMATE_CALM_PRESENTATION_EVENT,
  FIRSTMATE_SYNTHETIC_KINDS,
  FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
  calmPresentationHides,
  calmPresentationIsActive,
  calmTranscriptClassIsVisible,
  setCalmPresentation,
  setCalmStockExportRendering,
  type CalmPresentationState,
  type CalmTranscriptClass,
  type FirstmateSyntheticKind,
} from "./fm-calm-visibility-core.ts";

type FirstmateSyntheticPresentation = {
  content: string;
  kind: FirstmateSyntheticKind;
};

export function registerFirstmateSyntheticPresentation(pi: ExtensionAPI): void {
  pi.registerEntryRenderer<FirstmateSyntheticPresentation>(
    FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
    (entry) => {
      if (calmPresentationHides("synthetic-user")) return undefined;
      const data = entry.data;
      if (!data || typeof data.content !== "string") return undefined;
      return new UserMessageComponent(data.content, getMarkdownTheme());
    },
  );
}

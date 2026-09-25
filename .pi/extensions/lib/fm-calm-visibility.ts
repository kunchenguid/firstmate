// Pi harness wrapper around the package-free Calm visibility core.
// ./fm-calm-visibility-core.ts owns the allowlist, state, and classification helpers;
// this file adds only Pi's synthetic-input renderer, which needs the Pi package.
import {
  getMarkdownTheme,
  type ExtensionAPI,
  UserMessageComponent,
} from "@earendil-works/pi-coding-agent";
import {
  calmPresentationHides,
  FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
  type FirstmateSyntheticPresentation,
} from "./fm-calm-visibility-core.ts";

export * from "./fm-calm-visibility-core.ts";

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

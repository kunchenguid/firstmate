// omp harness wrapper around the package-free Calm visibility core.
// ../../../.pi/extensions/lib/fm-calm-visibility-core.ts owns the allowlist, state,
// and classification helpers; this file adds only omp's synthetic-input renderer,
// which needs the omp package. omp documents registerMessageRenderer, so this path
// prefers it and keeps registerEntryRenderer as a compatibility fallback.
import {
  getMarkdownTheme,
  UserMessageComponent,
} from "@oh-my-pi/pi-coding-agent";
import {
  calmPresentationHides,
  FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
  type FirstmateSyntheticPresentation,
} from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";

export * from "../../../.pi/extensions/lib/fm-calm-visibility-core.ts";

type MessageRendererApi = {
  registerMessageRenderer?: (
    customType: string,
    renderer: (
      message: { content?: unknown; data?: unknown },
      options: { expanded: boolean },
      theme: unknown,
    ) => unknown,
  ) => void;
  registerEntryRenderer?: (
    customType: string,
    renderer: (entry: { data?: FirstmateSyntheticPresentation }) => unknown,
  ) => void;
};

// The renderer callback receives an untyped custom message, so narrow to the one
// field Calm renders instead of trusting an asserted shape.
function presentationContent(value: unknown): string | undefined {
  if (
    value &&
    typeof value === "object" &&
    "content" in value &&
    typeof value.content === "string"
  ) {
    return value.content;
  }
  return undefined;
}

export function registerFirstmateSyntheticPresentation(pi: MessageRendererApi): void {
  const render = (content: string | undefined) => {
    if (calmPresentationHides("synthetic-user") || content === undefined) return undefined;
    return new UserMessageComponent(content, getMarkdownTheme());
  };

  if (typeof pi.registerMessageRenderer === "function") {
    pi.registerMessageRenderer(FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE, (message) =>
      render(presentationContent(message.data) ?? presentationContent(message)),
    );
    return;
  }
  if (typeof pi.registerEntryRenderer === "function") {
    pi.registerEntryRenderer(FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE, (entry) =>
      render(presentationContent(entry.data)),
    );
  }
}

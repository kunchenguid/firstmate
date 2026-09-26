// Firstmate's inline image display for Pi.
//
// /image <path> shows a local PNG, JPEG, or WebP file in this session's
// transcript, and the fm_show_image tool lets the agent deliberately show a file
// or generated artifact the same way instead of only printing its path. Neither
// sends pixels to the model: the command records a custom session entry, which
// Pi keeps out of model context, and the tool returns only text while its
// renderer draws the image from the result details. Both persist the bounded
// display copy, so a resumed session shows the image it showed before even if
// the file has since changed.
//
// ./lib/fm-image-display.ts owns validation, the bounded display copy, and the
// rendering component; Pi's TUI owns the terminal image protocol.
// docs/inline-images.md owns the operator-facing behavior.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Container, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import {
  describeImage,
  FmImageComponent,
  type FmImageView,
  loadImageForDisplay,
  parseImageView,
  sanitizeForDisplay,
} from "./lib/fm-image-display.ts";

export const FM_IMAGE_ENTRY_TYPE = "fm-image";
export const FM_SHOW_IMAGE_TOOL = "fm_show_image";

/** The model-facing outcome: plain text only, stating what the transcript can show. */
export function describeDisplayOutcome(view: FmImageView, mode: ExtensionContext["mode"]): string {
  const summary = describeImage(view);
  if (mode !== "tui") return `Nothing was displayed because Pi is running without a terminal UI (${mode} mode): ${summary}`;
  if (!view.display) return `Pi could not prepare a bounded inline copy, so the transcript shows only the file path: ${summary}`;
  return `Prepared the image for Pi's transcript renderer; it appears inline when image display is enabled and supported, otherwise only its file path appears: ${summary}`;
}

export default function registerFirstmateImageDisplay(pi: ExtensionAPI): void {
  pi.registerEntryRenderer?.(FM_IMAGE_ENTRY_TYPE, (entry, _options, theme) => {
    const view = parseImageView(entry.data);
    return view ? new FmImageComponent(view, theme) : undefined;
  });

  pi.registerCommand?.("image", {
    description: "Explicitly show a local PNG, JPEG, or WebP image inline without sending it to the model: /image <path>",
    handler: async (args, ctx) => {
      const loaded = await loadImageForDisplay(args, ctx.cwd);
      if (!loaded.ok) {
        ctx.ui.notify(loaded.error, "error");
        return;
      }
      pi.appendEntry<FmImageView>(FM_IMAGE_ENTRY_TYPE, loaded.image);
      if (!loaded.image.display) {
        ctx.ui.notify(`Could not prepare an inline copy; showing only the path of ${loaded.image.path}.`, "warning");
      }
    },
  });

  pi.registerTool?.({
    name: FM_SHOW_IMAGE_TOOL,
    label: "Show image",
    description:
      "Display a local PNG, JPEG, or WebP image file inline in this Pi terminal session so the user can see it, rather than only printing its path. Use it for a generated image, screenshot, or other visual artifact the user should look at. The image pixels are not sent to the model; use read instead when you need to inspect an image yourself.",
    promptSnippet: "Show a local PNG, JPEG, or WebP file inline in the terminal for the user without sending its pixels to the model.",
    parameters: Type.Object({
      path: Type.String({
        description: "Path of the local image file. Relative paths resolve from the working directory and ~ expands to the home directory.",
      }),
    }),
    renderShell: "self",
    renderCall: (args, theme) => {
      const path = typeof args?.path === "string" ? sanitizeForDisplay(args.path) : "";
      return new Text(`${theme.fg("toolTitle", theme.bold("show image"))} ${theme.fg("accent", path)}`, 0, 0);
    },
    renderResult: (result, options, theme, context) => {
      if (options.isPartial) return new Container();
      const view = context.isError ? undefined : parseImageView(result.details);
      if (!view) {
        const text = result.content
          .map((item) => (item.type === "text" ? item.text : ""))
          .filter(Boolean)
          .join("\n");
        return new Text(theme.fg(context.isError ? "error" : "toolOutput", sanitizeForDisplay(text)), 0, 0);
      }
      const previous = context.lastComponent;
      if (previous instanceof FmImageComponent && previous.view.display?.data === view.display?.data && previous.view.path === view.path) {
        previous.update(theme, context.showImages);
        return previous;
      }
      return new FmImageComponent(view, theme, context.showImages);
    },
    execute: async (_toolCallId, params, _signal, _onUpdate, ctx) => {
      const loaded = await loadImageForDisplay(params.path, ctx.cwd);
      if (!loaded.ok) throw new Error(loaded.error);
      return {
        content: [{ type: "text", text: describeDisplayOutcome(loaded.image, ctx.mode) }],
        details: loaded.image,
      };
    },
  });
}

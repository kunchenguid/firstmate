import type { RenderElement } from "claude-code";
import {
  isFirstmateOperationalRow,
  type CalmUserMessageProps,
} from "./operational-input.ts";

export type CalmBox = {
  type: "Box";
  props: { flexDirection: "column" | "row" };
  children: (CalmBox | CalmText)[];
};

export type CalmText = {
  type: "Text";
  props: { color: string };
  children: string[];
};

export type CalmElement = CalmBox | CalmText;

const calmElementsAreRenderElements: CalmElement extends RenderElement ? true : never = true;
void calmElementsAreRenderElements;

export const CALM_HIDDEN_SITES = ["ToolUse", "ToolResult", "ToolGroup", "UserMessage"] as const;

export type CalmHiddenSite = (typeof CALM_HIDDEN_SITES)[number];

export function hiddenCalmRow(): CalmBox {
  return { type: "Box", props: { flexDirection: "column" }, children: [] };
}

export function calmHidesSite(
  site: CalmHiddenSite,
  active: boolean,
  props: unknown,
): boolean {
  if (!active) return false;
  if (site === "UserMessage") {
    return isFirstmateOperationalRow(props as CalmUserMessageProps | undefined);
  }
  return true;
}
import type { RenderElement } from "claude-code";
import {
  isFirstmateOperationalRow,
  type CalmUserMessageProps,
} from "./operational-input.ts";
import type { CalmShipSpan } from "./working-ship.ts";

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

export const CALM_HIDDEN_SITES = ["ToolUse", "ToolResult", "UserMessage"] as const;
export const CALM_WORKING_SITE = "Spinner";

export type CalmHiddenSite = (typeof CALM_HIDDEN_SITES)[number];

export function hiddenCalmRow(): CalmBox {
  return { type: "Box", props: { flexDirection: "column" }, children: [] };
}

export function calmRowSpans(row: CalmShipSpan[]): CalmText[] {
  return row.map((span) => ({
    type: "Text",
    props: { color: span.color },
    children: [span.text],
  }));
}

export function calmShipElement(rows: CalmShipSpan[][]): CalmBox {
  return {
    type: "Box",
    props: { flexDirection: "column" },
    children: rows.map((row) => ({
      type: "Box",
      props: { flexDirection: "row" },
      children: calmRowSpans(row),
    })),
  };
}

export function calmViewportColumns(viewport: unknown): number {
  if (viewport === null || typeof viewport !== "object") return 0;
  const { columns } = viewport as { columns?: unknown };
  return typeof columns === "number" && Number.isFinite(columns) ? Math.max(0, Math.floor(columns)) : 0;
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
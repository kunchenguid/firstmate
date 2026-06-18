import React from "react";

export interface CardProps extends React.HTMLAttributes<HTMLDivElement> {
  /** solid = opaque grouped surface; material = translucent blur; raised = elevated. */
  variant?: "solid" | "material" | "raised";
  /** Use the accent hairline instead of the neutral one. */
  accent?: boolean;
  /** Interior padding (CSS value). */
  padding?: string;
  children?: React.ReactNode;
}

/**
 * Grouped container card — the base surface for rows, banners, wells.
 * @dsCard group="Components"
 * @startingPoint section="Surfaces" subtitle="Card container" viewport="700x200"
 */
export function Card(props: CardProps): JSX.Element;

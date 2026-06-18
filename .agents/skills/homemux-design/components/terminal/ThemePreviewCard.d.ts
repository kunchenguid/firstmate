import React from "react";

export interface ThemePreviewCardProps extends React.HTMLAttributes<HTMLDivElement> {
  /** Theme id or object. */
  theme?: string | object;
  /** Show the name + appearance header. */
  showTitle?: boolean;
}

/**
 * Live terminal theme swatch — sample prompt lines + the 16-color ANSI ramp.
 * @dsCard group="Components"
 * @startingPoint section="Terminal" subtitle="Theme preview card" viewport="700x300"
 */
export function ThemePreviewCard(props: ThemePreviewCardProps): JSX.Element;

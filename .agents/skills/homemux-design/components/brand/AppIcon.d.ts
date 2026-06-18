import React from "react";

export interface AppIconProps extends React.SVGProps<SVGSVGElement> {
  /** Edge length in px. */
  size?: number;
  /** Corner radius override (defaults to the iOS tile ~22.5%). */
  radius?: number;
  /** Render just the mint glyph on transparent (nav/wordmark lockups). */
  bare?: boolean;
  /** Soft glow behind the mark (default true). */
  glow?: boolean;
}

/**
 * The HomeMux app icon — gable roof over a terminal block cursor on the dark canvas.
 * @dsCard group="Components"
 * @startingPoint section="Brand" subtitle="App icon / brand mark" viewport="700x260"
 */
export function AppIcon(props: AppIconProps): JSX.Element;

import React from "react";

export interface PaletteDotsProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Theme id ("homemux-dark"…) or a theme object. */
  theme?: string | object;
  /** Dot diameter in px. */
  size?: number;
  /** Ring color behind dots (match the surface). */
  ring?: string;
}

/**
 * Overlapping ANSI palette dots that preview a terminal theme.
 * @dsCard group="Components"
 */
export function PaletteDots(props: PaletteDotsProps): JSX.Element;

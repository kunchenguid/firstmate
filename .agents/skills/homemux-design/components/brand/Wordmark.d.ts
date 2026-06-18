import React from "react";

export interface WordmarkProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Type size in px (the tile scales with it). */
  size?: number;
  /** "tile" = full app icon; "bare" = glyph only. */
  mark?: "tile" | "bare";
  /** "Home" text color. */
  color?: string;
  /** "Mux" accent color. */
  accent?: string;
}

/**
 * Horizontal HomeMux lockup — app tile + wordmark.
 * @dsCard group="Components"
 */
export function Wordmark(props: WordmarkProps): JSX.Element;

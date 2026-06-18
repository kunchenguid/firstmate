import React from "react";

export interface IconProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Lucide icon name, kebab-case (e.g. "terminal", "command", "rectangle-stack"). */
  name: string;
  /** Edge length in px. */
  size?: number;
  /** Lucide stroke width. HomeMux uses 2 for body, 2.25 for emphasis. */
  strokeWidth?: number;
  /** CSS color; defaults to currentColor so it inherits the accent/label tint. */
  color?: string;
}

/**
 * Line icon (Lucide) — HomeMux's web stand-in for iOS SF Symbols.
 * @dsCard group="Components"
 */
export function Icon(props: IconProps): JSX.Element;

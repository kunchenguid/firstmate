import React from "react";

export interface KeyCapProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** Sticky/held state — fills with the mint accent (e.g. Ctrl engaged). */
  active?: boolean;
  children?: React.ReactNode;
}

/**
 * Monospace terminal keycap for the keyboard accessory row.
 * @dsCard group="Components"
 */
export function KeyCap(props: KeyCapProps): JSX.Element;

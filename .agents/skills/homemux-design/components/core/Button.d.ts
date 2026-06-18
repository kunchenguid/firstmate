import React from "react";

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** Visual weight. prominent = filled mint pill; bordered = tinted; plain = text only. */
  variant?: "prominent" | "bordered" | "plain";
  /** iOS controlSize. */
  size?: "large" | "small";
  /** Use the red danger tint instead of the mint accent. */
  destructive?: boolean;
  /** Stretch to fill its container (used in sheets / cards). */
  fullWidth?: boolean;
  /** Optional leading icon node (an SF-Symbol-equivalent SVG). */
  icon?: React.ReactNode;
  children?: React.ReactNode;
}

/**
 * The standard HomeMux action button.
 *
 * @dsCard group="Components"
 * @startingPoint section="Core" subtitle="Primary action button" viewport="700x150"
 */
export function Button(props: ButtonProps): JSX.Element;

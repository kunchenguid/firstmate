import React from "react";

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Color of the badge (drives fill/text). */
  tint?: string;
  /** tinted = 12% fill (default), outline = hairline, solid = filled. */
  variant?: "tinted" | "outline" | "solid";
  children?: React.ReactNode;
}

/**
 * Capsule label — transport tag (SSH/Mosh), theme name, trial state.
 * @dsCard group="Components"
 */
export function Badge(props: BadgeProps): JSX.Element;

import React from "react";

export interface IconButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** Lucide icon name. */
  name: string;
  /** Accessible label (also the tooltip). */
  label?: string;
  /** Edge length in px. */
  size?: number;
  shape?: "rounded" | "circle";
  /** material = translucent blur chip (floating command button); soft = tinted fill; plain = bare. */
  variant?: "material" | "soft" | "plain";
  /** Glyph color. */
  tint?: string;
  iconSize?: number;
}

/**
 * Square or circular icon button — toolbar glyphs and the floating command button.
 * @dsCard group="Components"
 * @startingPoint section="Core" subtitle="Icon / floating command button" viewport="700x150"
 */
export function IconButton(props: IconButtonProps): JSX.Element;

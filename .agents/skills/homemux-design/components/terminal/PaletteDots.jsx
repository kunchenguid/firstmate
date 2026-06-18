import React from "react";
import { resolveTheme } from "./themes.js";

/**
 * HomeMux PaletteDots — the overlapping ANSI swatch dots that preview a theme
 * in list rows and the theme picker (colors 0,1,2,4,5,6).
 */
export function PaletteDots({ theme = "homemux-dark", size = 16, ring = "var(--surface-1)", style = {}, ...rest }) {
  const t = resolveTheme(theme);
  const idx = [0, 1, 2, 4, 5, 6];
  return (
    <span style={{ display: "inline-flex", paddingRight: 2, ...style }} {...rest}>
      {idx.map((i, k) => (
        <span
          key={i}
          style={{
            width: size,
            height: size,
            marginLeft: k === 0 ? 0 : -size * 0.3,
            borderRadius: "50%",
            background: t.ansi[i],
            boxShadow: `0 0 0 1.5px ${ring}`,
          }}
        />
      ))}
    </span>
  );
}

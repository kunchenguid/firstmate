import React from "react";
import { AppIcon } from "./AppIcon.jsx";

/**
 * HomeMux Wordmark — the horizontal lockup: app tile + "HomeMux" set in the UI
 * font, semibold, with "Mux" in the mint accent. `onDark` keeps the tile;
 * `mark="bare"` swaps to the glyph-only lockup for compact chrome.
 */
export function Wordmark({ size = 28, mark = "tile", color = "var(--text-primary)", accent = "var(--accent)", style = {}, ...rest }) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: size * 0.42, ...style }} {...rest}>
      <AppIcon size={size * 1.32} bare={mark === "bare"} glow={mark === "tile"} />
      <span style={{ fontFamily: "var(--font-ui)", fontWeight: "var(--weight-bold)",
        fontSize: size, letterSpacing: "var(--tracking-tight)", color, lineHeight: 1 }}>
        Home<span style={{ color: accent }}>Mux</span>
      </span>
    </span>
  );
}

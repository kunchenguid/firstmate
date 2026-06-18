import React from "react";

/**
 * HomeMux Badge — a small capsule label. Used for the transport tag (SSH /
 * Mosh), theme name, and trial state. Tinted variant fills with 12% of its
 * color, matching the SwiftUI StatusBadge.
 */
export function Badge({ children, tint = "var(--text-tertiary)", variant = "tinted", style = {}, ...rest }) {
  const variants = {
    tinted: { background: "color-mix(in srgb, " + tint + " 12%, transparent)", color: tint, border: "1px solid transparent" },
    outline: { background: "transparent", color: tint, border: "1px solid color-mix(in srgb, " + tint + " 40%, transparent)" },
    solid: { background: tint, color: "var(--text-on-accent)", border: "1px solid transparent" },
  };
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: "5px",
        fontFamily: "var(--font-ui)",
        fontSize: "var(--type-caption2)",
        fontWeight: "var(--weight-semibold)",
        letterSpacing: "0.01em",
        lineHeight: 1,
        padding: "4px 8px",
        borderRadius: "var(--radius-pill)",
        whiteSpace: "nowrap",
        ...variants[variant],
        ...style,
      }}
      {...rest}
    >
      {children}
    </span>
  );
}

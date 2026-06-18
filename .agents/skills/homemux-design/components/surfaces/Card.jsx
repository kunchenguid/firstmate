import React from "react";

/**
 * HomeMux Card — a grouped container. `material` is the translucent blurred
 * card used over the terminal / onboarding; `solid` is the opaque grouped
 * surface used in lists and settings. Hairline border, continuous corners.
 */
export function Card({ children, variant = "solid", accent = false, padding = "var(--inset-card)", style = {}, ...rest }) {
  const variants = {
    solid: { background: "var(--surface-1)" },
    material: {
      background: "var(--material-regular)",
      WebkitBackdropFilter: "var(--blur-regular)",
      backdropFilter: "var(--blur-regular)",
    },
    raised: { background: "var(--surface-2)", boxShadow: "var(--shadow-card)" },
  };
  return (
    <div
      style={{
        borderRadius: "var(--radius-xl)",
        border: "1px solid " + (accent ? "var(--accent-line)" : "var(--hairline)"),
        padding,
        color: "var(--text-primary)",
        fontFamily: "var(--font-ui)",
        ...variants[variant],
        ...style,
      }}
      {...rest}
    >
      {children}
    </div>
  );
}

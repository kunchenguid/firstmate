import React from "react";

/**
 * HomeMux Button — the standard tappable action.
 * Mirrors SwiftUI .borderedProminent / .bordered / .plain button styles with
 * iOS controlSize. Prominent is a filled mint pill with near-black ink.
 */
export function Button({
  children,
  variant = "prominent",
  size = "large",
  destructive = false,
  fullWidth = false,
  icon = null,
  disabled = false,
  style = {},
  ...rest
}) {
  const sizes = {
    large: { padding: "13px 22px", font: "var(--type-headline)", radius: "var(--radius-sm)", gap: "8px" },
    small: { padding: "7px 14px", font: "var(--type-subheadline)", radius: "10px", gap: "6px" },
  };
  const s = sizes[size] || sizes.large;
  const accent = destructive ? "var(--danger)" : "var(--accent)";

  const base = {
    display: fullWidth ? "flex" : "inline-flex",
    width: fullWidth ? "100%" : "auto",
    alignItems: "center",
    justifyContent: "center",
    gap: s.gap,
    padding: s.padding,
    fontFamily: "var(--font-ui)",
    fontSize: s.font,
    fontWeight: "var(--weight-semibold)",
    lineHeight: 1,
    borderRadius: s.radius,
    border: "1px solid transparent",
    cursor: disabled ? "default" : "pointer",
    opacity: disabled ? 0.4 : 1,
    transition: "transform var(--dur-fast) var(--ease-snappy), filter var(--dur-fast) var(--ease-standard)",
    WebkitTapHighlightColor: "transparent",
    userSelect: "none",
  };

  const variants = {
    prominent: {
      background: accent,
      color: destructive ? "#fff" : "var(--text-on-accent)",
      boxShadow: destructive ? "none" : "0 0 20px var(--accent-glow)",
    },
    bordered: {
      background: destructive ? "var(--danger-soft)" : "var(--accent-soft)",
      color: accent,
      borderColor: destructive ? "transparent" : "var(--accent-line)",
    },
    plain: {
      background: "transparent",
      color: accent,
    },
  };

  return (
    <button
      type="button"
      disabled={disabled}
      style={{ ...base, ...variants[variant], ...style }}
      onMouseDown={(e) => !disabled && (e.currentTarget.style.transform = "scale(var(--press-scale))")}
      onMouseUp={(e) => (e.currentTarget.style.transform = "scale(1)")}
      onMouseLeave={(e) => (e.currentTarget.style.transform = "scale(1)")}
      {...rest}
    >
      {icon ? <span style={{ display: "inline-flex" }} aria-hidden="true">{icon}</span> : null}
      {children}
    </button>
  );
}

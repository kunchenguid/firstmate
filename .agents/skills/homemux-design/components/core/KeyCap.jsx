import React from "react";

/**
 * HomeMux KeyCap — a monospace key in the terminal accessory row (Esc, Tab,
 * Ctrl, arrows, Ctrl-C…). Tertiary fill by default; the active/sticky state
 * (e.g. Ctrl held) fills with the accent.
 */
export function KeyCap({ children, active = false, onClick, style = {}, ...rest }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{
        fontFamily: "var(--font-mono)",
        fontSize: "var(--type-callout)",
        fontWeight: "var(--weight-semibold)",
        lineHeight: 1,
        padding: "8px 11px",
        borderRadius: "var(--radius-xs)",
        border: "1px solid " + (active ? "transparent" : "var(--hairline)"),
        background: active ? "var(--accent)" : "var(--surface-3)",
        color: active ? "var(--text-on-accent)" : "var(--text-primary)",
        cursor: "pointer",
        transition: "transform var(--dur-fast) var(--ease-snappy), background var(--dur-fast)",
        WebkitTapHighlightColor: "transparent",
        userSelect: "none",
        ...style,
      }}
      onMouseDown={(e) => (e.currentTarget.style.transform = "scale(var(--press-scale))")}
      onMouseUp={(e) => (e.currentTarget.style.transform = "scale(1)")}
      onMouseLeave={(e) => (e.currentTarget.style.transform = "scale(1)")}
      {...rest}
    >
      {children}
    </button>
  );
}

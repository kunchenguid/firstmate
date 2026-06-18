import React from "react";

/**
 * HomeMux ListRow — an inset-grouped list row. Optional leading element (an
 * icon tile), a title + subtitle stack, trailing content (badges, palette
 * dots, chevron), and a pressable affordance.
 */
export function ListRow({
  leading = null,
  title,
  subtitle = null,
  detail = null,
  trailing = null,
  chevron = false,
  onClick,
  style = {},
  ...rest
}) {
  const pressable = !!onClick;
  return (
    <div
      onClick={onClick}
      role={pressable ? "button" : undefined}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "12px 14px",
        background: "var(--surface-1)",
        fontFamily: "var(--font-ui)",
        color: "var(--text-primary)",
        cursor: pressable ? "pointer" : "default",
        transition: "background var(--dur-fast) var(--ease-standard)",
        ...style,
      }}
      onMouseEnter={(e) => pressable && (e.currentTarget.style.background = "var(--surface-2)")}
      onMouseLeave={(e) => pressable && (e.currentTarget.style.background = "var(--surface-1)")}
      {...rest}
    >
      {leading}
      <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 4 }}>
        <span style={{ fontSize: "var(--type-headline)", fontWeight: "var(--weight-semibold)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
          {title}
        </span>
        {subtitle ? (
          <span style={{ fontSize: "var(--type-subheadline)", color: "var(--text-secondary)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
            {subtitle}
          </span>
        ) : null}
        {detail ? (
          <span style={{ fontSize: "var(--type-caption)", color: "var(--text-tertiary)", display: "flex", alignItems: "center", gap: 6 }}>
            {detail}
          </span>
        ) : null}
      </div>
      {trailing}
      {chevron ? (
        <span style={{ color: "var(--text-tertiary)", display: "inline-flex" }} aria-hidden="true">
          <svg width="8" height="14" viewBox="0 0 8 14" fill="none"><path d="M1 1l6 6-6 6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
        </span>
      ) : null}
    </div>
  );
}

/**
 * IconTile — the rounded square leading glyph used in host rows: theme
 * background, accent terminal glyph, faint accent hairline.
 */
export function IconTile({ children, size = 44, background = "var(--bg-abyss)", tint = "var(--accent)", style = {} }) {
  return (
    <span
      style={{
        width: size,
        height: size,
        flex: "none",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        borderRadius: "var(--radius-sm)",
        background,
        color: tint,
        border: "1px solid var(--accent-line)",
        ...style,
      }}
    >
      {children}
    </span>
  );
}

import React from "react";
import { resolveTheme } from "./themes.js";

/**
 * HomeMux ThemePreviewCard — the live terminal swatch shown in Settings and
 * the host editor. Renders sample prompt lines in the theme's own colors plus
 * the full 16-color ANSI ramp, framed by an accent hairline.
 */
export function ThemePreviewCard({ theme = "homemux-dark", showTitle = true, style = {}, ...rest }) {
  const t = resolveTheme(theme);
  return (
    <div
      style={{
        background: t.bg,
        borderRadius: "var(--radius-lg)",
        border: `1px solid ${t.accent}59`,
        padding: 14,
        display: "flex",
        flexDirection: "column",
        gap: 12,
        fontFamily: "var(--font-ui)",
        ...style,
      }}
      {...rest}
    >
      {showTitle ? (
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
            <span style={{ fontSize: "var(--type-headline)", fontWeight: "var(--weight-semibold)", color: t.fg }}>{t.name}</span>
            <span style={{ fontSize: "var(--type-caption)", color: t.fg + "AA" }}>{t.appearance}</span>
          </div>
          <span style={{ width: 12, height: 12, borderRadius: "50%", background: t.accent }} />
        </div>
      ) : null}

      <div style={{ fontFamily: "var(--font-mono)", fontSize: "var(--type-caption)", lineHeight: 1.5, display: "flex", flexDirection: "column", gap: 2 }}>
        <span style={{ color: t.ansi[10] }}>$ tmux attach -t work</span>
        <span style={{ color: t.fg }}>HomeMux reconnects to your session</span>
        <span style={{ color: t.ansi[11] }}>errors stay readable, prompts stay calm</span>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(8, 1fr)", gap: 4 }}>
        {t.ansi.map((c, i) => (
          <span key={i} style={{ height: 14, borderRadius: 4, background: c }} />
        ))}
      </div>
    </div>
  );
}

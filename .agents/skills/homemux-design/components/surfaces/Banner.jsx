import React from "react";
import { Icon } from "../core/Icon.jsx";

const TONES = {
  warning: { color: "var(--warning)", soft: "var(--warning-soft)", icon: "triangle-alert" },
  danger: { color: "var(--danger)", soft: "var(--danger-soft)", icon: "triangle-alert" },
  accent: { color: "var(--accent)", soft: "var(--accent-soft)", icon: "circle-check" },
  info: { color: "var(--info)", soft: "color-mix(in srgb, var(--info) 14%, transparent)", icon: "info" },
};

/**
 * HomeMux Banner — an inline message card with an icon well, title + message,
 * and an optional action button. Covers the recovery banner (failed/
 * disconnected), the trial banner, and Mosh-fallback notices.
 */
export function Banner({ tone = "warning", icon, title, message, action, style = {}, ...rest }) {
  const t = TONES[tone] || TONES.warning;
  return (
    <div
      style={{
        display: "flex",
        alignItems: "flex-start",
        gap: 12,
        padding: 14,
        borderRadius: "var(--radius-md)",
        background: "var(--material-regular)",
        WebkitBackdropFilter: "var(--blur-regular)",
        backdropFilter: "var(--blur-regular)",
        border: "1px solid var(--hairline)",
        fontFamily: "var(--font-ui)",
        ...style,
      }}
      {...rest}
    >
      <span
        style={{
          width: 30,
          height: 30,
          flex: "none",
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          borderRadius: "50%",
          background: t.soft,
          color: t.color,
        }}
      >
        <Icon name={icon || t.icon} size={17} color="currentColor" />
      </span>
      <div style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column", gap: 3 }}>
        <span style={{ fontSize: "var(--type-subheadline)", fontWeight: "var(--weight-semibold)", color: "var(--text-primary)" }}>{title}</span>
        {message ? <span style={{ fontSize: "var(--type-footnote)", color: "var(--text-secondary)", lineHeight: 1.4 }}>{message}</span> : null}
      </div>
      {action ? <div style={{ flex: "none", alignSelf: "center" }}>{action}</div> : null}
    </div>
  );
}

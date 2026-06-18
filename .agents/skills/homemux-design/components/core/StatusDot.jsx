import React from "react";

const COLORS = {
  connected: "var(--status-connected)",
  connecting: "var(--status-connecting)",
  failed: "var(--status-failed)",
  idle: "var(--text-tertiary)",
};

/**
 * HomeMux StatusDot — the small glowing connection indicator in the terminal
 * status bar. Connecting pulses; connected glows steady; failed is red.
 */
export function StatusDot({ state = "connected", size = 9, pulse, style = {}, ...rest }) {
  const color = COLORS[state] || COLORS.idle;
  const shouldPulse = pulse ?? state === "connecting";
  return (
    <span
      style={{
        display: "inline-block",
        width: size,
        height: size,
        borderRadius: "50%",
        background: color,
        boxShadow: state === "idle" ? "none" : `0 0 6px ${color}`,
        animation: shouldPulse ? "hmx-dot-pulse 1.2s var(--ease-standard) infinite" : "none",
        ...style,
      }}
      {...rest}
    >
      <style>{"@keyframes hmx-dot-pulse{0%,100%{opacity:1}50%{opacity:0.35}}"}</style>
    </span>
  );
}

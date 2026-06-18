import React from "react";

/**
 * HomeMux Switch — iOS toggle. On = mint track. Used in the host editor
 * ("One-tap tmux session") and settings.
 */
export function Switch({ checked = false, onChange, disabled = false, style = {}, ...rest }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => !disabled && onChange && onChange(!checked)}
      style={{
        position: "relative",
        width: 51,
        height: 31,
        flex: "none",
        borderRadius: "var(--radius-pill)",
        border: "none",
        padding: 0,
        cursor: disabled ? "default" : "pointer",
        opacity: disabled ? 0.4 : 1,
        background: checked ? "var(--accent)" : "var(--surface-3)",
        boxShadow: checked ? "0 0 16px var(--accent-glow)" : "inset 0 0 0 1px var(--hairline)",
        transition: "background var(--dur-base) var(--ease-standard)",
        WebkitTapHighlightColor: "transparent",
        ...style,
      }}
      {...rest}
    >
      <span
        style={{
          position: "absolute",
          top: 2,
          left: checked ? 22 : 2,
          width: 27,
          height: 27,
          borderRadius: "50%",
          background: "#fff",
          boxShadow: "0 2px 4px rgba(0,0,0,0.35)",
          transition: "left var(--dur-base) var(--ease-snappy)",
        }}
      />
    </button>
  );
}

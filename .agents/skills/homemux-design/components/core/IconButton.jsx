import React from "react";
import { Icon } from "./Icon.jsx";

/**
 * HomeMux IconButton — a square/circular tappable glyph (toolbar items, the
 * floating command button, accessory controls). Defaults to a translucent
 * material chip with an accent glyph and a faint accent hairline.
 */
export function IconButton({
  name,
  label,
  size = 44,
  shape = "rounded",
  variant = "material",
  tint = "var(--accent)",
  iconSize,
  disabled = false,
  style = {},
  ...rest
}) {
  const variants = {
    material: {
      background: "var(--material-regular)",
      border: "1px solid var(--accent-line)",
      WebkitBackdropFilter: "var(--blur-regular)",
      backdropFilter: "var(--blur-regular)",
      color: tint,
    },
    soft: {
      background: "var(--accent-soft)",
      border: "1px solid transparent",
      color: tint,
    },
    plain: {
      background: "transparent",
      border: "1px solid transparent",
      color: tint,
    },
  };
  return (
    <button
      type="button"
      aria-label={label || name}
      title={label}
      disabled={disabled}
      style={{
        width: size,
        height: size,
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        borderRadius: shape === "circle" ? "50%" : "var(--radius-sm)",
        cursor: disabled ? "default" : "pointer",
        opacity: disabled ? 0.4 : 1,
        transition: "transform var(--dur-fast) var(--ease-snappy)",
        WebkitTapHighlightColor: "transparent",
        ...variants[variant],
        ...style,
      }}
      onMouseDown={(e) => !disabled && (e.currentTarget.style.transform = "scale(var(--press-scale))")}
      onMouseUp={(e) => (e.currentTarget.style.transform = "scale(1)")}
      onMouseLeave={(e) => (e.currentTarget.style.transform = "scale(1)")}
      {...rest}
    >
      <Icon name={name} size={iconSize || Math.round(size * 0.46)} color="currentColor" />
    </button>
  );
}

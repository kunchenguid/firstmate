import React from "react";

/**
 * HomeMux TextField — a grouped form field (host, username, command draft).
 * Label sits above; the input is a filled rounded rect. `mono` switches to the
 * terminal font for commands and keys. Supports a leading icon node.
 */
export function TextField({
  label,
  value,
  onChange,
  placeholder,
  mono = false,
  leading = null,
  footnote,
  type = "text",
  style = {},
  ...rest
}) {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 6, ...style }}>
      {label ? (
        <span style={{ fontFamily: "var(--font-ui)", fontSize: "var(--type-footnote)", color: "var(--text-secondary)", fontWeight: "var(--weight-medium)" }}>
          {label}
        </span>
      ) : null}
      <span
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          background: "var(--surface-2)",
          border: "1px solid var(--hairline)",
          borderRadius: "var(--radius-sm)",
          padding: "0 12px",
        }}
      >
        {leading}
        <input
          type={type}
          value={value}
          onChange={(e) => onChange && onChange(e.target.value)}
          placeholder={placeholder}
          spellCheck={false}
          autoCapitalize="none"
          autoCorrect="off"
          style={{
            flex: 1,
            minWidth: 0,
            background: "transparent",
            border: "none",
            outline: "none",
            padding: "11px 0",
            fontFamily: mono ? "var(--font-mono)" : "var(--font-ui)",
            fontSize: mono ? "var(--type-subheadline)" : "var(--type-body)",
            color: "var(--text-primary)",
          }}
          {...rest}
        />
      </span>
      {footnote ? (
        <span style={{ fontFamily: "var(--font-ui)", fontSize: "var(--type-footnote)", color: "var(--text-tertiary)", lineHeight: 1.35 }}>
          {footnote}
        </span>
      ) : null}
    </label>
  );
}

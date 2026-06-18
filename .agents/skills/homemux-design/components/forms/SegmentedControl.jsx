import React from "react";

/**
 * HomeMux SegmentedControl — iOS segmented picker. Used for Transport
 * (Automatic / SSH / Mosh) and auth method. The selected segment rides on a
 * raised pill that slides between options.
 */
export function SegmentedControl({ options, value, onChange, style = {}, ...rest }) {
  const items = options.map((o) => (typeof o === "string" ? { label: o, value: o } : o));
  const index = Math.max(0, items.findIndex((i) => i.value === value));
  return (
    <div
      role="tablist"
      style={{
        position: "relative",
        display: "grid",
        gridTemplateColumns: `repeat(${items.length}, 1fr)`,
        gap: 0,
        padding: 2,
        borderRadius: "10px",
        background: "var(--surface-3)",
        border: "1px solid var(--hairline)",
        ...style,
      }}
      {...rest}
    >
      <span
        aria-hidden="true"
        style={{
          position: "absolute",
          top: 2,
          bottom: 2,
          left: `calc(${(100 / items.length) * index}% + 2px)`,
          width: `calc(${100 / items.length}% - 4px)`,
          borderRadius: "8px",
          background: "var(--accent)",
          boxShadow: "0 1px 3px rgba(0,0,0,0.4)",
          transition: "left var(--dur-base) var(--ease-snappy)",
        }}
      />
      {items.map((item) => {
        const selected = item.value === value;
        return (
          <button
            key={item.value}
            type="button"
            role="tab"
            aria-selected={selected}
            onClick={() => onChange && onChange(item.value)}
            style={{
              position: "relative",
              zIndex: 1,
              padding: "7px 12px",
              border: "none",
              background: "transparent",
              fontFamily: "var(--font-ui)",
              fontSize: "var(--type-subheadline)",
              fontWeight: "var(--weight-semibold)",
              color: selected ? "var(--text-on-accent)" : "var(--text-secondary)",
              cursor: "pointer",
              transition: "color var(--dur-base) var(--ease-standard)",
              WebkitTapHighlightColor: "transparent",
            }}
          >
            {item.label}
          </button>
        );
      })}
    </div>
  );
}

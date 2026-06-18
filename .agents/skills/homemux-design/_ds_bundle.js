/* @ds-bundle: {"format":3,"namespace":"HomeMuxDesignSystem_359607","components":[{"name":"AppIcon","sourcePath":"components/brand/AppIcon.jsx"},{"name":"Wordmark","sourcePath":"components/brand/Wordmark.jsx"},{"name":"Badge","sourcePath":"components/core/Badge.jsx"},{"name":"Button","sourcePath":"components/core/Button.jsx"},{"name":"Icon","sourcePath":"components/core/Icon.jsx"},{"name":"IconButton","sourcePath":"components/core/IconButton.jsx"},{"name":"KeyCap","sourcePath":"components/core/KeyCap.jsx"},{"name":"StatusDot","sourcePath":"components/core/StatusDot.jsx"},{"name":"SegmentedControl","sourcePath":"components/forms/SegmentedControl.jsx"},{"name":"Switch","sourcePath":"components/forms/Switch.jsx"},{"name":"TextField","sourcePath":"components/forms/TextField.jsx"},{"name":"Banner","sourcePath":"components/surfaces/Banner.jsx"},{"name":"Card","sourcePath":"components/surfaces/Card.jsx"},{"name":"ListRow","sourcePath":"components/surfaces/ListRow.jsx"},{"name":"IconTile","sourcePath":"components/surfaces/ListRow.jsx"},{"name":"PaletteDots","sourcePath":"components/terminal/PaletteDots.jsx"},{"name":"ThemePreviewCard","sourcePath":"components/terminal/ThemePreviewCard.jsx"},{"name":"THEMES","sourcePath":"components/terminal/themes.js"}],"sourceHashes":{"components/brand/AppIcon.jsx":"2cc234a8b0e9","components/brand/Wordmark.jsx":"75373fa1c908","components/core/Badge.jsx":"1f37894ac543","components/core/Button.jsx":"b58969adb1be","components/core/Icon.jsx":"8da518b686b1","components/core/IconButton.jsx":"91a38dbb3c51","components/core/KeyCap.jsx":"2f65c6315473","components/core/StatusDot.jsx":"6835d6224d65","components/forms/SegmentedControl.jsx":"30e60dd0d405","components/forms/Switch.jsx":"bf1a8bbb6aac","components/forms/TextField.jsx":"d9524db0b887","components/surfaces/Banner.jsx":"8c278cf77907","components/surfaces/Card.jsx":"a98c182581cd","components/surfaces/ListRow.jsx":"a4a61704a75e","components/terminal/PaletteDots.jsx":"41ae91b8ea45","components/terminal/ThemePreviewCard.jsx":"35a645e78975","components/terminal/themes.js":"436b7b06161b","ui_kits/homemux-ios/app.jsx":"045ac90147e4","ui_kits/homemux-ios/data.js":"4f78ea3e72a6","ui_kits/homemux-ios/ios-frame.jsx":"be3343be4b51","ui_kits/homemux-ios/screens/AddHost.jsx":"d3a71c6670ad","ui_kits/homemux-ios/screens/CommandMenu.jsx":"c2585c2c2e93","ui_kits/homemux-ios/screens/Home.jsx":"4250d15ca2f3","ui_kits/homemux-ios/screens/Onboarding.jsx":"49a1bf362de2","ui_kits/homemux-ios/screens/Paywall.jsx":"d2ced762d75c","ui_kits/homemux-ios/screens/Prompts.jsx":"bb41d4f1263c","ui_kits/homemux-ios/screens/Settings.jsx":"0a07ce100776","ui_kits/homemux-ios/screens/Terminal.jsx":"5fef0e5828c1","ui_kits/homemux-ios/screens/TmuxPicker.jsx":"3506e82066d3"},"inlinedExternals":[],"unexposedExports":[{"name":"resolveTheme","sourcePath":"components/terminal/themes.js"}]} */

(() => {

const __ds_ns = (window.HomeMuxDesignSystem_359607 = window.HomeMuxDesignSystem_359607 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/brand/AppIcon.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
let gid = 0;

/**
 * HomeMux AppIcon — the brand mark (gable roof over a terminal block cursor) on
 * the dark radial canvas. Use `bare` to render just the mint glyph on
 * transparent (for nav lockups). Size in px; radius defaults to the iOS tile.
 */
function AppIcon({
  size = 96,
  radius,
  bare = false,
  glow = true,
  style = {},
  ...rest
}) {
  const id = React.useMemo(() => "hmx" + ++gid, []);
  const r = radius != null ? radius : Math.round(size * 0.225);
  const mark = (stroke, fill) => /*#__PURE__*/React.createElement("g", null, /*#__PURE__*/React.createElement("path", {
    d: "M300 474 L 512 312 L 724 474",
    stroke: stroke,
    strokeWidth: "74",
    strokeLinecap: "round",
    strokeLinejoin: "round",
    fill: "none"
  }), /*#__PURE__*/React.createElement("rect", {
    x: "414",
    y: "548",
    width: "72",
    height: "168",
    rx: "16",
    fill: fill
  }), /*#__PURE__*/React.createElement("rect", {
    x: "538",
    y: "548",
    width: "72",
    height: "168",
    rx: "16",
    fill: fill
  }));
  if (bare) {
    return /*#__PURE__*/React.createElement("svg", _extends({
      width: size,
      height: size,
      viewBox: "0 0 1024 1024",
      fill: "none",
      style: style,
      "aria-label": "HomeMux"
    }, rest), mark("var(--accent)", "var(--accent)"));
  }
  return /*#__PURE__*/React.createElement("svg", _extends({
    width: size,
    height: size,
    viewBox: "0 0 1024 1024",
    fill: "none",
    style: {
      borderRadius: r,
      display: "block",
      ...style
    },
    "aria-label": "HomeMux"
  }, rest), /*#__PURE__*/React.createElement("defs", null, /*#__PURE__*/React.createElement("radialGradient", {
    id: id + "bg",
    cx: "42%",
    cy: "33%",
    r: "88%"
  }, /*#__PURE__*/React.createElement("stop", {
    offset: "0%",
    stopColor: "#12171F"
  }), /*#__PURE__*/React.createElement("stop", {
    offset: "58%",
    stopColor: "#0A0D12"
  }), /*#__PURE__*/React.createElement("stop", {
    offset: "100%",
    stopColor: "#06080C"
  })), /*#__PURE__*/React.createElement("linearGradient", {
    id: id + "m",
    x1: "300",
    y1: "300",
    x2: "724",
    y2: "724",
    gradientUnits: "userSpaceOnUse"
  }, /*#__PURE__*/React.createElement("stop", {
    offset: "0%",
    stopColor: "#8FFAC4"
  }), /*#__PURE__*/React.createElement("stop", {
    offset: "100%",
    stopColor: "#5EEAD4"
  })), glow ? /*#__PURE__*/React.createElement("filter", {
    id: id + "g",
    x: "-40%",
    y: "-40%",
    width: "180%",
    height: "180%"
  }, /*#__PURE__*/React.createElement("feGaussianBlur", {
    stdDeviation: "16",
    result: "b"
  }), /*#__PURE__*/React.createElement("feMerge", null, /*#__PURE__*/React.createElement("feMergeNode", {
    in: "b"
  }), /*#__PURE__*/React.createElement("feMergeNode", {
    in: "SourceGraphic"
  }))) : null), /*#__PURE__*/React.createElement("rect", {
    width: "1024",
    height: "1024",
    rx: r * (1024 / size),
    fill: `url(#${id}bg)`
  }), /*#__PURE__*/React.createElement("g", {
    filter: glow ? `url(#${id}g)` : undefined
  }, mark(`url(#${id}m)`, `url(#${id}m)`)));
}
Object.assign(__ds_scope, { AppIcon });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/brand/AppIcon.jsx", error: String((e && e.message) || e) }); }

// components/brand/Wordmark.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux Wordmark — the horizontal lockup: app tile + "HomeMux" set in the UI
 * font, semibold, with "Mux" in the mint accent. `onDark` keeps the tile;
 * `mark="bare"` swaps to the glyph-only lockup for compact chrome.
 */
function Wordmark({
  size = 28,
  mark = "tile",
  color = "var(--text-primary)",
  accent = "var(--accent)",
  style = {},
  ...rest
}) {
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: size * 0.42,
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement(__ds_scope.AppIcon, {
    size: size * 1.32,
    bare: mark === "bare",
    glow: mark === "tile"
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-ui)",
      fontWeight: "var(--weight-bold)",
      fontSize: size,
      letterSpacing: "var(--tracking-tight)",
      color,
      lineHeight: 1
    }
  }, "Home", /*#__PURE__*/React.createElement("span", {
    style: {
      color: accent
    }
  }, "Mux")));
}
Object.assign(__ds_scope, { Wordmark });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/brand/Wordmark.jsx", error: String((e && e.message) || e) }); }

// components/core/Badge.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux Badge — a small capsule label. Used for the transport tag (SSH /
 * Mosh), theme name, and trial state. Tinted variant fills with 12% of its
 * color, matching the SwiftUI StatusBadge.
 */
function Badge({
  children,
  tint = "var(--text-tertiary)",
  variant = "tinted",
  style = {},
  ...rest
}) {
  const variants = {
    tinted: {
      background: "color-mix(in srgb, " + tint + " 12%, transparent)",
      color: tint,
      border: "1px solid transparent"
    },
    outline: {
      background: "transparent",
      color: tint,
      border: "1px solid color-mix(in srgb, " + tint + " 40%, transparent)"
    },
    solid: {
      background: tint,
      color: "var(--text-on-accent)",
      border: "1px solid transparent"
    }
  };
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: "5px",
      fontFamily: "var(--font-ui)",
      fontSize: "var(--type-caption2)",
      fontWeight: "var(--weight-semibold)",
      letterSpacing: "0.01em",
      lineHeight: 1,
      padding: "4px 8px",
      borderRadius: "var(--radius-pill)",
      whiteSpace: "nowrap",
      ...variants[variant],
      ...style
    }
  }, rest), children);
}
Object.assign(__ds_scope, { Badge });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Badge.jsx", error: String((e && e.message) || e) }); }

// components/core/Button.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux Button — the standard tappable action.
 * Mirrors SwiftUI .borderedProminent / .bordered / .plain button styles with
 * iOS controlSize. Prominent is a filled mint pill with near-black ink.
 */
function Button({
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
    large: {
      padding: "13px 22px",
      font: "var(--type-headline)",
      radius: "var(--radius-sm)",
      gap: "8px"
    },
    small: {
      padding: "7px 14px",
      font: "var(--type-subheadline)",
      radius: "10px",
      gap: "6px"
    }
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
    userSelect: "none"
  };
  const variants = {
    prominent: {
      background: accent,
      color: destructive ? "#fff" : "var(--text-on-accent)",
      boxShadow: destructive ? "none" : "0 0 20px var(--accent-glow)"
    },
    bordered: {
      background: destructive ? "var(--danger-soft)" : "var(--accent-soft)",
      color: accent,
      borderColor: destructive ? "transparent" : "var(--accent-line)"
    },
    plain: {
      background: "transparent",
      color: accent
    }
  };
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    disabled: disabled,
    style: {
      ...base,
      ...variants[variant],
      ...style
    },
    onMouseDown: e => !disabled && (e.currentTarget.style.transform = "scale(var(--press-scale))"),
    onMouseUp: e => e.currentTarget.style.transform = "scale(1)",
    onMouseLeave: e => e.currentTarget.style.transform = "scale(1)"
  }, rest), icon ? /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex"
    },
    "aria-hidden": "true"
  }, icon) : null, children);
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Button.jsx", error: String((e && e.message) || e) }); }

// components/core/Icon.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
let styleInjected = false;
function ensureStyle() {
  if (styleInjected || typeof document === "undefined") return;
  styleInjected = true;
  const el = document.createElement("style");
  el.textContent = ".hmx-icon{display:inline-flex;line-height:0}.hmx-icon svg{width:100%;height:100%;display:block}";
  document.head.appendChild(el);
}

/**
 * HomeMux Icon — thin wrapper over Lucide (the line-icon set we use as a
 * web stand-in for iOS SF Symbols). Render <Icon name="terminal" />. Requires
 * the Lucide UMD script to be loaded on the page; it converts the placeholder
 * after mount. Color is inherited (stroke=currentColor); size is in px.
 */
function Icon({
  name,
  size = 20,
  strokeWidth = 2,
  color = "currentColor",
  style = {},
  ...rest
}) {
  const ref = React.useRef(null);
  ensureStyle();
  React.useEffect(() => {
    const lucide = typeof window !== "undefined" ? window.lucide : null;
    if (lucide && ref.current) {
      ref.current.innerHTML = `<i data-lucide="${name}" stroke-width="${strokeWidth}"></i>`;
      try {
        lucide.createIcons({
          attrs: {
            "stroke-width": strokeWidth
          },
          nameAttr: "data-lucide"
        });
      } catch (e) {/* noop */}
    }
  }, [name, strokeWidth]);
  return /*#__PURE__*/React.createElement("span", _extends({
    ref: ref,
    className: "hmx-icon",
    style: {
      width: size,
      height: size,
      color,
      ...style
    },
    "aria-hidden": "true"
  }, rest));
}
Object.assign(__ds_scope, { Icon });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Icon.jsx", error: String((e && e.message) || e) }); }

// components/core/IconButton.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux IconButton — a square/circular tappable glyph (toolbar items, the
 * floating command button, accessory controls). Defaults to a translucent
 * material chip with an accent glyph and a faint accent hairline.
 */
function IconButton({
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
      color: tint
    },
    soft: {
      background: "var(--accent-soft)",
      border: "1px solid transparent",
      color: tint
    },
    plain: {
      background: "transparent",
      border: "1px solid transparent",
      color: tint
    }
  };
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    "aria-label": label || name,
    title: label,
    disabled: disabled,
    style: {
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
      ...style
    },
    onMouseDown: e => !disabled && (e.currentTarget.style.transform = "scale(var(--press-scale))"),
    onMouseUp: e => e.currentTarget.style.transform = "scale(1)",
    onMouseLeave: e => e.currentTarget.style.transform = "scale(1)"
  }, rest), /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: name,
    size: iconSize || Math.round(size * 0.46),
    color: "currentColor"
  }));
}
Object.assign(__ds_scope, { IconButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/IconButton.jsx", error: String((e && e.message) || e) }); }

// components/core/KeyCap.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux KeyCap — a monospace key in the terminal accessory row (Esc, Tab,
 * Ctrl, arrows, Ctrl-C…). Tertiary fill by default; the active/sticky state
 * (e.g. Ctrl held) fills with the accent.
 */
function KeyCap({
  children,
  active = false,
  onClick,
  style = {},
  ...rest
}) {
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    onClick: onClick,
    style: {
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
      ...style
    },
    onMouseDown: e => e.currentTarget.style.transform = "scale(var(--press-scale))",
    onMouseUp: e => e.currentTarget.style.transform = "scale(1)",
    onMouseLeave: e => e.currentTarget.style.transform = "scale(1)"
  }, rest), children);
}
Object.assign(__ds_scope, { KeyCap });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/KeyCap.jsx", error: String((e && e.message) || e) }); }

// components/core/StatusDot.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
const COLORS = {
  connected: "var(--status-connected)",
  connecting: "var(--status-connecting)",
  failed: "var(--status-failed)",
  idle: "var(--text-tertiary)"
};

/**
 * HomeMux StatusDot — the small glowing connection indicator in the terminal
 * status bar. Connecting pulses; connected glows steady; failed is red.
 */
function StatusDot({
  state = "connected",
  size = 9,
  pulse,
  style = {},
  ...rest
}) {
  const color = COLORS[state] || COLORS.idle;
  const shouldPulse = pulse ?? state === "connecting";
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      display: "inline-block",
      width: size,
      height: size,
      borderRadius: "50%",
      background: color,
      boxShadow: state === "idle" ? "none" : `0 0 6px ${color}`,
      animation: shouldPulse ? "hmx-dot-pulse 1.2s var(--ease-standard) infinite" : "none",
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("style", null, "@keyframes hmx-dot-pulse{0%,100%{opacity:1}50%{opacity:0.35}}"));
}
Object.assign(__ds_scope, { StatusDot });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/StatusDot.jsx", error: String((e && e.message) || e) }); }

// components/forms/SegmentedControl.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux SegmentedControl — iOS segmented picker. Used for Transport
 * (Automatic / SSH / Mosh) and auth method. The selected segment rides on a
 * raised pill that slides between options.
 */
function SegmentedControl({
  options,
  value,
  onChange,
  style = {},
  ...rest
}) {
  const items = options.map(o => typeof o === "string" ? {
    label: o,
    value: o
  } : o);
  const index = Math.max(0, items.findIndex(i => i.value === value));
  return /*#__PURE__*/React.createElement("div", _extends({
    role: "tablist",
    style: {
      position: "relative",
      display: "grid",
      gridTemplateColumns: `repeat(${items.length}, 1fr)`,
      gap: 0,
      padding: 2,
      borderRadius: "10px",
      background: "var(--surface-3)",
      border: "1px solid var(--hairline)",
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      top: 2,
      bottom: 2,
      left: `calc(${100 / items.length * index}% + 2px)`,
      width: `calc(${100 / items.length}% - 4px)`,
      borderRadius: "8px",
      background: "var(--accent)",
      boxShadow: "0 1px 3px rgba(0,0,0,0.4)",
      transition: "left var(--dur-base) var(--ease-snappy)"
    }
  }), items.map(item => {
    const selected = item.value === value;
    return /*#__PURE__*/React.createElement("button", {
      key: item.value,
      type: "button",
      role: "tab",
      "aria-selected": selected,
      onClick: () => onChange && onChange(item.value),
      style: {
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
        WebkitTapHighlightColor: "transparent"
      }
    }, item.label);
  }));
}
Object.assign(__ds_scope, { SegmentedControl });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/SegmentedControl.jsx", error: String((e && e.message) || e) }); }

// components/forms/Switch.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux Switch — iOS toggle. On = mint track. Used in the host editor
 * ("One-tap tmux session") and settings.
 */
function Switch({
  checked = false,
  onChange,
  disabled = false,
  style = {},
  ...rest
}) {
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    role: "switch",
    "aria-checked": checked,
    disabled: disabled,
    onClick: () => !disabled && onChange && onChange(!checked),
    style: {
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
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    style: {
      position: "absolute",
      top: 2,
      left: checked ? 22 : 2,
      width: 27,
      height: 27,
      borderRadius: "50%",
      background: "#fff",
      boxShadow: "0 2px 4px rgba(0,0,0,0.35)",
      transition: "left var(--dur-base) var(--ease-snappy)"
    }
  }));
}
Object.assign(__ds_scope, { Switch });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/Switch.jsx", error: String((e && e.message) || e) }); }

// components/forms/TextField.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux TextField — a grouped form field (host, username, command draft).
 * Label sits above; the input is a filled rounded rect. `mono` switches to the
 * terminal font for commands and keys. Supports a leading icon node.
 */
function TextField({
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
  return /*#__PURE__*/React.createElement("label", {
    style: {
      display: "flex",
      flexDirection: "column",
      gap: 6,
      ...style
    }
  }, label ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-ui)",
      fontSize: "var(--type-footnote)",
      color: "var(--text-secondary)",
      fontWeight: "var(--weight-medium)"
    }
  }, label) : null, /*#__PURE__*/React.createElement("span", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8,
      background: "var(--surface-2)",
      border: "1px solid var(--hairline)",
      borderRadius: "var(--radius-sm)",
      padding: "0 12px"
    }
  }, leading, /*#__PURE__*/React.createElement("input", _extends({
    type: type,
    value: value,
    onChange: e => onChange && onChange(e.target.value),
    placeholder: placeholder,
    spellCheck: false,
    autoCapitalize: "none",
    autoCorrect: "off",
    style: {
      flex: 1,
      minWidth: 0,
      background: "transparent",
      border: "none",
      outline: "none",
      padding: "11px 0",
      fontFamily: mono ? "var(--font-mono)" : "var(--font-ui)",
      fontSize: mono ? "var(--type-subheadline)" : "var(--type-body)",
      color: "var(--text-primary)"
    }
  }, rest))), footnote ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-ui)",
      fontSize: "var(--type-footnote)",
      color: "var(--text-tertiary)",
      lineHeight: 1.35
    }
  }, footnote) : null);
}
Object.assign(__ds_scope, { TextField });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/forms/TextField.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/Banner.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
const TONES = {
  warning: {
    color: "var(--warning)",
    soft: "var(--warning-soft)",
    icon: "triangle-alert"
  },
  danger: {
    color: "var(--danger)",
    soft: "var(--danger-soft)",
    icon: "triangle-alert"
  },
  accent: {
    color: "var(--accent)",
    soft: "var(--accent-soft)",
    icon: "circle-check"
  },
  info: {
    color: "var(--info)",
    soft: "color-mix(in srgb, var(--info) 14%, transparent)",
    icon: "info"
  }
};

/**
 * HomeMux Banner — an inline message card with an icon well, title + message,
 * and an optional action button. Covers the recovery banner (failed/
 * disconnected), the trial banner, and Mosh-fallback notices.
 */
function Banner({
  tone = "warning",
  icon,
  title,
  message,
  action,
  style = {},
  ...rest
}) {
  const t = TONES[tone] || TONES.warning;
  return /*#__PURE__*/React.createElement("div", _extends({
    style: {
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
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("span", {
    style: {
      width: 30,
      height: 30,
      flex: "none",
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      borderRadius: "50%",
      background: t.soft,
      color: t.color
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: icon || t.icon,
    size: 17,
    color: "currentColor"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0,
      display: "flex",
      flexDirection: "column",
      gap: 3
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: "var(--type-subheadline)",
      fontWeight: "var(--weight-semibold)",
      color: "var(--text-primary)"
    }
  }, title), message ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: "var(--type-footnote)",
      color: "var(--text-secondary)",
      lineHeight: 1.4
    }
  }, message) : null), action ? /*#__PURE__*/React.createElement("div", {
    style: {
      flex: "none",
      alignSelf: "center"
    }
  }, action) : null);
}
Object.assign(__ds_scope, { Banner });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/Banner.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/Card.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux Card — a grouped container. `material` is the translucent blurred
 * card used over the terminal / onboarding; `solid` is the opaque grouped
 * surface used in lists and settings. Hairline border, continuous corners.
 */
function Card({
  children,
  variant = "solid",
  accent = false,
  padding = "var(--inset-card)",
  style = {},
  ...rest
}) {
  const variants = {
    solid: {
      background: "var(--surface-1)"
    },
    material: {
      background: "var(--material-regular)",
      WebkitBackdropFilter: "var(--blur-regular)",
      backdropFilter: "var(--blur-regular)"
    },
    raised: {
      background: "var(--surface-2)",
      boxShadow: "var(--shadow-card)"
    }
  };
  return /*#__PURE__*/React.createElement("div", _extends({
    style: {
      borderRadius: "var(--radius-xl)",
      border: "1px solid " + (accent ? "var(--accent-line)" : "var(--hairline)"),
      padding,
      color: "var(--text-primary)",
      fontFamily: "var(--font-ui)",
      ...variants[variant],
      ...style
    }
  }, rest), children);
}
Object.assign(__ds_scope, { Card });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/Card.jsx", error: String((e && e.message) || e) }); }

// components/surfaces/ListRow.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux ListRow — an inset-grouped list row. Optional leading element (an
 * icon tile), a title + subtitle stack, trailing content (badges, palette
 * dots, chevron), and a pressable affordance.
 */
function ListRow({
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
  return /*#__PURE__*/React.createElement("div", _extends({
    onClick: onClick,
    role: pressable ? "button" : undefined,
    style: {
      display: "flex",
      alignItems: "center",
      gap: 12,
      padding: "12px 14px",
      background: "var(--surface-1)",
      fontFamily: "var(--font-ui)",
      color: "var(--text-primary)",
      cursor: pressable ? "pointer" : "default",
      transition: "background var(--dur-fast) var(--ease-standard)",
      ...style
    },
    onMouseEnter: e => pressable && (e.currentTarget.style.background = "var(--surface-2)"),
    onMouseLeave: e => pressable && (e.currentTarget.style.background = "var(--surface-1)")
  }, rest), leading, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0,
      display: "flex",
      flexDirection: "column",
      gap: 4
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: "var(--type-headline)",
      fontWeight: "var(--weight-semibold)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, title), subtitle ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: "var(--type-subheadline)",
      color: "var(--text-secondary)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, subtitle) : null, detail ? /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: "var(--type-caption)",
      color: "var(--text-tertiary)",
      display: "flex",
      alignItems: "center",
      gap: 6
    }
  }, detail) : null), trailing, chevron ? /*#__PURE__*/React.createElement("span", {
    style: {
      color: "var(--text-tertiary)",
      display: "inline-flex"
    },
    "aria-hidden": "true"
  }, /*#__PURE__*/React.createElement("svg", {
    width: "8",
    height: "14",
    viewBox: "0 0 8 14",
    fill: "none"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 1l6 6-6 6",
    stroke: "currentColor",
    strokeWidth: "2",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  }))) : null);
}

/**
 * IconTile — the rounded square leading glyph used in host rows: theme
 * background, accent terminal glyph, faint accent hairline.
 */
function IconTile({
  children,
  size = 44,
  background = "var(--bg-abyss)",
  tint = "var(--accent)",
  style = {}
}) {
  return /*#__PURE__*/React.createElement("span", {
    style: {
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
      ...style
    }
  }, children);
}
Object.assign(__ds_scope, { ListRow, IconTile });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/surfaces/ListRow.jsx", error: String((e && e.message) || e) }); }

// components/terminal/themes.js
try { (() => {
// HomeMux built-in terminal themes (ported from TerminalTheme.swift).
// Shared business data for PaletteDots / ThemePreviewCard. Styling stays in CSS.

const THEMES = {
  "homemux-dark": {
    id: "homemux-dark",
    name: "HomeMux Dark",
    appearance: "Dark",
    bg: "#0A0D12",
    fg: "#DDE5F1",
    caret: "#7CF7B6",
    accent: "#7CF7B6",
    ansi: ["#151A22", "#FF6B72", "#67E8A5", "#F6C177", "#7AA2FF", "#C792EA", "#5EDDE6", "#DDE5F1", "#5A6472", "#FF8F95", "#8AF0BB", "#F9D99A", "#9BB8FF", "#D9A5F2", "#8BEAF0", "#F7FAFF"]
  },
  "coastline-light": {
    id: "coastline-light",
    name: "Coastline Light",
    appearance: "Light",
    bg: "#F8FBFF",
    fg: "#16202C",
    caret: "#0969B3",
    accent: "#0969B3",
    ansi: ["#102030", "#B83248", "#177A4D", "#9B6A00", "#1C64B7", "#8752A3", "#0C7C86", "#E4EAF2", "#5D6A78", "#D94D61", "#209B63", "#BA8200", "#2F7FDF", "#A96AC5", "#109AA6", "#FFFFFF"]
  },
  "ember-console": {
    id: "ember-console",
    name: "Ember Console",
    appearance: "Dark",
    bg: "#120E0B",
    fg: "#F3E5D8",
    caret: "#FFB06A",
    accent: "#FFB06A",
    ansi: ["#211813", "#FF6A5C", "#86D88A", "#E8B75F", "#74A4FF", "#D087D6", "#69C9C4", "#E8D6C7", "#6F5A4E", "#FF8E82", "#A8E6A9", "#F5D68A", "#9BBCFF", "#E0A1E5", "#91DAD6", "#FFF4EA"]
  },
  "pine-mist": {
    id: "pine-mist",
    name: "Pine Mist",
    appearance: "Light",
    bg: "#F4F7F2",
    fg: "#18251E",
    caret: "#2D7D5F",
    accent: "#2D7D5F",
    ansi: ["#102018", "#B4474A", "#2D7D5F", "#8B6F20", "#3E6FA3", "#7C5B91", "#2F8087", "#E1E8DF", "#607267", "#D25E62", "#3F9C78", "#A9862C", "#5789C1", "#9671AD", "#3F9AA1", "#FFFFFF"]
  }
};
function resolveTheme(theme) {
  if (!theme) return THEMES["homemux-dark"];
  if (typeof theme === "string") return THEMES[theme] || THEMES["homemux-dark"];
  return theme;
}
Object.assign(__ds_scope, { THEMES, resolveTheme });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/terminal/themes.js", error: String((e && e.message) || e) }); }

// components/terminal/PaletteDots.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux PaletteDots — the overlapping ANSI swatch dots that preview a theme
 * in list rows and the theme picker (colors 0,1,2,4,5,6).
 */
function PaletteDots({
  theme = "homemux-dark",
  size = 16,
  ring = "var(--surface-1)",
  style = {},
  ...rest
}) {
  const t = __ds_scope.resolveTheme(theme);
  const idx = [0, 1, 2, 4, 5, 6];
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
      display: "inline-flex",
      paddingRight: 2,
      ...style
    }
  }, rest), idx.map((i, k) => /*#__PURE__*/React.createElement("span", {
    key: i,
    style: {
      width: size,
      height: size,
      marginLeft: k === 0 ? 0 : -size * 0.3,
      borderRadius: "50%",
      background: t.ansi[i],
      boxShadow: `0 0 0 1.5px ${ring}`
    }
  })));
}
Object.assign(__ds_scope, { PaletteDots });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/terminal/PaletteDots.jsx", error: String((e && e.message) || e) }); }

// components/terminal/ThemePreviewCard.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
/**
 * HomeMux ThemePreviewCard — the live terminal swatch shown in Settings and
 * the host editor. Renders sample prompt lines in the theme's own colors plus
 * the full 16-color ANSI ramp, framed by an accent hairline.
 */
function ThemePreviewCard({
  theme = "homemux-dark",
  showTitle = true,
  style = {},
  ...rest
}) {
  const t = __ds_scope.resolveTheme(theme);
  return /*#__PURE__*/React.createElement("div", _extends({
    style: {
      background: t.bg,
      borderRadius: "var(--radius-lg)",
      border: `1px solid ${t.accent}59`,
      padding: 14,
      display: "flex",
      flexDirection: "column",
      gap: 12,
      fontFamily: "var(--font-ui)",
      ...style
    }
  }, rest), showTitle ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      flexDirection: "column",
      gap: 2
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: "var(--type-headline)",
      fontWeight: "var(--weight-semibold)",
      color: t.fg
    }
  }, t.name), /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: "var(--type-caption)",
      color: t.fg + "AA"
    }
  }, t.appearance)), /*#__PURE__*/React.createElement("span", {
    style: {
      width: 12,
      height: 12,
      borderRadius: "50%",
      background: t.accent
    }
  })) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: "var(--font-mono)",
      fontSize: "var(--type-caption)",
      lineHeight: 1.5,
      display: "flex",
      flexDirection: "column",
      gap: 2
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: t.ansi[10]
    }
  }, "$ tmux attach -t work"), /*#__PURE__*/React.createElement("span", {
    style: {
      color: t.fg
    }
  }, "HomeMux reconnects to your session"), /*#__PURE__*/React.createElement("span", {
    style: {
      color: t.ansi[11]
    }
  }, "errors stay readable, prompts stay calm")), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "grid",
      gridTemplateColumns: "repeat(8, 1fr)",
      gap: 4
    }
  }, t.ansi.map((c, i) => /*#__PURE__*/React.createElement("span", {
    key: i,
    style: {
      height: 14,
      borderRadius: 4,
      background: c
    }
  }))));
}
Object.assign(__ds_scope, { ThemePreviewCard });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/terminal/ThemePreviewCard.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/app.jsx
try { (() => {
// HomeMux iOS — interactive shell tying the screens + states together.
(function () {
  function App() {
    const allHosts = window.HMX_HOSTS;
    const [stage, setStage] = React.useState("onboarding"); // onboarding | home | terminal | paywall
    const [emptyHome, setEmptyHome] = React.useState(false);
    const [host, setHost] = React.useState(null);
    const [term, setTerm] = React.useState({
      state: "connected",
      fallback: false,
      selecting: false
    });
    const [overlay, setOverlay] = React.useState(null); // add | settings | cmd | hostkey | password | tmux | tmuxEmpty

    const openTerminal = (h, opts = {}) => {
      setHost(h);
      setOverlay(null);
      setTerm({
        state: "connected",
        fallback: false,
        selecting: false,
        ...opts
      });
      setStage("terminal");
    };
    const goTerm = opts => openTerminal(allHosts[1], opts);
    const groups = [["Flow", [["Onboarding", () => {
      setOverlay(null);
      setStage("onboarding");
    }], ["Home", () => {
      setOverlay(null);
      setEmptyHome(false);
      setStage("home");
    }], ["Empty", () => {
      setOverlay(null);
      setEmptyHome(true);
      setStage("home");
    }]]], ["Terminal", [["Connected", () => goTerm({})], ["Connecting", () => goTerm({
      state: "connecting"
    })], ["Failed", () => goTerm({
      state: "failed"
    })], ["Mosh→SSH", () => goTerm({
      fallback: true
    })], ["Selection", () => goTerm({
      selecting: true
    })], ["Command", () => {
      goTerm({});
      setOverlay("cmd");
    }]]], ["Sheets & prompts", [["Add Host", () => {
      setStage("home");
      setOverlay("add");
    }], ["Settings", () => {
      setStage("home");
      setOverlay("settings");
    }], ["Host Key", () => {
      goTerm({
        state: "connecting"
      });
      setOverlay("hostkey");
    }], ["Password", () => {
      goTerm({
        state: "connecting"
      });
      setOverlay("password");
    }], ["tmux", () => {
      goTerm({});
      setOverlay("tmux");
    }], ["tmux · none", () => {
      goTerm({});
      setOverlay("tmuxEmpty");
    }], ["Paywall", () => {
      setOverlay(null);
      setStage("paywall");
    }]]]];
    return /*#__PURE__*/React.createElement("div", {
      style: {
        minHeight: "100vh",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 18,
        padding: "32px 16px",
        background: "radial-gradient(120% 90% at 50% 0%, #14181F 0%, #0A0C10 60%, #07090C 100%)"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        position: "relative"
      }
    }, /*#__PURE__*/React.createElement(window.IOSDevice, {
      dark: true
    }, stage === "home" && /*#__PURE__*/React.createElement(window.Home, {
      hosts: emptyHome ? [] : allHosts,
      onOpen: h => openTerminal(h),
      onAdd: () => setOverlay("add"),
      onSettings: () => setOverlay("settings")
    }), stage === "terminal" && host && /*#__PURE__*/React.createElement(window.Terminal, {
      host: host,
      state: term.state,
      fallback: term.fallback,
      selecting: term.selecting,
      onBack: () => setStage("home"),
      onCommandMenu: () => setOverlay("cmd"),
      onExitSelect: () => setTerm(t => ({
        ...t,
        selecting: false
      })),
      onReconnect: () => setTerm({
        state: "connected",
        fallback: true,
        selecting: false
      })
    }), stage === "paywall" && /*#__PURE__*/React.createElement(window.Paywall, {
      onBack: () => setStage("home")
    }), stage === "onboarding" && /*#__PURE__*/React.createElement(window.Onboarding, {
      onDone: () => setStage("home")
    }), overlay === "add" && /*#__PURE__*/React.createElement(window.AddHost, {
      onClose: () => setOverlay(null),
      onSave: () => setOverlay(null)
    }), overlay === "settings" && /*#__PURE__*/React.createElement(window.Settings, {
      onClose: () => setOverlay(null)
    }), overlay === "cmd" && /*#__PURE__*/React.createElement(window.CommandMenu, {
      onClose: () => setOverlay(null)
    }), overlay === "hostkey" && /*#__PURE__*/React.createElement(window.HostKeyPrompt, {
      onTrust: () => openTerminal(allHosts[1]),
      onCancel: () => setOverlay(null)
    }), overlay === "password" && /*#__PURE__*/React.createElement(window.PasswordPrompt, {
      host: host,
      onConnect: () => openTerminal(allHosts[1]),
      onCancel: () => setOverlay(null)
    }), overlay === "tmux" && /*#__PURE__*/React.createElement(window.TmuxPicker, {
      variant: "sessions",
      onClose: () => setOverlay(null),
      onAttach: () => openTerminal(allHosts[1])
    }), overlay === "tmuxEmpty" && /*#__PURE__*/React.createElement(window.TmuxPicker, {
      variant: "empty",
      onClose: () => setOverlay(null)
    }))), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: 8,
        maxWidth: 470,
        width: "100%"
      }
    }, groups.map(([label, items]) => /*#__PURE__*/React.createElement("div", {
      key: label,
      style: {
        display: "flex",
        flexWrap: "wrap",
        gap: 7,
        alignItems: "center",
        justifyContent: "center"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: 10,
        textTransform: "uppercase",
        letterSpacing: "0.08em",
        color: "var(--text-tertiary)",
        width: "100%",
        textAlign: "center"
      }
    }, label), items.map(([t, fn]) => /*#__PURE__*/React.createElement("button", {
      key: t,
      onClick: fn,
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: 12,
        color: "var(--text-secondary)",
        background: "rgba(255,255,255,0.04)",
        border: "1px solid var(--hairline)",
        borderRadius: 99,
        padding: "6px 13px",
        cursor: "pointer"
      }
    }, t))))));
  }
  ReactDOM.createRoot(document.getElementById("root")).render(/*#__PURE__*/React.createElement(App, null));
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/app.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/data.js
try { (() => {
// Sample data for the HomeMux iOS UI kit (from MVP-PLAN §15.2 home-screen layout).
window.HMX_HOSTS = [{
  id: "mac",
  title: "Mac mini",
  endpoint: "alex@mac-mini.local",
  port: 22,
  transport: "Automatic",
  activeTransport: "Mosh",
  auth: "Private Key",
  startup: "Plain shell",
  startupIcon: "square-terminal",
  theme: "homemux-dark"
}, {
  id: "claude",
  title: "Mac mini · claude",
  endpoint: "alex@mac-mini.local",
  port: 22,
  transport: "Automatic",
  activeTransport: "Mosh",
  auth: "Private Key",
  startup: "tmux · claude",
  startupIcon: "layers",
  theme: "homemux-dark"
}, {
  id: "codex",
  title: "Mac mini · codex",
  endpoint: "alex@mac-mini.local",
  port: 22,
  transport: "Automatic",
  activeTransport: "Mosh",
  auth: "Private Key",
  startup: "tmux · codex",
  startupIcon: "layers",
  theme: "ember-console"
}, {
  id: "vps",
  title: "VPS",
  endpoint: "root@example.com",
  port: 22,
  transport: "SSH",
  activeTransport: "SSH",
  auth: "Password",
  startup: "Plain shell",
  startupIcon: "square-terminal",
  theme: "homemux-dark"
}];
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/data.js", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/ios-frame.jsx
try { (() => {
// @ds-adherence-ignore -- omelette starter scaffold (raw elements/hex/px by design)

/* BEGIN USAGE */
// iOS.jsx — Simplified iOS 26 (Liquid Glass) device frame
// Based on the iOS 26 UI Kit + Figma status bar spec. No assets, no deps.
// Exports (to window): IOSDevice, IOSStatusBar, IOSNavBar, IOSGlassPill, IOSList, IOSListRow, IOSKeyboard
//
// Usage — wrap your screen content in <IOSDevice> to get the bezel, status bar
// and home indicator (props: title, dark, keyboard):
//
//   <IOSDevice title="Settings">
//     ...your screen content...
//   </IOSDevice>
//   <IOSDevice dark title="Search" keyboard>…</IOSDevice>
/* END USAGE */

// ─────────────────────────────────────────────────────────────
// Status bar
// ─────────────────────────────────────────────────────────────
function IOSStatusBar({
  dark = false,
  time = '9:41'
}) {
  const c = dark ? '#fff' : '#000';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 154,
      alignItems: 'center',
      justifyContent: 'center',
      padding: '21px 24px 19px',
      boxSizing: 'border-box',
      position: 'relative',
      zIndex: 20,
      width: '100%'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      height: 22,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      paddingTop: 1.5
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: '-apple-system, "SF Pro", system-ui',
      fontWeight: 590,
      fontSize: 17,
      lineHeight: '22px',
      color: c
    }
  }, time)), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      height: 22,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
      paddingTop: 1,
      paddingRight: 1
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "19",
    height: "12",
    viewBox: "0 0 19 12"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0",
    y: "7.5",
    width: "3.2",
    height: "4.5",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "4.8",
    y: "5",
    width: "3.2",
    height: "7",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "9.6",
    y: "2.5",
    width: "3.2",
    height: "9.5",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "14.4",
    y: "0",
    width: "3.2",
    height: "12",
    rx: "0.7",
    fill: c
  })), /*#__PURE__*/React.createElement("svg", {
    width: "17",
    height: "12",
    viewBox: "0 0 17 12"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M8.5 3.2C10.8 3.2 12.9 4.1 14.4 5.6L15.5 4.5C13.7 2.7 11.2 1.5 8.5 1.5C5.8 1.5 3.3 2.7 1.5 4.5L2.6 5.6C4.1 4.1 6.2 3.2 8.5 3.2Z",
    fill: c
  }), /*#__PURE__*/React.createElement("path", {
    d: "M8.5 6.8C9.9 6.8 11.1 7.3 12 8.2L13.1 7.1C11.8 5.9 10.2 5.1 8.5 5.1C6.8 5.1 5.2 5.9 3.9 7.1L5 8.2C5.9 7.3 7.1 6.8 8.5 6.8Z",
    fill: c
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "8.5",
    cy: "10.5",
    r: "1.5",
    fill: c
  })), /*#__PURE__*/React.createElement("svg", {
    width: "27",
    height: "13",
    viewBox: "0 0 27 13"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0.5",
    y: "0.5",
    width: "23",
    height: "12",
    rx: "3.5",
    stroke: c,
    strokeOpacity: "0.35",
    fill: "none"
  }), /*#__PURE__*/React.createElement("rect", {
    x: "2",
    y: "2",
    width: "20",
    height: "9",
    rx: "2",
    fill: c
  }), /*#__PURE__*/React.createElement("path", {
    d: "M25 4.5V8.5C25.8 8.2 26.5 7.2 26.5 6.5C26.5 5.8 25.8 4.8 25 4.5Z",
    fill: c,
    fillOpacity: "0.4"
  }))));
}

// ─────────────────────────────────────────────────────────────
// Liquid glass pill — blur + tint + shine
// ─────────────────────────────────────────────────────────────
function IOSGlassPill({
  children,
  dark = false,
  style = {}
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      height: 44,
      minWidth: 44,
      borderRadius: 9999,
      position: 'relative',
      overflow: 'hidden',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      boxShadow: dark ? '0 2px 6px rgba(0,0,0,0.35), 0 6px 16px rgba(0,0,0,0.2)' : '0 1px 3px rgba(0,0,0,0.07), 0 3px 10px rgba(0,0,0,0.06)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 9999,
      backdropFilter: 'blur(12px) saturate(180%)',
      WebkitBackdropFilter: 'blur(12px) saturate(180%)',
      background: dark ? 'rgba(120,120,128,0.28)' : 'rgba(255,255,255,0.5)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 9999,
      boxShadow: dark ? 'inset 1.5px 1.5px 1px rgba(255,255,255,0.15), inset -1px -1px 1px rgba(255,255,255,0.08)' : 'inset 1.5px 1.5px 1px rgba(255,255,255,0.7), inset -1px -1px 1px rgba(255,255,255,0.4)',
      border: dark ? '0.5px solid rgba(255,255,255,0.15)' : '0.5px solid rgba(0,0,0,0.06)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 1,
      display: 'flex',
      alignItems: 'center',
      padding: '0 4px'
    }
  }, children));
}

// ─────────────────────────────────────────────────────────────
// Navigation bar — glass pills + large title
// ─────────────────────────────────────────────────────────────
function IOSNavBar({
  title = 'Title',
  dark = false,
  trailingIcon = true
}) {
  const muted = dark ? 'rgba(255,255,255,0.6)' : '#404040';
  const text = dark ? '#fff' : '#000';
  const pillIcon = content => /*#__PURE__*/React.createElement(IOSGlassPill, {
    dark: dark
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 36,
      height: 36,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center'
    }
  }, content));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 10,
      paddingTop: 62,
      paddingBottom: 10,
      position: 'relative',
      zIndex: 5
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '0 16px'
    }
  }, pillIcon(/*#__PURE__*/React.createElement("svg", {
    width: "12",
    height: "20",
    viewBox: "0 0 12 20",
    fill: "none",
    style: {
      marginLeft: -1
    }
  }, /*#__PURE__*/React.createElement("path", {
    d: "M10 2L2 10l8 8",
    stroke: muted,
    strokeWidth: "2.5",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  }))), trailingIcon && pillIcon(/*#__PURE__*/React.createElement("svg", {
    width: "22",
    height: "6",
    viewBox: "0 0 22 6"
  }, /*#__PURE__*/React.createElement("circle", {
    cx: "3",
    cy: "3",
    r: "2.5",
    fill: muted
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "11",
    cy: "3",
    r: "2.5",
    fill: muted
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "19",
    cy: "3",
    r: "2.5",
    fill: muted
  })))), /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '0 16px',
      fontFamily: '-apple-system, system-ui',
      fontSize: 34,
      fontWeight: 700,
      lineHeight: '41px',
      color: text,
      letterSpacing: 0.4
    }
  }, title));
}

// ─────────────────────────────────────────────────────────────
// Grouped list (inset card, r:26) + row (52px)
// ─────────────────────────────────────────────────────────────
function IOSListRow({
  title,
  detail,
  icon,
  chevron = true,
  isLast = false,
  dark = false
}) {
  const text = dark ? '#fff' : '#000';
  const sec = dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const ter = dark ? 'rgba(235,235,245,0.3)' : 'rgba(60,60,67,0.3)';
  const sep = dark ? 'rgba(84,84,88,0.65)' : 'rgba(60,60,67,0.12)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      minHeight: 52,
      padding: '0 16px',
      position: 'relative',
      fontFamily: '-apple-system, system-ui',
      fontSize: 17,
      letterSpacing: -0.43
    }
  }, icon && /*#__PURE__*/React.createElement("div", {
    style: {
      width: 30,
      height: 30,
      borderRadius: 7,
      background: icon,
      marginRight: 12,
      flexShrink: 0
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      color: text
    }
  }, title), detail && /*#__PURE__*/React.createElement("span", {
    style: {
      color: sec,
      marginRight: 6
    }
  }, detail), chevron && /*#__PURE__*/React.createElement("svg", {
    width: "8",
    height: "14",
    viewBox: "0 0 8 14",
    style: {
      flexShrink: 0
    }
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 1l6 6-6 6",
    stroke: ter,
    strokeWidth: "2",
    fill: "none",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  })), !isLast && /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      bottom: 0,
      right: 0,
      left: icon ? 58 : 16,
      height: 0.5,
      background: sep
    }
  }));
}
function IOSList({
  header,
  children,
  dark = false
}) {
  const hc = dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const bg = dark ? '#1C1C1E' : '#fff';
  return /*#__PURE__*/React.createElement("div", null, header && /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: '-apple-system, system-ui',
      fontSize: 13,
      color: hc,
      textTransform: 'uppercase',
      padding: '8px 36px 6px',
      letterSpacing: -0.08
    }
  }, header), /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      borderRadius: 26,
      margin: '0 16px',
      overflow: 'hidden'
    }
  }, children));
}

// ─────────────────────────────────────────────────────────────
// Device frame
// ─────────────────────────────────────────────────────────────
function IOSDevice({
  children,
  width = 402,
  height = 874,
  dark = false,
  title,
  keyboard = false
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      width,
      height,
      borderRadius: 48,
      overflow: 'hidden',
      position: 'relative',
      background: dark ? '#000' : '#F2F2F7',
      boxShadow: '0 40px 80px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.12)',
      fontFamily: '-apple-system, system-ui, sans-serif',
      WebkitFontSmoothing: 'antialiased'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 11,
      left: '50%',
      transform: 'translateX(-50%)',
      width: 126,
      height: 37,
      borderRadius: 24,
      background: '#000',
      zIndex: 50
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 0,
      left: 0,
      right: 0,
      zIndex: 10
    }
  }, /*#__PURE__*/React.createElement(IOSStatusBar, {
    dark: dark
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      height: '100%',
      display: 'flex',
      flexDirection: 'column'
    }
  }, title !== undefined && /*#__PURE__*/React.createElement(IOSNavBar, {
    title: title,
    dark: dark
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      overflow: 'auto'
    }
  }, children), keyboard && /*#__PURE__*/React.createElement(IOSKeyboard, {
    dark: dark
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      bottom: 0,
      left: 0,
      right: 0,
      zIndex: 60,
      height: 34,
      display: 'flex',
      justifyContent: 'center',
      alignItems: 'flex-end',
      paddingBottom: 8,
      pointerEvents: 'none'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 139,
      height: 5,
      borderRadius: 100,
      background: dark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.25)'
    }
  })));
}

// ─────────────────────────────────────────────────────────────
// Keyboard — iOS 26 liquid glass
// ─────────────────────────────────────────────────────────────
function IOSKeyboard({
  dark = false
}) {
  const glyph = dark ? 'rgba(255,255,255,0.7)' : '#595959';
  const sugg = dark ? 'rgba(255,255,255,0.6)' : '#333';
  const keyBg = dark ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.85)';

  // special-key icons
  const icons = {
    shift: /*#__PURE__*/React.createElement("svg", {
      width: "19",
      height: "17",
      viewBox: "0 0 19 17"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M9.5 1L1 9.5h4.5V16h8V9.5H18L9.5 1z",
      fill: glyph
    })),
    del: /*#__PURE__*/React.createElement("svg", {
      width: "23",
      height: "17",
      viewBox: "0 0 23 17"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M7 1h13a2 2 0 012 2v11a2 2 0 01-2 2H7l-6-7.5L7 1z",
      fill: "none",
      stroke: glyph,
      strokeWidth: "1.6",
      strokeLinejoin: "round"
    }), /*#__PURE__*/React.createElement("path", {
      d: "M10 5l7 7M17 5l-7 7",
      stroke: glyph,
      strokeWidth: "1.6",
      strokeLinecap: "round"
    })),
    ret: /*#__PURE__*/React.createElement("svg", {
      width: "20",
      height: "14",
      viewBox: "0 0 20 14"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M18 1v6H4m0 0l4-4M4 7l4 4",
      fill: "none",
      stroke: "#fff",
      strokeWidth: "1.8",
      strokeLinecap: "round",
      strokeLinejoin: "round"
    }))
  };
  const key = (content, {
    w,
    flex,
    ret,
    fs = 25,
    k
  } = {}) => /*#__PURE__*/React.createElement("div", {
    key: k,
    style: {
      height: 42,
      borderRadius: 8.5,
      flex: flex ? 1 : undefined,
      width: w,
      minWidth: 0,
      background: ret ? '#08f' : keyBg,
      boxShadow: '0 1px 0 rgba(0,0,0,0.075)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: '-apple-system, "SF Compact", system-ui',
      fontSize: fs,
      fontWeight: 458,
      color: ret ? '#fff' : glyph
    }
  }, content);
  const row = (keys, pad = 0) => /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6.5,
      justifyContent: 'center',
      padding: `0 ${pad}px`
    }
  }, keys.map(l => key(l, {
    flex: true,
    k: l
  })));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 15,
      borderRadius: 27,
      overflow: 'hidden',
      padding: '11px 0 2px',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      boxShadow: dark ? '0 -2px 20px rgba(0,0,0,0.09)' : '0 -1px 6px rgba(0,0,0,0.018), 0 -3px 20px rgba(0,0,0,0.012)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 27,
      backdropFilter: 'blur(12px) saturate(180%)',
      WebkitBackdropFilter: 'blur(12px) saturate(180%)',
      background: dark ? 'rgba(120,120,128,0.14)' : 'rgba(255,255,255,0.25)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 27,
      boxShadow: dark ? 'inset 1.5px 1.5px 1px rgba(255,255,255,0.15)' : 'inset 1.5px 1.5px 1px rgba(255,255,255,0.7), inset -1px -1px 1px rgba(255,255,255,0.4)',
      border: dark ? '0.5px solid rgba(255,255,255,0.15)' : '0.5px solid rgba(0,0,0,0.06)',
      pointerEvents: 'none'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 20,
      alignItems: 'center',
      padding: '8px 22px 13px',
      width: '100%',
      boxSizing: 'border-box',
      position: 'relative'
    }
  }, ['"The"', 'the', 'to'].map((w, i) => /*#__PURE__*/React.createElement(React.Fragment, {
    key: i
  }, i > 0 && /*#__PURE__*/React.createElement("div", {
    style: {
      width: 1,
      height: 25,
      background: '#ccc',
      opacity: 0.3
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      textAlign: 'center',
      fontFamily: '-apple-system, system-ui',
      fontSize: 17,
      color: sugg,
      letterSpacing: -0.43,
      lineHeight: '22px'
    }
  }, w)))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 13,
      padding: '0 6.5px',
      width: '100%',
      boxSizing: 'border-box',
      position: 'relative'
    }
  }, row(['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p']), row(['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'], 20), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 14.25,
      alignItems: 'center'
    }
  }, key(icons.shift, {
    w: 45,
    k: 'shift'
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6.5,
      flex: 1
    }
  }, ['z', 'x', 'c', 'v', 'b', 'n', 'm'].map(l => key(l, {
    flex: true,
    k: l
  }))), key(icons.del, {
    w: 45,
    k: 'del'
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6,
      alignItems: 'center'
    }
  }, key('ABC', {
    w: 92.25,
    fs: 18,
    k: 'abc'
  }), key('', {
    flex: true,
    k: 'space'
  }), key(icons.ret, {
    w: 92.25,
    ret: true,
    k: 'ret'
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      height: 56,
      width: '100%',
      position: 'relative'
    }
  }));
}
Object.assign(window, {
  IOSDevice,
  IOSStatusBar,
  IOSNavBar,
  IOSGlassPill,
  IOSList,
  IOSListRow,
  IOSKeyboard
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/ios-frame.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/AddHost.jsx
try { (() => {
// Add Host — host editor sheet (ported from HostEditorView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    TextField,
    SegmentedControl,
    Switch,
    ThemePreviewCard,
    Button,
    Icon
  } = HMX;
  const Sheet = window.HMXSheet;
  function Section({
    label,
    children
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        marginTop: 16
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        fontWeight: 600,
        letterSpacing: "0.04em",
        textTransform: "uppercase",
        color: "var(--text-tertiary)",
        padding: "0 4px 8px"
      }
    }, label), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: 12
      }
    }, children));
  }
  function AddHost({
    onClose,
    onSave
  }) {
    const [name, setName] = React.useState("Mac mini · claude");
    const [host, setHost] = React.useState("mac-mini.local");
    const [user, setUser] = React.useState("alex");
    const [transport, setTransport] = React.useState("automatic");
    const [auth, setAuth] = React.useState("key");
    const [tmux, setTmux] = React.useState(true);
    const [session, setSession] = React.useState("claude");
    return /*#__PURE__*/React.createElement(Sheet, {
      title: "Add Host",
      onClose: onClose
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        overflowY: "auto",
        padding: "0 16px 12px"
      }
    }, /*#__PURE__*/React.createElement(Section, {
      label: "Connection"
    }, /*#__PURE__*/React.createElement(TextField, {
      label: "Display name",
      value: name,
      onChange: setName
    }), /*#__PURE__*/React.createElement(TextField, {
      label: "Host",
      value: host,
      onChange: setHost,
      leading: /*#__PURE__*/React.createElement(Icon, {
        name: "server",
        size: 16,
        color: "var(--text-tertiary)"
      })
    }), /*#__PURE__*/React.createElement(TextField, {
      label: "Username",
      value: user,
      onChange: setUser
    })), /*#__PURE__*/React.createElement(Section, {
      label: "Transport"
    }, /*#__PURE__*/React.createElement(SegmentedControl, {
      value: transport,
      onChange: setTransport,
      options: [{
        label: "Automatic",
        value: "automatic"
      }, {
        label: "SSH",
        value: "ssh"
      }, {
        label: "Mosh",
        value: "mosh"
      }]
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        padding: "0 4px",
        lineHeight: 1.4
      }
    }, "Automatic uses Mosh when available and falls back to SSH. You never choose up front.")), /*#__PURE__*/React.createElement(Section, {
      label: "Authentication"
    }, /*#__PURE__*/React.createElement(SegmentedControl, {
      value: auth,
      onChange: setAuth,
      options: [{
        label: "Password",
        value: "pwd"
      }, {
        label: "Private Key",
        value: "key"
      }]
    }), auth === "key" ? /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: 6
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        background: "var(--bg-abyss)",
        border: "1px solid var(--hairline)",
        borderRadius: "var(--radius-sm)",
        padding: "12px 13px",
        minHeight: 92,
        fontFamily: "var(--font-mono)",
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        lineHeight: 1.5
      }
    }, "Paste OpenSSH Ed25519 private key\u2026"), /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        padding: "0 4px",
        lineHeight: 1.4
      }
    }, "Stored in the iOS Keychain. The key never leaves this device.")) : /*#__PURE__*/React.createElement(TextField, {
      label: "Password",
      type: "password",
      placeholder: "\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022",
      value: "",
      onChange: () => {}
    })), /*#__PURE__*/React.createElement(Section, {
      label: "Startup"
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        background: "var(--surface-1)",
        border: "1px solid var(--hairline)",
        borderRadius: "var(--radius-md)",
        padding: "12px 14px"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: "var(--type-callout)"
      }
    }, "One-tap tmux session"), /*#__PURE__*/React.createElement(Switch, {
      checked: tmux,
      onChange: setTmux
    })), tmux && /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(TextField, {
      label: "Session name",
      mono: true,
      value: session,
      onChange: setSession
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: "var(--type-footnote)",
        color: "var(--text-secondary)",
        background: "var(--bg-abyss)",
        border: "1px solid var(--hairline)",
        borderRadius: 10,
        padding: "10px 12px"
      }
    }, "tmux new-session -A -s ", session || "session"))), /*#__PURE__*/React.createElement(Section, {
      label: "Appearance"
    }, /*#__PURE__*/React.createElement(ThemePreviewCard, {
      theme: "homemux-dark"
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        marginTop: 18
      }
    }, /*#__PURE__*/React.createElement(Button, {
      variant: "prominent",
      fullWidth: true,
      onClick: onSave
    }, "Save Host"))));
  }
  window.AddHost = AddHost;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/AddHost.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/CommandMenu.jsx
try { (() => {
// Command Menu — floating command palette sheet (ported from CommandPaletteView + TerminalCommandCatalog)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    Icon
  } = HMX;
  const GROUPS = [{
    title: "Text",
    items: [{
      icon: "text-cursor-input",
      title: "Select Text",
      sub: "Enter explicit selection mode"
    }, {
      icon: "copy",
      title: "Copy Visible Screen",
      sub: "Copy the current terminal buffer"
    }, {
      icon: "clipboard",
      title: "Paste",
      sub: "Paste clipboard text into the session"
    }]
  }, {
    title: "Keys",
    items: [{
      icon: "corner-down-left",
      title: "Send Esc",
      sub: "Escape"
    }, {
      icon: "command",
      title: "Ctrl-C",
      sub: "Interrupt"
    }, {
      icon: "arrow-up-to-line",
      title: "Home",
      sub: "Move to line start"
    }]
  }, {
    title: "tmux",
    items: [{
      icon: "square-plus",
      title: "New Window",
      sub: "tmux new-window"
    }, {
      icon: "square-arrow-right",
      title: "Next Window",
      sub: "tmux next-window"
    }, {
      icon: "log-out",
      title: "Detach",
      sub: "tmux detach-client"
    }]
  }, {
    title: "Session",
    items: [{
      icon: "rotate-cw",
      title: "Reconnect",
      sub: "Close and reopen the session"
    }, {
      icon: "layers",
      title: "List tmux Sessions",
      sub: "Open the attach session picker"
    }, {
      icon: "circle-x",
      title: "Close Session",
      sub: "Disconnect and leave this screen"
    }]
  }];
  function CommandMenu({
    onClose
  }) {
    return /*#__PURE__*/React.createElement(Sheet, {
      title: "Command Menu",
      onClose: onClose
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "0 16px 8px"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        background: "var(--surface-2)",
        border: "1px solid var(--hairline)",
        borderRadius: "var(--radius-sm)",
        padding: "9px 12px"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "search",
      size: 16,
      color: "var(--text-tertiary)"
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--text-tertiary)",
        fontSize: "var(--type-subheadline)"
      }
    }, "Search commands"))), /*#__PURE__*/React.createElement("div", {
      style: {
        overflowY: "auto",
        padding: "0 16px 8px"
      }
    }, GROUPS.map(g => /*#__PURE__*/React.createElement("div", {
      key: g.title,
      style: {
        marginTop: 14
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        fontWeight: 600,
        letterSpacing: "0.04em",
        textTransform: "uppercase",
        color: "var(--text-tertiary)",
        padding: "0 4px 6px"
      }
    }, g.title), /*#__PURE__*/React.createElement("div", {
      style: {
        background: "var(--surface-1)",
        border: "1px solid var(--hairline)",
        borderRadius: "var(--radius-md)",
        overflow: "hidden"
      }
    }, g.items.map((it, i) => /*#__PURE__*/React.createElement("div", {
      key: it.title,
      style: {
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "12px 14px",
        borderTop: i ? "1px solid var(--separator)" : "none",
        cursor: "pointer"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: it.icon,
      size: 19,
      color: "var(--text-secondary)"
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-callout)"
      }
    }, it.title), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-caption)",
        color: "var(--text-tertiary)"
      }
    }, it.sub)))))))));
  }

  // Shared bottom sheet shell.
  function Sheet({
    title,
    onClose,
    children,
    maxHeight = "82%"
  }) {
    return /*#__PURE__*/React.createElement("div", {
      onClick: onClose,
      style: {
        position: "absolute",
        inset: 0,
        zIndex: 90,
        background: "rgba(0,0,0,0.45)",
        display: "flex",
        flexDirection: "column",
        justifyContent: "flex-end"
      }
    }, /*#__PURE__*/React.createElement("div", {
      onClick: e => e.stopPropagation(),
      style: {
        maxHeight,
        background: "var(--bg-base)",
        borderTopLeftRadius: "var(--radius-2xl)",
        borderTopRightRadius: "var(--radius-2xl)",
        border: "1px solid var(--hairline)",
        borderBottom: "none",
        boxShadow: "var(--shadow-sheet)",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
        color: "var(--text-primary)",
        fontFamily: "var(--font-ui)"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        justifyContent: "center",
        paddingTop: 8
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        width: 36,
        height: 5,
        borderRadius: 99,
        background: "var(--surface-3)"
      }
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        padding: "10px 16px 12px"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: "var(--type-headline)",
        fontWeight: 600
      }
    }, title), /*#__PURE__*/React.createElement("span", {
      onClick: onClose,
      style: {
        fontSize: "var(--type-callout)",
        color: "var(--accent)",
        cursor: "pointer"
      }
    }, "Close")), children, /*#__PURE__*/React.createElement("div", {
      style: {
        height: 28,
        flex: "none"
      }
    })));
  }
  window.CommandMenu = CommandMenu;
  window.HMXSheet = Sheet;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/CommandMenu.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/Home.jsx
try { (() => {
// Home — saved connections list (ported from HomeView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    IconButton,
    Banner,
    ListRow,
    IconTile,
    Badge,
    PaletteDots,
    Icon,
    Button
  } = HMX;
  function EmptyHosts({
    onAdd
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        margin: "6px 16px 0",
        padding: "28px 24px",
        borderRadius: "var(--radius-2xl)",
        background: "var(--material-regular)",
        WebkitBackdropFilter: "var(--blur-regular)",
        backdropFilter: "var(--blur-regular)",
        border: "1px solid var(--hairline)",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 18,
        textAlign: "center"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        width: 76,
        height: 76,
        borderRadius: "var(--radius-xl)",
        background: "var(--accent-soft)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        boxShadow: "0 0 32px var(--accent-glow)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "square-terminal",
      size: 36,
      color: "var(--accent)"
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: 8
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-title2)",
        fontWeight: "var(--weight-semibold)"
      }
    }, "No Hosts Yet"), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-callout)",
        color: "var(--text-secondary)",
        lineHeight: 1.45
      }
    }, "Add your Mac mini, workstation, or homelab server to start a one-tap terminal session.")), /*#__PURE__*/React.createElement(Button, {
      variant: "prominent",
      fullWidth: true,
      icon: /*#__PURE__*/React.createElement(Icon, {
        name: "plus",
        size: 18,
        color: "currentColor"
      }),
      onClick: onAdd
    }, "Add First Host"));
  }
  function Home({
    hosts,
    onOpen,
    onAdd,
    onSettings
  }) {
    const empty = !hosts || hosts.length === 0;
    return /*#__PURE__*/React.createElement("div", {
      style: {
        minHeight: "100%",
        background: "var(--bg-base)",
        color: "var(--text-primary)",
        fontFamily: "var(--font-ui)",
        paddingBottom: 40
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "58px 16px 8px",
        display: "flex",
        flexDirection: "column",
        gap: 12
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between"
      }
    }, /*#__PURE__*/React.createElement(IconButton, {
      name: "settings",
      label: "Settings",
      variant: "plain",
      tint: "var(--text-secondary)",
      onClick: onSettings
    }), /*#__PURE__*/React.createElement(IconButton, {
      name: "plus",
      label: "Add Host",
      variant: "plain",
      tint: "var(--accent)",
      onClick: onAdd
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-large-title)",
        fontWeight: "var(--weight-bold)",
        letterSpacing: "var(--tracking-tight)"
      }
    }, "HomeMux")), /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "8px 16px 14px"
      }
    }, /*#__PURE__*/React.createElement(Banner, {
      tone: "accent",
      icon: "clock",
      title: "Trial \xB7 12 days left",
      message: "Full access is unlocked during the trial. No terminal features are gated."
    })), empty ? /*#__PURE__*/React.createElement(EmptyHosts, {
      onAdd: onAdd
    }) : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "0 16px 6px",
        fontSize: "var(--type-footnote)",
        fontWeight: 600,
        letterSpacing: "0.04em",
        textTransform: "uppercase",
        color: "var(--text-tertiary)"
      }
    }, "Connections"), /*#__PURE__*/React.createElement("div", {
      style: {
        margin: "0 16px",
        borderRadius: "var(--radius-md)",
        overflow: "hidden",
        border: "1px solid var(--hairline)"
      }
    }, hosts.map((h, i) => /*#__PURE__*/React.createElement("div", {
      key: h.id,
      style: {
        borderTop: i ? "1px solid var(--separator)" : "none"
      }
    }, /*#__PURE__*/React.createElement(ListRow, {
      chevron: true,
      onClick: () => onOpen(h),
      leading: /*#__PURE__*/React.createElement(IconTile, {
        background: h.theme === "ember-console" ? "#120E0B" : "var(--bg-abyss)",
        tint: h.theme === "ember-console" ? "#FFB06A" : "var(--accent)"
      }, /*#__PURE__*/React.createElement(Icon, {
        name: "terminal",
        size: 20
      })),
      title: h.title,
      subtitle: `${h.endpoint}:${h.port}`,
      detail: /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(Icon, {
        name: h.startupIcon,
        size: 13
      }), " ", h.auth, " \xB7 ", h.startup),
      trailing: /*#__PURE__*/React.createElement(PaletteDots, {
        theme: h.theme,
        ring: "var(--surface-1)"
      })
    })))), /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "10px 18px 0",
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        lineHeight: 1.4
      }
    }, "Tap a host to reconnect. Swipe or long-press for edit and delete actions.")));
  }
  window.Home = Home;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/Home.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/Onboarding.jsx
try { (() => {
// Onboarding — 3-page intro (ported from OnboardingView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    Button,
    Icon,
    ThemePreviewCard
  } = HMX;
  const PAGES = [{
    icon: "square-terminal",
    title: "One tap back into tmux",
    body: "HomeMux is built for the terminal sessions you already keep alive. Add a host once, then jump back into your shell or saved tmux session from iPhone."
  }, {
    icon: "shield-check",
    title: "Local-first by design",
    body: "Keys stay in Keychain. Voice input runs on device and only creates a draft. No account, no cloud vault, no telemetry by default."
  }, {
    icon: "circle-plus",
    title: "Start with one host",
    body: "Save your Mac mini, workstation, VPS, or homelab server. Automatic transport and tmux shortcuts can be tuned after the first connection."
  }];
  function Onboarding({
    onDone
  }) {
    const [page, setPage] = React.useState(0);
    const last = page === PAGES.length - 1;
    const p = PAGES[page];
    return /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        inset: 0,
        zIndex: 80,
        background: "linear-gradient(160deg, #0E141C 0%, #0A0D12 55%, #06080C 100%)",
        display: "flex",
        flexDirection: "column",
        color: "var(--text-primary)",
        fontFamily: "var(--font-ui)"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        justifyContent: "flex-end",
        padding: "60px 20px 0"
      }
    }, /*#__PURE__*/React.createElement(Button, {
      variant: "bordered",
      size: "small",
      onClick: onDone
    }, "Skip")), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 26,
        padding: "0 30px",
        textAlign: "center"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        width: 116,
        height: 116,
        borderRadius: "var(--radius-3xl)",
        background: "var(--accent-soft)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        boxShadow: "0 0 40px var(--accent-glow)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: p.icon,
      size: 52,
      color: "var(--accent)",
      strokeWidth: 2
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: 12
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: 30,
        fontWeight: "var(--weight-bold)",
        letterSpacing: "var(--tracking-tight)",
        lineHeight: 1.1
      }
    }, p.title), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-callout)",
        color: "var(--text-secondary)",
        lineHeight: 1.5
      }
    }, p.body)), /*#__PURE__*/React.createElement("div", {
      style: {
        width: "100%",
        maxWidth: 320
      }
    }, /*#__PURE__*/React.createElement(ThemePreviewCard, {
      theme: "homemux-dark",
      showTitle: false
    }))), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        justifyContent: "center",
        gap: 7,
        paddingBottom: 22
      }
    }, PAGES.map((_, i) => /*#__PURE__*/React.createElement("span", {
      key: i,
      style: {
        width: i === page ? 22 : 7,
        height: 7,
        borderRadius: 99,
        background: i === page ? "var(--accent)" : "var(--surface-3)",
        transition: "all var(--dur-base) var(--ease-snappy)"
      }
    }))), /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "0 30px 40px",
        display: "flex",
        flexDirection: "column",
        gap: 14
      }
    }, /*#__PURE__*/React.createElement(Button, {
      variant: "prominent",
      fullWidth: true,
      icon: /*#__PURE__*/React.createElement(Icon, {
        name: last ? "plus" : "arrow-right",
        size: 18,
        color: "currentColor"
      }),
      onClick: () => last ? onDone() : setPage(page + 1)
    }, last ? "Add First Host" : "Continue"), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        textAlign: "center"
      }
    }, "You can replay this introduction from Settings.")));
  }
  window.Onboarding = Onboarding;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/Onboarding.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/Paywall.jsx
try { (() => {
// Paywall — trial ended (ported from PaywallView)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    Icon,
    Button,
    AppIcon
  } = HMX;
  const FEATURES = [{
    icon: "server",
    title: "Unlimited saved hosts",
    detail: "Keep using your SSH, Mosh, and one-tap tmux connections."
  }, {
    icon: "command",
    title: "Command menu & terminal polish",
    detail: "Selection mode, special keys, tmux actions, paste, and voice draft stay available."
  }, {
    icon: "palette",
    title: "Themes & future client features",
    detail: "Built-in terminal themes and client-side upgrades are included."
  }, {
    icon: "cloud-off",
    title: "No account or subscription",
    detail: "Credentials stay local. No recurring plan, no cloud vault."
  }];
  function Paywall({
    onBack
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        inset: 0,
        zIndex: 70,
        background: "var(--bg-base)",
        color: "var(--text-primary)",
        fontFamily: "var(--font-ui)",
        overflowY: "auto"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 6,
        padding: "56px 12px 6px"
      }
    }, /*#__PURE__*/React.createElement(IconBack, {
      onBack: onBack
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: "var(--type-headline)",
        fontWeight: 600
      }
    }, "HomeMux Pro")), /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "8px 16px 32px",
        display: "flex",
        flexDirection: "column",
        gap: 18
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "24px 20px",
        borderRadius: "var(--radius-2xl)",
        background: "var(--material-regular)",
        WebkitBackdropFilter: "var(--blur-regular)",
        backdropFilter: "var(--blur-regular)",
        border: "1px solid var(--accent-line)",
        display: "flex",
        flexDirection: "column",
        gap: 16
      }
    }, /*#__PURE__*/React.createElement(AppIcon, {
      size: 64,
      radius: 16
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: 8
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-title1)",
        fontWeight: "var(--weight-bold)",
        letterSpacing: "var(--tracking-tight)"
      }
    }, "Your trial has ended"), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-callout)",
        color: "var(--text-secondary)",
        lineHeight: 1.45
      }
    }, "Buy HomeMux once to keep full access to SSH, Mosh, tmux shortcuts, themes, and the command menu."))), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        fontWeight: 600,
        letterSpacing: "0.04em",
        textTransform: "uppercase",
        color: "var(--text-tertiary)",
        padding: "0 4px 8px"
      }
    }, "Included forever"), /*#__PURE__*/React.createElement("div", {
      style: {
        background: "var(--surface-1)",
        border: "1px solid var(--hairline)",
        borderRadius: "var(--radius-md)",
        overflow: "hidden"
      }
    }, FEATURES.map((f, i) => /*#__PURE__*/React.createElement("div", {
      key: f.title,
      style: {
        display: "flex",
        gap: 12,
        padding: "13px 14px",
        borderTop: i ? "1px solid var(--separator)" : "none"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: f.icon,
      size: 19,
      color: "var(--accent)"
    }), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-subheadline)",
        fontWeight: 600
      }
    }, f.title), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-secondary)",
        lineHeight: 1.4
      }
    }, f.detail)))))), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexDirection: "column",
        gap: 11
      }
    }, /*#__PURE__*/React.createElement(Button, {
      variant: "prominent",
      fullWidth: true
    }, "Buy Lifetime Unlock \xB7 $49"), /*#__PURE__*/React.createElement(Button, {
      variant: "bordered",
      fullWidth: true
    }, "Restore Purchase"), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        lineHeight: 1.45,
        padding: "4px 4px 0"
      }
    }, "A one-time, non-consumable purchase handled by Apple. No subscription, no account, no cloud vault."))));
  }
  function IconBack({
    onBack
  }) {
    return /*#__PURE__*/React.createElement("button", {
      onClick: onBack,
      "aria-label": "Back",
      style: {
        width: 32,
        height: 32,
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        background: "transparent",
        border: "none",
        cursor: "pointer",
        color: "var(--accent)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "chevron-left",
      size: 22,
      color: "currentColor"
    }));
  }
  window.Paywall = Paywall;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/Paywall.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/Prompts.jsx
try { (() => {
// Prompts — iOS alert dialog (host-key trust) + password sheet
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    Icon
  } = HMX;

  // Centered iOS-style alert.
  function AlertDialog({
    children
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        inset: 0,
        zIndex: 95,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 28,
        background: "rgba(0,0,0,0.5)"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        width: "100%",
        maxWidth: 290,
        borderRadius: "var(--radius-xl)",
        overflow: "hidden",
        background: "var(--material-regular)",
        WebkitBackdropFilter: "var(--blur-regular)",
        backdropFilter: "var(--blur-regular)",
        border: "1px solid var(--hairline-strong)",
        boxShadow: "var(--shadow-card)",
        fontFamily: "var(--font-ui)",
        color: "var(--text-primary)"
      }
    }, children));
  }
  function AlertButtons({
    buttons
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        borderTop: "1px solid var(--hairline)"
      }
    }, buttons.map((b, i) => /*#__PURE__*/React.createElement("button", {
      key: b.label,
      onClick: b.onClick,
      style: {
        flex: 1,
        padding: "13px 8px",
        border: "none",
        borderLeft: i ? "1px solid var(--hairline)" : "none",
        background: "transparent",
        cursor: "pointer",
        fontFamily: "var(--font-ui)",
        fontSize: "var(--type-callout)",
        fontWeight: b.bold ? "var(--weight-bold)" : "var(--weight-regular)",
        color: b.destructive ? "var(--danger)" : "var(--accent)"
      }
    }, b.label)));
  }
  function HostKeyPrompt({
    onTrust,
    onCancel
  }) {
    return /*#__PURE__*/React.createElement(AlertDialog, null, /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "20px 18px 16px",
        textAlign: "center",
        display: "flex",
        flexDirection: "column",
        gap: 9
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        alignSelf: "center",
        width: 42,
        height: 42,
        borderRadius: "50%",
        background: "var(--warning-soft)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        marginBottom: 2
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "shield-alert",
      size: 22,
      color: "var(--warning)"
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-headline)",
        fontWeight: 600
      }
    }, "Trust this host key?"), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-secondary)",
        lineHeight: 1.45
      }
    }, "mac-mini.local:22 presented ", /*#__PURE__*/React.createElement("b", {
      style: {
        color: "var(--text-primary)"
      }
    }, "ssh-ed25519"), ". Accept only if this matches your server."), /*#__PURE__*/React.createElement("div", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: 11,
        color: "var(--text-secondary)",
        background: "var(--bg-abyss)",
        border: "1px solid var(--hairline)",
        borderRadius: 10,
        padding: "9px 10px",
        wordBreak: "break-all",
        lineHeight: 1.5
      }
    }, "SHA256:Hb9k2P+rQ0xLZ7v8mWp3cF1uYt6Ns4Aa0Dd5Ee2Bb")), /*#__PURE__*/React.createElement(AlertButtons, {
      buttons: [{
        label: "Cancel",
        onClick: onCancel
      }, {
        label: "Trust",
        bold: true,
        onClick: onTrust
      }]
    }));
  }
  function PasswordPrompt({
    host,
    onConnect,
    onCancel
  }) {
    const Sheet = window.HMXSheet;
    const {
      Button
    } = HMX;
    return /*#__PURE__*/React.createElement(Sheet, {
      title: "Enter Password",
      onClose: onCancel,
      maxHeight: "auto"
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "0 16px 16px",
        display: "flex",
        flexDirection: "column",
        gap: 8
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        fontWeight: 600,
        letterSpacing: "0.04em",
        textTransform: "uppercase",
        color: "var(--text-tertiary)",
        padding: "0 4px 2px"
      }
    }, "SSH Password"), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        background: "var(--surface-2)",
        border: "1px solid var(--accent-line)",
        borderRadius: "var(--radius-sm)",
        padding: "0 12px"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "lock",
      size: 16,
      color: "var(--text-tertiary)"
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        padding: "12px 0",
        fontFamily: "var(--font-mono)",
        letterSpacing: 3,
        color: "var(--text-primary)"
      }
    }, "\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022")), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        padding: "2px 4px 6px"
      }
    }, host ? `${host.endpoint}:${host.port}` : "root@example.com:22", " \xB7 stored only in the iOS Keychain."), /*#__PURE__*/React.createElement(Button, {
      variant: "prominent",
      fullWidth: true,
      onClick: onConnect
    }, "Connect")));
  }
  window.HostKeyPrompt = HostKeyPrompt;
  window.PasswordPrompt = PasswordPrompt;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/Prompts.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/Settings.jsx
try { (() => {
// Settings — sheet (ported from SettingsView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    ThemePreviewCard,
    PaletteDots,
    Icon,
    Badge
  } = HMX;
  const Sheet = window.HMXSheet;
  const THEMES = [{
    id: "homemux-dark",
    name: "HomeMux Dark",
    appearance: "Dark"
  }, {
    id: "ember-console",
    name: "Ember Console",
    appearance: "Dark"
  }, {
    id: "coastline-light",
    name: "Coastline Light",
    appearance: "Light"
  }, {
    id: "pine-mist",
    name: "Pine Mist",
    appearance: "Light"
  }];
  function Row({
    icon,
    title,
    detail,
    last
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        gap: 12,
        padding: "12px 14px",
        borderTop: last ? "1px solid var(--separator)" : "none"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: icon,
      size: 19,
      color: "var(--accent)"
    }), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-subheadline)",
        fontWeight: 600
      }
    }, title), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-secondary)",
        lineHeight: 1.4
      }
    }, detail)));
  }
  function Group({
    label,
    footer,
    children
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        marginTop: 16
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        fontWeight: 600,
        letterSpacing: "0.04em",
        textTransform: "uppercase",
        color: "var(--text-tertiary)",
        padding: "0 4px 8px"
      }
    }, label), /*#__PURE__*/React.createElement("div", {
      style: {
        background: "var(--surface-1)",
        border: "1px solid var(--hairline)",
        borderRadius: "var(--radius-md)",
        overflow: "hidden"
      }
    }, children), footer ? /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        padding: "8px 4px 0",
        lineHeight: 1.4
      }
    }, footer) : null);
  }
  function Settings({
    onClose
  }) {
    const [sel, setSel] = React.useState("homemux-dark");
    return /*#__PURE__*/React.createElement(Sheet, {
      title: "Settings",
      onClose: onClose
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        overflowY: "auto",
        padding: "0 16px 12px"
      }
    }, /*#__PURE__*/React.createElement(Group, {
      label: "Access"
    }, /*#__PURE__*/React.createElement(Row, {
      icon: "clock",
      title: "Full-access trial",
      detail: "12 days left. The trial includes the complete unrestricted app."
    })), /*#__PURE__*/React.createElement(Group, {
      label: "Terminal Theme",
      footer: "Built-in palettes are original to HomeMux. Named third-party schemes are deferred until a license review."
    }, THEMES.map((t, i) => /*#__PURE__*/React.createElement("div", {
      key: t.id,
      onClick: () => setSel(t.id),
      style: {
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "11px 14px",
        cursor: "pointer",
        borderTop: i ? "1px solid var(--separator)" : "none"
      }
    }, /*#__PURE__*/React.createElement(PaletteDots, {
      theme: t.id,
      ring: "var(--surface-1)"
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-callout)"
      }
    }, t.name), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-caption)",
        color: "var(--text-secondary)"
      }
    }, t.appearance)), sel === t.id ? /*#__PURE__*/React.createElement(Icon, {
      name: "circle-check",
      size: 20,
      color: "var(--accent)"
    }) : null)), /*#__PURE__*/React.createElement("div", {
      style: {
        padding: 14,
        borderTop: "1px solid var(--separator)"
      }
    }, /*#__PURE__*/React.createElement(ThemePreviewCard, {
      theme: sel
    }))), /*#__PURE__*/React.createElement(Group, {
      label: "Privacy"
    }, /*#__PURE__*/React.createElement(Row, {
      icon: "key-round",
      title: "Keys stay in Keychain",
      detail: "Passwords, keys, and passphrases are stored locally."
    }), /*#__PURE__*/React.createElement(Row, {
      icon: "mic",
      title: "Voice stays on device",
      detail: "Dictation creates a draft first and never sends automatically.",
      last: true
    }), /*#__PURE__*/React.createElement(Row, {
      icon: "cloud-off",
      title: "No account or cloud vault",
      detail: "HomeMux connects directly to hosts you save on this device.",
      last: true
    })), /*#__PURE__*/React.createElement(Group, {
      label: "Help"
    }, /*#__PURE__*/React.createElement(Row, {
      icon: "circle-help",
      title: "Replay Onboarding",
      detail: "See the three-screen introduction again."
    }))));
  }
  window.Settings = Settings;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/Settings.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/Terminal.jsx
try { (() => {
// Terminal — the live session + its states (ported from TerminalSessionView.swift)
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    IconButton,
    Badge,
    StatusDot,
    KeyCap,
    Icon,
    Button,
    Banner
  } = HMX;
  function TerminalBody({
    state
  }) {
    if (state === "connecting") {
      return /*#__PURE__*/React.createElement("div", {
        style: {
          fontFamily: "var(--font-mono)",
          fontSize: 13.5,
          lineHeight: 1.62,
          padding: "16px"
        }
      }, /*#__PURE__*/React.createElement("div", {
        style: {
          color: "var(--t-8)"
        }
      }, "Resolving mac-mini.local\u2026"), /*#__PURE__*/React.createElement("div", {
        style: {
          color: "var(--t-8)"
        }
      }, "Probing transport \xB7 mosh-server"), /*#__PURE__*/React.createElement("div", {
        style: {
          color: "var(--t-11)"
        }
      }, "Establishing secure channel\u2026"));
    }
    return /*#__PURE__*/React.createElement("div", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: 13.5,
        lineHeight: 1.62,
        padding: "16px 16px 6px",
        whiteSpace: "pre-wrap",
        wordBreak: "break-word",
        opacity: state === "failed" ? 0.4 : 1
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        color: "var(--t-8)"
      }
    }, "Last login: Tue Jun 17 09:14 on ttys004"), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-10)"
      }
    }, "alex@mac-mini"), " ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-4)"
      }
    }, "~/code/app")), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-2)"
      }
    }, "\u276F"), " ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-fg)"
      }
    }, "tmux attach -t claude")), /*#__PURE__*/React.createElement("div", {
      style: {
        color: "var(--t-8)",
        marginTop: 4
      }
    }, "[claude] resuming session \xB7 3 windows"), /*#__PURE__*/React.createElement("div", {
      style: {
        color: "var(--t-fg)"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-2)"
      }
    }, "\u25CF"), " Edited ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-4)"
      }
    }, "src/api/server.ts"), " ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-2)"
      }
    }, "+42"), " ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-1)"
      }
    }, "-8")), /*#__PURE__*/React.createElement("div", {
      style: {
        color: "var(--t-fg)"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-2)"
      }
    }, "\u2713"), " 128 tests passed ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-8)"
      }
    }, "(2.4s)")), /*#__PURE__*/React.createElement("div", {
      style: {
        marginTop: 4
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-2)"
      }
    }, "\u276F"), " ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-fg)"
      }
    }, "npm run build")), /*#__PURE__*/React.createElement("div", {
      style: {
        color: "var(--t-8)"
      }
    }, "  vite v5.2 building for production\u2026"), /*#__PURE__*/React.createElement("div", {
      style: {
        color: "var(--t-11)"
      }
    }, "  transforming modules  ", /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-2)"
      }
    }, "\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588"), /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-8)"
      }
    }, "\u2591\u2591"), "  86%"), state === "connected" && /*#__PURE__*/React.createElement("div", {
      style: {
        marginTop: 2
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        color: "var(--t-2)"
      }
    }, "\u276F"), " ", /*#__PURE__*/React.createElement("span", {
      style: {
        display: "inline-block",
        width: 8.5,
        height: 17,
        background: "var(--t-caret)",
        verticalAlign: "-3px",
        borderRadius: 1,
        animation: "hmx-caret 1.1s steps(2) infinite"
      }
    })), /*#__PURE__*/React.createElement("style", null, "@keyframes hmx-caret{50%{opacity:0}}"));
  }

  // Explicit text-selection mode overlay.
  function SelectionOverlay({
    onExit
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        inset: 0,
        zIndex: 5
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        inset: 0,
        background: "rgba(0,0,0,0.18)"
      }
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        top: 92,
        left: 28,
        width: 232,
        height: 22,
        background: "color-mix(in srgb, var(--accent) 32%, transparent)",
        borderRadius: 3
      }
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        top: 114,
        left: 16,
        width: 150,
        height: 22,
        background: "color-mix(in srgb, var(--accent) 32%, transparent)",
        borderRadius: 3
      }
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        position: "absolute",
        top: 12,
        left: 12,
        right: 12,
        display: "flex",
        alignItems: "center",
        gap: 8,
        padding: "9px 13px",
        borderRadius: "var(--radius-pill)",
        background: "var(--material-regular)",
        WebkitBackdropFilter: "var(--blur-regular)",
        backdropFilter: "var(--blur-regular)",
        border: "1px solid var(--accent-line)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "text-cursor-input",
      size: 15,
      color: "var(--accent)"
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: "var(--type-footnote)",
        fontWeight: 600
      }
    }, "Selection Mode"), /*#__PURE__*/React.createElement("span", {
      style: {
        fontSize: "var(--type-caption)",
        color: "var(--text-secondary)",
        marginLeft: "auto"
      }
    }, "Drag to select terminal text")));
  }
  function SelectionBar({
    onExit
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        gap: 8,
        overflowX: "auto",
        padding: "10px 12px 30px",
        background: "var(--material-bar)",
        WebkitBackdropFilter: "var(--blur-thin)",
        backdropFilter: "var(--blur-thin)",
        borderTop: "1px solid var(--accent-line)"
      }
    }, /*#__PURE__*/React.createElement(Button, {
      size: "small",
      variant: "bordered",
      onClick: onExit
    }, "Copy"), /*#__PURE__*/React.createElement(Button, {
      size: "small",
      variant: "prominent",
      onClick: onExit
    }, "Copy & Exit"), /*#__PURE__*/React.createElement(Button, {
      size: "small",
      variant: "bordered"
    }, "Select Visible"), /*#__PURE__*/React.createElement(Button, {
      size: "small",
      variant: "plain",
      onClick: onExit
    }, "Cancel"));
  }
  function Terminal({
    host,
    onBack,
    onCommandMenu,
    state = "connected",
    fallback = false,
    selecting = false,
    onExitSelect,
    onReconnect
  }) {
    const themeClass = "term-" + host.theme;
    const statusText = state === "failed" ? "Connection failed" : state === "connecting" ? "Connecting…" : "Connected";
    return /*#__PURE__*/React.createElement("div", {
      className: themeClass,
      style: {
        position: "absolute",
        inset: 0,
        display: "flex",
        flexDirection: "column",
        background: "var(--t-bg)",
        color: "var(--text-primary)",
        fontFamily: "var(--font-ui)"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        paddingTop: 54,
        background: "var(--material-bar)",
        WebkitBackdropFilter: "var(--blur-regular)",
        backdropFilter: "var(--blur-regular)",
        borderBottom: "1px solid " + (state === "failed" ? "var(--danger-soft)" : "var(--accent-line)")
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 10,
        padding: "8px 12px"
      }
    }, /*#__PURE__*/React.createElement(IconButton, {
      name: "chevron-left",
      label: "Back",
      variant: "plain",
      tint: "var(--accent)",
      size: 32,
      onClick: onBack
    }), /*#__PURE__*/React.createElement(StatusDot, {
      state: state
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        minWidth: 0,
        flex: 1
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-caption)",
        fontWeight: 600,
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis"
      }
    }, statusText), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-caption2)",
        color: "var(--text-secondary)",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis"
      }
    }, host.endpoint, ":", host.port)), state === "connected" && /*#__PURE__*/React.createElement(Badge, {
      tint: "var(--status-connected)"
    }, fallback ? "SSH" : host.activeTransport), /*#__PURE__*/React.createElement(IconButton, {
      name: "ellipsis",
      label: "Session actions",
      variant: "plain",
      tint: "var(--text-secondary)",
      size: 32
    }))), state === "failed" && /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "10px 12px 2px"
      }
    }, /*#__PURE__*/React.createElement(Banner, {
      tone: "danger",
      title: "Could not connect",
      message: "Mosh appears installed, but UDP could not reach this host. Falling back is available.",
      action: /*#__PURE__*/React.createElement(Button, {
        size: "small",
        onClick: onReconnect
      }, "Reconnect")
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        overflow: "auto",
        position: "relative"
      }
    }, /*#__PURE__*/React.createElement(TerminalBody, {
      state: state
    }), selecting && /*#__PURE__*/React.createElement(SelectionOverlay, {
      onExit: onExitSelect
    }), fallback && state === "connected" && !selecting && /*#__PURE__*/React.createElement("div", {
      style: {
        position: "sticky",
        top: 12,
        display: "flex",
        justifyContent: "center",
        pointerEvents: "none"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 7,
        padding: "8px 13px",
        borderRadius: "var(--radius-pill)",
        background: "var(--material-regular)",
        WebkitBackdropFilter: "var(--blur-regular)",
        backdropFilter: "var(--blur-regular)",
        border: "1px solid var(--hairline)",
        fontSize: "var(--type-caption)",
        color: "var(--text-secondary)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "info",
      size: 13,
      color: "var(--status-info)"
    }), "Connected with SSH \xB7 Mosh isn\u2019t installed on this machine.")), !selecting && state === "connected" && /*#__PURE__*/React.createElement("div", {
      style: {
        position: "sticky",
        bottom: 14,
        display: "flex",
        justifyContent: "flex-end",
        paddingRight: 16,
        pointerEvents: "none"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        pointerEvents: "auto"
      }
    }, /*#__PURE__*/React.createElement(IconButton, {
      name: "command",
      label: "Command menu",
      shape: "circle",
      size: 52,
      onClick: onCommandMenu,
      style: {
        boxShadow: "var(--shadow-float)"
      }
    })))), selecting ? /*#__PURE__*/React.createElement(SelectionBar, {
      onExit: onExitSelect
    }) : /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        gap: 8,
        overflowX: "auto",
        padding: "10px 10px 30px",
        background: "var(--material-bar)",
        WebkitBackdropFilter: "var(--blur-thin)",
        backdropFilter: "var(--blur-thin)",
        borderTop: "1px solid var(--hairline)"
      }
    }, /*#__PURE__*/React.createElement(KeyCap, null, /*#__PURE__*/React.createElement("span", {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 5
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "mic",
      size: 14
    }), " Mic")), /*#__PURE__*/React.createElement(KeyCap, null, "Esc"), /*#__PURE__*/React.createElement(KeyCap, null, "Tab"), /*#__PURE__*/React.createElement(KeyCap, {
      active: true
    }, "Ctrl"), /*#__PURE__*/React.createElement(KeyCap, null, "\u2190"), /*#__PURE__*/React.createElement(KeyCap, null, "\u2193"), /*#__PURE__*/React.createElement(KeyCap, null, "\u2191"), /*#__PURE__*/React.createElement(KeyCap, null, "\u2192"), /*#__PURE__*/React.createElement(KeyCap, null, "Ctrl-C"), /*#__PURE__*/React.createElement(KeyCap, null, "Ctrl-D"), /*#__PURE__*/React.createElement(KeyCap, null, "Ctrl-Z"), /*#__PURE__*/React.createElement(KeyCap, null, "Paste")));
  }
  window.Terminal = Terminal;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/Terminal.jsx", error: String((e && e.message) || e) }); }

// ui_kits/homemux-ios/screens/TmuxPicker.jsx
try { (() => {
// tmux session picker (ported from TmuxSessionPicker) — sessions / empty / not-installed
(function () {
  const HMX = window.HomeMuxDesignSystem_359607;
  const {
    Icon,
    Button
  } = HMX;
  const SESSIONS = [{
    name: "claude",
    windows: 3,
    attached: false
  }, {
    name: "codex",
    windows: 2,
    attached: false
  }, {
    name: "backend",
    windows: 5,
    attached: true
  }];
  function Unavailable({
    icon,
    title,
    body
  }) {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        padding: "34px 28px 40px",
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 12,
        textAlign: "center"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        width: 64,
        height: 64,
        borderRadius: "var(--radius-lg)",
        background: "var(--surface-2)",
        border: "1px solid var(--hairline)",
        display: "flex",
        alignItems: "center",
        justifyContent: "center"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: icon,
      size: 28,
      color: "var(--text-tertiary)"
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-headline)",
        fontWeight: 600
      }
    }, title), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-secondary)",
        lineHeight: 1.45,
        maxWidth: 280
      }
    }, body));
  }
  function TmuxPicker({
    variant = "sessions",
    onClose,
    onAttach
  }) {
    const Sheet = window.HMXSheet;
    return /*#__PURE__*/React.createElement(Sheet, {
      title: "Attach tmux",
      onClose: onClose
    }, variant === "notInstalled" && /*#__PURE__*/React.createElement(Unavailable, {
      icon: "package-x",
      title: "tmux is not installed",
      body: "Install tmux on the host, then tap Reconnect and try again."
    }), variant === "empty" && /*#__PURE__*/React.createElement(Unavailable, {
      icon: "layers",
      title: "No tmux sessions yet",
      body: "Start a tmux session on the host, or save a one-tap tmux shortcut to create its named session automatically."
    }), variant === "sessions" && /*#__PURE__*/React.createElement("div", {
      style: {
        overflowY: "auto",
        padding: "0 16px 8px"
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-footnote)",
        color: "var(--text-tertiary)",
        padding: "0 4px 8px"
      }
    }, "3 sessions detected on mac-mini.local. Tap to attach."), /*#__PURE__*/React.createElement("div", {
      style: {
        background: "var(--surface-1)",
        border: "1px solid var(--hairline)",
        borderRadius: "var(--radius-md)",
        overflow: "hidden"
      }
    }, SESSIONS.map((s, i) => /*#__PURE__*/React.createElement("div", {
      key: s.name,
      onClick: onAttach,
      style: {
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "13px 14px",
        cursor: "pointer",
        borderTop: i ? "1px solid var(--separator)" : "none"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        width: 36,
        height: 36,
        flex: "none",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        borderRadius: 9,
        background: "var(--bg-abyss)",
        border: "1px solid var(--accent-line)",
        color: "var(--accent)"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: "layers",
      size: 18
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        minWidth: 0
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        fontFamily: "var(--font-mono)",
        fontSize: "var(--type-callout)",
        display: "flex",
        alignItems: "center",
        gap: 8
      }
    }, s.name, s.attached && /*#__PURE__*/React.createElement("span", {
      style: {
        fontFamily: "var(--font-ui)",
        fontSize: "var(--type-caption2)",
        fontWeight: 600,
        color: "var(--status-connected)",
        background: "color-mix(in srgb, var(--status-connected) 14%, transparent)",
        padding: "2px 7px",
        borderRadius: 99
      }
    }, "attached")), /*#__PURE__*/React.createElement("div", {
      style: {
        fontSize: "var(--type-caption)",
        color: "var(--text-tertiary)"
      }
    }, s.windows, " windows")), /*#__PURE__*/React.createElement(Icon, {
      name: "chevron-right",
      size: 16,
      color: "var(--text-tertiary)"
    })))), /*#__PURE__*/React.createElement("div", {
      style: {
        marginTop: 14
      }
    }, /*#__PURE__*/React.createElement(Button, {
      variant: "bordered",
      fullWidth: true,
      icon: /*#__PURE__*/React.createElement(Icon, {
        name: "rotate-cw",
        size: 16,
        color: "currentColor"
      })
    }, "Refresh"))));
  }
  window.TmuxPicker = TmuxPicker;
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/homemux-ios/screens/TmuxPicker.jsx", error: String((e && e.message) || e) }); }

__ds_ns.AppIcon = __ds_scope.AppIcon;

__ds_ns.Wordmark = __ds_scope.Wordmark;

__ds_ns.Badge = __ds_scope.Badge;

__ds_ns.Button = __ds_scope.Button;

__ds_ns.Icon = __ds_scope.Icon;

__ds_ns.IconButton = __ds_scope.IconButton;

__ds_ns.KeyCap = __ds_scope.KeyCap;

__ds_ns.StatusDot = __ds_scope.StatusDot;

__ds_ns.SegmentedControl = __ds_scope.SegmentedControl;

__ds_ns.Switch = __ds_scope.Switch;

__ds_ns.TextField = __ds_scope.TextField;

__ds_ns.Banner = __ds_scope.Banner;

__ds_ns.Card = __ds_scope.Card;

__ds_ns.ListRow = __ds_scope.ListRow;

__ds_ns.IconTile = __ds_scope.IconTile;

__ds_ns.PaletteDots = __ds_scope.PaletteDots;

__ds_ns.ThemePreviewCard = __ds_scope.ThemePreviewCard;

__ds_ns.THEMES = __ds_scope.THEMES;

})();

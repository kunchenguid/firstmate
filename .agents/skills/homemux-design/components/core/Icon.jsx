import React from "react";

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
export function Icon({ name, size = 20, strokeWidth = 2, color = "currentColor", style = {}, ...rest }) {
  const ref = React.useRef(null);
  ensureStyle();
  React.useEffect(() => {
    const lucide = typeof window !== "undefined" ? window.lucide : null;
    if (lucide && ref.current) {
      ref.current.innerHTML = `<i data-lucide="${name}" stroke-width="${strokeWidth}"></i>`;
      try { lucide.createIcons({ attrs: { "stroke-width": strokeWidth }, nameAttr: "data-lucide" }); } catch (e) { /* noop */ }
    }
  }, [name, strokeWidth]);
  return (
    <span
      ref={ref}
      className="hmx-icon"
      style={{ width: size, height: size, color, ...style }}
      aria-hidden="true"
      {...rest}
    />
  );
}

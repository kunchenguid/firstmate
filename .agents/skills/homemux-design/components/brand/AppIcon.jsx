import React from "react";

let gid = 0;

/**
 * HomeMux AppIcon — the brand mark (gable roof over a terminal block cursor) on
 * the dark radial canvas. Use `bare` to render just the mint glyph on
 * transparent (for nav lockups). Size in px; radius defaults to the iOS tile.
 */
export function AppIcon({ size = 96, radius, bare = false, glow = true, style = {}, ...rest }) {
  const id = React.useMemo(() => "hmx" + ++gid, []);
  const r = radius != null ? radius : Math.round(size * 0.225);
  const mark = (stroke, fill) => (
    <g>
      <path d="M300 474 L 512 312 L 724 474" stroke={stroke} strokeWidth="74" strokeLinecap="round" strokeLinejoin="round" fill="none" />
      <rect x="414" y="548" width="72" height="168" rx="16" fill={fill} />
      <rect x="538" y="548" width="72" height="168" rx="16" fill={fill} />
    </g>
  );

  if (bare) {
    return (
      <svg width={size} height={size} viewBox="0 0 1024 1024" fill="none" style={style} aria-label="HomeMux" {...rest}>
        {mark("var(--accent)", "var(--accent)")}
      </svg>
    );
  }

  return (
    <svg width={size} height={size} viewBox="0 0 1024 1024" fill="none"
      style={{ borderRadius: r, display: "block", ...style }} aria-label="HomeMux" {...rest}>
      <defs>
        <radialGradient id={id + "bg"} cx="42%" cy="33%" r="88%">
          <stop offset="0%" stopColor="#12171F" />
          <stop offset="58%" stopColor="#0A0D12" />
          <stop offset="100%" stopColor="#06080C" />
        </radialGradient>
        <linearGradient id={id + "m"} x1="300" y1="300" x2="724" y2="724" gradientUnits="userSpaceOnUse">
          <stop offset="0%" stopColor="#8FFAC4" />
          <stop offset="100%" stopColor="#5EEAD4" />
        </linearGradient>
        {glow ? (
          <filter id={id + "g"} x="-40%" y="-40%" width="180%" height="180%">
            <feGaussianBlur stdDeviation="16" result="b" />
            <feMerge><feMergeNode in="b" /><feMergeNode in="SourceGraphic" /></feMerge>
          </filter>
        ) : null}
      </defs>
      <rect width="1024" height="1024" rx={r * (1024 / size)} fill={`url(#${id}bg)`} />
      <g filter={glow ? `url(#${id}g)` : undefined}>
        {mark(`url(#${id}m)`, `url(#${id}m)`)}
      </g>
    </svg>
  );
}

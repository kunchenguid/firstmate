---
name: Firstmate
description: A harbour noticeboard for a working fleet - warm chart paper, enamel sign-pins, and ink-offset cards.
colors:
  rust-600: "#a93a1f"
  rust-500: "#c0452a"
  rust-400: "#d35f3f"
  rust-050: "#fbece3"
  navy-700: "#1a2238"
  gold-600: "#b5791c"
  gold-500: "#e0a52e"
  gold-300: "#f0d38c"
  gold-100: "#f8ecc9"
  ocean-600: "#2f6688"
  ocean-500: "#3c7ea6"
  ocean-050: "#e8f1f5"
  sea-700: "#234e3a"
  sea-500: "#2f6b4f"
  sea-200: "#b9d4c5"
  sea-050: "#e9f2ec"
  paper-000: "#fbf4e2"
  paper-100: "#f6ecd3"
  paper-300: "#e7d6ae"
  cream-line: "#ddc89c"
  ink-900: "#241c14"
  ink-700: "#3f3224"
  ink-500: "#6f5e46"
  ink-300: "#9c8a6c"
  white: "#fffdf7"
typography:
  display:
    fontFamily: "Chango, Cooper Black, Rockwell, Georgia, serif"
    fontSize: "23px"
    fontWeight: 400
    lineHeight: 1
    letterSpacing: "normal"
  headline:
    fontFamily: "JetBrains Mono, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "1.4rem"
    fontWeight: 600
    lineHeight: 1
  title:
    fontFamily: "Jost, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
    fontSize: "1.15rem"
    fontWeight: 800
    lineHeight: 1.25
  body:
    fontFamily: "Jost, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.55
  body-compact:
    fontFamily: "Jost, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
    fontSize: "0.9375rem"
    fontWeight: 400
    lineHeight: 1.45
  sign:
    fontFamily: "Jost, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
    fontSize: "0.8125rem"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "0.16em"
  label:
    fontFamily: "Jost, ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif"
    fontSize: "0.6875rem"
    fontWeight: 800
    lineHeight: 1
    letterSpacing: "0.07em"
  meta:
    fontFamily: "JetBrains Mono, ui-monospace, SF Mono, Menlo, Consolas, monospace"
    fontSize: "0.8125rem"
    fontWeight: 400
    lineHeight: 1.3
rounded:
  xs: "6px"
  banner: "7px"
  sm: "9px"
  md: "12px"
  lg: "18px"
  pill: "999px"
spacing:
  2xs: "4px"
  xs: "6px"
  sm: "8px"
  md: "12px"
  lg: "18px"
  xl: "22px"
  2xl: "28px"
components:
  button-primary:
    backgroundColor: "{colors.rust-500}"
    textColor: "{colors.white}"
    typography: "{typography.label}"
    rounded: "{rounded.banner}"
    padding: "8px 16px"
  button-primary-hover:
    backgroundColor: "{colors.rust-600}"
    textColor: "{colors.white}"
  button-gold:
    backgroundColor: "{colors.gold-500}"
    textColor: "{colors.navy-700}"
    typography: "{typography.label}"
    rounded: "{rounded.banner}"
    padding: "8px 16px"
  button-gold-hover:
    backgroundColor: "{colors.gold-600}"
    textColor: "{colors.white}"
  badge-online:
    backgroundColor: "{colors.sea-500}"
    textColor: "{colors.paper-000}"
    typography: "{typography.label}"
    rounded: "{rounded.xs}"
    padding: "5px 9px 4px"
  badge-warn:
    backgroundColor: "{colors.gold-500}"
    textColor: "{colors.navy-700}"
    typography: "{typography.label}"
    rounded: "{rounded.xs}"
    padding: "5px 9px 4px"
  badge-danger:
    backgroundColor: "{colors.rust-600}"
    textColor: "{colors.paper-000}"
    typography: "{typography.label}"
    rounded: "{rounded.xs}"
    padding: "5px 9px 4px"
  badge-info:
    backgroundColor: "{colors.ocean-500}"
    textColor: "{colors.paper-000}"
    typography: "{typography.label}"
    rounded: "{rounded.xs}"
    padding: "5px 9px 4px"
  badge-neutral:
    backgroundColor: "{colors.paper-000}"
    textColor: "{colors.ink-900}"
    typography: "{typography.label}"
    rounded: "{rounded.xs}"
    padding: "5px 9px 4px"
  card:
    backgroundColor: "{colors.white}"
    textColor: "{colors.ink-700}"
    rounded: "{rounded.lg}"
  card-warm:
    backgroundColor: "{colors.paper-000}"
    textColor: "{colors.ink-700}"
    rounded: "{rounded.lg}"
  card-poster:
    backgroundColor: "{colors.white}"
    textColor: "{colors.ink-700}"
    rounded: "{rounded.md}"
  stat:
    backgroundColor: "{colors.paper-000}"
    textColor: "{colors.ink-900}"
    rounded: "{rounded.md}"
    padding: "14px 16px"
  stat-call:
    backgroundColor: "{colors.rust-050}"
    textColor: "{colors.rust-600}"
    rounded: "{rounded.md}"
    padding: "14px 16px"
  option:
    backgroundColor: "{colors.paper-000}"
    textColor: "{colors.ink-900}"
    typography: "{typography.body-compact}"
    rounded: "{rounded.sm}"
    padding: "9px 12px"
  option-selected:
    backgroundColor: "{colors.rust-050}"
    textColor: "{colors.ink-900}"
    typography: "{typography.body-compact}"
    rounded: "{rounded.sm}"
    padding: "9px 12px"
  input-freeform:
    backgroundColor: "{colors.white}"
    textColor: "{colors.ink-900}"
    typography: "{typography.body-compact}"
    rounded: "{rounded.sm}"
    padding: "8px 11px"
  icon-button:
    backgroundColor: "{colors.white}"
    textColor: "{colors.ink-900}"
    rounded: "{rounded.sm}"
    height: "34px"
    width: "34px"
  chip-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.ink-500}"
    typography: "{typography.sign}"
    rounded: "{rounded.pill}"
    padding: "5px 12px"
  row:
    backgroundColor: "transparent"
    textColor: "{colors.ink-700}"
    padding: "11px 18px"
---

# Design System: Firstmate

## Overview

**Creative North Star: "The Harbour Noticeboard"**

Firstmate's interface is a board on a harbour wall, not a window into a database.
The page is warm chart paper with a faint fractal grain sitting over it.
Everything of consequence is a physical thing fixed to that paper: an enamel sign-pin, a stencilled section sign, a card dealt onto a squared-up pile.
Depth is drawn rather than lit, a solid ink block offset a few pixels behind the object, the way a thick painted sign throws an edge.
Nothing floats and nothing glows.

The density is working-dense, not marketing-airy.
One captain scans a whole fleet in a single viewport, so the system spends its space on legibility and its personality on edges: 2px ink borders, hard offsets, uppercase tracked labels, and a monospace voice for every id, count, timestamp and URL.
Colour is reserved for meaning.
Hull Rust is the only voice that says "you, now", while Sea Green, Brass Gold, and Harbour Ocean carry landed, waiting, and reference.
The large warm neutral field is what makes those four legible at a glance.

The display face, Chango, a fat rounded poster serif, appears exactly once, as the wordmark.
It sets the register for everything else without being asked to do any other work.
Jost carries the interface and JetBrains Mono carries the record.
This system is derived from the shipped implementation in [`.agents/skills/bearings/assets/board-template.html`](.agents/skills/bearings/assets/board-template.html), which remains the authoritative source for every token value below.
The anti-reference is the generic SaaS dashboard: cool grey-blue on white, translucent floating panels, soft diffuse elevation, and a rounded-everything shape language.
This system is warm, edged, and printed.

**Key Characteristics:**

- Warm chart-paper ground (`#f6ecd3`) with a 4.5%-opacity fractal-noise grain, never plain white
- Two distinct shadow languages: soft ambient for resting surfaces, hard ink offset for authority
- A single display face used once, as the wordmark only
- Monospace as the system's record voice, for every id, count, timestamp and link
- Four semantic accents on a large neutral field, with rust rationed
- One breakpoint (900px) and one container width (1180px)
- All state transitions 120ms, and `:active` presses 1px down

## Colors

A warm maritime palette: four saturated accents earning their place against a broad field of aged paper and brown-black ink.
There is no cool grey anywhere in the system, because even the neutrals are warm (`--ink-900` is a brown-black, not `#000`).

### Primary

- **Hull Rust** (`#c0452a`): the system's single voice of demand.
  It fills the brand disc, primary buttons, selected radio accents, the alert stat tile's border, and the stencilled section eyebrows.
  Its darker step **Hull Rust Deep** (`#a93a1f`) is the primary hover and the danger pin fill.
  **Rust Wash** (`#fbece3`) is the tint behind an active decision or an alert metric, and **Rust Light** (`#d35f3f`) appears only as the focused-input border.

### Secondary

- **Brass Gold** (`#e0a52e`): the colour of action offered rather than demanded, used on the dispatch button, the warn pin, and the "recommended" option tag.
  **Brass Deep** (`#b5791c`) is its hover and that tag's border.
  **Brass Pale** (`#f0d38c`) is the focus ring for the entire system, and **Brass Wash** (`#f8ecc9`) the warn tint.

### Tertiary

- **Harbour Ocean** (`#3c7ea6`): the reference colour.
  **Ocean Deep** (`#2f6688`) carries every link, PR reference, and external URL, and **Ocean Wash** (`#e8f1f5`) the info tint.
  Ocean never carries an action, only a pointer to something elsewhere.
- **Sea Green** (`#2f6b4f`): the colour of settled, landed, good.
  It fills the online pin and the landed row checkmark.
  **Sea Deep** (`#234e3a`) is the queued-confirmation text, **Sea Mist** (`#b9d4c5`) its border, and **Sea Wash** (`#e9f2ec`) its tint.

### Neutral

- **Chart Paper** (`#f6ecd3`): the page ground and the sticky nav's tinted backdrop.
  This is the system's true background.
- **Board Paper** (`#fbf4e2`): the warm card surface and the resting fill for stat tiles, option rows, and warm cards.
  One step warmer than the page, used to sit *on* the board.
- **Signal White** (`#fffdf7`): the standard card surface, an off-white with a paper cast, never `#ffffff`.
- **Chart Edge** (`#e7d6ae`): the soft divider between compact rows.
- **Cream Line** (`#ddc89c`): the default border on cards, inputs, and icon buttons.
- **Log Ink** (`#241c14`): the strong-text colour and, more importantly, the *only* colour used for hard shadows and emphatic borders.
  It is the most-referenced token in the system.
- **Ink Body** (`#3f3224`): default body text.
- **Ink Muted** (`#6f5e46`): secondary and supporting text, labels.
- **Ink Faint** (`#9c8a6c`): metadata, ids, timestamps, and the dashed "more" chip border.

### The semantic layer

Components never reach for a ramp step directly.
They consume a semantic alias that resolves to one: `--bg-page`, `--surface-card`, `--surface-card-warm`, `--text-strong` / `--text-body` / `--text-muted` / `--text-faint`, `--border-default` / `--border-soft`, and the four status pairs `--status-online|warn|danger|info`, each with a `-soft` tint.
Add a new alias rather than a new ramp step when a new role appears.

### Named Rules

**The One Voice Rule.** Hull Rust means "the captain must act."
It is not a brand wash.
If rust appears on more than one demand per region of the board, it has stopped meaning anything.

**The Warm Neutral Rule.** There is no `#000`, no `#fff`, and no cool grey in this system.
Text is brown-black, white is `#fffdf7`, and every surface carries a paper cast.
A cool neutral entering the palette breaks the world.

**The Reference-Not-Action Rule.** Ocean is a pointer, never a button.
Anything the captain can *do* is rust or gold, and anything that takes them *elsewhere* is ocean.

## Typography

**Display Font:** Chango (with Cooper Black, Rockwell, Georgia, serif)
**Body Font:** Jost (with `ui-sans-serif`, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif)
**Label/Mono Font:** JetBrains Mono (with `ui-monospace`, SF Mono, Menlo, Consolas, monospace)

**Character:** A fat rounded poster serif sets the sign-painted register, a geometric sans does the reading, and a technical mono does the record-keeping.
The pairing works because each face has exactly one job and never borrows another's.
Jost is run heavy (700-800) for anything structural, which is what keeps a geometric sans from reading as generic.

### Hierarchy

- **Display** (400, 23px, line-height 1): Chango, used for the wordmark and nothing else.
  Chango ships a single weight and is never set below about 20px or in more than two words.
- **Headline** (mono 600, 1.4rem / `--fs-h3`, line-height 1): the metric numeral in a stat tile.
  Numbers are mono so a column of counts aligns and a changing count does not reflow its label.
- **Title** (800, 1.15rem / `--fs-h4`, line-height 1.25): the decision card heading, the heaviest reading type in the system.
- **Body** (400, 1rem, line-height 1.55): the document default set on `body`.
- **Body Compact** (400, 0.9375rem / `--fs-sm`, line-height 1.45): the working size for card detail, row titles (at 700), option labels, and inputs.
  Most of the interface is set here, not at 1rem.
- **Sign** (800, 0.8125rem / `--fs-xs`, uppercase, letter-spacing 0.16em): the stencilled section eyebrow.
  This is the widest tracking in the system, and the reason a section label reads as painted signage rather than a heading.
- **Label** (800, 0.6875rem / `--fs-2xs`, uppercase, letter-spacing 0.07em): pin text, stat labels, context keys, dispatch counts.
  Tighter tracking than Sign because it sits inside an enamel pin, not on open paper.
- **Meta** (mono 400, 0.8125rem / `--fs-xs`): ids, timestamps, PR references, provenance, stack counts, and links.
  Ocean Deep when it is a link, Ink Faint when it is a record.

### Named Rules

**The Display-Once Rule.** Chango appears exactly once per page, as the wordmark.
Any second use of the display face, whether a section heading, a hero number, or a callout, devalues it and costs the whole board its register.

**The Record-Is-Mono Rule.** If a string is a machine fact such as an id, a count, a timestamp, a URL, or a PR number, it is set in JetBrains Mono.
If it is something a human wrote, it is Jost.
The captain should be able to tell the two apart without reading them.

**The Heavy-Structure Rule.** Structural sans type is 700 or 800.
There is no 500 or 600 Jost in the system, and a label that needs de-emphasis changes colour (`--text-muted`, `--text-faint`), not weight.

## Layout

A single centred column, `--container-app` at **1180px**, with **28px** horizontal gutters that hold from the sticky nav through the main region to the footer.
The nav is 64px tall, sticky at `top: 0` (`z-index: 20`), and tints its backdrop with `color-mix(in srgb, var(--paper-100) 86%, transparent)` plus `saturate(150%) blur(10px)` so the paper ground reads through it rather than being covered by a panel.

The main region is a vertical flex column with a **22px** section gap and `26px 28px 72px` padding, where the generous bottom padding keeps the last card off the viewport edge.
Inside it, content is organised as full-width **two-column grids** (`minmax(0, 1fr)` twice, 22px gap).
The `minmax(0, ...)` is load-bearing, because every column contains ellipsised single-line text that would otherwise blow the track out.
The stat strip above them is `repeat(auto-fit, minmax(150px, 1fr))` at a 12px gap, so tiles reflow without a media query.

**Spacing rhythm.** The project declares no `--spacing-*` custom properties, so the rhythm is expressed in literal values and is consistent: **4px** (label-to-value), **6-8px** (icon gap, inline gap), **12px** (the default gap, used for section internals, card pads, and the stat strip), **18px** (compact row inset, card pad), **22px** (section and column gap), and **28px** (container gutter).
Compact rows are `11px 18px` with a 1px `--border-soft` top rule and no rule on the first child.

**Responsive.** There is one breakpoint, **900px**, where every two-column grid collapses to a single column.
Nothing else changes: no type scale shift, no gutter change, no nav restructure.
The stat strip and the 78px / 1fr context grid handle their own narrowing intrinsically.

### Named Rules

**The One Breakpoint Rule.** This board has a single media query at 900px, and it does one thing: two columns become one.
Intrinsic sizing (`auto-fit`, `minmax(0,1fr)`, `fit-content`) handles everything else.
Reach for `minmax` before reaching for a second breakpoint.

**The Shared Baseline Rule.** Within a row of cards, one element owns the rhythm and the rest follow it.
The decision card's form is a flex column at the same 12px gap as its pad, and its footer rides `margin-top: auto`, so every answer button across the row lands on the same baseline with identical breathing room.

## Elevation & Depth

The system runs **two shadow languages with strictly separated jobs**, plus a paper grain that gives the whole page a physical ground.

Soft ambient shadow is atmosphere, and says "this is a surface".
Hard ink offset is authority, and says "this is an object pinned to the board, and it matters".
They are never combined on one element, and the choice between them is semantic, not decorative.

The page itself carries `--texture-paper`, an inline SVG `feTurbulence` fractal noise (baseFrequency 0.85, 2 octaves, desaturated) at **0.045 opacity**, tiled at 160px over `--bg-page`.
It is what stops the warm neutral from reading as a flat fill.

### Shadow Vocabulary

- **Soft ambient** (`box-shadow: 0 1px 2px rgba(36, 28, 20, 0.06), 0 4px 10px rgba(36, 28, 20, 0.06)`): ordinary cards and resting containers.
  Note the shadow colour is the ink brown at 6%, not black, because a black shadow on paper reads grey and cold.
- **Hard offset** (`box-shadow: 4px 4px 0 var(--ink-900)`): poster cards.
  This is the full-weight statement, paired with a 2px ink border.
- **Hard offset, small** (`box-shadow: 3px 3px 0 var(--ink-900)`): the brand disc, primary and gold buttons, and each card in the dealt decision stack.
  This is the working weight.
- **Pin offset** (`box-shadow: 2px 2px 0 var(--ink-900)`): enamel sign-pins only, matching their smaller scale.
- **Focus ring** (`box-shadow: 0 0 0 3px var(--gold-300)`): every focusable control, replacing the UA outline.
  Brass Pale is the only focus colour in the system.
- **Selected inset** (`box-shadow: inset 0 0 0 1px var(--rust-500)`): doubles a selected option's rust border inward, thickening it without shifting layout.

### Named Rules

**The Two Shadows Rule.** Soft ambient (`0 1px 2px` plus `0 4px 10px` at 6% ink) is for ordinary resting surfaces.
Hard ink offset (`3-4px 3-4px 0 var(--ink-900)`) is for anything that claims authority: poster cards, sign-pins, primary and gold buttons, the brand disc.
Never put both on one element, and never use a hard offset without a matching ink border.

**The Ink-Shadow Rule.** Hard shadows are always `var(--ink-900)` at full opacity, always a positive x *and* y offset, always `0` blur.
A blurred, tinted, or single-axis hard shadow is out of the system.

**The Gold Focus Rule.** Focus is always `0 0 0 3px var(--gold-300)` with `outline: none`.
It is the one place gold appears without meaning "action", and it must never be removed without a replacement of equal visibility.

## Shapes

A **six-step radius scale**, chosen by object scale rather than by nesting depth: `--radius-xs` **6px** (pins, small tags), `--radius-banner` **7px** (buttons), `--radius-sm` **9px** (inputs, option rows, icon buttons), `--radius-md` **12px** (stat tiles, poster cards), `--radius-lg` **18px** (standard cards), and `--radius-pill` **999px** (the ghost "more" chip and the 34px brand disc).
The button radius is deliberately tighter than the card scale, so a button reads as a stamped plate.

**Border weight is the emphasis dial**, and it moves in three steps.
**1px** `--border-default` or `--border-soft` covers ordinary card edges and row rules.
**1.5px** covers interactive edges such as option rows, inputs, icon buttons, pins, and the queued confirmation.
**2px** `--ink-900` covers emphatic objects such as poster cards, the brand disc, alert stat tiles, and the dealt decision cards.
A dashed **1.5px** `--ink-300` pill is the one dashed treatment in the system, reserved for "there are more of these".

The signature geometry is the **dealt stack**.
A decision card is a grid with two pseudo-element siblings painted behind it as full, opaque card faces at opposing rotations, `rotate(1.3deg) translate(4px, 5px)` and `rotate(-1.1deg) translate(-3px, 9px)`, each with the same 2px ink border and small hard offset.
The pile thins as cards are answered, so the stack's depth *is* the remaining count.

### Named Rules

**The Solid Pile Rule.** Stacked-card edges are opaque card faces at real rotations, never translucent offset rectangles.
A paper pile is made of paper, and faking it with opacity reads as a loading skeleton.

**The Radius-By-Scale Rule.** Radius tracks the object's physical size, not its position in the DOM.
A 6px pin inside an 18px card is correct, while a nested container inheriting its parent's 18px is not.

## Components

### Buttons

- **Character:** stamped plates, tighter-cornered than the cards around them, edged in ink, and pressing 1px down when struck.
- **Shape:** `--radius-banner` (7px), 2px border, inline-flex with an 8px icon gap, `white-space: nowrap`.
- **Primary:** Hull Rust fill, Signal White text, Log Ink border, 3px hard offset.
  Small size is `8px 16px` at `--fs-xs`, weight 800, and hover deepens the fill to Hull Rust Deep.
- **Gold:** Brass Gold fill, Deepwater Navy text, Log Ink border, 3px hard offset.
  Hover goes to Brass Deep with Signal White text, the one button that inverts its text colour on hover, because Brass Deep is too dark for navy.
- **Icon button** (stack nav): 34px square, `--radius-sm`, Signal White fill, 1.5px `--border-default`, with 16px stroke icons.
  Hover tints to Chart Paper and darkens the border to Ink Muted.
- **States:** every transition is 120ms across `background, border-color, transform, box-shadow`.
  `:focus-visible` swaps to the gold ring with `outline: none`, `:active` is `translateY(1px)`, and `[disabled]` is `opacity: 0.5` with `cursor: not-allowed` (0.4 on icon buttons).

### Pins (`fm-badge`)

- **Character:** small enamel signs nailed to the board.
  This is the system's most recognisable object.
- **Style:** inline-flex, 6px gap, `--fs-2xs` at weight 800, uppercase, 0.07em tracking, `5px 9px 4px` padding, `--radius-xs`, **1.5px `--ink-900` border**, **2px hard ink offset**, `line-height: 1`, never wrapping.
  The asymmetric bottom padding optically centres uppercase type.
- **Variants:** `online` Sea Green with Board Paper text, `warn` Brass Gold with Deepwater Navy, `danger` Hull Rust Deep with Board Paper, `info` Harbour Ocean with Board Paper, `neutral` Board Paper with Log Ink, and `solid` Hull Rust with Board Paper.
- **Rule:** a pin always carries a real ink border and offset.
  A borderless coloured rectangle is a chip, not a pin, and does not belong in this system.

### Section signs (`fm-sign`)

- **Character:** stencilled labels painted above each region of the board.
- **Style:** inline-flex, 8px gap, weight 800, uppercase, **0.16em** tracking, `--fs-xs`, `line-height: 1`, with a 14px stroke icon.
  `--eyebrow` is Hull Rust, and `--muted` is Ink Muted for the supporting count on the right of a section head.
- **Behaviour:** section heads are `display: flex` with `align-items: baseline` and `justify-content: space-between`, so the sign and its muted counterpart share a baseline.

### Cards / Containers

- **Corner style:** `--radius-lg` (18px) standard, `--radius-md` (12px) for poster.
- **Standard:** Signal White, 1px `--border-default`, soft ambient shadow, and `overflow: hidden` so child rows clip to the radius.
- **Warm:** the same card on Board Paper, used when a card holds pickable rows rather than read-only content.
- **Poster:** Signal White, **2px `--ink-900`**, 4px hard offset, 12px radius.
  Reserved for cards that must be obeyed or read, such as the decision card and the board-failed-to-load message.
- **Internal padding:** `18px 20px 16px` for card pads, with a 12px internal gap.

### Compact rows

- **Character:** a ledger line, flush, ruled, and ellipsised rather than wrapped.
- **Style:** flex, 12px gap, `11px 18px` padding, 1px `--border-soft` top rule, and none on the first child.
- **Content:** a flexible `min-width: 0` main block (title at `--fs-sm` / 700 Ink Strong, sub at `--fs-xs` Ink Muted, both single-line ellipsis) plus fixed-width mono metadata and a 26px `--radius-sm` state square (Sea Wash fill, Sea Green icon, 1.5px Sea Mist border) on the right.

### Option rows

- **Character:** a form field that behaves like a card, not a radio.
- **Style:** flex with `align-items: flex-start`, 10px gap, `9px 12px` padding, Board Paper fill, 1.5px `--border-default`, `--radius-sm`.
  The native input keeps `accent-color: var(--rust-500)` and `margin-top: 3px` to sit on the label's first line.
- **States:** hover darkens the border to Ink Faint, and selected uses `:has(input:checked)` for a Hull Rust border, Rust Wash fill, and a rust inset ring.
  A "recommended" tag sits right-aligned in Brass Pale fill, Deepwater Navy text, Brass Deep border, `--radius-xs`.

### Inputs

- **Style:** full width, Signal White, 1.5px `--border-default`, `--radius-sm`, `8px 11px` padding, Jost at `--fs-sm`, Ink Strong text.
- **Focus:** `outline: none`, border shifts to Hull Rust Light, plus the gold focus ring.
  The border shift and the ring work together, and neither alone is enough.

### Navigation

- **Style:** 64px sticky bar, tinted paper backdrop with blur, 1px `--border-default` bottom rule, container-width inner row.
- **Brand:** a 34px Hull Rust disc with a Board Paper stroke icon at 60%, a 2px ink border and a small hard offset, beside the 23px Chango wordmark in Ink Strong.
  The disc is the system's only circle.
- **Mobile:** unchanged, because the nav is already a single row that fits.

### Stat tiles

- **Character:** the board's numbers, read at a glance.
- **Style:** flex column, 4px gap, `14px 16px` padding, Board Paper, 1px `--border-soft`, `--radius-md`, `min-width: 0`.
- **Alert variant:** Rust Wash fill with a **2px Hull Rust** border and a Hull Rust Deep numeral, the one place a metric raises its voice.
- **Content:** mono numeral at `--fs-h3` / 600 / `line-height: 1`, and mono label at `--fs-2xs` uppercase with 0.04em tracking in Ink Muted.

### Signature component: the dealt decision stack

One decision at a time, dealt off a visible pile.
The wrapper is `position: relative; display: grid`, and `::before` and `::after` are opaque card faces at opposing small rotations and offsets behind it, each with the 2px ink border, 12px radius, and small hard offset.
All decision cards share `grid-area: 1 / 1` so only the active one shows.
Modifier classes thin the pile toward the end of the deck, where `--penult` drops one edge and `--last` and `--empty` drop both.
The stack-nav sits *below* the pile with a 6px top margin, so the pile edges that poke out underneath do not collide with it, and so the active card's top edge aligns with the neighbouring column's card.

## Do's and Don'ts

### Do:

- **Do** put every new colour through the semantic alias layer (`--status-*`, `--text-*`, `--border-*`, `--surface-*`) instead of letting a component reference a ramp step directly.
- **Do** pair every hard ink shadow with a matching ink border.
  `3px 3px 0 var(--ink-900)` with a 1.5-2px `var(--ink-900)` edge is the unit, and neither half works alone.
- **Do** set every machine fact, including ids, counts, timestamps, PR numbers, URLs, and provenance, in JetBrains Mono.
- **Do** use `minmax(0, 1fr)` on any grid track that holds ellipsised single-line text, and `min-width: 0` on any flex child that does.
- **Do** keep all state transitions at 120ms over `background, border-color, transform, box-shadow`, and press `:active` down by exactly 1px.
- **Do** replace a removed `outline` with `box-shadow: var(--focus-ring)` in the same rule.
  Every focusable control in this system has a visible gold ring.
- **Do** reach for intrinsic sizing (`auto-fit`, `minmax`, `fit-content`) before adding a second breakpoint.
- **Do** vary border weight (1px, then 1.5px, then 2px) to signal emphasis, rather than varying radius or shadow blur.

### Don't:

- **Don't** introduce `#000`, `#ffffff`, or any cool grey.
  Text is `--ink-900` (`#241c14`), white is `--white` (`#fffdf7`), and every surface carries a paper cast.
- **Don't** use Chango anywhere but the wordmark, and don't add a fourth typeface.
- **Don't** put a soft ambient shadow and a hard ink offset on the same element.
- **Don't** blur, tint, or single-axis a hard shadow.
  It is always positive x and y, zero blur, full-opacity `--ink-900`.
- **Don't** set structural sans type at 500 or 600.
  Structure is 700-800, and de-emphasis is a colour change to `--text-muted` or `--text-faint`, not a weight change.
- **Don't** spend Hull Rust on decoration.
  It marks what the captain must act on, and rationing it is what makes it work.
- **Don't** give Harbour Ocean an action.
  Ocean points elsewhere, and rust and gold are the only colours a control may wear.
- **Don't** fake a stacked pile with translucent offset rectangles, because stack edges are opaque card faces at real rotations.
- **Don't** add a `--spacing-*` custom property scale without migrating the existing literals, because a half-migrated scale is worse than the current consistent literals.

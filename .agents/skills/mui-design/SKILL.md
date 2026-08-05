---
name: mui-design
description: >-
  Agent-only reference for building UI on Material UI (MUI) instead of hand-rolling components.
  Use before designing, adding, or restyling any UI in a project whose frontend uses MUI.
  Use when choosing between reusing an MUI component and writing a new one.
  Use when starting a new screen, to check whether an official MUI template already covers its shape.
  Use before judging design-system conformance in the browser evaluation gate on an MUI project.
user-invocable: false
metadata:
  internal: true
---

# mui-design

This skill owns how UI gets built on Material UI: what to reach for first, where the design tokens live, and what counts as a defect.

It exists because the default failure mode is inventing. An agent asked for a dropdown writes a dropdown; asked for a table, writes a table. Each one is defensible alone, and together they become a second design system nobody chose, with its own spacing, its own focus states, and its own accessibility gaps.

## Check the project actually uses MUI

This skill applies only where MUI is a real dependency. Confirm it in the project's `package.json` before applying anything here.

**As of 2026-08-05, `parlino` does NOT have MUI installed.** Its frontend is React 18 + Vite with hand-written CSS in `app.css` and `landing.css`, and no component library. Adopting MUI there is a separate, unstarted migration - do not begin rewriting existing parlino components under these rules just because this skill loaded. Until that migration lands, `parlino`'s design authority is its own `docs/brand.md` plus `docs/landing.md`.

## The rule

**Find the MUI component first. Write your own only when MUI genuinely has none.**

A new one-off CSS class for something MUI already ships is a defect, not a style choice. So is a hand-built select, dialog, tooltip, tabs bar, snackbar, or data table.

Legitimate reasons to hand-write:

- The thing is domain-specific and has no generic equivalent - a call waveform, a conversation funnel, an audio player with product-specific states.
- MUI's component cannot express the required behavior, and you can say concretely which part fails.

"It was faster to write my own" is not one of them, and neither is "the MUI one looked different" - that is what the theme is for.

## Templates: start from a shape that exists

MUI ships eight free official templates, all with source on GitHub, each with a custom theme plus a default Material theme and light/dark modes. Sections are marked with comments so pieces can be lifted rather than copied whole.

| Template | Use it for |
|---|---|
| `Dashboard` | Metric-and-chart overview screens |
| `CRUD Dashboard` | List + create/edit/delete screens, mobile-friendly sidebar |
| `Sign-in`, `Sign-in Side`, `Sign-up` | Auth screens |
| `Checkout` | Multi-step flows with validation |
| `Blog` | Content/article layouts |
| `Marketing Page` | Landing pages: features, testimonials, pricing, FAQ |

Before building a screen, check whether one of these already has its shape, and take the layout and component choices from it. Take the structure, not the visual design - the theme supplies the look.

The paid store templates at `mui.com/templates` are a different thing; nothing here depends on them.

## The theme is the only source of tokens

Colour, radius, shadow, spacing and typography live in the theme. Components consume them.

- A hard-coded colour in `sx` is a defect. Use the palette.
- A spacing value invented outside the theme's scale is a defect.
- Brand values belong in the theme, taken from the project's brand document - not retyped per component.

When the brand and Material disagree, the brand wins and the theme is what encodes that: override `palette`, `typography`, `shape.borderRadius`, and per-component radii and shadows once, centrally, rather than fighting Material's defaults at each call site.

## Known obstacles when adding MUI to an existing hand-styled frontend

Recorded from the parlino survey so the next agent does not rediscover them. Each is real and none is a reason to give up - they are the things to solve deliberately, ideally before the first component is migrated.

- **Portals break element-scoped CSS variables.** `Dialog`, `Menu`, `Select`, `Tooltip`, `Popover` and `Snackbar` render into `document.body`, outside whatever element scopes your tokens. If variables are declared on a page wrapper rather than `:root`, every one of them resolves to nothing inside a portal.
- **Breakpoints must be reconciled, not stacked.** A project with its own breakpoint plus MUI's `0/600/900/1200/1536` reflows at two different widths on the same page. Pick one scale.
- **Inline styles beat MUI.** A codebase applying tokens via `style={{}}` will override MUI components silently; those call sites need converting to `sx` or theme usage.
- **`!important` beats everything.** Audit existing ones before assuming a component can be themed.
- **Style injection order matters.** Wrap the app in `StyledEngineProvider injectFirst` so MUI's styles come first and project CSS can override deliberately instead of by accident.
- **Icons are a set, not a pile.** `@mui/icons-material` is filled Material Symbols; mixing it with an existing line-art sprite reads as two icon languages. Choose one per surface.

## In the browser evaluation gate

On an MUI project the gate's design-system criterion means: **is this built from MUI components and the theme?** A screen that looks acceptable but reimplements a `Select` by hand, or hard-codes a hex that already exists in the palette, fails that criterion even when it renders correctly.

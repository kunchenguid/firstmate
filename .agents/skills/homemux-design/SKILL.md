---
name: homemux-design
description: Use this skill to generate well-branded interfaces and assets for HomeMux, either for production or throwaway prototypes/mocks/etc. Contains essential design guidelines, colors, type, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the README.md file within this skill, and explore the other available files.
If creating visual artifacts (slides, mocks, throwaway prototypes, etc), copy assets out and create static HTML files for the user to view. If working on production code, you can copy assets and read the rules here to become an expert in designing with this brand.
If the user invokes this skill without any other guidance, ask them what they want to build or design, ask some questions, and act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

## What HomeMux is
A premium, zen, iOS-first SSH/Mosh/tmux client. Near-black canvas, one calm mint-teal accent (`#7CF7B6`), iOS system fonts (SF Pro UI / SF Mono terminal), translucent floating chrome over the terminal, soft depth, generous space. Calm reassuring copy, no emoji, no hype. See `readme.md` for the full content + visual foundations.

## Where things are
- `styles.css` — link this one file; it `@import`s all tokens (`tokens/*.css`), including the four built-in terminal themes (`.term-homemux-dark` etc).
- `components/**` — React primitives. Load `_ds_bundle.js` and read `const { Button, Icon, ... } = window.HomeMuxDesignSystem_359607`. Each component has a `.prompt.md` with usage.
- `ui_kits/homemux-ios/` — full interactive iOS app recreation; copy screens as starting points.
- `assets/logo/` — brand mark (`homemux-icon.svg`, `homemux-mark.svg`).
- `guidelines/foundations/` — specimen cards for color/type/spacing/brand.

## Icons & fonts
Icons use **Lucide** (`unpkg.com/lucide`) as the web stand-in for the app's SF Symbols — load the UMD script and use the `Icon` component. The product type is **IBM Plex Sans** (UI) + **IBM Plex Mono** (terminal), loaded via `tokens/fonts.css` (Google Fonts); both are SIL OFL and bundle-able into the native app. Reference `var(--font-ui)` / `var(--font-mono)` — never hardcode.

## Defaults
Dark mode always. Use tokens, never invent colors. One primary (mint) action per screen, bottom-anchored. Terminal content is colored monospace on black using `var(--t-*)` from the active `term-*` class. Keep it minimal and quiet.

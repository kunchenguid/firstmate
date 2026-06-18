# HomeMux Design System

> **Your home terminal, anywhere.**
> A polished, premium, *zen* iOS-first SSH / Mosh / tmux client for developers who keep
> long-lived terminal sessions — coding agents, builds, tests — alive on their own
> machines (a Mac mini, workstation, or homelab server) and want to jump back in from
> their iPhone.

This is the design system for HomeMux: foundations (color, type, spacing, motion),
reusable React UI components, the terminal-theme palettes, the brand mark, and a
full interactive iOS UI kit. It exists so design agents can produce new HomeMux
screens, marketing, and prototypes that feel cohesive with the product.

---

## Product context

HomeMux is **subscription-free** (one-time lifetime purchase), **local-first** (no
account, no cloud vault; credentials live in the iOS Keychain), and narrow on purpose.
The core flow:

```
Add host → connect with the best transport (Automatic Mosh, fall back to SSH)
→ optionally one-tap attach to an existing tmux session → use a floating command menu → get back to work.
```

It is **not** an enterprise SSH manager, a server dashboard, or a new "workspace"
abstraction. It respects the workflow the user already has (SSH/Mosh + tmux) and makes
returning to it feel obvious and calm. The current app is functional-only; this system
is the holistic, premium design direction layered on top — designing *every state*.

### Sources (explore these to go deeper)

- **GitHub — `kunchenguid/homemux`** (private): native SwiftUI iOS app.
  - `docs/MVP-PLAN.md` — the definitive product + scope + flows doc (audience, jobs-to-be-done, command-menu spec, transport design, monetization, positioning).
  - `HomeMux/HomeMuxApp/Theming/TerminalTheme.swift` — the four built-in terminal themes (ported verbatim into `tokens/terminal-themes.css`).
  - `HomeMux/HomeMuxApp/Chrome/*` — `HomeView`, `TerminalSessionView`, `HostEditorView`, `SettingsView` (the screens recreated in the UI kit).
  - `HomeMux/HomeMuxApp/Onboarding/OnboardingView.swift`, `Theming/ThemePickerView.swift`, `Chrome/TerminalCommandCatalog.swift`.

  The recreations here are read from that Swift source (the source of truth), not from
  screenshots. If you have repo access, read those files to extend a screen faithfully.

---

## Content fundamentals — how HomeMux writes

The voice is **calm, plain, technical-but-human, and reassuring**. It explains what is
happening without alarm, and never oversells.

- **Person:** second person ("**your** terminal", "hosts **you** save"). The product
  refers to itself as "HomeMux", not "we".
- **Tone:** confident and quiet. It states facts and outcomes. Reassurance is a recurring
  job — especially around connectivity and privacy. Fallbacks are explained, not flagged
  as failures: *"Connected with SSH. Mosh is not installed on this machine."*
- **Casing:** Title Case for screen titles and buttons ("Add First Host", "Restore
  Purchase", "Attach tmux Session…"). Sentence case for body and helper text.
- **`tmux` / `ssh` / `mosh`** are lowercase as commands/protocols, mid-sentence
  ("Attach tmux session…", "Automatic uses Mosh when available"). Capitalize Mosh/SSH
  when used as proper transport names in badges.
- **Terminology:** *host* / *connection* / *one-tap tmux attach* / *transport* /
  *command menu* / *selection mode*. Avoid "server", "workspace", "project".
- **Length:** short. Titles are 2–5 words. Helper text is one sentence, occasionally two.
  Empty states teach in a sentence then offer one action.
- **Privacy is a feature, said plainly:** "Keys stay in Keychain." "No account, no cloud
  vault." "Voice stays on device."
- **No emoji. No exclamation marks** (one, at most, ever). No hype words ("revolutionary",
  "blazing"). Monospace is used for literal commands the app will run
  (`tmux new-session -A -s claude`), shown so advanced users can trust it.

Representative copy:

> One tap back into tmux • Local-first by design • Start with one host
> Could not connect — Mosh appears installed, but UDP could not reach this host. [Reconnect]
> Trial · 12 days left — Full access is unlocked during the trial. No terminal features are gated.

---

## Visual foundations

The whole product lives on a **near-black canvas** with **one calm mint-teal accent**.
It should feel zen: lots of negative space, a single focal action per screen, soft depth,
nothing noisy.

- **Color.** Canvas is `#0A0D12`–`#0B0E14` (the terminal background *is* the app
  background). Surfaces step up in near-black (`#11151C`, `#171C26`, `#1F2632`). The sole
  accent is **mint `#7CF7B6`** (interactive tint, caret, brand), with **teal `#5EEAD4`**
  as a secondary/icon-gradient partner. Status uses the terminal palette's own greens/
  ambers/reds (`#67E8A5` connected, `#F6C177` connecting, `#FF6B72` failed). Color is
  rationed — most of every screen is greyscale; the mint earns attention.
- **Type.** **IBM Plex Sans** (UI) + **IBM Plex Mono** (terminal: prompt, command
  drafts, keycaps, theme previews, literal commands) — an engineered, quietly premium,
  slightly editorial pairing. Both are SIL OFL (open source), loaded from Google Fonts in
  the web previews and bundle-able into the native iOS app. System families trail as
  fallbacks. Big bold large-titles (34/700, tight tracking); quiet secondary labels at 62%
  opacity.
- **Spacing & layout.** 2pt grid. 16px screen margins. Generous breathing room. One
  primary action, bottom-anchored and full-width, on action screens.
- **Backgrounds.** Mostly flat near-black. The only gradients are subtle: the onboarding
  canvas (a soft 160° dark wash) and the app-icon's radial vignette. No photography, no
  illustration, no texture/pattern. Live terminal output is the "imagery" — colored
  monospace on black.
- **Corners.** Continuous (squircle) radii: 8 keycaps, 12 icon tiles/inputs, 16 banners,
  20 theme cards, 24 sheets, 28 hero cards, 34 onboarding well. Capsules for badges/pills.
- **Cards.** Hairline border (`rgba(255,255,255,0.08)`), soft shadow
  (`0 8px 24px rgba(0,0,0,.34)`). Chrome floating over the terminal uses **translucent
  material**: a blurred dark fill (`backdrop-filter: blur(20px)`) — status bar, command
  draft bar, keyboard row, the floating command button, banners. Accent chrome gets a
  35%-mint hairline and sometimes a soft glow.
- **Borders & separators.** 1px hairlines, never heavy rules. Accent hairlines at 35%
  mint outline interactive/branded surfaces.
- **Shadows & glow.** Soft, low, dark shadows for elevation. The accent has a *glow*
  (`0 0 20px` mint at ~45%) used sparingly on the primary button, status dot, on switches,
  and behind the icon mark.
- **Transparency & blur.** Reserved for floating chrome over content (the terminal) and
  modals — the iOS "material" feel. Solid surfaces everywhere else.
- **Motion.** Calm and quick. Standard `cubic-bezier(0.4,0,0.2,1)`; an iOS-snappy spring
  `cubic-bezier(0.32,0.72,0,1)` for toggles, the segmented pill, and the page dots.
  Durations 140/240/360ms. The terminal caret blinks (1.1s steps). The connecting status
  dot pulses. No bounces, no decorative looping animation.
- **Hover/press.** This is a touch product: press = scale to 0.97, no harsh color shift.
  Pressable list rows lighten one surface step. Disabled = 40% opacity.
- **Imagery vibe.** Cool, dark, high-contrast, calm. Mint/teal on near-black. No warmth,
  no grain, no people.

---

## Iconography

- **System:** **Lucide** (MIT, CDN: `unpkg.com/lucide`), used as the web stand-in for the
  app's native **SF Symbols**. Both are thin, geometric, single-weight outline sets, so the
  look carries over. **This is a substitution — flagged below.** Stroke width 2 (2.25 for
  emphasis), color inherits via `currentColor` so icons take the accent or label tint.
- Use the `Icon` component (`<Icon name="terminal" />`) — it wraps Lucide. Common glyphs:
  `terminal`, `square-terminal`, `command`, `plus`, `settings`, `key-round`, `lock`,
  `mic`, `layers` (tmux), `rotate-cw` (reconnect), `server`, `shield-check`, `cloud-off`,
  `clock`, `chevron-left/right`, `check-circle`, `ellipsis`.
- **No emoji.** No unicode glyphs as UI icons — *except* inside the terminal viewport,
  where real shell glyphs are content: the `❯` prompt, `●`/`✓` status marks, box-drawing
  progress bars. Those are intentional and typed in the mono font.
- **Brand mark:** a custom gable **roof over two columns** — "many connections, one home"
  (the product's value prop). Mint gradient glyph on the dark radial canvas. See
  `assets/logo/` and the `AppIcon` / `Wordmark` components. (This replaces the original
  placeholder prompt-glyph icon from the repo.)

> ⚠️ **Substitutions to confirm:** (1) **Icons** — the app uses SF Symbols (not
> web-available); we use Lucide. (2) **Fonts** — the product type is **IBM Plex Sans / IBM
> Plex Mono** (SIL OFL), loaded from Google Fonts for the web previews. Bundle the licensed
> Plex files into the iOS build for offline/native rendering; system fonts trail as fallbacks.

---

## Index / manifest

**Root**
- `styles.css` — global entry point (the only file consumers link). `@import`s the tokens.
- `tokens/` — `colors.css`, `typography.css`, `spacing.css`, `terminal-themes.css`.
- `assets/logo/` — `homemux-icon.svg` (app tile), `homemux-mark.svg` (glyph), `icon-directions.html` (exploration).
- `SKILL.md` — Agent-Skills-compatible entry for Claude Code.

**Foundations** — specimen cards in `guidelines/foundations/` (Design System tab):
Colors (accent, surfaces, text, status, ANSI normal/bright), Type (display, body, mono,
scale), Spacing (radii, spacing, elevation, materials), Brand (icon & wordmark, terminal themes).

**Components** (`window.HomeMuxDesignSystem_359607.*`)
- `core/` — `Button`, `IconButton`, `Icon`, `Badge`, `KeyCap`, `StatusDot`
- `forms/` — `Switch`, `SegmentedControl`, `TextField`
- `surfaces/` — `Card`, `ListRow` (+ `IconTile`), `Banner`
- `terminal/` — `PaletteDots`, `ThemePreviewCard` (+ `themes.js` data)
- `brand/` — `AppIcon`, `Wordmark`

**UI kit** — `ui_kits/homemux-ios/` (`index.html`): interactive click-through of the iOS
app. Core flow — Onboarding → Home → Terminal (with the floating Command Menu) → Add Host
→ Settings — plus every designed **state**: empty (no hosts), Terminal connecting /
connection-failed-recovery / Mosh→SSH fallback notice / explicit selection mode, the
host-key trust dialog, the SSH password sheet, the tmux session picker (sessions / empty
/ not-installed), and the trial-ended paywall. A reviewer screen-jump bar under the device
opens each. Screens in `screens/`, sample data in `data.js`, device bezel via `ios-frame.jsx`.

---

*Built from the `kunchenguid/homemux` SwiftUI source. The terminal palettes, copy, screen
structure, and command catalog are lifted from the real app; explore that repo to extend
any screen with full fidelity.*
